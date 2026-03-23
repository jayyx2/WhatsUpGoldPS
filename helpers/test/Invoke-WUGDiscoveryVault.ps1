<#
.SYNOPSIS
    Interactive DPAPI vault manager — view, add, update, or remove
    discovery credentials from the encrypted vault.

.DESCRIPTION
    Provides a menu-driven interface to manage the DiscoveryHelpers
    DPAPI vault. All credentials are encrypted with DPAPI (current user
    + machine) and optionally AES-256 if a vault password is set.

    Actions:
      [L] List   — Show all stored credentials (name, type, expiry, age)
      [V] View   — Peek at a specific credential (shows safe preview, not the secret)
      [A] Add    — Store a new credential (guided prompts per type)
      [U] Update — Replace an existing credential with a new value
      [D] Delete — Remove a credential from the vault
      [Q] Quit   — Exit the manager

    Credential types supported:
      AWSKeys      — Access Key ID + Secret Access Key
      AzureSP      — Tenant ID + Application ID + Client Secret
      BearerToken  — Single API token (Proxmox, Fortinet, etc.)
      PSCredential — Username + Password (F5, HyperV, VMware, etc.)

.PARAMETER Action
    Run a single action without the interactive menu.
    Valid values: List, View, Add, Update, Delete
.PARAMETER Name
    Credential name for non-interactive use with -Action.
.PARAMETER CredType
    Credential type for -Action Add. Prompted if omitted.

.EXAMPLE
    .\Invoke-WUGDiscoveryVault.ps1
    # Opens the interactive menu.

.EXAMPLE
    .\Invoke-WUGDiscoveryVault.ps1 -Action List
    # Lists all vault entries and exits.

.EXAMPLE
    .\Invoke-WUGDiscoveryVault.ps1 -Action Add -Name 'AWS.Credential' -CredType AWSKeys
    # Adds an AWS credential directly (prompts for key values).

.NOTES
    Author  : jason@wug.ninja
    Created : 2026-03-21
    Requires: PowerShell 5.1+, DiscoveryHelpers.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('List','View','Add','Update','Delete')]
    [string]$Action,
    [string]$Name,
    [ValidateSet('AWSKeys','AzureSP','BearerToken','PSCredential')]
    [string]$CredType
)

# ============================================================================
# region  Load Helpers
# ============================================================================
$scriptDir    = Split-Path $MyInvocation.MyCommand.Path -Parent
$discoveryDir = Join-Path (Split-Path $scriptDir -Parent) 'discovery'
. (Join-Path $discoveryDir 'DiscoveryHelpers.ps1')
Initialize-DiscoveryVault
# endregion

