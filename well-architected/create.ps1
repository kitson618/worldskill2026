#Requires -Version 5.1
<#
.SYNOPSIS
  Well-Architected baseline in us-east-1. Windows PowerShell 5.1 and PowerShell 7.

.EXAMPLE
  Set-ExecutionPolicy -Scope Process Bypass
  .\create.ps1
  .\create.ps1 -Action destroy

.NOTES
  Needs AWS CLI v2 on PATH and credentials. Does not need Python, OpenSSL, or Git Bash.
  Billable: 2 NAT Gateways, ALB, CloudFront, WAF, bastion, one app instance.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'create', 'destroy', 'down')]
    [string]$Action = 'up'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$env:AWS_PAGER = ''
$env:AWS_DEFAULT_REGION = 'us-east-1'
$env:AWS_REGION = 'us-east-1'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:StateFile = if ($env:STATE_FILE) { $env:STATE_FILE } else { Join-Path $Root 'wa-state.json' }
$script:WorkDir = $null
$script:S = @{}

function Import-WaConfig {
    $path = if ($env:CONFIG_FILE) { $env:CONFIG_FILE } else { Join-Path $Root 'config.env' }
    if (-not (Test-Path -LiteralPath $path)) { throw "missing config file: $path" }
    foreach ($raw in [System.IO.File]::ReadAllLines($path)) {
        $line = $raw
        $hash = $line.IndexOf('#')
        if ($hash -ge 0) { $line = $line.Substring(0, $hash) }
        $line = $line.Trim()
        if (-not $line) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { throw "bad config line: $raw" }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim()
        if ($key -notmatch '^[A-Z][A-Z0-9_]*$') { throw "bad config key: $key" }
        if (-not (Test-Path -LiteralPath "Env:$key")) {
            Set-Item -Path "Env:$key" -Value $val
        }
    }
    foreach ($required in @(
        'REGION', 'NAME', 'ENV', 'VPC_NAME', 'VPC_CIDR',
        'PUBLIC_CIDR_1', 'PUBLIC_CIDR_2', 'PRIVATE_CIDR_1', 'PRIVATE_CIDR_2',
        'ISOLATED_CIDR_1', 'ISOLATED_CIDR_2', 'INSTANCE_TYPE'
    )) {
        $current = [Environment]::GetEnvironmentVariable($required)
        if ([string]::IsNullOrWhiteSpace($current)) { throw "set $required in $path" }
    }
    if ($env:REGION -ne 'us-east-1') { throw 'REGION must be us-east-1 (CloudFront WAF)' }
    $env:AWS_DEFAULT_REGION = $env:REGION
    $env:AWS_REGION = $env:REGION
    $script:Name = $env:NAME
    $script:Env = $env:ENV
    $script:VpcName = $env:VPC_NAME
    $script:VpcCidr = $env:VPC_CIDR
    $script:InstanceType = $env:INSTANCE_TYPE
    $script:PublicCidrs = @($env:PUBLIC_CIDR_1, $env:PUBLIC_CIDR_2)
    $script:PrivateCidrs = @($env:PRIVATE_CIDR_1, $env:PRIVATE_CIDR_2)
    $script:IsolatedCidrs = @($env:ISOLATED_CIDR_1, $env:ISOLATED_CIDR_2)
}

function Write-Log([string]$Message) {
    Write-Host "==> $Message"
}

function ConvertTo-AwsJson {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) {
        $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
        return '"' + $escaped + '"'
    }
    if ($Value -is [bool]) {
        if ($Value) { return 'true' } else { return 'false' }
    }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [int64] -or $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
        return ([string]$Value).Replace(',', '.')
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = New-Object System.Collections.Generic.List[string]
        foreach ($key in @($Value.Keys)) {
            $pairs.Add((ConvertTo-AwsJson ([string]$key)) + ':' + (ConvertTo-AwsJson $Value[$key]))
        }
        return '{' + ($pairs -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Value) {
            $items.Add((ConvertTo-AwsJson $item))
        }
        return '[' + ($items -join ',') + ']'
    }
    throw "Cannot serialize $($Value.GetType().FullName)"
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Write-JsonFile([string]$Path, $Object) {
    Write-Utf8NoBom $Path (ConvertTo-AwsJson $Object)
}

function Get-FileArg([string]$Path) {
    $full = ([System.IO.Path]::GetFullPath($Path)) -replace '\\', '/'
    return "file://$full"
}

function New-JsonList {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Items)
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $Items) { [void]$list.Add($item) }
    return $list
}

function Invoke-AwsRaw {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AwsArgs)
    $output = & aws @AwsArgs
    if ($LASTEXITCODE -ne 0) {
        throw "aws $($AwsArgs -join ' ') failed with exit $LASTEXITCODE"
    }
    if ($null -eq $output) { return '' }
    return (($output | Out-String).Trim())
}

function Get-AwsText {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AwsArgs)
    return (Invoke-AwsRaw @AwsArgs --output text)
}

function Get-AwsJson {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AwsArgs)
    $raw = Invoke-AwsRaw @AwsArgs --output json
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw -eq 'null') { return $null }
    return ($raw | ConvertFrom-Json)
}

function Invoke-Aws {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AwsArgs)
    [void](Invoke-AwsRaw @AwsArgs)
}

function Save-State {
    Write-JsonFile $script:StateFile $script:S
}

function Set-State([string]$Key, [string]$Value) {
    $script:S[$Key] = $Value
    Save-State
}

function Get-State([string]$Key) {
    if ($script:S -is [System.Collections.IDictionary]) {
        if (-not $script:S.Contains($Key) -or $null -eq $script:S[$Key]) { return '' }
        return [string]$script:S[$Key]
    }
    $prop = $script:S.PSObject.Properties[$Key]
    if ($null -eq $prop -or $null -eq $prop.Value) { return '' }
    return [string]$prop.Value
}

function New-WorkDir {
    $script:WorkDir = Join-Path $env:TEMP ("wa-cli-" + $PID)
    New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null
}

