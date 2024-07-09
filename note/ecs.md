## Create Cluster

```bash
aws ecs create-cluster --cluster-name efs-lab-cluster
```

## Create Task & Task execute Role

```bash
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

```bash
aws iam create-role --role-name ecsTaskRole --assume-role-policy-document file://ecs-task-trust-policy.json
aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document file://ecs-task-trust-policy.json
```

```bash
aws iam attach-role-policy --role-name ecsTaskExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
```

## Task-definition

```bash
{
  "family": "efs-lab-task",
  "networkMode": "awsvpc",
  "containerDefinitions": [
    {
      "name": "efs-lab-container",
      "image": "<account-id>.dkr.ecr.<region>.amazonaws.com/efs-lab:latest",
      "memory": 512,
      "cpu": 256,
      "essential": true,
      "portMappings": [
        {
          "containerPort": 3000,
          "hostPort": 3000,
          "protocol": "tcp"
        }
      ],
      "mountPoints": [
        {
          "sourceVolume": "efs-volume",
          "containerPath": "/mnt/efs"
        }
      ]
    }
  ],
  "volumes": [
    {
      "name": "efs-volume",
      "efsVolumeConfiguration": {
        "fileSystemId": "<your-efs-filesystem-id>"
      }
    }
  ],
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "taskRoleArn": "arn:aws:iam::<account-id>:role/ecsTaskRole",
  "executionRoleArn": "arn:aws:iam::<account-id>:role/ecsTaskExecutionRole"
}
```