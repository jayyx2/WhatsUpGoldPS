<#
.SYNOPSIS
    Standalone discovery framework for infrastructure device APIs.
    Optionally provisions WUG REST API monitors when WhatsUpGoldPS is available.

.DESCRIPTION
    DiscoveryHelpers is a portable, WUG-independent framework that discovers
    monitorable items from infrastructure device APIs (F5, Fortinet, etc.).
    It can run anywhere PowerShell 5.1+ runs   no WhatsUp Gold required.

    Two operating modes:

    === Standalone Mode (no WUG) ===

      1. Register-DiscoveryProvider    Register a technology provider
      2. Invoke-Discovery              Discover items from target hosts
      3. Export-DiscoveryPlan          Output plan as JSON, CSV, or objects
         (or just pipe to Format-Table, Out-GridView, etc.)

      Use this mode for:
        - Inventory / audit scripts that run anywhere
        - Feeding results into other monitoring systems (Zabbix, PRTG, etc.)
        - CI/CD pipelines that validate infrastructure
        - Standalone reporting without any NMS dependency

    === WUG Integration Mode ===

      4. Invoke-WUGDiscovery           Discover from WUG-registered devices
      5. Invoke-WUGDiscoverySync       Create WUG REST API monitors from plan
      6. New-WUGDiscoveryCredential    Store API creds in WUG credential store

      Use this mode when WhatsUpGoldPS is loaded and connected.

    Provider Pattern:
      Each technology registers a provider with:
        - Name             Unique identifier (e.g., 'F5', 'Fortinet')
        - MatchAttribute   WUG device attribute for auto-matching (WUG mode only)
        - DiscoverScript   ScriptBlock that receives a context hashtable and
                           returns discovered item objects
        - DefaultPort      Default API port (443)
        - DefaultProtocol  Default protocol ('https')

    The DiscoverScript receives a context with:
        DeviceId, DeviceName, DeviceIP, BaseUri, Port, Protocol,
        ProviderName, AttributeValue, ExistingMonitors, IgnoreCertErrors

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: PowerShell 5.1+
    Optional: WhatsUpGoldPS module (for WUG integration mode only)
    Encoding: UTF-8 with BOM
    Standalone: Yes   core discovery functions have zero external dependencies.

    SECURITY (WUG mode):
    - Device API credentials are stored in WUG via Add-WUGCredential (REST API type).
    - They are NEVER written to disk as plaintext/DPAPI files.
    - WUG's credential store handles encryption and access control.
    - The REST API monitor uses the credential assigned to the device.
    - Set RestApiUseAnonymous='0' so the monitor uses the device credential.

    SECURITY (Standalone mode):
    - Credentials/tokens passed as parameters live only in memory.
    - Export-DiscoveryPlan does NOT include credentials in its output.
    - If you persist the plan to disk, no secrets are included.
#>

# ============================================================================
# region  Provider Registry (Standalone   no WUG dependency)
# ============================================================================

$script:DiscoveryProviders = @{}

function Register-DiscoveryProvider {
    <#
    .SYNOPSIS
        Registers a technology-specific discovery provider.
    .DESCRIPTION
        Adds a provider definition that Invoke-Discovery or Invoke-WUGDiscovery
        uses to query device APIs and build monitor plans. Each provider knows
        how to talk to a specific device type (F5 iControl, FortiGate REST,
        etc.) and returns a structured list of items to monitor.

        This function has zero WUG dependencies   it just stores the provider
        definition in memory for later use.
    .PARAMETER Name
        Unique provider name (e.g., 'F5', 'Fortinet').
    .PARAMETER MatchAttribute
        WUG device attribute name for auto-matching in WUG mode.
        Ignored in standalone mode. Default: 'DiscoveryHelper.<Name>'.
    .PARAMETER DiscoverScript
        A ScriptBlock that receives a hashtable context and returns an
        array of discovered item objects. The context contains:
          DeviceId       : Device identifier (WUG ID or user-supplied label)
          DeviceName     : Device display name
          DeviceIP       : Device IP address or hostname
          BaseUri        : Base API URL (e.g., https://10.0.0.1:443)
          Port           : API port
          Protocol       : 'https' or 'http'
          ProviderName   : This provider's name
          AttributeValue : Attribute value (WUG mode) or empty string
          ExistingMonitors: Array of existing monitors (WUG mode) or empty
          IgnoreCertErrors: Boolean
    .PARAMETER CredentialType
        WUG credential type (WUG mode only). Default: 'restapi'.
    .PARAMETER AuthType
        Authentication method the target device API expects.
        'BasicAuth'   requires username + password (e.g., F5 iControl).
        'BearerToken'   requires a single API token (e.g., FortiGate).
        Used by Start-WUGDiscovery to know what to prompt for.
        Default: 'BasicAuth'.
    .PARAMETER DefaultPort
        Default API port. Default: 443.
    .PARAMETER DefaultProtocol
        Default protocol. Default: 'https'.
    .PARAMETER IgnoreCertErrors
        Whether monitors should ignore cert errors. Default: $true.
    .EXAMPLE
        Register-DiscoveryProvider -Name 'F5' `
            -MatchAttribute 'DiscoveryHelper.F5' `
            -DiscoverScript { param($ctx) ... return $items }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [string]$MatchAttribute,

        [Parameter(Mandatory = $true)]
        [ScriptBlock]$DiscoverScript,

        [Parameter()]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
        [string]$CredentialType = 'restapi',

        [Parameter()]
        [ValidateSet('BasicAuth', 'BearerToken')]
        [string]$AuthType = 'BasicAuth',

        [Parameter()]
        [int]$DefaultPort = 443,

        [Parameter()]
        [string]$DefaultProtocol = 'https',

        [Parameter()]
        [bool]$IgnoreCertErrors = $true
    )

    if (-not $MatchAttribute) {
        $MatchAttribute = "DiscoveryHelper.$Name"
    }

    $script:DiscoveryProviders[$Name] = [PSCustomObject]@{
        Name             = $Name
        MatchAttribute   = $MatchAttribute
        DiscoverScript   = $DiscoverScript
        CredentialType   = $CredentialType
        AuthType         = $AuthType
        DefaultPort      = $DefaultPort
        DefaultProtocol  = $DefaultProtocol
        IgnoreCertErrors = $IgnoreCertErrors
    }

    Write-Verbose "Registered discovery provider '$Name' (match: $MatchAttribute)"
}

# Backward-compatible alias for existing code
Set-Alias -Name 'Register-WUGDiscoveryProvider' -Value 'Register-DiscoveryProvider' -Scope Script

function Get-DiscoveryProvider {
    <#
    .SYNOPSIS
        Returns registered discovery providers.
    .PARAMETER Name
        Provider name filter. Returns all if omitted.
    #>
    [CmdletBinding()]
    param(
        [string]$Name
    )

    if ($Name) {
        if ($script:DiscoveryProviders.ContainsKey($Name)) {
            return $script:DiscoveryProviders[$Name]
        }
        Write-Warning "Discovery provider '$Name' is not registered."
        return $null
    }

    return $script:DiscoveryProviders.Values
}

Set-Alias -Name 'Get-WUGDiscoveryProvider' -Value 'Get-DiscoveryProvider' -Scope Script

# endregion

# ============================================================================
# region  Device Discovery
# ============================================================================

function Find-WUGDiscoveryDevices {
    <#
    .SYNOPSIS
        Finds WUG devices that match a discovery provider's attribute.
    .DESCRIPTION
        Searches for devices with the provider's MatchAttribute set.
        Returns device ID, name, IP, and the attribute value.
    .PARAMETER ProviderName
        Name of the registered provider to search for.
    .PARAMETER DeviceId
        Optionally limit search to specific device IDs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProviderName,

        [Parameter()]
        [int[]]$DeviceId
    )

    $provider = Get-DiscoveryProvider -Name $ProviderName
    if (-not $provider) {
        Write-Error "Provider '$ProviderName' is not registered."
        return
    }

    $matchAttr = $provider.MatchAttribute
    $devices = @()

    if ($DeviceId) {
        foreach ($id in $DeviceId) {
            $dev = Get-WUGDevice -DeviceId $id
            if ($dev) { $devices += $dev }
        }
    }
    else {
        # Search all devices   get ALL devices and filter by attribute
        # This is the discovery mode: find every device tagged for this provider
        Write-Verbose "Searching all devices for attribute '$matchAttr'..."
        $allDevices = Get-WUGDevice -Search '*' -Column 'name'
        $devices = @($allDevices)
    }

    $matched = @()
    foreach ($dev in $devices) {
        $devId = $dev.id
        try {
            $attrs = Get-WUGDeviceAttribute -DeviceId $devId
            $helperAttr = $attrs | Where-Object { $_.name -eq $matchAttr }
            if ($helperAttr -and $helperAttr.value -and $helperAttr.value -notin @('', 'false', '0', $null)) {
                $matched += [PSCustomObject]@{
                    DeviceId       = $devId
                    DeviceName     = $dev.displayName
                    DeviceIP       = if ($dev.networkAddress) { $dev.networkAddress } else { $dev.hostName }
                    AttributeValue = $helperAttr.value
                    ProviderName   = $ProviderName
                }
            }
        }
        catch {
            Write-Warning "Failed to check attributes for device $devId ($($dev.displayName)): $_"
        }
    }

    Write-Verbose "Found $($matched.Count) device(s) for provider '$ProviderName'"
    return $matched
}

# endregion

# ============================================================================
# region  Discovered Item Schema (Standalone   no WUG dependency)
# ============================================================================

function New-DiscoveredItem {
    <#
    .SYNOPSIS
        Creates a standardized discovered-item object for the monitor plan.
    .DESCRIPTION
        Each provider's DiscoverScript should return one or more of these
        objects. They describe what should be monitored and how.

        In standalone mode, these are pure data objects   inspect, filter,
        export them however you like. In WUG mode, Invoke-WUGDiscoverySync
        creates the actual monitors from these objects.
    .PARAMETER Name
        Human-readable name for this item (used in the monitor name).
    .PARAMETER ItemType
        Classification: 'ActiveMonitor' or 'PerformanceMonitor'.
    .PARAMETER MonitorType
        Monitor type: 'RestApi', 'TcpIp', 'Certificate', 'Ping', etc.
    .PARAMETER MonitorParams
        Hashtable of type-specific parameters.
    .PARAMETER UniqueKey
        A string that uniquely identifies this item across discovery runs.
        Used for idempotent create/skip logic.
    .PARAMETER DeviceId
        Device identifier (WUG device ID or a user-supplied label).
    .PARAMETER Attributes
        Optional hashtable of device attributes to set/update.
    .PARAMETER Tags
        Optional array of tags for filtering/grouping.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet('ActiveMonitor', 'PerformanceMonitor')]
        [string]$ItemType,

        [Parameter(Mandatory = $true)]
        [string]$MonitorType,

        [Parameter(Mandatory = $true)]
        [hashtable]$MonitorParams,

        [Parameter(Mandatory = $true)]
        [string]$UniqueKey,

        [Parameter()]
        [int]$DeviceId,

        [Parameter()]
        [hashtable]$Attributes,

        [Parameter()]
        [string[]]$Tags
    )

    [PSCustomObject]@{
        Name          = $Name
        ItemType      = $ItemType
        MonitorType   = $MonitorType
        MonitorParams = $MonitorParams
        UniqueKey     = $UniqueKey
        DeviceId      = $DeviceId
        Attributes    = if ($Attributes) { $Attributes } else { @{} }
        Tags          = if ($Tags) { $Tags } else { @() }
    }
}

Set-Alias -Name 'New-WUGDiscoveredItem' -Value 'New-DiscoveredItem' -Scope Script

# endregion

# ============================================================================
# region  Standalone Discovery (no WUG dependency)
# ============================================================================

function Invoke-Discovery {
    <#
    .SYNOPSIS
        Runs discovery providers against specified hosts. No WUG required.
    .DESCRIPTION
        Standalone discovery that works anywhere PowerShell 5.1 runs.
        Provide target hosts directly   no WUG device database needed.

        Returns a plan of discovered items that you can:
          - Pipe to Format-Table for quick review
          - Pipe to Export-DiscoveryPlan for JSON/CSV output
          - Pipe to Invoke-WUGDiscoverySync if WUG is available
          - Process in any custom script or feed to another NMS

    .PARAMETER ProviderName
        Which provider to run (e.g., 'F5', 'Fortinet').
    .PARAMETER Target
        Hostname(s) or IP address(es) to discover. Required.
    .PARAMETER DeviceName
        Friendly name(s) for each target. If omitted, uses the target value.
        Must be same count as -Target if specified.
    .PARAMETER ApiPort
        API port. Default: from provider registration.
    .PARAMETER ApiProtocol
        API protocol. Default: from provider registration.
    .PARAMETER AttributeValue
        Value passed to the provider's context as AttributeValue.
        For Fortinet, this is the API token. For others, 'true'.
    .PARAMETER IgnoreCertErrors
        Override provider's IgnoreCertErrors setting.
    .EXAMPLE
        # Discover F5 load balancers   no WUG needed
        . .\DiscoveryHelpers.ps1
        . .\DiscoveryProvider-F5.ps1
        $plan = Invoke-Discovery -ProviderName 'F5' -Target 'lb1.corp.local','lb2.corp.local'
        $plan | Format-Table Name, ItemType, MonitorType

    .EXAMPLE
        # Discover FortiGate with API token (via credential hashtable)
        $plan = Invoke-Discovery -ProviderName 'Fortinet' `
            -Target '192.168.1.1' `
            -Credential @{ ApiToken = 'your-api-token-here' }
        $plan | Export-DiscoveryPlan -Format JSON -Path '.\fortinet-plan.json'

    .EXAMPLE
        # Discover and review interactively
        Invoke-Discovery -ProviderName 'F5' -Target '10.0.0.5' |
            Out-GridView -Title 'F5 Discovery Results'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProviderName,

        [Parameter(Mandatory = $true)]
        [string[]]$Target,

        [Parameter()]
        [string[]]$DeviceName,

        [Parameter()]
        [int]$ApiPort,

        [Parameter()]
        [string]$ApiProtocol,

        [Parameter()]
        [string]$AttributeValue = '',

        [Parameter()]
        [hashtable]$Credential,

        [Parameter()]
        [hashtable]$Options,

        [Parameter()]
        [bool]$IgnoreCertErrors
    )

    $provider = Get-DiscoveryProvider -Name $ProviderName
    if (-not $provider) {
        Write-Error "Provider '$ProviderName' is not registered. Load the provider script first."
        return @()
    }

    $proto = if ($ApiProtocol) { $ApiProtocol } else { $provider.DefaultProtocol }
    $port = if ($ApiPort) { $ApiPort } else { $provider.DefaultPort }
    $certErrors = if ($PSBoundParameters.ContainsKey('IgnoreCertErrors')) { $IgnoreCertErrors } else { $provider.IgnoreCertErrors }

    $allItems = @()

    for ($i = 0; $i -lt $Target.Count; $i++) {
        $host_target = $Target[$i]
        $name = if ($DeviceName -and $i -lt $DeviceName.Count) { $DeviceName[$i] } else { $host_target }

        Write-Verbose "Discovering '$name' ($host_target)..."

        $baseUri = "${proto}://${host_target}:${port}"

        $ctx = @{
            DeviceId         = $i + 1     # Sequential ID for standalone
            DeviceName       = $name
            DeviceIP         = $host_target
            BaseUri          = $baseUri
            Port             = $port
            Protocol         = $proto
            ProviderName     = $provider.Name
            AttributeValue   = $AttributeValue
            Credential       = $Credential
            ExistingMonitors = @()
            IgnoreCertErrors = $certErrors
            Options          = $Options
        }

        try {
            $items = & $provider.DiscoverScript $ctx
            if ($items) {
                foreach ($item in @($items)) {
                    $item | Add-Member -NotePropertyName 'DeviceName' -NotePropertyValue $name -Force
                    $item | Add-Member -NotePropertyName 'DeviceIP' -NotePropertyValue $host_target -Force
                    $item | Add-Member -NotePropertyName 'ProviderName' -NotePropertyValue $provider.Name -Force
                    $allItems += $item
                }
            }
            Write-Verbose "Found $(@($items).Count) items on '$name'"
        }
        catch {
            Write-Warning "Discovery failed for '$name' ($host_target): $_"
        }
    }

    Write-Verbose "Total discovered items: $($allItems.Count)"
    return $allItems
}

function Export-DiscoveryPlan {
    <#
    .SYNOPSIS
        Exports a discovery plan to JSON, CSV, or formatted console output.
    .DESCRIPTION
        Takes the output of Invoke-Discovery and writes it in the
        requested format. Useful for feeding into other tools, archiving
        results, or generating reports.

        No WUG dependency   works anywhere.
    .PARAMETER Plan
        Discovery plan objects from Invoke-Discovery.
    .PARAMETER Format
        Output format: 'JSON', 'CSV', 'Table', 'Object'. Default: 'Table'.
    .PARAMETER Path
        File path for JSON/CSV output. If omitted, writes to the pipeline.
    .PARAMETER IncludeParams
        Include the full MonitorParams hashtable in output. Default: $false.
        Useful for debugging but makes the output verbose.
    .EXAMPLE
        $plan | Export-DiscoveryPlan -Format JSON -Path '.\plan.json'
    .EXAMPLE
        $plan | Export-DiscoveryPlan -Format CSV -Path '.\plan.csv'
    .EXAMPLE
        $plan | Export-DiscoveryPlan -Format Table
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PSCustomObject[]]$Plan,

        [Parameter()]
        [ValidateSet('JSON', 'CSV', 'Table', 'Object')]
        [string]$Format = 'Table',

        [Parameter()]
        [string]$Path,

        [Parameter()]
        [switch]$IncludeParams
    )

    begin {
        $items = [System.Collections.ArrayList]@()
        $diskUtilizationWmiConfigured = $false
    }

    process {
        foreach ($item in $Plan) {
            [void]$items.Add($item)
        }
    }

    end {
        # Patterns that indicate secrets in MonitorParams values
        $secretKeys = @('RestApiCustomHeader', 'RestApiPassword', 'Password',
                        'ApiToken', 'Secret', 'Bearer', 'Authorization')

        # Build flat output objects
        $output = foreach ($item in $items) {
            $obj = [ordered]@{
                DeviceName  = $item.DeviceName
                DeviceIP    = $item.DeviceIP
                Provider    = $item.ProviderName
                Name        = $item.Name
                ItemType    = $item.ItemType
                MonitorType = $item.MonitorType
                UniqueKey   = $item.UniqueKey
                Tags        = ($item.Tags -join ', ')
            }
            if ($IncludeParams -and $item.MonitorParams) {
                # Scrub secrets before exporting
                $safeParams = @{}
                foreach ($key in $item.MonitorParams.Keys) {
                    $val = $item.MonitorParams[$key]
                    $isSensitive = $false
                    foreach ($sk in $secretKeys) {
                        if ($key -like "*$sk*") { $isSensitive = $true; break }
                    }
                    if ($isSensitive -and $val) {
                        $safeParams[$key] = '*** REDACTED ***'
                    }
                    else {
                        $safeParams[$key] = $val
                    }
                }
                $obj['MonitorParams'] = ($safeParams | ConvertTo-Json -Compress)
            }
            [PSCustomObject]$obj
        }

        switch ($Format) {
            'JSON' {
                $json = $output | ConvertTo-Json -Depth 5
                if ($Path) {
                    $Utf8Bom = New-Object System.Text.UTF8Encoding($true)
                    [System.IO.File]::WriteAllText($Path, $json, $Utf8Bom)
                    Write-Verbose "Exported $($output.Count) items to '$Path' (JSON)"
                }
                else {
                    $json
                }
            }
            'CSV' {
                if ($Path) {
                    $output | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
                    Write-Verbose "Exported $($output.Count) items to '$Path' (CSV)"
                }
                else {
                    $output | ConvertTo-Csv -NoTypeInformation
                }
            }
            'Table' {
                $output | Format-Table -AutoSize
            }
            'Object' {
                $output
            }
        }
    }
}

# endregion

# ============================================================================
# region  DPAPI Credential Vault (Standalone   Windows only, no WUG dependency)
# ============================================================================

# Vault scope: 'CurrentUser' (default) or 'LocalMachine' (any admin/SYSTEM can decrypt).
# Reads $env:WUG_VAULT_SCOPE so re-dot-sourcing this file does not reset a scope
# that was already established by the caller or the task wrapper.
if ($env:WUG_VAULT_SCOPE -eq 'LocalMachine') {
    $script:VaultDpapiScope    = 'LocalMachine'
    $script:DiscoveryVaultPath = Join-Path $env:ProgramData 'WhatsUpGoldPS\Vault'
}
else {
    $script:VaultDpapiScope    = 'CurrentUser'
    $script:DiscoveryVaultPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Vault'
}

# Optional AES vault password (set via Set-DiscoveryVaultPassword)
$script:VaultAESKey = $null

# DPAPI scope is already set above based on WUG_VAULT_SCOPE env var.
# The Set-DiscoveryVaultScope function can be used to change it at runtime.

# Required for ProtectedData (LocalMachine DPAPI scope) -- no-op if already loaded.
Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue

# ============================================================================
# Internal vault encrypt/decrypt -- respects $script:VaultDpapiScope.
# All Save-DiscoveryCredential and Get-DiscoveryCredential calls route through
# these so scope changes affect the entire vault uniformly.
# ============================================================================
function Invoke-VaultEncrypt {
    <#
        Internal. Encrypts a SecureString for vault storage.
        CurrentUser  -- ConvertFrom-SecureString (DPAPI CurrentUser, existing behaviour).
        LocalMachine -- ProtectedData::Protect with LocalMachine scope; stored as 'LM:<base64>'.
    #>
    param([Parameter(Mandatory)][System.Security.SecureString]$SecureString)

    if ($script:VaultDpapiScope -eq 'LocalMachine') {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
        try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($plain)
        $plain = $null
        try {
            $protected = [System.Security.Cryptography.ProtectedData]::Protect(
                $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        }
        finally {
            for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = 0 }
        }
        return 'LM:' + [Convert]::ToBase64String($protected)
    }
    else {
        return ConvertFrom-SecureString -SecureString $SecureString
    }
}

