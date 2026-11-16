# Windows activity generator (run ON the Windows VM in an elevated PowerShell).
# Produces benign failed/successful logons, process creation, PowerShell script block
# logging events and temporary local account changes. The temp user is removed at the end
# of every run (idempotent). Usage: .\generate-activity.ps1 [-Rounds 5]
param([int]$Rounds = 5)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.DirectoryServices.AccountManagement

$tmpUser = 'demo_tmp_user'
# Random throwaway password, never stored
$chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!#%'
$tmpPass = -join (1..24 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })

function Remove-DemoUser {
    if (Get-LocalUser -Name $tmpUser -ErrorAction SilentlyContinue) { Remove-LocalUser -Name $tmpUser }
}
Remove-DemoUser

try {
    $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Machine')
    for ($i = 1; $i -le $Rounds; $i++) {
        Write-Host "round $i/$Rounds"

        # Failed logons (event 4625)
        foreach ($u in 'administrator', 'svc_backup', 'alice', $tmpUser) {
            [void]$ctx.ValidateCredentials($u, 'NotThePassword-1!')
        }

        # Account management (4720/4732/4738) and a successful logon (4624)
        $secure = ConvertTo-SecureString $tmpPass -AsPlainText -Force
        New-LocalUser -Name $tmpUser -Password $secure -Description 'temporary demo user' | Out-Null
        Add-LocalGroupMember -Group 'Users' -Member $tmpUser -ErrorAction SilentlyContinue
        [void]$ctx.ValidateCredentials($tmpUser, $tmpPass)
        Remove-DemoUser

        # Process creation (Sysmon 1 / 4688)
        whoami | Out-Null; ipconfig | Out-Null; hostname | Out-Null
        net user | Out-Null; tasklist | Out-Null; cmd.exe /c 'echo activity' | Out-Null

        # PowerShell script block logging (4104), including a benign encoded command
        Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 | Out-Null
        Get-Service | Where-Object { $_.Status -eq 'Running' } | Out-Null
        Get-ChildItem C:\Users\Public -ErrorAction SilentlyContinue | Out-Null
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Get-Date'))
        powershell.exe -NoProfile -EncodedCommand $enc | Out-Null

        Start-Sleep -Seconds 2
    }
} finally {
    Remove-DemoUser
}
Write-Host 'done'
