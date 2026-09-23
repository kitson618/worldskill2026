# `app.yml` — Unicorn GameDay 基礎設施模板

AWS CLI 分段教學：[cli/README.md](cli/README.md)，完整腳本：[app.sh](app.sh)。SDK 教學（boto3）：[sdk/README.md](sdk/README.md)。

CloudFormation 模板（706 行，`AWSTemplateFormatVersion: 2010-09-09`）。`Description` 只有一個字：`Unicorn`。這是中國區 Cloud Raiser / HengHa GameDay 的 **選手端應用堆疊**，不是出題方的 nested stack（那個是同目錄的 `StackSet-HengHa-CloudRaiser-game-nested-stack.yml`）。

同目錄對應資產：

| 檔案 | 用途 |
|---|---|
| `ws-ec2-pipeline-server` | ASG userdata 會從 S3 拉下來執行的 Go binary |
| `test.json` | Bastion userdata 用的 SSM 取 key 指令 |
| `dashboard/` | 分數板前端殘件（此模板沒有部署它） |

預設區域從硬編碼 ARN 可判斷是 **`us-east-1`**，帳號 **`608671652196`**。模板本身沒有 `AWS::Region` 參數。

---

## 這份模板在建什麼

一條對外路徑、一條資料路徑：

```
Internet
  → CloudFront（自訂 Cache Policy，只轉發一條 query string）
    → internet-facing ALB :80（兩條 public subnet）
      → ASG（t3.micro，private subnet × 2）
        → ./ws-ec2-pipeline-server
          → DocumentDB（Mongo 相容，27017）
          → Secrets Manager（VPC Interface Endpoint）
          → AppConfig（DB / S3 / API Gateway 連線資訊）
          → S3 `gameday-608671652196`（binary + 可能的業務物件）

旁路：
  API Gateway (REGIONAL) GET /  → Lambda（回傳 account_id）
  Bastion t3.micro（public subnet 1，SSH 鎖單一 IP）
  VPC Flow Logs → 同一個 S3 bucket（Parquet / Hive / 每小時 partition）
```

對齊 GameDay 常見給分項：多 AZ、ALB、CloudFront、S3 versioning + AES256、Flow Log、ASG、私網資料庫、Secrets Manager、X-Ray tracing。

---

## 參數

| 參數 | 預設 | 說明 |
|---|---|---|
| `EnvironmentName` | `Unicorn` | 資源 Name tag 前綴 |
| `VpcCIDR` | `10.0.0.0/16` | VPC |
| `PublicSubnet1CIDR` | `10.0.10.0/24` | AZ0 公網 |
| `PublicSubnet2CIDR` | `10.0.11.0/24` | AZ1 公網 |
| `PrivateSubnet1CIDR` | `10.0.20.0/24` | AZ0 私網 |
| `PrivateSubnet2CIDR` | `10.0.21.0/24` | AZ1 私網 |
| `apiGatewayHTTPMethod` | `GET` | **沒有被任何資源引用** |

CIDR 寫死在 `ApplicationSg` / `DatabaseSg` 的 ingress（`10.0.0.0/16`），改 `VpcCIDR` 不會跟著改安全組。

---

## 網路

兩 AZ、各一公一私。公網共用一張路由表 → IGW；私網也共用 **一張** 路由表 → **單一 NAT**（EIP + NAT 都在 `PublicSubnet1`）。

後果：

- AZ1 的私網實例跨 AZ 走 NAT，單點故障、流量費較高。
- 私網路由表 Name tag 寫 `(AZ1)`，實際上綁了兩條 private subnet。
- GameDay 成本／可靠度題若要求「每層多 AZ、每 AZ 自己的 NAT」，這份過不了。

Bastion 在 `PublicSubnet1`，公網 IP，SG 只放行 `119.237.240.242/32:22`。

應用 SG `ApplicationSg` 對 VPC CIDR 放行 80 / 22 / 443。ALB 網卡在 public subnet（`10.0.10.0/24`、`10.0.11.0/24`），因此 ALB → 實例 :80 走得通。沒有「只允許 ALB SG」的收緊。

