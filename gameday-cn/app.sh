#!/usr/bin/env bash
# Unicorn GameDay — AWS CLI equivalent of app.yml
# Region: us-east-1 (hard-coded in the original template ARNs / service names)
#
# Prerequisites the CloudFormation assumed already exist; this script creates
# them if missing:
#   IAM role MyLambdaExecutionRole
#   IAM role WSEC2Role + instance profile
#
# Upload the Go binary after the bucket exists:
#   aws s3 cp ws-ec2-pipeline-server "s3://${BUCKET}/ws-ec2-pipeline-server"
set -euo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_REGION="$AWS_DEFAULT_REGION"

# --- Parameters (same defaults as app.yml) ---------------------------------
ENV_NAME="${ENV_NAME:-Unicorn}"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
PUBLIC_SUBNET1_CIDR="${PUBLIC_SUBNET1_CIDR:-10.0.10.0/24}"
PUBLIC_SUBNET2_CIDR="${PUBLIC_SUBNET2_CIDR:-10.0.11.0/24}"
PRIVATE_SUBNET1_CIDR="${PRIVATE_SUBNET1_CIDR:-10.0.20.0/24}"
PRIVATE_SUBNET2_CIDR="${PRIVATE_SUBNET2_CIDR:-10.0.21.0/24}"
API_HTTP_METHOD="${API_HTTP_METHOD:-GET}"          # unused in CFN; kept for parity
AMI_ID="${AMI_ID:-ami-0b72821e2f351e396}"
KEY_NAME="${KEY_NAME:-gameday-key}"
LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME:-MyLambdaExecutionRole}"
EC2_ROLE_NAME="${EC2_ROLE_NAME:-WSEC2Role}"
BASTION_SSH_CIDR="${BASTION_SSH_CIDR:-119.237.240.242/32}"
CACHE_QUERY_STRING="${CACHE_QUERY_STRING:-input-SUNhbkhhelVuaWNvem40LTY3NDkSY}"
DOCDB_INSTANCE_CLASS="${DOCDB_INSTANCE_CLASS:-db.t3.medium}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${BUCKET:-gameday-${ACCOUNT_ID}}"
AZ1="$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)"
AZ2="$(aws ec2 describe-availability-zones --query 'AvailabilityZones[1].ZoneName' --output text)"
WORKDIR="$(mktemp -d /tmp/unicorn-cli.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

role_exists() { aws iam get-role --role-name "$1" >/dev/null 2>&1; }
profile_exists() { aws iam get-instance-profile --instance-profile-name "$1" >/dev/null 2>&1; }

echo "==> account=$ACCOUNT_ID region=$AWS_REGION az=$AZ1,$AZ2 bucket=$BUCKET"

# --- IAM the CFN referenced but did not create ------------------------------
if ! role_exists "$LAMBDA_ROLE_NAME"; then
  echo "==> create IAM role $LAMBDA_ROLE_NAME"
  aws iam create-role --role-name "$LAMBDA_ROLE_NAME" --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }' >/dev/null
  aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess
fi
LAMBDA_ROLE_ARN="$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query 'Role.Arn' --output text)"

if ! role_exists "$EC2_ROLE_NAME"; then
  echo "==> create IAM role $EC2_ROLE_NAME"
  aws iam create-role --role-name "$EC2_ROLE_NAME" --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }' >/dev/null
  aws iam attach-role-policy --role-name "$EC2_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam put-role-policy --role-name "$EC2_ROLE_NAME" --policy-name unicorn-ec2 --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::${BUCKET}\",\"arn:aws:s3:::${BUCKET}/*\"]},
      {\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\",\"ssm:GetParameter\"],\"Resource\":\"*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"appconfig:StartConfigurationSession\",\"appconfig:GetLatestConfiguration\",\"appconfig:GetConfiguration\"],\"Resource\":\"*\"}
    ]
  }"
fi