function Invoke-VaultDecrypt {
    <#
        Internal. Decrypts a vault-stored encrypted string back to a SecureString.
        Detects scope automatically from the 'LM:' prefix -- no caller change needed
        when reading vaults created under either scope.
    #>
    param([Parameter(Mandatory)][string]$EncryptedString)

    if ($EncryptedString.StartsWith('LM:')) {
        $protected = [Convert]::FromBase64String($EncryptedString.Substring(3))
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protected, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        $plain = [System.Text.Encoding]::Unicode.GetString($bytes)
        for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = 0 }
        return ConvertTo-SecureString -String $plain -AsPlainText -Force
    }
    else {
        return ConvertTo-SecureString -String $EncryptedString
    }
}

function Set-DiscoveryVaultPath {
    <#
    .SYNOPSIS
        Changes the DPAPI credential vault directory.
    .DESCRIPTION
        By default the vault lives at %LOCALAPPDATA%\WhatsUpGoldPS\DiscoveryHelpers\Vault.
        Call this before Save/Get/Remove-DiscoveryCredential to use a
        different directory (e.g., a shared secure location).
    .PARAMETER Path
        Absolute path to the vault directory.
    .EXAMPLE
        Set-DiscoveryVaultPath -Path 'D:\SecureVault\Discovery'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $script:DiscoveryVaultPath = $Path
    Write-Verbose "Discovery vault path set to '$Path'"
}

function Set-DiscoveryVaultScope {
    <#
    .SYNOPSIS
        Switches the vault between CurrentUser and LocalMachine DPAPI scope.
    .DESCRIPTION
        CurrentUser  (default): credentials encrypted to the specific Windows user
          account + machine. Only that user on that machine can decrypt them.
          Vault path: %LOCALAPPDATA%\WhatsUpGoldPS\DiscoveryHelpers\Vault

        LocalMachine: credentials encrypted to the machine key. Any admin-level
          process or SYSTEM on this machine can decrypt them -- including scheduled
          tasks running as SYSTEM or a different service account.
          Vault path: %ProgramData%\WhatsUpGoldPS\Vault

        IMPORTANT: existing credentials saved under CurrentUser cannot be read
        after switching to LocalMachine (different key). Re-run the interactive
        setup (Setup-*-Discovery.ps1) after switching to repopulate the vault.

        Call this BEFORE Save-DiscoveryCredential or Resolve-DiscoveryCredential.
    .PARAMETER Scope
        'CurrentUser' or 'LocalMachine'.
    .EXAMPLE
        # Allow scheduled tasks running as SYSTEM to read vault credentials
        Set-DiscoveryVaultScope -Scope LocalMachine
        .\Setup-CUCM-Discovery.ps1 -Target 192.168.75.33 -Action None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CurrentUser', 'LocalMachine')]
        [string]$Scope
    )

    $script:VaultDpapiScope = $Scope

    if ($Scope -eq 'LocalMachine') {
        $script:DiscoveryVaultPath = Join-Path $env:ProgramData 'WhatsUpGoldPS\Vault'
        $env:WUG_VAULT_SCOPE       = 'LocalMachine'
        Write-Host "Vault scope: LocalMachine  Path: $($script:DiscoveryVaultPath)" -ForegroundColor Cyan
        Write-Warning "LocalMachine scope -- any administrator or SYSTEM process on this machine can decrypt these credentials."
    }
    else {
        $script:DiscoveryVaultPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Vault'
        $env:WUG_VAULT_SCOPE       = 'CurrentUser'
        Write-Verbose "Vault scope: CurrentUser  Path: $($script:DiscoveryVaultPath)"
    }
}

function Set-DiscoveryVaultPassword {
    <#
    .SYNOPSIS
        Sets a vault password for AES-256 encryption on top of DPAPI.
    .DESCRIPTION
        When set, ALL vault operations apply an additional AES-256 layer
        on top of DPAPI. This provides defense-in-depth:

          Layer 1: AES-256 with password-derived key (PBKDF2, 600k iterations)
          Layer 2: DPAPI (tied to Windows user + machine)

        Even if an attacker compromises the user session (DPAPI alone
        would be vulnerable), they still cannot decrypt without the vault
        password.

        Call this once per session before any Save/Get operations.
        The password is held in memory as a SecureString.

    .PARAMETER Password
        The vault password as a SecureString.
    .EXAMPLE
        $vp = Read-Host -AsSecureString -Prompt 'Vault password'
        Set-DiscoveryVaultPassword -Password $vp
    .EXAMPLE
        # Or let it prompt you:
        Set-DiscoveryVaultPassword
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [System.Security.SecureString]$Password
    )

    if (-not $Password) {
        $Password = Read-Host -AsSecureString -Prompt 'Enter vault password'
    }

    # Derive AES key from password using PBKDF2 (600,000 iterations per OWASP 2023+ guidance)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        # Salt: deterministic component (machine+user) + random component (persisted)
        # The random component prevents precomputation attacks against known machine/user combos
        $saltFile = Join-Path $script:DiscoveryVaultPath '.vault-salt.bin'
        if (Test-Path $saltFile) {
            $randomSalt = [System.IO.File]::ReadAllBytes($saltFile)
        }
        else {
            Initialize-DiscoveryVault
            $randomSalt = New-Object byte[] 16
            $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
            $rng.GetBytes($randomSalt)
            $rng.Dispose()
            [System.IO.File]::WriteAllBytes($saltFile, $randomSalt)
            Write-Verbose "Generated random salt component for vault."
        }
        $deterministicPart = "$($env:COMPUTERNAME)|$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)|DiscoveryVault"
        $detBytes = [System.Text.Encoding]::UTF8.GetBytes($deterministicPart)
        $saltBytes = New-Object byte[] ($detBytes.Length + $randomSalt.Length)
        [System.Array]::Copy($detBytes, 0, $saltBytes, 0, $detBytes.Length)
        [System.Array]::Copy($randomSalt, 0, $saltBytes, $detBytes.Length, $randomSalt.Length)
        $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($plain, $saltBytes, 600000)
        $script:VaultAESKey = $deriveBytes.GetBytes(32)  # 256 bits
        $deriveBytes.Dispose()
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $plain = $null
    }

    Write-Verbose "Vault password set   AES-256 layer enabled for this session."
}

function Clear-DiscoveryVaultPassword {
    <#
    .SYNOPSIS
        Clears the in-memory vault password, disabling the AES layer.
    #>
    [CmdletBinding()]
    param()

    if ($script:VaultAESKey) {
        # Zero out the key bytes in memory
        for ($i = 0; $i -lt $script:VaultAESKey.Length; $i++) {
            $script:VaultAESKey[$i] = 0
        }
    }
    $script:VaultAESKey = $null
    Write-Verbose "Vault password cleared."
}

function Initialize-DiscoveryVault {
    <#
    .SYNOPSIS
        Creates the vault directory with restricted ACLs if it does not exist.
    #>
    [CmdletBinding()]
    param()

    if (Test-Path -Path $script:DiscoveryVaultPath) { return }

    $newDir = New-Item -Path $script:DiscoveryVaultPath -ItemType Directory -Force

    # Lock down: current user + SYSTEM + Administrators only
    try {
        $acl = $newDir.GetAccessControl()
        $acl.SetAccessRuleProtection($true, $false)  # disable inheritance, remove inherited

        $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'NT AUTHORITY\SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'BUILTIN\Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $userRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')

        $acl.AddAccessRule($systemRule)
        $acl.AddAccessRule($adminRule)
        $acl.AddAccessRule($userRule)
        $newDir.SetAccessControl($acl)
        Write-Verbose "Vault directory created and secured: $($script:DiscoveryVaultPath)"
    }
    catch {
        Write-Warning "Could not restrict ACLs on vault directory: $_. Verify permissions manually."
    }
}

function Get-VaultHmacKey {
    <#
    .SYNOPSIS
        Returns a 32-byte HMAC key for vault integrity, creating it on first use.
    .DESCRIPTION
        Internal function. The HMAC key is a random 32-byte secret protected with
        DPAPI and stored in .vault-hmac.key in the vault directory. Only the same
        Windows user on the same machine can decrypt it, making integrity hashes
        unforgeable by anyone else.
    #>
    [CmdletBinding()]
    param()

    Initialize-DiscoveryVault
    $keyFile = Join-Path $script:DiscoveryVaultPath '.vault-hmac.key'

    if (Test-Path $keyFile) {
        try {
            $encrypted = [System.IO.File]::ReadAllText($keyFile).Trim()
            $ss = Invoke-VaultDecrypt -EncryptedString $encrypted
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
            try {
                $b64 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                return [Convert]::FromBase64String($b64)
            }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        catch {
            Write-Verbose "Could not read HMAC key, regenerating: $_"
        }
    }

    # Generate new random 32-byte key
    $keyBytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
    $rng.GetBytes($keyBytes)
    $rng.Dispose()

    # DPAPI-protect and save
    $b64 = [Convert]::ToBase64String($keyBytes)
    $ss = ConvertTo-SecureString $b64 -AsPlainText -Force
    $encrypted = Invoke-VaultEncrypt -SecureString $ss
    $Utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($keyFile, $encrypted, $Utf8Bom)
    $b64 = $null
    Write-Verbose "HMAC key generated and saved to vault."
    return $keyBytes
}

function Get-VaultHmac {
    <#
    .SYNOPSIS
        Computes HMAC-SHA256 over the given data using the vault HMAC key.
    .DESCRIPTION
        Internal function. Returns a hex-encoded HMAC-SHA256 string.
        Used for tamper-proof integrity verification on credential files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Data
    )
    $keyBytes = Get-VaultHmacKey
    if (-not $keyBytes) {
        Write-Warning "Could not obtain HMAC key; falling back to unsigned hash."
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Data))
        $sha.Dispose()
        return [BitConverter]::ToString($hashBytes) -replace '-', ''
    }
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyBytes
    $hashBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Data))
    $hmac.Dispose()
    # Zero the local copy of the key
    for ($i = 0; $i -lt $keyBytes.Length; $i++) { $keyBytes[$i] = 0 }
    return [BitConverter]::ToString($hashBytes) -replace '-', ''
}

function Write-VaultAuditLog {
    <#
    .SYNOPSIS
        Appends an entry to the vault audit log.
    .DESCRIPTION
        Internal function. Logs credential operations (save, read, delete)
        to a local audit file in the vault directory. Useful for compliance
        and investigating unauthorized access attempts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$CredentialName,

        [Parameter()]
        [string]$Detail = ''
    )

    Initialize-DiscoveryVault

    $logPath = Join-Path $script:DiscoveryVaultPath '.vault-audit.log'

    # Read last line's hash for chain integrity
    $prevHash = '0'
    try {
        if (Test-Path $logPath) {
            $lastLine = Get-Content $logPath -Tail 1 -ErrorAction SilentlyContinue
            if ($lastLine) {
                $lastObj = $lastLine | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($lastObj.Hash) { $prevHash = $lastObj.Hash }
            }
        }
    }
    catch { }

    $entry = [ordered]@{
        Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        Action    = $Action
        Name      = $CredentialName
        User      = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Machine   = $env:COMPUTERNAME
        PID       = $PID
        Detail    = $Detail
    }

    # Compute chain hash: SHA-256(prevHash | timestamp | action | name)
    $chainInput = "$prevHash|$($entry.Timestamp)|$($entry.Action)|$($entry.Name)"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $chainBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($chainInput))
    $sha.Dispose()
    $entry['Hash'] = [BitConverter]::ToString($chainBytes) -replace '-', ''

    $line = ($entry | ConvertTo-Json -Compress)
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::AppendAllText($logPath, "$line`n", $Utf8NoBom)
    }
    catch {
        Write-Verbose "Could not write audit log: $_"
    }
}

function Protect-VaultData {
    <#
    .SYNOPSIS
        Applies optional AES-256 encryption on top of DPAPI-encrypted data.
    .DESCRIPTION
        Internal function. If a vault password is set, encrypts the input
        string with AES-256-CBC using the PBKDF2-derived key. Otherwise
        returns the input unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Data
    )

    if (-not $script:VaultAESKey) { return $Data }

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.Key = $script:VaultAESKey
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.GenerateIV()  # random IV per encryption

    $encryptor = $aes.CreateEncryptor()
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Data)
    $cipherBytes = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)

    # Zero plaintext byte array before releasing
    for ($i = 0; $i -lt $plainBytes.Length; $i++) { $plainBytes[$i] = 0 }

    $encryptor.Dispose()

    # Prepend IV (16 bytes) to ciphertext so we can decrypt later
    $combined = New-Object byte[] ($aes.IV.Length + $cipherBytes.Length)
    [System.Array]::Copy($aes.IV, 0, $combined, 0, $aes.IV.Length)
    [System.Array]::Copy($cipherBytes, 0, $combined, $aes.IV.Length, $cipherBytes.Length)

    $aes.Dispose()

    # Return as Base64 with a prefix so we know it's AES-wrapped
    return "AES256:" + [Convert]::ToBase64String($combined)
}

function Unprotect-VaultData {
    <#
    .SYNOPSIS
        Removes the AES-256 layer if present, returning the DPAPI-encrypted data.
    .DESCRIPTION
        Internal function. If the data has the AES256: prefix, decrypts with
        the vault password. If no prefix, returns unchanged (DPAPI-only).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Data
    )

    if (-not $Data.StartsWith('AES256:')) { return $Data }

    if (-not $script:VaultAESKey) {
        throw "This credential is protected with a vault password. Run Set-DiscoveryVaultPassword first."
    }

    $combined = [Convert]::FromBase64String($Data.Substring(7))

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.Key = $script:VaultAESKey
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

    # Extract IV (first 16 bytes) and ciphertext
    $iv = New-Object byte[] 16
    $cipherBytes = New-Object byte[] ($combined.Length - 16)
    [System.Array]::Copy($combined, 0, $iv, 0, 16)
    [System.Array]::Copy($combined, 16, $cipherBytes, 0, $cipherBytes.Length)
    $aes.IV = $iv

    $decryptor = $aes.CreateDecryptor()
    $plainBytes = $decryptor.TransformFinalBlock($cipherBytes, 0, $cipherBytes.Length)
    $decryptor.Dispose()
    $aes.Dispose()

    $result = [System.Text.Encoding]::UTF8.GetString($plainBytes)
    # Zero decrypted byte array before releasing
    for ($i = 0; $i -lt $plainBytes.Length; $i++) { $plainBytes[$i] = 0 }

    return $result
}

function Save-DiscoveryCredential {
    <#
    .SYNOPSIS
        Encrypts a credential (single secret or multi-field bundle) and saves
        it to the DPAPI vault with optional AES-256 double encryption.
    .DESCRIPTION
        Supports two credential types:

        SINGLE SECRET (default   backward compatible):
          A single API token, password, or other secret string.
          Use -Secret or -SecureSecret.

        MULTI-FIELD BUNDLE (-Fields):
          Multiple named fields, each individually encrypted.
          Ideal for Azure (TenantId, ClientId, ClientSecret), OAuth2
          flows, database connections, etc.
          Use -Fields with a hashtable of name=SecureString pairs,
          or use Request-DiscoveryCredential which prompts for each field.

        Encryption layers applied:
          1. DPAPI (CurrentUser scope)   tied to Windows user + machine
          2. AES-256 (optional)   if Set-DiscoveryVaultPassword was called

        Optional:
          -ExpiresInDays : Set an expiration date. Get-DiscoveryCredential
                           will warn when credentials are expiring soon
                           and refuse to return expired ones.

    .PARAMETER Name
        Friendly name for this credential (e.g., 'Azure-Prod', 'FortiGate-FW1').
    .PARAMETER Secret
        A single plaintext secret to encrypt. WARNING: appears in command history.
    .PARAMETER SecureSecret
        A single SecureString secret to encrypt (recommended over -Secret).
    .PARAMETER Fields
        A hashtable of field-name = SecureString pairs for multi-field credentials.
        Each value is individually DPAPI-encrypted.
        Example: @{ TenantId = $ssTenant; ClientId = $ssClient; ClientSecret = $ssSecret }
    .PARAMETER Description
        Optional description stored alongside (not encrypted).
    .PARAMETER ExpiresInDays
        Optional. Number of days until this credential expires.
        Get-DiscoveryCredential warns at 14 days, refuses at 0.
    .PARAMETER Force
        Overwrite an existing credential with the same name.
    .EXAMPLE
        # Single secret (API token)
        $tok = Read-Host -AsSecureString -Prompt 'API token'
        Save-DiscoveryCredential -Name 'FortiGate-FW1' -SecureSecret $tok
    .EXAMPLE
        # Multi-field (Azure service principal)
        $tenant = Read-Host -AsSecureString -Prompt 'Tenant ID'
        $clientId = Read-Host -AsSecureString -Prompt 'Client ID'
        $clientSecret = Read-Host -AsSecureString -Prompt 'Client Secret'
        Save-DiscoveryCredential -Name 'Azure-Prod' -Fields @{
            TenantId     = $tenant
            ClientId     = $clientId
            ClientSecret = $clientSecret
        } -ExpiresInDays 365
    .EXAMPLE
        # Easiest: use Request-DiscoveryCredential for interactive setup
        Request-DiscoveryCredential -Name 'Azure-Prod' -Fields 'TenantId','ClientId','ClientSecret'
    .NOTES
        SECURITY: DPAPI CurrentUser scope   decryptable only by the same
        Windows user on the same machine. If the user profile is destroyed
        or the machine is rebuilt, the secrets are unrecoverable.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[\w\-\.]+$')]
        [string]$Name,

        [Parameter(Mandatory = $true, ParameterSetName = 'PlainText')]
        [string]$Secret,

        [Parameter(Mandatory = $true, ParameterSetName = 'SecureString')]
        [System.Security.SecureString]$SecureSecret,

        [Parameter(Mandatory = $true, ParameterSetName = 'Bundle')]
        [hashtable]$Fields,

        [Parameter()]
        [string]$Description = '',

        [Parameter()]
        [int]$ExpiresInDays,

        [Parameter()]
        [switch]$Force
    )

    # SECURITY WARNING: plaintext parameter leaks to PSReadLine history and transcripts
    if ($PSCmdlet.ParameterSetName -eq 'PlainText') {
        Write-Warning @"
SECURITY: You passed the secret as plaintext via -Secret.
  - It may appear in your PowerShell command history (~\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt)
  - It may appear in any active transcript (Start-Transcript)
  - It may appear in script block logging (Event Viewer)
Consider using the safer approach:
  `$ss = Read-Host -AsSecureString -Prompt 'Secret'
  Save-DiscoveryCredential -Name '$Name' -SecureSecret `$ss
Or use: Request-DiscoveryCredential -Name '$Name'
"@
    }

    Initialize-DiscoveryVault

    $filePath = Join-Path $script:DiscoveryVaultPath "$Name.cred"

    if ((Test-Path $filePath) -and -not $Force) {
        Write-Error "Credential '$Name' already exists. Use -Force to overwrite."
        return
    }

    # Build encrypted payload(s)
    $credType = 'Single'
    $encryptedData = $null
    $encryptedFields = $null

    if ($PSCmdlet.ParameterSetName -eq 'Bundle') {
        # Multi-field: encrypt each field individually
        $credType = 'Bundle'
        $encryptedFields = [ordered]@{}
        foreach ($fieldName in $Fields.Keys) {
            $fieldSS = $Fields[$fieldName]
            if ($fieldSS -isnot [System.Security.SecureString]) {
                Write-Error "Field '$fieldName' must be a SecureString. Use Read-Host -AsSecureString or Request-DiscoveryCredential."
                return
            }
            $fieldEncrypted = Invoke-VaultEncrypt -SecureString $fieldSS
            $encryptedFields[$fieldName] = Protect-VaultData -Data $fieldEncrypted
        }
    }
    else {
        # Single secret
        if ($PSCmdlet.ParameterSetName -eq 'PlainText') {
            $ss = New-Object System.Security.SecureString
            foreach ($char in $Secret.ToCharArray()) {
                $ss.AppendChar($char)
            }
            $ss.MakeReadOnly()
        }
        else {
            $ss = $SecureSecret
        }
        $dpapi = Invoke-VaultEncrypt -SecureString $ss
        $encryptedData = Protect-VaultData -Data $dpapi
    }

    # Calculate expiry
    $expiresUtc = $null
    if ($PSBoundParameters.ContainsKey('ExpiresInDays') -and $ExpiresInDays -gt 0) {
        $expiresUtc = (Get-Date).ToUniversalTime().AddDays($ExpiresInDays).ToString('o')
    }

    # Compute HMAC-SHA256 integrity over all encrypted material (keyed, unforgeable)
    $integritySource = if ($credType -eq 'Bundle') {
        ($encryptedFields.Values | Sort-Object) -join '|'
    }
    else {
        $encryptedData
    }
    # For LocalMachine scope, don't include user identity in hash (credential is machine-scoped)
    if ($script:VaultDpapiScope -eq 'LocalMachine') {
        $integrityInput = "$integritySource|$($env:COMPUTERNAME)|LOCALMACHINE"
    }
    else {
        $integrityInput = "$integritySource|$($env:COMPUTERNAME)|$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    }
    $integrityHash = Get-VaultHmac -Data $integrityInput

    $credObject = [ordered]@{
        Name        = $Name
        Type        = $credType
        Description = $Description
        CreatedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        ExpiresUtc  = $expiresUtc
        Machine     = $env:COMPUTERNAME
        User        = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Integrity   = $integrityHash
    }

    if ($credType -eq 'Bundle') {
        $credObject['FieldNames'] = @($encryptedFields.Keys)
        $credObject['Fields'] = $encryptedFields
    }
    else {
        $credObject['Encrypted'] = $encryptedData
    }

    if ($PSCmdlet.ShouldProcess($Name, "Save $credType credential")) {
        $json = $credObject | ConvertTo-Json -Depth 5
        $Utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($filePath, $json, $Utf8Bom)
        Write-VaultAuditLog -Action 'Save' -CredentialName $Name -Detail "Type=$credType$(if($expiresUtc){"; Expires=$expiresUtc"})"
        Write-Verbose "Credential '$Name' ($credType) saved to vault"

        # Also save to the OTHER vault scope so scheduled tasks work regardless
        # of whether they run as SYSTEM (LocalMachine) or the current user (CurrentUser).
        $otherScope = if ($script:VaultDpapiScope -eq 'LocalMachine') { 'CurrentUser' } else { 'LocalMachine' }
        $otherVaultPath = if ($otherScope -eq 'LocalMachine') {
            Join-Path $env:ProgramData 'WhatsUpGoldPS\Vault'
        } else {
            Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Vault'
        }
        try {
            if (-not (Test-Path $otherVaultPath)) {
                New-Item -ItemType Directory -Path $otherVaultPath -Force | Out-Null
            }
            $otherFilePath = Join-Path $otherVaultPath "$Name.cred"
            # Re-encrypt for the other DPAPI scope
            $savedScope = $script:VaultDpapiScope
            $script:VaultDpapiScope = $otherScope
            $otherCredObject = [ordered]@{}
            foreach ($k in $credObject.Keys) { $otherCredObject[$k] = $credObject[$k] }
            if ($credType -eq 'Bundle') {
                $otherFields = [ordered]@{}
                foreach ($fieldName in $Fields.Keys) {
                    $fieldSS = $Fields[$fieldName]
                    $fieldEncrypted = Invoke-VaultEncrypt -SecureString $fieldSS
                    $otherFields[$fieldName] = Protect-VaultData -Data $fieldEncrypted
                }
                $otherCredObject['Fields'] = $otherFields
                $otherIntegritySource = ($otherFields.Values | Sort-Object) -join '|'
            }
            else {
                $otherDpapi = Invoke-VaultEncrypt -SecureString $ss
                $otherCredObject['Encrypted'] = Protect-VaultData -Data $otherDpapi
                $otherIntegritySource = $otherCredObject['Encrypted']
            }
            if ($otherScope -eq 'LocalMachine') {
                $otherIntegrityInput = "$otherIntegritySource|$($env:COMPUTERNAME)|LOCALMACHINE"
            } else {
                $otherIntegrityInput = "$otherIntegritySource|$($env:COMPUTERNAME)|$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
            }
            $otherCredObject['Integrity'] = Get-VaultHmac -Data $otherIntegrityInput
            $otherCredObject['User'] = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $otherJson = $otherCredObject | ConvertTo-Json -Depth 5
            [System.IO.File]::WriteAllText($otherFilePath, $otherJson, $Utf8Bom)
            $script:VaultDpapiScope = $savedScope
            Write-Verbose "Credential '$Name' also saved to $otherScope vault"
        }
        catch {
            $script:VaultDpapiScope = $savedScope
            Write-Verbose "Could not save to $otherScope vault: $_"
        }
    }

    [PSCustomObject]@{
        Name       = $Name
        Type       = $credType
        VaultPath  = $filePath
        ExpiresUtc = $expiresUtc
        CreatedUtc = $credObject.CreatedUtc
    }
}

