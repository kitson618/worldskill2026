## IAM Role - Cluster

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

```bash
aws iam create-role --role-name EKSClusterRole --assume-role-policy-document file://eks-cluster-trust-policy.json
aws iam attach-role-policy --role-name EKSClusterRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
aws iam attach-role-policy --role-name EKSClusterRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSServicePolicy
```

## IAM Role - Node Group

```bash
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

```bash
aws iam create-role --role-name EKSNodeGroupRole --assume-role-policy-document file://eks-nodegroup-trust-policy.json
aws iam attach-role-policy --role-name EKSNodeGroupRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam attach-role-policy --role-name EKSNodeGroupRole --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
aws iam attach-role-policy --role-name EKSNodeGroupRole --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
```

## OIDC config IAM

```bash
##Provider URL
https://oidc.eks.us-east-1.amazonaws.com/id/A0996CD74BA1157A5F291E813BE05705

##Audience
sts.amazonaws.com
```

## Connect eks

```bash
aws eks update-kubeconfig --name eks_name --region=us-east-1 --role-arn arn:aws:iam::608671652196:role/EKSClusterRole
```

[EFS CSI Driver](https://www.notion.so/EFS-CSI-Driver-6857a627eddb47fe990d74aae23bc161?pvs=21)

## Create nginx-ingress-controller

```bash
kubectl create ns nginx-ingress-ns
helm repo add bitnami-repo https://charts.bitnami.com/bitnami

helm install nginx-ingress-controller bitnami-repo/nginx-ingress-controller \
--namespace nginx-ingress-ns \
--set service.type=LoadBalancer \
--set service.publishService.enabled=true \
--set service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-proxy-protocol"='*' \
--set service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=nlb \
--set service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-internal"=true \

```