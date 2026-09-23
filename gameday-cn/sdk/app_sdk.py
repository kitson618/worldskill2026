#!/usr/bin/env python3
"""Unicorn GameDay — boto3 equivalent of app.yml, one function per section.

Teaching walkthrough: ../sdk/README.md
CLI equivalent:       ../app.sh

    pip install boto3
    python3 app_sdk.py

Creates billable resources (NAT Gateway, DocumentDB, CloudFront).
Does not upload ws-ec2-pipeline-server; do that after the bucket exists.
"""

from __future__ import annotations

import base64
import io
import json
import time
import zipfile

import boto3
from botocore.exceptions import ClientError


# --- shared config (app.yml Parameters) ------------------------------------

REGION = "us-east-1"
ENV_NAME = "Unicorn"
VPC_CIDR = "10.0.0.0/16"
PUBLIC_CIDRS = ("10.0.10.0/24", "10.0.11.0/24")
PRIVATE_CIDRS = ("10.0.20.0/24", "10.0.21.0/24")
AMI_ID = "ami-0b72821e2f351e396"
KEY_NAME = "gameday-key"
LAMBDA_ROLE_NAME = "MyLambdaExecutionRole"
EC2_ROLE_NAME = "WSEC2Role"
BASTION_SSH_CIDR = "119.237.240.242/32"
CACHE_QUERY_STRING = "input-SUNhbkhhelVuaWNvem40LTY3NDkSY"
DOCDB_INSTANCE_CLASS = "db.t3.medium"


def clients(region: str = REGION) -> dict:
    """One Session, one client per service. Pass this dict between sections."""
    session = boto3.Session(region_name=region)
    names = (
        "ec2", "s3", "iam", "lambda", "apigateway", "elbv2",
        "cloudfront", "autoscaling", "secretsmanager", "docdb", "appconfig", "sts",
    )
    ctx = {name: session.client(name) for name in names}
    ctx["region"] = region
    ctx["account_id"] = ctx["sts"].get_caller_identity()["Account"]
    ctx["bucket"] = f"gameday-{ctx['account_id']}"
    return ctx


def _exists(fn) -> bool:
    try:
        fn()
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] in {
            "NoSuchEntity", "NoSuchEntityException", "InvalidKeyPair.NotFound",
        }:
            return False
        raise


# --- 1. Network -------------------------------------------------------------

