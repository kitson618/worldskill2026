# Unicorn GameDay — AWS SDK（boto3）分段範例

這份文件把 [`app.yml`](../app.yml) 拆成可以分開讀的 SDK 範例。完整可執行程式在 [`app_sdk.py`](app_sdk.py)。同一套 API 的 AWS CLI 教學在 [`cli/README.md`](../cli/README.md)，完整腳本在 [`app.sh`](../app.sh)。

SDK 和 CLI 打的是同一組 AWS API。差別是：CLI 把 ID 放進 shell 變數，SDK 把 ID 放進下一個 Python 呼叫。CloudFormation 的 `!Ref` / `!GetAtt` 在這裡都要自己接。

```bash
pip install boto3
cd gameday-cn/sdk
python3 app_sdk.py
```

會建立要收費的資源（NAT Gateway、DocumentDB、CloudFront）。沒有對真實帳號跑過。

| 章 | 函式 | 對應 `app.yml` |
|---|---|---|
| 1 | `build_network` | VPC、subnet、IGW、NAT、路由表 |
| 2 | `build_bucket_and_flow_logs` | `s3Bucket`、`S3Flowlog` |
| 3 | `ensure_iam` | 模板假設已存在的兩個 role |
| 4 | `build_api` | Lambda、API Gateway |
| 5 | `build_bastion` | Key pair、bastion |
| 6 | `build_alb` | ALB、target group、listener |
| 7 | `build_cloudfront` | Cache policy、distribution |
| 8 | `build_asg` | Launch template、ASG |
| 9 | `build_docdb` | Secrets Manager、VPC endpoint、DocumentDB |
| 10 | `build_appconfig` | AppConfig 整條部署鏈 |

---

## 0. 一個 Session，多個 client

不要每個呼叫都 `boto3.client(...)`。一個 `Session` 帶 region 和憑證，各服務各拿一個 client。後面的章節都從 `ctx` 拿 client 和上一段產出的 ID。

```python
session = boto3.Session(region_name="us-east-1")
ec2 = session.client("ec2")
account_id = session.client("sts").get_caller_identity()["Account"]
```

`ctx` 就是這份範例的「Outputs」。CloudFormation 結束時印 VPC ID；這裡是函式把 `vpc_id` 寫進 dict，下一個函式讀它。

模板把帳號 `608671652196` 和 bucket 名寫死。SDK 範例改從 STS 取帳號，bucket 用 `gameday-{account_id}`。

---

## 1. 網路

對應：`VPC`、四條 subnet、`InternetGateway`、`NatGateway`、兩張路由表。

要學的模式：

- 建立資源 → 從回傳 dict 取出 ID → 傳給下一個 API
- DNS 不是 `create_vpc` 的參數，要再呼叫 `modify_vpc_attribute`
- NAT 是非同步的，路由必須等 waiter

```python
vpc_id = ec2.create_vpc(CidrBlock="10.0.0.0/16")["Vpc"]["VpcId"]
ec2.modify_vpc_attribute(VpcId=vpc_id, EnableDnsSupport={"Value": True})
ec2.modify_vpc_attribute(VpcId=vpc_id, EnableDnsHostnames={"Value": True})
ec2.create_tags(Resources=[vpc_id], Tags=[{"Key": "Name", "Value": "Unicorn"}])

igw_id = ec2.create_internet_gateway()["InternetGateway"]["InternetGatewayId"]
ec2.attach_internet_gateway(InternetGatewayId=igw_id, VpcId=vpc_id)

subnet_id = ec2.create_subnet(
    VpcId=vpc_id, CidrBlock="10.0.10.0/24", AvailabilityZone=az
)["Subnet"]["SubnetId"]
ec2.modify_subnet_attribute(SubnetId=subnet_id, MapPublicIpOnLaunch={"Value": True})

alloc = ec2.allocate_address(Domain="vpc")["AllocationId"]
nat_id = ec2.create_nat_gateway(SubnetId=pub1, AllocationId=alloc)["NatGateway"]["NatGatewayId"]
ec2.get_waiter("nat_gateway_available").wait(NatGatewayIds=[nat_id])
ec2.create_route(
    RouteTableId=private_rt, DestinationCidrBlock="0.0.0.0/0", NatGatewayId=nat_id
)
```

CLI 等價：`aws ec2 create-vpc`、`aws ec2 wait nat-gateway-available`。

