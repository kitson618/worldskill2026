# cloud raiser url
http://cloudraiser-dev3-292608829.us-east-1.elb.amazonaws.com/login

# login information
202406200925,lab_user4,12922372,HK-TEAM


sudo wget https://dev.mysql.com/get/mysql80-community-release-el9-1.noarch.rpm
sudo dnf install mysql80-community-release-el9-1.noarch.rpm -y
sudo rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2023
sudo dnf install mysql-community-client -y
curl -O https://alb-log-bucket-851725623384.s3.amazonaws.com/server02.zip
mysql -u cloudraiser -pcloudraiser -h cloudraiser.cbokk0csqoc7.us-east-1.rds.amazonaws.com cloudraiser
yum install libxcrypt-compat -y