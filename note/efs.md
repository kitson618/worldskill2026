## Create Security Group

```bash
export VPC_ID=vpc-0895baaccde483578
export SOURCE_SECURITY_GROUP=sg-0303c88cea433f797

SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --description "EFS security group" \
    --group-name efs-security-group \
    --vpc-id $VPC_ID \
    --query 'GroupId' \
    --output text)
    
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 2049 \
    --source-group $SOURCE_SECURITY_GROUP

aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 2049 \
    --cidr 0.0.0.0/0
```

## Create EFS

```bash
EFS_ID=$(aws efs create-file-system \
    --performance-mode generalPurpose \
    --encrypted \
    --tags Key=Name,Value=lab-efs \
    --query 'FileSystemId' \
    --output text)
```

```bash
export PRI_SUBNET_ID1=subnet-0d838141598732521
export PRI_SUBNET_ID2=subnet-094fdbd6358797b09

aws efs create-mount-target \
    --file-system-id $EFS_ID \
    --subnet-id $PRI_SUBNET_ID1 \
    --security-groups $SECURITY_GROUP_ID

aws efs create-mount-target \
    --file-system-id $EFS_ID \
    --subnet-id $PRI_SUBNET_ID2 \
    --security-groups $SECURITY_GROUP_ID
```

## EFS Full Access

```bash
POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Id": "efs-policy-full-policy-123321",
    "Statement": [
        {
            "Sid": "efs-statement-123321",
            "Effect": "Allow",
            "Principal": {
                "AWS": "*"
            },
            "Action": [
                "elasticfilesystem:ClientRootAccess",
                "elasticfilesystem:ClientWrite",
                "elasticfilesystem:ClientMount"
            ],
            "Condition": {
                "Bool": {
                    "elasticfilesystem:AccessedViaMountTarget": "true"
                }
            }
        }
    ]
}
EOF
)

aws efs put-file-system-policy \
    --file-system-id $EFS_ID \
    --policy "$POLICY"
```

## Attach to EC2

```bash
export MOUNT_DIR=/mnt/efs
export EFS_DNS=fs-018f328936e9261e8.efs.us-east-1.amazonaws.com

sudo mkdir $MOUNT_DIR
sudo chmod 777 $MOUNT_DIR
```

```bash
sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport $EFS_DNS:/ $MOUNT_DIR
```