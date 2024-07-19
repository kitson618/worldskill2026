## **Create a VPC and capture the VPC ID**

```jsx
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "ACCOUNT_ID=$ACCOUNT_ID"

VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=LabVpc
echo "VPC_ID=$VPC_ID"
```

## **Create Subnets and capture their IDs**:

```jsx
# Public Subnets
PUB_SUBNET1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone us-east-1a --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $PUB_SUBNET1 --tags Key=Name,Value=PublicSubnet1
PUB_SUBNET2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 --availability-zone us-east-1b --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $PUB_SUBNET2 --tags Key=Name,Value=PublicSubnet2

# Private Subnets
PRI_SUBNET1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.3.0/24 --availability-zone us-east-1a --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $PRI_SUBNET1 --tags Key=Name,Value=PrivateSubnet1
PRI_SUBNET2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.4.0/24 --availability-zone us-east-1b --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $PRI_SUBNET2 --tags Key=Name,Value=PrivateSubnet2

# Database Subnets
DB_SUBNET1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.5.0/24 --availability-zone us-east-1a --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $DB_SUBNET1 --tags Key=Name,Value=DatabaseSubnet1
DB_SUBNET2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.6.0/24 --availability-zone us-east-1b --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $DB_SUBNET2 --tags Key=Name,Value=DatabaseSubnet2

echo "PUB_SUBNET1=$PUB_SUBNET1"
echo "PUB_SUBNET2=$PUB_SUBNET2"
echo "PRI_SUBNET1=$PRI_SUBNET1"
echo "PRI_SUBNET2=$PRI_SUBNET2"
echo "DB_SUBNET1=$DB_SUBNET1"
echo "DB_SUBNET2=$DB_SUBNET2"
```

## **Create Internet Gateway and Attach to VPC**

```jsx
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID
aws ec2 create-tags --resources $IGW_ID --tags Key=Name,Value=MyInternetGateway
echo "IGW_ID=$IGW_ID"
```

## **Create and Attach Route Tables**

```jsx
# Public Route Table
PUB_RTB=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $PUB_RTB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $PUB_RTB --subnet-id $PUB_SUBNET1
aws ec2 associate-route-table --route-table-id $PUB_RTB --subnet-id $PUB_SUBNET2
aws ec2 create-tags --resources $PUB_RTB --tags Key=Name,Value=PublicRouteTable

# Private Route Table
PRI_RTB=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 associate-route-table --route-table-id $PRI_RTB --subnet-id $PRI_SUBNET1
aws ec2 associate-route-table --route-table-id $PRI_RTB --subnet-id $PRI_SUBNET2
aws ec2 create-tags --resources $PRI_RTB --tags Key=Name,Value=PrivateRouteTable

echo "PUB_RTB=$PUB_RTB"
echo "PRI_RTB=$PRI_RTB"
```

## **Create NAT Gateways**

```jsx
# Allocate Elastic IP for NAT Gateway
EIP1=$(aws ec2 allocate-address --query 'AllocationId' --output text)
EIP2=$(aws ec2 allocate-address --query 'AllocationId' --output text)

# Create NAT Gateways
NAT_GW1=$(aws ec2 create-nat-gateway --subnet-id $PUB_SUBNET1 --allocation-id $EIP1 --query 'NatGateway.NatGatewayId' --output text)
aws ec2 create-tags --resources $NAT_GW1 --tags Key=Name,Value=NATGateway1
NAT_GW2=$(aws ec2 create-nat-gateway --subnet-id $PUB_SUBNET2 --allocation-id $EIP2 --query 'NatGateway.NatGatewayId' --output text)
aws ec2 create-tags --resources $NAT_GW2 --tags Key=Name,Value=NATGateway2

# Update Private Route Table to use NAT Gateway
aws ec2 create-route --route-table-id $PRI_RTB --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_GW1
aws ec2 create-route --route-table-id $PRI_RTB --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_GW2

echo "NAT_GW1=$NAT_GW1"
echo "NAT_GW2=$NAT_GW2"
```

## **Create IAM Role with Least Privilege for VPC Flow Logs**

```jsx
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "vpc-flow-logs.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
} 

```

```jsx
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents",
                "logs:DescribeLogGroups",
                "logs:DescribeLogStreams",
                "s3:PutObject",
                "s3:GetBucketLocation"
            ],
            "Resource": [
                "arn:aws:logs:*:*:log-group:VPCFlowLogs:*"
            ]
        }
    ]
}
```

```jsx
# Create the IAM Role
aws iam create-role --role-name VPCFlowLogRole --assume-role-policy-document file://trust-policy.json

# Attach the policy
aws iam put-role-policy --role-name VPCFlowLogRole --policy-name VPCFlowLogPolicy --policy-document file://vpc-flow-log-policy.json

```

```bash
aws ec2 create-flow-logs --resource-type VPC --resource-ids $VPC_ID --traffic-type ALL --log-group-name VPCFlowLogs --deliver-logs-permission-arn arn:aws:iam::$ACCOUNT_ID:role/VPCFlowLogRole
```



## **S3 VPC Flow Log**

```json
{
    "Version": "2012-10-17",
    "Id": "AWSLogDeliveryWrite20150319",
    "Statement": [
        {
            "Sid": "AWSLogDeliveryWrite",
            "Effect": "Allow",
            "Principal": {
                "Service": "delivery.logs.amazonaws.com"
            },
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::template-logging-608671652196/AWSLogs/aws-account-id=608671652196/*",
            "Condition": {
                "StringEquals": {
                    "aws:SourceAccount": "608671652196",
                    "s3:x-amz-acl": "bucket-owner-full-control"
                },
                "ArnLike": {
                    "aws:SourceArn": "arn:aws:logs:us-east-1:608671652196:*"
                }
            }
        },
        {
            "Sid": "AWSLogDeliveryAclCheck",
            "Effect": "Allow",
            "Principal": {
                "Service": "delivery.logs.amazonaws.com"
            },
            "Action": "s3:GetBucketAcl",
            "Resource": "arn:aws:s3:::template-logging-608671652196",
            "Condition": {
                "StringEquals": {
                    "aws:SourceAccount": "608671652196"
                },
                "ArnLike": {
                    "aws:SourceArn": "arn:aws:logs:us-east-1:608671652196:*"
                }
            }
        }
    ]
}
```