function Get-DiscoveryCredential {
    <#
    .SYNOPSIS
        Retrieves and decrypts a credential from the DPAPI vault.
    .DESCRIPTION
        Reads a DPAPI-encrypted credential file and decrypts it back to
        plaintext. Only works for the same Windows user on the same machine
        that originally saved it.

        Supports both single secrets and multi-field bundles.

        For single secrets:
          Returns the decrypted string (or SecureString with -AsSecureString).

        For bundles (multi-field):
          Returns a hashtable of field-name = decrypted-value.
          Use -Field to retrieve a single field from a bundle.
          Use -AsSecureString to get SecureStrings instead of plaintext.

        Enforces expiry: warns at 14 days, errors at 0 days.
        Logs every access to the vault audit log.

    .PARAMETER Name
        The credential name (as used in Save-DiscoveryCredential).
        Omit to list all credentials (metadata only, no decryption).
    .PARAMETER Field
        For bundles: return only this specific field's value.
    .PARAMETER AsSecureString
        Return value(s) as SecureString instead of plaintext.
    .PARAMETER IgnoreExpiry
        Return the credential even if it has expired.
    .EXAMPLE
        # Single secret
        $token = Get-DiscoveryCredential -Name 'FortiGate-FW1'
    .EXAMPLE
        # Bundle   get all fields as a hashtable
        $azure = Get-DiscoveryCredential -Name 'Azure-Prod'
        $azure.TenantId
        $azure.ClientSecret
    .EXAMPLE
        # Bundle   get one field
        $secret = Get-DiscoveryCredential -Name 'Azure-Prod' -Field 'ClientSecret'
    .EXAMPLE
        # List all saved credentials
        Get-DiscoveryCredential
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        [Parameter()]
        [string]$Field,

        [Parameter()]
        [switch]$AsSecureString,

        [Parameter()]
        [switch]$IgnoreExpiry
    )

    if (-not (Test-Path $script:DiscoveryVaultPath)) {
        Write-Warning "No vault found at '$($script:DiscoveryVaultPath)'. Use Save-DiscoveryCredential first."
        return
    }

    # No name = list all credentials (metadata only, no decryption)
    if (-not $Name) {
        $files = Get-ChildItem -Path $script:DiscoveryVaultPath -Filter '*.cred' -File
        foreach ($file in $files) {
            $content = [System.IO.File]::ReadAllText($file.FullName)
            $obj = $content | ConvertFrom-Json
            $credType = if ($obj.Type) { $obj.Type } else { 'Single' }
            $fieldNames = if ($obj.FieldNames) { $obj.FieldNames -join ', ' } else { '' }
            $expiresIn = ''
            if ($obj.ExpiresUtc) {
                $days = ([DateTime]::Parse($obj.ExpiresUtc) - (Get-Date).ToUniversalTime()).Days
                if ($days -lt 0) { $expiresIn = 'EXPIRED' }
                elseif ($days -le 14) { $expiresIn = "$days days (WARNING)" }
                else { $expiresIn = "$days days" }
            }
            [PSCustomObject]@{
                Name        = $obj.Name
                Type        = $credType
                Fields      = $fieldNames
                Description = $obj.Description
                ExpiresIn   = $expiresIn
                CreatedUtc  = $obj.CreatedUtc
                Machine     = $obj.Machine
                User        = $obj.User
                VaultPath   = $file.FullName
            }
        }
        return
    }

    $filePath = Join-Path $script:DiscoveryVaultPath "$Name.cred"
    if (-not (Test-Path $filePath)) {
        Write-Error "Credential '$Name' not found in vault."
        return
    }

    $content = [System.IO.File]::ReadAllText($filePath)
    $obj = $content | ConvertFrom-Json
    $credType = if ($obj.Type) { $obj.Type } else { 'Single' }

    # Check expiry
    if ($obj.ExpiresUtc -and -not $IgnoreExpiry) {
        $expiresDate = [DateTime]::Parse($obj.ExpiresUtc)
        $daysLeft = ($expiresDate - (Get-Date).ToUniversalTime()).Days
        if ($daysLeft -lt 0) {
            Write-VaultAuditLog -Action 'ReadDenied' -CredentialName $Name -Detail "Expired $([Math]::Abs($daysLeft)) days ago"
            Write-Error "Credential '$Name' EXPIRED $([Math]::Abs($daysLeft)) days ago ($(($obj.ExpiresUtc))). Re-save with updated secret, or use -IgnoreExpiry to override."
            return
        }
        elseif ($daysLeft -le 14) {
            Write-Warning "Credential '$Name' expires in $daysLeft days ($($obj.ExpiresUtc)). Consider rotating."
        }
    }

    # Verify HMAC-SHA256 integrity
    if ($obj.Integrity) {
        $integritySource = if ($credType -eq 'Bundle') {
            $fieldValues = @()
            foreach ($fn in $obj.FieldNames) {
                $fieldValues += $obj.Fields.$fn
            }
            ($fieldValues | Sort-Object) -join '|'
        }
        else {
            if ($obj.Encrypted) { $obj.Encrypted } else { '' }
        }
        # Detect if credential uses LocalMachine DPAPI (encrypted values have LM: prefix)
        $isLocalMachineScope = $false
        if ($credType -eq 'Bundle' -and $obj.Fields) {
            $firstField = $obj.FieldNames | Select-Object -First 1
            if ($firstField -and $obj.Fields.$firstField -and $obj.Fields.$firstField.ToString().StartsWith('LM:')) {
                $isLocalMachineScope = $true
            }
        }
        elseif ($obj.Encrypted -and $obj.Encrypted.ToString().StartsWith('LM:')) {
            $isLocalMachineScope = $true
        }
        # Use consistent identity for integrity check (match what was used during save)
        if ($isLocalMachineScope) {
            $integrityInput = "$integritySource|$($env:COMPUTERNAME)|LOCALMACHINE"
        }
        else {
            $integrityInput = "$integritySource|$($env:COMPUTERNAME)|$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
        $expectedHash = Get-VaultHmac -Data $integrityInput
        if ($obj.Integrity -ne $expectedHash) {
            Write-VaultAuditLog -Action 'IntegrityFailed' -CredentialName $Name
            Write-Error "INTEGRITY CHECK FAILED for credential '$Name'. The vault file may have been tampered with or was saved before HMAC migration. Delete it with Remove-DiscoveryCredential and re-save."
            return
        }
        Write-Verbose "Integrity check passed for '$Name'"
    }

    Write-VaultAuditLog -Action 'Read' -CredentialName $Name -Detail "Type=$credType"

    # --- Decrypt based on type ---
    if ($credType -eq 'Bundle') {
        # Multi-field credential
        if ($Field) {
            # Return a single field
            if ($obj.FieldNames -notcontains $Field) {
                Write-Error "Field '$Field' not found in credential '$Name'. Available fields: $($obj.FieldNames -join ', ')"
                return
            }
            $rawEncrypted = $obj.Fields.$Field
            try {
                $dpapiData = Unprotect-VaultData -Data $rawEncrypted
                $fieldSS = Invoke-VaultDecrypt -EncryptedString $dpapiData
            }
            catch {
                Write-Error "Failed to decrypt field '$Field' from credential '$Name': $_"
                return
            }
            if ($AsSecureString) { return $fieldSS }
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($fieldSS)
            try { return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        else {
            # Return all fields as a hashtable
            $result = @{}
            foreach ($fn in $obj.FieldNames) {
                $rawEncrypted = $obj.Fields.$fn
                try {
                    $dpapiData = Unprotect-VaultData -Data $rawEncrypted
                    $fieldSS = Invoke-VaultDecrypt -EncryptedString $dpapiData
                }
                catch {
                    Write-Error "Failed to decrypt field '$fn' from credential '$Name': $_"
                    return
                }
                if ($AsSecureString) {
                    $result[$fn] = $fieldSS
                }
                else {
                    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($fieldSS)
                    try { $result[$fn] = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
                    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
                }
            }
            return $result
        }
    }
    else {
        # Single secret (backward compatible)
        try {
            $dpapiData = Unprotect-VaultData -Data $obj.Encrypted
            $ss = Invoke-VaultDecrypt -EncryptedString $dpapiData
        }
        catch {
            Write-Error "Failed to decrypt credential '$Name'. This credential can only be decrypted by $($obj.User) on $($obj.Machine). Error: $_"
            return
        }

        if ($AsSecureString) { return $ss }
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
}

function Request-DiscoveryCredential {
    <#
    .SYNOPSIS
        Interactively prompts for secret(s) and saves them to the DPAPI vault.
    .DESCRIPTION
        This is the RECOMMENDED way to store credentials. It:
          1. Prompts with Read-Host -AsSecureString (input is masked with ****)
          2. Asks for confirmation (enter each value again)
          3. Saves with DPAPI encryption + integrity hash + optional AES layer
          4. Verifies the save by reading it back

        Supports two modes:

        SINGLE SECRET (default):
          Prompts once for a single secret (API token, password, etc.)

        MULTI-FIELD BUNDLE (-Fields):
          Prompts for each field name in the list. Each field is individually
          encrypted. Perfect for Azure, OAuth2, database connections, etc.
          Example: -Fields 'TenantId','ClientId','ClientSecret'

        The secret(s) NEVER appear in plaintext in:
          - The console (masked input)
          - PowerShell command history (PSReadLine)
          - Transcript logs
          - Script block logging / Event Viewer
          - The script file itself

    .PARAMETER Name
        Friendly name for this credential (e.g., 'Azure-Prod').
    .PARAMETER Fields
        Array of field names for a multi-field bundle.
        Each field is prompted individually with masked input.
    .PARAMETER Prompt
        Custom prompt text (single-secret mode only).
    .PARAMETER Description
        Optional description stored with the credential.
    .PARAMETER ExpiresInDays
        Optional. Number of days until this credential expires.
    .PARAMETER Force
        Overwrite an existing credential with the same name.
    .EXAMPLE
        # Single secret   API token
        Request-DiscoveryCredential -Name 'FortiGate-FW1' -Description 'FW1 API token'
    .EXAMPLE
        # Multi-field   Azure service principal
        Request-DiscoveryCredential -Name 'Azure-Prod' `
            -Fields 'TenantId','ClientId','ClientSecret' `
            -ExpiresInDays 365 -Description 'Azure SP for monitoring'
    .EXAMPLE
        # Multi-field   Database connection
        Request-DiscoveryCredential -Name 'SQL-Prod' `
            -Fields 'Server','Database','Username','Password'
    .NOTES
        Requires an interactive console. Cannot run in unattended mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[\w\-\.]+$')]
        [string]$Name,

        [Parameter()]
        [string[]]$Fields,

        [Parameter()]
        [string]$Prompt,

        [Parameter()]
        [string]$Description = '',

        [Parameter()]
        [int]$ExpiresInDays,

        [Parameter()]
        [switch]$Force
    )

    # Check if already exists
    $filePath = Join-Path $script:DiscoveryVaultPath "$Name.cred"
    if ((Test-Path $filePath) -and -not $Force) {
        Write-Warning "Credential '$Name' already exists in the vault."
        $overwrite = Read-Host "Overwrite? (Y/N)"
        if ($overwrite -ne 'Y' -and $overwrite -ne 'y') {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return
        }
        $Force = [switch]$true
    }

    Write-Host ""
    Write-Host "All input is masked   secrets will NOT appear on screen." -ForegroundColor Cyan

    if ($Fields -and $Fields.Count -gt 0) {
        # === MULTI-FIELD BUNDLE MODE ===
        Write-Host "Setting up credential '$Name' with $($Fields.Count) fields: $($Fields -join ', ')" -ForegroundColor Cyan
        Write-Host ""

        $fieldSecureStrings = @{}

        foreach ($fieldName in $Fields) {
            # Prompt
            $ss1 = Read-Host -AsSecureString -Prompt "  $fieldName"

            # Validate non-empty
            $bstr1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss1)
            try { $len1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr1).Length }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1) }
            if ($len1 -eq 0) {
                Write-Error "'$fieldName' cannot be empty. Aborting."
                return
            }

            # Confirm
            $ss2 = Read-Host -AsSecureString -Prompt "  Confirm $fieldName"

            # Compare
            $bstr1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss1)
            $bstr2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss2)
            try {
                $p1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr1)
                $p2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr2)
                $match = ($p1 -ceq $p2)
            }
            finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)
                $p1 = $null
                $p2 = $null
            }

            if (-not $match) {
                Write-Error "'$fieldName' entries do not match. Nothing was saved."
                return
            }

            $fieldSecureStrings[$fieldName] = $ss1
        }

        # Save as bundle
        $saveParams = @{
            Name        = $Name
            Fields      = $fieldSecureStrings
            Description = $Description
            Force       = $Force
        }
        if ($PSBoundParameters.ContainsKey('ExpiresInDays')) {
            $saveParams['ExpiresInDays'] = $ExpiresInDays
        }
        $result = Save-DiscoveryCredential @saveParams

        # Verify by reading back
        $verify = Get-DiscoveryCredential -Name $Name -AsSecureString -ErrorAction SilentlyContinue
        if (-not $verify) {
            Write-Error "Verification failed   credential was saved but could not be read back."
            return
        }

        Write-Host ""
        Write-Host "Credential '$Name' saved and verified ($($Fields.Count) fields)." -ForegroundColor Green
        Write-Host "  Fields:  $($Fields -join ', ')" -ForegroundColor Gray
        Write-Host "  Vault:   $($result.VaultPath)" -ForegroundColor Gray
        Write-Host "  User:    $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -ForegroundColor Gray
        Write-Host "  Machine: $env:COMPUTERNAME" -ForegroundColor Gray
        if ($result.ExpiresUtc) {
            Write-Host "  Expires: $($result.ExpiresUtc)" -ForegroundColor Gray
        }
        Write-Host ""
        Write-Host "Retrieve with:  Get-DiscoveryCredential -Name '$Name'" -ForegroundColor Cyan
        Write-Host "Single field:   Get-DiscoveryCredential -Name '$Name' -Field 'ClientSecret'" -ForegroundColor Cyan

        return $result
    }

    # === SINGLE SECRET MODE ===
    if (-not $Prompt) { $Prompt = "Enter secret for '$Name'" }

    $ss1 = Read-Host -AsSecureString -Prompt $Prompt

    # Validate non-empty
    $bstr1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss1)
    try { $len1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr1).Length }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1) }
    if ($len1 -eq 0) {
        Write-Error "Secret cannot be empty."
        return
    }

    # Confirm (second entry)
    $ss2 = Read-Host -AsSecureString -Prompt "Confirm secret for '$Name'"

    # Compare
    $bstr1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss1)
    $bstr2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss2)
    try {
        $plain1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr1)
        $plain2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr2)
        $match = ($plain1 -ceq $plain2)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)
        $plain1 = $null
        $plain2 = $null
    }

    if (-not $match) {
        Write-Error "Secrets do not match. Nothing was saved."
        return
    }

    # Save
    $saveParams = @{
        Name         = $Name
        SecureSecret = $ss1
        Description  = $Description
        Force        = $Force
    }
    if ($PSBoundParameters.ContainsKey('ExpiresInDays')) {
        $saveParams['ExpiresInDays'] = $ExpiresInDays
    }
    $result = Save-DiscoveryCredential @saveParams

    # Verify by reading back
    $verify = Get-DiscoveryCredential -Name $Name -AsSecureString -ErrorAction SilentlyContinue
    if (-not $verify) {
        Write-Error "Verification failed   credential was saved but could not be read back."
        return
    }

    Write-Host ""
    Write-Host "Credential '$Name' saved and verified." -ForegroundColor Green
    Write-Host "  Vault:   $($result.VaultPath)" -ForegroundColor Gray
    Write-Host "  User:    $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -ForegroundColor Gray
    Write-Host "  Machine: $env:COMPUTERNAME" -ForegroundColor Gray
    if ($result.ExpiresUtc) {
        Write-Host "  Expires: $($result.ExpiresUtc)" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "Retrieve with:  Get-DiscoveryCredential -Name '$Name'" -ForegroundColor Cyan

    $result
}

function Resolve-DiscoveryCredential {
    <#
    .SYNOPSIS
        Smart credential resolver   loads from vault, shows preview, prompts
        if missing, saves new creds back to vault. One function for everything.
    .DESCRIPTION
        Replaces the 40+ line copy-paste pattern in every Setup script with a
        single call. Handles all credential types:

          AWSKeys      -- Access Key ID + Secret Access Key
          AzureSP      -- Tenant ID + Application ID + Client Secret
          BearerToken  -- Single API token (Proxmox, Fortinet, etc.)
          OCIConfig    -- OCI config file path + profile + tenancy OCID
          PSCredential -- Username + Password (F5, HyperV, VMware, etc.)
          WUGServer    -- WhatsUp Gold server connection info (host, port, protocol, creds)

        Flow:
          1. Check vault for existing credential   show safe preview
          2. Prompt: [Y]es use it / [R]eset / [N]o skip
          3. If missing or reset: prompt for new values per CredType
          4. Save to vault and return the credential
             (unless -DeferSave is set   caller validates first, then saves)

        Returns:
          PSCredential    for AWSKeys / AzureSP / PSCredential types
          String          for BearerToken type
          Hashtable       for WUGServer type (Server, Port, Protocol, Credential, IgnoreSSL)
          $null           if skipped, cancelled, or non-interactive with no vault entry

    .PARAMETER Name
        Vault credential name (e.g., 'AWS.Credential', 'Proxmox.192.168.1.30.Token').
    .PARAMETER CredType
        Credential type: 'AWSKeys', 'AzureSP', 'BearerToken', 'PSCredential'.
        If omitted, auto-detected from the Name pattern.
    .PARAMETER ProviderLabel
        Friendly label for prompts (e.g., 'AWS', 'Proxmox'). Defaults to Name.
    .PARAMETER DeferSave
        Don't save new credentials to vault. The caller should validate the
        credential works first, then call Save-ResolvedCredential to persist.
    .PARAMETER NonInteractive
        Skip prompts entirely   return vault data or $null.
    .PARAMETER AutoUse
        When $true, skip the Y/R/N prompt and auto-use existing vault creds.
        Still prompts if vault is empty. Default: $false.
    .EXAMPLE
        # AWS   prompts for Access Key + Secret if not in vault
        $cred = Resolve-DiscoveryCredential -Name 'AWS.Credential' -CredType AWSKeys
        # Returns PSCredential: UserName=AccessKey, Password=SecretKey

    .EXAMPLE
        # Azure   auto-discover vault name from existing entries
        $cred = Resolve-DiscoveryCredential -Name 'Azure' -CredType AzureSP
        # Returns PSCredential: UserName="TenantId|AppId", Password=ClientSecret

    .EXAMPLE
        # Proxmox   existing token from vault, auto-use
        $token = Resolve-DiscoveryCredential -Name 'Proxmox.192.168.1.30.Token' -AutoUse

    .EXAMPLE
        # WUG Server   all connection info from vault
        $wug = Resolve-DiscoveryCredential -Name 'WUG.Server' -CredType WUGServer
        # Returns hashtable: Server, Port, Protocol, Credential, IgnoreSSL

    .EXAMPLE
        # DeferSave   validate before persisting
        $cred = Resolve-DiscoveryCredential -Name 'WUG.Server' -CredType WUGServer -DeferSave
        if (Test-Connection $cred.Server) { Save-ResolvedCredential -Name 'WUG.Server' -Value $cred }

    .EXAMPLE
        # Non-interactive   return vault data or nothing
        $cred = Resolve-DiscoveryCredential -Name 'HyperV.host1.Credential' -NonInteractive
    .NOTES
        This is the single canonical way to get credentials across the
        entire discovery ecosystem (Setup scripts, Runner, Tests, Vault manager).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [ValidateSet('AWSKeys', 'AzureSP', 'BearerToken', 'FilePath', 'OCIConfig', 'PSCredential', 'SNMPv2', 'SNMPv3', 'WUGServer')]
        [string]$CredType,

        [Parameter()]
        [string]$ProviderLabel,

        [Parameter()]
        [switch]$DeferSave,

        [Parameter()]
        [switch]$NonInteractive,

        [Parameter()]
        [switch]$AutoUse
    )

    Initialize-DiscoveryVault

    if (-not $ProviderLabel) { $ProviderLabel = $Name }

    # --- Auto-detect CredType from name pattern if not specified -----------
    if (-not $CredType) {
        if ($Name -match '^AWS\.')                         { $CredType = 'AWSKeys' }
        elseif ($Name -match '^Azure\..*\.ServicePrincipal$' -or $Name -eq 'Azure') { $CredType = 'AzureSP' }
        elseif ($Name -match '^OCI\.')                     { $CredType = 'OCIConfig' }
        elseif ($Name -match '\.ServiceAccount$|\.KeyFile$') { $CredType = 'FilePath' }
        elseif ($Name -match '\.Token$|^FortiGate')        { $CredType = 'BearerToken' }
        elseif ($Name -match '^WUG\.Server')                { $CredType = 'WUGServer' }
        elseif ($Name -match '\.Snmp$|\.SNMP$' -and $Name -match 'v3|V3') { $CredType = 'SNMPv3' }
        elseif ($Name -match '\.Snmp$|\.SNMP$')            { $CredType = 'SNMPv2' }
        elseif ($Name -match '\.Credential$')              { $CredType = 'PSCredential' }
        else                                               { $CredType = 'PSCredential' }
        Write-Verbose "Auto-detected CredType '$CredType' from name '$Name'"
    }

    # --- Azure: auto-discover vault name if generic -----------------------
    $VaultName = $Name
    if ($CredType -eq 'AzureSP' -and $Name -eq 'Azure') {
        $vaultDir = $script:DiscoveryVaultPath
        if (Test-Path $vaultDir) {
            $azFiles = @(Get-ChildItem -Path $vaultDir -Filter 'Azure.*.ServicePrincipal.cred' -ErrorAction SilentlyContinue)
            if ($azFiles.Count -gt 0) {
                $VaultName = $azFiles[0].BaseName
                Write-Host "  Found Azure vault entry: $VaultName" -ForegroundColor DarkGray
            }
        }
    }

    # --- Check vault for existing credential ------------------------------
    $stored = Get-DiscoveryCredential -Name $VaultName -ErrorAction SilentlyContinue

    if ($stored) {
        # Build safe preview
        $preview = switch ($CredType) {
            'AWSKeys' {
                if ($stored -is [PSCredential]) { "AccessKey=$($stored.UserName)" }
                elseif ($stored -is [string] -and $stored -match '\|') {
                    "AccessKey=$(($stored -split '\|', 2)[0])"
                } else { '(stored)' }
            }
            'AzureSP' {
                if ($stored -is [PSCredential]) {
                    $p = $stored.UserName -split '\|', 2
                    "TenantId=$($p[0]), AppId=$($p[1])"
                } elseif ($stored -is [string] -and $stored -match '\|') {
                    $p = $stored -split '\|', 3
                    "TenantId=$($p[0]), AppId=$($p[1])"
                } else { '(stored)' }
            }
            'PSCredential' {
                if ($stored -is [PSCredential]) { "User=$($stored.UserName)" }
                elseif ($stored -is [string] -and $stored -match '\|') {
                    "User=$(($stored -split '\|', 2)[0])"
                } else { '(stored)' }
            }
            'BearerToken' {
                $t = "$stored"
                if ($t.Length -gt 12) { "Token=$($t.Substring(0,4))...$($t.Substring($t.Length - 4))" }
                elseif ($t.Length -gt 0) { 'Token=****' }
                else { '(stored)' }
            }
            'OCIConfig' {
                if ($stored -is [string] -and $stored -match '\|') {
                    $p = $stored -split '\|', 3
                    "ConfigFile=$($p[0]), Profile=$($p[1])"
                } else { '(stored)' }
            }
            'WUGServer' {
                if ($stored -is [string] -and $stored -match '\|') {
                    $wp = $stored -split '\|', 5
                    "Server=$($wp[0]):$($wp[1]) ($($wp[2])), User=$($wp[3])"
                } else { '(stored)' }
            }
            'FilePath' {
                "Path=$stored"
            }
            'SNMPv2' {
                if ($stored -is [hashtable] -and $stored.Community) { 'Community=****' }
                else { '(stored)' }
            }
            'SNMPv3' {
                if ($stored -is [hashtable] -and $stored.Username) {
                    "User=$($stored.Username), Auth=$($stored.AuthProtocol), Priv=$($stored.PrivacyProtocol)"
                } else { '(stored)' }
            }
            default { '(stored)' }
        }

        Write-Host "  Vault: $VaultName" -ForegroundColor DarkGray
        Write-Host "  Found: $preview" -ForegroundColor Green

        if ($NonInteractive -or $AutoUse) {
            Write-Host "  Using existing credential." -ForegroundColor Green
        }
        else {
            $choice = Read-Host -Prompt "  Use existing? [Y]es / [R]eset / [N]o skip"
            switch -Regex ($choice) {
                '^[Rr]' {
                    Write-Host "  Removing old credential..." -ForegroundColor Yellow
                    Remove-DiscoveryCredential -Name $VaultName -Confirm:$false -ErrorAction SilentlyContinue
                    $stored = $null
                }
                '^[Nn]' {
                    Write-Host "  Skipped." -ForegroundColor DarkGray
                    return $null
                }
                default {
                    Write-Host "  Using existing credential." -ForegroundColor Green
                }
            }
        }

        # Convert stored value to proper return type
        if ($stored) {
            return (ConvertFrom-VaultStored -Stored $stored -CredType $CredType)
        }
    }
    else {
        if ($NonInteractive) {
            Write-Host "  No credential in vault for '$VaultName'." -ForegroundColor DarkGray
            return $null
        }
        Write-Host "  No credential found in vault: $VaultName" -ForegroundColor Yellow
    }

    # --- Prompt for new credential ----------------------------------------
    switch ($CredType) {
        'AWSKeys' {
            Write-Host ''
            Write-Host "  Enter AWS IAM credentials:" -ForegroundColor Yellow
            $akInput = Read-Host -Prompt "    Access Key ID"
            if ([string]::IsNullOrWhiteSpace($akInput)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }
            $AccessKey = $akInput.Trim()

            $skSS = Read-Host -AsSecureString -Prompt "    Secret Access Key"
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($skSS)
            try { $plainSK = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            if ([string]::IsNullOrWhiteSpace($plainSK)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }

            if (-not $DeferSave) {
                $combined = "$AccessKey|$plainSK"
                $ss = ConvertTo-SecureString $combined -AsPlainText -Force
                Save-DiscoveryCredential -Name $VaultName -SecureSecret $ss `
                    -Description "AWS IAM ($AccessKey)" -Force | Out-Null
                Write-Host "  Saved to vault as '$VaultName'." -ForegroundColor Green
            } else {
                Write-Host "  Credential NOT saved (DeferSave). Validate, then call Save-ResolvedCredential." -ForegroundColor DarkYellow
            }

            $secKey = ConvertTo-SecureString $plainSK -AsPlainText -Force
            return [PSCredential]::new($AccessKey, $secKey)
        }
        'AzureSP' {
            Write-Host ''
            Write-Host "  Enter Azure Service Principal details:" -ForegroundColor Yellow
            # Auto-extract TenantId from vault name if pattern matches Azure.xxx.ServicePrincipal
            $tenantId = $null
            if ($VaultName -match '^Azure\.(.+)\.ServicePrincipal$') {
                $tenantId = $Matches[1]
                Write-Host "    Tenant ID: $tenantId (from vault name)" -ForegroundColor DarkGray
            }
            if (-not $tenantId) {
                $tenantId = Read-Host -Prompt "    Tenant ID"
            }
            $appId    = Read-Host -Prompt "    Application (Client) ID"
            $secretSS = Read-Host -AsSecureString -Prompt "    Client Secret"
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretSS)
            try { $plainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            if ([string]::IsNullOrWhiteSpace($tenantId) -or [string]::IsNullOrWhiteSpace($appId) -or [string]::IsNullOrWhiteSpace($plainSecret)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }

            $vn = "Azure.$tenantId.ServicePrincipal"
            if (-not $DeferSave) {
                $combined = "$tenantId|$appId|$plainSecret"
                $ss = ConvertTo-SecureString $combined -AsPlainText -Force
                Save-DiscoveryCredential -Name $vn -SecureSecret $ss `
                    -Description "Azure SP (Tenant=$tenantId, App=$appId)" -Force | Out-Null
                Write-Host "  Saved to vault as '$vn'." -ForegroundColor Green
            } else {
                Write-Host "  Credential NOT saved (DeferSave). Validate, then call Save-ResolvedCredential." -ForegroundColor DarkYellow
            }

            $combinedUser = "$tenantId|$appId"
            $secSecret = ConvertTo-SecureString $plainSecret -AsPlainText -Force
            return [PSCredential]::new($combinedUser, $secSecret)
        }
        'BearerToken' {
            Write-Host ''
            $provHint = ''
            if ($VaultName -match 'Proxmox')  { $provHint = ' (format: user@realm!tokenid=secret-uuid)' }
            if ($VaultName -match 'Forti')    { $provHint = ' (FortiGate REST API admin token)' }
            $ss = Read-Host -AsSecureString -Prompt "  API token for ${ProviderLabel}${provHint}"
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
            try { $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            if ([string]::IsNullOrWhiteSpace($token)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }
            if (-not $DeferSave) {
                Save-DiscoveryCredential -Name $VaultName -SecureSecret $ss `
                    -Description "$ProviderLabel API token" -Force | Out-Null
                Write-Host "  Saved to vault as '$VaultName'." -ForegroundColor Green
            } else {
                Write-Host "  Credential NOT saved (DeferSave). Validate, then call Save-ResolvedCredential." -ForegroundColor DarkYellow
            }
            return $token
        }
        'OCIConfig' {
            Write-Host ''
            Write-Host "  Enter OCI configuration details:" -ForegroundColor Yellow
            $defaultCfg = Join-Path $env:USERPROFILE '.oci\config'
            $cfgInput = Read-Host -Prompt "    Config file path [default: $defaultCfg]"
            $cfgPath = if ([string]::IsNullOrWhiteSpace($cfgInput)) { $defaultCfg } else { $cfgInput.Trim() }
            if (-not (Test-Path $cfgPath)) {
                Write-Warning "  Config file not found: $cfgPath"
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }
            $profInput = Read-Host -Prompt "    Profile [default: DEFAULT]"
            $ociProfile = if ([string]::IsNullOrWhiteSpace($profInput)) { 'DEFAULT' } else { $profInput.Trim() }

            # Try to extract tenancy from config file
            $defaultTenancy = $null
            try {
                $cfgContent = Get-Content $cfgPath -Raw
                if ($cfgContent -match 'tenancy\s*=\s*(ocid1\.tenancy\.[^\s]+)') {
                    $defaultTenancy = $Matches[1]
                }
            }
            catch { }
            $tenancyPrompt = if ($defaultTenancy) { "    Tenancy OCID [default: $defaultTenancy]" } else { '    Tenancy OCID' }
            $tenancyInput = Read-Host -Prompt $tenancyPrompt
            $ociTenancy = if ([string]::IsNullOrWhiteSpace($tenancyInput) -and $defaultTenancy) { $defaultTenancy } else { $tenancyInput.Trim() }
            if ([string]::IsNullOrWhiteSpace($ociTenancy)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }

            $result = @{
                ConfigFile = $cfgPath
                Profile    = $ociProfile
                TenancyId  = $ociTenancy
            }

            if (-not $DeferSave) {
                $combined = "$cfgPath|$ociProfile|$ociTenancy"
                $ss = ConvertTo-SecureString $combined -AsPlainText -Force
                Save-DiscoveryCredential -Name $VaultName -SecureSecret $ss `
                    -Description "OCI ($ociProfile @ $cfgPath)" -Force | Out-Null
                Write-Host "  Saved to vault as '$VaultName'." -ForegroundColor Green
            } else {
                Write-Host "  Credential NOT saved (DeferSave). Validate, then call Save-ResolvedCredential." -ForegroundColor DarkYellow
            }
            return $result
        }
        'PSCredential' {
            Write-Host ''
            $skipCheck = Read-Host -Prompt "  Enter credentials for ${ProviderLabel}? [Y/n]"
            if ($skipCheck -match '^[Nn]') {
                Write-Host '  Skipped.' -ForegroundColor DarkGray; return $null
            }
            Write-Host "  Enter ${ProviderLabel} credentials:" -ForegroundColor Yellow
            $userName = Read-Host -Prompt "    Username"
            if ([string]::IsNullOrWhiteSpace($userName)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }
            $passwordSS = Read-Host -AsSecureString -Prompt "    Password"
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($passwordSS)
            try { $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            if ([string]::IsNullOrWhiteSpace($plainPwd)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }
            $cred = [PSCredential]::new($userName, $passwordSS)
            if (-not $DeferSave) {
                $combined = "$userName|$plainPwd"
                $ss = ConvertTo-SecureString $combined -AsPlainText -Force
                Save-DiscoveryCredential -Name $VaultName -SecureSecret $ss `
                    -Description "$ProviderLabel ($userName)" -Force | Out-Null
                Write-Host "  Saved to vault as '$VaultName'." -ForegroundColor Green
            } else {
                Write-Host "  Credential NOT saved (DeferSave). Validate, then call Save-ResolvedCredential." -ForegroundColor DarkYellow
            }
            return $cred
        }
        'WUGServer' {
            Write-Host ''
            Write-Host "  WhatsUp Gold server connection:" -ForegroundColor Yellow
            $srv = Read-Host -Prompt "    Server hostname or IP"
            if ([string]::IsNullOrWhiteSpace($srv)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }
            $srv = $srv.Trim()
            $pInput = Read-Host -Prompt "    Port [9644]"
            $port = if ([string]::IsNullOrWhiteSpace($pInput)) { 9644 } else { [int]$pInput }
            $prInput = Read-Host -Prompt "    Protocol [https]"
            $proto = if ([string]::IsNullOrWhiteSpace($prInput)) { 'https' } else { $prInput.Trim() }
            Write-Host "  Enter WhatsUp Gold credentials for $srv`:" -ForegroundColor Yellow
            $wugUser = Read-Host -Prompt "    Username"
            if ([string]::IsNullOrWhiteSpace($wugUser)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }
            $wugPassSS = Read-Host -AsSecureString -Prompt "    Password"
            $bstrWug = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($wugPassSS)
            try { $plainWugPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstrWug) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrWug) }
            if ([string]::IsNullOrWhiteSpace($plainWugPwd)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }
            $cred = [PSCredential]::new($wugUser, $wugPassSS)
            $sslInput = Read-Host -Prompt "    Ignore SSL errors? [Y/n]"
            $ignoreSSL = -not ($sslInput -match '^[Nn]')

            $result = @{
                Server     = $srv
                Port       = $port
                Protocol   = $proto
                Credential = $cred
                IgnoreSSL  = $ignoreSSL
            }

            if (-not $DeferSave) {
                $combined = "$srv|$port|$proto|$wugUser|$plainWugPwd"
                $ss = ConvertTo-SecureString $combined -AsPlainText -Force
                Save-DiscoveryCredential -Name $VaultName -SecureSecret $ss `
                    -Description "WUG $proto`://$srv`:$port ($wugUser)" -Force | Out-Null
                Write-Host "  Saved to vault as '$VaultName'." -ForegroundColor Green
            } else {
                Write-Host "  Credential NOT saved (DeferSave). Validate, then call Save-ResolvedCredential." -ForegroundColor DarkYellow
            }
            return $result
        }
        'FilePath' {
            Write-Host ''
            $pathInput = Read-Host -Prompt "  Path to ${ProviderLabel} file"
            if ([string]::IsNullOrWhiteSpace($pathInput)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }
            $pathInput = $pathInput.Trim()
            if (-not (Test-Path $pathInput)) {
                Write-Warning "  File not found: $pathInput"
            }
            if (-not $DeferSave) {
                $ss = ConvertTo-SecureString $pathInput -AsPlainText -Force
                Save-DiscoveryCredential -Name $VaultName -SecureSecret $ss `
                    -Description "$ProviderLabel ($pathInput)" -Force | Out-Null
                Write-Host "  Saved to vault as '$VaultName'." -ForegroundColor Green
            } else {
                Write-Host "  Credential NOT saved (DeferSave). Validate, then call Save-ResolvedCredential." -ForegroundColor DarkYellow
            }
            return $pathInput
        }
        'SNMPv2' {
            Write-Host ''
            Write-Host "  SNMPv2 community string for ${ProviderLabel}:" -ForegroundColor Yellow
            $communitySS = Read-Host -AsSecureString -Prompt "    Community string"
            $bstrComm = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($communitySS)
            try { $plainCommunity = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstrComm) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrComm) }
            if ([string]::IsNullOrWhiteSpace($plainCommunity)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }
            $result = @{ Version = 2; Community = $plainCommunity }
            if (-not $DeferSave) {
                $fields = [ordered]@{ Community = (ConvertTo-SecureString $plainCommunity -AsPlainText -Force) }
                Save-DiscoveryCredential -Name $VaultName -Fields $fields `
                    -Description "$ProviderLabel SNMPv2" -Force | Out-Null
                Write-Host "  Saved to vault as '$VaultName'." -ForegroundColor Green
            } else {
                Write-Host "  Credential NOT saved (DeferSave). Validate, then call Save-ResolvedCredential." -ForegroundColor DarkYellow
            }
            return $result
        }
        'SNMPv3' {
            Write-Host ''
            Write-Host "  SNMPv3 credentials for ${ProviderLabel}:" -ForegroundColor Yellow
            $snmpUser = Read-Host -Prompt "    Username"
            if ([string]::IsNullOrWhiteSpace($snmpUser)) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }
            $snmpContext = Read-Host -Prompt "    Context (optional, press Enter to skip)"
            Write-Host "    Auth protocols: 0=None, 1=MD5, 2=SHA, 3=SHA256, 4=SHA384, 5=SHA512"
            $authProtoInput = Read-Host -Prompt "    Auth protocol [0]"
            $authProto = if ([string]::IsNullOrWhiteSpace($authProtoInput)) { 0 } else { [int]$authProtoInput }
            $plainAuthPwd = ''
            if ($authProto -gt 0) {
                $authPwdSS = Read-Host -AsSecureString -Prompt "    Auth password"
                $bstrAuth = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($authPwdSS)
                try { $plainAuthPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstrAuth) }
                finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrAuth) }
            }
            Write-Host "    Privacy protocols: 0=None, 1=DES, 2=AES128, 3=AES192, 4=AES256"
            $privProtoInput = Read-Host -Prompt "    Privacy protocol [0]"
            $privProto = if ([string]::IsNullOrWhiteSpace($privProtoInput)) { 0 } else { [int]$privProtoInput }
            $plainPrivPwd = ''
            if ($privProto -gt 0) {
                $privPwdSS = Read-Host -AsSecureString -Prompt "    Privacy password"
                $bstrPriv = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($privPwdSS)
                try { $plainPrivPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstrPriv) }
                finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrPriv) }
            }
            $result = @{
                Version         = 3
                Username        = $snmpUser
                Context         = $snmpContext
                AuthProtocol    = $authProto
                AuthPassword    = $plainAuthPwd
                PrivacyProtocol = $privProto
                PrivacyPassword = $plainPrivPwd
            }
            if (-not $DeferSave) {
                $fields = [ordered]@{
                    Username        = (ConvertTo-SecureString $snmpUser -AsPlainText -Force)
                    Context         = (ConvertTo-SecureString $snmpContext -AsPlainText -Force)
                    AuthProtocol    = (ConvertTo-SecureString ([string]$authProto) -AsPlainText -Force)
                    AuthPassword    = (ConvertTo-SecureString $plainAuthPwd -AsPlainText -Force)
                    PrivacyProtocol = (ConvertTo-SecureString ([string]$privProto) -AsPlainText -Force)
                    PrivacyPassword = (ConvertTo-SecureString $plainPrivPwd -AsPlainText -Force)
                }
                Save-DiscoveryCredential -Name $VaultName -Fields $fields `
                    -Description "$ProviderLabel SNMPv3 ($snmpUser)" -Force | Out-Null
                Write-Host "  Saved to vault as '$VaultName'." -ForegroundColor Green
            } else {
                Write-Host "  Credential NOT saved (DeferSave). Validate, then call Save-ResolvedCredential." -ForegroundColor DarkYellow
            }
            return $result
        }
    }
    return $null
}

function ConvertFrom-VaultStored {
    <#
    .SYNOPSIS
        Internal helper — converts raw vault data to the expected return type.
    .DESCRIPTION
        Handles multiple input formats:
        - PSCredential objects (returned as-is for compatible types)
        - Pipe-delimited strings (legacy format)
        - Hashtables from Fields-based vault storage (new format)
        
        Always returns the canonical format for each CredType so callers can
        use consistent property access (e.g., .UserName, .Password for PSCredential).
    #>
    [CmdletBinding()]
    param($Stored, [string]$CredType)

    switch ($CredType) {
        'AWSKeys' {
            if ($Stored -is [PSCredential]) { return $Stored }
            # Fields-based hashtable: AccessKey, SecretKey (plaintext strings)
            if ($Stored -is [hashtable]) {
                $ak = if ($Stored.AccessKey) { $Stored.AccessKey } elseif ($Stored.AccessKeyId) { $Stored.AccessKeyId } else { $null }
                $sk = if ($Stored.SecretKey) { $Stored.SecretKey } elseif ($Stored.SecretAccessKey) { $Stored.SecretAccessKey } else { $null }
                if ($ak -and $sk) {
                    $secKey = ConvertTo-SecureString $sk -AsPlainText -Force
                    return [PSCredential]::new($ak, $secKey)
                }
            }
            # Pipe-delimited string: AccessKey|SecretKey
            if ($Stored -is [string] -and $Stored -match '\|') {
                $parts = $Stored -split '\|', 2
                $secKey = ConvertTo-SecureString $parts[1] -AsPlainText -Force
                return [PSCredential]::new($parts[0], $secKey)
            }
            return $Stored
        }
        'PSCredential' {
            if ($Stored -is [PSCredential]) { return $Stored }
            # Fields-based hashtable: Username, Password (plaintext strings)
            if ($Stored -is [hashtable]) {
                $user = if ($Stored.Username) { $Stored.Username } elseif ($Stored.User) { $Stored.User } else { $null }
                $pass = if ($Stored.Password) { $Stored.Password } elseif ($Stored.Secret) { $Stored.Secret } else { $null }
                if ($user -and $pass) {
                    $secPwd = ConvertTo-SecureString $pass -AsPlainText -Force
                    return [PSCredential]::new($user, $secPwd)
                }
            }
            # Pipe-delimited string: Username|Password
            if ($Stored -is [string] -and $Stored -match '\|') {
                $parts = $Stored -split '\|', 2
                $secPwd = ConvertTo-SecureString $parts[1] -AsPlainText -Force
                return [PSCredential]::new($parts[0], $secPwd)
            }
            return $Stored
        }
        'AzureSP' {
            if ($Stored -is [PSCredential]) { return $Stored }
            # Fields-based hashtable: TenantId, ClientId/ApplicationId, ClientSecret
            if ($Stored -is [hashtable]) {
                $tid = $Stored.TenantId
                $aid = if ($Stored.ClientId) { $Stored.ClientId } elseif ($Stored.ApplicationId) { $Stored.ApplicationId } else { $null }
                $sec = if ($Stored.ClientSecret) { $Stored.ClientSecret } elseif ($Stored.Secret) { $Stored.Secret } else { $null }
                if ($tid -and $aid -and $sec) {
                    $combinedUser = "$tid|$aid"
                    $secSecret = ConvertTo-SecureString $sec -AsPlainText -Force
                    return [PSCredential]::new($combinedUser, $secSecret)
                }
            }
            # Pipe-delimited string: TenantId|AppId|ClientSecret
            if ($Stored -is [string] -and $Stored -match '\|') {
                $parts = $Stored -split '\|', 3
                if ($parts.Count -ge 3) {
                    $combinedUser = "$($parts[0])|$($parts[1])"
                    $secSecret = ConvertTo-SecureString $parts[2] -AsPlainText -Force
                    return [PSCredential]::new($combinedUser, $secSecret)
                }
            }
            return $Stored
        }
        'BearerToken' {
            # BearerToken returns plain string; hashtable with single field also supported
            if ($Stored -is [hashtable]) {
                if ($Stored.Token) { return $Stored.Token }
                if ($Stored.ApiKey) { return $Stored.ApiKey }
                if ($Stored.Secret) { return $Stored.Secret }
                # Return first value if single-field hashtable
                if ($Stored.Count -eq 1) { return $Stored.Values | Select-Object -First 1 }
            }
            return $Stored
        }
        'OCIConfig' {
            # Already hashtable-friendly
            if ($Stored -is [hashtable] -and $Stored.ConfigFile) { return $Stored }
            if ($Stored -is [string] -and $Stored -match '\|') {
                $parts = $Stored -split '\|', 3
                if ($parts.Count -ge 3) {
                    return @{
                        ConfigFile = $parts[0]
                        Profile    = $parts[1]
                        TenancyId  = $parts[2]
                    }
                }
            }
            return $Stored
        }
        'SNMPv2' {
            # Returns hashtable with Version and Community
            if ($Stored -is [hashtable]) {
                return @{
                    Version   = 2
                    Community = if ($Stored.Community) { $Stored.Community } else { $Stored.Values | Select-Object -First 1 }
                }
            }
            # Plain string = community string
            if ($Stored -is [string]) {
                return @{ Version = 2; Community = $Stored }
            }
            return $Stored
        }
        'SNMPv3' {
            # Returns hashtable with all SNMPv3 fields
            if ($Stored -is [hashtable]) {
                return @{
                    Version         = 3
                    Username        = if ($Stored.Username) { $Stored.Username } elseif ($Stored.User) { $Stored.User } else { '' }
                    Context         = if ($Stored.Context) { $Stored.Context } else { '' }
                    AuthProtocol    = if ($Stored.AuthProtocol) { $Stored.AuthProtocol } else { 0 }
                    AuthPassword    = if ($Stored.AuthPassword) { $Stored.AuthPassword } else { '' }
                    PrivacyProtocol = if ($Stored.PrivacyProtocol) { $Stored.PrivacyProtocol } else { 0 }
                    PrivacyPassword = if ($Stored.PrivacyPassword) { $Stored.PrivacyPassword } else { '' }
                }
            }
            return $Stored
        }
        'WUGServer' {
            # Already hashtable-friendly
            if ($Stored -is [hashtable] -and $Stored.Server) { return $Stored }
            if ($Stored -is [string] -and $Stored -match '\|') {
                $parts = $Stored -split '\|', 5
                if ($parts.Count -ge 5) {
                    $secPwd = ConvertTo-SecureString $parts[4] -AsPlainText -Force
                    return @{
                        Server     = $parts[0]
                        Port       = [int]$parts[1]
                        Protocol   = $parts[2]
                        Credential = [PSCredential]::new($parts[3], $secPwd)
                        IgnoreSSL  = $true
                    }
                }
            }
            return $Stored
        }
        default { return $Stored }
    }
}

function Save-ResolvedCredential {
    <#
    .SYNOPSIS
        Persists a credential returned by Resolve-DiscoveryCredential -DeferSave.
    .DESCRIPTION
        Call this after you have validated the credential works. It encodes the
        value in the correct vault format based on CredType and saves it.
    .PARAMETER Name
        Vault credential name (same name used in Resolve-DiscoveryCredential).
    .PARAMETER CredType
        The credential type: AWSKeys, AzureSP, BearerToken, PSCredential, WUGServer.
    .PARAMETER Value
        The credential value returned by Resolve-DiscoveryCredential:
          PSCredential   for AWSKeys, AzureSP, PSCredential
          String         for BearerToken
          Hashtable      for WUGServer (with Server, Port, Protocol, Credential keys)
    .EXAMPLE
        $wug = Resolve-DiscoveryCredential -Name 'WUG.Server' -CredType WUGServer -DeferSave
        # ... test connection succeeds ...
        Save-ResolvedCredential -Name 'WUG.Server' -CredType WUGServer -Value $wug
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [ValidateSet('AWSKeys','AzureSP','BearerToken','FilePath','OCIConfig','PSCredential','WUGServer')] [string]$CredType,
        [Parameter(Mandatory)] $Value
    )

    Initialize-DiscoveryVault

    switch ($CredType) {
        'AWSKeys' {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value.Password)
            try { $sk = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            $ss = ConvertTo-SecureString "$($Value.UserName)|$sk" -AsPlainText -Force
            Save-DiscoveryCredential -Name $Name -SecureSecret $ss `
                -Description "AWS IAM ($($Value.UserName))" -Force | Out-Null
        }
        'AzureSP' {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value.Password)
            try { $secret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            $ss = ConvertTo-SecureString "$($Value.UserName)|$secret" -AsPlainText -Force
            $parts = $Value.UserName -split '\|', 2
            Save-DiscoveryCredential -Name $Name -SecureSecret $ss `
                -Description "Azure SP (Tenant=$($parts[0]), App=$($parts[1]))" -Force | Out-Null
        }
        'BearerToken' {
            $ss = ConvertTo-SecureString "$Value" -AsPlainText -Force
            Save-DiscoveryCredential -Name $Name -SecureSecret $ss `
                -Description 'API token' -Force | Out-Null
        }
        'OCIConfig' {
            $combined = "$($Value.ConfigFile)|$($Value.Profile)|$($Value.TenancyId)"
            $ss = ConvertTo-SecureString $combined -AsPlainText -Force
            Save-DiscoveryCredential -Name $Name -SecureSecret $ss `
                -Description "OCI ($($Value.Profile) @ $($Value.ConfigFile))" -Force | Out-Null
        }
        'PSCredential' {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value.Password)
            try { $pwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            $ss = ConvertTo-SecureString "$($Value.UserName)|$pwd" -AsPlainText -Force
            Save-DiscoveryCredential -Name $Name -SecureSecret $ss `
                -Description "$($Value.UserName)" -Force | Out-Null
        }
        'WUGServer' {
            $c = $Value.Credential
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($c.Password)
            try { $pwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            $combined = "$($Value.Server)|$($Value.Port)|$($Value.Protocol)|$($c.UserName)|$pwd"
            $ss = ConvertTo-SecureString $combined -AsPlainText -Force
            Save-DiscoveryCredential -Name $Name -SecureSecret $ss `
                -Description "WUG $($Value.Protocol)://$($Value.Server):$($Value.Port) ($($c.UserName))" -Force | Out-Null
        }
        'FilePath' {
            $ss = ConvertTo-SecureString "$Value" -AsPlainText -Force
            Save-DiscoveryCredential -Name $Name -SecureSecret $ss `
                -Description "File path: $Value" -Force | Out-Null
        }
    }
    Write-Host "  Saved to vault as '$Name'." -ForegroundColor Green
}