def build_network(ctx: dict) -> None:
    """VPC, two public + two private subnets, one NAT, shared route tables.

    CloudFormation !Ref / !GetAtt becomes: save the ID, pass it to the next call.
    """
    ec2 = ctx["ec2"]
    azs = ec2.describe_availability_zones(
        Filters=[{"Name": "state", "Values": ["available"]}]
    )["AvailabilityZones"]
    az1, az2 = azs[0]["ZoneName"], azs[1]["ZoneName"]

    vpc_id = ec2.create_vpc(CidrBlock=VPC_CIDR)["Vpc"]["VpcId"]
    ec2.modify_vpc_attribute(VpcId=vpc_id, EnableDnsSupport={"Value": True})
    ec2.modify_vpc_attribute(VpcId=vpc_id, EnableDnsHostnames={"Value": True})
    ec2.create_tags(Resources=[vpc_id], Tags=[{"Key": "Name", "Value": ENV_NAME}])

    igw_id = ec2.create_internet_gateway()["InternetGateway"]["InternetGatewayId"]
    ec2.create_tags(Resources=[igw_id], Tags=[{"Key": "Name", "Value": ENV_NAME}])
    ec2.attach_internet_gateway(InternetGatewayId=igw_id, VpcId=vpc_id)

    def subnet(cidr: str, az: str, public: bool, name: str) -> str:
        subnet_id = ec2.create_subnet(
            VpcId=vpc_id, CidrBlock=cidr, AvailabilityZone=az
        )["Subnet"]["SubnetId"]
        if public:
            ec2.modify_subnet_attribute(
                SubnetId=subnet_id, MapPublicIpOnLaunch={"Value": True}
            )
        ec2.create_tags(Resources=[subnet_id], Tags=[{"Key": "Name", "Value": name}])
        return subnet_id

    pub1 = subnet(PUBLIC_CIDRS[0], az1, True, f"{ENV_NAME} Public Subnet (AZ1)")
    pub2 = subnet(PUBLIC_CIDRS[1], az2, True, f"{ENV_NAME} Public Subnet (AZ2)")
    pri1 = subnet(PRIVATE_CIDRS[0], az1, False, f"{ENV_NAME} Private Subnet (AZ1)")
    pri2 = subnet(PRIVATE_CIDRS[1], az2, False, f"{ENV_NAME} Private Subnet (AZ2)")

    alloc = ec2.allocate_address(Domain="vpc")["AllocationId"]
    nat_id = ec2.create_nat_gateway(SubnetId=pub1, AllocationId=alloc)["NatGateway"]["NatGatewayId"]

    public_rt = ec2.create_route_table(VpcId=vpc_id)["RouteTable"]["RouteTableId"]
    private_rt = ec2.create_route_table(VpcId=vpc_id)["RouteTable"]["RouteTableId"]
    ec2.create_tags(Resources=[public_rt], Tags=[{"Key": "Name", "Value": f"{ENV_NAME} Public Routes"}])
    ec2.create_tags(Resources=[private_rt], Tags=[{"Key": "Name", "Value": f"{ENV_NAME} Private Routes (AZ1)"}])
    ec2.create_route(RouteTableId=public_rt, DestinationCidrBlock="0.0.0.0/0", GatewayId=igw_id)
    for subnet_id, table_id in (
        (pub1, public_rt), (pub2, public_rt), (pri1, private_rt), (pri2, private_rt)
    ):
        ec2.associate_route_table(RouteTableId=table_id, SubnetId=subnet_id)

    # NAT is asynchronous. A route created before state=available is rejected.
    ec2.get_waiter("nat_gateway_available").wait(NatGatewayIds=[nat_id])
    ec2.create_route(RouteTableId=private_rt, DestinationCidrBlock="0.0.0.0/0", NatGatewayId=nat_id)

    ctx.update(
        vpc_id=vpc_id, igw_id=igw_id,
        public_subnet_ids=(pub1, pub2), private_subnet_ids=(pri1, pri2),
        nat_gateway_id=nat_id,
    )


# --- 2. S3 + VPC Flow Logs --------------------------------------------------

def build_bucket_and_flow_logs(ctx: dict) -> None:
    """Encrypted, versioned bucket, then VPC flow logs delivered as Parquet."""
    s3, ec2 = ctx["s3"], ctx["ec2"]
    bucket = ctx["bucket"]
    if ctx["region"] == "us-east-1":
        s3.create_bucket(Bucket=bucket)
    else:
        s3.create_bucket(
            Bucket=bucket,
            CreateBucketConfiguration={"LocationConstraint": ctx["region"]},
        )
    s3.put_bucket_versioning(
        Bucket=bucket, VersioningConfiguration={"Status": "Enabled"}
    )
    s3.put_bucket_encryption(
        Bucket=bucket,
        ServerSideEncryptionConfiguration={
            "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
        },
    )
    s3.put_public_access_block(
        Bucket=bucket,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": True,
            "IgnorePublicAcls": True,
            "BlockPublicPolicy": True,
            "RestrictPublicBuckets": True,
        },
    )

    # $ in the format is literal AWS tokens, not Python interpolation.
    log_format = (
        "${version} ${vpc-id} ${subnet-id} ${instance-id} ${srcaddr} ${dstaddr} "
        "${srcport} ${dstport} ${protocol} ${tcp-flags} ${type} ${pkt-srcaddr} ${pkt-dstaddr}"
    )
    result = ec2.create_flow_logs(
        ResourceIds=[ctx["vpc_id"]],
        ResourceType="VPC",
        TrafficType="ALL",
        LogDestinationType="s3",
        LogDestination=f"arn:aws:s3:::{bucket}",
        LogFormat=log_format,
        MaxAggregationInterval=60,
        DestinationOptions={
            "FileFormat": "parquet",
            "HiveCompatiblePartitions": True,
            "PerHourPartition": True,
        },
    )
    if result.get("Unsuccessful"):
        raise RuntimeError(f"flow log create failed: {result['Unsuccessful']}")


