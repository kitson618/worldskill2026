# Unicorn GameDay — AWS CLI 分段範例

這份文件把 [`app.yml`](../app.yml) 拆成可以分開讀的 AWS CLI 範例。完整腳本在 [`app.sh`](../app.sh)。同一套 API 的 boto3 版在 [`sdk/README.md`](../sdk/README.md)。

CLI 和 SDK 打的是同一組 API。差別是：SDK 從回傳 dict 取 ID，CLI 用 `--query` 把 ID 放進 shell 變數，下一條命令再讀它。CloudFormation 的 `!Ref` / `!GetAtt` 在這裡都要自己接。

```bash
export AWS_PAGER=""
export AWS_DEFAULT_REGION=us-east-1
# 一次建完：
../app.sh
```

下面的片段假設你在同一個 shell 裡依序跑。會建立要收費的資源（NAT Gateway、DocumentDB、CloudFront）。沒有對真實帳號跑過。

| 章 | 在教什麼 | 對應 `app.yml` |
|---|---|---|
| 0 | `--query`、引號、`file://` | Parameters |
| 1 | 建立 → 存 ID → `aws … wait` | VPC、subnet、IGW、NAT、路由表 |
| 2 | `s3api` 分次設定；單引號保住 `${…}` | `s3Bucket`、`S3Flowlog` |
| 3 | policy 是 JSON 字串 | 模板假設已存在的兩個 role |
| 4 | `fileb://` zip；多次 `put-*` | Lambda、API Gateway |
| 5 | `file://` userdata 不用自己 base64 | Key pair、bastion |
| 6 | shorthand `Key=Value` | ALB、target group、listener |
| 7 | 複雜結構用 JSON 檔，不要硬寫 shorthand | Cache policy、distribution |
| 8 | Launch Template 的 UserData 要自己 base64 | Launch template、ASG |
| 9 | 沒有 `{{resolve:secretsmanager}}` | Secrets Manager、VPC endpoint、DocumentDB |
| 10 | 六個 ID 依序接 | AppConfig 整條部署鏈 |

---

## 0. 先會這三個習慣

### 用 `--query` 接 ID

CloudFormation 的 `!Ref VPC`，在 CLI 是：

```bash
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="gameday-${ACCOUNT_ID}"
```

`--query` 是 JMESPath，`--output text` 才不會帶引號。漏了 `--output text`，變數會變成 `"vpc-abc"`（含雙引號），下一條命令會失敗。

模板把帳號 `608671652196` 和 bucket 名寫死。範例改從 STS 取。

### 引號決定誰來展開變數

| 寫法 | 誰展開 |
|---|---|
| `"$VPC_ID"` | shell。要用上一步的 ID 時用這個 |
| `'${version}'` | 不展開。Flow Log 的 `${version}` 是 AWS token，必須單引號 |
| `file://path.json` | CLI 讀檔。複雜 JSON 用這個，不要在命令列跳脫 |

### `file://` 和 `fileb://`

- `file://policy.json`：文字。IAM policy、CloudFront config、secret JSON。
- `fileb://function.zip`：二進位。Lambda zip、AppConfig content。少了 `b`，CLI 會把 zip 當 UTF-8 讀壞。

---

## 1. 網路

對應：`VPC`、四條 subnet、`InternetGateway`、`NatGateway`、兩張路由表。

要學的模式：每一條 `create-*` 都用 `--query` 把 ID 存下來。NAT 是非同步的，路由必須等 `aws ec2 wait`。