Set-Alias -Name 'Resolve-WUGDiscoveryCredential' -Value 'Resolve-DiscoveryCredential' -Scope Script

function Remove-DiscoveryCredential {
    <#
    .SYNOPSIS
        Deletes a credential from the DPAPI vault.
    .PARAMETER Name
        The credential name to delete.
    .EXAMPLE
        Remove-DiscoveryCredential -Name 'FortiGate-FW1'
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $filePath = Join-Path $script:DiscoveryVaultPath "$Name.cred"
    if (-not (Test-Path $filePath)) {
        Write-Warning "Credential '$Name' not found in vault."
        return
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Delete credential from vault')) {
        Remove-Item -Path $filePath -Force
        Write-VaultAuditLog -Action 'Delete' -CredentialName $Name
        Write-Verbose "Credential '$Name' removed from vault."
    }
}

# endregion

# ============================================================================
# region  WUG Device Discovery (requires WhatsUpGoldPS)
# ============================================================================

function Invoke-WUGDiscovery {
    <#
    .SYNOPSIS
        Runs discovery providers against matching WUG devices.
    .DESCRIPTION
        For each targeted device:
        1. Resolves the WUG REST API credential assigned to the device
        2. Calls the provider's DiscoverScript
        3. Returns a discovery plan (list of items to create/sync)

        The plan can be reviewed before committing with Invoke-WUGDiscoverySync.
    .PARAMETER ProviderName
        Run a specific provider only. If omitted, runs all registered providers.
    .PARAMETER DeviceId
        Limit discovery to specific device IDs.
    .PARAMETER ApiPort
        Override the default API port for the target devices.
    .PARAMETER ApiProtocol
        Override the default protocol. Default: from provider.
    .PARAMETER Options
        Provider-specific settings, passed to the DiscoverScript as $ctx.Options.
    .EXAMPLE
        # Discover all F5 devices
        $plan = Invoke-WUGDiscovery -ProviderName 'F5'
        $plan | Format-Table DeviceName, Name, ItemType, MonitorType

    .EXAMPLE
        # Discover everything
        $plan = Invoke-WUGDiscovery
        $plan | Group-Object ProviderName | Select-Object Name, Count

    .EXAMPLE
        # Skip the Redfish deep walk for a faster, shallower scan
        $plan = Invoke-WUGDiscovery -ProviderName 'Redfish' -Options @{ NoDeepWalk = $true }
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ProviderName,

        [Parameter()]
        [int[]]$DeviceId,

        [Parameter()]
        [int]$ApiPort,

        [Parameter()]
        [string]$ApiProtocol,

        [Parameter()]
        [hashtable]$Credential,

        [Parameter()]
        [hashtable]$Options
    )

    if (-not (Get-Command -Name 'Get-WUGDevice' -ErrorAction SilentlyContinue)) {
        throw "WhatsUpGoldPS module is not loaded. Run 'Import-Module WhatsUpGoldPS' and 'Connect-WUGServer' first."
    }

    $providers = @()
    if ($ProviderName) {
        $p = Get-DiscoveryProvider -Name $ProviderName
        if ($p) { $providers += $p }
    }
    else {
        $providers = @(Get-DiscoveryProvider)
    }

    if ($providers.Count -eq 0) {
        Write-Warning "No discovery providers registered. Use Register-DiscoveryProvider first."
        return @()
    }

    $allItems = @()

    foreach ($provider in $providers) {
        Write-Verbose "Running discovery for provider '$($provider.Name)'..."

        $matchedDevices = Find-WUGDiscoveryDevices -ProviderName $provider.Name -DeviceId $DeviceId
        if ($matchedDevices.Count -eq 0) {
            Write-Verbose "No devices found for provider '$($provider.Name)'"
            continue
        }

        foreach ($device in $matchedDevices) {
            Write-Verbose "Discovering device $($device.DeviceId) ($($device.DeviceName))..."

            # Build the base URI for the device API
            $proto = if ($ApiProtocol) { $ApiProtocol } else { $provider.DefaultProtocol }
            $port = if ($ApiPort) { $ApiPort } else { $provider.DefaultPort }
            $baseUri = "${proto}://$($device.DeviceIP):${port}"

            # Get existing monitors assigned to this device for skip logic
            $existingMonitors = @()
            try {
                $existingMonitors = @(Get-WUGActiveMonitor -DeviceId $device.DeviceId)
            }
            catch {
                Write-Verbose "Could not fetch existing monitors for device $($device.DeviceId): $_"
            }

            # Build context for the provider script
            $ctx = @{
                DeviceId         = $device.DeviceId
                DeviceName       = $device.DeviceName
                DeviceIP         = $device.DeviceIP
                BaseUri          = $baseUri
                Port             = $port
                Protocol         = $proto
                ProviderName     = $provider.Name
                AttributeValue   = $device.AttributeValue
                Credential       = $Credential
                ExistingMonitors = $existingMonitors
                IgnoreCertErrors = $provider.IgnoreCertErrors
                Options          = $Options
            }

            try {
                $items = & $provider.DiscoverScript $ctx
                if ($items) {
                    foreach ($item in @($items)) {
                        # Stamp device/provider info
                        $item | Add-Member -NotePropertyName 'DeviceId' -NotePropertyValue $device.DeviceId -Force
                        $item | Add-Member -NotePropertyName 'DeviceName' -NotePropertyValue $device.DeviceName -Force
                        $item | Add-Member -NotePropertyName 'DeviceIP' -NotePropertyValue $device.DeviceIP -Force
                        $item | Add-Member -NotePropertyName 'ProviderName' -NotePropertyValue $provider.Name -Force
                        $allItems += $item
                    }
                }
                Write-Verbose "Provider '$($provider.Name)' found $(@($items).Count) items on device $($device.DeviceName)"
            }
            catch {
                Write-Warning "Discovery failed for '$($provider.Name)' on device $($device.DeviceName) ($($device.DeviceIP)): $_"
            }
        }
    }

    Write-Verbose "Total discovered items: $($allItems.Count)"
    return $allItems
}

