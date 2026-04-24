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
            $combined = $null; $plainSK = $null
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
            $combined = $null; $plainSecret = $null
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
            $token = $null
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
            $combined = $null; $plainPwd = $null
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
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDoOm4JH55st32V
# NFvhfn53A4p+x15uDf6EqJgeeiQ/5qCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCAN1ghPPfUc5tQSghHwwIzbKEl4Dg/u/5Scge7/WKbdeDANBgkqhkiG9w0BAQEF
# AASCAgChfZPSmDCGlRGaYF6W3DyM+twsDaBX8/ttjv4PdwOoYxactEFm6yEn6Hp+
# DujPmhocXuaWADmM1ADlxqI1hQI8VngFUjy4FgBQZJ8Pi5DL5zHdHiJAVzGR0iCm
# k1PvQ1cJIZgds0kOD5cNIRj8Y9Izd7txV2owCEOmALWdw2dKvpZUuMogqxdhGeY7
# gtDh0tUQG2WOfriKz+w8ajyFmh42AIlV/+PVqpgV1n64WFJa3OpS4talFs6TFtGs
# JWpscmLkrqoAr/Rb0PKO2DG0ET6bP/h/z5WecgG1LdhOnHSHMtuHwkOpSQngdMBb
# ICmYHv9Vb4lHVhCQKSKa+MTPoVUMffMROgz7mWmGEQNpRyXRatLFx7E/fmqOcC03
# ZqqzAFUhx/8ckbLWSW1jlNjLEyz6J8OqpHfRXVKgwpkUNiRxHl8Nsalpldp9McQ2
# OprYpdZeRaVOn1duu77sDa2sVM+/v/povjI055JzJBRKd5sOz6bVqid+Fq84ZAfu
# m8vB/ERdsa0NJBPk+LiOlDUbvNT91r1yKvVsPkPexs+8tmPNhsSU59jxL2Uus4n5
# BZqMpVN8m2qIsmAEY73V2eIEN5C7I2WGdbj3PrtildJcuRxk7uPIcCxSd+tWrRlU
# EGx+sm5Di7cwFKFvxyP9F+LZWCIeXaA2Xk4YVm+jJPQSrMChjKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjAwMDAwMzlaMC8GCSqGSIb3DQEJBDEiBCC9ZDGg
# KaH8oV597uTxrHzn9fQbNQ5c5H5yrrELyR/F+DANBgkqhkiG9w0BAQEFAASCAgAy
# 9kfsUXXQehUH57v6GRFDTDkkPlYvoANLUDUQ53/fyHAslRgZmAZNN0xUZBUxjuTT
# GfjzhTOAg2WoYgkp69q7h4xti6bpVzqx5w18gDyzs9NTEW0nQOD+rXC94TkcMXk/
# NLz9T4WYMZnD/3pUngSb7pwTBHb+k5qvU6duqY6zBrZ+t8P+S+mR5GJAOPLrK8Em
# 6jx7/0Fg/iuwX2iFBCxgCUkALCw+2VU1t3LOIS+w6JV+3zzYmkpBn3/GQtJVvSlY
# A0ekANebcssGKL+KKWC3KEs04wkK+CcNzPKbzet5sMFRicttOs4FRxNrTH+7sb2O
# 7CdtYKTxxYjy127tJa8tXId/w5fPsJOJrm05jrH0b70ouu6qNnA51xZoLUmetU8l
# KN68z8CZcGLNchT7NCaXY9P+xZykEz6rZNIO9DSTON0wSxe8fcbIyTNNTo+W/eP6
# LJApA0SygfAAjFOA+SrYJtKkagVfMQfll7ca4XMH2MeooZOkOkw0SHUrznfcMqo1
# rwC7fzwJkEN4848g39p6/V8RoTp0pF3Hdq2sZvMtRilHlckiuPZV29ervm/UJJuD
# JardgtXaGCH7n6z03+mc2vGMRqODPyAri3kq4WEZ/UTIMerk8p6Xd6fiwiPZ8jX3
# cjRiDa89KjE3XMEM0wJk26W94kfS2g25Y7ZLG1KLjg==
# SIG # End signature block
