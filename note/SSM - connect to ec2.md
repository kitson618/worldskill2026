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