```bash
AZ1="$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)"
AZ2="$(aws ec2 describe-availability-zones --query 'AvailabilityZones[1].ZoneName' --output text)"

VPC_ID="$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
aws ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value=Unicorn

IGW_ID="$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)"
aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"

PUBLIC_SUBNET1="$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block 10.0.10.0/24 --availability-zone "$AZ1" \
  --query 'Subnet.SubnetId' --output text)"
aws ec2 modify-subnet-attribute --subnet-id "$PUBLIC_SUBNET1" --map-public-ip-on-launch
# public-2 = 10.0.11.0/24 / $AZ2
# private-1 = 10.0.20.0/24 / $AZ1
# private-2 = 10.0.21.0/24 / $AZ2

EIP_ALLOC="$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)"
NAT_GW_ID="$(aws ec2 create-nat-gateway \
  --subnet-id "$PUBLIC_SUBNET1" --allocation-id "$EIP_ALLOC" \
  --query 'NatGateway.NatGatewayId' --output text)"

PUBLIC_RT="$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)"
PRIVATE_RT="$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)"
aws ec2 create-route --route-table-id "$PUBLIC_RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
aws ec2 associate-route-table --route-table-id "$PUBLIC_RT" --subnet-id "$PUBLIC_SUBNET1"
aws ec2 associate-route-table --route-table-id "$PRIVATE_RT" --subnet-id "$PRIVATE_SUBNET1"
aws ec2 associate-route-table --route-table-id "$PRIVATE_RT" --subnet-id "$PRIVATE_SUBNET2"

aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID"
aws ec2 create-route --route-table-id "$PRIVATE_RT" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_GW_ID"
```

和模板一樣：兩條 private subnet 共用一張路由表、一個 NAT，放在 public subnet 1。AZ 故障時私網出不了網。`AvailabilityZones[0]` 等同模板的 `!Select [0, !GetAZs '']`。

`--enable-dns-support` 是旗標，不是 `create-vpc` 的欄位。漏了，私網的 DNS（Secrets Manager endpoint、RDS hostname）會解不開。

---

## 2. S3 與 Flow Logs

對應：`s3Bucket`、`S3Flowlog`。

要學的模式：`aws s3 mb` 只能建 bucket。版本、加密、封鎖公開存取是 `aws s3api` 的另外三次呼叫。

```bash
# us-east-1 不能帶 LocationConstraint。其他區域才要：
#   --create-bucket-configuration LocationConstraint="$AWS_DEFAULT_REGION"
aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_DEFAULT_REGION"
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]
  }'
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Flow Log 的 format **必須單引號**。雙引號時 shell 會把 `${version}` 展開成空字串，AWS 收到的 format 是壞的，命令還是成功。

```bash
aws ec2 create-flow-logs \
  --resource-type VPC \
  --resource-ids "$VPC_ID" \
  --traffic-type ALL \
  --log-destination-type s3 \
  --log-destination "arn:aws:s3:::${BUCKET}" \
  --log-format '${version} ${vpc-id} ${subnet-id} ${instance-id} ${srcaddr} ${dstaddr} ${srcport} ${dstport} ${protocol} ${tcp-flags} ${type} ${pkt-srcaddr} ${pkt-dstaddr}' \
  --max-aggregation-interval 60 \
  --destination-options FileFormat=parquet,HiveCompatiblePartitions=true,PerHourPartition=true
```

回傳裡的 `Unsuccessful` 不為空才算失敗。CLI 有時仍 exit 0。要看輸出，不要只看 exit code。

模板沒有給 flow log 的 bucket policy。資源可以建出來，檔案不一定寫得進去。範例故意不加，以便和模板對得起來。

---

## 3. 模板沒建立的 IAM

`app.yml` 直接寫死 `MyLambdaExecutionRole` 和 `WSEC2Role`。CLI 範例在角色不存在時才建。

```bash
if ! aws iam get-role --role-name MyLambdaExecutionRole >/dev/null 2>&1; then
  aws iam create-role --role-name MyLambdaExecutionRole \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Principal":{"Service":"lambda.amazonaws.com"},
        "Action":"sts:AssumeRole"
      }]
    }'
  aws iam attach-role-policy --role-name MyLambdaExecutionRole \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  aws iam attach-role-policy --role-name MyLambdaExecutionRole \
    --policy-arn arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess
fi
LAMBDA_ROLE_ARN="$(aws iam get-role --role-name MyLambdaExecutionRole --query 'Role.Arn' --output text)"
```

`--assume-role-policy-document` 要的是 JSON **字串**。上面用單引號包住，shell 不會去展開。檔案比較大時改成：

```bash
aws iam create-role --role-name WSEC2Role \
  --assume-role-policy-document file://ec2-trust.json
```

EC2 還要 instance profile，而且建完不能立刻拿去 `run-instances`。IAM 是最終一致，等十秒：

```bash
aws iam create-instance-profile --instance-profile-name WSEC2Role --path /
aws iam add-role-to-instance-profile \
  --instance-profile-name WSEC2Role --role-name WSEC2Role