# --- 3. IAM the template assumed already existed ----------------------------

def ensure_iam(ctx: dict) -> None:
    """app.yml references MyLambdaExecutionRole and WSEC2Role; it does not create them."""
    iam = ctx["iam"]
    if not _exists(lambda: iam.get_role(RoleName=LAMBDA_ROLE_NAME)):
        iam.create_role(
            RoleName=LAMBDA_ROLE_NAME,
            AssumeRolePolicyDocument=json.dumps({
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {"Service": "lambda.amazonaws.com"},
                    "Action": "sts:AssumeRole",
                }],
            }),
        )
        iam.attach_role_policy(
            RoleName=LAMBDA_ROLE_NAME,
            PolicyArn="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
        )
        iam.attach_role_policy(
            RoleName=LAMBDA_ROLE_NAME,
            PolicyArn="arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess",
        )
    ctx["lambda_role_arn"] = iam.get_role(RoleName=LAMBDA_ROLE_NAME)["Role"]["Arn"]

    bucket = ctx["bucket"]
    if not _exists(lambda: iam.get_role(RoleName=EC2_ROLE_NAME)):
        iam.create_role(
            RoleName=EC2_ROLE_NAME,
            AssumeRolePolicyDocument=json.dumps({
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {"Service": "ec2.amazonaws.com"},
                    "Action": "sts:AssumeRole",
                }],
            }),
        )
        iam.attach_role_policy(
            RoleName=EC2_ROLE_NAME,
            PolicyArn="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
        )
        iam.put_role_policy(
            RoleName=EC2_ROLE_NAME,
            PolicyName="unicorn-ec2",
            PolicyDocument=json.dumps({
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Action": ["s3:GetObject", "s3:ListBucket"],
                        "Resource": [f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"],
                    },
                    {
                        "Effect": "Allow",
                        "Action": ["secretsmanager:GetSecretValue", "ssm:GetParameter"],
                        "Resource": "*",
                    },
                    {
                        "Effect": "Allow",
                        "Action": [
                            "appconfig:StartConfigurationSession",
                            "appconfig:GetLatestConfiguration",
                            "appconfig:GetConfiguration",
                        ],
                        "Resource": "*",
                    },
                ],
            }),
        )
    if not _exists(lambda: iam.get_instance_profile(InstanceProfileName=EC2_ROLE_NAME)):
        iam.create_instance_profile(InstanceProfileName=EC2_ROLE_NAME, Path="/")
        iam.add_role_to_instance_profile(
            InstanceProfileName=EC2_ROLE_NAME, RoleName=EC2_ROLE_NAME
        )
        time.sleep(10)  # instance profile is not usable in the same second it is created
    profile = iam.get_instance_profile(InstanceProfileName=EC2_ROLE_NAME)["InstanceProfile"]
    ctx["instance_profile_arn"] = profile["Arn"]
    ctx["instance_profile_name"] = profile["InstanceProfileName"]


# --- 4. Lambda + API Gateway ------------------------------------------------