# endregion

# ============================================================================
# region  WUG Discovery Sync (requires WhatsUpGoldPS)
# ============================================================================

function Invoke-WUGDiscoverySync {
    <#
    .SYNOPSIS
        Syncs discovered items into WUG monitors (creates new, skips existing).
    .DESCRIPTION
        Takes the output of Invoke-WUGDiscovery and for each item:

        1. Checks if a monitor with the same name already exists
        2. Creates it if missing (Active or Performance monitor)
        3. Assigns it to the target device
        4. Updates device attributes if the item includes any

        This is idempotent   running it multiple times only creates what's
        missing. Monitors whose discovered items have disappeared are NOT
        automatically deleted (safety). Use -RemoveOrphans to enable that.

    .PARAMETER Plan
        Discovered items from Invoke-WUGDiscovery.
    .PARAMETER PollingIntervalSeconds
        Polling interval for Active Monitor assignments. Default: 300 (5 min).
    .PARAMETER PerfPollingIntervalMinutes
        Polling interval for Performance Monitors. Default: 5.
    .PARAMETER RemoveOrphans
        If set, removes monitors that were previously created by discovery
        but whose items no longer appear. CAUTION: destructive.
    .PARAMETER MonitorNamePrefix
        Prefix added by the provider. Used in orphan detection lookups.
    .PARAMETER UpdateAttributes
        Whether to update device attributes from discovered items. Default: $true.
    .EXAMPLE
        $plan = Invoke-WUGDiscovery -ProviderName 'F5'
        $plan | Format-Table DeviceName, Name, ItemType, MonitorType
        Invoke-WUGDiscoverySync -Plan $plan

    .EXAMPLE
        # Full auto: discover and sync in one pipeline
        Invoke-WUGDiscovery -ProviderName 'Fortinet' | Invoke-WUGDiscoverySync
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PSCustomObject[]]$Plan,

        [Parameter()]
        [ValidateRange(60, 86400)]
        [int]$PollingIntervalSeconds,

        [Parameter()]
        [ValidateRange(1, 1440)]
        [int]$PerfPollingIntervalMinutes,

        [Parameter()]
        [switch]$RemoveOrphans,

        [Parameter()]
        [string]$MonitorNamePrefix,

        [Parameter()]
        [bool]$UpdateAttributes = $true
    )

    begin {
        if (-not (Get-Command -Name 'Add-WUGActiveMonitor' -ErrorAction SilentlyContinue)) {
            throw "WhatsUpGoldPS module is not loaded."
        }
        if (-not (Get-Command -Name 'Get-WUGAPIResponse' -ErrorAction SilentlyContinue)) {
            $apiResponsePath = Join-Path $PSScriptRoot '..\..\functions\Get-WUGAPIResponse.ps1'
            if (Test-Path $apiResponsePath) { . $apiResponsePath }
        }
        if (-not (Get-Command -Name 'Get-WUGAPIResponse' -ErrorAction SilentlyContinue)) {
            throw "Get-WUGAPIResponse is not available."
        }

        Write-Verbose "Fetching existing WUG active monitors for duplicate check..."
        $existingActiveNames = Get-WUGMonitorLibraryMap -Type active

        $stats = @{
            ActiveCreated  = 0
            PerfCreated    = 0
            Skipped        = 0
            Assigned       = 0
            AttrsUpdated   = 0
            Failed         = 0
        }
        $deviceActiveMonitors = @{}
        $items = [System.Collections.ArrayList]@()
    }

    process {
        foreach ($item in $Plan) {
            [void]$items.Add($item)
        }
    }

    end {
        $total = $items.Count
        $current = 0

        foreach ($item in $items) {
            $current++
            $pct = [Math]::Round(($current / $total) * 100)
            Write-Progress -Activity 'WUG Discovery Sync' `
                -Status "Processing $current of $total - $($item.Name)" `
                -PercentComplete $pct

            $monName = $item.Name

            # --- Create Active Monitor ---
            if ($item.ItemType -eq 'ActiveMonitor') {
                $monId = $null
                if ($existingActiveNames.ContainsKey($monName)) {
                    $monId = $existingActiveNames[$monName]
                    Write-Verbose "Active monitor '$monName' already exists (ID: $monId)"
                    $stats.Skipped++
                }
                else {
                    if ($item.MonitorParams.Count -eq 0) {
                        Write-Verbose "Skipping creation for '$monName'   no params (built-in monitor expected in library)"
                        $stats.Skipped++
                    }
                    elseif ($PSCmdlet.ShouldProcess($monName, "Create $($item.MonitorType) Active Monitor")) {
                        try {
                            $addParams = @{
                                Type = $item.MonitorType
                                Name = $monName
                            }
                            # Copy monitor params, filtering out non-cmdlet keys
                            foreach ($key in $item.MonitorParams.Keys) {
                                if ($key -ne 'Description') {
                                    $addParams[$key] = $item.MonitorParams[$key]
                                }
                            }

                            $result = Add-WUGActiveMonitor @addParams
                            $stats.ActiveCreated++
                            Write-Verbose "Created active monitor '$monName' ($($item.MonitorType))"

                            if ($result) {
                                # Add-WUGActiveMonitor returns the bare new monitor ID.
                                $monId = if ($result -is [ValueType] -or $result -is [string]) { $result }
                                    elseif ($result.PSObject.Properties['resourceId']) { $result.resourceId }
                                    else { $result.id }
                                $existingActiveNames[$monName] = $monId
                            }
                            if (-not $monId) {
                                $monId = (Get-WUGMonitorLibraryMap -Type active)[$monName]
                                if ($monId) { $existingActiveNames[$monName] = $monId }
                            }
                        }
                        catch {
                            Write-Warning "Failed to create active monitor '$monName': $_"
                            $stats.Failed++
                        }
                    }
                }

                # WUG rejects duplicate assignments instead of merging, so check first.
                if ($monId -and $item.DeviceId) {
                    $devKey = [string]$item.DeviceId
                    if (-not $deviceActiveMonitors.ContainsKey($devKey)) {
                        $assignedIds = @{}
                        try {
                            $devMonUri = "$($global:WhatsUpServerBaseURI)/api/v1/devices/$devKey/monitors/-?type=active&view=basic"
                            foreach ($mon in @((Get-WUGAPIResponse -Uri $devMonUri -Method GET).data)) {
                                if ($mon -and $mon.monitorTypeId) { $assignedIds[[string]$mon.monitorTypeId] = $true }
                            }
                        }
                        catch {
                            Write-Verbose "Could not read active assignments for device ${devKey}: $_"
                        }
                        $deviceActiveMonitors[$devKey] = $assignedIds
                    }

                    if ($deviceActiveMonitors[$devKey].ContainsKey([string]$monId)) {
                        Write-Verbose "Monitor '$monName' already assigned to device $devKey"
                        $stats.Skipped++
                    }
                    else {
                        try {
                            $assignSplat = @{
                                DeviceId  = $item.DeviceId
                                MonitorId = $monId
                            }
                            if ($PSBoundParameters.ContainsKey('PollingIntervalSeconds')) {
                                $assignSplat['PollingIntervalSeconds'] = $PollingIntervalSeconds
                            }
                            Add-WUGActiveMonitorToDevice @assignSplat | Out-Null
                            $deviceActiveMonitors[$devKey][[string]$monId] = $true
                            $stats.Assigned++
                            Write-Verbose "Assigned '$monName' to device $devKey"
                        }
                        catch {
                            if ($_.Exception.Message -match 'already|assigned|exists|duplicate') {
                                Write-Verbose "Monitor '$monName' already assigned to device $devKey"
                                $stats.Skipped++
                            }
                            else {
                                Write-Warning "Failed to assign '$monName' to device ${devKey}: $_"
                                $stats.Failed++
                            }
                        }
                    }
                }
            }

            # --- Create Performance Monitor ---
            if ($item.ItemType -eq 'PerformanceMonitor') {
                # Performance monitors are per-device   skip if no valid DeviceId
                if (-not $item.DeviceId -or $item.DeviceId -eq 0) {
                    Write-Verbose "Skipping perf monitor '$monName'   no valid DeviceId"
                    $stats.Skipped++
                    continue
                }
                if ($PSCmdlet.ShouldProcess($monName, "Create $($item.MonitorType) Performance Monitor on device $($item.DeviceId)")) {
                    try {
                        $perfParams = @{
                            DeviceId = $item.DeviceId
                            Type     = $item.MonitorType
                        }
                        if ($PSBoundParameters.ContainsKey('PerfPollingIntervalMinutes')) {
                            $perfParams['PollingIntervalMinutes'] = $PerfPollingIntervalMinutes
                        }
                        if ($item.MonitorParams.ContainsKey('Name')) {
                            $perfParams['Name'] = $item.MonitorParams['Name']
                        }
                        else {
                            $perfParams['Name'] = $monName
                        }
                        # Copy monitor params, filtering out non-cmdlet keys
                        foreach ($key in $item.MonitorParams.Keys) {
                            if ($key -ne 'Name' -and $key -ne 'Description') {
                                $perfParams[$key] = $item.MonitorParams[$key]
                            }
                        }

                        $result = Add-WUGPerformanceMonitor @perfParams
                        $stats.PerfCreated++
                        $stats.Assigned++
                        Write-Verbose "Created performance monitor '$monName' on device $($item.DeviceId)"
                    }
                    catch {
                        # Check if it's a duplicate error
                        if ($_.Exception.Message -match 'already exists|duplicate') {
                            Write-Verbose "Skipping perf monitor '$monName'   already exists"
                            $stats.Skipped++
                        }
                        else {
                            Write-Warning "Failed to create performance monitor '$monName': $_"
                            $stats.Failed++
                        }
                    }
                }
            }

            # --- Update Device Attributes ---
            if ($UpdateAttributes -and $item.DeviceId -and $item.DeviceId -ne 0 -and $item.Attributes -and $item.Attributes.Count -gt 0) {
                foreach ($attrName in $item.Attributes.Keys) {
                    $attrValue = $item.Attributes[$attrName]
                    if ($PSCmdlet.ShouldProcess("Device $($item.DeviceId): $attrName=$attrValue", 'Set device attribute')) {
                        try {
                            Set-WUGDeviceAttribute -DeviceId $item.DeviceId -Name $attrName -Value $attrValue | Out-Null
                            $stats.AttrsUpdated++
                        }
                        catch {
                            Write-Warning "Failed to set attribute '$attrName' on device $($item.DeviceId): $_"
                        }
                    }
                }
            }
        }

        Write-Progress -Activity 'WUG Discovery Sync' -Completed

        [PSCustomObject]@{
            ActiveCreated = $stats.ActiveCreated
            PerfCreated   = $stats.PerfCreated
            Skipped       = $stats.Skipped
            Assigned      = $stats.Assigned
            AttrsUpdated  = $stats.AttrsUpdated
            Failed        = $stats.Failed
            Total         = $total
        }
    }
}

