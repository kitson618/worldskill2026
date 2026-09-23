# Well-Architected baseline（us-east-1）

從零建立一套對齊 AWS Well-Architected 的基礎設施。區域固定 `us-east-1`。Windows 用 PowerShell，macOS / Linux 用 bash。兩邊建的是同一套架構。

會產生費用：兩個 NAT Gateway、一台 ALB、CloudFront、WAF、一台 bastion、一台應用實例。用完請刪除。

## 檔案

| 檔案 | 用途 |
|---|---|
| `config.env` | 共用設定：VPC 名稱、CIDR、`ENV=prd`、實例類型 |
| `create.ps1` | Windows PowerShell 5.1 / PowerShell 7 |
| `create.sh` | bash（macOS / Linux） |
| `wa-state.json` | PowerShell 建立後寫入，`destroy` 用。不要提交 |
| `wa-state.env` | bash 建立後寫入，`destroy` 用。不要提交 |
| `wa-bastion.pem` | bastion 私鑰，只產生一次。不要提交 |

## 前置條件

- AWS CLI v2 在 `PATH` 上，且已設定憑證（`aws sts get-caller-identity` 要成功）
- 帳號在 `us-east-1` 至少有兩個可用 AZ
- PowerShell 版不需要 Python、OpenSSL、Git Bash
- bash 版需要 `python3`、`curl`、`openssl`

腳本會忽略本機預設 region，一律打 `us-east-1`。

## 建立

Windows PowerShell：

```powershell
cd well-architected
Set-ExecutionPolicy -Scope Process Bypass
.\create.ps1
```

bash：

```bash
cd well-architected
chmod +x create.sh
./create.sh
```

## 設定

所有變數在 [config.env](config.env)。`create.sh` 和 `create.ps1` 讀同一份。已存在的環境變數優先於檔案。

```text
REGION=us-east-1
NAME=wa
ENV=prd
VPC_NAME=wa-vpc
VPC_CIDR=10.0.0.0/16
PUBLIC_CIDR_1=10.0.0.0/24
PUBLIC_CIDR_2=10.0.1.0/24
PRIVATE_CIDR_1=10.0.10.0/24
PRIVATE_CIDR_2=10.0.11.0/24
ISOLATED_CIDR_1=10.0.20.0/24
ISOLATED_CIDR_2=10.0.21.0/24
INSTANCE_TYPE=t3.micro
BASTION_SSH_CIDR=
```

`ENV` 會寫成每個資源的 tag `env`。預設是 `prd`。改 VPC 名稱或 CIDR 只改這個檔，不要改腳本。`REGION` 必須是 `us-east-1`，因為 CloudFront WAF 只能建在這個區域。

可選參數：

| 變數 | 預設 | 說明 |
|---|---|---|
| `NAME` | `wa` | 資源名稱前綴，也是 `Project` tag |
| `ENV` | `prd` | tag `env` 的值 |
| `VPC_NAME` | `wa-vpc` | VPC 的 Name tag |
| `VPC_CIDR` | `10.0.0.0/16` | VPC CIDR |
| `PUBLIC_CIDR_1` / `PUBLIC_CIDR_2` | `10.0.0.0/24`、`10.0.1.0/24` | 公網 |
| `PRIVATE_CIDR_1` / `PRIVATE_CIDR_2` | `10.0.10.0/24`、`10.0.11.0/24` | 私網 |
| `ISOLATED_CIDR_1` / `ISOLATED_CIDR_2` | `10.0.20.0/24`、`10.0.21.0/24` | 隔離網 |
| `INSTANCE_TYPE` | `t3.micro` | bastion 與應用實例 |
| `BASTION_SSH_CIDR` | 空，表示目前公網 IP `/32` | bastion SSH 來源 |

名稱在區域內必須唯一。已有 `wa-state.json` 或 `wa-state.env` 時，腳本會拒絕再建一次。

