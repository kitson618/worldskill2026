```bash
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ssm:UpdateInstanceInformation",
                "ssmmessages:CreateControlChannel",
                "ssmmessages:CreateDataChannel",
                "ssmmessages:OpenControlChannel",
                "ssmmessages:OpenDataChannel"
            ],
            "Resource": "*"
        }
    ]
}
```

```bash
arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy
arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

```yaml
com.amazonaws.[region].ssm
com.amazonaws.[region].ec2messages
com.amazonaws.[region].ssmmessages
```

## Check what is my ip

```yaml
curl ipinfo.io
```


## Check what is my ip

```yaml
Content-Type: multipart/mixed; boundary="//"
MIME-Version: 1.0

--//
Content-Type: text/cloud-config; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="cloud-config.txt"

#cloud-config
cloud_final_modules:
- [users-groups, once]
users:
  - name: username
    ssh-authorized-keys: 
    - PublicKeypair

```


```
 #!/bin/bash
 yum update -y
 sudo su
 cd /root
 yum update -y
 yum install -y docker
 service docker start
 usermod -a -G docker ec2-user
 curl -L https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose
 chmod +x /usr/local/bin/docker-compose
 wget https://dev.mysql.com/get/mysql80-community-release-el9-1.noarch.rpm
 dnf install mysql80-community-release-el9-1.noarch.rpm -y
 rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2023
 dnf install mysql-community-client -y
 rm -f mysql80-community-release-el9-1.noarch.rpm
 yum install libxcrypt-compat -y
```