# endregion

# ============================================================================
# region  WUG Credential Setup (requires WhatsUpGoldPS)
# ============================================================================

function New-WUGDiscoveryCredential {
    <#
    .SYNOPSIS
        Creates a WUG REST API credential and assigns it to a device
        for use by discovery-provisioned monitors.
    .DESCRIPTION
        Wraps Add-WUGCredential + Set-WUGDeviceCredential to ensure the
        device has a REST API credential that WUG monitors can use to
        poll the device's API. Also sets the DiscoveryHelper attribute
        on the device so Invoke-WUGDiscovery can find it.

        For F5 BIG-IP:   Basic auth (username/password via iControl REST)
        For FortiGate:    Bearer token (API token via FortiOS REST API)
    .PARAMETER DeviceId
        WUG device ID to configure.
    .PARAMETER ProviderName
        Discovery provider name (e.g., 'F5', 'Fortinet').
    .PARAMETER CredentialName
        Name for the WUG credential. Auto-generated if omitted.
    .PARAMETER Username
        REST API username (for basic auth providers like F5).
    .PARAMETER Password
        REST API password (for basic auth providers).
    .PARAMETER ApiToken
        API bearer token (for token-based providers like Fortinet).
    .PARAMETER TokenUrl
        OAuth2 token URL (for F5 BIG-IP token auth).
    .PARAMETER IgnoreCertErrors
        Whether the credential should ignore SSL cert errors. Default: $true.
    .EXAMPLE
        # F5 BIG-IP   basic auth
        New-WUGDiscoveryCredential -DeviceId 42 -ProviderName 'F5' `
            -Username 'admin' -Password 'pass' -IgnoreCertErrors

    .EXAMPLE
        # FortiGate   API token
        New-WUGDiscoveryCredential -DeviceId 55 -ProviderName 'Fortinet' `
            -ApiToken 'your-api-token-here'
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [int]$DeviceId,

        [Parameter(Mandatory = $true)]
        [string]$ProviderName,

        [Parameter()]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
        [string]$CredentialName,

        [Parameter()]
        [string]$Username,

        [Parameter()]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
        [string]$Password,

        [Parameter()]
        [string]$ApiToken,

        [Parameter()]
        [string]$TokenUrl,

        [Parameter()]
        [bool]$IgnoreCertErrors = $true
    )

    $provider = Get-DiscoveryProvider -Name $ProviderName
    if (-not $provider) {
        Write-Error "Provider '$ProviderName' is not registered. Register it first."
        return
    }

    # Generate credential name
    if (-not $CredentialName) {
        $dev = Get-WUGDevice -DeviceId $DeviceId
        $devName = if ($dev.displayName) { $dev.displayName } else { "Device-$DeviceId" }
        $CredentialName = "$ProviderName API - $devName"
    }

    # Build credential params
    $credParams = @{
        Name = $CredentialName
        Type = 'restapi'
    }

    if ($ApiToken) {
        # Token-based auth   credential is a placeholder since actual auth
        # goes via RestApiCustomHeader on each monitor. WUG requires a valid
        # credential assigned to the device, so we set a dummy username.
        $credParams['RestApiUsername']  = 'api-token'
        $credParams['RestApiPassword']  = $ApiToken
        $credParams['RestApiAuthType']  = '0'  # Basic auth
    }
    elseif ($Username -and $Password) {
        # Basic auth (F5 iControl style)
        $credParams['RestApiUsername']  = $Username
        $credParams['RestApiPassword']  = $Password
        $credParams['RestApiAuthType']  = '0'
        if ($TokenUrl) {
            # If token URL provided, use OAuth2 password grant
            $credParams['RestApiAuthType']     = '1'
            $credParams['RestApiGrantType']    = '1'  # Password grant
            $credParams['RestApiTokenUrl']     = $TokenUrl
            $credParams['RestApiPwdGrantUserName'] = $Username
            $credParams['RestApiPwdGrantPassword'] = $Password
        }
    }
    else {
        Write-Error "Provide either -ApiToken (token auth) or -Username and -Password (basic auth)."
        return
    }

    if ($PSCmdlet.ShouldProcess($CredentialName, 'Create REST API credential')) {
        try {
            $credResult = Add-WUGCredential @credParams
            $credId = $null
            if ($credResult.PSObject.Properties['resourceId']) { $credId = $credResult.resourceId }
            elseif ($credResult.PSObject.Properties['id']) { $credId = $credResult.id }
            Write-Verbose "Created REST API credential '$CredentialName' (ID: $credId)"
        }
        catch {
            Write-Error "Failed to create credential: $_"
            return
        }
    }

    # Assign credential to device
    if ($credId -and $PSCmdlet.ShouldProcess("Device $DeviceId", "Assign credential $credId")) {
        try {
            Set-WUGDeviceCredential -DeviceId $DeviceId -CredentialId $credId -Assign
            Write-Verbose "Assigned credential to device $DeviceId"
        }
        catch {
            Write-Warning "Failed to assign credential to device $DeviceId`: $_"
        }
    }

    # Set discovery attribute on device
    $matchAttr = $provider.MatchAttribute
    if ($PSCmdlet.ShouldProcess("Device $DeviceId", "Set attribute $matchAttr=true")) {
        try {
            Set-WUGDeviceAttribute -DeviceId $DeviceId -Name $matchAttr -Value 'true'
            Write-Verbose "Set attribute '$matchAttr=true' on device $DeviceId"
        }
        catch {
            Write-Warning "Failed to set discovery attribute on device $DeviceId`: $_"
        }
    }

    [PSCustomObject]@{
        CredentialId   = $credId
        CredentialName = $CredentialName
        DeviceId       = $DeviceId
        ProviderName   = $ProviderName
        MatchAttribute = $matchAttr
    }
}

# endregion

# ============================================================================
# region  Start-WUGDiscovery   Full End-to-End Orchestrator
# ============================================================================