def build_api(ctx: dict) -> None:
    """REST API GET / → Lambda. Permission is omitted, matching the commented CFN block."""
    lam = ctx["lambda"]
    source = (
        "exports.handler = async function(event) {\n"
        f'  return {{"account_id": "{ctx["account_id"]}"}};\n'
        "};\n"
    )
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as archive:
        archive.writestr("index.js", source)
    fn = lam.create_function(
        FunctionName="unicorn-apigw-fn",
        Runtime="nodejs18.x",
        Handler="index.handler",
        Timeout=5,
        Role=ctx["lambda_role_arn"],
        Code={"ZipFile": buf.getvalue()},
        TracingConfig={"Mode": "Active"},
    )
    ctx["lambda_arn"] = fn["FunctionArn"]

    api = ctx["apigateway"]
    api_id = api.create_rest_api(
        name="unicorn-apigw",
        description="unicorn-apigw",
        endpointConfiguration={"types": ["REGIONAL"]},
    )["id"]
    root_id = api.get_resources(restApiId=api_id)["items"][0]["id"]
    api.put_method(
        restApiId=api_id, resourceId=root_id, httpMethod="GET", authorizationType="NONE"
    )
    api.put_method_response(
        restApiId=api_id, resourceId=root_id, httpMethod="GET", statusCode="200",
        responseModels={"application/json": "Empty"},
    )
    # CFN used IntegrationHttpMethod GET. Lambda's invoke API is POST; kept for parity.
    api.put_integration(
        restApiId=api_id,
        resourceId=root_id,
        httpMethod="GET",
        type="AWS",
        integrationHttpMethod="GET",
        uri=(
            f"arn:aws:apigateway:{ctx['region']}:lambda:path/2015-03-31/"
            f"functions/{ctx['lambda_arn']}/invocations"
        ),
    )
    api.put_integration_response(
        restApiId=api_id, resourceId=root_id, httpMethod="GET", statusCode="200"
    )
    api.create_deployment(restApiId=api_id, stageName="Prod")
    ctx["api_id"] = api_id
    ctx["api_url"] = f"https://{api_id}.execute-api.{ctx['region']}.amazonaws.com/Prod"


# --- 5. Bastion -------------------------------------------------------------

def build_bastion(ctx: dict) -> None:
    ec2 = ctx["ec2"]
    if not _exists(lambda: ec2.describe_key_pairs(KeyNames=[KEY_NAME])):
        material = ec2.create_key_pair(KeyName=KEY_NAME)["KeyMaterial"]
        path = f"{KEY_NAME}.pem"
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(material)
        print(f"wrote {path} — this is the only time AWS returns the private key")

    sg = ec2.create_security_group(
        GroupName=f"{ENV_NAME}-bastion",
        Description="SG to test ping",
        VpcId=ctx["vpc_id"],
    )["GroupId"]
    ec2.authorize_security_group_ingress(
        GroupId=sg, IpProtocol="tcp", FromPort=22, ToPort=22, CidrIp=BASTION_SSH_CIDR
    )
    user_data = """#!/bin/bash
yum update -y
cd /root
aws ssm get-parameter --name /ec2/keypair/key-0067cec476023d650 --with-decryption --query Parameter.Value --output text > gameday-key.pem
chmod 400 ./gameday-key.pem
"""
    instance_id = ec2.run_instances(
        ImageId=AMI_ID,
        InstanceType="t3.micro",
        MinCount=1,
        MaxCount=1,
        KeyName=KEY_NAME,
        IamInstanceProfile={"Name": ctx["instance_profile_name"]},
        UserData=user_data,  # run_instances accepts plain text; Launch Template does not
        NetworkInterfaces=[{
            "AssociatePublicIpAddress": True,
            "DeviceIndex": 0,
            "Groups": [sg],
            "SubnetId": ctx["public_subnet_ids"][0],
        }],
        TagSpecifications=[{
            "ResourceType": "instance",
            "Tags": [{"Key": "Name", "Value": "bastion"}],
        }],
    )["Instances"][0]["InstanceId"]
    ctx["bastion_sg_id"] = sg
    ctx["bastion_id"] = instance_id


# --- 6. ALB -----------------------------------------------------------------