INSTANCE_PROFILE_NAME="${EC2_ROLE_NAME}"
if ! profile_exists "$INSTANCE_PROFILE_NAME"; then
  echo "==> create instance profile $INSTANCE_PROFILE_NAME"
  aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --path / >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$EC2_ROLE_NAME"
  echo "    waiting for instance profile propagation"
  sleep 10
fi
INSTANCE_PROFILE_ARN="$(aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --query 'InstanceProfile.Arn' --output text)"

# --- NETWORK ----------------------------------------------------------------
echo "==> VPC"
VPC_ID="$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --query 'Vpc.VpcId' --output text)"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
aws ec2 create-tags --resources "$VPC_ID" --tags "Key=Name,Value=${ENV_NAME}"

echo "==> Internet Gateway"
IGW_ID="$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)"
aws ec2 create-tags --resources "$IGW_ID" --tags "Key=Name,Value=${ENV_NAME}"
aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"

echo "==> Subnets"
PUBLIC_SUBNET1="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PUBLIC_SUBNET1_CIDR" --availability-zone "$AZ1" --query 'Subnet.SubnetId' --output text)"
PUBLIC_SUBNET2="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PUBLIC_SUBNET2_CIDR" --availability-zone "$AZ2" --query 'Subnet.SubnetId' --output text)"
PRIVATE_SUBNET1="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRIVATE_SUBNET1_CIDR" --availability-zone "$AZ1" --query 'Subnet.SubnetId' --output text)"
PRIVATE_SUBNET2="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRIVATE_SUBNET2_CIDR" --availability-zone "$AZ2" --query 'Subnet.SubnetId' --output text)"
aws ec2 modify-subnet-attribute --subnet-id "$PUBLIC_SUBNET1" --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id "$PUBLIC_SUBNET2" --map-public-ip-on-launch
aws ec2 create-tags --resources "$PUBLIC_SUBNET1" --tags "Key=Name,Value=${ENV_NAME} Public Subnet (AZ1)"
aws ec2 create-tags --resources "$PUBLIC_SUBNET2" --tags "Key=Name,Value=${ENV_NAME} Public Subnet (AZ2)"
aws ec2 create-tags --resources "$PRIVATE_SUBNET1" --tags "Key=Name,Value=${ENV_NAME} Private Subnet (AZ1)"
aws ec2 create-tags --resources "$PRIVATE_SUBNET2" --tags "Key=Name,Value=${ENV_NAME} Private Subnet (AZ2)"

echo "==> NAT Gateway (single, PublicSubnet1 — same as CFN)"
EIP_ALLOC="$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)"
NAT_GW_ID="$(aws ec2 create-nat-gateway --subnet-id "$PUBLIC_SUBNET1" --allocation-id "$EIP_ALLOC" --query 'NatGateway.NatGatewayId' --output text)"

echo "==> Route tables"
PUBLIC_RT="$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)"
PRIVATE_RT="$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)"
aws ec2 create-tags --resources "$PUBLIC_RT" --tags "Key=Name,Value=${ENV_NAME} Public Routes"
aws ec2 create-tags --resources "$PRIVATE_RT" --tags "Key=Name,Value=${ENV_NAME} Private Routes (AZ1)"
aws ec2 create-route --route-table-id "$PUBLIC_RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
aws ec2 associate-route-table --route-table-id "$PUBLIC_RT" --subnet-id "$PUBLIC_SUBNET1" >/dev/null
aws ec2 associate-route-table --route-table-id "$PUBLIC_RT" --subnet-id "$PUBLIC_SUBNET2" >/dev/null
aws ec2 associate-route-table --route-table-id "$PRIVATE_RT" --subnet-id "$PRIVATE_SUBNET1" >/dev/null
aws ec2 associate-route-table --route-table-id "$PRIVATE_RT" --subnet-id "$PRIVATE_SUBNET2" >/dev/null