function Start-WUGDiscovery {
    <#
    .SYNOPSIS
        One-command discovery: prompts for creds, adds devices, creates monitors.
    .DESCRIPTION
        End-to-end orchestrator for WUG discovery. Run it from the WUG server
        periodically (Task Scheduler, etc.). On first run it prompts for
        credentials with masked input and stores them in the DPAPI vault.
        Subsequent runs are fully automatic.

        Flow:
          1. Loads provider, checks DPAPI vault for creds, prompts if missing
          2. For each target IP/hostname:
             a. Searches WUG for existing device   adds via Add-WUGDevice if missing
             b. Creates REST API credential in WUG   assigns to device
             c. Sets the provider's MatchAttribute on the device
          3. Runs Invoke-WUGDiscovery   builds the monitor plan
          4. Shows the plan for review (unless -Confirm:$false)
          5. Runs Invoke-WUGDiscoverySync   creates monitors, assigns to devices
          6. Returns summary

        Credentials are stored in two places:
          - DPAPI vault (local, encrypted to Windows user + machine)   used by
            this script for first-run setup and any live API calls
          - WUG credential store (encrypted by WUG)   used by WUG's polling
            engine for ongoing REST API monitor authentication

    .PARAMETER ProviderName
        Discovery provider to run (e.g., 'F5', 'Fortinet').
    .PARAMETER Target
        IP addresses or hostnames of the target devices.
    .PARAMETER ApiPort
        Override the default API port for the targets.
    .PARAMETER ApiProtocol
        Override the default protocol.
    .PARAMETER DeviceGroupId
        WUG device group ID to add new devices to. Default: 0.
    .PARAMETER PollingIntervalSeconds
        Polling interval for active monitors. Default: 300 (5 min).
    .PARAMETER PerfPollingIntervalMinutes
        Polling interval for performance monitors. Default: 5.
    .PARAMETER VaultPassword
        Optional vault password for AES-256 double encryption on the DPAPI vault.
        If the vault was set up with a password, provide it here.
    .PARAMETER SkipDeviceAdd
        Do not add devices to WUG. Only sync monitors for existing devices.
    .EXAMPLE
        # First run   prompts for F5 credentials with masked input:
        Start-WUGDiscovery -ProviderName 'F5' -Target 'lb1.corp.local','lb2.corp.local'

        # Subsequent runs   fully automatic, no prompts:
        Start-WUGDiscovery -ProviderName 'F5' -Target 'lb1.corp.local','lb2.corp.local'
    .EXAMPLE
        # FortiGate with custom port:
        Start-WUGDiscovery -ProviderName 'Fortinet' -Target '10.0.0.1' -ApiPort 8443
    .EXAMPLE
        # Non-interactive (Task Scheduler)   skips confirmation prompt:
        Start-WUGDiscovery -ProviderName 'F5' -Target 'lb1.corp.local' -Confirm:$false
    .NOTES
        Requires: WhatsUpGoldPS module loaded and connected (Connect-WUGServer).
        DPAPI vault creds are per-user, per-machine. Run as the same user that
        will run the scheduled task.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProviderName,

        [Parameter(Mandatory = $true)]
        [string[]]$Target,

        [Parameter()]
        [int]$ApiPort,

        [Parameter()]
        [string]$ApiProtocol,

        [Parameter()]
        [int]$DeviceGroupId = 0,

        [Parameter()]
        [ValidateRange(60, 86400)]
        [int]$PollingIntervalSeconds = 300,

        [Parameter()]
        [ValidateRange(1, 1440)]
        [int]$PerfPollingIntervalMinutes = 5,

        [Parameter()]
        [SecureString]$VaultPassword,

        [Parameter()]
        [switch]$SkipDeviceAdd
    )

    # --- Validate prerequisites -----------------------------------------------
    $provider = Get-DiscoveryProvider -Name $ProviderName
    if (-not $provider) {
        Write-Error "Provider '$ProviderName' is not registered. Load the provider script first."
        return
    }

    if (-not (Get-Command -Name 'Get-WUGDevice' -ErrorAction SilentlyContinue)) {
        throw "WhatsUpGoldPS module is not loaded. Run 'Import-Module WhatsUpGoldPS' and 'Connect-WUGServer' first."
    }

    # --- Credential setup (DPAPI vault) ---------------------------------------
    # Vault keys are per-provider per-target so each device can have unique creds.
    # First run: masked interactive prompt. Subsequent runs: automatic from vault.
    if ($VaultPassword) {
        Set-DiscoveryVaultPassword -Password $VaultPassword
    }

    $credentialCache = @{}  # target -> credential hashtable

    foreach ($t in $Target) {
        $cred = $null

        if ($provider.AuthType -eq 'BearerToken') {
            # Single API token
            $vaultKey = "$ProviderName.$t.Token"
            $token = Get-DiscoveryCredential -Name $vaultKey -ErrorAction SilentlyContinue
            if ($token) {
                $cred = @{ ApiToken = $token }
                Write-Verbose "Loaded token for '$t' from vault"
            }
            else {
                Write-Host "No API token found for '$t'. Starting secure setup..." -ForegroundColor Yellow
                Write-Host "  The token will be encrypted with DPAPI (tied to this user + machine)." -ForegroundColor DarkGray
                Write-Host "  It will never appear in plaintext in logs, history, or on screen." -ForegroundColor DarkGray
                Request-DiscoveryCredential -Name $vaultKey `
                    -Prompt "$ProviderName API token for $t" `
                    -Description "$ProviderName bearer token for $t"
                $token = Get-DiscoveryCredential -Name $vaultKey -ErrorAction SilentlyContinue
                if (-not $token) {
                    Write-Error "Credential setup cancelled or failed for '$t'. Skipping."
                    continue
                }
                $cred = @{ ApiToken = $token }
            }
        }
        else {
            # BasicAuth   username + password stored as a bundle
            $vaultKey = "$ProviderName.$t"
            $bundle = Get-DiscoveryCredential -Name $vaultKey -ErrorAction SilentlyContinue
            if ($bundle -is [hashtable] -and $bundle.ContainsKey('Username') -and $bundle.ContainsKey('Password')) {
                $cred = $bundle
                Write-Verbose "Loaded credentials for '$t' from vault"
            }
            else {
                Write-Host "No credentials found for '$t'. Starting secure setup..." -ForegroundColor Yellow
                Write-Host "  Credentials will be encrypted with DPAPI (tied to this user + machine)." -ForegroundColor DarkGray
                Write-Host "  They will never appear in plaintext in logs, history, or on screen." -ForegroundColor DarkGray
                $usernameInput = Read-Host -Prompt "$ProviderName username for $t"
                $passwordInput = Read-Host -Prompt "$ProviderName password for $t" -AsSecureString
                if (-not $usernameInput) {
                    Write-Error "Username cannot be empty for '$t'. Skipping."
                    continue
                }
                $fields = @{
                    Username = ConvertTo-SecureString $usernameInput -AsPlainText -Force
                    Password = $passwordInput
                }
                Save-DiscoveryCredential -Name $vaultKey -Fields $fields `
                    -Description "$ProviderName credentials for $t" | Out-Null
                $bundle = Get-DiscoveryCredential -Name $vaultKey -ErrorAction SilentlyContinue
                if (-not ($bundle -is [hashtable])) {
                    Write-Error "Credential setup failed for '$t'. Skipping."
                    continue
                }
                $cred = $bundle
            }
        }

        $credentialCache[$t] = $cred
    }

    if ($credentialCache.Count -eq 0) {
        Write-Error "No valid credentials for any target. Aborting."
        return
    }

    # --- Find or create devices in WUG ----------------------------------------
    Write-Host ""
    Write-Host "=== $ProviderName Discovery ===" -ForegroundColor Cyan
    Write-Host "Targets: $($Target -join ', ')" -ForegroundColor Cyan

    $deviceMap = @{}  # target -> WUG device ID

    foreach ($t in $Target) {
        if (-not $credentialCache.ContainsKey($t)) { continue }

        # Search WUG for existing device by IP/hostname
        $existingDevice = $null
        try {
            $searchResults = @(Get-WUGDevice -SearchValue $t)
            if ($searchResults.Count -gt 0) {
                $existingDevice = $searchResults | Where-Object {
                    $_.networkAddress -eq $t -or
                    $_.hostName -eq $t -or
                    $_.displayName -eq $t
                } | Select-Object -First 1
                if (-not $existingDevice -and $searchResults.Count -eq 1) {
                    $existingDevice = $searchResults[0]
                }
            }
        }
        catch {
            Write-Verbose "Search for '$t' returned error: $_"
        }

        if ($existingDevice) {
            $deviceMap[$t] = $existingDevice.id
            Write-Host "  Found existing device: $($existingDevice.displayName) (ID: $($existingDevice.id))" -ForegroundColor Green
        }
        elseif (-not $SkipDeviceAdd) {
            Write-Host "  Adding '$t' to WUG..." -ForegroundColor Yellow
            try {
                Add-WUGDevice -IpOrName $t -GroupId $DeviceGroupId | Out-Null
                # Allow WUG to process the device scan
                Start-Sleep -Seconds 3
                $newDevice = @(Get-WUGDevice -SearchValue $t) | Select-Object -First 1
                if ($newDevice) {
                    $deviceMap[$t] = $newDevice.id
                    Write-Host "  Added device: $($newDevice.displayName) (ID: $($newDevice.id))" -ForegroundColor Green
                }
                else {
                    Write-Warning "Device '$t' was added but could not be found. Check WUG manually."
                }
            }
            catch {
                Write-Warning "Failed to add device '$t': $_"
            }
        }
        else {
            Write-Warning "Device '$t' not found in WUG and -SkipDeviceAdd is set. Skipping."
        }
    }

    if ($deviceMap.Count -eq 0) {
        Write-Error "No devices available in WUG. Aborting."
        return
    }

    # --- Create WUG REST API credentials + set attributes ---------------------
    Write-Host ""
    Write-Host "Configuring credentials and attributes..." -ForegroundColor Cyan

    foreach ($t in @($deviceMap.Keys)) {
        $devId = $deviceMap[$t]
        $cred = $credentialCache[$t]

        $credParams = @{
            DeviceId     = $devId
            ProviderName = $ProviderName
        }

        if ($cred.ContainsKey('ApiToken')) {
            $credParams['ApiToken'] = $cred.ApiToken
        }
        else {
            $credParams['Username'] = $cred.Username
            $credParams['Password'] = $cred.Password
        }

        try {
            New-WUGDiscoveryCredential @credParams | Out-Null
            Write-Host "  [$t] REST API credential created and assigned" -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to create WUG credential for '$t': $_"
        }
    }

    # --- Run discovery --------------------------------------------------------
    Write-Host ""
    Write-Host "Running $ProviderName discovery..." -ForegroundColor Cyan

    $discoveryParams = @{
        ProviderName = $ProviderName
        DeviceId     = @($deviceMap.Values)
    }
    if ($ApiPort) { $discoveryParams['ApiPort'] = $ApiPort }
    if ($ApiProtocol) { $discoveryParams['ApiProtocol'] = $ApiProtocol }

    # Pass credentials to provider context for any live API calls
    $firstTarget = $Target | Where-Object { $credentialCache.ContainsKey($_) } | Select-Object -First 1
    if ($firstTarget) {
        $discoveryParams['Credential'] = $credentialCache[$firstTarget]
    }

    $plan = Invoke-WUGDiscovery @discoveryParams

    if (-not $plan -or $plan.Count -eq 0) {
        Write-Warning "No items discovered. Check connectivity and credentials."
        return [PSCustomObject]@{
            Provider         = $ProviderName
            TargetsProcessed = $deviceMap.Count
            ItemsDiscovered  = 0
        }
    }

    # --- Review plan ----------------------------------------------------------
    Write-Host ""
    Write-Host "Discovery Plan: $($plan.Count) monitors" -ForegroundColor Cyan
    $plan | Format-Table Name, ItemType, MonitorType, DeviceName -AutoSize

    # --- Sync to WUG ----------------------------------------------------------
    if ($PSCmdlet.ShouldProcess("$($plan.Count) monitors on $($deviceMap.Count) device(s)", "Create and assign $ProviderName monitors")) {
        $result = Invoke-WUGDiscoverySync -Plan $plan `
            -PollingIntervalSeconds $PollingIntervalSeconds `
            -PerfPollingIntervalMinutes $PerfPollingIntervalMinutes

        Write-Host ""
        Write-Host "Sync complete!" -ForegroundColor Green
        Write-Host "  Active monitors created:      $($result.ActiveCreated)" -ForegroundColor White
        Write-Host "  Performance monitors created:  $($result.PerfCreated)" -ForegroundColor White
        Write-Host "  Assigned to devices:           $($result.Assigned)" -ForegroundColor White
        Write-Host "  Skipped (already exist):       $($result.Skipped)" -ForegroundColor White
        Write-Host "  Device attributes updated:     $($result.AttrsUpdated)" -ForegroundColor White
        if ($result.Failed -gt 0) {
            Write-Host "  Failed:                        $($result.Failed)" -ForegroundColor Red
        }

        $result | Add-Member -NotePropertyName 'Provider' -NotePropertyValue $ProviderName -Force
        $result | Add-Member -NotePropertyName 'TargetsProcessed' -NotePropertyValue $deviceMap.Count -Force
        $result | Add-Member -NotePropertyName 'ItemsDiscovered' -NotePropertyValue $plan.Count -Force
        return $result
    }
}

# endregion

# ============================================================================
# region  Deploy-DashboardWebConfig
# ============================================================================
function Deploy-DashboardWebConfig {
    <#
    .SYNOPSIS
        Ensures a web.config exists in the target directory that denies
        anonymous access, forcing WUG Forms authentication.
    .PARAMETER Path
        The dashboards directory where the web.config should be placed.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $webConfigPath = Join-Path $Path 'web.config'
    $webConfigContent = @'
<?xml version="1.0" encoding="UTF-8"?>
<!--
    Deployed by WhatsUpGoldPS dashboard helpers.
    Denies anonymous access so users must authenticate through the
    WhatsUp Gold web console before viewing dashboard reports.
    Delete this file to restore anonymous access to this folder.
-->
<configuration>
  <system.web>
    <authorization>
      <deny users="?" />
    </authorization>
    <customErrors mode="On">
      <error statusCode="401" redirect="/NmConsole" />
    </customErrors>
  </system.web>
</configuration>
'@

    try {
        $currentContent = $null
        if (Test-Path $webConfigPath) { $currentContent = [System.IO.File]::ReadAllText($webConfigPath) }
        if ($currentContent -ne $webConfigContent) {
            [System.IO.File]::WriteAllText($webConfigPath, $webConfigContent, (New-Object System.Text.UTF8Encoding $true))
            Write-Host "  Deployed web.config (WUG login required for dashboards)." -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "  Could not deploy web.config to ${Path}: $_"
    }
}

# ============================================================================
# region  Shared WUG push helpers
#
# The Setup-*-Discovery.ps1 scripts each grew their own copy of the connect,
# monitor-library, device-match and group-membership logic. These functions
# are the single implementation of those steps.
# ============================================================================

function Connect-WUGDiscoveryServer {
    <#
    .SYNOPSIS
        Connects to WhatsUp Gold for a discovery push, reusing an existing session.

    .DESCRIPTION
        Every discovery setup script repeated the same connect block. This is that
        block in one place: it keeps an existing session unless a different server
        is requested, and otherwise falls back to the vault.

    .PARAMETER WUGServer
        WhatsUp Gold server to connect to. Omit to reuse the current session or the vault entry.

    .PARAMETER WUGCredential
        Credential for the server. Omit to use the vault.

    .EXAMPLE
        Connect-WUGDiscoveryServer -WUGServer 'wug.contoso.com'
    #>
    [CmdletBinding()]
    param(
        [string]$WUGServer,
        [System.Management.Automation.PSCredential]$WUGCredential
    )

    $alreadyConnected = $global:WUGBearerHeaders -and $global:WhatsUpServerBaseURI
    if ($alreadyConnected -and -not $WUGServer) {
        Write-Verbose "Reusing existing WUG session: $($global:WhatsUpServerBaseURI)"
        return $true
    }

    try {
        if ($WUGServer -and $WUGCredential) {
            Connect-WUGServer -serverUri $WUGServer -Credential $WUGCredential -IgnoreSSLErrors -ErrorAction Stop | Out-Null
        }
        elseif ($WUGServer) {
            Connect-WUGServer -serverUri $WUGServer -IgnoreSSLErrors -ErrorAction Stop | Out-Null
        }
        else {
            Connect-WUGServer -AutoConnect -IgnoreSSLErrors -ErrorAction Stop | Out-Null
        }
        return $true
    }
    catch {
        Write-Error "Failed to connect to WhatsUp Gold: $_"
        return $false
    }
}

function Get-WUGMonitorLibraryMap {
    <#
    .SYNOPSIS
        Returns the WhatsUp Gold monitor library as a name-to-id hashtable.

    .DESCRIPTION
        The setup scripts searched the library once per monitor name, which costs one
        round trip per name and silently loses a name whenever a single search fails.
        This reads the whole library in one paged pass instead.

    .PARAMETER Type
        Which library to read: active or performance.

    .PARAMETER AsObject
        Return the full monitor object for each name instead of just its id. Use this
        when the caller needs property bags or other monitor details.

    .EXAMPLE
        $map = Get-WUGMonitorLibraryMap -Type active
        if ($map.ContainsKey('Ping')) { $id = $map['Ping'] }

    .EXAMPLE
        $lib = Get-WUGMonitorLibraryMap -Type performance -AsObject
        $bags = $lib['My Monitor'].propertyBags

    .OUTPUTS
        Hashtable of monitor name to monitor id, or to the monitor object when -AsObject
        is used. Throws if the library cannot be read, so callers never mistake a failed
        read for an empty library.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('active', 'performance')]
        [string]$Type,

        [switch]$AsObject
    )

    if (-not (Get-Command -Name 'Get-WUGAPIResponse' -ErrorAction SilentlyContinue)) {
        $apiResponsePath = Join-Path $PSScriptRoot '..\..\functions\Get-WUGAPIResponse.ps1'
        if (Test-Path $apiResponsePath) { . $apiResponsePath }
    }

    $map = @{}
    $pageId = $null
    $page = 0

    do {
        $uri = "$($global:WhatsUpServerBaseURI)/api/v1/monitors/-?type=$Type&view=details&includeDeviceMonitors=false&includeSystemMonitors=true&includeCoreMonitors=true&limit=250"
        if ($pageId) { $uri += "&pageId=$pageId" }

        $response = Get-WUGAPIResponse -Uri $uri -Method GET

        $monitors = @()
        if ($Type -eq 'active' -and $response.data.activeMonitors) { $monitors = @($response.data.activeMonitors) }
        elseif ($response.data.performanceMonitors) { $monitors = @($response.data.performanceMonitors) }
        elseif ($response.data.monitors) { $monitors = @($response.data.monitors) }

        foreach ($mon in $monitors) {
            $name = if ($mon.name) { $mon.name } elseif ($mon.Description) { $mon.Description } else { $null }
            $id = if ($mon.monitorId) { $mon.monitorId } elseif ($mon.id) { $mon.id } else { $null }
            if (-not $name -or $map.ContainsKey($name)) { continue }
            if ($AsObject) { $map[$name] = $mon }
            elseif ($id) { $map[$name] = $id }
        }

        $pageId = if ($response.paging) { $response.paging.nextPageId } else { $null }
        $page++
    } while ($pageId -and $page -lt 100)

    Write-Verbose "Read $($map.Count) $Type monitor(s) from the library in $page page(s)."
    return $map
}

function Find-WUGDiscoveryDeviceMatch {
    <#
    .SYNOPSIS
        Finds an existing WUG device by name or address.

    .DESCRIPTION
        Reports whether the lookup itself succeeded, which a bare device search cannot.
        Treating a failed search as "no match" is what makes a rerun create duplicates,
        so callers should check LookupFailed before creating anything.

    .PARAMETER Name
        Display name or host name to match.

    .PARAMETER Address
        IPv4 address to match.

    .PARAMETER AlternateName
        Additional display name to accept, such as a provider-suffixed name.

    .EXAMPLE
        $match = Find-WUGDiscoveryDeviceMatch -Name 'sql01' -Address '10.0.0.5'
        if ($match.LookupFailed) { return }
        if ($match.Device) { $id = $match.Device.id }

    .OUTPUTS
        PSCustomObject with Device (or $null), Found, and LookupFailed.
    #>
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$Address,
        [string]$AlternateName
    )

    $result = [PSCustomObject]@{
        Device       = $null
        Found        = $false
        LookupFailed = $false
        Error        = $null
    }

    $candidates = @()
    foreach ($term in @($Address, $Name)) {
        if ($term) { $candidates += $term }
    }
    if ($candidates.Count -eq 0) { return $result }

    foreach ($term in $candidates) {
        try {
            $searchResults = @(Get-WUGDevice -SearchValue $term -ErrorAction Stop)
        }
        catch {
            $result.LookupFailed = $true
            $result.Error = $_.Exception.Message
            Write-Warning "Device lookup failed for '$term': $($_.Exception.Message). Skipping rather than risking a duplicate."
            return $result
        }

        $match = $searchResults | Where-Object {
            ($Name -and ($_.displayName -eq $Name -or $_.hostName -eq $Name)) -or
            ($AlternateName -and $_.displayName -eq $AlternateName) -or
            ($Address -and $_.networkAddress -eq $Address)
        } | Select-Object -First 1

        if ($match) {
            $result.Device = $match
            $result.Found = $true
            return $result
        }
    }

    return $result
}

function Resolve-WUGDiscoveryTargetDevice {
    <#
    .SYNOPSIS
        Returns the WUG device ID for a discovery target, creating the device when it is missing.

    .DESCRIPTION
        Pre-checks by name and address (so reruns never duplicate), creates only IPv4
        targets that are absent, and optionally assigns a WUG credential. Returns $null
        when the lookup fails or the device cannot be created.

    .PARAMETER Target
        Host name or IPv4 address used for discovery.

    .PARAMETER Brand
        Brand to set when the device is created.

    .PARAMETER PrimaryRole
        Primary role to set when the device is created.

    .PARAMETER CredentialId
        Optional WUG credential ID to assign to the device.

    .PARAMETER Note
        Note applied when the device is created.

    .EXAMPLE
        $id = Resolve-WUGDiscoveryTargetDevice -Target '10.0.0.1' -Brand 'Cisco' -PrimaryRole 'Router'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target,

        [string]$Brand = 'Not Set',

        [string]$PrimaryRole = 'Device',

        [string]$CredentialId,

        [string]$Note = 'Added by WhatsUpGoldPS discovery.'
    )

    $match = Find-WUGDiscoveryDeviceMatch -Name $Target -Address $Target
    if ($match.LookupFailed) { return $null }

    $deviceId = $null
    if ($match.Found) {
        $deviceId = [int]$match.Device.id
        Write-Host "  [EXISTS] $Target (WUG ID $deviceId)" -ForegroundColor Gray
    }
    elseif ($Target -match '^\d{1,3}(\.\d{1,3}){3}$') {
        Write-Host "  [CREATE] $Target" -ForegroundColor Yellow
        $created = Add-WUGDeviceTemplate -displayName $Target -DeviceAddress $Target -Brand $Brand `
            -PrimaryRole $PrimaryRole -Note $Note -ErrorAction Stop
        if ($created.idMap) { $deviceId = [int]($created.idMap | Select-Object -First 1).resultId }
        if (-not $deviceId) {
            Write-Warning "  WUG did not return a device ID for $Target."
            return $null
        }
    }
    else {
        Write-Warning "  $Target is not in WUG and is not an IPv4 address; add it to WUG first."
        return $null
    }

    if ($CredentialId) {
        try {
            Set-WUGDeviceCredential -DeviceId ([string]$deviceId) -CredentialId $CredentialId -Assign -Confirm:$false -ErrorAction Stop | Out-Null
        }
        catch {
            if ($_.Exception.Message -notmatch 'already|assigned|exists|duplicate') {
                Write-Warning "  Could not assign credential $CredentialId to ${Target}: $_"
            }
        }
    }

    return $deviceId
}

function Sync-WUGDiscoveryDeviceGroup {
    <#
    .SYNOPSIS
        Ensures a root-level static group exists and contains the given devices.

    .DESCRIPTION
        Gives each provider one group to own, so a rescan can be issued once for the
        group instead of once per device. Existing membership is preserved; only
        missing devices are added.

    .PARAMETER Name
        Group name, by convention '<Provider>-WhatsUpGoldPS'.

    .PARAMETER DeviceId
        Device IDs that should belong to the group.

    .PARAMETER Description
        Description applied when the group is created.

    .EXAMPLE
        $group = Sync-WUGDiscoveryDeviceGroup -Name 'Proxmox-WhatsUpGoldPS' -DeviceId $ids
        if ($group.GroupId) { Invoke-WUGDeviceRefresh -GroupId $group.GroupId }

    .OUTPUTS
        PSCustomObject with GroupId, Created, Added, and Error.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [int[]]$DeviceId,

        [string]$Description
    )

    $result = [PSCustomObject]@{
        GroupId = $null
        Created = $false
        Added   = 0
        Error   = $null
    }

    if (-not $Description) { $Description = "Devices managed by WhatsUpGoldPS discovery ($Name)." }

    try {
        $matches = @(Get-WUGDeviceGroup -SearchValue $Name -GroupType all -View detail -ErrorAction Stop)
        $group = $matches | Where-Object { $_.Name -eq $Name -and $_.ParentGroupId -eq 0 } | Select-Object -First 1

        if ($group) {
            # The API filters on 'static_group' but reports the type back as 'static'.
            if ($group.GroupType -notmatch '^static') {
                throw "Group '$Name' exists but is a '$($group.GroupType)' group, not a static one."
            }
            $result.GroupId = [int]$group.Id
        }
        elseif ($PSCmdlet.ShouldProcess($Name, 'Create device group')) {
            $new = Add-WUGDeviceGroup -ParentGroupId 0 -Name $Name -Description $Description -Confirm:$false -ErrorAction Stop
            if ($new.id) {
                $result.GroupId = [int]$new.id
                $result.Created = $true
            }
        }

        if (-not $result.GroupId) { throw "Could not resolve the '$Name' group id." }

        if ($DeviceId -and $DeviceId.Count -gt 0) {
            $current = @(Get-WUGDeviceGroup -ConfigGroupId $result.GroupId -GroupDevices -GroupDevicesView id -ErrorAction Stop)
            $currentIds = @($current | ForEach-Object { [int]$_.id })
            $missing = @($DeviceId | Where-Object { $currentIds -notcontains $_ })

            if ($missing.Count -gt 0 -and $PSCmdlet.ShouldProcess($Name, "Add $($missing.Count) device(s)")) {
                # The endpoint returns HTTP 500 somewhere between 25 and 50 ids, and applies part
                # of the batch before failing, so requests are kept small and counted per batch.
                $batchSize = 25
                for ($i = 0; $i -lt $missing.Count; $i += $batchSize) {
                    $end = [Math]::Min($i + $batchSize - 1, $missing.Count - 1)
                    $batch = @($missing[$i..$end])
                    try {
                        Add-WUGDeviceGroupMember -GroupId $result.GroupId -DeviceId $batch -Confirm:$false -ErrorAction Stop | Out-Null
                        $result.Added += $batch.Count
                    }
                    catch {
                        Write-Warning "Could not add $($batch.Count) device(s) to '$Name': $($_.Exception.Message)"
                    }
                }

                if ($result.Added -lt $missing.Count) {
                    $verified = @(Get-WUGDeviceGroup -ConfigGroupId $result.GroupId -GroupDevices -GroupDevicesView id -ErrorAction SilentlyContinue |
                        ForEach-Object { [int]$_.id })
                    $result.Added = @($DeviceId | Where-Object { $verified -contains $_ }).Count
                }
            }
        }
    }
    catch {
        $result.Error = $_.Exception.Message
        Write-Warning "Could not prepare device group '$Name': $($_.Exception.Message)"
    }

    return $result
}

function Write-DiscoveryStats {
    <#
    .SYNOPSIS
        Prints a discovery push summary.

    .PARAMETER Stats
        Hashtable of counters collected during the push.

    .PARAMETER Title
        Heading shown above the counters.

    .EXAMPLE
        Write-DiscoveryStats -Stats $stats -Title 'Proxmox push complete'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Stats,

        [string]$Title = 'Summary'
    )

    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
    foreach ($key in ($Stats.Keys | Sort-Object)) {
        $value = $Stats[$key]
        $colour = if ($key -match 'Failed|Error' -and $value -gt 0) { 'Red' } else { 'White' }
        Write-Host ("  {0,-22}: {1}" -f $key, $value) -ForegroundColor $colour
    }
}

# endregion

