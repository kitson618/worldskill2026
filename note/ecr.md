## Create Repository

```bash
export ECR_REPO_NAME=server01
aws ecr create-repository \
    --repository-name $ECR_REPO_NAME \
    --image-tag-mutability IMMUTABLE \
    --image-scanning-configuration scanOnPush=true
```

## Push Image to ECR

```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 608671652196.dkr.ecr.us-east-1.amazonaws.com
docker tag server01:latest 608671652196.dkr.ecr.us-east-1.amazonaws.com/server01:latest
docker push 608671652196.dkr.ecr.us-east-1.amazonaws.com/server01:latest
```