def build_alb(ctx: dict) -> None:
    ec2, elbv2 = ctx["ec2"], ctx["elbv2"]
    sg = ec2.create_security_group(
        GroupName=f"{ENV_NAME}-elb",
        Description="ELB Security Group",
        VpcId=ctx["vpc_id"],
    )["GroupId"]
    ec2.authorize_security_group_ingress(
        GroupId=sg, IpProtocol="tcp", FromPort=80, ToPort=80, CidrIp="0.0.0.0/0"
    )
    alb_arn = elbv2.create_load_balancer(
        Name=f"{ENV_NAME}-alb",
        Scheme="internet-facing",
        Type="application",
        Subnets=list(ctx["public_subnet_ids"]),
        SecurityGroups=[sg],
    )["LoadBalancers"][0]["LoadBalancerArn"]
    tg_arn = elbv2.create_target_group(
        Name="EC2TargetGroup",
        Protocol="HTTP",
        Port=80,
        VpcId=ctx["vpc_id"],
        HealthCheckProtocol="HTTP",
        HealthCheckIntervalSeconds=30,
        HealthCheckTimeoutSeconds=15,
        HealthyThresholdCount=5,
        UnhealthyThresholdCount=3,
        Matcher={"HttpCode": "200"},
    )["TargetGroups"][0]["TargetGroupArn"]
    elbv2.modify_target_group_attributes(
        TargetGroupArn=tg_arn,
        Attributes=[{"Key": "deregistration_delay.timeout_seconds", "Value": "20"}],
    )
    elbv2.create_listener(
        LoadBalancerArn=alb_arn,
        Protocol="HTTP",
        Port=80,
        DefaultActions=[{"Type": "forward", "TargetGroupArn": tg_arn}],
    )
    elbv2.get_waiter("load_balancer_available").wait(LoadBalancerArns=[alb_arn])
    alb = elbv2.describe_load_balancers(LoadBalancerArns=[alb_arn])["LoadBalancers"][0]
    ctx["alb_arn"] = alb_arn
    ctx["alb_dns"] = alb["DNSName"]
    ctx["target_group_arn"] = tg_arn


# --- 7. CloudFront ----------------------------------------------------------

def build_cloudfront(ctx: dict) -> None:
    cf = ctx["cloudfront"]
    policy_id = cf.create_cache_policy(CachePolicyConfig={
        "Name": "MyCustomCachePolicyForSpecificQueryString",
        "Comment": "Cache policy that includes the specific query string parameter",
        "DefaultTTL": 86400,
        "MaxTTL": 31536000,
        "MinTTL": 1,
        "ParametersInCacheKeyAndForwardedToOrigin": {
            "CookiesConfig": {"CookieBehavior": "none"},
            "EnableAcceptEncodingGzip": True,
            "EnableAcceptEncodingBrotli": True,
            "HeadersConfig": {"HeaderBehavior": "none"},
            "QueryStringsConfig": {
                "QueryStringBehavior": "whitelist",
                "QueryStrings": {"Quantity": 1, "Items": [CACHE_QUERY_STRING]},
            },
        },
    })["CachePolicy"]["Id"]

    # CachePolicyId replaces ForwardedValues. Do not send both.
    dist = cf.create_distribution(DistributionConfig={
        "CallerReference": str(int(time.time())),
        "Comment": "Unicorn ALB origin",
        "Enabled": True,
        "Origins": {"Quantity": 1, "Items": [{
            "Id": "ALB",
            "DomainName": ctx["alb_dns"],
            "CustomOriginConfig": {
                "HTTPPort": 80,
                "HTTPSPort": 443,
                "OriginProtocolPolicy": "http-only",
                "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]},
            },
        }]},
        "DefaultCacheBehavior": {
            "TargetOriginId": "ALB",
            "ViewerProtocolPolicy": "allow-all",
            "CachePolicyId": policy_id,
        },
    })["Distribution"]
    ctx["cloudfront_domain"] = dist["DomainName"]


# --- 8. Application ASG -----------------------------------------------------

