<#
.SYNOPSIS
    CUCM phone inventory discovery, dashboard generation, and optional WUG monitor sync.

.DESCRIPTION
    Uses the WhatsUp Gold SNMP COM API to walk Cisco's ccmPhoneTable on one or
    more CUCM servers. The script keeps two outputs separate:

      - inventory rows for dashboards, exports, and console review
      - a framework-aligned WUG monitor plan for shared SNMPTable phone status
        monitoring plus aggregate CUCM count attributes on the device

    Actions:
      PushToWUG       Create or reuse WUG devices and SNMP credentials, then sync monitors.
      ExportJSON      Export phone inventory plus monitor-plan metadata to JSON.
      ExportCSV       Export phone inventory rows to CSV.
      ShowTable       Show a concise phone table in the console.
      Dashboard       Generate one HTML report per CUCM target.
      DashboardAndPush Generate dashboards, then push the monitor plan to WUG.
      None            Discover only.

.PARAMETER Target
    One or more CUCM IP addresses or hostnames.

.PARAMETER Action
    What to do after discovery.

.PARAMETER SnmpVersion
    SNMP version to use with Initialize4. Valid values: 1, 2, 3.

.PARAMETER Community
    Read community for SNMP v1/v2.

.PARAMETER SnmpUsername
    SNMP v3 username.

.PARAMETER SnmpContext
    SNMP v3 context.

.PARAMETER SnmpAuthProtocol
    SNMP v3 auth protocol. Valid values: 'None', 'MD5', 'SHA', 'SHA1', 'SHA256', 'SHA384', 'SHA512'.

.PARAMETER SnmpAuthPassword
    SNMP v3 auth password.

.PARAMETER SnmpPrivacyProtocol
    SNMP v3 privacy protocol. Valid values: 'None', 'DES', '3DES', 'TripleDES', 'AES', 'AES128', 'AES192', 'AES256'.

.PARAMETER SnmpPrivacyPassword
    SNMP v3 privacy password.

.PARAMETER SnmpPort
    SNMP port. Default: 161.

.PARAMETER TimeoutMs
    SNMP timeout in milliseconds. Default: 5000.

.PARAMETER Retries
    SNMP retry count. Default: 1.

.PARAMETER VaultName
    Optional DPAPI vault bundle name for SNMP settings. Default: CUCM.Snmp.

.PARAMETER WUGServer
    Optional WhatsUp Gold server address for PushToWUG actions.

.PARAMETER WUGCredential
    Optional WhatsUp Gold credential for PushToWUG actions.

.PARAMETER DeviceGroupId
    Optional WUG device group for newly created devices. Default: 0.

.PARAMETER PollingIntervalSeconds
    Polling interval for WUG active monitors. Default: 300.

.PARAMETER OutputPath
    Output directory for exports and dashboards.

.PARAMETER NonInteractive
    Suppress prompts. Requires direct SNMP parameters or a saved vault bundle.

.EXAMPLE
    .\Setup-CUCM-Discovery.ps1 -Target 192.168.75.33,192.168.75.34 -Action Dashboard

.EXAMPLE
    .\Setup-CUCM-Discovery.ps1 -Target 192.168.75.33 -SnmpVersion 2 -Community public -Action PushToWUG -NonInteractive

.NOTES
    Requires: PowerShell 5.1+, WhatsUpGoldPS.Snmp module (SharpSnmpLib).
    Encoding: UTF-8 with BOM
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Target,

    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'ShowTable', 'Dashboard', 'DashboardAndPush', 'None')]
    [string]$Action,

    [ValidateSet(1, 2, 3)]
    [int]$SnmpVersion = 2,

    [string]$Community,

    [string]$SnmpUsername,

    [string]$SnmpContext,

    [ValidateSet('None', 'MD5', 'SHA', 'SHA1', 'SHA256', 'SHA384', 'SHA512')]
    [string]$SnmpAuthProtocol = 'SHA256',

    [string]$SnmpAuthPassword,

    [ValidateSet('None', 'DES', '3DES', 'TripleDES', 'AES', 'AES128', 'AES192', 'AES256')]
    [string]$SnmpPrivacyProtocol = 'AES256',

    [string]$SnmpPrivacyPassword,

    [int]$SnmpPort = 161,

    [int]$TimeoutMs = 5000,

    [int]$Retries = 1,

    [string]$VaultName = 'CUCM.Snmp',

    [string]$WUGServer,

    [PSCredential]$WUGCredential,

    [int]$DeviceGroupId = 0,

    [ValidateRange(60, 86400)]
    [int]$PollingIntervalSeconds = 300,

    [string]$OutputPath,

    [switch]$NonInteractive
)

$script:InputSnmpVersionSpecified = $PSBoundParameters.ContainsKey('SnmpVersion')
$script:InputSnmpAuthProtocolSpecified = $PSBoundParameters.ContainsKey('SnmpAuthProtocol')
$script:InputSnmpPrivacyProtocolSpecified = $PSBoundParameters.ContainsKey('SnmpPrivacyProtocol')