echo "    waiting for NAT Gateway"
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID"
aws ec2 create-route --route-table-id "$PRIVATE_RT" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_GW_ID" >/dev/null

# --- S3 + VPC Flow Logs -----------------------------------------------------
echo "==> S3 bucket $BUCKET"
if [[ "$AWS_REGION" == "us-east-1" ]]; then
  aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" >/dev/null
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
fi
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration '{
  "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]
}'
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "==> VPC Flow Logs → s3://$BUCKET (parquet / hive / hourly)"
aws ec2 create-flow-logs \
  --resource-type VPC \
  --resource-ids "$VPC_ID" \
  --traffic-type ALL \
  --log-destination-type s3 \
  --log-destination "arn:aws:s3:::${BUCKET}" \
  --log-format '${version} ${vpc-id} ${subnet-id} ${instance-id} ${srcaddr} ${dstaddr} ${srcport} ${dstport} ${protocol} ${tcp-flags} ${type} ${pkt-srcaddr} ${pkt-dstaddr}' \
  --max-aggregation-interval 60 \
  --destination-options FileFormat=parquet,HiveCompatiblePartitions=true,PerHourPartition=true >/dev/null

# --- API Gateway & Lambda ---------------------------------------------------
echo "==> Lambda"
cat > "$WORKDIR/index.js" <<EOF
exports.handler = async function(event) {
  return {"account_id": "${ACCOUNT_ID}"};
};
EOF
( cd "$WORKDIR" && zip -q function.zip index.js )
LAMBDA_NAME="unicorn-apigw-fn"
aws lambda create-function \
  --function-name "$LAMBDA_NAME" \
  --runtime nodejs18.x \
  --handler index.handler \
  --timeout 5 \
  --tracing-config Mode=Active \
  --role "$LAMBDA_ROLE_ARN" \
  --zip-file "fileb://${WORKDIR}/function.zip" >/dev/null
LAMBDA_ARN="$(aws lambda get-function --function-name "$LAMBDA_NAME" --query 'Configuration.FunctionArn' --output text)"

echo "==> API Gateway REST (REGIONAL) unicorn-apigw"
API_ID="$(aws apigateway create-rest-api \
  --name unicorn-apigw \
  --description unicorn-apigw \
  --endpoint-configuration types=REGIONAL \
  --query id --output text)"
ROOT_ID="$(aws apigateway get-resources --rest-api-id "$API_ID" --query 'items[0].id' --output text)"
aws apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$ROOT_ID" \
  --http-method GET \
  --authorization-type NONE >/dev/null
aws apigateway put-method-response \
  --rest-api-id "$API_ID" \
  --resource-id "$ROOT_ID" \
  --http-method GET \
  --status-code 200 \
  --response-models '{"application/json":"Empty"}' >/dev/null
# CFN used IntegrationHttpMethod GET (Lambda invoke is normally POST). Kept as-is.
aws apigateway put-integration \
  --rest-api-id "$API_ID" \
  --resource-id "$ROOT_ID" \
  --http-method GET \
  --type AWS \
  --integration-http-method GET \
  --uri "arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations" >/dev/null
aws apigateway put-integration-response \
  --rest-api-id "$API_ID" \
  --resource-id "$ROOT_ID" \
  --http-method GET \
  --status-code 200 >/dev/null
# CFN left AWS::Lambda::Permission commented out — same here.
aws apigateway create-deployment --rest-api-id "$API_ID" --stage-name Prod >/dev/null
API_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/Prod"

# --- EC2 key + bastion ------------------------------------------------------
echo "==> Key pair $KEY_NAME"
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  aws ec2 create-key-pair --key-name "$KEY_NAME" --query KeyMaterial --output text > "${KEY_NAME}.pem"
  chmod 400 "${KEY_NAME}.pem"
fi

echo "==> Bastion SG + instance"
BASTION_SG="$(aws ec2 create-security-group --group-name "${ENV_NAME}-bastion" --description "SG to test ping" --vpc-id "$VPC_ID" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$BASTION_SG" --protocol tcp --port 22 --cidr "$BASTION_SSH_CIDR" >/dev/null

