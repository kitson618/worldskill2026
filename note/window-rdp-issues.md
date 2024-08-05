```bash
Set-Item WSMan:\localhost\Client\TrustedHosts -Value *
Enter-PSSession -ComputerName PvtIP -Credential USERNAME
net localgroup "Remote Desktop Users" "USERNAME" /add

```