function ConvertTo-CUCMPlainText {
    [CmdletBinding()]
    param(
        [Parameter()]
        $Value
    )

    if ($null -eq $Value) { return '' }

    # Handle both SecureString and plain string inputs
    if ($Value -is [System.Security.SecureString]) {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        try {
            return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
    else {
        return [string]$Value
    }
}

function ConvertTo-CUCMSecureString {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Value
    )

    if ([string]::IsNullOrEmpty($Value)) {
        $empty = New-Object System.Security.SecureString
        $empty.MakeReadOnly()
        return $empty
    }

    return (ConvertTo-SecureString -String $Value -AsPlainText -Force)
}

function ConvertTo-WUGAuthProtocolCode {
    <#
    .SYNOPSIS
        Converts friendly SNMP auth protocol names to WUG numeric codes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Protocol
    )

    $map = @{
        'None' = '0'
        'MD5' = '1'
        'SHA' = '3'
        'SHA1' = '3'
        'SHA256' = '5'
        'SHA384' = '6'
        'SHA512' = '7'
    }

    if ($map.ContainsKey($Protocol)) {
        return $map[$Protocol]
    }

    throw "Unsupported SNMP auth protocol '$Protocol' for WUG. Supported: $($map.Keys -join ', ')"
}

function ConvertTo-WUGPrivProtocolCode {
    <#
    .SYNOPSIS
        Converts friendly SNMP privacy protocol names to WUG numeric codes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Protocol
    )

    $map = @{
        'None' = '0'
        'DES' = '1'
        '3DES' = '2'
        'TripleDES' = '2'
        'AES' = '3'
        'AES128' = '3'
        'AES192' = '4'
        'AES256' = '5'
    }

    if ($map.ContainsKey($Protocol)) {
        return $map[$Protocol]
    }

    throw "Unsupported SNMP privacy protocol '$Protocol' for WUG. Supported: $($map.Keys -join ', ')"
}

function Get-CUCMDashboardRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$PhoneRows
    )

    $rows = @()
    foreach ($row in $PhoneRows) {
        $attrs = $row.Attributes
        $rows += [PSCustomObject]@{
            CallManager      = $row.DeviceName
            PhoneName        = $attrs['CUCM.PhoneName']
            Description      = $attrs['CUCM.PhoneDescription']
            UserName         = $attrs['CUCM.PhoneUserName']
            Status           = $attrs['CUCM.PhoneStatus']
            Protocol         = $attrs['CUCM.PhoneProtocol']
            IPAddress        = $attrs['CUCM.PhoneIpAddress']
            IPv4Address      = $attrs['CUCM.PhoneInetAddressIPv4']
            MACAddress       = $attrs['CUCM.PhonePhysicalAddress']
            LastRegistered   = $attrs['CUCM.PhoneTimeLastRegistered']
            LastStatusUpdate = $attrs['CUCM.PhoneTimeLastStatusUpdt']
            LoadID           = $attrs['CUCM.PhoneLoadID']
            Target           = $attrs['CUCM.Target']
        }
    }

    return $rows
}