def build_asg(ctx: dict) -> None:
    ec2, autoscaling = ctx["ec2"], ctx["autoscaling"]
    sg = ec2.create_security_group(
        GroupName=f"{ENV_NAME}-app",
        Description="applciation",
        VpcId=ctx["vpc_id"],
    )["GroupId"]
    for port in (80, 22, 443):
        ec2.authorize_security_group_ingress(
            GroupId=sg, IpProtocol="tcp", FromPort=port, ToPort=port, CidrIp=VPC_CIDR
        )
    user_data = f"""#!/bin/bash
yum update -y
cd /root
aws s3 cp s3://{ctx['bucket']}/ws-ec2-pipeline-server .
wget https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
chmod 700 ./ws-ec2-pipeline-server
./ws-ec2-pipeline-server
"""
    lt = ec2.create_launch_template(
        LaunchTemplateName="applicationLaunchTemplate",
        LaunchTemplateData={
            "ImageId": AMI_ID,
            "InstanceType": "t3.micro",
            "KeyName": KEY_NAME,
            "IamInstanceProfile": {"Arn": ctx["instance_profile_arn"]},
            "UserData": base64.b64encode(user_data.encode()).decode(),
            "TagSpecifications": [{
                "ResourceType": "instance",
                "Tags": [{"Key": "Name", "Value": "Application"}],
            }],
            "NetworkInterfaces": [{
                "AssociatePublicIpAddress": True,
                "DeviceIndex": 0,
                "Groups": [sg],
            }],
        },
    )["LaunchTemplate"]
    autoscaling.create_auto_scaling_group(
        AutoScalingGroupName="applicationAsg",
        LaunchTemplate={
            "LaunchTemplateId": lt["LaunchTemplateId"],
            "Version": str(lt["LatestVersionNumber"]),
        },
        MinSize=1,
        MaxSize=5,
        VPCZoneIdentifier=",".join(ctx["private_subnet_ids"]),
        TargetGroupARNs=[ctx["target_group_arn"]],
        EnabledMetrics=[
            {"Metric": "GroupMinSize", "Granularity": "1Minute"},
            {"Metric": "GroupMaxSize", "Granularity": "1Minute"},
        ],
    )
    ctx["app_sg_id"] = sg


# --- 9. DocumentDB + Secrets Manager ----------------------------------------

def build_docdb(ctx: dict) -> None:
    ec2 = ctx["ec2"]
    ec2.create_vpc_endpoint(
        VpcId=ctx["vpc_id"],
        ServiceName=f"com.amazonaws.{ctx['region']}.secretsmanager",
        VpcEndpointType="Interface",
        SubnetIds=list(ctx["private_subnet_ids"]),
        SecurityGroupIds=[ctx["app_sg_id"], ctx["bastion_sg_id"]],
        PrivateDnsEnabled=True,
    )
    db_sg = ec2.create_security_group(
        GroupName=f"{ENV_NAME}-docdb",
        Description="SG to test ping",
        VpcId=ctx["vpc_id"],
    )["GroupId"]
    ec2.authorize_security_group_ingress(
        GroupId=db_sg, IpProtocol="tcp", FromPort=27017, ToPort=27017, CidrIp=VPC_CIDR
    )

    sm = ctx["secretsmanager"]
    secret_arn = sm.create_secret(
        Name="DocDBClusterRotationSecret",
        GenerateSecretString={
            "SecretStringTemplate": '{"username":"someadmin","ssl":true}',
            "GenerateStringKey": "password",
            "PasswordLength": 16,
            "ExcludePunctuation": True,
        },
        Tags=[{"Key": "AppName", "Value": ENV_NAME}],
    )["ARN"]
    secret = json.loads(sm.get_secret_value(SecretId=secret_arn)["SecretString"])

    docdb = ctx["docdb"]
    docdb.create_db_subnet_group(
        DBSubnetGroupName="unicorn-private-subnet",
        DBSubnetGroupDescription="private-subnet",
        SubnetIds=list(ctx["private_subnet_ids"]),
    )
    docdb.create_db_cluster(
        DBClusterIdentifier="unicorn-docdb",
        Engine="docdb",
        MasterUsername=secret["username"],
        MasterUserPassword=secret["password"],
        DBSubnetGroupName="unicorn-private-subnet",
        VpcSecurityGroupIds=[db_sg],
    )
    docdb.create_db_instance(
        DBInstanceIdentifier="unicorn-docdb-1",
        DBInstanceClass=DOCDB_INSTANCE_CLASS,
        Engine="docdb",
        DBClusterIdentifier="unicorn-docdb",
    )
    docdb.get_waiter("db_instance_available").wait(DBInstanceIdentifier="unicorn-docdb-1")
    endpoint = docdb.describe_db_clusters(
        DBClusterIdentifier="unicorn-docdb"
    )["DBClusters"][0]["Endpoint"]
    secret.update({"host": endpoint, "port": 27017, "engine": "mongo"})
    sm.put_secret_value(SecretId=secret_arn, SecretString=json.dumps(secret))
    ctx["secret_arn"] = secret_arn
    ctx["docdb_endpoint"] = endpoint