cat > "$WORKDIR/bastion-userdata.sh" <<'UD'
#!/bin/bash
yum update -y
cd /root
aws ssm get-parameter --name /ec2/keypair/key-0067cec476023d650 --with-decryption --query Parameter.Value --output text > gameday-key.pem
chmod 400 ./gameday-key.pem
UD
BASTION_ID="$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name "$KEY_NAME" \
  --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
  --user-data "file://${WORKDIR}/bastion-userdata.sh" \
  --network-interfaces "AssociatePublicIpAddress=true,DeviceIndex=0,Groups=${BASTION_SG},SubnetId=${PUBLIC_SUBNET1}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=bastion}]" \
  --query 'Instances[0].InstanceId' --output text)"

# --- ALB --------------------------------------------------------------------
echo "==> ALB"
ELB_SG="$(aws ec2 create-security-group --group-name "${ENV_NAME}-elb" --description "ELB Security Group" --vpc-id "$VPC_ID" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$ELB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null

ALB_ARN="$(aws elbv2 create-load-balancer \
  --name "${ENV_NAME}-alb" \
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
  --attributes Key=deregistration_delay.timeout_seconds,Value=20 >/dev/null
aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" >/dev/null

echo "    waiting for ALB"
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
ALB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)"

# --- CloudFront -------------------------------------------------------------
echo "==> CloudFront cache policy + distribution"
python3 - "$CACHE_QUERY_STRING" > "$WORKDIR/cache-policy.json" <<'PY'
import json, sys
qs = sys.argv[1]
json.dump({
  "Name": "MyCustomCachePolicyForSpecificQueryString",
  "Comment": "Cache policy that includes the specific query string parameter",
  "DefaultTTL": 86400,
  "MaxTTL": 31536000,
  "MinTTL": 1,
  "ParametersInCacheKeyAndForwardedToOrigin": {
    "CookiesConfig": {"CookieBehavior": "none"},
    "EnableAcceptEncodingGzip": True,
    "EnableAcceptEncodingBrotli": True,
    "HeadersConfig": {"HeaderBehavior": "none"},
    "QueryStringsConfig": {"QueryStringBehavior": "whitelist", "QueryStrings": [qs]}
  }
}, sys.stdout)
PY
CACHE_POLICY_ID="$(aws cloudfront create-cache-policy --cache-policy-config "file://${WORKDIR}/cache-policy.json" --query 'CachePolicy.Id' --output text)"

python3 - "$ALB_DNS" "$CACHE_POLICY_ID" > "$WORKDIR/cf-dist.json" <<'PY'
import json, sys, time
alb, policy = sys.argv[1], sys.argv[2]
json.dump({
  "CallerReference": str(int(time.time())),
  "Enabled": True,
  "Comment": "Unicorn ALB origin",
  "Origins": {"Quantity": 1, "Items": [{
    "Id": "ALB",
    "DomainName": alb,
    "CustomOriginConfig": {
      "HTTPPort": 80,
      "HTTPSPort": 443,
      "OriginProtocolPolicy": "http-only"
    }
  }]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "ALB",
    "ViewerProtocolPolicy": "allow-all",
    "CachePolicyId": policy
  }
}, sys.stdout)
PY
CF_DOMAIN="$(aws cloudfront create-distribution --distribution-config "file://${WORKDIR}/cf-dist.json" --query 'Distribution.DomainName' --output text)"

# --- Application SG / Launch Template / ASG ---------------------------------
echo "==> Application SG + Launch Template + ASG"
APP_SG="$(aws ec2 create-security-group --group-name "${ENV_NAME}-app" --description "applciation" --vpc-id "$VPC_ID" --query GroupId --output text)"
for port in 80 22 443; do
  aws ec2 authorize-security-group-ingress --group-id "$APP_SG" --protocol tcp --port "$port" --cidr "$VPC_CIDR" >/dev/null