function Remove-WorkDir {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-BestEffort {
    param([scriptblock]$Script)
    try {
        & $Script
    }
    catch {
        Write-Warning $_.Exception.Message
    }
}

function New-RandomHex([int]$Bytes = 24) {
    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    return -join ($buffer | ForEach-Object { $_.ToString('x2') })
}

function New-Subnet([string]$VpcId, [string]$Cidr, [string]$Az, [bool]$Public, [string]$SubnetName) {
    $id = Get-AwsText ec2 create-subnet --vpc-id $VpcId --cidr-block $Cidr --availability-zone $Az `
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$SubnetName},{Key=Project,Value=$Name},{Key=env,Value=$script:Env}]" `
        --query Subnet.SubnetId
    if ($Public) {
        Invoke-Aws ec2 modify-subnet-attribute --subnet-id $id --map-public-ip-on-launch
    }
    return $id
}

function New-RouteTable([string]$VpcId, [string]$TableName) {
    return Get-AwsText ec2 create-route-table --vpc-id $VpcId `
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$TableName},{Key=Project,Value=$Name},{Key=env,Value=$script:Env}]" `
        --query RouteTable.RouteTableId
}

function Build-Bucket([string]$Account) {
    $bucket = "${Name}-logs-${Account}-use1"
    Write-Log "S3 log bucket $bucket"
    Invoke-Aws s3api create-bucket --bucket $bucket --region us-east-1
    Invoke-Aws s3api put-public-access-block --bucket $bucket --public-access-block-configuration `
        'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
    Invoke-Aws s3api put-bucket-versioning --bucket $bucket --versioning-configuration Status=Enabled
    $encPath = Join-Path $script:WorkDir 'encryption.json'
    Write-JsonFile $encPath @{
        Rules = (New-JsonList @{
            ApplyServerSideEncryptionByDefault = @{ SSEAlgorithm = 'AES256' }
            BucketKeyEnabled = $true
        })
    }
    Invoke-Aws s3api put-bucket-encryption --bucket $bucket --server-side-encryption-configuration (Get-FileArg $encPath)
    $ownPath = Join-Path $script:WorkDir 'ownership.json'
    Write-JsonFile $ownPath @{ Rules = (New-JsonList @{ ObjectOwnership = 'BucketOwnerEnforced' }) }
    Invoke-Aws s3api put-bucket-ownership-controls --bucket $bucket --ownership-controls (Get-FileArg $ownPath)
    $lifePath = Join-Path $script:WorkDir 'lifecycle.json'
    Write-JsonFile $lifePath @{
        Rules = (New-JsonList @{
            ID = 'expire-logs-90d'
            Status = 'Enabled'
            Filter = @{ Prefix = '' }
            Expiration = @{ Days = 90 }
            NoncurrentVersionExpiration = @{ NoncurrentDays = 30 }
            AbortIncompleteMultipartUpload = @{ DaysAfterInitiation = 7 }
        })
    }
    Invoke-Aws s3api put-bucket-lifecycle-configuration --bucket $bucket --lifecycle-configuration (Get-FileArg $lifePath)

    $arn = "arn:aws:s3:::$bucket"
    $policyPath = Join-Path $script:WorkDir 'bucket-policy.json'
    Write-JsonFile $policyPath @{
        Version = '2012-10-17'
        Statement = (New-JsonList `
            @{
                Sid = 'DenyInsecureTransport'
                Effect = 'Deny'
                Principal = '*'
                Action = 's3:*'
                Resource = (New-JsonList $arn "$arn/*")
                Condition = @{ Bool = @{ 'aws:SecureTransport' = 'false' } }
            } `
            @{
                Sid = 'FlowLogWrite'
                Effect = 'Allow'
                Principal = @{ Service = 'delivery.logs.amazonaws.com' }
                Action = 's3:PutObject'
                Resource = "$arn/flow/AWSLogs/$Account/*"
                Condition = @{
                    StringEquals = @{ 'aws:SourceAccount' = $Account }
                    ArnLike = @{ 'aws:SourceArn' = "arn:aws:logs:us-east-1:${Account}:*" }
                }
            } `
            @{
                Sid = 'FlowLogAclCheck'
                Effect = 'Allow'
                Principal = @{ Service = 'delivery.logs.amazonaws.com' }
                Action = 's3:GetBucketAcl'
                Resource = $arn
                Condition = @{
                    StringEquals = @{ 'aws:SourceAccount' = $Account }
                    ArnLike = @{ 'aws:SourceArn' = "arn:aws:logs:us-east-1:${Account}:*" }
                }
            } `
            @{
                Sid = 'AlbLogWrite'
                Effect = 'Allow'
                Principal = @{ Service = 'logdelivery.elasticloadbalancing.amazonaws.com' }
                Action = 's3:PutObject'
                Resource = "$arn/alb/AWSLogs/$Account/*"
                Condition = @{ StringEquals = @{ 'aws:SourceAccount' = $Account } }
            } `
            @{
                Sid = 'AlbLogAclCheck'
                Effect = 'Allow'
                Principal = @{ Service = 'logdelivery.elasticloadbalancing.amazonaws.com' }
                Action = 's3:GetBucketAcl'
                Resource = $arn
                Condition = @{ StringEquals = @{ 'aws:SourceAccount' = $Account } }
            })
    }
    Invoke-Aws s3api put-bucket-policy --bucket $bucket --policy (Get-FileArg $policyPath)
    Invoke-Aws s3api put-bucket-tagging --bucket $bucket --tagging "TagSet=[{Key=Name,Value=$bucket},{Key=Project,Value=$Name},{Key=env,Value=$script:Env}]"
    Set-State BUCKET $bucket
}