sleep 10
```

`get-role` 找不到時 exit code 非 0。`set -e` 的腳本要用 `if ! aws iam get-role ...`，不能裸呼叫。

---

## 4. Lambda 與 API Gateway

對應：`lambdaFunction`、`apiGateway`、`apiMethod`、`Deployment`。

要學的模式：程式先 zip，用 `fileb://` 上傳。API Gateway 不是一條命令，是 method → integration → deployment。沒有 `create-deployment` 就沒有可呼叫的 URL。

```bash
mkdir -p /tmp/unicorn-cli
cat > /tmp/unicorn-cli/index.js <<EOF
exports.handler = async function(event) {
  return {"account_id": "${ACCOUNT_ID}"};
};
EOF
( cd /tmp/unicorn-cli && zip -q function.zip index.js )

aws lambda create-function \
  --function-name unicorn-apigw-fn \
  --runtime nodejs18.x \
  --handler index.handler \
  --timeout 5 \
  --tracing-config Mode=Active \
  --role "$LAMBDA_ROLE_ARN" \
  --zip-file fileb:///tmp/unicorn-cli/function.zip

LAMBDA_ARN="$(aws lambda get-function --function-name unicorn-apigw-fn \
  --query 'Configuration.FunctionArn' --output text)"
```

`create-function` 的回傳已經有 ARN。再 `get-function` 是為了和「建立與查詢分開」的習慣對齊；角色剛建好時，第一次 create 也可能因 IAM 延遲失敗，重試時用 `get-function` 取已存在的 ARN。

```bash
API_ID="$(aws apigateway create-rest-api \
  --name unicorn-apigw \
  --description unicorn-apigw \
  --endpoint-configuration types=REGIONAL \
  --query id --output text)"
ROOT_ID="$(aws apigateway get-resources --rest-api-id "$API_ID" \
  --query 'items[0].id' --output text)"

aws apigateway put-method \
  --rest-api-id "$API_ID" --resource-id "$ROOT_ID" \
  --http-method GET --authorization-type NONE

aws apigateway put-integration \
  --rest-api-id "$API_ID" --resource-id "$ROOT_ID" \
  --http-method GET \
  --type AWS \
  --integration-http-method GET \
  --uri "arn:aws:apigateway:${AWS_DEFAULT_REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations"

aws apigateway put-integration-response \
  --rest-api-id "$API_ID" --resource-id "$ROOT_ID" \
  --http-method GET --status-code 200

aws apigateway create-deployment --rest-api-id "$API_ID" --stage-name Prod
API_URL="https://${API_ID}.execute-api.${AWS_DEFAULT_REGION}.amazonaws.com/Prod"
```

模板把 `AWS::Lambda::Permission` 註解掉了。沒有下面這條，stage URL 會 500。範例同樣不加：

```bash
# 模板沒有。要通的話才加：
# aws lambda add-permission \
#   --function-name unicorn-apigw-fn \
#   --statement-id apigw \
#   --action lambda:InvokeFunction \
#   --principal apigateway.amazonaws.com \
#   --source-arn "arn:aws:execute-api:${AWS_DEFAULT_REGION}:${ACCOUNT_ID}:${API_ID}/*/*/"
```

`--integration-http-method GET` 是照模板。Lambda 的 invoke API 慣例是 POST。

---

## 5. Bastion

對應：`Ec2KeyPair`、`BastionSg`、`Ec2Instance`。

`run-instances --user-data file://` 吃的是**純文字**。CLI 會自己 base64。不要先 `base64` 再傳，否則機器裡的腳本是亂碼。

```bash
aws ec2 create-key-pair --key-name gameday-key \
  --query KeyMaterial --output text > gameday-key.pem
chmod 400 gameday-key.pem
```

`KeyMaterial` 只回傳這一次。重導向到檔案，不要印到終端機紀錄。