---

## 儲存與流量日誌

`s3Bucket`：

- 名稱硬編碼 `gameday-608671652196`（全域唯一，換帳號必炸）
- `AccessControl: Private`（舊欄位，新帳號可能直接拒絕）
- Versioning `Enabled`
- SSE-S3 AES256

`S3Flowlog`：VPC 全流量、60s 聚合、目的地 S3、格式含 src/dst/port/protocol、Parquet + Hive partition + 每小時切分。

註解掉的：

- CloudWatch Logs 版 Flow Log（還引用不存在的 `FlowLogRole`）
- S3 bucket policy（空的 `Statement`）

沒有 delivery.amazonaws.com / `aws:SourceAccount` 的 bucket policy 時，Flow Log 常常寫不進去。評分若查「VPC flow log enabled」只看資源存在，不一定查得到實際檔案。

---

## API Gateway + Lambda

Lambda `nodejs18.x`，inline：

```js
exports.handler = async function(event) {
  return {"account_id": "608671652196"};
};
```

- Role 硬編碼 `arn:aws:iam::608671652196:role/MyLambdaExecutionRole`（模板不建立；nested stack 那邊才有同名角色）
- `TracingConfig.Mode: Active`（X-Ray 給分項）
- Timeout 5s

API Gateway：

- REST API、REGIONAL、名稱 `unicorn-apigw`
- 根路徑 `GET`，`AuthorizationType: NONE`
- Integration type `AWS`（非 AWS_PROXY），`IntegrationHttpMethod: GET`（Lambda 呼叫慣例是 **POST**）
- URI 寫死 `arn:aws:apigateway:us-east-1:lambda:path/...`
- Stage `Prod`

`AWS::Lambda::Permission` **整段註解**。沒有這條 permission，API Gateway 調不到 Lambda。`apiGatewayHTTPMethod` 參數也沒用上。

AppConfig 裡的 API URL 是另一次部署留下的：

`https://ihowe95td3.execute-api.us-east-1.amazonaws.com/Prod`

重新部署會換 id，這段字串不會更新。

---

## 運算：Bastion、ALB、ASG

### Key / IAM

- `AWS::EC2::KeyPair` 名稱 `gameday-key`
- `EC2Role` 是 Instance Profile，角色名 **`WSEC2Role`（既有，模板不建）**
- Bastion userdata 再從 SSM 拉一把 **另一個** key：`/ec2/keypair/key-0067cec476023d650`（與 CFN 建的 KeyPair 不是同一把）

### Bastion

`ami-0b72821e2f351e396`、`t3.micro`、Name=`bastion`。AMI 沒有 SSM 參數，換區域即失效。

### ALB

internet-facing、兩 public subnet、:80 HTTP、health check HTTP :80 / 200。Access log 整段註解（還曾把 log bucket 設成 `PublicRead`）。

Target group：interval 30、timeout 15、healthy 5、unhealthy 3、deregistration 20s。沒寫 `TargetType`，預設 `instance`，給 ASG 用是對的。

### Launch Template + ASG

- 同 AMI、`t3.micro`、Name=`Application`
- userdata：`aws s3 cp s3://gameday-608671652196/ws-ec2-pipeline-server .`，下載 RDS CA bundle，`chmod 700` 後直接跑 binary
- `AssociatePublicIpAddress: true` 但 ASG 放在 **private subnet**（這旗標對私網通常無效；出網靠 NAT）
- ASG `MinSize=1` `MaxSize=5`，掛 `EC2TargetGroup`，收集 `GroupMinSize` / `GroupMaxSize`（1 分鐘）
- **沒有 Target Tracking / Step Scaling**。GameDay 成本比與「hands-off 後自動擴縮」這兩項都拿不到
- 模板不會把 `ws-ec2-pipeline-server` 上傳到 S3；ASG 起來時 bucket 是空的，binary 起不來

---

## CloudFront