和模板一樣：兩條 private subnet 共用一張路由表、一個 NAT，放在 public subnet 1。AZ 故障時私網出不了網。`describe_availability_zones` 取前兩個可用 AZ，等同模板的 `!Select [0, !GetAZs '']`。

---

## 2. S3 與 Flow Logs

對應：`s3Bucket`、`S3Flowlog`。

要學的模式：bucket 建立後，加密、版本、封鎖公開存取是**另外三次**呼叫，不是 `create_bucket` 的欄位。`us-east-1` 不能帶 `LocationConstraint`。

```python
s3.create_bucket(Bucket=bucket)  # us-east-1：不要加 LocationConstraint
s3.put_bucket_versioning(
    Bucket=bucket, VersioningConfiguration={"Status": "Enabled"}
)
s3.put_bucket_encryption(
    Bucket=bucket,
    ServerSideEncryptionConfiguration={
        "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
    },
)

result = ec2.create_flow_logs(
    ResourceIds=[vpc_id],
    ResourceType="VPC",
    TrafficType="ALL",
    LogDestinationType="s3",
    LogDestination=f"arn:aws:s3:::{bucket}",
    LogFormat="${version} ${vpc-id} ${subnet-id} ...",
    MaxAggregationInterval=60,
    DestinationOptions={
        "FileFormat": "parquet",
        "HiveCompatiblePartitions": True,
        "PerHourPartition": True,
    },
)
if result["Unsuccessful"]:
    raise RuntimeError(result["Unsuccessful"])
```

`LogFormat` 裡的 `${version}` 是 AWS 的 token。用普通字串，不要用 f-string，否則 Python 會去找變數 `version`。

`create_flow_logs` 失敗時 HTTP 仍可能是 200，錯誤在 `Unsuccessful`。要自己檢查。

模板沒有給 flow log 的 bucket policy。資源可以建出來，檔案不一定寫得進去。實務要再加一條允許 `delivery.logs.amazonaws.com` 的 policy；這份範例故意不加，以便和模板對得起來。

---

## 3. 模板沒建立的 IAM

`app.yml` 直接寫：

- Lambda role：`arn:aws:iam::608671652196:role/MyLambdaExecutionRole`
- Instance profile 角色：`WSEC2Role`

SDK 範例在角色不存在時才建。判斷方式是呼叫 `get_role`，捕捉 `NoSuchEntity`，不要用「先 list 再比對」。

```python
try:
    iam.get_role(RoleName="MyLambdaExecutionRole")
except ClientError as exc:
    if exc.response["Error"]["Code"] != "NoSuchEntity":
        raise
    iam.create_role(
        RoleName="MyLambdaExecutionRole",
        AssumeRolePolicyDocument=json.dumps({...}),  # 必須是字串，不是 dict
    )
```

`AssumeRolePolicyDocument` 和 `put_role_policy` 的 `PolicyDocument` 都要 `json.dumps`。傳 dict 會被拒絕。

Instance profile 建完不能立刻拿去 `run_instances`，IAM 是最終一致。範例 `sleep(10)`。

---

## 4. Lambda 與 API Gateway

對應：`lambdaFunction`、`apiGateway`、`apiMethod`、`Deployment`。

要學的模式：

- Lambda 程式碼是 zip bytes，放在 `Code={"ZipFile": ...}`，不是檔案路徑
- API Gateway 是多次呼叫拼出來的：API → method → integration → deployment
- 沒有 `create_deployment` 就沒有可呼叫的 URL

```python
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as archive:
    archive.writestr("index.js", source)

fn = lam.create_function(
    FunctionName="unicorn-apigw-fn",
    Runtime="nodejs18.x",
    Handler="index.handler",
    Role=lambda_role_arn,
    Code={"ZipFile": buf.getvalue()},
    Timeout=5,
    TracingConfig={"Mode": "Active"},  # X-Ray
)

api_id = api.create_rest_api(
    name="unicorn-apigw",
    endpointConfiguration={"types": ["REGIONAL"]},
)["id"]
root_id = api.get_resources(restApiId=api_id)["items"][0]["id"]
api.put_method(
    restApiId=api_id, resourceId=root_id,
    httpMethod="GET", authorizationType="NONE",
)
api.put_integration(
    restApiId=api_id, resourceId=root_id, httpMethod="GET",
    type="AWS",
    integrationHttpMethod="GET",  # 模板如此；Lambda invoke 慣例是 POST
    uri=(
        f"arn:aws:apigateway:{region}:lambda:path/2015-03-31/"
        f"functions/{fn_arn}/invocations"
    ),
)
api.create_deployment(restApiId=api_id, stageName="Prod")
```