done

cat > "$WORKDIR/app-userdata.sh" <<UD
#!/bin/bash
yum update -y
cd /root
aws s3 cp s3://${BUCKET}/ws-ec2-pipeline-server .
wget https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
sudo chmod 700 ./ws-ec2-pipeline-server
sudo ./ws-ec2-pipeline-server
UD
APP_UD="$(base64 < "$WORKDIR/app-userdata.sh" | tr -d '\n')"

python3 - "$AMI_ID" "$KEY_NAME" "$INSTANCE_PROFILE_ARN" "$APP_SG" "$APP_UD" > "$WORKDIR/lt.json" <<'PY'
import json, sys
ami, key, profile, sg, ud = sys.argv[1:]
json.dump({
  "ImageId": ami,
  "InstanceType": "t3.micro",
  "KeyName": key,
  "IamInstanceProfile": {"Arn": profile},
  "UserData": ud,
  "TagSpecifications": [{"ResourceType": "instance", "Tags": [{"Key": "Name", "Value": "Application"}]}],
  "NetworkInterfaces": [{
    "AssociatePublicIpAddress": True,
    "DeviceIndex": 0,
    "Groups": [sg]
  }]
}, sys.stdout)
PY
LT_ID="$(aws ec2 create-launch-template \
  --launch-template-name applicationLaunchTemplate \
  --launch-template-data "file://${WORKDIR}/lt.json" \
  --query 'LaunchTemplate.LaunchTemplateId' --output text)"
LT_VERSION="$(aws ec2 describe-launch-templates --launch-template-ids "$LT_ID" --query 'LaunchTemplates[0].LatestVersionNumber' --output text)"

aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name applicationAsg \
  --launch-template "LaunchTemplateId=${LT_ID},Version=${LT_VERSION}" \
  --min-size 1 --max-size 5 \
  --vpc-zone-identifier "${PRIVATE_SUBNET1},${PRIVATE_SUBNET2}" \
  --target-group-arns "$TG_ARN" \
  --enabled-metrics GroupMinSize GroupMaxSize \
  --metrics-granularity 1Minute

# --- DocumentDB + Secrets Manager ------------------------------------------
echo "==> Secrets Manager VPC endpoint"
aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --vpc-endpoint-type Interface \
  --service-name "com.amazonaws.${AWS_REGION}.secretsmanager" \
  --subnet-ids "$PRIVATE_SUBNET1" "$PRIVATE_SUBNET2" \
  --security-group-ids "$APP_SG" "$BASTION_SG" \
  --private-dns-enabled >/dev/null

echo "==> Database SG + secret + DocDB"
DB_SG="$(aws ec2 create-security-group --group-name "${ENV_NAME}-docdb" --description "SG to test ping" --vpc-id "$VPC_ID" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$DB_SG" --protocol tcp --port 27017 --cidr "$VPC_CIDR" >/dev/null

SECRET_ARN="$(aws secretsmanager create-secret \
  --name DocDBClusterRotationSecret \
  --tags Key=AppName,Value=Unicorn \
  --generate-secret-string '{
    "SecretStringTemplate":"{\"username\":\"someadmin\",\"ssl\":true}",
    "GenerateStringKey":"password",
    "PasswordLength":16,
    "ExcludePunctuation":true
  }' --query ARN --output text)"
SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text)"
DOCDB_USER="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["username"])' "$SECRET_JSON")"
DOCDB_PASS="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["password"])' "$SECRET_JSON")"

aws docdb create-db-subnet-group \
  --db-subnet-group-name unicorn-private-subnet \
  --db-subnet-group-description private-subnet \
  --subnet-ids "$PRIVATE_SUBNET1" "$PRIVATE_SUBNET2" >/dev/null