自訂 Cache Policy：

- DefaultTTL 86400、MinTTL 1、MaxTTL 1 年
- Cookie / Header：none
- Gzip + Brotli
- Query string **whitelist 一條**：`input-SUNhbkhhelVuaWNvem40LTY3NDkSY`

這條 query 很像評分探測用的 token。沒帶這個參數的請求，快取 key 不含 query；帶了才進 cache key 並轉發 origin。

Distribution：

- Origin = ALB DNS、HTTP only、port 80
- `ViewerProtocolPolicy: allow-all`（HTTP 不強制跳 HTTPS）
- 沒有 Alternate domain、WAF、OAC、自訂 error page、logging

---

## DocumentDB + Secrets Manager

| 資源 | 行為 |
|---|---|
| `SecretsManagerVPCEndpoint` | Interface endpoint，`us-east-1` 硬編碼，Private DNS 開，SG 掛 Application + Bastion |
| `DatabaseSg` | 27017 對 `10.0.0.0/16` |
| `DocDBClusterRotationSecret` | 自動產生 16 字元密碼、`username=someadmin`、`ssl=true`、無標點 |
| `DocDBCluster` | 從 secret dynamic reference 取帳密 |
| `DocDBInstance` | `db.t3.medium`（DocumentDB 最低檔；單實例、無 replica） |
| `DBSubnetGroup` | 兩條 private subnet |
| `SecretTargetAttachment` | 把 secret 綁到 cluster |

沒開：加密、備份天數、deletion protection、Multi-AZ replica、審計。輪替 `RotationSchedule` 整段註解，而且引用的是不存在的 `MyDocDBClusterRotationSecret` / `TestVPC` / `TestSubnet01`。

---

## AppConfig

一次部署完整鏈：Application `Unicorn` → Environment `Production` → hosted profile → version 1 → strategy（0 分鐘、GrowthFactor 100，等於立刻切滿）→ Deployment。

Hosted JSON（應用 binary 的執行設定）：

```json
{
  "DBSeretARN": "arn:aws:secretsmanager:us-east-1:608671652196:secret:DocDBClusterRotationSecret-…",
  "MongoDbDatabase": "unicorndb",
  "MongoDbCollection": "unicorncollection",
  "MongoDbCAFilePath": "./global-bundle.pem",
  "Port": 80,
  "Bucket": "gameday-608671652196",
  "ApiGatewayUrl": "https://ihowe95td3.execute-api.us-east-1.amazonaws.com/Prod"
}
```

`DBSeretARN` 拼錯（少一個 c）。ARN 與 API URL 都是 **上一次手動貼上的字串**，不是 `!Ref` / `!GetAtt`。新 stack 的 secret 後綴會變，binary 會連到舊 ARN。

Deployment 的 `ConfigurationVersion: '1'` 也寫死；改 hosted content 不會自動出新版。

---

## Outputs

只輸出：VPC、四條 subnet、S3 bucket 名、Lambda 名、Secret ARN。

**沒有**：ALB DNS、CloudFront domain、API Gateway URL、DocDB endpoint、AppConfig ApplicationId。對完賽後對分數板／填 `server.ini` 不友善。

---

## 依賴與部署前必備（模板外）

模板假設帳號裡已經有：

1. IAM role `MyLambdaExecutionRole`（Lambda 執行；nested stack 有建）
2. IAM role `WSEC2Role`（EC2 instance profile；要能 `s3:GetObject`、`ssm:GetParameter`、讀 Secrets Manager / AppConfig）
3. 物件 `s3://gameday-608671652196/ws-ec2-pipeline-server`（ASG 啟動後才需要，但 bucket 是這份模板建的，要自己再 `aws s3 cp`）
4. （可選）SSM 參數 `/ec2/keypair/key-0067cec476023d650` — 只給 Bastion userdata 用

部署：