```bash
BASTION_SG="$(aws ec2 create-security-group \
  --group-name Unicorn-bastion --description "SG to test ping" \
  --vpc-id "$VPC_ID" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress \
  --group-id "$BASTION_SG" --protocol tcp --port 22 --cidr 119.237.240.242/32

cat > /tmp/unicorn-cli/bastion-userdata.sh <<'EOF'
#!/bin/bash
yum update -y
cd /root
aws ssm get-parameter --name /ec2/keypair/key-0067cec476023d650 \
  --with-decryption --query Parameter.Value --output text > gameday-key.pem
chmod 400 ./gameday-key.pem
EOF

BASTION_ID="$(aws ec2 run-instances \
  --image-id ami-0b72821e2f351e396 \
  --instance-type t3.micro \
  --key-name gameday-key \
  --iam-instance-profile Name=WSEC2Role \
  --user-data file:///tmp/unicorn-cli/bastion-userdata.sh \
  --network-interfaces "AssociatePublicIpAddress=true,DeviceIndex=0,Groups=${BASTION_SG},SubnetId=${PUBLIC_SUBNET1}" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bastion}]' \
  --query 'Instances[0].InstanceId' --output text)"
```

`--network-interfaces` 用 shorthand：逗號分隔欄位，沒有空格。有空格會被 shell 拆成下一個參數。

SSH 只放行模板裡的 `119.237.240.242/32`。UserData 去 SSM 拉的那把 key，不是剛才 `create-key-pair` 建的。參數不存在時機器還是會起來，只是 userdata 失敗。

`--tag-specifications` 的 JSON 用單引號，避免 shell 吃掉 `[]`。

---

## 6. ALB

對應：`ELBSecurityGroup`、`ApplicationLoadBalancer`、`EC2TargetGroup`、`ALBListener`。

子命令是 `aws elbv2`，不是 `aws elb`（那是 Classic Load Balancer）。

```bash
ELB_SG="$(aws ec2 create-security-group \
  --group-name Unicorn-elb --description "ELB Security Group" \
  --vpc-id "$VPC_ID" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress \
  --group-id "$ELB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0

ALB_ARN="$(aws elbv2 create-load-balancer \
  --name Unicorn-alb \
  --scheme internet-facing \
  --subnets "$PUBLIC_SUBNET1" "$PUBLIC_SUBNET2" \
  --security-groups "$ELB_SG" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)"

TG_ARN="$(aws elbv2 create-target-group \
  --name EC2TargetGroup \
  --protocol HTTP --port 80 --vpc-id "$VPC_ID" \
  --health-check-protocol HTTP \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 15 \
  --healthy-threshold-count 5 \
  --unhealthy-threshold-count 3 \
  --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"

aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=20

aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions "Type=forward,TargetGroupArn=${TG_ARN}"

aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
ALB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)"
```

CloudFront 的 origin 要用這個 `DNSName`，不是 ARN。建立當下 DNS 可能還沒填好，所以先 `wait` 再 `describe`。

`--default-actions` 是 shorthand。值裡有逗號時不要加空格。Target group 名稱在同一區域必須唯一。

---

## 7. CloudFront

對應：`MyCustomCachePolicy`、`cloudfrontdistribution`。

這裡不要用 shorthand。`Quantity` / `Items` 嵌太深，命令列會寫錯。寫 JSON，用 `file://`。

`cache-policy.json`：

```json
{
  "Name": "MyCustomCachePolicyForSpecificQueryString",
  "Comment": "Cache policy that includes the specific query string parameter",
  "DefaultTTL": 86400,
  "MaxTTL": 31536000,
  "MinTTL": 1,
  "ParametersInCacheKeyAndForwardedToOrigin": {
    "CookiesConfig": {"CookieBehavior": "none"},
    "EnableAcceptEncodingGzip": true,
    "EnableAcceptEncodingBrotli": true,
    "HeadersConfig": {"HeaderBehavior": "none"},
    "QueryStringsConfig": {
      "QueryStringBehavior": "whitelist",
      "QueryStrings": {
        "Quantity": 1,
        "Items": ["input-SUNhbkhhelVuaWNvem40LTY3NDkSY"]
      }
    }
  }
}
```

`QueryStrings` 必須是 `{"Quantity":1,"Items":[...]}`，不能是 JSON array。這和 CloudFormation YAML 的寫法不一樣。

```bash
CACHE_POLICY_ID="$(aws cloudfront create-cache-policy \
  --cache-policy-config file://cache-policy.json \
  --query 'CachePolicy.Id' --output text)"
```