# SIG # Begin signature block
# MIIr1gYJKoZIhvcNAQcCoIIrxzCCK8MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUB/KqcmQpTWuU+3mqznjiyXPo
# rwGggiUNMIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
# AQwFADB7MQswCQYDVQQGEwJHQjEbMBkGA1UECAwSR3JlYXRlciBNYW5jaGVzdGVy
# MRAwDgYDVQQHDAdTYWxmb3JkMRowGAYDVQQKDBFDb21vZG8gQ0EgTGltaXRlZDEh
# MB8GA1UEAwwYQUFBIENlcnRpZmljYXRlIFNlcnZpY2VzMB4XDTIxMDUyNTAwMDAw
# MFoXDTI4MTIzMTIzNTk1OVowVjELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDEtMCsGA1UEAxMkU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IFJvb3QgUjQ2MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAjeeUEiIE
# JHQu/xYjApKKtq42haxH1CORKz7cfeIxoFFvrISR41KKteKW3tCHYySJiv/vEpM7
# fbu2ir29BX8nm2tl06UMabG8STma8W1uquSggyfamg0rUOlLW7O4ZDakfko9qXGr
# YbNzszwLDO/bM1flvjQ345cbXf0fEj2CA3bm+z9m0pQxafptszSswXp43JJQ8mTH
# qi0Eq8Nq6uAvp6fcbtfo/9ohq0C/ue4NnsbZnpnvxt4fqQx2sycgoda6/YDnAdLv
# 64IplXCN/7sVz/7RDzaiLk8ykHRGa0c1E3cFM09jLrgt4b9lpwRrGNhx+swI8m2J
# mRCxrds+LOSqGLDGBwF1Z95t6WNjHjZ/aYm+qkU+blpfj6Fby50whjDoA7NAxg0P
# OM1nqFOI+rgwZfpvx+cdsYN0aT6sxGg7seZnM5q2COCABUhA7vaCZEao9XOwBpXy
# bGWfv1VbHJxXGsd4RnxwqpQbghesh+m2yQ6BHEDWFhcp/FycGCvqRfXvvdVnTyhe
# Be6QTHrnxvTQ/PrNPjJGEyA2igTqt6oHRpwNkzoJZplYXCmjuQymMDg80EY2NXyc
# uu7D1fkKdvp+BRtAypI16dV60bV/AK6pkKrFfwGcELEW/MxuGNxvYv6mUKe4e7id
# FT/+IAx1yCJaE5UZkADpGtXChvHjjuxf9OUCAwEAAaOCARIwggEOMB8GA1UdIwQY
# MBaAFKARCiM+lvEH7OKvKe+CpX/QMKS0MB0GA1UdDgQWBBQy65Ka/zWWSC8oQEJw
# IDaRXBeF5jAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zATBgNVHSUE
# DDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEMGA1Ud
# HwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwuY29tb2RvY2EuY29tL0FBQUNlcnRpZmlj
# YXRlU2VydmljZXMuY3JsMDQGCCsGAQUFBwEBBCgwJjAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuY29tb2RvY2EuY29tMA0GCSqGSIb3DQEBDAUAA4IBAQASv6Hvi3Sa
# mES4aUa1qyQKDKSKZ7g6gb9Fin1SB6iNH04hhTmja14tIIa/ELiueTtTzbT72ES+
# BtlcY2fUQBaHRIZyKtYyFfUSg8L54V0RQGf2QidyxSPiAjgaTCDi2wH3zUZPJqJ8
# ZsBRNraJAlTH/Fj7bADu/pimLpWhDFMpH2/YGaZPnvesCepdgsaLr4CnvYFIUoQx
# 2jLsFeSmTD1sOXPUC4U5IOCFGmjhp0g4qdE2JXfBjRkWxYhMZn0vY86Y6GnfrDyo
# XZ3JHFuu2PMvdM+4fvbXg50RlmKarkUT2n/cR/vfw1Kf5gZV6Z2M8jpiUbzsJA8p
# 1FiAhORFe1rYMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG
# 9w0BAQwFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkw
# FwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1
# cmVkIElEIFJvb3QgQ0EwHhcNMjIwODAxMDAwMDAwWhcNMzExMTA5MjM1OTU5WjBi
# MQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3
# d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3Qg
# RzQwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC/5pBzaN675F1KPDAi
# MGkz7MKnJS7JIT3yithZwuEppz1Yq3aaza57G4QNxDAf8xukOBbrVsaXbR2rsnny
# yhHS5F/WBTxSD1Ifxp4VpX6+n6lXFllVcq9ok3DCsrp1mWpzMpTREEQQLt+C8weE
# 5nQ7bXHiLQwb7iDVySAdYyktzuxeTsiT+CFhmzTrBcZe7FsavOvJz82sNEBfsXpm
# 7nfISKhmV1efVFiODCu3T6cw2Vbuyntd463JT17lNecxy9qTXtyOj4DatpGYQJB5
# w3jHtrHEtWoYOAMQjdjUN6QuBX2I9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsD
# dV14Ztk6MUSaM0C/CNdaSaTC5qmgZ92kJ7yhTzm1EVgX9yRcRo9k98FpiHaYdj1Z
# XUJ2h4mXaXpI8OCiEhtmmnTK3kse5w5jrubU75KSOp493ADkRSWJtppEGSt+wJS0
# 0mFt6zPZxd9LBADMfRyVw4/3IbKyEbe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hk
# pjPRiQfhvbfmQ6QYuKZ3AeEPlAwhHbJUKSWJbOUOUlFHdL4mrLZBdd56rF+NP8m8
# 00ERElvlEFDrMcXKchYiCd98THU/Y+whX8QgUWtvsauGi0/C1kVfnSD8oR7FwI+i
# sX4KJpn15GkvmB0t9dmpsh3lGwIDAQABo4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB
# /zAdBgNVHQ4EFgQU7NfjgtJxXWRM3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAUReui
# r/SSy4IxLVGLp6chnfNtyA8wDgYDVR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0w
# azAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUF
# BzAChjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVk
# SURSb290Q0EuY3J0MEUGA1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAowCDAG
# BgRVHSAAMA0GCSqGSIb3DQEBDAUAA4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9
# mqyhhyzshV6pGrsi+IcaaVQi7aSId229GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxS
# A8hO0Cre+i1Wz/n096wwepqLsl7Uz9FDRJtDIeuWcqFItJnLnU+nBgMTdydE1Od/
# 6Fmo8L8vC6bp8jQ87PcDx4eo0kxAGTVGamlUsLihVo7spNU96LHc/RzY9HdaXFSM
# b++hUD38dglohJ9vytsgjTVgHAIDyyCwrFigDkBjxZgiwbJZ9VVrzyerbHbObyMt
# 9H5xaiNrIv8SuFQtJ37YOtnwtoeW/VvRXKwYw02fc7cBqZ9Xql4o4rmUMIIGGjCC
# BAKgAwIBAgIQYh1tDFIBnjuQeRUgiSEcCjANBgkqhkiG9w0BAQwFADBWMQswCQYD
# VQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMS0wKwYDVQQDEyRTZWN0
# aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAw
# WhcNMzYwMzIxMjM1OTU5WjBUMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGln
# byBMaW1pdGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcg
# Q0EgUjM2MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAmyudU/o1P45g
# BkNqwM/1f/bIU1MYyM7TbH78WAeVF3llMwsRHgBGRmxDeEDIArCS2VCoVk4Y/8j6
# stIkmYV5Gej4NgNjVQ4BYoDjGMwdjioXan1hlaGFt4Wk9vT0k2oWJMJjL9G//N52
# 3hAm4jF4UjrW2pvv9+hdPX8tbbAfI3v0VdJiJPFy/7XwiunD7mBxNtecM6ytIdUl
# h08T2z7mJEXZD9OWcJkZk5wDuf2q52PN43jc4T9OkoXZ0arWZVeffvMr/iiIROSC
# zKoDmWABDRzV/UiQ5vqsaeFaqQdzFf4ed8peNWh1OaZXnYvZQgWx/SXiJDRSAolR
# zZEZquE6cbcH747FHncs/Kzcn0Ccv2jrOW+LPmnOyB+tAfiWu01TPhCr9VrkxsHC
# 5qFNxaThTG5j4/Kc+ODD2dX/fmBECELcvzUHf9shoFvrn35XGf2RPaNTO2uSZ6n9
# otv7jElspkfK9qEATHZcodp+R4q2OIypxR//YEb3fkDn3UayWW9bAgMBAAGjggFk
# MIIBYDAfBgNVHSMEGDAWgBQy65Ka/zWWSC8oQEJwIDaRXBeF5jAdBgNVHQ4EFgQU
# DyrLIIcouOxvSK4rVKYpqhekzQwwDgYDVR0PAQH/BAQDAgGGMBIGA1UdEwEB/wQI
# MAYBAf8CAQAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwGwYDVR0gBBQwEjAGBgRVHSAA
# MAgGBmeBDAEEATBLBgNVHR8ERDBCMECgPqA8hjpodHRwOi8vY3JsLnNlY3RpZ28u
# Y29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYuY3JsMHsGCCsGAQUF
# BwEBBG8wbTBGBggrBgEFBQcwAoY6aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0
# aWdvUHVibGljQ29kZVNpZ25pbmdSb290UjQ2LnA3YzAjBggrBgEFBQcwAYYXaHR0
# cDovL29jc3Auc2VjdGlnby5jb20wDQYJKoZIhvcNAQEMBQADggIBAAb/guF3YzZu
# e6EVIJsT/wT+mHVEYcNWlXHRkT+FoetAQLHI1uBy/YXKZDk8+Y1LoNqHrp22AKMG
# xQtgCivnDHFyAQ9GXTmlk7MjcgQbDCx6mn7yIawsppWkvfPkKaAQsiqaT9DnMWBH
# VNIabGqgQSGTrQWo43MOfsPynhbz2Hyxf5XWKZpRvr3dMapandPfYgoZ8iDL2OR3
# sYztgJrbG6VZ9DoTXFm1g0Rf97Aaen1l4c+w3DC+IkwFkvjFV3jS49ZSc4lShKK6
# BrPTJYs4NG1DGzmpToTnwoqZ8fAmi2XlZnuchC4NPSZaPATHvNIzt+z1PHo35D/f
# 7j2pO1S8BCysQDHCbM5Mnomnq5aYcKCsdbh0czchOm8bkinLrYrKpii+Tk7pwL7T
# jRKLXkomm5D1Umds++pip8wH2cQpf93at3VDcOK4N7EwoIJB0kak6pSzEu4I64U6
# gZs7tS/dGNSljf2OSSnRr7KWzq03zl8l75jy+hOds9TWSenLbjBQUGR96cFr6lEU
# fAIEHVC1L68Y1GGxx4/eRI82ut83axHMViw1+sVpbPxg51Tbnio1lB93079WPFnY
# aOvfGAA0e0zcfF/M9gXr+korwQTh2Prqooq2bYNMvUoUKD85gnJ+t0smrWrb8dee
# 2CvYZXD5laGtaAxOfy/VKNmwuWuAh9kcMIIGPjCCBKagAwIBAgIQB5zg5NEUf4XN
# OXPPdi036zANBgkqhkiG9w0BAQwFADBUMQswCQYDVQQGEwJHQjEYMBYGA1UEChMP
# U2VjdGlnbyBMaW1pdGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1YmxpYyBDb2RlIFNp
# Z25pbmcgQ0EgUjM2MB4XDTI2MDIwOTAwMDAwMFoXDTI5MDQyMTIzNTk1OVowVTEL
# MAkGA1UEBhMCVVMxFDASBgNVBAgMC0Nvbm5lY3RpY3V0MRcwFQYDVQQKDA5KYXNv
# biBBbGJlcmlubzEXMBUGA1UEAwwOSmFzb24gQWxiZXJpbm8wggIiMA0GCSqGSIb3
# DQEBAQUAA4ICDwAwggIKAoICAQDzemjeAdcmFpCOW+UwY9yNFVf6XhE6x2+hGOAR
# xsbfAKfnk/lqRKSchLUWD8RJjSS9wN/AZIO5sMzxN/9TSue9GQQrgY0gJ+JkgyIC
# Ll2Z78gTvVtTkLOXeuzJSS1ABLn5dfLTq90k9Q3jvYEo0EgBOTapdEA8T55vdzmQ
# aJ/hc9wphPs9zMAHtoeCnbUQJwqsDPv1e4gXW8PiTsaJacfu0VYxsj66ExDSBt6X
# v4Srz2+dNZX/LgQAAy3Y2a+YqfLyFm3/Oe2MNQbtdJ1SOx1t3hPApef/3da4mx5c
# 080C37bVvpPg2hbCmQQS+epeGAJSFUbKzohNZHR2GMeiBqxAPNPUe/k2QPQ8xqsh
# Yr/apiQGy+Hw8HrQ3siKvjs7c9S7xHcvEXHdCQWPieEtHgxBSAN19DfFXC3gMGmy
# m/QI7pSl8FHqgiS7ze/QifdFE2W9viPrWpo9HZ/iCjBLCeL+BoMe9rMRa/ful84q
# HbU4OS7n9sXevj4YWpjsRdqcfSzm4QSyxDMkbAh2SM1WThSrvQaR0B+7nxgfkmvN
# E5YtP+ixMp/fmzGFotrbZ+pSzj04VzIkGqKEVKuqtrt/heEmj5cVRSyOziVTIWq+
# p1uo6AbxC0yT5gDUjIw0kRQ3x0QnRm2bC/5HhCyTcvo2XLRelb8UBIxTPP22s7uq
# mIawOwIDAQABo4IBiTCCAYUwHwYDVR0jBBgwFoAUDyrLIIcouOxvSK4rVKYpqhek
# zQwwHQYDVR0OBBYEFOmBdKNA+QFYSh21aHK/BmkiAYmwMA4GA1UdDwEB/wQEAwIH
# gDAMBgNVHRMBAf8EAjAAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMEoGA1UdIARDMEEw
# NQYMKwYBBAGyMQECAQMCMCUwIwYIKwYBBQUHAgEWF2h0dHBzOi8vc2VjdGlnby5j
# b20vQ1BTMAgGBmeBDAEEATBJBgNVHR8EQjBAMD6gPKA6hjhodHRwOi8vY3JsLnNl
# Y3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ0NBUjM2LmNybDB5Bggr
# BgEFBQcBAQRtMGswRAYIKwYBBQUHMAKGOGh0dHA6Ly9jcnQuc2VjdGlnby5jb20v
# U2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FSMzYuY3J0MCMGCCsGAQUFBzABhhdo
# dHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAYEABCLJuMZz
# nf7WTFaysIt3aAF7wsDgP0WEJxSQ+0f20kEbt8FxCuKPUiHn8ntfAf6uH4QZITQC
# bhL00ABn6m26caMNNyeT6w06dVjwlm1yl/Ds/bxliRcicURn7ZHc2eeyRNNLMpxD
# EvFwsCzvT99jMkfWfVEa6Yizyfa0I3xzG9QVHb2jWsqJpu2liwJw/l+45uqPLDU+
# QJ9XMBAKG+6G1gzOrF/d8KYcCTQSQLLR/Ts7Oi8CEjl+rCkuwipvTdyqfITlLntG
# RwLWXRZeqObtdsMvs84nhhCOdHypze+xXzShTlipUujicJQK3GxXoAeSvPS3BOYj
# UpmjN1TAdgA1dRRHIxkh8OJU4NVsfljADHZf+5273xcSfbrubTYk+eAdLPpWTvx8
# 7cF2EFHM3bBaJ96Y7Da7JPWZWpQYuUh5CLvheoO7VohL967VQKZiUZy5FK9l6tmu
# J27JVAreIyrOVF+FdZ0l/DjPvgF6MlRjvok4+8/qZelxPRsP03eliiirMIIGtDCC
# BJygAwIBAgIQDcesVwX/IZkuQEMiDDpJhjANBgkqhkiG9w0BAQsFADBiMQswCQYD
# VQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGln
# aWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwHhcN
# MjUwNTA3MDAwMDAwWhcNMzgwMTE0MjM1OTU5WjBpMQswCQYDVQQGEwJVUzEXMBUG
# A1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQg
# RzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExMIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtHgx0wqYQXK+PEbAHKx126NGaHS0URed
# Ta2NDZS1mZaDLFTtQ2oRjzUXMmxCqvkbsDpz4aH+qbxeLho8I6jY3xL1IusLopuW
# 2qftJYJaDNs1+JH7Z+QdSKWM06qchUP+AbdJgMQB3h2DZ0Mal5kYp77jYMVQXSZH
# ++0trj6Ao+xh/AS7sQRuQL37QXbDhAktVJMQbzIBHYJBYgzWIjk8eDrYhXDEpKk7
# RdoX0M980EpLtlrNyHw0Xm+nt5pnYJU3Gmq6bNMI1I7Gb5IBZK4ivbVCiZv7PNBY
# qHEpNVWC2ZQ8BbfnFRQVESYOszFI2Wv82wnJRfN20VRS3hpLgIR4hjzL0hpoYGk8
# 1coWJ+KdPvMvaB0WkE/2qHxJ0ucS638ZxqU14lDnki7CcoKCz6eum5A19WZQHkqU
# JfdkDjHkccpL6uoG8pbF0LJAQQZxst7VvwDDjAmSFTUms+wV/FbWBqi7fTJnjq3h
# j0XbQcd8hjj/q8d6ylgxCZSKi17yVp2NL+cnT6Toy+rN+nM8M7LnLqCrO2JP3oW/
# /1sfuZDKiDEb1AQ8es9Xr/u6bDTnYCTKIsDq1BtmXUqEG1NqzJKS4kOmxkYp2WyO
# Di7vQTCBZtVFJfVZ3j7OgWmnhFr4yUozZtqgPrHRVHhGNKlYzyjlroPxul+bgIsp
# zOwbtmsgY1MCAwEAAaOCAV0wggFZMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0O
# BBYEFO9vU0rp5AZ8esrikFb2L9RJ7MtOMB8GA1UdIwQYMBaAFOzX44LScV1kTN8u
# Zz/nupiuHA9PMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDCDB3
# BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0
# LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDov
# L2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmwwIAYD
# VR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4IC
# AQAXzvsWgBz+Bz0RdnEwvb4LyLU0pn/N0IfFiBowf0/Dm1wGc/Do7oVMY2mhXZXj
# DNJQa8j00DNqhCT3t+s8G0iP5kvN2n7Jd2E4/iEIUBO41P5F448rSYJ59Ib61eoa
# lhnd6ywFLerycvZTAz40y8S4F3/a+Z1jEMK/DMm/axFSgoR8n6c3nuZB9BfBwAQY
# K9FHaoq2e26MHvVY9gCDA/JYsq7pGdogP8HRtrYfctSLANEBfHU16r3J05qX3kId
# +ZOczgj5kjatVB+NdADVZKON/gnZruMvNYY2o1f4MXRJDMdTSlOLh0HCn2cQLwQC
# qjFbqrXuvTPSegOOzr4EWj7PtspIHBldNE2K9i697cvaiIo2p61Ed2p8xMJb82Yo
# sn0z4y25xUbI7GIN/TpVfHIqQ6Ku/qjTY6hc3hsXMrS+U0yy+GWqAXam4ToWd2UQ
# 1KYT70kZjE4YtL8Pbzg0c1ugMZyZZd/BdHLiRu7hAWE6bTEm4XYRkA6Tl4KSFLFk
# 43esaUeqGkH/wyW4N7OigizwJWeukcyIPbAvjSabnf7+Pu0VrFgoiovRDiyx3zEd
# mcif/sYQsfch28bZeUz2rtY/9TCA6TD8dC3JE3rYkrhLULy7Dc90G6e8BlqmyIjl
# gp2+VqsS9/wQD7yFylIz0scmbKvFoW2jNrbM1pD2T7m3XDCCBu0wggTVoAMCAQIC
# EAhP3DNPfkVO28MPj/mSGDUwDQYJKoZIhvcNAQELBQAwaTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTAeFw0y
# NjA4MDUwMDAwMDBaFw0zNzExMDQyMzU5NTlaMGMxCzAJBgNVBAYTAlVTMRcwFQYD
# VQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgU0hBMjU2IFJT
# QTQwOTYgVGltZXN0YW1wIFJlc3BvbmRlciAyMDI2IDEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQC2e6byyf7NSvjUm0xls/04xjD4fAkOkbnGQi7+Wpx8
# 1iYxfzViaxSIctuH3KSl5YEYpMuFgGsA31N2D9ATMbfZdw5uaAhuWevQKhDdZIB4
# NnqcfpfpWQXJiQnDdAElETC+bhSEvNLGbA8DtwUpFMQ4yyYQSPqomT92osQAv6hB
# i47ATZS6JfVWe6XxhF4jJZ3iSAuf2Cros1czRSmWRHqMv9AfGZvp8ygYElhudpQj
# tcPpwoOl6QrZJUyV3iINvN4cO05prGV0fkjG426xDr2d3z9lcSIHkdvGPdGUrXdx
# fVbgOUVcp2/8ISEzwKPW++Wa+E2ujI91EZtukGWDJ/xZ27k3oHKEXBRGfRTqjOU+
# jE3ba/5++JSE/7oNHnjs5mekExYN96LV/mxUbCKJb8pBNY4r3uD7hEmk/M81XhVg
# wDA7aMzYC3LZBg9WY5BMmbSay5ecmtJuXaB/0nKWmQmVZeqTVDgsmzHP5MQuhAJk
# iWNuC9MmCg9TZHXbJ2/yLVSov9p16UDTLtT0+aa1vN71fHeu1qMLlLNB3WOB/ADC
# xr3S/1hxI92Z6jKgEED/btwIvbfuXkNNhg8MtDg43c4tMZae9FvqMOt/9PvmAxF9
# TNIsIFB8G6yb36ZJZGUL8N/pL971DyLXcK6HM5PYnH5X+eVtczhCgHCVQCF6XDAl
# PQIDAQABo4IBlTCCAZEwDAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQUFMljijAu1Er7
# bpTz5uNAfvXszeIwHwYDVR0jBBgwFoAU729TSunkBnx6yuKQVvYv1Ensy04wDgYD
# VR0PAQH/BAQDAgeAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMIGVBggrBgEFBQcB
# AQSBiDCBhTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMF0G
# CCsGAQUFBzAChlFodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5jcnQwXwYD
# VR0fBFgwVjBUoFKgUIZOaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEuY3JsMCAG
# A1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOC
# AgEAjcU6YR6dUgrfmawJgH59KECxa9Ji8sEi2g10CBDaMiqsaxWyW5cwlT/6ZF5s
# FznazqVsoC85U9dqLOYqQwst+UQQoNlDHgKRLa3xoc+OReFreFhnTXSG0Vrd2E2C
# ZqUfm+5a+He1MJ/h+tNLuA+0Zzhn/Fo+FDYAHWZHx4R79ZsfRFYe9UiXpXBDf6Dk
# Uo183Y38NYmR/XfDYf7YZ+oR9t3flbDwK+hgGMs0gNNp1w9Z2CyOyI5or/sSwomA
# uNQ0hWC9xoU4stD8aWsD7RkcmgVRs6vlIk3zPKQ+ylcheWkMlj+CoVRlFE55pv0Z
# WCaFt04lwP/rdGHE9qEVQZtyRE42ox7oNgC/r+Y4bSlZ3dw9K2x1xLtu6PkPKeLB
# FjzKigwfqm3Hm+k/+lnME8F5kPZTgiy2HLEHklpryqs6QHnPXrRNeIzkAMyylnRN
# 8P0wmirS0WkU+ywpEWFZ4QNg+9xS43tTuW9x0eXh7NDc1P/sV+zWxHXKH8tFt1nc
# HdVzqrZaYPyYMLSn2TOXajveJW1L3joiQSPsWRGxkbDDW15jERFE4LvjnGu2O9zD
# 1nLJSMdlYZEikl4w2w+q4IN/R+TIe0H4ngCI1moJCTbevGH4punIxM1Uoi0nmX3Z
# K+XbRT01uowE5ViXWHng0RgsmrX/EdYUo80r3TfMlkD0/YMxggYzMIIGLwIBATBo
# MFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNV
# BAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYCEAec4OTRFH+F
# zTlzz3YtN+swCQYFKw4DAhoFAKB4MBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAw
# GQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisG
# AQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFINQs71exRegH7CHSqd7yKVp+RBsMA0G
# CSqGSIb3DQEBAQUABIICAGLcLAHTkAL4+KMyncJIMe1+2YAhJAPTCyzNP5UtY3e8
# USb9RHvc583IXJ2FKl7mnXCjTvCGa1InEnHAEqeo553P0lZVV0dS2XnzjQv7hLmZ
# rkZEe88YW8Is8R2EQVj5quV1S/NUkruyKAsSVJczmtuqRE+sP1mZi3D1rAEFA8po
# f3OmUka64ucdz2S5OAJgX+8tRs0NwUDkZL9U3gve1UEtM7z1yVb+UrsZpP5uPUob
# krXEUuSPtqo8TK8jgUM/8X3HYfg5XSXg2BtSlNTzB8qixwRfiRL/rhd1AHEUoya5
# ew3OpcF5L426OaPf7AcYxw/4l40fOGAH9T929OMb8vO4Ds8dRuY5CAmsyaa5tGDl
# m7mFY0/VO8g3e6AfdipmbRHGFRxSR7QpvQSgwD0OAQYTVmAXYH3G8QxVnCDQDuZF
# HgEc0K4t633L/5P/f7dWq9n7f0G90nK6xudgV+Qn6eQp1Q8Y5e20VHUNIg13F5xc
# Ad2Ytr4BGVqU9SBin1Qacg+a7MdRyq/hsvYdwHCV47f0ovd0lB7o3uZ5XlvaSNRo
# 4teZXQ1SVFVlZ1mVUOn+/rBduu3BMMD2AIR3iGWeEXzi4+xs9vDzwglu1YQ4Dp4m
# dW+aN7n8y//LIXaULEQHn1fu343I3MoeJcNUPJYQdfK6BrktGtGqFxUy2n2o8GWt
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCE/c
# M09+RU7bww+P+ZIYNTANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDkzMDIzMDIwNVowLwYJKoZIhvcN
# AQkEMSIEIJP0o0k5j1Vp0Zw7RduJ+0Z22OniooP8dyqt585c3LAXMA0GCSqGSIb3
# DQEBAQUABIICABtHmfRqLdl0LBZk/m4rk0M3NagrpxvjcjVlug5UlUAlEiDJ4ihD
# HCMmTg1hEsYjePjW9J+vEgyec8zdrPN6ficjDbx6qDaIhW3X8ca+IxWYJdhRVGqh
# y4zaa5jUtjHiHdLWgqrhVYc8jttP383l58VR5IjQcP6xeOdhU/1ZZ0NaV1NithdA
# SjJmHrOTUoVyCcRMboRyBJmuUNzaZ26zolp0v2A0QA2r8Onie3ZHc+IColfA5sga
# KhN2mto5TK+UiPD/0OtSuhiAE3TAZw1PGkCo5XhGPJ2/Jhf7FguOsGM6nqe/Ul6l
# PfNgM4m6aU29h3ix7OYmql4DI5QNU6MoKVhc0HlrSLe7pOui7XxHpv1MnnhyEP6E
# vB87tTBfU2ef+RbpY13ejrKEoBFxbHMQ80GOJKTJSinCX+yAecqcC0g7CGGYiie+
# q75PdUWVf7fg0gtqPULYM+cUjDbIuhQ+NH4p3yik7QMG/kJjvumDGTtqjbGi1c5C
# hOlSF7Kr5d19sVtqJ2fA1+WJyMFemBXoZG3wmgudJ7L25CaTTvtDr4dVH3O/PdHe
# aDlrfUx5fMT73DCeK/+Rp8FY33gk2jw+WazqWTirYRQ35nc62K4mOaR4iZo2w7+3
# /d2Jo380QeU0+rMLCJclNikCniILqJssZVZCxsCYfLHwIyEzpPMPlzk+
# SIG # End signature block
