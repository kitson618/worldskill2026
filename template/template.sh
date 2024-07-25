$AWS_REGION = "us-east-1"

# Set your environment name
$ENV_NAME = "template"

# VPC
$VPC_ID = (aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$ENV_NAME

# Enable DNS support and hostnames for the VPC
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames '{"Value":true}'

# Internet Gateway
$IGW_ID = (aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID

# Subnets
$PUBLIC_SUBNET1_ID = (aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.10.0/24 --availability-zone ${AWS_REGION}a --query 'Subnet.SubnetId' --output text)
$PUBLIC_SUBNET2_ID = (aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.11.0/24 --availability-zone ${AWS_REGION}b --query 'Subnet.SubnetId' --output text)
$PRIVATE_SUBNET1_ID = (aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.20.0/24 --availability-zone ${AWS_REGION}a --query 'Subnet.SubnetId' --output text)
$PRIVATE_SUBNET2_ID = (aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.21.0/24 --availability-zone ${AWS_REGION}b --query 'Subnet.SubnetId' --output text)
$ISOLATED_SUBNET1_ID = (aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.30.0/24 --availability-zone ${AWS_REGION}a --query 'Subnet.SubnetId' --output text)
$ISOLATED_SUBNET2_ID = (aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.31.0/24 --availability-zone ${AWS_REGION}b --query 'Subnet.SubnetId' --output text)

# Route Tables
$PUBLIC_RT_ID = (aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
$PRIVATE_RT_ID = (aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
$ISOLATED_RT_ID = (aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)

# Routes
aws ec2 create-route --route-table-id $PUBLIC_RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID

# Associate Route Tables with Subnets
aws ec2 associate-route-table --subnet-id $PUBLIC_SUBNET1_ID --route-table-id $PUBLIC_RT_ID
aws ec2 associate-route-table --subnet-id $PUBLIC_SUBNET2_ID --route-table-id $PUBLIC_RT_ID
aws ec2 associate-route-table --subnet-id $PRIVATE_SUBNET1_ID --route-table-id $PRIVATE_RT_ID
aws ec2 associate-route-table --subnet-id $PRIVATE_SUBNET2_ID --route-table-id $PRIVATE_RT_ID
aws ec2 associate-route-table --subnet-id $ISOLATED_SUBNET1_ID --route-table-id $ISOLATED_RT_ID
aws ec2 associate-route-table --subnet-id $ISOLATED_SUBNET2_ID --route-table-id $ISOLATED_RT_ID

# NAT Gateway
$EIP_ALLOC_ID = (aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
$NAT_GW_ID = (aws ec2 create-nat-gateway --subnet-id $PUBLIC_SUBNET1_ID --allocation-id $EIP_ALLOC_ID --query 'NatGateway.NatGatewayId' --output text)

# Wait for NAT Gateway to be available
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW_ID

# Add route to NAT Gateway in private route table
aws ec2 create-route --route-table-id $PRIVATE_RT_ID --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_GW_ID

# S3 Bucket for VPC Flow Logs
$ACCOUNT_ID = (aws sts get-caller-identity --query 'Account' --output text)
$FLOW_LOG_BUCKET = "${ENV_NAME}-vpcflowlog-logging-${ACCOUNT_ID}"
aws s3 mb "s3://${FLOW_LOG_BUCKET}" --region $AWS_REGION
aws s3api put-bucket-versioning --bucket $FLOW_LOG_BUCKET --versioning-configuration Status=Enabled

# Enable VPC Flow Logs
$FLOW_LOG_ROLE_ARN = (aws iam create-role --role-name flow-logs-role --assume-role-policy-document '{"Version": "2012-10-17","Statement": [{"Effect": "Allow","Principal": {"Service": "vpc-flow-logs.amazonaws.com"},"Action": "sts:AssumeRole"}]}' --query 'Role.Arn' --output text)
aws iam put-role-policy --role-name flow-logs-role --policy-name flow-logs-policy --policy-document '{"Version": "2012-10-17","Statement": [{"Effect": "Allow","Action": ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogGroups","logs:DescribeLogStreams"],"Resource": "*"}]}'

aws ec2 create-flow-logs --resource-type VPC --resource-ids $VPC_ID --traffic-type ALL --log-destination-type s3 --log-destination "arn:aws:s3:::${FLOW_LOG_BUCKET}"

# Create a security group for the bastion host
$BASTION_SG_ID = (aws ec2 create-security-group --group-name BastionSG --description "Security group for Bastion Host" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $BASTION_SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0

# Create a key pair for EC2 instances
$KEY_NAME = "${ENV_NAME}-keypair"
aws ec2 create-key-pair --key-name $KEY_NAME --query 'KeyMaterial' --output text | Out-File -Encoding ascii -FilePath "${KEY_NAME}.pem"

# Set appropriate permissions for the key file (PowerShell equivalent of chmod 400)
$acl = Get-Acl "${KEY_NAME}.pem"
$acl.SetAccessRuleProtection($true, $false)
$adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrator","FullControl","Allow")
$acl.SetAccessRule($adminRule)
$acl | Set-Acl "${KEY_NAME}.pem"

# Launch Bastion Host
$BASTION_INSTANCE_ID = (aws ec2 run-instances --image-id ami-0b72821e2f351e396 --count 1 --instance-type t3.micro --key-name $KEY_NAME --security-group-ids $BASTION_SG_ID --subnet-id $PUBLIC_SUBNET1_ID --associate-public-ip-address --query 'Instances[0].InstanceId' --output text)

# Create Application Load Balancer
$ALB_SG_ID = (aws ec2 create-security-group --group-name ALBSG --description "Security group for ALB" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $ALB_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0

$ALB_ARN = (aws elbv2 create-load-balancer --name "${ENV_NAME}-alb" --subnets $PUBLIC_SUBNET1_ID $PUBLIC_SUBNET2_ID --security-groups $ALB_SG_ID --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Create target group
$TG_ARN = (aws elbv2 create-target-group --name "${ENV_NAME}-tg" --protocol HTTP --port 80 --vpc-id $VPC_ID --query 'TargetGroups[0].TargetGroupArn' --output text)

# Create listener
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TG_ARN

# Create DynamoDB table
aws dynamodb create-table --table-name "${ENV_NAME}-table" --attribute-definitions AttributeName=id,AttributeType=S --key-schema AttributeName=id,KeyType=HASH --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5

# Create ECS Cluster
aws ecs create-cluster --cluster-name "${ENV_NAME}-cluster"

# Create ECR Repository
aws ecr create-repository --repository-name "${ENV_NAME}-repo" --image-scanning-configuration scanOnPush=true

Write-Host "Basic infrastructure has been created."