## 刪除

```powershell
.\create.ps1 -Action destroy
```

```bash
./create.sh destroy
```

CloudFront 要先停用再等部署完成，這一步常常要十多分鐘。狀態檔會在刪除結束後移除。

## 架構

```
Internet
  -> CloudFront（強制 HTTPS、TLS 1.2）+ WAF
    -> public ALB :80
      -> ASG（private subnet，launch template）
Bastion 在 public subnet，SSH 只開你的 IP，並掛 SSM
Isolated subnet 沒有 IGW、沒有 NAT
每個 AZ 一個 NAT，只給 private subnet
一個 S3 bucket：ALB access log + VPC flow log
```

VPC `10.0.0.0/16`：

| 層 | CIDR | 出網 |
|---|---|---|
| public-a / public-b | `10.0.0.0/24`、`10.0.1.0/24` | IGW |
| private-a / private-b | `10.0.10.0/24`、`10.0.11.0/24` | 該 AZ 的 NAT |
| isolated-a / isolated-b | `10.0.20.0/24`、`10.0.21.0/24` | 無。之後放資料庫 |

S3 Gateway endpoint 掛在 private 與 isolated 路由表，存取 S3 不經 NAT。

應用路徑：

1. WAF（CloudFront scope，必須 `us-east-1`）：IP reputation、Common Rule Set、Known Bad Inputs
2. CloudFront 對 origin 加上 `X-Origin-Verify`
3. ALB 安全組只允許 CloudFront 的 origin-facing prefix list，不開 `0.0.0.0/0`
4. 沒有這個 header 的請求，ALB 回 403；有 header 才轉到 target group
5. Launch template userdata 安裝 `httpd`，用 IMDSv2 寫出 instance id 與 AZ

直接打 ALB DNS 應為 403。等 CloudFront 部署完成後，用腳本印出的 `https://xxxx.cloudfront.net/`。應用實例還要約 3 分鐘才會 healthy。

## Well-Architected 對應

| 支柱 | 這份腳本做了什麼 |
|---|---|
| 安全 | IMDSv2、EBS / S3 加密、S3 封鎖公開與禁止 HTTP、執行個體角色只有 SSM、ALB 不對全網開放、origin header、WAF |
| 可靠 | 兩個 AZ、每個 AZ 一個 NAT、ASG + ELB 健康檢查、ALB 刪除保護、依 ALB request 的 target tracking |
| 效能 | CloudFront 在 ALB 前面、HTTP/2。動態站台使用 CachingDisabled |
| 成本 | `t3.micro`、`PriceClass_100`、日誌 90 天過期。沒有 Shield Advanced |
| 營運 | 統一 tag、VPC flow log（Parquet）、ALB access log、ALB 5xx 警報、狀態檔供刪除 |

單一 NAT 較便宜，但一個 AZ 故障時該 AZ 的私網出不了網，所以這裡用兩個。

## 建完會印出

- CloudFront URL
- ALB DNS（直接存取應 403）
- bastion 公網 IP 與 pem 路徑
- S3 bucket 名稱
- `X-Origin-Verify` 的值（也寫在狀態檔）

Bastion：

```powershell
ssh -i .\wa-bastion.pem ec2-user@<BASTION_PUBLIC_IP>
```

也可以用 Session Manager，不必開 SSH。應用實例在 private subnet，沒有公網 IP。

## 沒有包含

- 自訂網域與 ACM 憑證（CloudFront 用預設憑證）
- ALB HTTPS listener（CloudFront 到 origin 是 HTTP，靠 prefix list 與 origin header 限制來源）
- 資料庫。isolated subnet 已留好，腳本不安 RDS / DocumentDB
- 多帳號、IaC 狀態後端、CI

## 費用

NAT Gateway 按小時加流量計費，兩顆會一直扣到 `destroy` 成功。CloudFront 停用等待期間 ALB 與 NAT 仍在計費。
