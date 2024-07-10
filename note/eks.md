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

```bash
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Effect": "Allow",
			"Principal": {
				"Federated": "arn:aws:iam::608671652196:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/A0996CD74BA1157A5F291E813BE05705"
			},
			"Action": "sts:AssumeRoleWithWebIdentity",
			"Condition": {
				"StringLike": {
					"oidc.eks.us-east-1.amazonaws.com/id/A0996CD74BA1157A5F291E813BE05705:sub": "system:serviceaccount:kube-system:efs-csi-*",
					"oidc.eks.us-east-1.amazonaws.com/id/A0996CD74BA1157A5F291E813BE05705:aud": "sts.amazonaws.com"
				}
			}
		}
	]
}
```

```bash
AmazonEFSCSIDriverPolicy
```

## SC

```yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-0e2e05c3423f62ffc
  directoryPerms: "700"
  gidRangeStart: "1000" # optional
  gidRangeEnd: "2000" # optional
  basePath: "/data" # optional
  ensureUniqueDirectory: "true" # optional
  reuseAccessPoint: "false" # optional
  subPathPattern: "${.PVC.namespace}/${.PVC.name}" # optional
```

## Deployment

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-claim
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: efs-app
spec:
  containers:
    - name: app
      image: centos
      command: ["/bin/sh"]
      args: ["-c", "while true; do echo $(date -u) >> /data/out; sleep 5; done"]
      volumeMounts:
        - name: persistent-storage
          mountPath: /mnt/efs
  volumes:
    - name: persistent-storage
      persistentVolumeClaim:
        claimName: efs-claim
```

## Create nginx-ingress-controller

```bash
# Create the namespace
kubectl create namespace nginx-ingress-ns

# Add the Bitnami Helm repository
helm repo add bitnami https://charts.bitnami.com/bitnami

# Update the Helm repositories
helm repo update

# Install the NGINX Ingress Controller
helm install nginx-ingress-controller-release bitnami/nginx-ingress-controller \
  --version 9.3.0 \
  --namespace nginx-ingress-ns \
  --set service.type=LoadBalancer \
  --set service.publishService.enabled=true \
  --set-string service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-backend-protocol"="http" \
  --set-string service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-proxy-protocol"="*" \
  --set-string service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-cross-zone-load-balancing-enabled"="true" \
  --set-string service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb" \
  --set-string service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"="internet-facing"

```

## Connect with kubeconfig.yaml

```bash
export KUBECONFIG=$PWD/k8s-config/edge-kubeconfig.yml
```


## Helm

```
helm create lab1
helm install lab  . -n lab  --create-namespace

```