function Build-Network([string]$Az1, [string]$Az2) {
    Write-Log "VPC $VpcCidr"
    $vpc = Get-AwsText ec2 create-vpc --cidr-block $VpcCidr `
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$script:VpcName},{Key=Project,Value=$Name},{Key=env,Value=$script:Env}]" `
        --query Vpc.VpcId
    Invoke-Aws ec2 modify-vpc-attribute --vpc-id $vpc --enable-dns-support
    Invoke-Aws ec2 modify-vpc-attribute --vpc-id $vpc --enable-dns-hostnames
    Set-State VPC_ID $vpc

    $igw = Get-AwsText ec2 create-internet-gateway `
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${Name}-igw},{Key=Project,Value=$Name},{Key=env,Value=$script:Env}]" `
        --query InternetGateway.InternetGatewayId
    Invoke-Aws ec2 attach-internet-gateway --internet-gateway-id $igw --vpc-id $vpc
    Set-State IGW_ID $igw

    $pub1 = New-Subnet $vpc $PublicCidrs[0] $Az1 $true "${Name}-public-a"
    $pub2 = New-Subnet $vpc $PublicCidrs[1] $Az2 $true "${Name}-public-b"
    $pri1 = New-Subnet $vpc $PrivateCidrs[0] $Az1 $false "${Name}-private-a"
    $pri2 = New-Subnet $vpc $PrivateCidrs[1] $Az2 $false "${Name}-private-b"
    $iso1 = New-Subnet $vpc $IsolatedCidrs[0] $Az1 $false "${Name}-isolated-a"
    $iso2 = New-Subnet $vpc $IsolatedCidrs[1] $Az2 $false "${Name}-isolated-b"
    Set-State PUBLIC_SUBNET_1 $pub1
    Set-State PUBLIC_SUBNET_2 $pub2
    Set-State PRIVATE_SUBNET_1 $pri1
    Set-State PRIVATE_SUBNET_2 $pri2
    Set-State ISOLATED_SUBNET_1 $iso1
    Set-State ISOLATED_SUBNET_2 $iso2

    $publicRt = New-RouteTable $vpc "${Name}-public-rt"
    Invoke-Aws ec2 create-route --route-table-id $publicRt --destination-cidr-block '0.0.0.0/0' --gateway-id $igw
    Invoke-Aws ec2 associate-route-table --route-table-id $publicRt --subnet-id $pub1
    Invoke-Aws ec2 associate-route-table --route-table-id $publicRt --subnet-id $pub2
    Set-State PUBLIC_RT $publicRt

    $isoRt = New-RouteTable $vpc "${Name}-isolated-rt"
    Invoke-Aws ec2 associate-route-table --route-table-id $isoRt --subnet-id $iso1
    Invoke-Aws ec2 associate-route-table --route-table-id $isoRt --subnet-id $iso2
    Set-State ISOLATED_RT $isoRt

    Write-Log 'NAT Gateway per AZ (private subnets only)'
    $eip1 = Get-AwsText ec2 allocate-address --domain vpc `
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${Name}-nat-a},{Key=Project,Value=$Name},{Key=env,Value=$script:Env}]" `
        --query AllocationId
    $eip2 = Get-AwsText ec2 allocate-address --domain vpc `
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${Name}-nat-b},{Key=Project,Value=$Name},{Key=env,Value=$script:Env}]" `
        --query AllocationId
    $nat1 = Get-AwsText ec2 create-nat-gateway --subnet-id $pub1 --allocation-id $eip1 `
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${Name}-nat-a},{Key=Project,Value=$Name},{Key=env,Value=$script:Env}]" `
        --query NatGateway.NatGatewayId
    $nat2 = Get-AwsText ec2 create-nat-gateway --subnet-id $pub2 --allocation-id $eip2 `
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${Name}-nat-b},{Key=Project,Value=$Name},{Key=env,Value=$script:Env}]" `
        --query NatGateway.NatGatewayId
    Set-State EIP_1 $eip1
    Set-State EIP_2 $eip2
    Set-State NAT_1 $nat1
    Set-State NAT_2 $nat2
    Write-Log 'waiting for NAT gateways'
    Invoke-Aws ec2 wait nat-gateway-available --nat-gateway-ids $nat1 $nat2

    $priRt1 = New-RouteTable $vpc "${Name}-private-rt-a"
    $priRt2 = New-RouteTable $vpc "${Name}-private-rt-b"
    Invoke-Aws ec2 create-route --route-table-id $priRt1 --destination-cidr-block '0.0.0.0/0' --nat-gateway-id $nat1
    Invoke-Aws ec2 create-route --route-table-id $priRt2 --destination-cidr-block '0.0.0.0/0' --nat-gateway-id $nat2
    Invoke-Aws ec2 associate-route-table --route-table-id $priRt1 --subnet-id $pri1
    Invoke-Aws ec2 associate-route-table --route-table-id $priRt2 --subnet-id $pri2
    Set-State PRIVATE_RT_1 $priRt1
    Set-State PRIVATE_RT_2 $priRt2

    $vpce = Get-AwsText ec2 create-vpc-endpoint --vpc-id $vpc --vpc-endpoint-type Gateway `
        --service-name "com.amazonaws.$($env:REGION).s3" `
        --route-table-ids $priRt1 $priRt2 $isoRt `
        --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=${Name}-s3},{Key=Project,Value=$Name},{Key=env,Value=$script:Env}]" `
        --query VpcEndpoint.VpcEndpointId
    Set-State S3_VPCE $vpce
}

function Build-FlowLogs {
    $bucket = Get-State BUCKET
    Write-Log "VPC flow logs -> s3://$bucket/flow"
    $result = Get-AwsJson ec2 create-flow-logs `
        --resource-type VPC `
        --resource-ids (Get-State VPC_ID) `
        --traffic-type ALL `
        --log-destination-type s3 `
        --log-destination "arn:aws:s3:::$bucket/flow" `
        --max-aggregation-interval 60 `
        --destination-options 'FileFormat=parquet,HiveCompatiblePartitions=true,PerHourPartition=true' `
        --tag-specifications "ResourceType=vpc-flow-log,Tags=[{Key=Name,Value=${Name}-flow},{Key=Project,Value=$Name},{Key=env,Value=$script:Env}]"
    if ($result.Unsuccessful) {
        throw "flow log was not created; check the bucket policy. $($result | Out-String)"
    }
    Set-State FLOW_LOG_ID ([string]@($result.FlowLogIds)[0])
}

