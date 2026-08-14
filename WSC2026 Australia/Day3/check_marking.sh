#!/usr/bin/env bash
#
# check_marking.sh
# -------------------------------------------------------------------
# Day 3 - Cloud Computing - marking scheme automated checker (AWS CLI)
#
# Reads each measurement-based Sub Criterion from the marking scheme and
# verifies it against a live AWS account using the AWS CLI, printing:
#
#   # Criterion ID - A.1
#   Result: PASS (or FAIL)
#   Description: (Output of awscli command)
#   ---
#
# Usage:
#   ./check_marking.sh                 # run all criteria
#   ./check_marking.sh A.1 B.5 C.2     # run only the listed criteria
#
# Requirements: aws cli v2, jq.  (kubectl optional - for B.3/B.4/C.5)
# -------------------------------------------------------------------

set -uo pipefail

# ===================== CONFIG (adjust as needed) ====================
PROJECT="${PROJECT:-mealmint}"
REGION="us-east-1"                                             # primary region (fixed)
DR_REGION="us-west-2"                                          # disaster-recovery region (fixed) - B.6 & C.3
MAXJOBS="${MAXJOBS:-8}"                                        # parallel checks at once
MIN_AWSCLI="${MIN_AWSCLI:-2.34.0}"                            # required for NAT AvailabilityMode (A.2)

ZONE_NAME="${ZONE_NAME:-mealmint.internal}"                    # A.3 / A.6 / A.7
VPN_NAME="${VPN_NAME:-mealmint-client-vpn}"                    # A.5
ALB_NAME="${ALB_NAME:-mealmint-alb}"                           # C.1
EVENTS_BUCKET_MATCH="${EVENTS_BUCKET_MATCH:-mealmint-events}"   # C.3 source bucket name fragment
DR_BUCKET_MATCH="${DR_BUCKET_MATCH:-mealmint-events-dr}"        # C.3 DR bucket name fragment
LAMBDA_NAME="${LAMBDA_NAME:-rate-api}"                         # C.4 (exact Lambda function name)
ARGOCD_RECORD="${ARGOCD_RECORD:-argocd.${ZONE_NAME}}"         # A.7
CF_STATIC_NAME="${CF_STATIC_NAME:-static-cf}"                  # D.1 CloudFront Name tag
CF_API_NAME="${CF_API_NAME:-api-cf}"                           # D.2 CloudFront Name tag
ECR_REPOS="${ECR_REPOS:-recipe-api search-api}"               # B.2 (required ECR repo names)

# Optional explicit overrides (otherwise auto-discovered):
VPC_ID="${VPC_ID:-}"
EKS_CLUSTER="${EKS_CLUSTER:-}"
DOCDB_CLUSTER="${DOCDB_CLUSTER:-}"
EVENTS_BUCKET="${EVENTS_BUCKET:-}"
DR_BUCKET="${DR_BUCKET:-}"
ZONE_ID="${ZONE_ID:-}"
# ====================================================================

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws cli not found" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq not found"      >&2; exit 1; }

# ----- AWS CLI version gate (bash 3.2 compatible) ---------------------
# Returns 0 if version $1 >= version $2 (dotted, e.g. 2.34.0).
ver_ge() {
  local IFS=. i x y
  local a=($1) b=($2)
  for i in 0 1 2; do
    x=${a[i]:-0}; y=${b[i]:-0}
    x=${x%%[!0-9]*}; [ -z "$x" ] && x=0   # strip any non-numeric suffix
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
  done
  return 0
}