function Get-CUCMResolvedSnmpSettings {
    [CmdletBinding()]
    param()

    $saved = $null
    if ($VaultName) {
        try {
            $saved = Get-DiscoveryCredential -Name $VaultName -ErrorAction SilentlyContinue
        }
        catch {
            $saved = $null
        }
    }

    if ($saved) {
        $savedVersion = if ($saved.ContainsKey('SnmpVersion')) { [string]$saved['SnmpVersion'] } else { '2' }
        $savedAuth = if ($savedVersion -eq '3') { 'SNMP v3' } else { "SNMP v$savedVersion" }

        Write-Host "  Vault: $VaultName" -ForegroundColor DarkGray
        Write-Host "  Found: $savedAuth settings" -ForegroundColor Green

        if ($NonInteractive -or $Action) {
            Write-Host '  Using existing credential.' -ForegroundColor Green
        }
        else {
            $savedChoice = Read-Host -Prompt '  Use existing? [Y]es / [R]eset / [N]o skip'
            switch -Regex ($savedChoice) {
                '^[Rr]' {
                    Write-Host '  Removing old credential...' -ForegroundColor Yellow
                    Remove-DiscoveryCredential -Name $VaultName -Confirm:$false -ErrorAction SilentlyContinue
                    $saved = $null
                }
                '^[Nn]' {
                    Write-Host '  Skipped.' -ForegroundColor DarkGray
                    return $null
                }
                default {
                    Write-Host '  Using existing credential.' -ForegroundColor Green
                }
            }
        }
    }

    $resolvedVersion = $SnmpVersion
    if ($saved -and $saved.ContainsKey('SnmpVersion') -and -not $script:InputSnmpVersionSpecified) {
        $resolvedVersion = [int]$saved['SnmpVersion']
    }

    $resolvedCommunity = $Community
    if ([string]::IsNullOrWhiteSpace($resolvedCommunity) -and $saved -and $saved.ContainsKey('Community')) {
        $resolvedCommunity = [string]$saved['Community']
    }

    $resolvedUsername = $SnmpUsername
    if ([string]::IsNullOrWhiteSpace($resolvedUsername) -and $saved -and $saved.ContainsKey('Username')) {
        $resolvedUsername = [string]$saved['Username']
    }

    $resolvedContext = $SnmpContext
    if ([string]::IsNullOrWhiteSpace($resolvedContext) -and $saved -and $saved.ContainsKey('Context')) {
        $resolvedContext = [string]$saved['Context']
    }

    $resolvedAuthProtocol = $SnmpAuthProtocol
    if ($saved -and $saved.ContainsKey('AuthProtocol') -and -not $script:InputSnmpAuthProtocolSpecified) {
        $resolvedAuthProtocol = [int]$saved['AuthProtocol']
    }

    $resolvedPrivacyProtocol = $SnmpPrivacyProtocol
    if ($saved -and $saved.ContainsKey('PrivacyProtocol') -and -not $script:InputSnmpPrivacyProtocolSpecified) {
        $resolvedPrivacyProtocol = [int]$saved['PrivacyProtocol']
    }

    $resolvedAuthPassword = ConvertTo-CUCMPlainText $SnmpAuthPassword
    if ([string]::IsNullOrWhiteSpace($resolvedAuthPassword) -and $saved -and $saved.ContainsKey('AuthPassword')) {
        $resolvedAuthPassword = [string]$saved['AuthPassword']
    }

    $resolvedPrivacyPassword = ConvertTo-CUCMPlainText $SnmpPrivacyPassword
    if ([string]::IsNullOrWhiteSpace($resolvedPrivacyPassword) -and $saved -and $saved.ContainsKey('PrivacyPassword')) {
        $resolvedPrivacyPassword = [string]$saved['PrivacyPassword']
    }

    if ($resolvedVersion -in @(1, 2) -and [string]::IsNullOrWhiteSpace($resolvedCommunity)) {
        if ($NonInteractive) {
            throw 'SNMP community is required for non-interactive SNMP v1/v2 discovery.'
        }
        $communitySecure = Read-Host -AsSecureString -Prompt 'SNMP read community'
        $resolvedCommunity = ConvertTo-CUCMPlainText $communitySecure
    }

    if ($resolvedVersion -eq 3) {
        if ([string]::IsNullOrWhiteSpace($resolvedUsername)) {
            if ($NonInteractive) {
                throw 'SNMP v3 username is required for non-interactive discovery.'
            }
            $resolvedUsername = Read-Host -Prompt 'SNMP v3 username'
        }

        if ($resolvedAuthProtocol -gt 0 -and [string]::IsNullOrWhiteSpace($resolvedAuthPassword)) {
            if ($NonInteractive) {
                throw 'SNMP v3 auth password is required when SnmpAuthProtocol is set.'
            }
            $resolvedAuthPassword = ConvertTo-CUCMPlainText (Read-Host -AsSecureString -Prompt 'SNMP v3 auth password')
        }

        if ($resolvedPrivacyProtocol -gt 0 -and [string]::IsNullOrWhiteSpace($resolvedPrivacyPassword)) {
            if ($NonInteractive) {
                throw 'SNMP v3 privacy password is required when SnmpPrivacyProtocol is set.'
            }
            $resolvedPrivacyPassword = ConvertTo-CUCMPlainText (Read-Host -AsSecureString -Prompt 'SNMP v3 privacy password')
        }
    }
    else {
        # For SNMP v1/v2, ignore all v3-only settings.
        $resolvedUsername = ''
        $resolvedContext = ''
        $resolvedAuthProtocol = 0
        $resolvedAuthPassword = ''
        $resolvedPrivacyProtocol = 0
        $resolvedPrivacyPassword = ''
    }

    $settings = [ordered]@{
        SnmpVersion = $resolvedVersion
        Community = $resolvedCommunity
        Username = $resolvedUsername
        Context = $resolvedContext
        AuthProtocol = $resolvedAuthProtocol
        AuthPassword = $resolvedAuthPassword
        PrivacyProtocol = $resolvedPrivacyProtocol
        PrivacyPassword = $resolvedPrivacyPassword
        Port = $SnmpPort
        TimeoutMs = $TimeoutMs
        Retries = $Retries
    }

    Write-Verbose "[SNMP Settings Resolved] Version: $resolvedVersion  Community: $(if([string]::IsNullOrWhiteSpace($resolvedCommunity)) { '(empty)' } else { '*****' })  Port: $SnmpPort  Timeout: ${TimeoutMs}ms  Retries: $Retries"
    if ($resolvedVersion -eq 3) {
        Write-Verbose "[SNMP v3] Username: $(if([string]::IsNullOrWhiteSpace($resolvedUsername)) { '(empty)' } else { $resolvedUsername })  Context: $(if([string]::IsNullOrWhiteSpace($resolvedContext)) { '(empty)' } else { $resolvedContext })  AuthProtocol: $resolvedAuthProtocol  PrivacyProtocol: $resolvedPrivacyProtocol"
    }

    if (-not $NonInteractive -and $VaultName) {
        $fields = [ordered]@{
            SnmpVersion = ConvertTo-CUCMSecureString -Value ([string]$settings.SnmpVersion)
        }

        if ([int]$settings.SnmpVersion -in @(1, 2)) {
            if (-not [string]::IsNullOrWhiteSpace($settings.Community)) {
                $fields['Community'] = ConvertTo-CUCMSecureString -Value $settings.Community
            }
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($settings.Username)) {
                $fields['Username'] = ConvertTo-CUCMSecureString -Value $settings.Username
            }
            if (-not [string]::IsNullOrWhiteSpace($settings.Context)) {
                $fields['Context'] = ConvertTo-CUCMSecureString -Value $settings.Context
            }

            $fields['AuthProtocol'] = ConvertTo-CUCMSecureString -Value ([string]$settings.AuthProtocol)
            $fields['PrivacyProtocol'] = ConvertTo-CUCMSecureString -Value ([string]$settings.PrivacyProtocol)

            if (-not [string]::IsNullOrWhiteSpace($settings.AuthPassword)) {
                $fields['AuthPassword'] = ConvertTo-CUCMSecureString -Value $settings.AuthPassword
            }
            if (-not [string]::IsNullOrWhiteSpace($settings.PrivacyPassword)) {
                $fields['PrivacyPassword'] = ConvertTo-CUCMSecureString -Value $settings.PrivacyPassword
            }
        }

        Save-DiscoveryCredential -Name $VaultName -Fields $fields -Description 'CUCM SNMP settings' -Force | Out-Null
    }

    return $settings
}