function Build-Iam {
    Write-Log 'IAM roles (SSM only, no admin)'
    $trust = Join-Path $script:WorkDir 'ec2-trust.json'
    Write-JsonFile $trust @{
        Version = '2012-10-17'
        Statement = (New-JsonList @{
            Effect = 'Allow'
            Principal = @{ Service = 'ec2.amazonaws.com' }
            Action = 'sts:AssumeRole'
        })
    }
    $trustArg = Get-FileArg $trust
    Invoke-Aws iam create-role --role-name "${Name}-app-role" --assume-role-policy-document $trustArg --tags "Key=Project,Value=$Name" "Key=env,Value=$script:Env"
    Invoke-Aws iam attach-role-policy --role-name "${Name}-app-role" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
    Invoke-Aws iam create-role --role-name "${Name}-bastion-role" --assume-role-policy-document $trustArg --tags "Key=Project,Value=$Name" "Key=env,Value=$script:Env"
    Invoke-Aws iam attach-role-policy --role-name "${Name}-bastion-role" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
    Invoke-Aws iam create-instance-profile --instance-profile-name "${Name}-app-profile" --tags "Key=Project,Value=$Name" "Key=env,Value=$script:Env"
    Invoke-Aws iam add-role-to-instance-profile --instance-profile-name "${Name}-app-profile" --role-name "${Name}-app-role"
    Invoke-Aws iam create-instance-profile --instance-profile-name "${Name}-bastion-profile" --tags "Key=Project,Value=$Name" "Key=env,Value=$script:Env"
    Invoke-Aws iam add-role-to-instance-profile --instance-profile-name "${Name}-bastion-profile" --role-name "${Name}-bastion-role"
    Set-State APP_ROLE "${Name}-app-role"
    Set-State BASTION_ROLE "${Name}-bastion-role"
    Set-State APP_PROFILE "${Name}-app-profile"
    Set-State BASTION_PROFILE "${Name}-bastion-profile"
    Write-Log 'waiting for instance profiles to propagate'
    Start-Sleep -Seconds 12
    $arn = Get-AwsText iam get-instance-profile --instance-profile-name "${Name}-app-profile" --query InstanceProfile.Arn
    Set-State APP_PROFILE_ARN $arn
}

function Build-SecurityGroups {
    Write-Log 'security groups'
    $vpc = Get-State VPC_ID
    $alb = Get-AwsText ec2 create-security-group --vpc-id $vpc --group-name "${Name}-alb" `
        --description 'ALB ingress from CloudFront only' --query GroupId
    $app = Get-AwsText ec2 create-security-group --vpc-id $vpc --group-name "${Name}-app" `
        --description 'App ingress from ALB on 80 and bastion on 22' --query GroupId
    $bastion = Get-AwsText ec2 create-security-group --vpc-id $vpc --group-name "${Name}-bastion" `
        --description 'Bastion SSH from operator IP' --query GroupId
    Invoke-Aws ec2 create-tags --resources $alb $app $bastion --tags "Key=Project,Value=$Name" "Key=env,Value=$script:Env"

    $cfPl = Get-AwsText ec2 describe-managed-prefix-lists `
        --filters 'Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing' `
        --query 'PrefixLists[0].PrefixListId'
    if ([string]::IsNullOrWhiteSpace($cfPl) -or $cfPl -eq 'None') {
        throw 'CloudFront origin-facing prefix list not found'
    }
    Invoke-Aws ec2 authorize-security-group-ingress --group-id $alb `
        --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds=[{PrefixListId=$cfPl}]"
    Invoke-Aws ec2 authorize-security-group-ingress --group-id $app --protocol tcp --port 80 --source-group $alb
    Invoke-Aws ec2 authorize-security-group-ingress --group-id $app --protocol tcp --port 22 --source-group $bastion
    Invoke-Aws ec2 authorize-security-group-ingress --group-id $bastion --protocol tcp --port 22 --cidr (Get-State BASTION_SSH_CIDR)
    Set-State ALB_SG $alb
    Set-State APP_SG $app
    Set-State BASTION_SG $bastion
    Set-State CF_PREFIX_LIST $cfPl
}

function Build-Bastion {
    Write-Log 'bastion in public subnet'
    $ami = Get-AwsText ssm get-parameter `
        --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 `
        --query Parameter.Value
    Set-State AMI_ID $ami
    $keyName = "${Name}-bastion"
    $keyPath = Join-Path $Root "$keyName.pem"
    $kp = Get-AwsJson ec2 create-key-pair --key-name $keyName `
        --tag-specifications "ResourceType=key-pair,Tags=[{Key=Name,Value=$keyName},{Key=Project,Value=$Name},{Key=env,Value=$script:Env}]"
    Write-Utf8NoBom $keyPath ($kp.KeyMaterial.Trim() + "`n")
    Set-State KEY_NAME $keyName

    $id = Get-AwsText ec2 run-instances `
        --image-id $ami `
        --instance-type $InstanceType `
        --key-name $keyName `
        --subnet-id (Get-State PUBLIC_SUBNET_1) `
        --security-group-ids (Get-State BASTION_SG) `
        --iam-instance-profile "Name=${Name}-bastion-profile" `
        --metadata-options 'HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1' `
        --count 1 `
        --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' `
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${Name}-bastion},{Key=Project,Value=$Name},{Key=env,Value=$script:Env}]" `
        --query 'Instances[0].InstanceId'
    Set-State BASTION_ID $id
    Invoke-Aws ec2 wait instance-running --instance-ids $id
    $ip = Get-AwsText ec2 describe-instances --instance-ids $id --query 'Reservations[0].Instances[0].PublicIpAddress'
    Set-State BASTION_PUBLIC_IP $ip
}

