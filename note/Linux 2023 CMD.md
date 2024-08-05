## Create security group

```bash
# Get your current public IP address
MY_IP=$(curl -s http://checkip.amazonaws.com)
MY_VPC_ID=vpc-0895baaccde483578

# Create the security group and capture the security group ID
SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --description "SSH access security group" \
    --group-name ssh-access-security-group \
    --vpc-id $MY_VPC_ID \
    --query 'GroupId' \
    --output text)

# Authorize inbound SSH traffic from your current IP
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 22 \
    --cidr $MY_IP/32
```

## Install Mysql

```bash
sudo wget https://dev.mysql.com/get/mysql80-community-release-el9-1.noarch.rpm
sudo dnf install mysql80-community-release-el9-1.noarch.rpm -y
sudo rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2023
sudo dnf install mysql-community-client -y
```

```bash
USERNAME=cloudraiser
PASSWORD=cloudraiser
HOSTNAMEORIP=cloudraiser.c7ynqw1udxwr.us-east-1.rds.amazonaws.com
DATABASENAME=cloudraiser
mysql -u $USERNAME -p$PASSWORD -h $HOSTNAMEORIP $DATABASENAME 
```

## Install Helm

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
```

## Linux Install Docker

```bash
sudo yum update -y
sudo yum install -y docker
sudo service docker start
sudo usermod -a -G docker ec2-user
```

```bash
sudo curl -L https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```

## NAT Instance

```bash
sudo yum install iptables-services -y
sudo systemctl enable iptables
sudo systemctl start iptables
```

```bash
nano /etc/sysctl.d/custom-ip-forwarding.conf
```

```bash
net.ipv4.ip_forward=1
```

```bash
sudo sysctl -p /etc/sysctl.d/custom-ip-forwarding.conf
```

```bash
sudo /sbin/iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
sudo /sbin/iptables -F FORWARD
sudo service iptables save
```

```bash
# install iptable
sudo yum install iptables-services -y
sudo systemctl enable iptables
sudo systemctl start iptables

# Turning on IP Forwarding
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Making a catchall rule for routing and masking the private IP
# Amazon Linux 2023 primay network interface is ens5
sudo iptables -t nat -A POSTROUTING -o ens5 -s 0.0.0.0/0 -j MASQUERADE
sudo /sbin/iptables -F FORWARD
sudo service iptables save
```


```
sudo cat /var/log/cloud-init-output.log