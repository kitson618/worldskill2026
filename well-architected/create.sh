#!/usr/bin/env bash
# Windows PowerShell: use create.ps1 (this bash file will not run in powershell.exe).
#   Set-ExecutionPolicy -Scope Process Bypass
#   .\create.ps1
#   .\create.ps1 -Action destroy
#
# Well-Architected baseline, us-east-1, created from zero with the AWS CLI.
#
#   ./create.sh          # build
#   ./create.sh destroy  # tear down (CloudFront disable can take ~15 min)
#
# Layout
#   Internet
#     -> CloudFront (HTTPS redirect, TLS 1.2) + WAF managed rules
#       -> public ALB :80, security group limited to the CloudFront prefix list
#         -> ASG in private subnets (launch template, sample httpd userdata)
#   Bastion in a public subnet, SSH locked to your IP, SSM enabled
#   Isolated subnets have no route to the internet (place databases here later)
#   One NAT Gateway per AZ for the private subnets
#   One S3 bucket: ALB access logs + VPC flow logs
#
# Pillars this script actually implements
#   Security: IMDSv2, encrypted EBS, S3 block-public + TLS-only, least-privilege
#             instance roles, ALB not open to 0.0.0.0/0, origin header, WAF
#   Reliability: 2 AZs, NAT per AZ, ASG + ELB health checks, ALB deletion protection
#   Performance: CloudFront in front of the ALB, HTTP/2
#   Cost: t3.micro, PriceClass_100, 90-day log expiry, no Shield Advanced
#   Operations: tags, flow logs, ALB access logs, 5xx alarm, state file for destroy
#
# Billable: 2 NAT Gateways, ALB, CloudFront, WAF, bastion, one app instance.
# Does not deploy. Review, export AWS credentials, then run it yourself.
set -euo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION=us-east-1
export AWS_REGION=us-east-1

ROOT="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="${STATE_FILE:-$ROOT/wa-state.env}"
NAME="${NAME:-wa}"
VPC_CIDR="10.0.0.0/16"
# public / private / isolated, two AZs. Isolated has no default route.
PUBLIC_CIDRS=(10.0.0.0/24 10.0.1.0/24)
PRIVATE_CIDRS=(10.0.10.0/24 10.0.11.0/24)
ISOLATED_CIDRS=(10.0.20.0/24 10.0.21.0/24)
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
BASTION_SSH_CIDR="${BASTION_SSH_CIDR:-}"
WORKDIR=""

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