function Build-Alb {
    Write-Log 'public ALB'
    $arn = Get-AwsText elbv2 create-load-balancer `
        --name "${Name}-alb" `
        --type application `
        --scheme internet-facing `
        --subnets (Get-State PUBLIC_SUBNET_1) (Get-State PUBLIC_SUBNET_2) `
        --security-groups (Get-State ALB_SG) `
        --tags "Key=Name,Value=${Name}-alb" "Key=Project,Value=$Name" "Key=env,Value=$script:Env" `
        --query 'LoadBalancers[0].LoadBalancerArn'
    Set-State ALB_ARN $arn
    Invoke-Aws elbv2 wait load-balancer-available --load-balancer-arns $arn
    $dns = Get-AwsText elbv2 describe-load-balancers --load-balancer-arns $arn --query 'LoadBalancers[0].DNSName'
    Set-State ALB_DNS $dns

    $tg = Get-AwsText elbv2 create-target-group `
        --name "${Name}-app-tg" `
        --protocol HTTP --port 80 `
        --vpc-id (Get-State VPC_ID) `
        --target-type instance `
        --health-check-protocol HTTP `
        --health-check-path / `
        --health-check-interval-seconds 30 `
        --health-check-timeout-seconds 5 `
        --healthy-threshold-count 2 `
        --unhealthy-threshold-count 3 `
        --matcher HttpCode=200 `
        --tags "Key=Name,Value=${Name}-app-tg" "Key=Project,Value=$Name" "Key=env,Value=$script:Env" `
        --query 'TargetGroups[0].TargetGroupArn'
    Invoke-Aws elbv2 modify-target-group-attributes --target-group-arn $tg `
        --attributes 'Key=deregistration_delay.timeout_seconds,Value=30'
    Set-State TG_ARN $tg

    $secret = New-RandomHex 24
    Set-State ORIGIN_SECRET $secret
    $listener = Get-AwsText elbv2 create-listener `
        --load-balancer-arn $arn `
        --protocol HTTP --port 80 `
        --default-actions '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"403","ContentType":"text/plain","MessageBody":"forbidden"}}]' `
        --query 'Listeners[0].ListenerArn'
    $condPath = Join-Path $script:WorkDir 'alb-conditions.json'
    $actPath = Join-Path $script:WorkDir 'alb-actions.json'
    Write-JsonFile $condPath (New-JsonList @{
        Field = 'http-header'
        HttpHeaderConfig = @{ HttpHeaderName = 'X-Origin-Verify'; Values = (New-JsonList $secret) }
    })
    Write-JsonFile $actPath (New-JsonList @{ Type = 'forward'; TargetGroupArn = $tg })
    Invoke-Aws elbv2 create-rule --listener-arn $listener --priority 1 `
        --conditions (Get-FileArg $condPath) --actions (Get-FileArg $actPath)
    Set-State LISTENER_ARN $listener

    Invoke-Aws elbv2 modify-load-balancer-attributes --load-balancer-arn $arn --attributes `
        'Key=access_logs.s3.enabled,Value=true' `
        "Key=access_logs.s3.bucket,Value=$(Get-State BUCKET)" `
        'Key=access_logs.s3.prefix,Value=alb' `
        'Key=deletion_protection.enabled,Value=true' `
        'Key=routing.http.drop_invalid_header_fields.enabled,Value=true' `
        'Key=idle_timeout.timeout_seconds,Value=60'
}

function Build-LaunchTemplate {
    Write-Log 'launch template + sample userdata'
    $userData = @'
#!/bin/bash
set -euxo pipefail
dnf install -y httpd
TOKEN="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")"
IID="$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)"
AZ="$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)"
cat > /var/www/html/index.html <<HTML
<!doctype html>
<meta charset="utf-8">
<title>well-architected</title>
<h1>well-architected sample</h1>
<p>instance ${IID} in ${AZ}</p>
HTML
systemctl enable --now httpd
'@
    $userData = $userData -replace "`r`n", "`n" -replace "`r", "`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userData))
    $ltPath = Join-Path $script:WorkDir 'lt.json'
    Write-JsonFile $ltPath @{
        ImageId = (Get-State AMI_ID)
        InstanceType = $InstanceType
        IamInstanceProfile = @{ Arn = (Get-State APP_PROFILE_ARN) }
        SecurityGroupIds = (New-JsonList (Get-State APP_SG))
        UserData = $b64
        MetadataOptions = @{
            HttpTokens = 'required'
            HttpEndpoint = 'enabled'
            HttpPutResponseHopLimit = 1
        }
        BlockDeviceMappings = (New-JsonList @{
            DeviceName = '/dev/xvda'
            Ebs = @{
                VolumeSize = 8
                VolumeType = 'gp3'
                Encrypted = $true
                DeleteOnTermination = $true
            }
        })
        TagSpecifications = (New-JsonList @{
            ResourceType = 'instance'
            Tags = (New-JsonList @{ Key = 'Name'; Value = "${Name}-app" } @{ Key = 'Project'; Value = $Name } @{ Key = 'env'; Value = $script:Env })
        })
    }
    $ltId = Get-AwsText ec2 create-launch-template `
        --launch-template-name "${Name}-app" `
        --version-description 'sample-httpd' `
        --launch-template-data (Get-FileArg $ltPath) `
        --tag-specifications "ResourceType=launch-template,Tags=[{Key=Name,Value=${Name}-app},{Key=Project,Value=$Name},{Key=env,Value=$script:Env}]" `
        --query LaunchTemplate.LaunchTemplateId
    Set-State LAUNCH_TEMPLATE_ID $ltId
}

function Build-Asg {
    Write-Log 'ASG in private subnets'
    Invoke-Aws autoscaling create-auto-scaling-group `
        --auto-scaling-group-name "${Name}-app" `
        --launch-template "LaunchTemplateId=$(Get-State LAUNCH_TEMPLATE_ID),Version=`$Latest" `
        --min-size 1 --max-size 2 --desired-capacity 1 `
        --vpc-zone-identifier "$(Get-State PRIVATE_SUBNET_1),$(Get-State PRIVATE_SUBNET_2)" `
        --target-group-arns (Get-State TG_ARN) `
        --health-check-type ELB `
        --health-check-grace-period 300 `
        --tags "Key=Name,Value=${Name}-app,PropagateAtLaunch=true" "Key=Project,Value=$Name,PropagateAtLaunch=true" "Key=env,Value=$script:Env,PropagateAtLaunch=true"
    Set-State ASG_NAME "${Name}-app"

    $albArn = Get-State ALB_ARN
    $tgArn = Get-State TG_ARN
    $albSuffix = $albArn.Substring($albArn.LastIndexOf('loadbalancer/') + 13)
    $tgSuffix = $tgArn.Substring($tgArn.LastIndexOf(':') + 1)
    $label = "$albSuffix/$tgSuffix"
    Invoke-Aws autoscaling put-scaling-policy `
        --auto-scaling-group-name "${Name}-app" `
        --policy-name "${Name}-alb-requests" `
        --policy-type TargetTrackingScaling `
        --target-tracking-configuration "PredefinedMetricSpecification={PredefinedMetricType=ALBRequestCountPerTarget,ResourceLabel=$label},TargetValue=100,DisableScaleIn=false"
}

function Build-Waf {
    Write-Log 'WAF on CloudFront (must be us-east-1)'
    $groups = @(
        @{ Name = 'AWSManagedRulesAmazonIpReputationList'; Metric = 'ip-reputation' }
        @{ Name = 'AWSManagedRulesCommonRuleSet'; Metric = 'common' }
        @{ Name = 'AWSManagedRulesKnownBadInputsRuleSet'; Metric = 'known-bad-inputs' }
    )
    $rules = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $groups.Count; $i++) {
        $rules.Add(@{
            Name = $groups[$i].Name
            Priority = $i
            Statement = @{ ManagedRuleGroupStatement = @{ VendorName = 'AWS'; Name = $groups[$i].Name } }
            OverrideAction = @{ None = @{} }
            VisibilityConfig = @{
                SampledRequestsEnabled = $true
                CloudWatchMetricsEnabled = $true
                MetricName = $groups[$i].Metric
            }
        })
    }
    $rulesPath = Join-Path $script:WorkDir 'waf-rules.json'
    Write-JsonFile $rulesPath $rules
    $summary = Get-AwsText wafv2 create-web-acl `
        --name "${Name}-cloudfront" `
        --scope CLOUDFRONT `
        --region us-east-1 `
        --default-action '{"Allow":{}}' `
        --description 'CloudFront edge ACL: IP reputation, common rules, known bad inputs' `
        --rules (Get-FileArg $rulesPath) `
        --visibility-config "SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=${Name}-cloudfront" `
        --tags "Key=Project,Value=$Name" "Key=env,Value=$script:Env" `
        --query 'Summary.[ARN,Id]'
    $parts = @($summary -split '\s+' | Where-Object { $_ })
    if ($parts.Count -lt 2) { throw "unexpected WAF create output: $summary" }
    Set-State WAF_ARN $parts[0]
    Set-State WAF_ID $parts[1]
}