# ============================================================================
# region  Helpers
# ============================================================================
function Show-VaultBanner {
    $vaultPath = $script:DiscoveryVaultPath
    $credFiles = @(Get-ChildItem -Path $vaultPath -Filter '*.cred' -File -ErrorAction SilentlyContinue)
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host '   WhatsUpGoldPS Discovery Vault Manager' -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host "   Vault : $vaultPath" -ForegroundColor White
    Write-Host "   Creds : $($credFiles.Count)" -ForegroundColor White
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

function Show-VaultList {
    $items = @(Get-DiscoveryCredential)
    if ($items.Count -eq 0) {
        Write-Host '  (vault is empty)' -ForegroundColor DarkGray
        return
    }
    $rows = foreach ($item in $items) {
        $age = if ($item.CreatedUtc) {
            $days = ((Get-Date).ToUniversalTime() - [DateTime]::Parse($item.CreatedUtc)).Days
            "${days}d ago"
        } else { '?' }

        $expiry = if ($item.ExpiresIn) { $item.ExpiresIn } else { 'never' }

        [PSCustomObject]@{
            '#'          = [array]::IndexOf($items, $item) + 1
            Name         = $item.Name
            Type         = $item.Type
            Description  = if ($item.Description) { $item.Description } else { '' }
            Age          = $age
            Expires      = $expiry
        }
    }
    $rows | Format-Table -AutoSize
}

function Get-SafePreview {
    param([string]$CredName)
    $stored = Get-DiscoveryCredential -Name $CredName -ErrorAction SilentlyContinue
    if (-not $stored) { return '(could not decrypt)' }

    if ($stored -is [PSCredential]) {
        return "User=$($stored.UserName)"
    }
    if ($stored -is [hashtable]) {
        $keys = @($stored.Keys)
        $previews = foreach ($k in $keys) {
            $v = "$($stored[$k])"
            if ($v.Length -gt 12) { "${k}=$($v.Substring(0,4))...$($v.Substring($v.Length - 4))" }
            elseif ($v.Length -gt 0) { "${k}=****" }
            else { "${k}=(empty)" }
        }
        return $previews -join ', '
    }
    if ($stored -is [string]) {
        if ($stored -match '\|') {
            # Could be AccessKey|Secret or User|Pass
            $parts = $stored -split '\|', 2
            return "Key=$($parts[0]), Secret=****"
        }
        if ($stored.Length -gt 12) {
            return "Token=$($stored.Substring(0,4))...$($stored.Substring($stored.Length - 4))"
        }
        if ($stored.Length -gt 0) { return 'Token=****' }
    }
    return '(stored)'
}

function Prompt-CredentialType {
    Write-Host ''
    Write-Host '  Credential types:' -ForegroundColor Cyan
    Write-Host '    [1] AWSKeys      — AWS Access Key ID + Secret Access Key'
    Write-Host '    [2] AzureSP      — Azure Service Principal (Tenant + App + Secret)'
    Write-Host '    [3] BearerToken  — Single API token (Proxmox, Fortinet, etc.)'
    Write-Host '    [4] PSCredential — Username + Password (F5, HyperV, VMware, etc.)'
    Write-Host ''
    $choice = Read-Host -Prompt '  Type [1-4]'
    switch ($choice) {
        '1' { return 'AWSKeys' }
        '2' { return 'AzureSP' }
        '3' { return 'BearerToken' }
        '4' { return 'PSCredential' }
        default {
            Write-Host '  Invalid choice.' -ForegroundColor Red
            return $null
        }
    }
}

function Save-TypedCredential {
    param(
        [string]$CredName,
        [string]$Type,
        [switch]$IsUpdate
    )

    $forceFlag = if ($IsUpdate) { $true } else { $false }
    $desc = ''

    switch ($Type) {
        'AWSKeys' {
            Write-Host ''
            Write-Host "  Enter AWS IAM credentials:" -ForegroundColor Yellow
            $akInput = Read-Host -Prompt "    Access Key ID"
            if ([string]::IsNullOrWhiteSpace($akInput)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $false
            }
            $AccessKey = $akInput.Trim()

            $skSS = Read-Host -AsSecureString -Prompt "    Secret Access Key"
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($skSS)
            try { $plainSK = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            if ([string]::IsNullOrWhiteSpace($plainSK)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $false
            }

            $combined = "$AccessKey|$plainSK"
            $ss = ConvertTo-SecureString $combined -AsPlainText -Force
            $desc = "AWS IAM ($AccessKey)"
            Save-DiscoveryCredential -Name $CredName -SecureSecret $ss `
                -Description $desc -Force:$forceFlag | Out-Null
        }
        'AzureSP' {
            Write-Host ''
            Write-Host "  Enter Azure Service Principal details:" -ForegroundColor Yellow
            $tenantId = Read-Host -Prompt "    Tenant ID"
            $appId    = Read-Host -Prompt "    Application (Client) ID"
            $secretSS = Read-Host -AsSecureString -Prompt "    Client Secret"
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretSS)
            try { $plainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            if ([string]::IsNullOrWhiteSpace($tenantId) -or [string]::IsNullOrWhiteSpace($appId) -or [string]::IsNullOrWhiteSpace($plainSecret)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $false
            }

            $combined = "$tenantId|$appId|$plainSecret"
            $ss = ConvertTo-SecureString $combined -AsPlainText -Force
            $desc = "Azure SP (Tenant=$tenantId, App=$appId)"
            Save-DiscoveryCredential -Name $CredName -SecureSecret $ss `
                -Description $desc -Force:$forceFlag | Out-Null
        }
        'BearerToken' {
            Write-Host ''
            $provHint = ''
            if ($CredName -match 'Proxmox')  { $provHint = ' (format: user@realm!tokenid=secret-uuid)' }
            if ($CredName -match 'Forti')    { $provHint = ' (FortiGate REST API admin token)' }
            $ss = Read-Host -AsSecureString -Prompt "    API token${provHint}"
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
            try { $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            if ([string]::IsNullOrWhiteSpace($token)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $false
            }

            $desc = 'API token'
            Save-DiscoveryCredential -Name $CredName -SecureSecret $ss `
                -Description $desc -Force:$forceFlag | Out-Null
        }
        'PSCredential' {
            Write-Host ''
            $cred = Get-Credential -Message "Credentials for '$CredName' (stored in DPAPI vault)"
            if (-not $cred) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $false
            }
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
            try { $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

            $combined = "$($cred.UserName)|$plainPwd"
            $ss = ConvertTo-SecureString $combined -AsPlainText -Force
            $desc = "Credential ($($cred.UserName))"
            Save-DiscoveryCredential -Name $CredName -SecureSecret $ss `
                -Description $desc -Force:$forceFlag | Out-Null
        }
        default {
            Write-Host "  Unknown type: $Type" -ForegroundColor Red
            return $false
        }
    }

    Write-Host "  Saved '$CredName' to vault." -ForegroundColor Green
    return $true
}

function Invoke-VaultAction-List {
    Write-Host '  --- Vault Contents ---' -ForegroundColor Cyan
    Show-VaultList
}

function Invoke-VaultAction-View {
    param([string]$TargetName)

    if (-not $TargetName) {
        Show-VaultList
        $TargetName = Read-Host -Prompt '  Credential name to view'
        if ([string]::IsNullOrWhiteSpace($TargetName)) { return }
    }

    $all = @(Get-DiscoveryCredential)
    $meta = $all | Where-Object { $_.Name -eq $TargetName }
    if (-not $meta) {
        Write-Host "  Credential '$TargetName' not found." -ForegroundColor Red
        return
    }

    Write-Host ''
    Write-Host "  Name        : $($meta.Name)" -ForegroundColor White
    Write-Host "  Type        : $($meta.Type)" -ForegroundColor White
    Write-Host "  Description : $($meta.Description)" -ForegroundColor White
    Write-Host "  Created     : $($meta.CreatedUtc)" -ForegroundColor White
    Write-Host "  Expires     : $(if ($meta.ExpiresIn) { $meta.ExpiresIn } else { 'never' })" -ForegroundColor White
    Write-Host "  Machine     : $($meta.Machine)" -ForegroundColor White
    Write-Host "  User        : $($meta.User)" -ForegroundColor White

    $preview = Get-SafePreview -CredName $TargetName
    Write-Host "  Preview     : $preview" -ForegroundColor Green
    Write-Host ''
}

function Invoke-VaultAction-Add {
    param([string]$TargetName, [string]$TargetType)

    if (-not $TargetName) {
        Write-Host ''
        Write-Host '  Common vault names:' -ForegroundColor DarkGray
        Write-Host '    AWS.Credential                         (AWSKeys)' -ForegroundColor DarkGray
        Write-Host '    Azure.<TenantId>.ServicePrincipal      (AzureSP)' -ForegroundColor DarkGray
        Write-Host '    Proxmox.<host>.Token                   (BearerToken)' -ForegroundColor DarkGray
        Write-Host '    FortiGate-<name>                       (BearerToken)' -ForegroundColor DarkGray
        Write-Host '    HyperV.<host>.Credential               (PSCredential)' -ForegroundColor DarkGray
        Write-Host '    F5.<host>.Credential                   (PSCredential)' -ForegroundColor DarkGray
        Write-Host '    VMware.<host>.Credential               (PSCredential)' -ForegroundColor DarkGray
        Write-Host ''
        $TargetName = Read-Host -Prompt '  Credential name'
        if ([string]::IsNullOrWhiteSpace($TargetName)) { return }
    }

    # Check if it already exists
    $existing = @(Get-DiscoveryCredential) | Where-Object { $_.Name -eq $TargetName }
    if ($existing) {
        Write-Host "  '$TargetName' already exists. Use [U]pdate to replace it." -ForegroundColor Yellow
        return
    }

    if (-not $TargetType) {
        # Try to guess from the name
        if ($TargetName -match '^AWS\.') { $TargetType = 'AWSKeys' }
        elseif ($TargetName -match '^Azure\..*\.ServicePrincipal$') { $TargetType = 'AzureSP' }
        elseif ($TargetName -match '\.Token$|^FortiGate') { $TargetType = 'BearerToken' }
        elseif ($TargetName -match '\.Credential$') { $TargetType = 'PSCredential' }
        else {
            $TargetType = Prompt-CredentialType
            if (-not $TargetType) { return }
        }
        Write-Host "  Type: $TargetType" -ForegroundColor DarkGray
    }

    Save-TypedCredential -CredName $TargetName -Type $TargetType
}

function Invoke-VaultAction-Update {
    param([string]$TargetName)

    if (-not $TargetName) {
        Show-VaultList
        $TargetName = Read-Host -Prompt '  Credential name to update'
        if ([string]::IsNullOrWhiteSpace($TargetName)) { return }
    }

    $all = @(Get-DiscoveryCredential)
    $meta = $all | Where-Object { $_.Name -eq $TargetName }
    if (-not $meta) {
        Write-Host "  Credential '$TargetName' not found." -ForegroundColor Red
        return
    }

    $preview = Get-SafePreview -CredName $TargetName
    Write-Host "  Current: $preview" -ForegroundColor Green

    # Determine type from existing metadata or name pattern
    $guessedType = $null
    if ($TargetName -match '^AWS\.') { $guessedType = 'AWSKeys' }
    elseif ($TargetName -match '^Azure\..*\.ServicePrincipal$') { $guessedType = 'AzureSP' }
    elseif ($TargetName -match '\.Token$|^FortiGate') { $guessedType = 'BearerToken' }
    elseif ($TargetName -match '\.Credential$') { $guessedType = 'PSCredential' }

    if (-not $guessedType) {
        $guessedType = Prompt-CredentialType
        if (-not $guessedType) { return }
    }
    else {
        Write-Host "  Type: $guessedType" -ForegroundColor DarkGray
        $changeType = Read-Host -Prompt "  Change type? [N]o / or enter new type (AWSKeys/AzureSP/BearerToken/PSCredential)"
        if ($changeType -and $changeType -notmatch '^[Nn]') {
            if ($changeType -in @('AWSKeys','AzureSP','BearerToken','PSCredential')) {
                $guessedType = $changeType
            }
        }
    }

    Write-Host "  Enter new values (replaces existing):" -ForegroundColor Yellow
    Save-TypedCredential -CredName $TargetName -Type $guessedType -IsUpdate
}

function Invoke-VaultAction-Delete {
    param([string]$TargetName)

    $all = @(Get-DiscoveryCredential)
    if ($all.Count -eq 0) {
        Write-Host '  Vault is empty — nothing to delete.' -ForegroundColor DarkGray
        return
    }

    if (-not $TargetName) {
        Show-VaultList
        Write-Host '  Enter a credential name, or * to delete ALL.' -ForegroundColor DarkGray
        $TargetName = Read-Host -Prompt '  Credential name (or *)'
        if ([string]::IsNullOrWhiteSpace($TargetName)) { return }
    }

    # Wildcard / select-all
    if ($TargetName -eq '*') {
        Write-Host ''
        Write-Host "  This will DELETE all $($all.Count) credential(s) from the vault:" -ForegroundColor Red
        foreach ($item in $all) {
            Write-Host "    - $($item.Name)" -ForegroundColor Yellow
        }
        Write-Host ''
        $confirm = Read-Host -Prompt "  Type YES to confirm deleting all $($all.Count) credentials"
        if ($confirm -ceq 'YES') {
            foreach ($item in $all) {
                Remove-DiscoveryCredential -Name $item.Name -Confirm:$false
                Write-Host "  Deleted '$($item.Name)'." -ForegroundColor Green
            }
            Write-Host "  Vault cleared ($($all.Count) credentials removed)." -ForegroundColor Green
        }
        else {
            Write-Host '  Cancelled.' -ForegroundColor DarkGray
        }
        return
    }

    # Wildcard pattern match (e.g. "AWS.*", "HyperV*")
    $matches = @($all | Where-Object { $_.Name -like $TargetName })
    if ($matches.Count -eq 0) {
        Write-Host "  No credentials matching '$TargetName'." -ForegroundColor Red
        return
    }

    if ($matches.Count -gt 1) {
        Write-Host ''
        Write-Host "  Matched $($matches.Count) credentials:" -ForegroundColor Yellow
        foreach ($m in $matches) {
            $preview = Get-SafePreview -CredName $m.Name
            Write-Host "    - $($m.Name)  ($preview)" -ForegroundColor Yellow
        }
        Write-Host ''
        $confirm = Read-Host -Prompt "  Delete all $($matches.Count) matches? [y/N]"
        if ($confirm -match '^[Yy]') {
            foreach ($m in $matches) {
                Remove-DiscoveryCredential -Name $m.Name -Confirm:$false
                Write-Host "  Deleted '$($m.Name)'." -ForegroundColor Green
            }
        }
        else {
            Write-Host '  Cancelled.' -ForegroundColor DarkGray
        }
        return
    }

    # Single match
    $meta = $matches[0]
    $preview = Get-SafePreview -CredName $meta.Name
    Write-Host "  Will delete: $($meta.Name) ($preview)" -ForegroundColor Yellow
    $confirm = Read-Host -Prompt '  Are you sure? [y/N]'
    if ($confirm -match '^[Yy]') {
        Remove-DiscoveryCredential -Name $meta.Name -Confirm:$false
        Write-Host "  Deleted '$($meta.Name)'." -ForegroundColor Green
    }
    else {
        Write-Host '  Cancelled.' -ForegroundColor DarkGray
    }
}
# endregion

# ============================================================================
# region  Main
# ============================================================================

# Non-interactive: single action mode
if ($Action) {
    switch ($Action) {
        'List'   { Invoke-VaultAction-List }
        'View'   { Invoke-VaultAction-View -TargetName $Name }
        'Add'    { Invoke-VaultAction-Add -TargetName $Name -TargetType $CredType }
        'Update' { Invoke-VaultAction-Update -TargetName $Name }
        'Delete' { Invoke-VaultAction-Delete -TargetName $Name }
    }
    return
}

# Interactive menu loop
Show-VaultBanner
Show-VaultList

while ($true) {
    Write-Host '  [L]ist  [V]iew  [A]dd  [U]pdate  [D]elete  [Q]uit' -ForegroundColor Cyan
    $menuChoice = Read-Host -Prompt '  Action'

    switch -Regex ($menuChoice) {
        '^[Ll]' { Invoke-VaultAction-List }
        '^[Vv]' { Invoke-VaultAction-View }
        '^[Aa]' { Invoke-VaultAction-Add }
        '^[Uu]' { Invoke-VaultAction-Update }
        '^[Dd]' { Invoke-VaultAction-Delete }
        '^[Qq]' {
            Write-Host '  Bye!' -ForegroundColor DarkGray
            return
        }
        default {
            Write-Host '  Invalid choice.' -ForegroundColor DarkGray
        }
    }
    Write-Host ''
}
# endregion

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAVbZlc5yEir6xa
# fj6Dgv4tLeedJ98p+RHjfVgQwybcuqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggYaMIIEAqADAgECAhBiHW0M
# UgGeO5B5FSCJIRwKMA0GCSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENv
# ZGUgU2lnbmluZyBSb290IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5
# NTlaMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzAp
# BgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0G
# CSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjI
# ztNsfvxYB5UXeWUzCxEeAEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NV
# DgFigOMYzB2OKhdqfWGVoYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/3
# 6F09fy1tsB8je/RV0mIk8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05Zw
# mRmTnAO5/arnY83jeNzhP06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm
# +qxp4VqpB3MV/h53yl41aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUe
# dyz8rNyfQJy/aOs5b4s+ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz4
# 4MPZ1f9+YEQIQty/NQd/2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBM
# dlyh2n5HirY4jKnFH/9gRvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQY
# MBaAFDLrkpr/NZZILyhAQnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritU
# pimqF6TNDDAOBgNVHQ8BAf8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNV
# HSUEDDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsG
# A1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1
# YmxpY0NvZGVTaWduaW5nUm9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsG
# AQUFBzAChjpodHRwOi8vY3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2Rl
# U2lnbmluZ1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0
# aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURh
# w1aVcdGRP4Wh60BAscjW4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0Zd
# OaWTsyNyBBsMLHqafvIhrCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajj
# cw5+w/KeFvPYfLF/ldYpmlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNc
# WbWDRF/3sBp6fWXhz7DcML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalO
# hOfCipnx8CaLZeVme5yELg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJs
# zkyeiaerlphwoKx1uHRzNyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z7
# 6mKnzAfZxCl/3dq3dUNw4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5J
# KdGvspbOrTfOXyXvmPL6E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHH
# j95Ejza63zdrEcxWLDX6xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2
# Bev6SivBBOHY+uqiirZtg0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/
# L9Uo2bC5a4CH2RwwggY+MIIEpqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqG
# SIb3DQEBDAUAMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYw
# HhcNMjYwMjA5MDAwMDAwWhcNMjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEU
# MBIGA1UECAwLQ29ubmVjdGljdXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcw
# FQYDVQQDDA5KYXNvbiBBbGJlcmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAPN6aN4B1yYWkI5b5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyE
# tRYPxEmNJL3A38Bkg7mwzPE3/1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d6
# 7MlJLUAEufl18tOr3ST1DeO9gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2
# h4KdtRAnCqwM+/V7iBdbw+JOxolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAAD
# LdjZr5ip8vIWbf857Yw1Bu10nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZ
# BBL56l4YAlIVRsrOiE1kdHYYx6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDe
# yIq+Oztz1LvEdy8Rcd0JBY+J4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN
# 79CJ90UTZb2+I+tamj0dn+IKMEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+Phha
# mOxF2px9LObhBLLEMyRsCHZIzVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi
# 2ttn6lLOPThXMiQaooRUq6q2u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSM
# jDSRFDfHRCdGbZsL/keELJNy+jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJ
# MIIBhTAfBgNVHSMEGDAWgBQPKssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU
# 6YF0o0D5AVhKHbVocr8GaSIBibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQC
# MAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIB
# AwIwJTAjBggrBgEFBQcCARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EM
# AQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2Vj
# dGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBE
# BggrBgEFBQcwAoY4aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGlj
# Q29kZVNpZ25pbmdDQVIzNi5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNl
# Y3RpZ28uY29tMA0GCSqGSIb3DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvC
# wOA/RYQnFJD7R/bSQRu3wXEK4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03
# J5PrDTp1WPCWbXKX8Oz9vGWJFyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9
# URrpiLPJ9rQjfHMb1BUdvaNayomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6s
# X93wphwJNBJAstH9Ozs6LwISOX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+z
# zieGEI50fKnN77FfNKFOWKlS6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcj
# GSHw4lTg1Wx+WMAMdl/7nbvfFxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjs
# Nrsk9ZlalBi5SHkIu+F6g7tWiEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1
# nSX8OM++AXoyVGO+iTj7z+pl6XE9Gw/Td6WKKKsxggMaMIIDFgIBATBoMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYCEAec4OTRFH+FzTlzz3Yt
# N+swDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZ
# BgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYB
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgzd0xWarxS15kfWxU/lhcquyOF5hK4c9u
# /di3qYPAyZIwDQYJKoZIhvcNAQEBBQAEggIAJeG3purw86V7oe4raYJbI5lPQXQI
# 4LbYmHSP/uJL7AnfR47yifRj7WtKfEaNGOal+NF0K1w9XLHWBX8W4NcaaluN+ngT
# fEcgqCa8w2dhBMieyuq4qsdNeNCbMF0hLOkZVtTns8ZtWX1Ti7vPaQTpDg/JPFvG
# VkSkcMIygoZ6c1lkkoDGq6wIYeCgG1IlFUnFYXJc85973Nyl+8cdPq3/yQ8xk6ca
# RT/nUcaz9J2kwJw+myG8AzcK2zi2tXzFmnGDMumHYDThHzL2eKiHr1Pt0rxTWIZO
# ow87vjQgquErznH7VvT6HyVRTUErWNZDk6rtMX2W/KdA35kJpC4HT/lL5bTJXZkJ
# g/qRvVlNLICl40pgxVAyDRaenoU5jwwuTRQtPWOvszy70ahZ3PFlBiTSCDzAwFIJ
# 8zou8LqVNdOou76GQdjT2cZtVaJCAKXbVDwA39n/Z6rIrPB16i1BdEJ8fx9PkR/q
# hivux8ZJ29wpMxKp56VUAzEUgaoI3e9sZFg/nvrtpY+eTgdlPu33zbyJPFisJ2bv
# qeVsGdZbTBYSuHWJzuAXCROGqm90Dz/VbOPJNWRmTzNqEDuxud/YqGm62/mliYnS
# bpHTPzB7exvQLo9MBaG1o9wMVg+L0rTKB9xJVza4RCojc4zLMTOhn2dge1aXisX7
# s50feLbC1aMssBg=
# SIG # End signature block