AWS_VER_RAW=$(aws --version 2>&1)            # e.g. "aws-cli/2.34.5 Python/3.13 ..."
AWS_VER=${AWS_VER_RAW#*aws-cli/}; AWS_VER=${AWS_VER%% *}
if ! ver_ge "$AWS_VER" "$MIN_AWSCLI"; then
  echo "ERROR: AWS CLI $AWS_VER detected, but >= $MIN_AWSCLI is required." >&2
  echo "       The Regional NAT Gateway 'AvailabilityMode' field (A.2) needs AWS CLI >= $MIN_AWSCLI;" >&2
  echo "       older versions silently omit it and would mis-score A.2." >&2
  echo "       Upgrade:  brew upgrade awscli   (or reinstall from https://awscli.amazonaws.com/AWSCLIV2.pkg)" >&2
  exit 1
fi

AWSP=(aws --region "$REGION" --output json)
WORKDIR=""   # temp dir for parallel output (set in main, cleaned on EXIT)

# ----- report helper: prints the required output block ----------------
report() {
  local id="$1" result="$2" desc="$3"
  printf '# Criterion ID - %s\n' "$id"
  printf 'Result: %s\n' "$result"
  printf 'Description: %s\n' "$desc"
  printf -- '---\n\n'
}

# ----- resource discovery (cached in globals) -------------------------
discover_vpc() {
  [ -n "$VPC_ID" ] && return 0
  VPC_ID=$("${AWSP[@]}" ec2 describe-vpcs \
            --filters "Name=tag:Name,Values=*${PROJECT}*" \
            --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
  if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
    # fall back to first non-default VPC
    VPC_ID=$("${AWSP[@]}" ec2 describe-vpcs \
              --filters "Name=isDefault,Values=false" \
              --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
  fi
  [ "$VPC_ID" = "None" ] && VPC_ID=""
}

discover_eks() {
  [ -n "$EKS_CLUSTER" ] && return 0
  EKS_CLUSTER=$("${AWSP[@]}" eks list-clusters --query 'clusters[0]' --output text 2>/dev/null)
  [ "$EKS_CLUSTER" = "None" ] && EKS_CLUSTER=""
}

discover_docdb() {
  [ -n "$DOCDB_CLUSTER" ] && return 0
  DOCDB_CLUSTER=$("${AWSP[@]}" docdb describe-db-clusters \
                   --query 'DBClusters[0].DBClusterIdentifier' --output text 2>/dev/null)
  [ "$DOCDB_CLUSTER" = "None" ] && DOCDB_CLUSTER=""
}

discover_events_bucket() {
  [ -n "$EVENTS_BUCKET" ] && return 0
  # source events bucket: matches the events fragment but NOT the DR fragment
  EVENTS_BUCKET=$(aws s3api list-buckets \
        --query "Buckets[?contains(Name, '${EVENTS_BUCKET_MATCH}') && !contains(Name, '${DR_BUCKET_MATCH}')].Name | [0]" \
        --output text 2>/dev/null)
  [ "$EVENTS_BUCKET" = "None" ] && EVENTS_BUCKET=""
}

discover_dr_bucket() {
  [ -n "$DR_BUCKET" ] && return 0
  # DR bucket: matches the DR fragment (full name incl. any suffix)
  DR_BUCKET=$(aws s3api list-buckets \
        --query "Buckets[?contains(Name, '${DR_BUCKET_MATCH}')].Name | [0]" \
        --output text 2>/dev/null)
  [ "$DR_BUCKET" = "None" ] && DR_BUCKET=""
}

discover_zone() {
  [ -n "$ZONE_ID" ] && return 0
  ZONE_ID=$(aws route53 list-hosted-zones \
            --query "HostedZones[?Name=='${ZONE_NAME}.'].Id | [0]" --output text 2>/dev/null)
  [ "$ZONE_ID" = "None" ] && ZONE_ID=""
}

# Run every discovery once, before the (parallel) checks fan out, so the
# results are cached in globals and inherited by all check subshells.
prefetch() {
  discover_vpc
  discover_eks
  discover_docdb
  discover_events_bucket
  discover_dr_bucket
  discover_zone
}

# =====================================================================
#  A. Networking
# =====================================================================

# A.1 - Public and private subnets across at least two AZs
check_A1() {
  discover_vpc
  local out pub_azs priv_azs pub_ids jqcls
  # subnet IDs explicitly associated with an internet-gateway route table
  pub_ids=$("${AWSP[@]}" ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
           --query "RouteTables[?Routes[?GatewayId!=null && starts_with(GatewayId,'igw-')]].Associations[].SubnetId" \
           --output text 2>&1)
  out=$("${AWSP[@]}" ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[].{Id:SubnetId,AZ:AvailabilityZone,Name:Tags[?Key==`Name`]|[0].Value}' 2>&1)
  # Classify each subnet: Name tag (public/private) first, then IGW route.
  jqcls='def cls($pubids): . as $s
    | if ($s.Name and ($s.Name|ascii_downcase|test("public"))) then "public"
      elif ($s.Name and ($s.Name|ascii_downcase|test("private"))) then "private"
      elif ($pubids|contains($s.Id)) then "public" else "private" end;'
  pub_azs=$(echo "$out"  | jq -r --arg p "$pub_ids" "$jqcls"' [ .[] | select(cls($p)=="public")  | .AZ ] | unique | length' 2>/dev/null)
  priv_azs=$(echo "$out" | jq -r --arg p "$pub_ids" "$jqcls"' [ .[] | select(cls($p)=="private") | .AZ ] | unique | length' 2>/dev/null)
  [ -z "$pub_azs" ] && pub_azs=0; [ -z "$priv_azs" ] && priv_azs=0
  if [ "$pub_azs" -ge 2 ] && [ "$priv_azs" -ge 2 ]; then RESULT=PASS; else RESULT=FAIL; fi
  DESC="VPC=$VPC_ID | public-subnet AZs=$pub_azs, private-subnet AZs=$priv_azs"$'\n'"$out"
}

# A.2 - Private subnets use a Regional NAT Gateway.
#  AWS NAT Gateway has an AvailabilityMode of "regional" (multi-AZ, GA Nov 2025)
#  or "zonal" (traditional, single-AZ). The efficient/intended answer is a
#  Regional NAT Gateway. Creating a single ZONAL NAT and attaching it to every
#  private subnet is the workaround and must FAIL. So PASS only when the NAT
#  Gateway used by the private routes is a Regional NAT Gateway.
check_A2() {
  discover_vpc
  local nat_out rt_out regional_ids nat_used reg_used bad_used
  nat_out=$("${AWSP[@]}" ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
        --query 'NatGateways[].{Id:NatGatewayId,Mode:AvailabilityMode,Subnet:SubnetId,Type:ConnectivityType}' 2>&1)
  rt_out=$("${AWSP[@]}" ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'RouteTables[].{Id:RouteTableId,Nat:Routes[?NatGatewayId].NatGatewayId}' 2>&1)
  regional_ids=$(echo "$nat_out" | jq -c '[.[]|select(.Mode=="regional")|.Id]' 2>/dev/null); [ -z "$regional_ids" ] && regional_ids="[]"
  nat_used=$(echo "$rt_out" | jq -c '[.[].Nat[]?]|unique' 2>/dev/null); [ -z "$nat_used" ] && nat_used="[]"
  # NATs used by routes that ARE regional, and those that are NOT (zonal workaround)
  reg_used=$(jq -n --argjson u "$nat_used" --argjson r "$regional_ids" '[$u[]|select($r|index(.))]|length' 2>/dev/null)
  bad_used=$(jq -n --argjson u "$nat_used" --argjson r "$regional_ids" '[$u[]|select(($r|index(.))|not)]|length' 2>/dev/null)
  [ -z "$reg_used" ] && reg_used=0; [ -z "$bad_used" ] && bad_used=0
  # PASS: private routes use a regional NAT and use NO zonal NAT
  if [ "$reg_used" -ge 1 ] && [ "$bad_used" -eq 0 ]; then RESULT=PASS; else RESULT=FAIL; fi
  DESC="regional NAT GWs=$regional_ids, NATs used by routes=$nat_used (regional used=$reg_used, zonal used=$bad_used)"$'\n'"$nat_out"
}

# A.3 - Route53 private hosted zone associated with the VPC
check_A3() {
  discover_vpc; discover_zone
  local out assoc
  if [ -z "$ZONE_ID" ]; then
    RESULT=FAIL; DESC="Hosted zone ${ZONE_NAME} not found"; return
  fi
  out=$(aws route53 get-hosted-zone --id "$ZONE_ID" \
        --query '{Private:HostedZone.Config.PrivateZone,VPCs:VPCs}' 2>&1)
  assoc=$(echo "$out" | jq -r --arg v "$VPC_ID" '[.VPCs[]?|select(.VPCId==$v)]|length' 2>/dev/null)
  if [ "${assoc:-0}" -ge 1 ]; then RESULT=PASS; else RESULT=FAIL; fi
  DESC="$out"
}

# A.4 - S3 Gateway VPC Endpoint exists
check_A4() {
  discover_vpc
  local out count
  out=$("${AWSP[@]}" ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=vpc-endpoint-type,Values=Gateway" \
        --query "VpcEndpoints[?contains(ServiceName,'s3')].{Id:VpcEndpointId,Svc:ServiceName,State:State}" 2>&1)
  count=$(echo "$out" | jq 'length' 2>/dev/null); [ -z "$count" ] && count=0
  if [ "$count" -ge 1 ]; then RESULT=PASS; else RESULT=FAIL; fi
  DESC="$out"
}

# A.5 - Client VPN endpoint with mutual (certificate) authentication
check_A5() {
  local out auth
  out=$("${AWSP[@]}" ec2 describe-client-vpn-endpoints \
        --query "ClientVpnEndpoints[?contains(to_string(Tags), '${VPN_NAME}') || Description=='${VPN_NAME}'].{Id:ClientVpnEndpointId,Status:Status.Code,Auth:AuthenticationOptions}" 2>&1)
  [ "$(echo "$out" | jq 'length' 2>/dev/null)" = "0" ] && \
    out=$("${AWSP[@]}" ec2 describe-client-vpn-endpoints \
        --query "ClientVpnEndpoints[].{Id:ClientVpnEndpointId,Status:Status.Code,Auth:AuthenticationOptions}" 2>&1)
  auth=$(echo "$out" | jq -r '[.[].Auth[]?|select(.Type=="certificate-authentication")]|length' 2>/dev/null)
  if [ "${auth:-0}" -ge 1 ]; then RESULT=PASS; else RESULT=FAIL; fi
  DESC="$out"
}

# A.6 - Through the Client VPN, mealmint.internal DNS records can be resolved.
#  Manual: requires connecting the Client VPN on the competitor's desktop and
#  actually querying the DNS, which cannot be automated from AWS CLI.
check_A6() { RESULT=None; DESC="Perform it manually. It cannot be automated."; }

# A.7 - argocd.mealmint.internal reachable through the Client VPN.
#  Manual: requires connecting the Client VPN on the competitor's desktop and
#  actually accessing the endpoint, which cannot be automated from AWS CLI.
check_A7() { RESULT=None; DESC="Perform it manually. It cannot be automated."; }

# =====================================================================
#  B. Compute nodes including database
# =====================================================================

# B.1 - EKS cluster deployed as a private cluster
check_B1() {
  discover_eks
  [ -z "$EKS_CLUSTER" ] && { RESULT=FAIL; DESC="No EKS cluster found"; return; }
  local out pub priv
  out=$("${AWSP[@]}" eks describe-cluster --name "$EKS_CLUSTER" \
        --query 'cluster.resourcesVpcConfig.{PublicAccess:endpointPublicAccess,PrivateAccess:endpointPrivateAccess,PublicCidrs:publicAccessCidrs}' 2>&1)
  pub=$(echo "$out"  | jq -r '.PublicAccess'  2>/dev/null)
  priv=$(echo "$out" | jq -r '.PrivateAccess' 2>/dev/null)
  if [ "$pub" = "false" ] && [ "$priv" = "true" ]; then RESULT=PASS; else RESULT=FAIL; fi
  DESC="cluster=$EKS_CLUSTER"$'\n'"$out"
}

# B.2 - The required ECR repositories exist (recipe-api, search-api).
#  PASS when every name in $ECR_REPOS exists (exact name or "<namespace>/<name>").
check_B2() {
  local want all r found=() missing=()
  want=($ECR_REPOS)
  all=$(aws ecr describe-repositories --region "$REGION" \
        --query 'repositories[].repositoryName' --output json 2>&1)
  for r in "${want[@]}"; do
    if echo "$all" | jq -e --arg r "$r" 'any(.[]?; . == $r or endswith("/" + $r))' >/dev/null 2>&1; then
      found+=("$r")
    else
      missing+=("$r")
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then RESULT=PASS; else RESULT=FAIL; fi
  DESC="required repos: ${want[*]}; found: ${found[*]:-none}; missing: ${missing[*]:-none}"$'\n'"existing repositories: $all"
}

# B.3 - Pods in the mealmint namespace use Pod Identity
check_B3() {
  discover_eks
  [ -z "$EKS_CLUSTER" ] && { RESULT=FAIL; DESC="No EKS cluster found"; return; }
  local out count
  out=$("${AWSP[@]}" eks list-pod-identity-associations --cluster-name "$EKS_CLUSTER" \
        --query "associations[?namespace=='${PROJECT}']" 2>&1)
  count=$(echo "$out" | jq 'length' 2>/dev/null); [ -z "$count" ] && count=0
  if [ "$count" -ge 1 ]; then RESULT=PASS; else RESULT=FAIL; fi
  DESC="Pod Identity associations in namespace '${PROJECT}': $count"$'\n'"$out"
}

# B.4 - ArgoCD resources deployed in the argocd namespace.
#  Manual: check the pods on the cluster with kubectl.
check_B4() {
  RESULT=None
  DESC="Perform it manually. It cannot be automated. kubectl get pods -n argocd"
}

# B.5 - DocumentDB backup retention >= 7 days
check_B5() {
  discover_docdb
  [ -z "$DOCDB_CLUSTER" ] && { RESULT=FAIL; DESC="No DocumentDB cluster found"; return; }
  local out ret
  out=$("${AWSP[@]}" docdb describe-db-clusters --db-cluster-identifier "$DOCDB_CLUSTER" \
        --query 'DBClusters[0].{Cluster:DBClusterIdentifier,Retention:BackupRetentionPeriod}' 2>&1)
  ret=$(echo "$out" | jq -r '.Retention' 2>/dev/null)
  if [ -n "$ret" ] && [ "$ret" != "null" ] && [ "$ret" -ge 7 ]; then RESULT=PASS; else RESULT=FAIL; fi
  DESC="$out"
}

# B.6 - DocumentDB cluster snapshot exists in the DR region (us-west-1)
check_B6() {
  discover_docdb
  local out count
  out=$(aws docdb describe-db-cluster-snapshots --region "$DR_REGION" \
        --query "DBClusterSnapshots[?contains(DBClusterIdentifier,'${DOCDB_CLUSTER:-$PROJECT}') || contains(DBClusterSnapshotIdentifier,'${PROJECT}')].{Snapshot:DBClusterSnapshotIdentifier,Cluster:DBClusterIdentifier,Status:Status}" --output json 2>&1)
  count=$(echo "$out" | jq 'length' 2>/dev/null); [ -z "$count" ] && count=0
  if [ "$count" -ge 1 ]; then RESULT=PASS; else RESULT=FAIL; fi
  DESC="DR region=$DR_REGION, matching snapshots=$count"$'\n'"$out"
}

# B.7 - DocumentDB cluster has a replica instance
check_B7() {
  discover_docdb
  [ -z "$DOCDB_CLUSTER" ] && { RESULT=FAIL; DESC="No DocumentDB cluster found"; return; }
  local out count
  out=$("${AWSP[@]}" docdb describe-db-clusters --db-cluster-identifier "$DOCDB_CLUSTER" \
        --query 'DBClusters[0].DBClusterMembers[].{Instance:DBInstanceIdentifier,Writer:IsClusterWriter}' 2>&1)
  count=$(echo "$out" | jq '[.[]|select(.Writer==false)]|length' 2>/dev/null); [ -z "$count" ] && count=0
  if [ "$count" -ge 1 ]; then RESULT=PASS; else RESULT=FAIL; fi
  DESC="replica (non-writer) instances=$count"$'\n'"$out"
}

# B.8 - TLS connection to the DocumentDB cluster is enabled
check_B8() {
  discover_docdb
  [ -z "$DOCDB_CLUSTER" ] && { RESULT=FAIL; DESC="No DocumentDB cluster found"; return; }
  local pg out tls
  pg=$("${AWSP[@]}" docdb describe-db-clusters --db-cluster-identifier "$DOCDB_CLUSTER" \
       --query 'DBClusters[0].DBClusterParameterGroup' --output text 2>&1)
  out=$("${AWSP[@]}" docdb describe-db-cluster-parameters --db-cluster-parameter-group-name "$pg" \
        --query "Parameters[?ParameterName=='tls'].{Name:ParameterName,Value:ParameterValue}" 2>&1)
  tls=$(echo "$out" | jq -r '.[0].Value' 2>/dev/null)
  # tls can be: disabled | enabled | fips-140-3. Both enabled and fips-140-3
  # enforce TLS, so anything other than "disabled" counts as TLS enabled.
  if [ -n "$tls" ] && [ "$tls" != "null" ] && [ "$tls" != "disabled" ]; then RESULT=PASS; else RESULT=FAIL; fi
  DESC="parameter group=$pg, tls=$tls"$'\n'"$out"
}

# =====================================================================
#  C. Availability options
# =====================================================================

# C.1 - API CloudFront points to the mealmint-alb
check_C1() {
  local alb_dns out match
  alb_dns=$(aws elbv2 describe-load-balancers --region "$REGION" \
            --query "LoadBalancers[?contains(LoadBalancerName,'${ALB_NAME}') || LoadBalancerName=='${ALB_NAME}'].DNSName | [0]" --output text 2>&1)
  out=$(aws cloudfront list-distributions \
        --query "DistributionList.Items[].{Id:Id,Origins:Origins.Items[].DomainName}" --output json 2>&1)
  if [ -n "$alb_dns" ] && [ "$alb_dns" != "None" ] && echo "$out" | grep -q "$alb_dns"; then
    RESULT=PASS
  else
    RESULT=FAIL
  fi
  DESC="ALB DNS=$alb_dns"$'\n'"CloudFront origins:"$'\n'"$out"
}

# C.2 - Firehose saves records in an S3 bucket, and the bucket actually
#  contains at least one delivered object (records were really saved).
check_C2() {
  local streams s desc bucket_arn bucket objkey rc
  streams=$(aws firehose list-delivery-streams --region "$REGION" \
            --query 'DeliveryStreamNames' --output json 2>&1)
  s=$(echo "$streams" | jq -r '.[]' 2>/dev/null | grep -i "$PROJECT" | head -1)
  [ -z "$s" ] && s=$(echo "$streams" | jq -r '.[0]' 2>/dev/null)
  [ -z "$s" -o "$s" = "null" ] && { RESULT=FAIL; DESC="No Firehose delivery stream found"$'\n'"$streams"; return; }
  desc=$(aws firehose describe-delivery-stream --region "$REGION" --delivery-stream-name "$s" 2>&1)
  bucket_arn=$(echo "$desc" | jq -r '[.DeliveryStreamDescription.Destinations[]? | (.ExtendedS3DestinationDescription.BucketARN // .S3DestinationDescription.BucketARN)] | map(select(.!=null)) | .[0] // empty' 2>/dev/null)
  if [ -z "$bucket_arn" ]; then RESULT=FAIL; DESC="stream=$s has no S3 destination configured"; return; fi
  bucket=${bucket_arn##*:::}
  # confirm the destination bucket actually holds at least one object
  objkey=$(aws s3api list-objects-v2 --bucket "$bucket" --max-keys 1 --query 'Contents[0].Key' --output text 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then RESULT=FAIL; DESC="stream=$s, dest bucket=$bucket (could not list objects)"; return; fi
  if [ -n "$objkey" ] && [ "$objkey" != "None" ]; then RESULT=PASS; else RESULT=FAIL; fi
  DESC="stream=$s, dest bucket=$bucket, sample object=${objkey:-none}"
}

# C.3 - source bucket replicates to the DR bucket which lives in the DR region.
#  Both buckets carry random suffixes, so they are resolved by name fragment.
#  Verifies (1) replication points to the DR bucket and (2) the DR bucket is
#  actually in the DR region (us-west-2).
check_C3() {
  discover_events_bucket
  discover_dr_bucket
  [ -z "$EVENTS_BUCKET" ] && { RESULT=FAIL; DESC="Source bucket (match '$EVENTS_BUCKET_MATCH') not found"; return; }
  [ -z "$DR_BUCKET" ]     && { RESULT=FAIL; DESC="DR bucket (match '$DR_BUCKET_MATCH') not found"; return; }
  local out dest dr_loc region_ok=FAIL repl_ok=FAIL
  out=$(aws s3api get-bucket-replication --bucket "$EVENTS_BUCKET" 2>&1)
  dest=$(echo "$out" | jq -r '[.ReplicationConfiguration.Rules[]?.Destination.Bucket // empty]|join(",")' 2>/dev/null)
  # replication destination ARN should reference the resolved DR bucket
  echo "$dest" | grep -q "$DR_BUCKET" && repl_ok=PASS
  # LocationConstraint: us-west-2 -> "us-west-2"; us-east-1 -> "None"
  dr_loc=$(aws s3api get-bucket-location --bucket "$DR_BUCKET" --query 'LocationConstraint' --output text 2>&1)
  [ "$dr_loc" = "$DR_REGION" ] && region_ok=PASS
  if [ "$repl_ok" = "PASS" ] && [ "$region_ok" = "PASS" ]; then RESULT=PASS; else RESULT=FAIL; fi
  DESC="source=$EVENTS_BUCKET -> repl dest=${dest:-none} (match DR=$repl_ok); DR bucket=$DR_BUCKET region=$dr_loc (expected $DR_REGION, $region_ok)"$'\n'"$out"
}

# C.4 - The 'rate-api' Lambda function is deployed in the VPC (this exact
#  function, not any other). PASS only if rate-api exists and has a VpcConfig.
check_C4() {
  local out vpc
  out=$(aws lambda get-function-configuration --region "$REGION" --function-name "$LAMBDA_NAME" \
        --query '{Function:FunctionName,VpcId:VpcConfig.VpcId,Subnets:VpcConfig.SubnetIds,SGs:VpcConfig.SecurityGroupIds}' 2>&1)
  if echo "$out" | grep -qi 'ResourceNotFoundException\|Function not found'; then
    RESULT=FAIL; DESC="Lambda function '$LAMBDA_NAME' not found"; return
  fi
  vpc=$(echo "$out" | jq -r '.VpcId' 2>/dev/null)
  if [ -n "$vpc" ] && [ "$vpc" != "null" ]; then RESULT=PASS; else RESULT=FAIL; fi
  DESC="$out"
}

# C.5 - Admission control blocks bad pods (Kubernetes-level).
#  Manual: apply the attached pod-c5.yaml (label mealmint/dev: dev) and
#  confirm admission control REJECTS it (rejection = PASS).
check_C5() {
  RESULT=None
  DESC="Perform it manually. It cannot be automated. Apply the attached pod-c5.yaml (kubectl apply -f pod-c5.yaml); the Pod has label 'mealmint/dev: dev' and must be DENIED by admission control. Rejected = PASS, created = FAIL."
}

# =====================================================================
#  D. Operations (Judgement - manual; we just surface the URL to open)
# =====================================================================

# Echo "https://<cloudfront-domain>" for the distribution whose Name tag
# equals $1 (falls back to matching the distribution Comment). Empty if none.
cf_url_by_name() {
  local name="$1" arn id domain
  arn=$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
        --resource-type-filters cloudfront:distribution \
        --tag-filters "Key=Name,Values=$name" \
        --query 'ResourceTagMappingList[0].ResourceARN' --output text 2>/dev/null)
  [ -n "$arn" ] && [ "$arn" != "None" ] && id=${arn##*/}
  if [ -z "${id:-}" ]; then   # fallback: match by Comment
    id=$(aws cloudfront list-distributions \
         --query "DistributionList.Items[?contains(Comment, '$name')].Id | [0]" --output text 2>/dev/null)
    [ "$id" = "None" ] && id=""
  fi
  [ -z "${id:-}" ] && return 1
  domain=$(aws cloudfront get-distribution --id "$id" \
           --query 'Distribution.DomainName' --output text 2>/dev/null)
  [ -z "$domain" -o "$domain" = "None" ] && return 1
  echo "https://$domain"
}

# D.1 - mealmint dashboard (judgement). Output the static-cf CloudFront URL.
check_D1() {
  local url; url=$(cf_url_by_name "$CF_STATIC_NAME")
  RESULT=None
  DESC="Perform it manually. It cannot be automated. ${url:-CloudFront with Name '$CF_STATIC_NAME' not found.}"
}

# D.2 - Mealmint API (judgement). Output both CloudFront URLs (static & api).
check_D2() {
  local static_url api_url
  static_url=$(cf_url_by_name "$CF_STATIC_NAME")
  api_url=$(cf_url_by_name "$CF_API_NAME")
  RESULT=None
  DESC="Perform it manually. It cannot be automated. static=${static_url:-not found}, api=${api_url:-not found}"
}

# =====================================================================
#  Runner
# =====================================================================
ALL_IDS=(A.1 A.2 A.3 A.4 A.5 A.6 A.7 \
         B.1 B.2 B.3 B.4 B.5 B.6 B.7 B.8 \
         C.1 C.2 C.3 C.4 C.5 \
         D.1 D.2)

run_one() {
  local id="$1" fn
  fn="check_${id//./}"
  RESULT="FAIL"; DESC="(no output)"
  if declare -F "$fn" >/dev/null; then
    "$fn"
  else
    RESULT="SKIP"; DESC="No check implemented for $id"
  fi
  report "$id" "$RESULT" "$DESC"
}

main() {
  local ids=("$@")
  [ ${#ids[@]} -eq 0 ] && ids=("${ALL_IDS[@]}")
  echo "# AWS region: $REGION   DR region: $DR_REGION   project: $PROJECT" >&2
  echo "# Identity: $(aws sts get-caller-identity --query Arn --output text 2>/dev/null)" >&2

  # Discover all shared resources ONCE; values are inherited by the
  # parallel check subshells below (no repeated VPC/EKS/... lookups).
  prefetch
  echo "# VPC=$VPC_ID  EKS=$EKS_CLUSTER  DocDB=$DOCDB_CLUSTER  Bucket=$EVENTS_BUCKET  Zone=$ZONE_ID" >&2
  echo >&2

  # Run checks in parallel (throttled to MAXJOBS), preserving output order
  # by writing each result to an indexed temp file, then concatenating.
  # WORKDIR is a global so the EXIT trap can still see it (set -u safe).
  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/marking.XXXXXX")
  trap 'rm -rf "${WORKDIR:-}"' EXIT
  local i=0
  for id in "${ids[@]}"; do
    run_one "$id" >"$WORKDIR/$(printf '%03d' "$i").out" 2>/dev/null &
    i=$((i + 1))
    # throttle: wait while at/over the concurrency limit (bash 3.2 safe)
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$MAXJOBS" ]; do
      sleep 0.1
    done
  done
  wait

  for f in "$WORKDIR"/*.out; do
    cat "$f"
  done
}

main "$@"