模板把 `AWS::Lambda::Permission` 註解掉了。沒有 `lambda:InvokeFunction` 給 `apigateway.amazonaws.com`，stage URL 會 500。範例同樣不加，並在函式註解標明。

URI 不要寫死 `us-east-1`。用 `ctx["region"]`，否則換區域會指到別區的 Lambda。

---

## 5. Bastion

對應：`Ec2KeyPair`、`BastionSg`、`Ec2Instance`。

```python
material = ec2.create_key_pair(KeyName="gameday-key")["KeyMaterial"]
# KeyMaterial 只回傳這一次。沒存下來就無法 SSH。

ec2.run_instances(
    ImageId=AMI_ID,
    InstanceType="t3.micro",
    MinCount=1,          # run_instances 必填；CloudFormation 沒有這兩個欄位
    MaxCount=1,
    KeyName="gameday-key",
    IamInstanceProfile={"Name": profile_name},
    UserData=script,     # 這裡是純文字，SDK 會自己 base64
    NetworkInterfaces=[{
        "AssociatePublicIpAddress": True,
        "DeviceIndex": 0,
        "Groups": [sg_id],
        "SubnetId": public_subnet_1,
    }],
    TagSpecifications=[{
        "ResourceType": "instance",
        "Tags": [{"Key": "Name", "Value": "bastion"}],
    }],
)
```

SSH 只放行模板裡的 `119.237.240.242/32`。換網路要改 `BASTION_SSH_CIDR`。

UserData 仍會去 SSM 拉 `/ec2/keypair/key-0067cec476023d650`。那把 key 不是這次 `create_key_pair` 建的。參數不存在時，機器還是會起來，只是 userdata 失敗。

`MinCount` / `MaxCount` 是 SDK 比 CloudFormation 多出來的必填欄位。漏了會直接 `ParamValidationError`。

---

## 6. ALB

對應：`ELBSecurityGroup`、`ApplicationLoadBalancer`、`EC2TargetGroup`、`ALBListener`。

client 名稱是 `elbv2`，不是 `elb`（那是 Classic Load Balancer）。

```python
elbv2 = session.client("elbv2")
alb_arn = elbv2.create_load_balancer(
    Name="Unicorn-alb",
    Scheme="internet-facing",
    Type="application",
    Subnets=[pub1, pub2],
    SecurityGroups=[elb_sg],
)["LoadBalancers"][0]["LoadBalancerArn"]

tg_arn = elbv2.create_target_group(
    Name="EC2TargetGroup",
    Protocol="HTTP", Port=80, VpcId=vpc_id,
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
    LoadBalancerArn=alb_arn, Protocol="HTTP", Port=80,
    DefaultActions=[{"Type": "forward", "TargetGroupArn": tg_arn}],
)
elbv2.get_waiter("load_balancer_available").wait(LoadBalancerArns=[alb_arn])
dns = elbv2.describe_load_balancers(LoadBalancerArns=[alb_arn])["LoadBalancers"][0]["DNSName"]
```

CloudFront 的 origin 要用這個 `DNSName`，不是 ALB 的 ARN，也不是建立當下回傳裡可能還是空的 DNS。等 waiter 再 `describe`。

Target group 名稱在同一區域必須唯一。`EC2TargetGroup` 已存在時，這段會失敗。

---

## 7. CloudFront

對應：`MyCustomCachePolicy`、`cloudfrontdistribution`。

CloudFront 的 list 參數仍是舊的 `Quantity` + `Items`，不是 Python list。自訂 origin 即使 `http-only`，也要帶 `OriginSslProtocols`，否則 `create_distribution` 會拒。