function Build-CloudFront {
    Write-Log 'CloudFront'
    $cachePolicy = Get-AwsText cloudfront list-cache-policies --type managed `
        --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='Managed-CachingDisabled'].CachePolicy.Id | [0]"
    if ([string]::IsNullOrWhiteSpace($cachePolicy) -or $cachePolicy -eq 'None') {
        throw 'managed cache policy CachingDisabled not found'
    }
    $cfPath = Join-Path $script:WorkDir 'cf.json'
    Write-JsonFile $cfPath @{
        CallerReference = 'wa-' + [int]([DateTime]::UtcNow - [DateTime]'1970-01-01Z').TotalSeconds
        Comment = 'well-architected sample'
        Enabled = $true
        PriceClass = 'PriceClass_100'
        HttpVersion = 'http2'
        WebACLId = (Get-State WAF_ARN)
        Origins = @{
            Quantity = 1
            Items = (New-JsonList @{
                Id = 'alb'
                DomainName = (Get-State ALB_DNS)
                CustomHeaders = @{
                    Quantity = 1
                    Items = (New-JsonList @{
                        HeaderName = 'X-Origin-Verify'
                        HeaderValue = (Get-State ORIGIN_SECRET)
                    })
                }
                CustomOriginConfig = @{
                    HTTPPort = 80
                    HTTPSPort = 443
                    OriginProtocolPolicy = 'http-only'
                    OriginSslProtocols = @{
                        Quantity = 1
                        Items = (New-JsonList 'TLSv1.2')
                    }
                }
            })
        }
        DefaultCacheBehavior = @{
            TargetOriginId = 'alb'
            ViewerProtocolPolicy = 'redirect-to-https'
            CachePolicyId = $cachePolicy
            Compress = $true
            AllowedMethods = @{
                Quantity = 7
                Items = (New-JsonList 'GET' 'HEAD' 'OPTIONS' 'PUT' 'POST' 'PATCH' 'DELETE')
                CachedMethods = @{
                    Quantity = 2
                    Items = (New-JsonList 'GET' 'HEAD')
                }
            }
        }
        ViewerCertificate = @{
            CloudFrontDefaultCertificate = $true
        }
    }
    $created = Get-AwsJson cloudfront create-distribution --distribution-config (Get-FileArg $cfPath)
    Set-State CF_ID ([string]$created.Distribution.Id)
    Set-State CF_DOMAIN ([string]$created.Distribution.DomainName)
    $cfArn = "arn:aws:cloudfront::$($script:S['ACCOUNT_ID']):distribution/$($created.Distribution.Id)"
    Invoke-Aws cloudfront tag-resource --resource $cfArn `
        --tags "Items=[{Key=Name,Value=${Name}-cloudfront},{Key=Project,Value=$Name},{Key=env,Value=$script:Env}]"
}