aws docdb create-db-cluster \
  --db-cluster-identifier unicorn-docdb \
  --engine docdb \
  --master-username "$DOCDB_USER" \
  --master-user-password "$DOCDB_PASS" \
  --db-subnet-group-name unicorn-private-subnet \
  --vpc-security-group-ids "$DB_SG" >/dev/null

aws docdb create-db-instance \
  --db-instance-identifier unicorn-docdb-1 \
  --db-instance-class "$DOCDB_INSTANCE_CLASS" \
  --engine docdb \
  --db-cluster-identifier unicorn-docdb >/dev/null

echo "    waiting for DocumentDB instance (several minutes)"
aws docdb wait db-instance-available --db-instance-identifier unicorn-docdb-1
DOCDB_ENDPOINT="$(aws docdb describe-db-clusters --db-cluster-identifier unicorn-docdb --query 'DBClusters[0].Endpoint' --output text)"

# SecretTargetAttachment equivalent: merge host/port into the secret
python3 - "$SECRET_JSON" "$DOCDB_ENDPOINT" > "$WORKDIR/secret-merged.json" <<'PY'
import json, sys
body = json.loads(sys.argv[1])
body.update({"host": sys.argv[2], "port": 27017, "engine": "mongo"})
json.dump(body, sys.stdout)
PY
aws secretsmanager put-secret-value --secret-id "$SECRET_ARN" --secret-string "file://${WORKDIR}/secret-merged.json" >/dev/null

# --- AppConfig --------------------------------------------------------------
echo "==> AppConfig"
APPCONFIG_APP="$(aws appconfig create-application --name Unicorn --description "Unicorn application." --tags Env=Production --query Id --output text)"
APPCONFIG_ENV="$(aws appconfig create-environment --application-id "$APPCONFIG_APP" --name Production --description "Production environment" --tags Env=Production --query Id --output text)"
APPCONFIG_PROFILE="$(aws appconfig create-configuration-profile --application-id "$APPCONFIG_APP" --name Unicorn --description "My test configuration profile" --location-uri hosted --tags Env=Production --query Id --output text)"

python3 - "$SECRET_ARN" "$BUCKET" "$API_URL" > "$WORKDIR/appconfig.json" <<'PY'
import json, sys
json.dump({
  "DBSeretARN": sys.argv[1],
  "MongoDbDatabase": "unicorndb",
  "MongoDbCollection": "unicorncollection",
  "MongoDbCAFilePath": "./global-bundle.pem",
  "Port": 80,
  "Bucket": sys.argv[2],
  "ApiGatewayUrl": sys.argv[3]
}, sys.stdout)
PY
APPCONFIG_VER="$(aws appconfig create-hosted-configuration-version \
  --application-id "$APPCONFIG_APP" \
  --configuration-profile-id "$APPCONFIG_PROFILE" \
  --description " configuration prod value" \
  --content-type application/json \
  --content "fileb://${WORKDIR}/appconfig.json" \
  --query VersionNumber --output text)"

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
  --tags Env=Production >/dev/null

# --- Outputs (same as app.yml) ----------------------------------------------
cat <<EOF

======== Outputs ========
VPC              $VPC_ID
PublicSubnet1    $PUBLIC_SUBNET1
PublicSubnet2    $PUBLIC_SUBNET2
PrivateSubnet1   $PRIVATE_SUBNET1
PrivateSubnet2   $PRIVATE_SUBNET2
S3Bucket         $BUCKET
LambdaFunction   $LAMBDA_NAME
SecretManager    $SECRET_ARN

ALB_DNS          $ALB_DNS
CloudFront       $CF_DOMAIN
ApiGatewayUrl    $API_URL
DocDBEndpoint    $DOCDB_ENDPOINT
Bastion          $BASTION_ID
=========================

Next:
  aws s3 cp ws-ec2-pipeline-server s3://${BUCKET}/ws-ec2-pipeline-server
  # then recycle ASG instances so userdata can fetch the binary
EOF