```python
policy_id = cf.create_cache_policy(CachePolicyConfig={
    "Name": "MyCustomCachePolicyForSpecificQueryString",
    "MinTTL": 1,
    "DefaultTTL": 86400,
    "MaxTTL": 31536000,
    "ParametersInCacheKeyAndForwardedToOrigin": {
        "EnableAcceptEncodingGzip": True,
        "EnableAcceptEncodingBrotli": True,
        "CookiesConfig": {"CookieBehavior": "none"},
        "HeadersConfig": {"HeaderBehavior": "none"},
        "QueryStringsConfig": {
            "QueryStringBehavior": "whitelist",
            "QueryStrings": {
                "Quantity": 1,
                "Items": ["input-SUNhbkhhelVuaWNvem40LTY3NDkSY"],
            },
        },
    },
})["CachePolicy"]["Id"]

cf.create_distribution(DistributionConfig={
    "CallerReference": str(int(time.time())),  # 重試時必須換，否則被當成同一筆
    "Comment": "Unicorn ALB origin",
    "Enabled": True,
    "Origins": {"Quantity": 1, "Items": [{
        "Id": "ALB",
        "DomainName": alb_dns,
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
        "CachePolicyId": policy_id,   # 有 CachePolicyId 就不要再傳 ForwardedValues
    },
})
```

`CallerReference` 是冪等鍵。同一個值再呼叫會回傳同一筆 distribution，不會更新 origin。

Cache policy 名稱是帳號全域唯一。模板用的那個名字若已存在，要換名或先刪。

Origin 是 HTTP only、viewer `allow-all`，和模板一致。沒有強制 HTTPS。

---

## 8. Launch Template 與 ASG

對應：`ApplicationSg`、`applicationLaunchTemplate`、`applicationAsg`。

和第 5 節的差別：Launch Template 的 `UserData` **必須自己 base64**。`run_instances` 會幫你編碼，這裡不會。

```python
encoded = base64.b64encode(user_data.encode()).decode()
lt = ec2.create_launch_template(
    LaunchTemplateName="applicationLaunchTemplate",
    LaunchTemplateData={
        "ImageId": AMI_ID,
        "InstanceType": "t3.micro",
        "KeyName": "gameday-key",
        "IamInstanceProfile": {"Arn": profile_arn},  # 這裡用 ARN，不是 Name
        "UserData": encoded,
        "NetworkInterfaces": [{
            "AssociatePublicIpAddress": True,
            "DeviceIndex": 0,
            "Groups": [app_sg],
        }],
    },
)["LaunchTemplate"]

autoscaling.create_auto_scaling_group(
    AutoScalingGroupName="applicationAsg",
    LaunchTemplate={
        "LaunchTemplateId": lt["LaunchTemplateId"],
        "Version": str(lt["LatestVersionNumber"]),  # 必須是字串
    },
    MinSize=1,
    MaxSize=5,
    VPCZoneIdentifier=f"{pri1},{pri2}",             # 逗號分隔，不是 list
    TargetGroupARNs=[tg_arn],
    EnabledMetrics=[
        {"Metric": "GroupMinSize", "Granularity": "1Minute"},
        {"Metric": "GroupMaxSize", "Granularity": "1Minute"},
    ],
)
```

ASG 放在 private subnet。`AssociatePublicIpAddress=True` 在沒有自動指派公網 IP 的 subnet 上不會給出公網 IP，出網靠第 1 節的 NAT。

沒有 target tracking policy。流量上來不會自動擴。這和模板一樣，GameDay「依 ALB request 擴縮」那一項拿不到。

UserData 會 `aws s3 cp s3://{bucket}/ws-ec2-pipeline-server`。SDK 不會上傳這個檔。bucket 建好後：

```bash
aws s3 cp ../ws-ec2-pipeline-server s3://gameday-ACCOUNT/ws-ec2-pipeline-server
```

然後回收 ASG 實例，新機器才拉得到 binary。

---

## 9. DocumentDB 與 Secrets Manager

對應：`SecretsManagerVPCEndpoint`、`DatabaseSg`、`DocDBClusterRotationSecret`、`DocDBCluster`、`DocDBInstance`、`DBSubnetGroup`。

要學的模式：secret 先產生，再讀出來當 `MasterUserPassword`。CloudFormation 用 `{{resolve:secretsmanager:...}}` 在部署時解析；SDK 沒有這個語法，要自己 `get_secret_value`。

```python
ec2.create_vpc_endpoint(
    VpcId=vpc_id,
    ServiceName=f"com.amazonaws.{region}.secretsmanager",
    VpcEndpointType="Interface",
    SubnetIds=[pri1, pri2],
    SecurityGroupIds=[app_sg, bastion_sg],
    PrivateDnsEnabled=True,
)

secret_arn = sm.create_secret(
    Name="DocDBClusterRotationSecret",
    GenerateSecretString={
        "SecretStringTemplate": '{"username":"someadmin","ssl":true}',
        "GenerateStringKey": "password",
        "PasswordLength": 16,
        "ExcludePunctuation": True,
    },
    Tags=[{"Key": "AppName", "Value": "Unicorn"}],
)["ARN"]
secret = json.loads(sm.get_secret_value(SecretId=secret_arn)["SecretString"])

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
    DBInstanceClass="db.t3.medium",
    Engine="docdb",
    DBClusterIdentifier="unicorn-docdb",
)
docdb.get_waiter("db_instance_available").wait(DBInstanceIdentifier="unicorn-docdb-1")
```