function New-CUCMBatchAttributeBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Attributes
    )

    $items = @()
    foreach ($name in $Attributes.Keys) {
        $items += @{ op = 'add'; name = $name; value = [string]$Attributes[$name] }
    }

    return (@{ items = $items } | ConvertTo-Json -Depth 6)
}

function Export-CUCMInventoryJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$DevicePlan
    )

    $inventoryRows = @()
    $monitorPlan = @()
    $summaries = @()

    foreach ($device in $DevicePlan.Values) {
        $inventoryRows += @(Get-CUCMDashboardRows -PhoneRows @($device.PhoneRows))
        $monitorPlan += @(New-CUCMDiscoveryPlanFromPhoneInventory -DeviceId 0 -DeviceName $device.Name -TargetAddress $device.IP -PhoneRows @($device.PhoneRows))
        $summaries += [PSCustomObject]@{
            DeviceName = $device.Name
            Target = $device.IP
            Phones = $device.Summary.total
            Registered = $device.Summary.registered
            Unregistered = $device.Summary.unregistered
            Rejected = $device.Summary.rejected
            PartiallyRegistered = $device.Summary.partiallyregistered
            Unknown = $device.Summary.unknown
        }
    }

    $payload = [PSCustomObject]@{
        GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Targets = $Target
        Summary = $summaries
        Inventory = $inventoryRows
        MonitorPlan = $monitorPlan
    }

    $payload | ConvertTo-Json -Depth 8 | Set-Content -Path $Path
}

function Import-CUCMWUGModule {
    [CmdletBinding()]
    param()

    if (Get-Command -Name 'Get-WUGDevice' -ErrorAction SilentlyContinue) {
        return
    }

    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $repoPsd1 = Join-Path $repoRoot 'WhatsUpGoldPS.psd1'
    if (Test-Path $repoPsd1) {
        Import-Module $repoPsd1 -Force -ErrorAction Stop
    }
    else {
        Import-Module WhatsUpGoldPS -ErrorAction Stop
    }
}

function Connect-CUCMWUG {
    [CmdletBinding()]
    param()

    if ($WUGCredential) {
        if (-not $WUGServer) {
            throw 'WUGServer is required when WUGCredential is supplied.'
        }
        Connect-WUGServer -serverUri $WUGServer -Credential $WUGCredential -IgnoreSSLErrors | Out-Null
        return
    }

    if ($WUGServer) {
        Connect-WUGServer -serverUri $WUGServer -IgnoreSSLErrors | Out-Null
    }
    else {
        Connect-WUGServer -AutoConnect -IgnoreSSLErrors | Out-Null
    }
}

function Resolve-CUCMWUGDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetAddress
    )

    $matches = @(Get-WUGDevice -SearchValue $TargetAddress)
    $device = $matches | Where-Object {
        $_.networkAddress -eq $TargetAddress -or
        $_.hostName -eq $TargetAddress -or
        $_.displayName -eq $TargetAddress
    } | Select-Object -First 1

    if (-not $device) {
        Add-WUGDevice -IpOrName $TargetAddress -GroupId $DeviceGroupId -UseAllCredentials:$false -ForceAdd:$true -Confirm:$false | Out-Null
        $matches = @(Get-WUGDevice -SearchValue $TargetAddress)
        $device = $matches | Where-Object {
            $_.networkAddress -eq $TargetAddress -or
            $_.hostName -eq $TargetAddress -or
            $_.displayName -eq $TargetAddress
        } | Select-Object -First 1
    }

    if (-not $device) {
        throw "Could not resolve or create WUG device for $TargetAddress."
    }

    return $device
}

