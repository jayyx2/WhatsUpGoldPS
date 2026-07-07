<#
.SYNOPSIS
    Populate the WhatsUpGoldPS DPAPI vault with provider credentials and
    optionally schedule recurring discovery tasks — all in one command.

.DESCRIPTION
    Run this script ONCE from an elevated (Run as Administrator) PowerShell
    prompt. It will:

      1. Set the vault to LocalMachine scope (SYSTEM-accessible) by default.
      2. Guide you through credential entry for each selected provider.
      3. Save every credential encrypted into the DPAPI vault.
      4. Print (or execute) the Register-DiscoveryScheduledTask.ps1 commands
         needed to schedule each provider's discovery run.

    After this script completes, ALL future discovery runs (scheduled or
    manual with -NonInteractive) will read credentials from the vault
    automatically — no password prompts.

    LocalMachine vs CurrentUser vault:
      LocalMachine (default) — any administrator or SYSTEM process on THIS
        machine can decrypt. Required for scheduled tasks running as SYSTEM.
      CurrentUser — only YOUR user account on this machine can decrypt.
        Suitable when scheduling tasks as yourself (not SYSTEM).

.PARAMETER VaultScope
    DPAPI scope: 'LocalMachine' (default, SYSTEM-accessible) or 'CurrentUser'.

.PARAMETER Providers
    Which providers to configure. If omitted, an interactive menu is shown.
    Valid: Azure, AWS, Proxmox, LoadMaster, Windows, CiscoWLC, CUCM

.PARAMETER Action
    Discovery action each scheduled task will perform.
    Default: Dashboard. Options: Dashboard, PushToWUG, ExportJSON, None.

.PARAMETER TriggerType
    Schedule frequency: Daily (default) or Hourly.

.PARAMETER TimeOfDay
    Time for daily runs (HH:mm). Default: '02:00'.

.PARAMETER RepeatIntervalMinutes
    For Hourly trigger: interval in minutes. Default: 60.

.PARAMETER OutputPath
    Base directory for dashboards and logs.
    Default: C:\ProgramData\WhatsUpGoldPS\Output (LocalMachine scope)
             %LOCALAPPDATA%\WhatsUpGoldPS\DiscoveryHelpers\Output (CurrentUser)

.PARAMETER Schedule
    Register scheduled tasks immediately after vault population.
    If omitted, the commands to schedule are printed instead.

.PARAMETER RunNow
    Start each scheduled task immediately after registering it.

.PARAMETER Force
    Overwrite existing vault entries without prompting.

.EXAMPLE
    # Full guided experience — interactive prompts for providers + credentials
    .\Initialize-WUGDiscoveryVault.ps1

.EXAMPLE
    # Pre-select providers; still prompts for credentials
    .\Initialize-WUGDiscoveryVault.ps1 -Providers Azure,Proxmox,Windows

.EXAMPLE
    # Configure + schedule + run immediately (dashboard-only)
    .\Initialize-WUGDiscoveryVault.ps1 -Providers Proxmox -Schedule -RunNow -Action Dashboard

.EXAMPLE
    # CurrentUser vault for tasks that run as yourself
    .\Initialize-WUGDiscoveryVault.ps1 -VaultScope CurrentUser -Providers Azure

.NOTES
    Author  : jason@wug.ninja
    Requires: PowerShell 5.1+, Administrator rights (for LocalMachine vault)
    Encoding: UTF-8 BOM
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('LocalMachine', 'CurrentUser')]
    [string]$VaultScope = 'LocalMachine',

    [ValidateSet('Azure', 'AWS', 'Proxmox', 'LoadMaster', 'Windows', 'CiscoWLC', 'CUCM')]
    [string[]]$Providers,

    [ValidateSet('Dashboard', 'PushToWUG', 'ExportJSON', 'ShowTable', 'None')]
    [string]$Action = 'Dashboard',

    [ValidateSet('Daily', 'Hourly')]
    [string]$TriggerType = 'Daily',

    [string]$TimeOfDay = '02:00',

    [int]$RepeatIntervalMinutes = 60,

    [string]$OutputPath,

    [switch]$Schedule,

    [switch]$RunNow,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$scriptDir    = Split-Path $MyInvocation.MyCommand.Path -Parent
$discoveryDir = $scriptDir   # This script lives in helpers/discovery/

# ============================================================================
# Admin check (required for LocalMachine vault)
# ============================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and $VaultScope -eq 'LocalMachine') {
    Write-Host ''
    Write-Host '  [ERROR] Administrator rights are required to write the LocalMachine vault.' -ForegroundColor Red
    Write-Host '  Please re-run from an elevated (Run as Administrator) PowerShell prompt.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Alternatively, use -VaultScope CurrentUser to use the per-user vault.' -ForegroundColor DarkGray
    Write-Host '  Note: CurrentUser vault cannot be read by SYSTEM scheduled tasks.' -ForegroundColor DarkGray
    Write-Host ''
    return
}

# ============================================================================
# Load DiscoveryHelpers + set vault scope
# ============================================================================
$helpersPath = Join-Path $discoveryDir 'DiscoveryHelpers.ps1'
if (-not (Test-Path $helpersPath)) {
    Write-Error "DiscoveryHelpers.ps1 not found at '$helpersPath'. Cannot continue."
    return
}
. $helpersPath
Set-DiscoveryVaultScope -Scope $VaultScope

# ============================================================================
# Output path
# ============================================================================
if (-not $OutputPath) {
    if ($VaultScope -eq 'LocalMachine') {
        $OutputPath = Join-Path $env:ProgramData 'WhatsUpGoldPS\Output'
    }
    else {
        $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
    }
}
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# ============================================================================
# Helper functions
# ============================================================================
function Write-Banner {
    param([string]$Title)
    Write-Host ''
    Write-Host '  =================================================================' -ForegroundColor DarkCyan
    Write-Host "   $Title" -ForegroundColor Cyan
    Write-Host '  =================================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-VaultSaved {
    param([string]$Name, [string]$Description)
    Write-Host "    [OK] $Description" -ForegroundColor Green
    Write-Host "         Vault key: $Name" -ForegroundColor DarkGray
}