`distribution.json` 的 origin 用上一段的 `$ALB_DNS`。即使 `http-only`，`OriginSslProtocols` 仍是必填，否則 `create-distribution` 會拒。

```json
{
  "CallerReference": "unicorn-1",
  "Enabled": true,
  "Comment": "Unicorn ALB origin",
  "Origins": {
    "Quantity": 1,
    "Items": [{
      "Id": "ALB",
      "DomainName": "Unicorn-alb-xxxx.us-east-1.elb.amazonaws.com",
      "CustomOriginConfig": {
        "HTTPPort": 80,
        "HTTPSPort": 443,
        "OriginProtocolPolicy": "http-only",
        "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}
      }
    }]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "ALB",
    "ViewerProtocolPolicy": "allow-all",
    "CachePolicyId": "替換成上一步的 ID"
  }
}
```

```bash
aws cloudfront create-distribution \
  --distribution-config file://distribution.json \
  --query 'Distribution.DomainName' --output text
```

`CallerReference` 是冪等鍵。同一個值再呼叫會回傳同一筆 distribution，不會更新 origin。重試時要換。

有 `CachePolicyId` 就不要再傳 `ForwardedValues`。兩個一起送會被拒。

Cache policy 名稱是帳號全域唯一。模板用的那個名字若已存在，要換名或先刪。

---

## 8. Launch Template 與 ASG

對應：`ApplicationSg`、`applicationLaunchTemplate`、`applicationAsg`。

和第 5 節的差別：`run-instances --user-data file://` 會幫你 base64。Launch Template 的 JSON 欄位 `UserData` **不會**。要自己編碼，而且不能含換行。

```bash
APP_SG="$(aws ec2 create-security-group \
  --group-name Unicorn-app --description "applciation" \
  --vpc-id "$VPC_ID" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$APP_SG" \
  --protocol tcp --port 80 --cidr 10.0.0.0/16

cat > /tmp/unicorn-cli/app-userdata.sh <<EOF
#!/bin/bash
yum update -y
cd /root
aws s3 cp s3://${BUCKET}/ws-ec2-pipeline-server .
wget https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
chmod 700 ./ws-ec2-pipeline-server
./ws-ec2-pipeline-server
EOF
USER_DATA_B64="$(base64 < /tmp/unicorn-cli/app-userdata.sh | tr -d '\n')"
```

macOS 的 `base64` 預設會換行。`tr -d '\n'` 不能省，否則 Launch Template 拒絕。

`lt.json` 的 `UserData` 填 `$USER_DATA_B64`，`IamInstanceProfile` 用 ARN 不是 Name：

```bash
aws ec2 create-launch-template \
  --launch-template-name applicationLaunchTemplate \
  --launch-template-data file://lt.json

LT_ID="$(aws ec2 describe-launch-templates \
  --launch-template-names applicationLaunchTemplate \
  --query 'LaunchTemplates[0].LaunchTemplateId' --output text)"
LT_VERSION="$(aws ec2 describe-launch-templates \
  --launch-template-ids "$LT_ID" \
  --query 'LaunchTemplates[0].LatestVersionNumber' --output text)"

aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name applicationAsg \
  --launch-template "LaunchTemplateId=${LT_ID},Version=${LT_VERSION}" \
  --min-size 1 --max-size 5 \
  --vpc-zone-identifier "${PRIVATE_SUBNET1},${PRIVATE_SUBNET2}" \
  --target-group-arns "$TG_ARN" \
  --enabled-metrics GroupMinSize GroupMaxSize \
  --metrics-granularity 1Minute
```

`--vpc-zone-identifier` 是逗號分隔的字串，不是重複旗標。`--launch-template` 的 `Version` 是字串，數字也行，但不要加空格。

ASG 放在 private subnet。Launch Template 裡的 `AssociatePublicIpAddress: true` 在私網通常無效，出網靠第 1 節的 NAT。

沒有 target tracking。流量上來不會自動擴。和模板一樣。

CLI 不會上傳 binary。bucket 建好後：

```bash
aws s3 cp ../ws-ec2-pipeline-server "s3://${BUCKET}/ws-ec2-pipeline-server"
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name applicationAsg
```

---