function Get-CUCMSnmpCredentialName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetAddress,

        [Parameter(Mandatory = $true)]
        [hashtable]$SnmpSettings
    )

    return "CUCM SNMP [$TargetAddress] v$($SnmpSettings.SnmpVersion)"
}

function Ensure-CUCMSnmpCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetAddress,

        [Parameter(Mandatory = $true)]
        [hashtable]$SnmpSettings
    )

    $credentialType = switch ([int]$SnmpSettings.SnmpVersion) {
        1 { 'snmpV1' }
        2 { 'snmpV2' }
        3 { 'snmpV3' }
        default { throw "Unsupported SNMP version '$($SnmpSettings.SnmpVersion)' for WUG push." }
    }

    $credentialName = Get-CUCMSnmpCredentialName -TargetAddress $TargetAddress -SnmpSettings $SnmpSettings
    $existing = @(Get-WUGCredential -SearchValue $credentialName -Type $credentialType -View basic) | Where-Object { $_.name -eq $credentialName } | Select-Object -First 1
    if ($existing) {
        return $existing
    }

    switch ($credentialType) {
        'snmpV1' {
            return (Add-WUGCredential -Name $credentialName -Type snmpV1 -SnmpReadCommunity $SnmpSettings.Community -Confirm:$false)
        }
        'snmpV2' {
            return (Add-WUGCredential -Name $credentialName -Type snmpV2 -SnmpReadCommunity $SnmpSettings.Community -Confirm:$false)
        }
        'snmpV3' {
            if ([string]::IsNullOrWhiteSpace($SnmpSettings.Username) -or [string]::IsNullOrWhiteSpace($SnmpSettings.AuthPassword)) {
                throw 'PushToWUG requires SNMPv3 username and auth password so a WUG credential can be created.'
            }

            # Convert friendly protocol names to WUG numeric codes
            $authProtocol = ConvertTo-WUGAuthProtocolCode -Protocol $SnmpSettings.AuthProtocol
            $encryptProtocol = ConvertTo-WUGPrivProtocolCode -Protocol $SnmpSettings.PrivacyProtocol

            return (Add-WUGCredential -Name $credentialName -Type snmpV3 `
                -SnmpV3Username $SnmpSettings.Username `
                -SnmpV3Context $SnmpSettings.Context `
                -SnmpV3AuthPassword $SnmpSettings.AuthPassword `
                -SnmpV3AuthProtocol $authProtocol `
                -SnmpV3EncryptPassword $SnmpSettings.PrivacyPassword `
                -SnmpV3EncryptProtocol $encryptProtocol `
                -Confirm:$false)
        }
    }
}

function Get-CUCMCredentialIdentifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $CredentialObject
    )

    if ($CredentialObject.PSObject.Properties['resourceId']) { return [string]$CredentialObject.resourceId }
    if ($CredentialObject.PSObject.Properties['id']) { return [string]$CredentialObject.id }
    throw 'Could not determine the WUG credential identifier.'
}

function Push-CUCMPlanToWUG {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$DevicePlan,

        [Parameter(Mandatory = $true)]
        [hashtable]$SnmpSettings
    )

    Import-CUCMWUGModule
    Connect-CUCMWUG

    $pushPlan = @()
    foreach ($deviceEntry in $DevicePlan.Values) {
        $resolvedDevice = Resolve-CUCMWUGDevice -TargetAddress $deviceEntry.IP
        $wugCredential = Ensure-CUCMSnmpCredential -TargetAddress $deviceEntry.IP -SnmpSettings $SnmpSettings
        $wugCredentialId = Get-CUCMCredentialIdentifier -CredentialObject $wugCredential

        $assignedSnmpCreds = @(Get-WUGDeviceCredential -DeviceId $resolvedDevice.id -Type snmp)
        if ($assignedSnmpCreds.Count -gt 0) {
            $alreadyAssigned = $assignedSnmpCreds | Where-Object {
                $_.id -eq $wugCredentialId -or $_.credentialId -eq $wugCredentialId -or $_.name -eq $wugCredential.name
            } | Select-Object -First 1
            if (-not $alreadyAssigned) {
                Write-Warning "Device $($resolvedDevice.displayName) already has SNMP credential assignments. Adding the CUCM credential without removing the existing ones."
            }
        }

        Set-WUGDeviceCredential -DeviceId $resolvedDevice.id -CredentialId $wugCredentialId -Assign -Confirm:$false | Out-Null
        Set-WUGDeviceAttribute -DeviceId $resolvedDevice.id -Name 'DiscoveryHelper.CUCM' -Value 'true' -Confirm:$false | Out-Null

        $pushPlan += @(New-CUCMDiscoveryPlanFromPhoneInventory -DeviceId ([int]$resolvedDevice.id) -DeviceName $resolvedDevice.displayName -TargetAddress $deviceEntry.IP -PhoneRows @($deviceEntry.PhoneRows))
    }

    if (-not $pushPlan -or $pushPlan.Count -eq 0) {
        Write-Warning 'No CUCM monitor items were generated for WUG sync.'
        return $null
    }

    if (-not $PSCmdlet.ShouldProcess("$($pushPlan.Count) CUCM monitor plan item(s)", 'Sync monitors to WhatsUp Gold')) {
        return $null
    }

    return (Invoke-WUGDiscoverySync -Plan $pushPlan -PollingIntervalSeconds $PollingIntervalSeconds -PerfPollingIntervalMinutes 5)
}

if (-not $OutputPath) {
    if ($NonInteractive) {
        $OutputPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
    }
    else {
        $OutputPath = $env:TEMP
    }
}
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$OutputDir = $OutputPath

$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
try {
    . (Join-Path $scriptDir 'DiscoveryHelpers.ps1')
}
catch {
    Write-Error "Failed to load DiscoveryHelpers.ps1: $_"
    return
}
try {
    . (Join-Path $scriptDir 'DiscoveryProvider-CUCM.ps1')
}
catch {
    Write-Error "Failed to load DiscoveryProvider-CUCM.ps1: $_"
    return
}

$dynDashPath = Join-Path (Split-Path $scriptDir -Parent) 'reports\Export-DynamicDashboardHtml.ps1'
if (Test-Path $dynDashPath) { . $dynDashPath }

Write-Host '=== CUCM Phone Inventory Discovery ===' -ForegroundColor Cyan
Write-Host "Targets: $($Target -join ', ')" -ForegroundColor Cyan
Write-Host ''

$snmpSettings = Get-CUCMResolvedSnmpSettings -Verbose
if (-not $snmpSettings) {
    Write-Error 'No CUCM SNMP settings available. Exiting.'
    return
}

Write-Host 'Walking ccmPhoneTable via WhatsUp Gold SNMP API...' -ForegroundColor Cyan
Write-Host "  SNMP Version: $($snmpSettings.SnmpVersion)  Port: $($snmpSettings.Port)  Timeout: $($snmpSettings.TimeoutMs)ms  Retries: $($snmpSettings.Retries)" -ForegroundColor DarkGray
if ($snmpSettings.SnmpVersion -eq 3) {
    Write-Host "  SNMP v3 User: $($snmpSettings.Username)  AuthProto: $($snmpSettings.AuthProtocol)  PrivProto: $($snmpSettings.PrivacyProtocol)" -ForegroundColor DarkGray
}
else {
    Write-Host "  Community: $($snmpSettings.Community)" -ForegroundColor DarkGray
}

$devicePlan = [ordered]@{}
foreach ($targetAddress in $Target) {
    Write-Host "  Walking $targetAddress ..." -ForegroundColor DarkGray -NoNewline
    try {
        $phoneRows = @(Get-CUCMPhoneInventory -DeviceName $targetAddress -TargetAddress $targetAddress -Credential $snmpSettings -Verbose)
    }
    catch {
        Write-Host ' FAILED' -ForegroundColor Red
        Write-Warning "SNMP walk error for ${targetAddress}: $_"
        $phoneRows = @()
    }
    Write-Host " $($phoneRows.Count) row(s)" -ForegroundColor $(if ($phoneRows.Count -gt 0) { 'Green' } else { 'Yellow' })
    if ($phoneRows.Count -eq 0) {
        continue
    }

    $summary = Get-CUCMPhoneStatusCounts -PhoneRows $phoneRows
    $devicePlan[$targetAddress] = [ordered]@{
        Name = $targetAddress
        IP = $targetAddress
        PhoneRows = $phoneRows
        Summary = $summary
    }
}

if ($devicePlan.Count -eq 0) {
    Write-Host ''
    Write-Host '!!! DIAGNOSTIC INFO !!!' -ForegroundColor Yellow
    Write-Host "Targets: $($Target -join ', ')" -ForegroundColor Yellow
    Write-Host "SNMP Version: $($snmpSettings.SnmpVersion)" -ForegroundColor Yellow
    Write-Host "SNMP Port: $($snmpSettings.Port)" -ForegroundColor Yellow
    Write-Host "SNMP Timeout: $($snmpSettings.TimeoutMs)ms" -ForegroundColor Yellow
    if ($snmpSettings.SnmpVersion -eq 3) {
        Write-Host "SNMP v3 Username: $($snmpSettings.Username)" -ForegroundColor Yellow
        Write-Host "SNMP v3 Context: $($snmpSettings.Context)" -ForegroundColor Yellow
        Write-Host "SNMP v3 AuthProtocol: $($snmpSettings.AuthProtocol)  PrivacyProtocol: $($snmpSettings.PrivacyProtocol)" -ForegroundColor Yellow
    }
    else {
        Write-Host "SNMP v$($snmpSettings.SnmpVersion) Community: $($snmpSettings.Community)" -ForegroundColor Yellow
    }
    Write-Host "Re-run with -Verbose flag for detailed SNMP walk diagnostics." -ForegroundColor Yellow
    Write-Host ''
    Write-Warning 'No CUCM phone rows were discovered.'
    return
}

Write-Host ''
Write-Host 'Discovery complete!' -ForegroundColor Green
foreach ($device in $devicePlan.Values) {
    Write-Host "  $($device.Name) ($($device.IP))  Phones=$($device.Summary.total)  Registered=$($device.Summary.registered)  Unregistered=$($device.Summary.unregistered)" -ForegroundColor White
}

$choice = $null
if ($Action) {
    switch ($Action) {
        'PushToWUG' { $choice = '1' }
        'ExportJSON' { $choice = '2' }
        'ExportCSV' { $choice = '3' }
        'ShowTable' { $choice = '4' }
        'Dashboard' { $choice = '5' }
        'None' { $choice = '6' }
        'DashboardAndPush' { $choice = '7' }
    }
}

if (-not $choice -and $NonInteractive) {
    $choice = '5'
}

if (-not $choice) {
    Write-Host ''
    Write-Host 'What would you like to do?' -ForegroundColor Cyan
    Write-Host '  [1] Push CUCM monitor plan to WhatsUp Gold'
    Write-Host '  [2] Export inventory to JSON file'
    Write-Host '  [3] Export inventory to CSV file'
    Write-Host '  [4] Show phone table in console'
    Write-Host '  [5] Generate HTML dashboards'
    Write-Host '  [6] Exit (do nothing)'
    Write-Host '  [7] Dashboard + Push to WUG'
    Write-Host ''
    $choice = Read-Host -Prompt 'Choice [1-7]'
}

if ($choice -eq '7') {
    $actionsToRun = @('5', '1')
}
else {
    $actionsToRun = @($choice)
}

foreach ($currentChoice in $actionsToRun) {
    switch ($currentChoice) {
        '1' {
            $syncResult = Push-CUCMPlanToWUG -DevicePlan $devicePlan -SnmpSettings $snmpSettings
            if ($syncResult) {
                Write-Host ''
                Write-Host 'WUG sync complete!' -ForegroundColor Green
                Write-Host "  Active monitors created:      $($syncResult.ActiveCreated)" -ForegroundColor White
                Write-Host "  Performance monitors created: $($syncResult.PerfCreated)" -ForegroundColor White
                Write-Host "  Assigned to devices:          $($syncResult.Assigned)" -ForegroundColor White
                Write-Host "  Skipped:                      $($syncResult.Skipped)" -ForegroundColor White
                Write-Host "  Attributes updated:           $($syncResult.AttrsUpdated)" -ForegroundColor White
                if ($syncResult.Failed -gt 0) {
                    Write-Host "  Failed:                       $($syncResult.Failed)" -ForegroundColor Red
                }
            }
        }
        '2' {
            $jsonPath = Join-Path $OutputDir "CUCM-Inventory-$(Get-Date -Format yyyyMMdd-HHmmss).json"
            Export-CUCMInventoryJson -Path $jsonPath -DevicePlan $devicePlan
            Write-Host "JSON exported: $jsonPath" -ForegroundColor Green
        }
        '3' {
            $csvPath = Join-Path $OutputDir "CUCM-Inventory-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
            $allRows = @()
            foreach ($device in $devicePlan.Values) {
                $allRows += @(Get-CUCMDashboardRows -PhoneRows @($device.PhoneRows))
            }
            $allRows | Export-Csv -Path $csvPath -NoTypeInformation
            Write-Host "CSV exported: $csvPath" -ForegroundColor Green
        }
        '4' {
            foreach ($device in $devicePlan.Values) {
                Get-CUCMDashboardRows -PhoneRows @($device.PhoneRows) |
                    Select-Object CallManager, PhoneName, Description, Status, Protocol, IPAddress, LastRegistered |
                    Format-Table -AutoSize
            }
        }
        '5' {
            Write-Host ''
            Write-Host 'Generating dashboards...' -ForegroundColor Cyan

            # Aggregate all phone rows
            $allRows = @()
            foreach ($device in $devicePlan.Values) {
                $allRows += @(Get-CUCMDashboardRows -PhoneRows @($device.PhoneRows))
            }

            if ($allRows.Count -eq 0) {
                Write-Warning 'No phone inventory to export.'
                break
            }

            # Create summary JSON file in output directory
            $summaryJsonPath = Join-Path $OutputDir 'CUCM-phone-inventory-summary.json'
            $allRows | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $summaryJsonPath -Encoding UTF8
            Write-Host "  Summary JSON: $summaryJsonPath ($($allRows.Count) phones)" -ForegroundColor DarkGray

            # Call dashboard exporter
            $exporterPath = Join-Path $PSScriptRoot '..\cisco-cucm\Export-CUCM-Dashboard.ps1'
            if (-not (Test-Path -LiteralPath $exporterPath)) {
                Write-Warning "Dashboard exporter not found: $exporterPath"
            }
            else {
                & $exporterPath -SummaryDirectory $OutputDir -OutputDirectory $OutputDir
            }

            $dashboardFiles = @(Get-ChildItem $OutputDir -Filter 'cucm-dashboard-*.html' -ErrorAction SilentlyContinue)
            Write-Host "Generated $($dashboardFiles.Count) dashboard(s)" -ForegroundColor Green

            # Copy to WUG NmConsole if available
            $nmConsolePaths = @(
                "${env:ProgramFiles(x86)}\Ipswitch\WhatsUp\Html\NmConsole"
                "${env:ProgramFiles}\Ipswitch\WhatsUp\Html\NmConsole"
            )
            $nmConsolePath = $nmConsolePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($nmConsolePath) {
                $wugDashDir = Join-Path $nmConsolePath 'dashboards'
                if (-not (Test-Path $wugDashDir)) {
                    New-Item -ItemType Directory -Path $wugDashDir -Force | Out-Null
                }

                foreach ($dashFile in $dashboardFiles) {
                    $destPath = Join-Path $wugDashDir (Split-Path $dashFile -Leaf)
                    try {
                        Copy-Item -Path $dashFile -Destination $destPath -Force
                        Write-Host "  Copied to WUG: $destPath" -ForegroundColor Green
                    }
                    catch {
                        Write-Warning "Could not copy dashboard to NmConsole: $_"
                    }
                }
                Deploy-DashboardWebConfig -Path $wugDashDir
            }
        }
        default {
            Write-Host 'Discovery completed with no output action selected.' -ForegroundColor Yellow
        }
    }
}

# ---- END OF SCRIPT (do not remove this line or the closing braces abov
# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA9rPdrneB4/JWM
# 9+SBjGi2USzt7/+5hIvKxpnYc0zOgaCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCCW4wGliMkRI66wu8Y5VmPOLWD6DeTLEqHk1hkeUSXcHDANBgkqhkiG9w0BAQEF
# AASCAgBSMgg11GjzIPvg4flljB6rW8r3f8lB36k9yYIbkv/nYb7X1eCw1eURH925
# ANujCW0hZIMdGbZ01F0tVRrVvDdLPsldXLk/bUivpM+rslLJgL/3Lg1L1Ay0JjQo
# jEg9njXikmG8qEEyz5twqWv+3CKsoj/KevmZkyZkZctZsyL9PoU0rbwT3YyOBY6L
# Bb3r3MWRfMwVAuXaSMcnYN1iMf/QI8dE1ZBVr9s7ixpfZk8AtYSVgMk+APGykYb8
# WkU3F4dzD0hk1WyG+vy1aWdhrmoDXWtmnMEkenqgkGo2gOpm+WweDtRZTOZ5+n+D
# IDOWzvj2CGONRV5vRgKgLiVToIDtzfI5Iv2LsabelHENwC6pIUQ9e0DPzUzgfKR8
# JISEKbu8cP9rvn9aPeGjwhQmpvxBQpppMxwUj963D5fGjZKUvk+uERm/QqE1s+MU
# KnCTESuZhCgzYNbOspcJFzsUyrqAfdI7US3aqYMdsV+DZxYjmrBWD0/X1zCqAIn0
# 7DkxYqEhTkSIiZx6zCe8YKMSKmYegWim4wflkOU0Bm9djvv96n7VQrMG5YyFyNms
# doLDsG4/p8JwBqt1wWqoczqWIDWBTwcsww5Tb2553vtZyKCfU4Q05T0kAgFxpQKD
# 6hH/263C8wu+Hg6kcEGNeqtjQ/hPjixpBaMVfPVNa/eiOyF3RqGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA2MjUxMjMzNTlaMC8GCSqGSIb3DQEJBDEiBCDodWAf
# uJDjQ2JIyRx5WlrLQiFcSoPnyOw2KS+zNSZkZjANBgkqhkiG9w0BAQEFAASCAgDQ
# QC8KTZ1JEA+WJ4QbpL9wEz06Pcc2f1SOu7pxn8Nauzd5GVcjl9g7OslMB2RzSHwy
# p04bdu+gcc7aaGT61pJCXSuYcfqtCabexCoyKElk0IJmT6PkVo6RQXe+CJwCFkto
# yzfsnMmTXpP+JUXRQcb6Wsko8vlZLkGRXboDlEoswpot6/hmB7VXnhPXxZubyI9E
# +48taBEWkp9gw30p0H6A8VLnaUk7uL8KDK2Sn1aDz7jdWFwYQE4y67v/+t4vOhaf
# ZuofKNXnjkcBZIIIf/N8CFXlVR/j/TnpwSlIXkLLTNniS9kUH9UYhmVf4uJYtHWT
# AXqe30UQWC2bgna2T8fNmRI9nLZS39JuvFmIeVW/ciqqihj1F1/OMa4Cj48xnOzz
# k4N1hV6IaWAemd8GL2+yiu8jHPlLun++nscXLcBunzZSiqa6vXfH+KQsLM2kw/6p
# /Q9T3m+Z02i6rHX3Hik/bagpUuBB6Fk8FxEG/PM2edRe7PvxyuSjswkya+SUXLYs
# /trWuEZlNtOhaQG77Rr7bKfXtQnP6IPYEnTrKMWiCI2l7NnhimAhe3YiW0pvGS+v
# ZvN/jCjxz3xOb6PvY9Vl37ZEUliViR4fu5p6AY/ye5K6BoL1g/UzcAWvJgb0m6x0
# 709zk6KoDEtw8UvBbYa6fKVuXYAGPnqgnVRos+wl3g==
# SIG # End signature block