function ToSS { param([string]$v)
    if ([string]::IsNullOrEmpty($v)) {
        $ss = New-Object System.Security.SecureString; $ss.MakeReadOnly(); return $ss
    }
    return (ConvertTo-SecureString -String $v -AsPlainText -Force)
}

function ReadSecure {
    param([string]$Prompt)
    $ss = Read-Host -AsSecureString -Prompt "    $Prompt"
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Track what was saved (for scheduling output)
$script:SavedProviders = [System.Collections.Generic.List[hashtable]]::new()

# ============================================================================
# Banner
# ============================================================================
Clear-Host
Write-Host ''
Write-Host '  =================================================================' -ForegroundColor Cyan
Write-Host '   WhatsUpGoldPS Discovery - Vault Initialization' -ForegroundColor White
Write-Host '  =================================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Vault Scope : $VaultScope" -ForegroundColor $(if ($VaultScope -eq 'LocalMachine') { 'Green' } else { 'Yellow' })
Write-Host "  Vault Path  : $script:DiscoveryVaultPath" -ForegroundColor White
Write-Host "  Output Path : $OutputPath" -ForegroundColor White
Write-Host "  Action      : $Action" -ForegroundColor White
Write-Host "  Schedule    : $(if ($Schedule) { 'Yes — tasks will be registered after vault setup' } else { 'No — commands will be printed' })" -ForegroundColor White
Write-Host ''
if ($VaultScope -eq 'LocalMachine') {
    Write-Host '  Credentials will be encrypted using the MACHINE key.' -ForegroundColor Gray
    Write-Host '  Any administrator or SYSTEM process on this machine can use them.' -ForegroundColor Gray
}
else {
    Write-Host '  Credentials will be encrypted using YOUR USER key.' -ForegroundColor Yellow
    Write-Host '  Only you, on this machine, can decrypt them.' -ForegroundColor Yellow
    Write-Host '  Scheduled tasks running as SYSTEM will NOT be able to read these.' -ForegroundColor Yellow
}
Write-Host ''

# ============================================================================
# Provider selection
# ============================================================================
$allProviders = @('Azure', 'AWS', 'Proxmox', 'LoadMaster', 'Windows', 'CiscoWLC', 'CUCM')

if (-not $Providers) {
    Write-Host '  Which providers do you want to configure?' -ForegroundColor Cyan
    Write-Host '  Enter numbers separated by commas, or A for all.' -ForegroundColor Gray
    Write-Host ''
    $i = 1
    foreach ($p in $allProviders) {
        Write-Host "    [$i] $p" -ForegroundColor White
        $i++
    }
    Write-Host '    [A] All providers' -ForegroundColor White
    Write-Host ''
    $sel = Read-Host -Prompt '  Selection'
    if ($sel -match '^[aA]$') {
        $Providers = $allProviders
    }
    else {
        $indices = $sel -split '[,\s]+' | ForEach-Object { [int]$_.Trim() - 1 } | Where-Object { $_ -ge 0 -and $_ -lt $allProviders.Count }
        $Providers = $indices | ForEach-Object { $allProviders[$_] }
    }
}

if (-not $Providers -or $Providers.Count -eq 0) {
    Write-Host '  No providers selected. Exiting.' -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host '  Selected providers: ' -NoNewline -ForegroundColor White
Write-Host ($Providers -join ', ') -ForegroundColor Cyan
Write-Host ''

# ============================================================================
# AZURE
# ============================================================================
if ($Providers -contains 'Azure') {
    Write-Banner -Title 'Azure - Service Principal Credentials'
    Write-Host '  Required: App Registration with Reader role on the subscription(s).' -ForegroundColor Gray
    Write-Host '  Find at: Azure Portal > App Registrations > your app > Certificates & Secrets' -ForegroundColor Gray
    Write-Host ''

    $tenantId     = Read-Host -Prompt '    Tenant ID (Directory ID)'
    $clientId     = Read-Host -Prompt '    Client ID (Application ID)'
    $clientSecret = ReadSecure -Prompt 'Client Secret (input hidden)'

    if ([string]::IsNullOrWhiteSpace($tenantId) -or [string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($clientSecret)) {
        Write-Host '  [SKIP] Azure — missing required values.' -ForegroundColor Yellow
    }
    else {
        $vaultName = "Azure.$($tenantId.Trim()).ServicePrincipal"
        $fields = [ordered]@{
            TenantId     = ToSS $tenantId.Trim()
            ClientId     = ToSS $clientId.Trim()
            ClientSecret = ToSS $clientSecret
        }
        Save-DiscoveryCredential -Name $vaultName -Fields $fields `
            -Description "Azure Service Principal for tenant $tenantId" -Force:$Force | Out-Null
        Write-VaultSaved -Name $vaultName -Description "Azure (TenantId=$tenantId, ClientId=$clientId)"
        $script:SavedProviders.Add(@{
            Provider = 'Azure'
            Target   = $tenantId.Trim()
        })
    }
}

# ============================================================================
# AWS
# ============================================================================
if ($Providers -contains 'AWS') {
    Write-Banner -Title 'AWS - IAM Access Key'
    Write-Host '  Required: IAM user with EC2/RDS/ELB read permissions.' -ForegroundColor Gray
    Write-Host '  Find at: AWS Console > IAM > Users > Security credentials' -ForegroundColor Gray
    Write-Host ''

    $awsAccessKey = Read-Host -Prompt '    Access Key ID'
    $awsSecretKey = ReadSecure -Prompt 'Secret Access Key (input hidden)'

    if ([string]::IsNullOrWhiteSpace($awsAccessKey) -or [string]::IsNullOrWhiteSpace($awsSecretKey)) {
        Write-Host '  [SKIP] AWS — missing required values.' -ForegroundColor Yellow
    }
    else {
        $fields = [ordered]@{
            AccessKey = ToSS $awsAccessKey.Trim()
            SecretKey = ToSS $awsSecretKey
        }
        Save-DiscoveryCredential -Name 'AWS.Credential' -Fields $fields `
            -Description "AWS IAM key $awsAccessKey" -Force:$Force | Out-Null
        Write-VaultSaved -Name 'AWS.Credential' -Description "AWS (AccessKey=$awsAccessKey)"

        $awsRegion = Read-Host -Prompt '    AWS Region(s) for scheduling (e.g., us-east-1 or all)'
        if ([string]::IsNullOrWhiteSpace($awsRegion)) { $awsRegion = 'all' }
        $script:SavedProviders.Add(@{
            Provider = 'AWS'
            Target   = $awsRegion.Trim()
        })
    }
}

# ============================================================================
# PROXMOX
# ============================================================================
if ($Providers -contains 'Proxmox') {
    Write-Banner -Title 'Proxmox VE - API Token or Password'
    Write-Host '  Recommended: API Token (Datacenter > Permissions > API Tokens).' -ForegroundColor Gray
    Write-Host '  Token format: user@realm!tokenname=<uuid>' -ForegroundColor Gray
    Write-Host '  Example: root@pam!discovery=6470f043-5899-4542-94da-f016f80bdd4f' -ForegroundColor DarkGray
    Write-Host ''

    $pveHost = Read-Host -Prompt '    Proxmox host (IP or FQDN)'
    if ([string]::IsNullOrWhiteSpace($pveHost)) {
        Write-Host '  [SKIP] Proxmox — host is required.' -ForegroundColor Yellow
    }
    else {
        $pveHost = $pveHost.Trim()
        Write-Host ''
        Write-Host '    [1] API Token (recommended)' -ForegroundColor White
        Write-Host '    [2] Username + Password' -ForegroundColor White
        $pveAuth = Read-Host -Prompt '    Auth method [1]'
        if ([string]::IsNullOrWhiteSpace($pveAuth)) { $pveAuth = '1' }

        if ($pveAuth -eq '1') {
            $pveToken = ReadSecure -Prompt 'API Token (user@realm!name=uuid, input hidden)'
            if ([string]::IsNullOrWhiteSpace($pveToken)) {
                Write-Host '  [SKIP] Proxmox — token is required.' -ForegroundColor Yellow
            }
            else {
                $vaultName = "Proxmox.$pveHost.Token"
                Save-DiscoveryCredential -Name $vaultName -SecureSecret (ToSS $pveToken) `
                    -Description "Proxmox API Token for $pveHost" -Force:$Force | Out-Null
                Write-VaultSaved -Name $vaultName -Description "Proxmox API Token ($pveHost)"
                $script:SavedProviders.Add(@{ Provider = 'Proxmox'; Target = $pveHost; AuthMethod = 'Token' })
            }
        }
        else {
            $pveUser = Read-Host -Prompt '    Username (e.g., root@pam)'
            $pvePass = ReadSecure -Prompt 'Password (input hidden)'
            if ([string]::IsNullOrWhiteSpace($pveUser) -or [string]::IsNullOrWhiteSpace($pvePass)) {
                Write-Host '  [SKIP] Proxmox — username and password required.' -ForegroundColor Yellow
            }
            else {
                $vaultName = "Proxmox.$pveHost.Credential"
                $fields = [ordered]@{
                    Username = ToSS $pveUser.Trim()
                    Password = ToSS $pvePass
                }
                Save-DiscoveryCredential -Name $vaultName -Fields $fields `
                    -Description "Proxmox credentials for $pveHost" -Force:$Force | Out-Null
                Write-VaultSaved -Name $vaultName -Description "Proxmox Password ($pveHost, $pveUser)"
                $script:SavedProviders.Add(@{ Provider = 'Proxmox'; Target = $pveHost; AuthMethod = 'Password' })
            }
        }
    }
}

# ============================================================================
# LOADMASTER
# ============================================================================
if ($Providers -contains 'LoadMaster') {
    Write-Banner -Title 'Kemp LoadMaster - API Key or Password'
    Write-Host '  Recommended: API Key (LoadMaster > System > Certificates & Security > API Security).' -ForegroundColor Gray
    Write-Host ''

    $lmHosts = Read-Host -Prompt '    LoadMaster host(s) - IP or FQDN (comma-separated)'
    if ([string]::IsNullOrWhiteSpace($lmHosts)) {
        Write-Host '  [SKIP] LoadMaster — host is required.' -ForegroundColor Yellow
    }
    else {
        $lmHostArr  = @($lmHosts -split '[,\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $primaryHost = $lmHostArr[0]

        Write-Host ''
        Write-Host '    [1] API Key (recommended)' -ForegroundColor White
        Write-Host '    [2] bal:password' -ForegroundColor White
        $lmAuth = Read-Host -Prompt '    Auth method [1]'
        if ([string]::IsNullOrWhiteSpace($lmAuth)) { $lmAuth = '1' }

        if ($lmAuth -eq '1') {
            $lmKey = ReadSecure -Prompt 'API Key (input hidden)'
            if ([string]::IsNullOrWhiteSpace($lmKey)) {
                Write-Host '  [SKIP] LoadMaster — API key required.' -ForegroundColor Yellow
            }
            else {
                $vaultName = "LoadMaster.$primaryHost.ApiKey"
                Save-DiscoveryCredential -Name $vaultName -SecureSecret (ToSS $lmKey) `
                    -Description "LoadMaster API Key for $primaryHost" -Force:$Force | Out-Null
                Write-VaultSaved -Name $vaultName -Description "LoadMaster API Key ($primaryHost)"
                $script:SavedProviders.Add(@{ Provider = 'LoadMaster'; Target = $lmHostArr -join ','; AuthMethod = 'ApiKey' })
            }
        }
        else {
            $lmUser = Read-Host -Prompt '    Username (usually "bal")'
            $lmPass = ReadSecure -Prompt 'Password (input hidden)'
            $vaultName = "LoadMaster.$primaryHost.Credential"
            $fields = [ordered]@{
                Username = ToSS ($lmUser.Trim())
                Password = ToSS $lmPass
            }
            Save-DiscoveryCredential -Name $vaultName -Fields $fields `
                -Description "LoadMaster credentials for $primaryHost" -Force:$Force | Out-Null
            Write-VaultSaved -Name $vaultName -Description "LoadMaster Password ($primaryHost, $lmUser)"
            $script:SavedProviders.Add(@{ Provider = 'LoadMaster'; Target = $lmHostArr -join ','; AuthMethod = 'Password' })
        }
    }
}

# ============================================================================
# WINDOWS (WMI)
# ============================================================================
if ($Providers -contains 'Windows') {
    Write-Banner -Title 'Windows Attributes / Disk IO - WMI Credentials'
    Write-Host '  Requires local administrator or domain admin on the target hosts.' -ForegroundColor Gray
    Write-Host '  You can enter multiple credentials (tried in order until one works).' -ForegroundColor Gray
    Write-Host ''

    $winHosts = Read-Host -Prompt '    Windows host(s) - IP or FQDN (comma-separated)'
    if ([string]::IsNullOrWhiteSpace($winHosts)) {
        Write-Host '  [SKIP] Windows — host is required.' -ForegroundColor Yellow
    }
    else {
        $winHostArr = @($winHosts -split '[,\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $credIndex  = 1
        $addMore    = $true

        while ($addMore) {
            Write-Host ''
            Write-Host "    Credential #$credIndex" -ForegroundColor Cyan
            $winUser = Read-Host -Prompt "    Username (e.g., DOMAIN\User or .\Administrator)"
            if ([string]::IsNullOrWhiteSpace($winUser)) {
                Write-Host '    Skipping blank credential.' -ForegroundColor DarkGray
                break
            }
            $winPass = ReadSecure -Prompt 'Password (input hidden)'
            $vaultName = "Windows.WMI.Credential.$credIndex"
            $fields = [ordered]@{
                Username = ToSS $winUser.Trim()
                Password = ToSS $winPass
            }
            Save-DiscoveryCredential -Name $vaultName -Fields $fields `
                -Description "Windows WMI credential #$credIndex ($winUser)" -Force:$Force | Out-Null
            Write-VaultSaved -Name $vaultName -Description "WMI Credential #$credIndex ($winUser)"
            $credIndex++

            Write-Host ''
            $moreInput = Read-Host -Prompt '    Add another Windows credential? [y/N]'
            $addMore = ($moreInput -match '^[yY]')
        }

        if ($credIndex -gt 1) {
            $script:SavedProviders.Add(@{ Provider = 'Windows'; Target = $winHostArr -join ',' })
        }
    }
}

# ============================================================================
# CISCO WLC (SNMP)
# ============================================================================
if ($Providers -contains 'CiscoWLC') {
    Write-Banner -Title 'Cisco WLC - SNMP Credentials'
    Write-Host '  SNMP is used to walk the Cisco WLC MIB for wireless device discovery.' -ForegroundColor Gray
    Write-Host ''

    $wlcHosts = Read-Host -Prompt '    WLC host(s) - IP or FQDN (comma-separated)'
    if ([string]::IsNullOrWhiteSpace($wlcHosts)) {
        Write-Host '  [SKIP] CiscoWLC — host is required.' -ForegroundColor Yellow
    }
    else {
        $wlcHostArr = @($wlcHosts -split '[,\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        Write-Host ''
        Write-Host '    [1] SNMPv2c (community string)' -ForegroundColor White
        Write-Host '    [2] SNMPv3  (username + auth + privacy)' -ForegroundColor White
        $wlcSnmpVer = Read-Host -Prompt '    SNMP version [1]'
        $wlcVer = if ($wlcSnmpVer -eq '2') { 3 } else { 2 }   # 1=SNMPv2c, 2=SNMPv3

        $wlcFields = [ordered]@{}

        if ($wlcSnmpVer -eq '2') {
            # SNMPv3
            $wlcVer = 3
            $wlcUser    = Read-Host -Prompt '    Username'
            $wlcCtx     = Read-Host -Prompt '    Context (blank = none)'
            Write-Host '    Auth protocols:    0=None  1=MD5  2=SHA(SHA1)  3=SHA256  4=SHA384  5=SHA512'
            $wlcAuthP   = Read-Host -Prompt '    Auth protocol [2=SHA]'
            if ([string]::IsNullOrWhiteSpace($wlcAuthP)) { $wlcAuthP = '2' }
            $wlcAuthPwd = ReadSecure -Prompt 'Auth password'
            Write-Host '    Privacy protocols: 0=None  1=DES  2=AES128  3=AES192  4=AES256'
            $wlcPrivP   = Read-Host -Prompt '    Privacy protocol [2=AES128]'
            if ([string]::IsNullOrWhiteSpace($wlcPrivP)) { $wlcPrivP = '2' }
            $wlcPrivPwd = ReadSecure -Prompt 'Privacy password'

            $wlcFields['SnmpVersion']    = ToSS '3'
            if (-not [string]::IsNullOrWhiteSpace($wlcUser))    { $wlcFields['Username']        = ToSS $wlcUser }
            if (-not [string]::IsNullOrWhiteSpace($wlcCtx))     { $wlcFields['Context']         = ToSS $wlcCtx }
            # Map numeric input to named protocol string expected by Setup scripts and SNMP module
            $authProtoMap = @{ '0'='None'; '1'='MD5'; '2'='SHA'; '3'='SHA256'; '4'='SHA384'; '5'='SHA512' }
            $privProtoMap = @{ '0'='None'; '1'='DES'; '2'='AES128'; '3'='AES192'; '4'='AES256' }
            $wlcAuthName = if ($authProtoMap.ContainsKey($wlcAuthP)) { $authProtoMap[$wlcAuthP] } else { $wlcAuthP }
            $wlcPrivName = if ($privProtoMap.ContainsKey($wlcPrivP)) { $privProtoMap[$wlcPrivP] } else { $wlcPrivP }
            $wlcFields['AuthProtocol']   = ToSS $wlcAuthName
            $wlcFields['PrivacyProtocol']= ToSS $wlcPrivName
            if (-not [string]::IsNullOrWhiteSpace($wlcAuthPwd)) { $wlcFields['AuthPassword']    = ToSS $wlcAuthPwd }
            if (-not [string]::IsNullOrWhiteSpace($wlcPrivPwd)) { $wlcFields['PrivacyPassword'] = ToSS $wlcPrivPwd }
        }
        else {
            # SNMPv2c
            $wlcVer = 2
            $wlcComm = Read-Host -Prompt '    Community string [public]'
            if ([string]::IsNullOrWhiteSpace($wlcComm)) { $wlcComm = 'public' }
            $wlcFields['SnmpVersion'] = ToSS '2'
            $wlcFields['Community']   = ToSS $wlcComm
        }

        Save-DiscoveryCredential -Name 'CiscoWLC.Snmp' -Fields $wlcFields `
            -Description 'CiscoWLC SNMP settings' -Force:$Force | Out-Null
        Write-VaultSaved -Name 'CiscoWLC.Snmp' -Description "CiscoWLC SNMP v$wlcVer ($($wlcHostArr -join ','))"
        $script:SavedProviders.Add(@{ Provider = 'CiscoWLC'; Target = $wlcHostArr -join ',' })
    }
}

# ============================================================================
# CUCM (SNMP)
# ============================================================================
if ($Providers -contains 'CUCM') {
    Write-Banner -Title 'Cisco CUCM - SNMP Credentials'
    Write-Host '  SNMP is used to walk the ccmPhoneTable MIB on the CUCM publisher.' -ForegroundColor Gray
    Write-Host ''

    $cucmHosts = Read-Host -Prompt '    CUCM host(s) - IP or FQDN (comma-separated)'
    if ([string]::IsNullOrWhiteSpace($cucmHosts)) {
        Write-Host '  [SKIP] CUCM — host is required.' -ForegroundColor Yellow
    }
    else {
        $cucmHostArr = @($cucmHosts -split '[,\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        Write-Host ''
        Write-Host '    [1] SNMPv2c (community string)' -ForegroundColor White
        Write-Host '    [2] SNMPv3  (username + auth + privacy)' -ForegroundColor White
        $cucmSnmpVer = Read-Host -Prompt '    SNMP version [1]'

        $cucmFields = [ordered]@{}

        if ($cucmSnmpVer -eq '2') {
            # SNMPv3
            $cucmUser    = Read-Host -Prompt '    Username'
            $cucmCtx     = Read-Host -Prompt '    Context (blank = none)'
            Write-Host '    Auth protocols:    0=None  1=MD5  2=SHA(SHA1)  3=SHA256  4=SHA384  5=SHA512'
            $cucmAuthP   = Read-Host -Prompt '    Auth protocol [2=SHA]'
            if ([string]::IsNullOrWhiteSpace($cucmAuthP)) { $cucmAuthP = '2' }
            $cucmAuthPwd = ReadSecure -Prompt 'Auth password'
            Write-Host '    Privacy protocols: 0=None  1=DES  2=AES128  3=AES192  4=AES256'
            $cucmPrivP   = Read-Host -Prompt '    Privacy protocol [2=AES128]'
            if ([string]::IsNullOrWhiteSpace($cucmPrivP)) { $cucmPrivP = '2' }
            $cucmPrivPwd = ReadSecure -Prompt 'Privacy password'

            $cucmFields['SnmpVersion']    = ToSS '3'
            if (-not [string]::IsNullOrWhiteSpace($cucmUser))    { $cucmFields['Username']        = ToSS $cucmUser }
            if (-not [string]::IsNullOrWhiteSpace($cucmCtx))     { $cucmFields['Context']         = ToSS $cucmCtx }
            # Map numeric input to named protocol string expected by Setup scripts and SNMP module
            $authProtoMap = @{ '0'='None'; '1'='MD5'; '2'='SHA'; '3'='SHA256'; '4'='SHA384'; '5'='SHA512' }
            $privProtoMap = @{ '0'='None'; '1'='DES'; '2'='AES128'; '3'='AES192'; '4'='AES256' }
            $cucmAuthName = if ($authProtoMap.ContainsKey($cucmAuthP)) { $authProtoMap[$cucmAuthP] } else { $cucmAuthP }
            $cucmPrivName = if ($privProtoMap.ContainsKey($cucmPrivP)) { $privProtoMap[$cucmPrivP] } else { $cucmPrivP }
            $cucmFields['AuthProtocol']   = ToSS $cucmAuthName
            $cucmFields['PrivacyProtocol']= ToSS $cucmPrivName
            if (-not [string]::IsNullOrWhiteSpace($cucmAuthPwd)) { $cucmFields['AuthPassword']    = ToSS $cucmAuthPwd }
            if (-not [string]::IsNullOrWhiteSpace($cucmPrivPwd)) { $cucmFields['PrivacyPassword'] = ToSS $cucmPrivPwd }
        }
        else {
            $cucmComm = Read-Host -Prompt '    Community string [public]'
            if ([string]::IsNullOrWhiteSpace($cucmComm)) { $cucmComm = 'public' }
            $cucmFields['SnmpVersion'] = ToSS '2'
            $cucmFields['Community']   = ToSS $cucmComm
        }

        Save-DiscoveryCredential -Name 'CUCM.Snmp' -Fields $cucmFields `
            -Description 'CUCM SNMP settings' -Force:$Force | Out-Null
        Write-VaultSaved -Name 'CUCM.Snmp' -Description "CUCM SNMP ($($cucmHostArr -join ','))"
        $script:SavedProviders.Add(@{ Provider = 'CUCM'; Target = $cucmHostArr -join ',' })
    }
}

# ============================================================================
# Summary + Scheduling
# ============================================================================
Write-Host ''
Write-Host '  =================================================================' -ForegroundColor DarkCyan
Write-Host '   Vault Setup Complete' -ForegroundColor Green
Write-Host '  =================================================================' -ForegroundColor DarkCyan
Write-Host ''
Write-Host "  Vault scope : $VaultScope" -ForegroundColor White
Write-Host "  Vault path  : $script:DiscoveryVaultPath" -ForegroundColor White
Write-Host "  Providers   : $($script:SavedProviders.Count) configured" -ForegroundColor White
Write-Host ''

if ($script:SavedProviders.Count -eq 0) {
    Write-Host '  No credentials were saved. Nothing to schedule.' -ForegroundColor Yellow
    return
}

# Build list of Register-DiscoveryScheduledTask.ps1 commands
$registerScript = Join-Path $discoveryDir 'Register-DiscoveryScheduledTask.ps1'
$scheduleCommands = [System.Collections.Generic.List[string]]::new()

foreach ($entry in $script:SavedProviders) {
    $p      = $entry.Provider
    $target = $entry.Target

    $providerName = if ($p -eq 'Windows') { 'WindowsAttributes' } else { $p }
    $cmd = ".\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider $providerName"

    switch ($p) {
        'Azure' {
            $cmd += " -Target '$target'"
        }
        'AWS' {
            $cmd += " -Target '$target'"
        }
        'Proxmox' {
            $cmd += " -Target '$target'"
            if ($entry.AuthMethod) { $cmd += " -AuthMethod $($entry.AuthMethod)" }
        }
        'LoadMaster' {
            $targets = $target -split ',' | ForEach-Object { "'$($_.Trim())'" }
            $cmd += " -Target $($targets -join ',')"
            if ($entry.AuthMethod) { $cmd += " -AuthMethod $($entry.AuthMethod)" }
        }
        'Windows' {
            $targets = $target -split ',' | ForEach-Object { "'$($_.Trim())'" }
            $cmd += " -Target $($targets -join ',')"
        }
        'CiscoWLC' {
            $targets = $target -split ',' | ForEach-Object { "'$($_.Trim())'" }
            $cmd += " -Target $($targets -join ',')"
        }
        'CUCM' {
            $targets = $target -split ',' | ForEach-Object { "'$($_.Trim())'" }
            $cmd += " -Target $($targets -join ',')"
        }
    }

    $cmd += " -Action $Action"
    $cmd += " -TriggerType $TriggerType"
    if ($TriggerType -eq 'Daily') {
        $cmd += " -TimeOfDay '$TimeOfDay'"
    }
    else {
        $cmd += " -RepeatIntervalMinutes $RepeatIntervalMinutes"
    }
    $cmd += " -OutputPath '$OutputPath'"
    if ($VaultScope -eq 'LocalMachine') {
        $cmd += ' -UseSystemVault -SkipVaultPopulate'
    }
    if ($RunNow) { $cmd += ' -RunNow' }

    $scheduleCommands.Add($cmd)
}

if ($Schedule) {
    Write-Host '  Registering scheduled tasks...' -ForegroundColor Cyan
    Write-Host ''
    foreach ($cmd in $scheduleCommands) {
        Write-Host "  > $cmd" -ForegroundColor DarkGray
        Write-Host ''
        if ($PSCmdlet.ShouldProcess($cmd, 'Register scheduled task')) {
            try {
                $expression = "& '$registerScript' " + ($cmd -replace '^[^-]+-', '')
                # Run via the script path directly
                $parts = $cmd -replace "^\.\\Register-DiscoveryScheduledTask\.ps1\s*", ''
                & $registerScript ($parts -split '\s+(?=-)' | Where-Object { $_ })
            }
            catch {
                Write-Warning "Failed to register task: $_"
            }
        }
    }
}
else {
    Write-Host '  To schedule each provider, run the following from an ELEVATED PowerShell prompt:' -ForegroundColor Cyan
    Write-Host "  (cd to the discovery folder first: cd '$discoveryDir')" -ForegroundColor DarkGray
    Write-Host ''
    foreach ($cmd in $scheduleCommands) {
        Write-Host "  $cmd" -ForegroundColor Yellow
        Write-Host ''
    }
    Write-Host '  Or run all at once by piping to Invoke-Expression, or re-run this script with -Schedule.' -ForegroundColor Gray
}

Write-Host ''
Write-Host '  Dashboard output directory: ' -ForegroundColor White -NoNewline
Write-Host $OutputPath -ForegroundColor Cyan
Write-Host ''
Write-Host '  Next steps:' -ForegroundColor Cyan
Write-Host '    1. Verify vault contents: Get-DiscoveryCredential -Name <vaultkey> -ShowRedacted' -ForegroundColor White
Write-Host '    2. Test a provider: .\Setup-Azure-Discovery.ps1 -Action Dashboard -NonInteractive' -ForegroundColor White
Write-Host '    3. View scheduled tasks: .\Register-DiscoveryScheduledTask.ps1 -Show' -ForegroundColor White
Write-Host ''

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAZhCFSSxhriaH+
# MS1/5zhYUe6u2IvjmIPry9v/lExaOqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
# jTanyYqJ1pQWMA0GCSqGSIb3DQEBDAUAMHsxCzAJBgNVBAYTAkdCMRswGQYDVQQI
# DBJHcmVhdGVyIE1hbmNoZXN0ZXIxEDAOBgNVBAcMB1NhbGZvcmQxGjAYBgNVBAoM
# EUNvbW9kbyBDQSBMaW1pdGVkMSEwHwYDVQQDDBhBQUEgQ2VydGlmaWNhdGUgU2Vy
# dmljZXMwHhcNMjEwNTI1MDAwMDAwWhcNMjgxMjMxMjM1OTU5WjBWMQswCQYDVQQG
# EwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMS0wKwYDVQQDEyRTZWN0aWdv
# IFB1YmxpYyBDb2RlIFNpZ25pbmcgUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCN55QSIgQkdC7/FiMCkoq2rjaFrEfUI5ErPtx94jGgUW+s
# hJHjUoq14pbe0IdjJImK/+8Skzt9u7aKvb0Ffyeba2XTpQxpsbxJOZrxbW6q5KCD
# J9qaDStQ6Utbs7hkNqR+Sj2pcaths3OzPAsM79szV+W+NDfjlxtd/R8SPYIDdub7
# P2bSlDFp+m2zNKzBenjcklDyZMeqLQSrw2rq4C+np9xu1+j/2iGrQL+57g2extme
# me/G3h+pDHazJyCh1rr9gOcB0u/rgimVcI3/uxXP/tEPNqIuTzKQdEZrRzUTdwUz
# T2MuuC3hv2WnBGsY2HH6zAjybYmZELGt2z4s5KoYsMYHAXVn3m3pY2MeNn9pib6q
# RT5uWl+PoVvLnTCGMOgDs0DGDQ84zWeoU4j6uDBl+m/H5x2xg3RpPqzEaDux5mcz
# mrYI4IAFSEDu9oJkRqj1c7AGlfJsZZ+/VVscnFcax3hGfHCqlBuCF6yH6bbJDoEc
# QNYWFyn8XJwYK+pF9e+91WdPKF4F7pBMeufG9ND8+s0+MkYTIDaKBOq3qgdGnA2T
# OglmmVhcKaO5DKYwODzQRjY1fJy67sPV+Qp2+n4FG0DKkjXp1XrRtX8ArqmQqsV/
# AZwQsRb8zG4Y3G9i/qZQp7h7uJ0VP/4gDHXIIloTlRmQAOka1cKG8eOO7F/05QID
# AQABo4IBEjCCAQ4wHwYDVR0jBBgwFoAUoBEKIz6W8Qfs4q8p74Klf9AwpLQwHQYD
# VR0OBBYEFDLrkpr/NZZILyhAQnAgNpFcF4XmMA4GA1UdDwEB/wQEAwIBhjAPBgNV
# HRMBAf8EBTADAQH/MBMGA1UdJQQMMAoGCCsGAQUFBwMDMBsGA1UdIAQUMBIwBgYE
# VR0gADAIBgZngQwBBAEwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2NybC5jb21v
# ZG9jYS5jb20vQUFBQ2VydGlmaWNhdGVTZXJ2aWNlcy5jcmwwNAYIKwYBBQUHAQEE
# KDAmMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5jb21vZG9jYS5jb20wDQYJKoZI
# hvcNAQEMBQADggEBABK/oe+LdJqYRLhpRrWrJAoMpIpnuDqBv0WKfVIHqI0fTiGF
# OaNrXi0ghr8QuK55O1PNtPvYRL4G2VxjZ9RAFodEhnIq1jIV9RKDwvnhXRFAZ/ZC
# J3LFI+ICOBpMIOLbAffNRk8monxmwFE2tokCVMf8WPtsAO7+mKYulaEMUykfb9gZ
# pk+e96wJ6l2CxouvgKe9gUhShDHaMuwV5KZMPWw5c9QLhTkg4IUaaOGnSDip0TYl
# d8GNGRbFiExmfS9jzpjoad+sPKhdnckcW67Y8y90z7h+9teDnRGWYpquRRPaf9xH
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggWNMIIEdaADAgECAhAOmxiO
# +dAt5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYD
# VQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAi
# BgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAw
# MDBaFw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdp
# Q2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERp
# Z2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsb
# hA3EMB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iT
# cMKyunWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGb
# NOsFxl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclP
# XuU15zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCr
# VYJBMtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFP
# ObURWBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTv
# kpI6nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWM
# cCxBYKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls
# 5Q5SUUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBR
# a2+xq4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6
# MIIBNjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qY
# rhwPTzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8E
# BAMCAYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDig
# NoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9v
# dENBLmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCg
# v0NcVec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQT
# SnovLbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh
# 65ZyoUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSw
# uKFWjuyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAO
# QGPFmCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjD
# TZ9ztwGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0G
# CSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExp
# bWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290
# IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28g
# UHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IB
# jwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEe
# AEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGV
# oYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk
# 8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzh
# P06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41
# aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+
# ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/
# 2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9g
# Rvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhA
# QnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8B
# Af8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcD
# AzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyG
# Omh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5n
# Um9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYu
# cDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG
# 9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW
# 4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIh
# rCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYp
# mlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7Dc
# ML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yE
# Lg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRz
# NyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw
# 4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6
# E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6
# xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZt
# g0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+
# MIIEpqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAw
# WhcNMjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVj
# dGljdXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBB
# bGJlcmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYW
# kI5b5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mw
# zPE3/1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1
# DeO9gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdb
# w+JOxolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1
# Bu10nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1k
# dHYYx6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0J
# BY+J4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0d
# n+IKMEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRs
# CHZIzVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRU
# q6q2u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keE
# LJNy+jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAW
# gBQPKssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8G
# aSIBibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYI
# KwYBBQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcC
# ARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAw
# PqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVT
# aWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0
# cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIz
# Ni5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqG
# SIb3DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3
# wXEK4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9
# vGWJFyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUd
# vaNayomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6
# LwISOX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFO
# WKlS6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7
# nbvfFxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6
# g7tWiEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7
# z+pl6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0G
# CSqGSIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0
# IFRydXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTla
# MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UE
# AxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEy
# NTYgMjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHT
# CphBcr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPh
# of6pvF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mA
# xAHeHYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBv
# MgEdgkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps
# 0wjUjsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF
# 83bRVFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXi
# UOeSLsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOM
# CZIVNSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydP
# pOjL6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrU
# G2ZdSoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+
# sdFUeEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0T
# AQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYD
# VR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMG
# A1UdJQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYY
# aHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2Fj
# ZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNV
# HR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1s
# BwEwDQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WI
# GjB/T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+
# IQhQE7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8M
# yb9rEVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2
# th9y1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjaj
# V/gxdEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2
# Lr3ty9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFze
# GxcytL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG
# 7uEBYTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+N
# Jpud/v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckT
# etiSuEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszW
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCoDvGEuN8QWC0cR2p5V0aDANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI1MDYwNDAwMDAwMFoXDTM2MDkwMzIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjUgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANBGrC0Sxp7Q6q5g
# VrMrV7pvUf+GcAoB38o3zBlCMGMyqJnfFNZx+wvA69HFTBdwbHwBSOeLpvPnZ8ZN
# +vo8dE2/pPvOx/Vj8TchTySA2R4QKpVD7dvNZh6wW2R6kSu9RJt/4QhguSssp3qo
# me7MrxVyfQO9sMx6ZAWjFDYOzDi8SOhPUWlLnh00Cll8pjrUcCV3K3E0zz09ldQ/
# /nBZZREr4h/GI6Dxb2UoyrN0ijtUDVHRXdmncOOMA3CoB/iUSROUINDT98oksouT
# MYFOnHoRh6+86Ltc5zjPKHW5KqCvpSduSwhwUmotuQhcg9tw2YD3w6ySSSu+3qU8
# DD+nigNJFmt6LAHvH3KSuNLoZLc1Hf2JNMVL4Q1OpbybpMe46YceNA0LfNsnqcnp
# JeItK/DhKbPxTTuGoX7wJNdoRORVbPR1VVnDuSeHVZlc4seAO+6d2sC26/PQPdP5
# 1ho1zBp+xUIZkpSFA8vWdoUoHLWnqWU3dCCyFG1roSrgHjSHlq8xymLnjCbSLZ49
# kPmk8iyyizNDIXj//cOgrY7rlRyTlaCCfw7aSUROwnu7zER6EaJ+AliL7ojTdS5P
# WPsWeupWs7NpChUk555K096V1hE0yZIXe+giAwW00aHzrDchIc2bQhpp0IoKRR7Y
# ufAkprxMiXAJQ1XCmnCfgPf8+3mnAgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBTkO/zyMe39/dfzkXFjGVBDz2GM6DAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQBlKq3xHCcEua5gQezRCESeY0ByIfjk9iJP
# 2zWLpQq1b4URGnwWBdEZD9gBq9fNaNmFj6Eh8/YmRDfxT7C0k8FUFqNh+tshgb4O
# 6Lgjg8K8elC4+oWCqnU/ML9lFfim8/9yJmZSe2F8AQ/UdKFOtj7YMTmqPO9mzskg
# iC3QYIUP2S3HQvHG1FDu+WUqW4daIqToXFE/JQ/EABgfZXLWU0ziTN6R3ygQBHMU
# BaB5bdrPbF6MRYs03h4obEMnxYOX8VBRKe1uNnzQVTeLni2nHkX/QqvXnNb+YkDF
# kxUGtMTaiLR9wjxUxu2hECZpqyU1d0IbX6Wq8/gVutDojBIFeRlqAcuEVT0cKsb+
# zJNEsuEB7O7/cuvTQasnM9AWcIQfVjnzrvwiCZ85EE8LUkqRhoS3Y50OHgaY7T/l
# wd6UArb+BOVAkg2oOvol/DJgddJ35XTxfUlQ+8Hggt8l2Yv7roancJIFcbojBcxl
# RcGG0LIhp6GvReQGgMgYxQbV1S3CrWqZzBt1R9xJgKf47CdxVRd/ndUlQ05oxYy2
# zRWVFjF7mcr4C34Mj3ocCVccAvlKV9jEnstrniLvUxxVZE/rptb7IRE2lskKPIJg
# baP5t2nGj/ULLi49xTcBZU8atufk+EMF/cWuiC7POGT75qaL6vdCvHlshtjdNXOC
# IUjsarfNZzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCCeoQvrcEhlbXiPqp7oFKgACsWHf6Fe0YxqBcqrqTQkyjANBgkqhkiG9w0BAQEF
# AASCAgAa3QCgXBgdI85vjGj/yP/YDD6V1nIGMk4xjwonQ1PgdC7iRNpWwxrzLmJG
# Ft0V3wT//YDY5s5IVWutezX4t2wdJPOGYqul02R4qayV8HnZ+Q0Tk71bwTTL32R3
# mOO2kkJDNFRnuKbe/9g/HN3EG1iojUPD1AyDAcWnpp85x5LfZY+j7BJMACGk7r98
# vcxnzKa5CYkuHeSjzHeqpRtjMTDPMx03JEHtgG4UcooISz4zyKaioqZqNOK/xYvD
# 7xut7dvYudenEkS/afZbeEkMkgL6PQvw9iq9hP3eKZFfIpN0hdynViKbxIGCktPs
# tXvWxWb7KfH7nUozhh+Y/ZTgvi9jvM79MYVUAcqVWCM1zlh+++8MYMqBqp0Beufy
# AS+uzIN6jvOf9Q/ILRXBuuIfKdVpsxcvtLB3hgbzF4EWSCAhkCiSKZqYP+qyE7jT
# 3096isTvorkGcIVQnpwRqGLEj7s01y2cnjTkR/laDBi+WhErAXKX3H9n5IOj6cOo
# BLfIywLCvIS+iE5P84cuGlG0FhvWVGjacF537B+Az2XzNDQ4+cfQsiEHHuii6aUu
# llQFN0b3bJUq2ECzMBsaLLIXIZJnvZl+SW4MpW7KCiEoSxcPyBX4gPSdxcVEaWjL
# 4by/Zm6zFu2ZAoHYx6xl0BOBqedCmpRcvDwVw3sYVwy/Ju8FgKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA3MDcxMTQ5MzNaMC8GCSqGSIb3DQEJBDEiBCBD5QKo
# CqxcanK4HHrn+1hdBoHfOVDYI0lDKzjNOfHegDANBgkqhkiG9w0BAQEFAASCAgDP
# C6rsp+kuCfVPyW7F5Hlk/icVp8YiJv3HF8qsVuZC65X/vqsELXsCj8TCOhc4vx/Q
# GBlqgmlmgQSohMi7hyGQUnr49iHvS7mRVWpq60BnOgJY2qNoNhacXN5YOlwM5AfB
# gZJW64tpGXgXjnjYf7/U6hYoR0R6zJ8JKMV4ChDEB3RGQQ9PCJ+VrbbdsmebHUoa
# zFj7sZbenfqQR0VYd4Ckcwc4/TMrb4oreKS4MaVm7R5dgR8dQxXO4n2sVYn4hAZf
# m6wOp5dh663wYZ7yAFt/6EjEJcVxu5SLAjpcA8E2qnBqzoMFxglSPm/UB6mg3+91
# yKFEiDz05jJi8oUqezbpNcmozb7/PVUOEw0qbkefgJwoYPL12i0Jzq0h/MPBeASI
# 34fZfUZ5EAfrpCm3k3UjvtbGFKuGoDw18bhO+Vv59gR5sVqjPNljj8s92ja9QVdD
# 7HTeAlhn2gcePMeuERfEc8UiDYvHVeN3Hs02Ka+24NgRzd7yLRMLqYEBzqSyikrc
# 1D8ALimq+cJjU9BLSf71+9Z6NkrMzYXERapCyEWa/5a0ZNZnTOfdrOBcifhivSg1
# Wc1S90IPVCNP7xOAEThQETz/NH5dZ5ZQKsMMO6yk41T8yQEH63MPPRKhL4003323
# 8nbwHZ0G0KbiLmy7+gkzAOvZO8kpOlt4DToF0VLHXQ==
# SIG # End signature block