# --- 10. AppConfig ----------------------------------------------------------

def build_appconfig(ctx: dict) -> None:
    appconfig = ctx["appconfig"]
    app_id = appconfig.create_application(
        Name=ENV_NAME, Description="Unicorn application.", Tags={"Env": "Production"}
    )["Id"]
    env_id = appconfig.create_environment(
        ApplicationId=app_id,
        Name="Production",
        Description="Production environment",
        Tags={"Env": "Production"},
    )["Id"]
    profile_id = appconfig.create_configuration_profile(
        ApplicationId=app_id,
        Name=ENV_NAME,
        Description="My test configuration profile",
        LocationUri="hosted",
        Tags={"Env": "Production"},
    )["Id"]
    hosted = {
        "DBSeretARN": ctx["secret_arn"],  # typo kept from the template
        "MongoDbDatabase": "unicorndb",
        "MongoDbCollection": "unicorncollection",
        "MongoDbCAFilePath": "./global-bundle.pem",
        "Port": 80,
        "Bucket": ctx["bucket"],
        "ApiGatewayUrl": ctx["api_url"],
    }
    version = appconfig.create_hosted_configuration_version(
        ApplicationId=app_id,
        ConfigurationProfileId=profile_id,
        Description=" configuration prod value",
        Content=json.dumps(hosted).encode(),
        ContentType="application/json",
    )["VersionNumber"]
    strategy_id = appconfig.create_deployment_strategy(
        Name="Unicorn DeploymentStrategy",
        Description="deployment strategy.",
        DeploymentDurationInMinutes=0,
        FinalBakeTimeInMinutes=0,
        GrowthFactor=100.0,
        GrowthType="LINEAR",
        ReplicateTo="NONE",
        Tags={"Env": "Production"},
    )["Id"]
    appconfig.start_deployment(
        ApplicationId=app_id,
        EnvironmentId=env_id,
        DeploymentStrategyId=strategy_id,
        ConfigurationProfileId=profile_id,
        ConfigurationVersion=str(version),
        Description="Unicorn deployment",
        Tags={"Env": "Production"},
    )
    ctx["appconfig_app_id"] = app_id


def main() -> None:
    ctx = clients()
    steps = (
        ("network", build_network),
        ("s3 + flow logs", build_bucket_and_flow_logs),
        ("iam", ensure_iam),
        ("lambda + api gateway", build_api),
        ("bastion", build_bastion),
        ("alb", build_alb),
        ("cloudfront", build_cloudfront),
        ("asg", build_asg),
        ("docdb", build_docdb),
        ("appconfig", build_appconfig),
    )
    for name, fn in steps:
        print(f"==> {name}")
        fn(ctx)
    print(json.dumps({
        "VPC": ctx["vpc_id"],
        "PublicSubnets": ctx["public_subnet_ids"],
        "PrivateSubnets": ctx["private_subnet_ids"],
        "S3Bucket": ctx["bucket"],
        "Lambda": ctx["lambda_arn"],
        "SecretManager": ctx["secret_arn"],
        "ALB": ctx["alb_dns"],
        "CloudFront": ctx["cloudfront_domain"],
        "ApiGatewayUrl": ctx["api_url"],
        "DocDB": ctx["docdb_endpoint"],
        "Bastion": ctx["bastion_id"],
    }, indent=2))


if __name__ == "__main__":
    main()