```bash
aws cloudformation deploy \
  --region us-east-1 \
  --template-file gameday-cn/app.yml \
  --stack-name unicorn \
  --parameter-overrides EnvironmentName=Unicorn

# 模板建完 bucket 之後再上傳 binary
aws s3 cp gameday-cn/ws-ec2-pipeline-server s3://gameday-608671652196/ws-ec2-pipeline-server
```

換帳號前至少要改：bucket 名、三處帳號 ARN、Lambda inline 的 `account_id`、AppConfig JSON、API Gateway URI 區域、Secrets Manager endpoint service name、Bastion SSH CIDR、AMI。

---

## 已知缺口（對照 GameDay 給分）

| 項目 | 狀態 |
|---|---|
| CloudFront | 有，但 origin HTTP-only、無 HTTPS 強制 |
| S3 versioning / 加密 | 有 |
| VPC Flow Log | 資源有；缺 bucket policy，實際落檔不保證 |
| EC2 Name tag | Bastion / Application 有 |
| ALB | 有 |
| 多 AZ subnet | 有 |
| 運算放私網 | ASG 在 private；Bastion 在 public |
| ASG target tracking（依 ALB request） | **無** |
| SG 無 `0.0.0.0/0` | ALB :80 是 `0.0.0.0/0`（HTTP 對外必要）；應用 SG 已收在 VPC CIDR |
| API Gateway tag | **無任何 Tag** |
| API Gateway X-Ray | Lambda 有 Active tracing；API 本身沒開 tracing |
| Lambda invoke permission | **註解掉，API 不通** |
| RDS/DocDB 加密、備份 ≥7 天、deletion protection | **都沒設** |
| Secret 輪替 | 註解且引用錯誤 logical ID |
| ECR / ECS | 不用（這題是 EC2 + Go binary） |
| WAF | 無 |
| IaC 可重複部署 | 大量硬編碼，換帳號／區域不能直接套 |

註解區塊（未啟用）：CloudWatch Flow Log、S3 bucket policy、Lambda permission、ALB log bucket、Secret rotation。

---

## 資源一覽

| Logical ID | 類型 | 備註 |
|---|---|---|
| `VPC` | `AWS::EC2::VPC` | DNS 開 |
| `InternetGateway` + `InternetGatewayAttachment` | EC2 | |
| `PublicSubnet1/2` `PrivateSubnet1/2` | Subnet | `!Select [0/1, !GetAZs '']` |
| `NatGatewayEIP` `NatGateway` | EIP + NAT | 只在 public-1 |
| `PublicRouteTable` `PrivateRouteTable` + routes/assoc | 路由 | 私網兩條 subnet 共用 |
| `s3Bucket` | S3 | 名稱寫死 |
| `S3Flowlog` | FlowLog | → 上列 bucket |
| `lambdaFunction` | Lambda | 硬編碼 role / account |
| `apiGateway` `apiMethod` `Deployment` | API Gateway | Stage `Prod` |
| `Ec2KeyPair` | KeyPair | `gameday-key` |
| `EC2Role` | InstanceProfile | 引用 `WSEC2Role` |
| `BastionSg` `Ec2Instance` | Bastion | SSH 單 IP |
| `ELBSecurityGroup` `ApplicationLoadBalancer` `EC2TargetGroup` `ALBListener` | ALB | :80 |
| `MyCustomCachePolicy` `cloudfrontdistribution` | CloudFront | origin=ALB |
| `ApplicationSg` `applicationLaunchTemplate` `applicationAsg` | 應用層 | min 1 max 5 |
| `SecretsManagerVPCEndpoint` | Interface VPCE | |
| `DatabaseSg` `DocDBCluster` `DocDBInstance` `DBSubnetGroup` | DocumentDB | `db.t3.medium` |
| `DocDBClusterRotationSecret` `SecretDocDBClusterAttachment` | Secrets Manager | |
| `Application` `ProdEnvironment` `ConfigurationProfile` `HostedConfigurationVersion` `DeploymentStrategy` `appConfigDeployment` | AppConfig | 連線 JSON 寫死 |

沒有 `Mappings`、`Conditions`、`Metadata`、`Rules`。