state_set() { printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"; }

cleanup_tmp() { [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap 'echo "failed at line $LINENO" >&2; cleanup_tmp' ERR
trap cleanup_tmp EXIT

new_workdir() {
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/wa-cli.XXXXXX")"
}

require_region() {
  local configured
  configured="$(aws configure get region || true)"
  if [[ -n "$configured" && "$configured" != "us-east-1" ]]; then
    log "ignoring configured region $configured; this stack is us-east-1"
  fi
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

build() {
  need aws
  need python3
  need curl
  need openssl
  require_region
  [[ ! -f "$STATE_FILE" ]] || die "state file already exists ($STATE_FILE). Run: $0 destroy"
  new_workdir
  : > "$STATE_FILE"
  chmod 600 "$STATE_FILE"

  local account az1 az2
  account="$(aws sts get-caller-identity --query Account --output text)"
  az1="$(aws ec2 describe-availability-zones --filters Name=state,Values=available --query 'AvailabilityZones[0].ZoneName' --output text)"
  az2="$(aws ec2 describe-availability-zones --filters Name=state,Values=available --query 'AvailabilityZones[1].ZoneName' --output text)"
  [[ -n "$az1" && -n "$az2" && "$az1" != "$az2" ]] || die "need two availability zones"
  state_set ACCOUNT_ID "$account"
  state_set AZ1 "$az1"
  state_set AZ2 "$az2"
  log "account=$account region=us-east-1 az=$az1,$az2"

  if [[ -z "$BASTION_SSH_CIDR" ]]; then
    BASTION_SSH_CIDR="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32"
  fi
  [[ "$BASTION_SSH_CIDR" == */* ]] || die "BASTION_SSH_CIDR must be a CIDR, got: $BASTION_SSH_CIDR"
  state_set BASTION_SSH_CIDR "$BASTION_SSH_CIDR"
  log "bastion SSH restricted to $BASTION_SSH_CIDR"

  build_bucket "$account"
  build_network "$az1" "$az2"
  build_flow_logs
  build_iam
  build_security_groups
  build_bastion "$az1"
  build_alb
  build_launch_template
  build_asg
  build_waf
  build_cloudfront
  build_alarm

  # shellcheck disable=SC1090
  source "$STATE_FILE"
  cat <<EOF

Stack created. CloudFront stays InProgress for several minutes; the URL 200s after it deploys.
App instances need ~3 minutes for userdata (httpd) before the target group goes healthy.

CloudFront     https://${CF_DOMAIN}/
ALB (direct)   http://${ALB_DNS}/   expected 403 without the origin header
Bastion        ${BASTION_PUBLIC_IP}   ssh -i ${ROOT}/${KEY_NAME}.pem ec2-user@${BASTION_PUBLIC_IP}
Bucket         ${BUCKET}
State          ${STATE_FILE}

Origin header (also in the state file):
  X-Origin-Verify: ${ORIGIN_SECRET}

Tear down:
  $0 destroy
EOF
}

build_bucket() {
  local account="$1"
  local bucket="${NAME}-logs-${account}-use1"
  log "S3 log bucket $bucket"
  aws s3api create-bucket --bucket "$bucket" --region us-east-1 >/dev/null
  aws s3api put-public-access-block --bucket "$bucket" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$bucket" --server-side-encryption-configuration '{
    "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]
  }'
  aws s3api put-bucket-ownership-controls --bucket "$bucket" --ownership-controls '{
    "Rules":[{"ObjectOwnership":"BucketOwnerEnforced"}]
  }'
  aws s3api put-bucket-lifecycle-configuration --bucket "$bucket" --lifecycle-configuration '{
    "Rules":[{
      "ID":"expire-logs-90d",
      "Status":"Enabled",
      "Filter":{"Prefix":""},
      "Expiration":{"Days":90},
      "NoncurrentVersionExpiration":{"NoncurrentDays":30},
      "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}
    }]
  }'
  # BucketOwnerEnforced: do not require s3:x-amz-acl. Log delivery uses HTTPS.
  python3 - "$bucket" "$account" > "$WORKDIR/bucket-policy.json" <<'PY'
import json, sys
bucket, account = sys.argv[1], sys.argv[2]
arn = f"arn:aws:s3:::{bucket}"
json.dump({
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [arn, f"{arn}/*"],
      "Condition": {"Bool": {"aws:SecureTransport": "false"}},
    },
    {
      "Sid": "FlowLogWrite",
      "Effect": "Allow",
      "Principal": {"Service": "delivery.logs.amazonaws.com"},
      "Action": "s3:PutObject",
      "Resource": f"{arn}/flow/AWSLogs/{account}/*",
      "Condition": {
        "StringEquals": {"aws:SourceAccount": account},
        "ArnLike": {"aws:SourceArn": f"arn:aws:logs:us-east-1:{account}:*"},
      },
    },
    {
      "Sid": "FlowLogAclCheck",
      "Effect": "Allow",
      "Principal": {"Service": "delivery.logs.amazonaws.com"},
      "Action": "s3:GetBucketAcl",
      "Resource": arn,
      "Condition": {
        "StringEquals": {"aws:SourceAccount": account},
        "ArnLike": {"aws:SourceArn": f"arn:aws:logs:us-east-1:{account}:*"},
      },
    },
    {
      "Sid": "AlbLogWrite",
      "Effect": "Allow",
      "Principal": {"Service": "logdelivery.elasticloadbalancing.amazonaws.com"},
      "Action": "s3:PutObject",
      "Resource": f"{arn}/alb/AWSLogs/{account}/*",
      "Condition": {"StringEquals": {"aws:SourceAccount": account}},
    },
    {
      "Sid": "AlbLogAclCheck",
      "Effect": "Allow",
      "Principal": {"Service": "logdelivery.elasticloadbalancing.amazonaws.com"},
      "Action": "s3:GetBucketAcl",
      "Resource": arn,
      "Condition": {"StringEquals": {"aws:SourceAccount": account}},
    },
  ],
}, sys.stdout)
PY
  aws s3api put-bucket-policy --bucket "$bucket" --policy "file://${WORKDIR}/bucket-policy.json"
  aws s3api put-bucket-tagging --bucket "$bucket" --tagging "TagSet=[{Key=Name,Value=${bucket}},{Key=Project,Value=${NAME}}]"
  state_set BUCKET "$bucket"
  BUCKET="$bucket"
}

build_network() {
  local az1="$1" az2="$2"
  log "VPC $VPC_CIDR"
  local vpc igw
  vpc="$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=${NAME}-vpc},{Key=Project,Value=${NAME}}]" \
    --query 'Vpc.VpcId' --output text)"
  aws ec2 modify-vpc-attribute --vpc-id "$vpc" --enable-dns-support
  aws ec2 modify-vpc-attribute --vpc-id "$vpc" --enable-dns-hostnames
  state_set VPC_ID "$vpc"
  VPC_ID="$vpc"

  igw="$(aws ec2 create-internet-gateway --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${NAME}-igw},{Key=Project,Value=${NAME}}]" \
    --query 'InternetGateway.InternetGatewayId' --output text)"
  aws ec2 attach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc"
  state_set IGW_ID "$igw"

  local i az cidr pub1 pub2 pri1 pri2 iso1 iso2
  pub1="$(make_subnet "$vpc" "${PUBLIC_CIDRS[0]}" "$az1" true "${NAME}-public-a")"
  pub2="$(make_subnet "$vpc" "${PUBLIC_CIDRS[1]}" "$az2" true "${NAME}-public-b")"
  pri1="$(make_subnet "$vpc" "${PRIVATE_CIDRS[0]}" "$az1" false "${NAME}-private-a")"
  pri2="$(make_subnet "$vpc" "${PRIVATE_CIDRS[1]}" "$az2" false "${NAME}-private-b")"
  iso1="$(make_subnet "$vpc" "${ISOLATED_CIDRS[0]}" "$az1" false "${NAME}-isolated-a")"
  iso2="$(make_subnet "$vpc" "${ISOLATED_CIDRS[1]}" "$az2" false "${NAME}-isolated-b")"
  state_set PUBLIC_SUBNET_1 "$pub1"
  state_set PUBLIC_SUBNET_2 "$pub2"
  state_set PRIVATE_SUBNET_1 "$pri1"
  state_set PRIVATE_SUBNET_2 "$pri2"
  state_set ISOLATED_SUBNET_1 "$iso1"
  state_set ISOLATED_SUBNET_2 "$iso2"
  PUBLIC_SUBNET_1="$pub1"
  PUBLIC_SUBNET_2="$pub2"
  PRIVATE_SUBNET_1="$pri1"
  PRIVATE_SUBNET_2="$pri2"

  local public_rt iso_rt pri_rt1 pri_rt2
  public_rt="$(make_rt "$vpc" "${NAME}-public-rt")"
  aws ec2 create-route --route-table-id "$public_rt" --destination-cidr-block 0.0.0.0/0 --gateway-id "$igw" >/dev/null
  aws ec2 associate-route-table --route-table-id "$public_rt" --subnet-id "$pub1" >/dev/null
  aws ec2 associate-route-table --route-table-id "$public_rt" --subnet-id "$pub2" >/dev/null
  state_set PUBLIC_RT "$public_rt"

  # Isolated: local route only. No IGW, no NAT.
  iso_rt="$(make_rt "$vpc" "${NAME}-isolated-rt")"
  aws ec2 associate-route-table --route-table-id "$iso_rt" --subnet-id "$iso1" >/dev/null
  aws ec2 associate-route-table --route-table-id "$iso_rt" --subnet-id "$iso2" >/dev/null
  state_set ISOLATED_RT "$iso_rt"

  log "NAT Gateway per AZ (private subnets only)"
  local eip1 eip2 nat1 nat2
  eip1="$(aws ec2 allocate-address --domain vpc --tag-specifications \
    "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${NAME}-nat-a},{Key=Project,Value=${NAME}}]" \
    --query AllocationId --output text)"
  eip2="$(aws ec2 allocate-address --domain vpc --tag-specifications \
    "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${NAME}-nat-b},{Key=Project,Value=${NAME}}]" \
    --query AllocationId --output text)"
  nat1="$(aws ec2 create-nat-gateway --subnet-id "$pub1" --allocation-id "$eip1" --tag-specifications \
    "ResourceType=natgateway,Tags=[{Key=Name,Value=${NAME}-nat-a},{Key=Project,Value=${NAME}}]" \
    --query 'NatGateway.NatGatewayId' --output text)"
  nat2="$(aws ec2 create-nat-gateway --subnet-id "$pub2" --allocation-id "$eip2" --tag-specifications \
    "ResourceType=natgateway,Tags=[{Key=Name,Value=${NAME}-nat-b},{Key=Project,Value=${NAME}}]" \
    --query 'NatGateway.NatGatewayId' --output text)"
  state_set EIP_1 "$eip1"
  state_set EIP_2 "$eip2"
  state_set NAT_1 "$nat1"
  state_set NAT_2 "$nat2"
  log "waiting for NAT gateways"
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$nat1" "$nat2"

  pri_rt1="$(make_rt "$vpc" "${NAME}-private-rt-a")"
  pri_rt2="$(make_rt "$vpc" "${NAME}-private-rt-b")"
  aws ec2 create-route --route-table-id "$pri_rt1" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$nat1" >/dev/null
  aws ec2 create-route --route-table-id "$pri_rt2" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$nat2" >/dev/null
  aws ec2 associate-route-table --route-table-id "$pri_rt1" --subnet-id "$pri1" >/dev/null
  aws ec2 associate-route-table --route-table-id "$pri_rt2" --subnet-id "$pri2" >/dev/null
  state_set PRIVATE_RT_1 "$pri_rt1"
  state_set PRIVATE_RT_2 "$pri_rt2"

  # S3 via the AWS network, not the NAT. Isolated subnets can reach S3 without internet.
  local vpce
  vpce="$(aws ec2 create-vpc-endpoint \
    --vpc-id "$vpc" \
    --vpc-endpoint-type Gateway \
    --service-name com.amazonaws.us-east-1.s3 \
    --route-table-ids "$pri_rt1" "$pri_rt2" "$iso_rt" \
    --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=${NAME}-s3},{Key=Project,Value=${NAME}}]" \
    --query 'VpcEndpoint.VpcEndpointId' --output text)"
  state_set S3_VPCE "$vpce"
}

make_subnet() {
  local vpc="$1" cidr="$2" az="$3" public="$4" name="$5"
  local id
  id="$(aws ec2 create-subnet --vpc-id "$vpc" --cidr-block "$cidr" --availability-zone "$az" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${NAME}}]" \
    --query 'Subnet.SubnetId' --output text)"
  if [[ "$public" == true ]]; then
    aws ec2 modify-subnet-attribute --subnet-id "$id" --map-public-ip-on-launch
  fi
  printf '%s' "$id"
}

make_rt() {
  local vpc="$1" name="$2"
  aws ec2 create-route-table --vpc-id "$vpc" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${NAME}}]" \
    --query 'RouteTable.RouteTableId' --output text
}

build_flow_logs() {
  log "VPC flow logs -> s3://${BUCKET}/flow"
  local result
  result="$(aws ec2 create-flow-logs \
    --resource-type VPC \
    --resource-ids "$VPC_ID" \
    --traffic-type ALL \
    --log-destination-type s3 \
    --log-destination "arn:aws:s3:::${BUCKET}/flow" \
    --max-aggregation-interval 60 \
    --destination-options FileFormat=parquet,HiveCompatiblePartitions=true,PerHourPartition=true \
    --tag-specifications "ResourceType=vpc-flow-log,Tags=[{Key=Name,Value=${NAME}-flow},{Key=Project,Value=${NAME}}]" \
    --output json)"
  if python3 -c 'import json,sys; data=json.loads(sys.argv[1]); raise SystemExit(1 if data.get("Unsuccessful") else 0)' "$result"; then
    :
  else
    printf '%s\n' "$result" >&2
    die "flow log was not created; check the bucket policy"
  fi
  state_set FLOW_LOG_ID "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["FlowLogIds"][0])' "$result")"
}

build_iam() {
  log "IAM roles (SSM only, no admin)"
  local trust="$WORKDIR/ec2-trust.json"
  cat > "$trust" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
  aws iam create-role --role-name "${NAME}-app-role" --assume-role-policy-document "file://${trust}" \
    --tags Key=Project,Value="${NAME}" >/dev/null
  aws iam attach-role-policy --role-name "${NAME}-app-role" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam create-role --role-name "${NAME}-bastion-role" --assume-role-policy-document "file://${trust}" \
    --tags Key=Project,Value="${NAME}" >/dev/null
  aws iam attach-role-policy --role-name "${NAME}-bastion-role" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

  aws iam create-instance-profile --instance-profile-name "${NAME}-app-profile" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "${NAME}-app-profile" --role-name "${NAME}-app-role"
  aws iam create-instance-profile --instance-profile-name "${NAME}-bastion-profile" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "${NAME}-bastion-profile" --role-name "${NAME}-bastion-role"
  state_set APP_ROLE "${NAME}-app-role"
  state_set BASTION_ROLE "${NAME}-bastion-role"
  state_set APP_PROFILE "${NAME}-app-profile"
  state_set BASTION_PROFILE "${NAME}-bastion-profile"
  log "waiting for instance profiles to propagate"
  sleep 12
  APP_PROFILE_ARN="$(aws iam get-instance-profile --instance-profile-name "${NAME}-app-profile" --query 'InstanceProfile.Arn' --output text)"
  state_set APP_PROFILE_ARN "$APP_PROFILE_ARN"
}

build_security_groups() {
  log "security groups"
  local alb app bastion cf_pl
  alb="$(aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name "${NAME}-alb" \
    --description "ALB ingress from CloudFront only" --query GroupId --output text)"
  app="$(aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name "${NAME}-app" \
    --description "App ingress from ALB on 80 and bastion on 22" --query GroupId --output text)"
  bastion="$(aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name "${NAME}-bastion" \
    --description "Bastion SSH from operator IP" --query GroupId --output text)"
  aws ec2 create-tags --resources "$alb" "$app" "$bastion" --tags "Key=Project,Value=${NAME}"

  cf_pl="$(aws ec2 describe-managed-prefix-lists \
    --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
    --query 'PrefixLists[0].PrefixListId' --output text)"
  [[ -n "$cf_pl" && "$cf_pl" != "None" ]] || die "CloudFront origin-facing prefix list not found"
  aws ec2 authorize-security-group-ingress --group-id "$alb" \
    --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds=[{PrefixListId=${cf_pl}}]" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$app" \
    --protocol tcp --port 80 --source-group "$alb" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$app" \
    --protocol tcp --port 22 --source-group "$bastion" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$bastion" \
    --protocol tcp --port 22 --cidr "$BASTION_SSH_CIDR" >/dev/null

  state_set ALB_SG "$alb"
  state_set APP_SG "$app"
  state_set BASTION_SG "$bastion"
  state_set CF_PREFIX_LIST "$cf_pl"
  ALB_SG="$alb"
  APP_SG="$app"
  BASTION_SG="$bastion"
}

build_bastion() {
  local az="$1"
  log "bastion in public subnet"
  local ami key_name key_path
  ami="$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query 'Parameter.Value' --output text)"
  state_set AMI_ID "$ami"
  AMI_ID="$ami"
  key_name="${NAME}-bastion"
  key_path="${ROOT}/${key_name}.pem"
  umask 077
  aws ec2 create-key-pair --key-name "$key_name" --query KeyMaterial --output text > "$key_path"
  chmod 400 "$key_path"
  state_set KEY_NAME "$key_name"

  local id
  id="$(aws ec2 run-instances \
    --image-id "$ami" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$key_name" \
    --subnet-id "$PUBLIC_SUBNET_1" \
    --security-group-ids "$BASTION_SG" \
    --iam-instance-profile "Name=${NAME}-bastion-profile" \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1 \
    --count 1 \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}-bastion},{Key=Project,Value=${NAME}}]" \
    --query 'Instances[0].InstanceId' --output text)"
  state_set BASTION_ID "$id"
  aws ec2 wait instance-running --instance-ids "$id"
  state_set BASTION_PUBLIC_IP "$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
}

build_alb() {
  log "public ALB"
  local arn tg listener
  arn="$(aws elbv2 create-load-balancer \
    --name "${NAME}-alb" \
    --type application \
    --scheme internet-facing \
    --subnets "$PUBLIC_SUBNET_1" "$PUBLIC_SUBNET_2" \
    --security-groups "$ALB_SG" \
    --tags Key=Name,Value="${NAME}-alb" Key=Project,Value="${NAME}" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
  state_set ALB_ARN "$arn"
  ALB_ARN="$arn"
  aws elbv2 wait load-balancer-available --load-balancer-arns "$arn"
  state_set ALB_DNS "$(aws elbv2 describe-load-balancers --load-balancer-arns "$arn" --query 'LoadBalancers[0].DNSName' --output text)"
  ALB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$arn" --query 'LoadBalancers[0].DNSName' --output text)"

  tg="$(aws elbv2 create-target-group \
    --name "${NAME}-app-tg" \
    --protocol HTTP --port 80 \
    --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-path / \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --matcher HttpCode=200 \
    --tags Key=Name,Value="${NAME}-app-tg" Key=Project,Value="${NAME}" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
  aws elbv2 modify-target-group-attributes --target-group-arn "$tg" \
    --attributes Key=deregistration_delay.timeout_seconds,Value=30 >/dev/null
  state_set TG_ARN "$tg"
  TG_ARN="$tg"

  # Default 403. Only CloudFront, which injects the origin header, is forwarded.
  ORIGIN_SECRET="$(openssl rand -hex 24)"
  state_set ORIGIN_SECRET "$ORIGIN_SECRET"
  listener="$(aws elbv2 create-listener \
    --load-balancer-arn "$arn" \
    --protocol HTTP --port 80 \
    --default-actions '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"403","ContentType":"text/plain","MessageBody":"forbidden"}}]' \
    --query 'Listeners[0].ListenerArn' --output text)"
  python3 - "$ORIGIN_SECRET" "$tg" "$WORKDIR" <<'PY'
import json, sys
secret, tg, workdir = sys.argv[1:]
with open(f"{workdir}/alb-conditions.json", "w", encoding="utf-8") as handle:
    json.dump([{
        "Field": "http-header",
        "HttpHeaderConfig": {"HttpHeaderName": "X-Origin-Verify", "Values": [secret]},
    }], handle)
with open(f"{workdir}/alb-actions.json", "w", encoding="utf-8") as handle:
    json.dump([{"Type": "forward", "TargetGroupArn": tg}], handle)
PY
  aws elbv2 create-rule \
    --listener-arn "$listener" \
    --priority 1 \
    --conditions "file://${WORKDIR}/alb-conditions.json" \
    --actions "file://${WORKDIR}/alb-actions.json" \
    >/dev/null
  state_set LISTENER_ARN "$listener"

  aws elbv2 modify-load-balancer-attributes --load-balancer-arn "$arn" --attributes \
    Key=access_logs.s3.enabled,Value=true \
    Key=access_logs.s3.bucket,Value="$BUCKET" \
    Key=access_logs.s3.prefix,Value=alb \
    Key=deletion_protection.enabled,Value=true \
    Key=routing.http.drop_invalid_header_fields.enabled,Value=true \
    Key=idle_timeout.timeout_seconds,Value=60 >/dev/null
}

build_launch_template() {
  log "launch template + sample userdata"
  cat > "$WORKDIR/userdata.sh" <<'EOF'
#!/bin/bash
set -euxo pipefail
dnf install -y httpd
TOKEN="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")"
IID="$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)"
AZ="$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)"
cat > /var/www/html/index.html <<HTML
<!doctype html>
<meta charset="utf-8">
<title>well-architected</title>
<h1>well-architected sample</h1>
<p>instance ${IID} in ${AZ}</p>
HTML
systemctl enable --now httpd
EOF
  local b64
  b64="$(base64 < "$WORKDIR/userdata.sh" | tr -d '\n')"
  python3 - "$AMI_ID" "$INSTANCE_TYPE" "$APP_PROFILE_ARN" "$APP_SG" "$b64" "$NAME" > "$WORKDIR/lt.json" <<'PY'
import json, sys
ami, itype, profile, sg, userdata, name = sys.argv[1:]
json.dump({
  "ImageId": ami,
  "InstanceType": itype,
  "IamInstanceProfile": {"Arn": profile},
  "SecurityGroupIds": [sg],
  "UserData": userdata,
  "MetadataOptions": {
    "HttpTokens": "required",
    "HttpEndpoint": "enabled",
    "HttpPutResponseHopLimit": 1,
  },
  "BlockDeviceMappings": [{
    "DeviceName": "/dev/xvda",
    "Ebs": {
      "VolumeSize": 8,
      "VolumeType": "gp3",
      "Encrypted": True,
      "DeleteOnTermination": True,
    },
  }],
  "TagSpecifications": [{
    "ResourceType": "instance",
    "Tags": [
      {"Key": "Name", "Value": f"{name}-app"},
      {"Key": "Project", "Value": name},
    ],
  }],
}, sys.stdout)
PY
  local lt_id
  lt_id="$(aws ec2 create-launch-template \
    --launch-template-name "${NAME}-app" \
    --version-description "sample-httpd" \
    --launch-template-data "file://${WORKDIR}/lt.json" \
    --tag-specifications "ResourceType=launch-template,Tags=[{Key=Name,Value=${NAME}-app},{Key=Project,Value=${NAME}}]" \
    --query 'LaunchTemplate.LaunchTemplateId' --output text)"
  state_set LAUNCH_TEMPLATE_ID "$lt_id"
  LAUNCH_TEMPLATE_ID="$lt_id"
}

build_asg() {
  log "ASG in private subnets"
  aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "${NAME}-app" \
    --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=\$Latest" \
    --min-size 1 --max-size 2 --desired-capacity 1 \
    --vpc-zone-identifier "${PRIVATE_SUBNET_1},${PRIVATE_SUBNET_2}" \
    --target-group-arns "$TG_ARN" \
    --health-check-type ELB \
    --health-check-grace-period 300 \
    --tags "Key=Name,Value=${NAME}-app,PropagateAtLaunch=true" "Key=Project,Value=${NAME},PropagateAtLaunch=true"
  state_set ASG_NAME "${NAME}-app"

  local label
  label="${ALB_ARN##*loadbalancer/}/${TG_ARN##*:}"
  aws autoscaling put-scaling-policy \
    --auto-scaling-group-name "${NAME}-app" \
    --policy-name "${NAME}-alb-requests" \
    --policy-type TargetTrackingScaling \
    --target-tracking-configuration \
    "PredefinedMetricSpecification={PredefinedMetricType=ALBRequestCountPerTarget,ResourceLabel=${label}},TargetValue=100,DisableScaleIn=false" \
    >/dev/null
}

build_waf() {
  log "WAF on CloudFront (must be us-east-1)"
  python3 - > "$WORKDIR/waf-rules.json" <<'PY'
import json, sys
groups = [
  ("AWSManagedRulesAmazonIpReputationList", "ip-reputation"),
  ("AWSManagedRulesCommonRuleSet", "common"),
  ("AWSManagedRulesKnownBadInputsRuleSet", "known-bad-inputs"),
]
rules = []
for i, (name, metric) in enumerate(groups):
    rules.append({
      "Name": name,
      "Priority": i,
      "Statement": {"ManagedRuleGroupStatement": {"VendorName": "AWS", "Name": name}},
      "OverrideAction": {"None": {}},
      "VisibilityConfig": {
        "SampledRequestsEnabled": True,
        "CloudWatchMetricsEnabled": True,
        "MetricName": metric,
      },
    })
json.dump(rules, sys.stdout)
PY
  local arn id
  read -r arn id < <(aws wafv2 create-web-acl \
    --name "${NAME}-cloudfront" \
    --scope CLOUDFRONT \
    --region us-east-1 \
    --default-action '{"Allow":{}}' \
    --description "CloudFront edge ACL: IP reputation, common rules, known bad inputs" \
    --rules "file://${WORKDIR}/waf-rules.json" \
    --visibility-config SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName="${NAME}-cloudfront" \
    --tags Key=Project,Value="${NAME}" \
    --query 'Summary.[ARN,Id]' --output text)
  state_set WAF_ARN "$arn"
  state_set WAF_ID "$id"
  WAF_ARN="$arn"
}

build_cloudfront() {
  log "CloudFront"
  local cache_policy
  cache_policy="$(aws cloudfront list-cache-policies --type managed \
    --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='Managed-CachingDisabled'].CachePolicy.Id | [0]" \
    --output text)"
  [[ -n "$cache_policy" && "$cache_policy" != "None" ]] || die "managed cache policy CachingDisabled not found"
  python3 - "$ALB_DNS" "$cache_policy" "$ORIGIN_SECRET" "$WAF_ARN" > "$WORKDIR/cf.json" <<'PY'
import json, sys, time
alb, policy, secret, waf = sys.argv[1:]
json.dump({
  "CallerReference": f"wa-{int(time.time())}",
  "Comment": "well-architected sample",
  "Enabled": True,
  "PriceClass": "PriceClass_100",
  "HttpVersion": "http2",
  "WebACLId": waf,
  "Origins": {"Quantity": 1, "Items": [{
    "Id": "alb",
    "DomainName": alb,
    "CustomHeaders": {"Quantity": 1, "Items": [{
      "HeaderName": "X-Origin-Verify",
      "HeaderValue": secret,
    }]},
    "CustomOriginConfig": {
      "HTTPPort": 80,
      "HTTPSPort": 443,
      "OriginProtocolPolicy": "http-only",
      "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]},
    },
  }]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "alb",
    "ViewerProtocolPolicy": "redirect-to-https",
    "CachePolicyId": policy,
    "Compress": True,
    "AllowedMethods": {
      "Quantity": 7,
      "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
      "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]},
    },
  },
  "ViewerCertificate": {
    "CloudFrontDefaultCertificate": True,
    "MinimumProtocolVersion": "TLSv1.2_2021",
  },
}, sys.stdout)
PY
  local id domain
  id="$(aws cloudfront create-distribution --distribution-config "file://${WORKDIR}/cf.json" --query 'Distribution.Id' --output text)"
  domain="$(aws cloudfront get-distribution --id "$id" --query 'Distribution.DomainName' --output text)"
  state_set CF_ID "$id"
  state_set CF_DOMAIN "$domain"
}

build_alarm() {
  local alb_dim="${ALB_ARN##*loadbalancer/}"
  aws cloudwatch put-metric-alarm \
    --alarm-name "${NAME}-alb-5xx" \
    --alarm-description "ALB 5xx count" \
    --namespace AWS/ApplicationELB \
    --metric-name HTTPCode_ELB_5XX_Count \
    --dimensions "Name=LoadBalancer,Value=${alb_dim}" \
    --statistic Sum --period 60 --evaluation-periods 1 --threshold 10 \
    --comparison-operator GreaterThanThreshold \
    --treat-missing-data notBreaching \
    --tags Key=Project,Value="${NAME}" >/dev/null
  state_set ALARM_NAME "${NAME}-alb-5xx"
}

# ---------------------------------------------------------------------------
# Destroy
# ---------------------------------------------------------------------------

destroy() {
  need aws
  need python3
  [[ -f "$STATE_FILE" ]] || die "no state file at $STATE_FILE"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  new_workdir
  log "destroying stack from $STATE_FILE"

  if [[ -n "${CF_ID:-}" ]]; then
    log "disable CloudFront $CF_ID (this wait is the slow part)"
    aws cloudfront get-distribution-config --id "$CF_ID" > "$WORKDIR/cf-get.json"
    python3 - "$WORKDIR/cf-get.json" "$WORKDIR/cf-off.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
body = json.load(open(src))
cfg = body["DistributionConfig"]
cfg["Enabled"] = False
json.dump(cfg, open(dst, "w"))
print(body["ETag"])
PY
    local etag
    etag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ETag"])' "$WORKDIR/cf-get.json")"
    aws cloudfront update-distribution --id "$CF_ID" --if-match "$etag" --distribution-config "file://${WORKDIR}/cf-off.json" >/dev/null
    aws cloudfront wait distribution-deployed --id "$CF_ID"
    etag="$(aws cloudfront get-distribution-config --id "$CF_ID" --query ETag --output text)"
    aws cloudfront delete-distribution --id "$CF_ID" --if-match "$etag"
  fi

  if [[ -n "${WAF_ID:-}" ]]; then
    local lock
    lock="$(aws wafv2 get-web-acl --scope CLOUDFRONT --region us-east-1 --name "${NAME}-cloudfront" --id "$WAF_ID" --query LockToken --output text || true)"
    if [[ -n "$lock" && "$lock" != "None" ]]; then
      aws wafv2 delete-web-acl --scope CLOUDFRONT --region us-east-1 --name "${NAME}-cloudfront" --id "$WAF_ID" --lock-token "$lock"
    fi
  fi

  if [[ -n "${ALARM_NAME:-}" ]]; then
    aws cloudwatch delete-alarms --alarm-names "$ALARM_NAME" || true
  fi

  if [[ -n "${ALB_ARN:-}" ]]; then
    aws elbv2 modify-load-balancer-attributes --load-balancer-arn "$ALB_ARN" \
      --attributes Key=deletion_protection.enabled,Value=false >/dev/null || true
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" || true
    aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" || true
  fi
  if [[ -n "${TG_ARN:-}" ]]; then
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN" || true
  fi

  if [[ -n "${ASG_NAME:-}" ]]; then
    aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --force-delete || true
    aws autoscaling wait group-not-exists --auto-scaling-group-names "$ASG_NAME" || true
  fi
  if [[ -n "${LAUNCH_TEMPLATE_ID:-}" ]]; then
    aws ec2 delete-launch-template --launch-template-id "$LAUNCH_TEMPLATE_ID" || true
  fi
  if [[ -n "${BASTION_ID:-}" ]]; then
    aws ec2 terminate-instances --instance-ids "$BASTION_ID" >/dev/null || true
    aws ec2 wait instance-terminated --instance-ids "$BASTION_ID" || true
  fi
  if [[ -n "${KEY_NAME:-}" ]]; then
    aws ec2 delete-key-pair --key-name "$KEY_NAME" || true
    rm -f "${ROOT}/${KEY_NAME}.pem"
  fi

  if [[ -n "${FLOW_LOG_ID:-}" ]]; then
    aws ec2 delete-flow-logs --flow-log-ids "$FLOW_LOG_ID" || true
  fi
  if [[ -n "${S3_VPCE:-}" ]]; then
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$S3_VPCE" || true
  fi
  if [[ -n "${NAT_1:-}" ]]; then
    aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_1" >/dev/null || true
  fi
  if [[ -n "${NAT_2:-}" ]]; then
    aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_2" >/dev/null || true
  fi
  if [[ -n "${NAT_1:-}" && -n "${NAT_2:-}" ]]; then
    log "waiting for NAT gateways to delete"
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_1" "$NAT_2" || true
  elif [[ -n "${NAT_1:-}" ]]; then
    log "waiting for NAT gateway to delete"
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_1" || true
  elif [[ -n "${NAT_2:-}" ]]; then
    log "waiting for NAT gateway to delete"
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_2" || true
  fi
  if [[ -n "${EIP_1:-}" ]]; then
    aws ec2 release-address --allocation-id "$EIP_1" || true
  fi
  if [[ -n "${EIP_2:-}" ]]; then
    aws ec2 release-address --allocation-id "$EIP_2" || true
  fi

  if [[ -n "${VPC_ID:-}" ]]; then
    if [[ -n "${IGW_ID:-}" ]]; then
      aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" || true
      aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" || true
    fi
    local sub
    for sub in \
      "${PUBLIC_SUBNET_1:-}" "${PUBLIC_SUBNET_2:-}" \
      "${PRIVATE_SUBNET_1:-}" "${PRIVATE_SUBNET_2:-}" \
      "${ISOLATED_SUBNET_1:-}" "${ISOLATED_SUBNET_2:-}"
    do
      [[ -n "$sub" ]] && aws ec2 delete-subnet --subnet-id "$sub" || true
    done
    for rt in "${PUBLIC_RT:-}" "${PRIVATE_RT_1:-}" "${PRIVATE_RT_2:-}" "${ISOLATED_RT:-}"; do
      [[ -n "$rt" ]] && aws ec2 delete-route-table --route-table-id "$rt" || true
    done
    for sg in "${ALB_SG:-}" "${APP_SG:-}" "${BASTION_SG:-}"; do
      [[ -n "$sg" ]] && aws ec2 delete-security-group --group-id "$sg" || true
    done
    aws ec2 delete-vpc --vpc-id "$VPC_ID" || true
  fi

  if [[ -n "${BUCKET:-}" ]]; then
    log "empty and delete $BUCKET"
    empty_bucket "$BUCKET"
    aws s3api delete-bucket --bucket "$BUCKET" || true
  fi

  delete_role "${APP_PROFILE:-}" "${APP_ROLE:-}"
  delete_role "${BASTION_PROFILE:-}" "${BASTION_ROLE:-}"

  rm -f "$STATE_FILE"
  log "destroyed"
}

delete_role() {
  local profile="$1" role="$2"
  [[ -n "$profile" ]] || return 0
  aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role" || true
  aws iam delete-instance-profile --instance-profile-name "$profile" || true
  [[ -n "$role" ]] || return 0
  aws iam detach-role-policy --role-name "$role" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore || true
  aws iam delete-role --role-name "$role" || true
}

empty_bucket() {
  local bucket="$1" key_marker="" version_marker=""
  while true; do
    if [[ -n "$key_marker" ]]; then
      aws s3api list-object-versions --bucket "$bucket" \
        --key-marker "$key_marker" --version-id-marker "$version_marker" \
        --output json > "$WORKDIR/versions.json"
    else
      aws s3api list-object-versions --bucket "$bucket" --output json > "$WORKDIR/versions.json"
    fi
    python3 - "$bucket" "$WORKDIR/versions.json" "$WORKDIR/versions.meta" <<'PY'
import json, subprocess, sys
bucket, src, meta = sys.argv[1:]
data = json.load(open(src))
objs = []
for key in ("Versions", "DeleteMarkers"):
    for item in data.get(key) or []:
        objs.append({"Key": item["Key"], "VersionId": item["VersionId"]})
for i in range(0, len(objs), 1000):
    chunk = objs[i:i + 1000]
    subprocess.check_call([
        "aws", "s3api", "delete-objects", "--bucket", bucket,
        "--delete", json.dumps({"Objects": chunk, "Quiet": True}),
    ])
with open(meta, "w", encoding="utf-8") as handle:
    handle.write("yes\n" if data.get("IsTruncated") else "no\n")
    handle.write((data.get("NextKeyMarker") or "") + "\n")
    handle.write((data.get("NextVersionIdMarker") or "") + "\n")
PY
    [[ "$(sed -n '1p' "$WORKDIR/versions.meta")" == "yes" ]] || break
    key_marker="$(sed -n '2p' "$WORKDIR/versions.meta")"
    version_marker="$(sed -n '3p' "$WORKDIR/versions.meta")"
  done
}

usage() {
  cat <<EOF
Usage: $0 [up|destroy]
  up       create the stack (default)
  destroy  delete resources recorded in wa-state.env
Env:
  BASTION_SSH_CIDR   default: your current public IP /32
  INSTANCE_TYPE      default: t3.micro
  NAME               default: wa
EOF
}

case "${1:-up}" in
  up|create) build ;;
  destroy|down) destroy ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