等的是 **instance** waiter，不是 cluster。Cluster 先到 available，instance 還沒好時 endpoint 還不能用。

模板的 `SecretTargetAttachment` 會把 RDS/DocDB 的 host 寫回 secret。DocumentDB 的 attachment 支援不完整，所以範例在 waiter 之後自己 `put_secret_value`，補上 `host`、`port`、`engine`。不要把密碼印出來。

沒設加密、備份天數、deletion protection、第二個 instance。和模板一樣。

---

## 10. AppConfig

對應：`Application` → `ProdEnvironment` → `ConfigurationProfile` → `HostedConfigurationVersion` → `DeploymentStrategy` → `appConfigDeployment`。

六個 API，順序不能換。下一個呼叫的 ID 來自上一個的回傳。

```python
app_id = appconfig.create_application(
    Name="Unicorn", Description="Unicorn application.", Tags={"Env": "Production"}
)["Id"]
env_id = appconfig.create_environment(
    ApplicationId=app_id, Name="Production", Description="Production environment"
)["Id"]
profile_id = appconfig.create_configuration_profile(
    ApplicationId=app_id, Name="Unicorn", LocationUri="hosted"
)["Id"]

hosted = {
    "DBSeretARN": secret_arn,          # 模板拼錯的鍵名，保留
    "MongoDbDatabase": "unicorndb",
    "MongoDbCollection": "unicorncollection",
    "MongoDbCAFilePath": "./global-bundle.pem",
    "Port": 80,
    "Bucket": bucket,
    "ApiGatewayUrl": api_url,          # 用第 4 節建出來的 URL，不貼舊的 execute-api id
}
version = appconfig.create_hosted_configuration_version(
    ApplicationId=app_id,
    ConfigurationProfileId=profile_id,
    Content=json.dumps(hosted).encode(),   # bytes，不是 str
    ContentType="application/json",
)["VersionNumber"]

strategy_id = appconfig.create_deployment_strategy(
    Name="Unicorn DeploymentStrategy",
    DeploymentDurationInMinutes=0,
    GrowthFactor=100.0,                     # float
    GrowthType="LINEAR",
    ReplicateTo="NONE",
)["Id"]
appconfig.start_deployment(
    ApplicationId=app_id,
    EnvironmentId=env_id,
    DeploymentStrategyId=strategy_id,
    ConfigurationProfileId=profile_id,
    ConfigurationVersion=str(version),      # 字串，不是 int
    Description="Unicorn deployment",
)
```

模板把 secret ARN 和 API URL 貼死。重跑 stack 後綴會變，binary 會連到舊資源。SDK 範例改成這次呼叫的回傳值。鍵名 `DBSeretARN` 仍保留，因為應用可能照這個錯字讀。

`GrowthFactor=100` 且 duration 0，等於立刻切到新版。

---

## 串起來

[`app_sdk.py`](app_sdk.py) 的 `main()` 只做這件事：

```python
ctx = clients()
for name, fn in steps:
    fn(ctx)
```

順序就是上面 1→10。第 8 節的 ASG 要第 6 節的 target group；第 9 節的 VPC endpoint 要第 5、8 節的 security group；第 10 節要第 4 節的 API URL 和第 9 節的 secret ARN。不能平行建。

跑完會印 VPC、subnet、bucket、Lambda ARN、secret ARN、ALB DNS、CloudFront domain、API URL、DocDB endpoint。密碼不印。

名稱在區域內必須唯一，重跑前要刪掉或改名：

- S3 bucket `gameday-{account}`
- Cache policy `MyCustomCachePolicyForSpecificQueryString`
- Launch template `applicationLaunchTemplate`
- ASG `applicationAsg`
- Secret `DocDBClusterRotationSecret`
- DocDB `unicorn-docdb`
- Target group `EC2TargetGroup`

AMI `ami-0b72821e2f351e396` 是模板寫死的。換區域或 AMI 下架時，改 `app_sdk.py` 頂部的 `AMI_ID`。