## 9. DocumentDB 與 Secrets Manager

對應：`SecretsManagerVPCEndpoint`、`DatabaseSg`、`DocDBClusterRotationSecret`、`DocDBCluster`、`DocDBInstance`、`DBSubnetGroup`。

CloudFormation 用 `{{resolve:secretsmanager:...}}` 在部署時解析密碼。CLI 沒有這個語法。先建 secret，再 `get-secret-value`，把 username / password 傳給 `create-db-cluster`。

```bash
aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --vpc-endpoint-type Interface \
  --service-name "com.amazonaws.${AWS_DEFAULT_REGION}.secretsmanager" \
  --subnet-ids "$PRIVATE_SUBNET1" "$PRIVATE_SUBNET2" \
  --security-group-ids "$APP_SG" "$BASTION_SG" \
  --private-dns-enabled

DB_SG="$(aws ec2 create-security-group \
  --group-name Unicorn-docdb --description "SG to test ping" \
  --vpc-id "$VPC_ID" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress \
  --group-id "$DB_SG" --protocol tcp --port 27017 --cidr 10.0.0.0/16

SECRET_ARN="$(aws secretsmanager create-secret \
  --name DocDBClusterRotationSecret \
  --tags Key=AppName,Value=Unicorn \
  --generate-secret-string '{
    "SecretStringTemplate":"{\"username\":\"someadmin\",\"ssl\":true}",
    "GenerateStringKey":"password",
    "PasswordLength":16,
    "ExcludePunctuation":true
  }' \
  --query ARN --output text)"
```

`--generate-secret-string` 裡的 `SecretStringTemplate` 是「JSON 裡的 JSON 字串」。外層單引號，內層 `\"`。寫錯時 secret 會建出來，但沒有 `username` 鍵，下一步才爆。

不要把密碼 echo 出來。用 `jq` 取欄位，立刻傳給下一個命令：

```bash
SECRET_JSON="$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" --query SecretString --output text)"
DOCDB_USER="$(printf '%s' "$SECRET_JSON" | jq -r .username)"
DOCDB_PASS="$(printf '%s' "$SECRET_JSON" | jq -r .password)"

aws docdb create-db-subnet-group \
  --db-subnet-group-name unicorn-private-subnet \
  --db-subnet-group-description private-subnet \
  --subnet-ids "$PRIVATE_SUBNET1" "$PRIVATE_SUBNET2"

aws docdb create-db-cluster \
  --db-cluster-identifier unicorn-docdb \
  --engine docdb \
  --master-username "$DOCDB_USER" \
  --master-user-password "$DOCDB_PASS" \
  --db-subnet-group-name unicorn-private-subnet \
  --vpc-security-group-ids "$DB_SG"

aws docdb create-db-instance \
  --db-instance-identifier unicorn-docdb-1 \
  --db-instance-class db.t3.medium \
  --engine docdb \
  --db-cluster-identifier unicorn-docdb

aws docdb wait db-instance-available --db-instance-identifier unicorn-docdb-1
DOCDB_ENDPOINT="$(aws docdb describe-db-clusters \
  --db-cluster-identifier unicorn-docdb \
  --query 'DBClusters[0].Endpoint' --output text)"
```

等的是 **instance** waiter，不是 cluster。Cluster 先 available 時，endpoint 還不能連。

模板的 `SecretTargetAttachment` 會把 host 寫回 secret。DocumentDB 這條支援不完整，所以等完之後自己合併再 `put-secret-value`。用檔案，不要把含密碼的 JSON 寫進 shell history：

```bash
printf '%s' "$SECRET_JSON" | jq --arg host "$DOCDB_ENDPOINT" \
  '. + {host: $host, port: 27017, engine: "mongo"}' > /tmp/unicorn-cli/secret.json
aws secretsmanager put-secret-value \
  --secret-id "$SECRET_ARN" \
  --secret-string file:///tmp/unicorn-cli/secret.json
rm -f /tmp/unicorn-cli/secret.json
unset DOCDB_PASS SECRET_JSON
```

沒設加密、備份天數、deletion protection、第二個 instance。和模板一樣。

---

## 10. AppConfig

對應：`Application` → `ProdEnvironment` → `ConfigurationProfile` → `HostedConfigurationVersion` → `DeploymentStrategy` → `appConfigDeployment`。

