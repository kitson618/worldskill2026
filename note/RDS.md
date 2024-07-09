## Create Database Subnet Group

```bash
aws rds create-db-subnet-group \
--db-subnet-group-name database-subnet-group \
--db-subnet-group-description "DB Subnet Group" \
--subnet-ids subnet-0dfe0aa1e7e28c439 subnet-001b2fc285e333cbc
```

## Create Security Group

```bash
export VPC_ID=vpc-0895baaccde483578

SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --description "database security group" \
    --group-name database-security-group \
    --vpc-id $VPC_ID \
    --query 'GroupId' \
    --output text)

# Authorize inbound traffic on port 3306
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 3306 \
    --cidr 10.0.0.0/16
```

| Type | Port |
| --- | --- |
| MySQL | 3306 |
| PostgreSQL | 5432 |
| Oracle | 1521 |
| Microsoft SQL Server | 1433 |

##