function Build-Alarm {
    $albArn = Get-State ALB_ARN
    $albDim = $albArn.Substring($albArn.LastIndexOf('loadbalancer/') + 13)
    Invoke-Aws cloudwatch put-metric-alarm `
        --alarm-name "${Name}-alb-5xx" `
        --alarm-description 'ALB 5xx count' `
        --namespace AWS/ApplicationELB `
        --metric-name HTTPCode_ELB_5XX_Count `
        --dimensions "Name=LoadBalancer,Value=$albDim" `
        --statistic Sum --period 60 --evaluation-periods 1 --threshold 10 `
        --comparison-operator GreaterThanThreshold `
        --treat-missing-data notBreaching `
        --tags "Key=Project,Value=$Name" "Key=env,Value=$script:Env"
    Set-State ALARM_NAME "${Name}-alb-5xx"
}

function Start-Build {
    Import-WaConfig
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        throw 'AWS CLI is not on PATH'
    }
    if (Test-Path -LiteralPath $script:StateFile) {
        throw "state file already exists ($script:StateFile). Run: .\create.ps1 -Action destroy"
    }
    New-WorkDir
    $script:S = @{}
    $configured = ''
    try { $configured = (Invoke-AwsRaw configure get region) } catch { $configured = '' }
    if ($configured -and $configured -ne 'us-east-1') {
        Write-Log "ignoring configured region $configured; this stack is us-east-1"
    }

    $account = Get-AwsText sts get-caller-identity --query Account
    $az1 = Get-AwsText ec2 describe-availability-zones --filters 'Name=state,Values=available' --query 'AvailabilityZones[0].ZoneName'
    $az2 = Get-AwsText ec2 describe-availability-zones --filters 'Name=state,Values=available' --query 'AvailabilityZones[1].ZoneName'
    if ([string]::IsNullOrWhiteSpace($az1) -or [string]::IsNullOrWhiteSpace($az2) -or $az1 -eq $az2) {
        throw 'need two availability zones'
    }
    Set-State NAME $Name
    Set-State ACCOUNT_ID $account
    Set-State AZ1 $az1
    Set-State AZ2 $az2
    Write-Log "account=$account region=$($env:REGION) az=$az1,$az2"

    $sshCidr = $env:BASTION_SSH_CIDR
    if ([string]::IsNullOrWhiteSpace($sshCidr)) {
        $ip = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com').ToString().Trim()
        $sshCidr = "$ip/32"
    }
    if ($sshCidr -notmatch '/') { throw "BastionSshCidr must be a CIDR, got: $sshCidr" }
    Set-State BASTION_SSH_CIDR $sshCidr
    Write-Log "bastion SSH restricted to $sshCidr"

    Build-Bucket $account
    Build-Network $az1 $az2
    Build-FlowLogs
    Build-Iam
    Build-SecurityGroups
    Build-Bastion
    Build-Alb
    Build-LaunchTemplate
    Build-Asg
    Build-Waf
    Build-CloudFront
    Build-Alarm

    Write-Host @"

Stack created. CloudFront stays InProgress for several minutes; the URL 200s after it deploys.
App instances need about 3 minutes for userdata (httpd) before the target group goes healthy.

CloudFront     https://$(Get-State CF_DOMAIN)/
ALB (direct)   http://$(Get-State ALB_DNS)/   expected 403 without the origin header
Bastion        $(Get-State BASTION_PUBLIC_IP)   ssh -i $Root\$(Get-State KEY_NAME).pem ec2-user@$(Get-State BASTION_PUBLIC_IP)
Bucket         $(Get-State BUCKET)
State          $script:StateFile

Origin header (also in the state file):
  X-Origin-Verify: $(Get-State ORIGIN_SECRET)

Tear down:
  .\create.ps1 -Action destroy
"@
}

function Get-JsonObjectAfterKey([string]$Json, [string]$Key) {
    $marker = '"' + $Key + '"'
    $keyAt = $Json.IndexOf($marker)
    if ($keyAt -lt 0) { throw "JSON key $Key not found" }
    $start = $Json.IndexOf('{', $keyAt)
    $depth = 0
    for ($i = $start; $i -lt $Json.Length; $i++) {
        $ch = $Json[$i]
        if ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) { return $Json.Substring($start, $i - $start + 1) }
        }
    }
    throw "unterminated JSON object for $Key"
}

function Clear-VersionedBucket([string]$Bucket) {
    $keyMarker = ''
    $versionMarker = ''
    do {
        $args = @('s3api', 'list-object-versions', '--bucket', $Bucket, '--output', 'json')
        if ($keyMarker) {
            $args += @('--key-marker', $keyMarker, '--version-id-marker', $versionMarker)
        }
        $raw = Invoke-AwsRaw @args
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw -eq 'null') { break }
        $page = $raw | ConvertFrom-Json
        $objs = New-Object 'System.Collections.Generic.List[object]'
        foreach ($kind in @('Versions', 'DeleteMarkers')) {
            $list = $page.$kind
            if ($null -eq $list) { continue }
            foreach ($item in @($list)) {
                if ($null -eq $item -or [string]::IsNullOrEmpty([string]$item.Key)) { continue }
                $objs.Add(@{ Key = [string]$item.Key; VersionId = [string]$item.VersionId })
            }
        }
        for ($i = 0; $i -lt $objs.Count; $i += 1000) {
            $chunk = New-Object 'System.Collections.Generic.List[object]'
            $end = [Math]::Min($i + 999, $objs.Count - 1)
            for ($j = $i; $j -le $end; $j++) { $chunk.Add($objs[$j]) }
            $delPath = Join-Path $script:WorkDir 'delete.json'
            Write-JsonFile $delPath @{ Objects = $chunk; Quiet = $true }
            Invoke-Aws s3api delete-objects --bucket $Bucket --delete (Get-FileArg $delPath)
        }
        $truncated = ($page.IsTruncated -eq $true)
        $keyMarker = [string]$page.NextKeyMarker
        $versionMarker = [string]$page.NextVersionIdMarker
    } while ($truncated)
}

function Remove-IamRole([string]$Profile, [string]$RoleName) {
    if ($Profile) {
        Invoke-BestEffort { Invoke-Aws iam remove-role-from-instance-profile --instance-profile-name $Profile --role-name $RoleName }
        Invoke-BestEffort { Invoke-Aws iam delete-instance-profile --instance-profile-name $Profile }
    }
    if ($RoleName) {
        Invoke-BestEffort { Invoke-Aws iam detach-role-policy --role-name $RoleName --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore }
        Invoke-BestEffort { Invoke-Aws iam delete-role --role-name $RoleName }
    }
}

function Start-Destroy {
    Import-WaConfig
    if (-not (Test-Path -LiteralPath $script:StateFile)) {
        throw "no state file at $script:StateFile"
    }
    $raw = [System.IO.File]::ReadAllText($script:StateFile)
    $script:S = $raw | ConvertFrom-Json
    $savedName = Get-State NAME
    if ($savedName) { $script:Name = $savedName }
    New-WorkDir
    Write-Log "destroying stack from $script:StateFile"

    $cfId = Get-State CF_ID
    if ($cfId) {
        Write-Log "disable CloudFront $cfId (this wait is the slow part)"
        $wrapper = Invoke-AwsRaw cloudfront get-distribution-config --id $cfId --output json
        $etag = ([regex]::Match($wrapper, '"ETag"\s*:\s*"([^"]+)"')).Groups[1].Value
        $config = Get-JsonObjectAfterKey $wrapper 'DistributionConfig'
        $disabled = [regex]::Replace($config, '"Enabled"\s*:\s*true', '"Enabled": false', 1)
        $offPath = Join-Path $script:WorkDir 'cf-off.json'
        Write-Utf8NoBom $offPath $disabled
        Invoke-BestEffort { Invoke-Aws cloudfront update-distribution --id $cfId --if-match $etag --distribution-config (Get-FileArg $offPath) }
        Invoke-BestEffort { Invoke-Aws cloudfront wait distribution-deployed --id $cfId }
        Invoke-BestEffort {
            $etag2 = Get-AwsText cloudfront get-distribution-config --id $cfId --query ETag
            Invoke-Aws cloudfront delete-distribution --id $cfId --if-match $etag2
        }
    }

    $wafId = Get-State WAF_ID
    if ($wafId) {
        Invoke-BestEffort {
            $lock = Get-AwsText wafv2 get-web-acl --scope CLOUDFRONT --region us-east-1 --name "${Name}-cloudfront" --id $wafId --query LockToken
            if ($lock -and $lock -ne 'None') {
                Invoke-Aws wafv2 delete-web-acl --scope CLOUDFRONT --region us-east-1 --name "${Name}-cloudfront" --id $wafId --lock-token $lock
            }
        }
    }

    $alarm = Get-State ALARM_NAME
    if ($alarm) { Invoke-BestEffort { Invoke-Aws cloudwatch delete-alarms --alarm-names $alarm } }

    $albArn = Get-State ALB_ARN
    if ($albArn) {
        Invoke-BestEffort { Invoke-Aws elbv2 modify-load-balancer-attributes --load-balancer-arn $albArn --attributes 'Key=deletion_protection.enabled,Value=false' }
        Invoke-BestEffort { Invoke-Aws elbv2 delete-load-balancer --load-balancer-arn $albArn }
        Invoke-BestEffort { Invoke-Aws elbv2 wait load-balancers-deleted --load-balancer-arns $albArn }
    }
    $tgArn = Get-State TG_ARN
    if ($tgArn) { Invoke-BestEffort { Invoke-Aws elbv2 delete-target-group --target-group-arn $tgArn } }

    $asg = Get-State ASG_NAME
    if ($asg) {
        Invoke-BestEffort { Invoke-Aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $asg --force-delete }
        Invoke-BestEffort { Invoke-Aws autoscaling wait group-not-exists --auto-scaling-group-names $asg }
    }
    $ltId = Get-State LAUNCH_TEMPLATE_ID
    if ($ltId) { Invoke-BestEffort { Invoke-Aws ec2 delete-launch-template --launch-template-id $ltId } }

    $bastion = Get-State BASTION_ID
    if ($bastion) {
        Invoke-BestEffort { Invoke-Aws ec2 terminate-instances --instance-ids $bastion }
        Invoke-BestEffort { Invoke-Aws ec2 wait instance-terminated --instance-ids $bastion }
    }
    $keyName = Get-State KEY_NAME
    if ($keyName) {
        Invoke-BestEffort { Invoke-Aws ec2 delete-key-pair --key-name $keyName }
        Remove-Item -LiteralPath (Join-Path $Root "$keyName.pem") -Force -ErrorAction SilentlyContinue
    }

    $flow = Get-State FLOW_LOG_ID
    if ($flow) { Invoke-BestEffort { Invoke-Aws ec2 delete-flow-logs --flow-log-ids $flow } }
    $vpce = Get-State S3_VPCE
    if ($vpce) { Invoke-BestEffort { Invoke-Aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $vpce } }

    $nat1 = Get-State NAT_1
    $nat2 = Get-State NAT_2
    if ($nat1) { Invoke-BestEffort { Invoke-Aws ec2 delete-nat-gateway --nat-gateway-id $nat1 } }
    if ($nat2) { Invoke-BestEffort { Invoke-Aws ec2 delete-nat-gateway --nat-gateway-id $nat2 } }
    if ($nat1 -and $nat2) {
        Write-Log 'waiting for NAT gateways to delete'
        Invoke-BestEffort { Invoke-Aws ec2 wait nat-gateway-deleted --nat-gateway-ids $nat1 $nat2 }
    }
    elseif ($nat1) { Invoke-BestEffort { Invoke-Aws ec2 wait nat-gateway-deleted --nat-gateway-ids $nat1 } }
    elseif ($nat2) { Invoke-BestEffort { Invoke-Aws ec2 wait nat-gateway-deleted --nat-gateway-ids $nat2 } }
    $eip1 = Get-State EIP_1
    $eip2 = Get-State EIP_2
    if ($eip1) { Invoke-BestEffort { Invoke-Aws ec2 release-address --allocation-id $eip1 } }
    if ($eip2) { Invoke-BestEffort { Invoke-Aws ec2 release-address --allocation-id $eip2 } }

    $vpc = Get-State VPC_ID
    if ($vpc) {
        $igw = Get-State IGW_ID
        if ($igw) {
            Invoke-BestEffort { Invoke-Aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $vpc }
            Invoke-BestEffort { Invoke-Aws ec2 delete-internet-gateway --internet-gateway-id $igw }
        }
        foreach ($sub in @(
            (Get-State PUBLIC_SUBNET_1), (Get-State PUBLIC_SUBNET_2),
            (Get-State PRIVATE_SUBNET_1), (Get-State PRIVATE_SUBNET_2),
            (Get-State ISOLATED_SUBNET_1), (Get-State ISOLATED_SUBNET_2)
        )) {
            if ($sub) { Invoke-BestEffort { Invoke-Aws ec2 delete-subnet --subnet-id $sub } }
        }
        foreach ($rt in @((Get-State PUBLIC_RT), (Get-State PRIVATE_RT_1), (Get-State PRIVATE_RT_2), (Get-State ISOLATED_RT))) {
            if ($rt) { Invoke-BestEffort { Invoke-Aws ec2 delete-route-table --route-table-id $rt } }
        }
        foreach ($sg in @((Get-State ALB_SG), (Get-State APP_SG), (Get-State BASTION_SG))) {
            if ($sg) { Invoke-BestEffort { Invoke-Aws ec2 delete-security-group --group-id $sg } }
        }
        Invoke-BestEffort { Invoke-Aws ec2 delete-vpc --vpc-id $vpc }
    }

    $bucket = Get-State BUCKET
    if ($bucket) {
        Write-Log "empty and delete $bucket"
        Invoke-BestEffort { Clear-VersionedBucket $bucket }
        Invoke-BestEffort { Invoke-Aws s3api delete-bucket --bucket $bucket }
    }

    Remove-IamRole (Get-State APP_PROFILE) (Get-State APP_ROLE)
    Remove-IamRole (Get-State BASTION_PROFILE) (Get-State BASTION_ROLE)
    Remove-Item -LiteralPath $script:StateFile -Force -ErrorAction SilentlyContinue
    Write-Log 'destroyed'
}

try {
    switch ($Action) {
        { $_ -in @('up', 'create') } { Start-Build }
        { $_ -in @('destroy', 'down') } { Start-Destroy }
    }
}
finally {
    Remove-WorkDir
}