六條命令，下一條的 ID 來自上一條的 `--query`。順序不能換。

```bash
APPCONFIG_APP="$(aws appconfig create-application \
  --name Unicorn --description "Unicorn application." \
  --tags Env=Production --query Id --output text)"

APPCONFIG_ENV="$(aws appconfig create-environment \
  --application-id "$APPCONFIG_APP" \
  --name Production --description "Production environment" \
  --tags Env=Production --query Id --output text)"

APPCONFIG_PROFILE="$(aws appconfig create-configuration-profile \
  --application-id "$APPCONFIG_APP" \
  --name Unicorn \
  --description "My test configuration profile" \
  --location-uri hosted \
  --tags Env=Production --query Id --output text)"
```

`--location-uri hosted` 才能接著 `create-hosted-configuration-version`。寫成 S3 URI 就不是這條路徑。

設定檔用這次的 secret ARN 和 API URL，不要貼模板裡舊的 `ihowe95td3`。鍵名 `DBSeretARN` 保留，應用可能照這個錯字讀。

```bash
jq -n \
  --arg secret "$SECRET_ARN" \
  --arg bucket "$BUCKET" \
  --arg api "$API_URL" \
  '{
    DBSeretARN: $secret,
    MongoDbDatabase: "unicorndb",
    MongoDbCollection: "unicorncollection",
    MongoDbCAFilePath: "./global-bundle.pem",
    Port: 80,
    Bucket: $bucket,
    ApiGatewayUrl: $api
  }' > /tmp/unicorn-cli/appconfig.json

APPCONFIG_VER="$(aws appconfig create-hosted-configuration-version \
  --application-id "$APPCONFIG_APP" \
  --configuration-profile-id "$APPCONFIG_PROFILE" \
  --description " configuration prod value" \
  --content-type application/json \
  --content fileb:///tmp/unicorn-cli/appconfig.json \
  --query VersionNumber --output text)"
```

這裡是 `fileb://`，不是 `file://`。Content 走二進位參數。

```bash
APPCONFIG_STRATEGY="$(aws appconfig create-deployment-strategy \
  --name "Unicorn DeploymentStrategy" \
  --description "deployment strategy." \
  --deployment-duration-in-minutes 0 \
  --final-bake-time-in-minutes 0 \
  --growth-factor 100 \
  --growth-type LINEAR \
  --replicate-to NONE \
  --tags Env=Production \
  --query Id --output text)"

aws appconfig start-deployment \
  --application-id "$APPCONFIG_APP" \
  --environment-id "$APPCONFIG_ENV" \
  --deployment-strategy-id "$APPCONFIG_STRATEGY" \
  --configuration-profile-id "$APPCONFIG_PROFILE" \
  --configuration-version "$APPCONFIG_VER" \
  --description "Unicorn deployment" \
  --tags Env=Production
```

`--growth-factor 100` 且 duration 0，等於立刻切到新版。`--configuration-version` 是字串；`--query VersionNumber` 印出來的數字可以直接代進去。

---

## 串起來

[`app.sh`](../app.sh) 就是上面 1→10，外加 `set -euo pipefail`。順序不能平行：

- ASG 要第 6 節的 target group
- VPC endpoint 要第 5、8 節的 security group
- AppConfig 要第 4 節的 API URL 和第 9 節的 secret ARN

CLI 和 SDK 對照：

| 你要做的事 | CLI | SDK |
|---|---|---|
| 取出 ID | `--query … --output text` | `resp["Vpc"]["VpcId"]` |
| 等 NAT / ALB / DocDB | `aws … wait` | `client.get_waiter(...).wait(...)` |
| 純文字 userdata | `--user-data file://` | `UserData=script`（`run_instances`） |
| Launch Template userdata | 自己 `base64 \| tr -d '\\n'` | `base64.b64encode(...).decode()` |
| 二進位上傳 | `fileb://` | `bytes` |
| 複雜 JSON | `file://` | Python dict |

名稱在區域內必須唯一，重跑前要刪掉或改名：S3 bucket、cache policy、launch template、ASG、secret、DocDB、target group。AMI `ami-0b72821e2f351e396` 是模板寫死的，換區域就失效。
