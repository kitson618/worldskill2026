aws s3 cp s3://bash-file-158481908025/ws-ec2-root .
aws s3 cp s3://bash-file-158481908025/server-lookup.ini .
aws s3 cp s3://bash-file-158481908025/server-root.ini .
aws s3 cp s3://bash-file-158481908025/ws-ec2-lookup .

#!/bin/bash
yum update -y
sudo su
cd /root
aws s3 cp s3://bash-file-158481908025/server-root.ini ./server.ini
aws s3 cp s3://bash-file-158481908025/ws-ec2-root .
chmod 700 ws-ec2-root
./ws-ec2-root


#!/bin/bash
yum update -y
sudo su
cd /root
aws s3 cp s3://bash-file-158481908025/server-lookup.ini ./server.ini
aws s3 cp s3://bash-file-158481908025/ws-ec2-lookup .
chmod 700 ws-ec2-lookup
./ws-ec2-lookup