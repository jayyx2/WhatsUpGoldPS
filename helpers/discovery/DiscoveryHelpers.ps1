<#
.SYNOPSIS
    Standalone discovery framework for infrastructure device APIs.
    Optionally provisions WUG REST API monitors when WhatsUpGoldPS is available.

.DESCRIPTION
    DiscoveryHelpers is a portable, WUG-independent framework that discovers
    monitorable items from infrastructure device APIs (F5, Fortinet, etc.).
    It can run anywhere PowerShell 5.1+ runs — no WhatsUp Gold required.

    Two operating modes:

    === Standalone Mode (no WUG) ===

      1. Register-DiscoveryProvider  — Register a technology provider
      2. Invoke-Discovery            — Discover items from target hosts
      3. Export-DiscoveryPlan        — Output plan as JSON, CSV, or objects
         (or just pipe to Format-Table, Out-GridView, etc.)

      Use this mode for:
        - Inventory / audit scripts that run anywhere
        - Feeding results into other monitoring systems (Zabbix, PRTG, etc.)
        - CI/CD pipelines that validate infrastructure
        - Standalone reporting without any NMS dependency

    === WUG Integration Mode ===

      4. Invoke-WUGDiscovery         — Discover from WUG-registered devices
      5. Invoke-WUGDiscoverySync     — Create WUG REST API monitors from plan
      6. New-WUGDiscoveryCredential  — Store API creds in WUG credential store

      Use this mode when WhatsUpGoldPS is loaded and connected.

    Provider Pattern:
      Each technology registers a provider with:
        - Name           — Unique identifier (e.g., 'F5', 'Fortinet')
        - MatchAttribute — WUG device attribute for auto-matching (WUG mode only)
        - DiscoverScript — ScriptBlock that receives a context hashtable and
                           returns discovered item objects
        - DefaultPort    — Default API port (443)
        - DefaultProtocol— Default protocol ('https')

    The DiscoverScript receives a context with:
        DeviceId, DeviceName, DeviceIP, BaseUri, Port, Protocol,
        ProviderName, AttributeValue, ExistingMonitors, IgnoreCertErrors

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: PowerShell 5.1+
    Optional: WhatsUpGoldPS module (for WUG integration mode only)
    Encoding: UTF-8 with BOM
    Standalone: Yes — core discovery functions have zero external dependencies.

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
# region  Provider Registry (Standalone — no WUG dependency)
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

        This function has zero WUG dependencies — it just stores the provider
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
        'BasicAuth' — requires username + password (e.g., F5 iControl).
        'BearerToken' — requires a single API token (e.g., FortiGate).
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
        # Search all devices — get ALL devices and filter by attribute
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
# region  Discovered Item Schema (Standalone — no WUG dependency)
# ============================================================================

function New-DiscoveredItem {
    <#
    .SYNOPSIS
        Creates a standardized discovered-item object for the monitor plan.
    .DESCRIPTION
        Each provider's DiscoverScript should return one or more of these
        objects. They describe what should be monitored and how.

        In standalone mode, these are pure data objects — inspect, filter,
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
        Provide target hosts directly — no WUG device database needed.

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
        # Discover F5 load balancers — no WUG needed
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

        No WUG dependency — works anywhere.
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
# region  DPAPI Credential Vault (Standalone — Windows only, no WUG dependency)
# ============================================================================

# Default vault directory: per-user, under the user's profile
$script:DiscoveryVaultPath = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Vault'

# Optional AES vault password (set via Set-DiscoveryVaultPassword)
$script:VaultAESKey = $null

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

    Write-Verbose "Vault password set — AES-256 layer enabled for this session."
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
            $ss = ConvertTo-SecureString -String $encrypted
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
    $encrypted = ConvertFrom-SecureString -SecureString $ss
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

        SINGLE SECRET (default — backward compatible):
          A single API token, password, or other secret string.
          Use -Secret or -SecureSecret.

        MULTI-FIELD BUNDLE (-Fields):
          Multiple named fields, each individually encrypted.
          Ideal for Azure (TenantId, ClientId, ClientSecret), OAuth2
          flows, database connections, etc.
          Use -Fields with a hashtable of name=SecureString pairs,
          or use Request-DiscoveryCredential which prompts for each field.

        Encryption layers applied:
          1. DPAPI (CurrentUser scope) — tied to Windows user + machine
          2. AES-256 (optional) — if Set-DiscoveryVaultPassword was called

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
        SECURITY: DPAPI CurrentUser scope — decryptable only by the same
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
            $fieldEncrypted = ConvertFrom-SecureString -SecureString $fieldSS
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
        $dpapi = ConvertFrom-SecureString -SecureString $ss
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
    $integrityInput = "$integritySource|$($env:COMPUTERNAME)|$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
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
        # Bundle — get all fields as a hashtable
        $azure = Get-DiscoveryCredential -Name 'Azure-Prod'
        $azure.TenantId
        $azure.ClientSecret
    .EXAMPLE
        # Bundle — get one field
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
        $integrityInput = "$integritySource|$($env:COMPUTERNAME)|$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
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
                $fieldSS = ConvertTo-SecureString -String $dpapiData
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
                    $fieldSS = ConvertTo-SecureString -String $dpapiData
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
            $ss = ConvertTo-SecureString -String $dpapiData
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
        # Single secret — API token
        Request-DiscoveryCredential -Name 'FortiGate-FW1' -Description 'FW1 API token'
    .EXAMPLE
        # Multi-field — Azure service principal
        Request-DiscoveryCredential -Name 'Azure-Prod' `
            -Fields 'TenantId','ClientId','ClientSecret' `
            -ExpiresInDays 365 -Description 'Azure SP for monitoring'
    .EXAMPLE
        # Multi-field — Database connection
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
    Write-Host "All input is masked — secrets will NOT appear on screen." -ForegroundColor Cyan

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
            Write-Error "Verification failed — credential was saved but could not be read back."
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
        Write-Error "Verification failed — credential was saved but could not be read back."
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
        Smart credential resolver — loads from vault, shows preview, prompts
        if missing, saves new creds back to vault. One function for everything.
    .DESCRIPTION
        Replaces the 40+ line copy-paste pattern in every Setup script with a
        single call. Handles all credential types:

          AWSKeys      — Access Key ID + Secret Access Key
          AzureSP      — Tenant ID + Application ID + Client Secret
          BearerToken  — Single API token (Proxmox, Fortinet, etc.)
          PSCredential — Username + Password (F5, HyperV, VMware, etc.)
          WUGServer    — WhatsUp Gold server connection info (host, port, protocol, creds)

        Flow:
          1. Check vault for existing credential → show safe preview
          2. Prompt: [Y]es use it / [R]eset / [N]o skip
          3. If missing or reset: prompt for new values per CredType
          4. Save to vault and return the credential
             (unless -DeferSave is set — caller validates first, then saves)

        Returns:
          PSCredential  — for AWSKeys / AzureSP / PSCredential types
          String        — for BearerToken type
          Hashtable     — for WUGServer type (Server, Port, Protocol, Credential, IgnoreSSL)
          $null         — if skipped, cancelled, or non-interactive with no vault entry

    .PARAMETER Name
        Vault credential name (e.g., 'AWS.Credential', 'Proxmox.192.168.1.39.Token').
    .PARAMETER CredType
        Credential type: 'AWSKeys', 'AzureSP', 'BearerToken', 'PSCredential'.
        If omitted, auto-detected from the Name pattern.
    .PARAMETER ProviderLabel
        Friendly label for prompts (e.g., 'AWS', 'Proxmox'). Defaults to Name.
    .PARAMETER DeferSave
        Don't save new credentials to vault. The caller should validate the
        credential works first, then call Save-ResolvedCredential to persist.
    .PARAMETER NonInteractive
        Skip prompts entirely — return vault data or $null.
    .PARAMETER AutoUse
        When $true, skip the Y/R/N prompt and auto-use existing vault creds.
        Still prompts if vault is empty. Default: $false.
    .EXAMPLE
        # AWS — prompts for Access Key + Secret if not in vault
        $cred = Resolve-DiscoveryCredential -Name 'AWS.Credential' -CredType AWSKeys
        # Returns PSCredential: UserName=AccessKey, Password=SecretKey

    .EXAMPLE
        # Azure — auto-discover vault name from existing entries
        $cred = Resolve-DiscoveryCredential -Name 'Azure' -CredType AzureSP
        # Returns PSCredential: UserName="TenantId|AppId", Password=ClientSecret

    .EXAMPLE
        # Proxmox — existing token from vault, auto-use
        $token = Resolve-DiscoveryCredential -Name 'Proxmox.192.168.1.39.Token' -AutoUse

    .EXAMPLE
        # WUG Server — all connection info from vault
        $wug = Resolve-DiscoveryCredential -Name 'WUG.Server' -CredType WUGServer
        # Returns hashtable: Server, Port, Protocol, Credential, IgnoreSSL

    .EXAMPLE
        # DeferSave — validate before persisting
        $cred = Resolve-DiscoveryCredential -Name 'WUG.Server' -CredType WUGServer -DeferSave
        if (Test-Connection $cred.Server) { Save-ResolvedCredential -Name 'WUG.Server' -Value $cred }

    .EXAMPLE
        # Non-interactive — return vault data or nothing
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
        [ValidateSet('AWSKeys', 'AzureSP', 'BearerToken', 'PSCredential', 'WUGServer')]
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
        elseif ($Name -match '\.Token$|^FortiGate')        { $CredType = 'BearerToken' }
        elseif ($Name -match '^WUG\.Server')                { $CredType = 'WUGServer' }
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
            'WUGServer' {
                if ($stored -is [string] -and $stored -match '\|') {
                    $wp = $stored -split '\|', 5
                    "Server=$($wp[0]):$($wp[1]) ($($wp[2])), User=$($wp[3])"
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
        'PSCredential' {
            Write-Host ''
            $cred = Get-Credential -Message "$ProviderLabel credentials"
            if (-not $cred) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }
            if (-not $DeferSave) {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
                try { $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
                finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

                $combined = "$($cred.UserName)|$plainPwd"
                $ss = ConvertTo-SecureString $combined -AsPlainText -Force
                Save-DiscoveryCredential -Name $VaultName -SecureSecret $ss `
                    -Description "$ProviderLabel ($($cred.UserName))" -Force | Out-Null
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
            $cred = Get-Credential -Message "WhatsUp Gold credentials for $srv"
            if (-not $cred) {
                Write-Host '  Cancelled.' -ForegroundColor DarkGray; return $null
            }
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
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
                try { $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
                finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
                $combined = "$srv|$port|$proto|$($cred.UserName)|$plainPwd"
                $ss = ConvertTo-SecureString $combined -AsPlainText -Force
                Save-DiscoveryCredential -Name $VaultName -SecureSecret $ss `
                    -Description "WUG $proto`://$srv`:$port ($($cred.UserName))" -Force | Out-Null
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
    #>
    [CmdletBinding()]
    param($Stored, [string]$CredType)

    switch ($CredType) {
        'AWSKeys' {
            if ($Stored -is [PSCredential]) { return $Stored }
            if ($Stored -is [string] -and $Stored -match '\|') {
                $parts = $Stored -split '\|', 2
                $secKey = ConvertTo-SecureString $parts[1] -AsPlainText -Force
                return [PSCredential]::new($parts[0], $secKey)
            }
            return $Stored
        }
        'PSCredential' {
            if ($Stored -is [PSCredential]) { return $Stored }
            if ($Stored -is [string] -and $Stored -match '\|') {
                $parts = $Stored -split '\|', 2
                $secPwd = ConvertTo-SecureString $parts[1] -AsPlainText -Force
                return [PSCredential]::new($parts[0], $secPwd)
            }
            return $Stored
        }
        'AzureSP' {
            if ($Stored -is [PSCredential]) { return $Stored }
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
            return $Stored
        }
        'WUGServer' {
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
          PSCredential — for AWSKeys, AzureSP, PSCredential
          String       — for BearerToken
          Hashtable    — for WUGServer (with Server, Port, Protocol, Credential keys)
    .EXAMPLE
        $wug = Resolve-DiscoveryCredential -Name 'WUG.Server' -CredType WUGServer -DeferSave
        # ... test connection succeeds ...
        Save-ResolvedCredential -Name 'WUG.Server' -CredType WUGServer -Value $wug
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [ValidateSet('AWSKeys','AzureSP','BearerToken','PSCredential','WUGServer')] [string]$CredType,
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
    .EXAMPLE
        # Discover all F5 devices
        $plan = Invoke-WUGDiscovery -ProviderName 'F5'
        $plan | Format-Table DeviceName, Name, ItemType, MonitorType

    .EXAMPLE
        # Discover everything
        $plan = Invoke-WUGDiscovery
        $plan | Group-Object ProviderName | Select-Object Name, Count
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
        [hashtable]$Credential
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

        This is idempotent — running it multiple times only creates what's
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
        [int]$PollingIntervalSeconds = 300,

        [Parameter()]
        [ValidateRange(1, 1440)]
        [int]$PerfPollingIntervalMinutes = 5,

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

        Write-Verbose "Fetching existing WUG active monitors for duplicate check..."
        $existingActive = @(Get-WUGActiveMonitor)
        $existingActiveNames = @{}
        foreach ($mon in $existingActive) {
            if ($mon.name) {
                $existingActiveNames[$mon.name] = $mon.id
            }
        }

        $stats = @{
            ActiveCreated  = 0
            PerfCreated    = 0
            Skipped        = 0
            Assigned       = 0
            AttrsUpdated   = 0
            Failed         = 0
        }
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
                        Write-Verbose "Skipping creation for '$monName' — no params (built-in monitor expected in library)"
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
                                $monId = if ($result.PSObject.Properties['resourceId']) { $result.resourceId } else { $result.id }
                                $existingActiveNames[$monName] = $monId
                            }
                        }
                        catch {
                            Write-Warning "Failed to create active monitor '$monName': $_"
                            $stats.Failed++
                        }
                    }
                }

                # Always assign to device (shared monitors get assigned to multiple devices)
                if ($monId -and $item.DeviceId) {
                    try {
                        Add-WUGActiveMonitorToDevice `
                            -DeviceId $item.DeviceId `
                            -MonitorId $monId `
                            -PollingIntervalSeconds $PollingIntervalSeconds
                        $stats.Assigned++
                        Write-Verbose "Assigned '$monName' to device $($item.DeviceId)"
                    }
                    catch {
                        if ($_.Exception.Message -match 'already|assigned|exists|duplicate') {
                            Write-Verbose "Monitor '$monName' already assigned to device $($item.DeviceId)"
                        }
                        else {
                            Write-Warning "Failed to assign '$monName' to device $($item.DeviceId): $_"
                            $stats.Failed++
                        }
                    }
                }
            }

            # --- Create Performance Monitor ---
            if ($item.ItemType -eq 'PerformanceMonitor') {
                # Performance monitors are per-device — skip if no valid DeviceId
                if (-not $item.DeviceId -or $item.DeviceId -eq 0) {
                    Write-Verbose "Skipping perf monitor '$monName' — no valid DeviceId"
                    $stats.Skipped++
                    continue
                }
                if ($PSCmdlet.ShouldProcess($monName, "Create $($item.MonitorType) Performance Monitor on device $($item.DeviceId)")) {
                    try {
                        $perfParams = @{
                            DeviceId               = $item.DeviceId
                            Type                   = $item.MonitorType
                            PollingIntervalMinutes = $PerfPollingIntervalMinutes
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
                            Write-Verbose "Skipping perf monitor '$monName' — already exists"
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
                            Set-WUGDeviceAttribute -DeviceId $item.DeviceId -Name $attrName -Value $attrValue
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
        # F5 BIG-IP — basic auth
        New-WUGDiscoveryCredential -DeviceId 42 -ProviderName 'F5' `
            -Username 'admin' -Password 'pass' -IgnoreCertErrors

    .EXAMPLE
        # FortiGate — API token
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
        # Token-based auth — credential is a placeholder since actual auth
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
# region  Start-WUGDiscovery — Full End-to-End Orchestrator
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
             a. Searches WUG for existing device — adds via Add-WUGDevice if missing
             b. Creates REST API credential in WUG — assigns to device
             c. Sets the provider's MatchAttribute on the device
          3. Runs Invoke-WUGDiscovery — builds the monitor plan
          4. Shows the plan for review (unless -Confirm:$false)
          5. Runs Invoke-WUGDiscoverySync — creates monitors, assigns to devices
          6. Returns summary

        Credentials are stored in two places:
          - DPAPI vault (local, encrypted to Windows user + machine) — used by
            this script for first-run setup and any live API calls
          - WUG credential store (encrypted by WUG) — used by WUG's polling
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
        # First run — prompts for F5 credentials with masked input:
        Start-WUGDiscovery -ProviderName 'F5' -Target 'lb1.corp.local','lb2.corp.local'

        # Subsequent runs — fully automatic, no prompts:
        Start-WUGDiscovery -ProviderName 'F5' -Target 'lb1.corp.local','lb2.corp.local'
    .EXAMPLE
        # FortiGate with custom port:
        Start-WUGDiscovery -ProviderName 'Fortinet' -Target '10.0.0.1' -ApiPort 8443
    .EXAMPLE
        # Non-interactive (Task Scheduler) — skips confirmation prompt:
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
            # BasicAuth — username + password stored as a bundle
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
# endregion

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDu4NeXOAtqXGQN
# 1n+FBC1vAErFi1bsaquuIfPf1Th/gqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCBYdyv/IJV5S38IRNUqzOfAGHhOaJf5McvOkU8rm2tuRDANBgkqhkiG9w0BAQEF
# AASCAgAbfhTg9sm4REpI6GIyvikuiXb1k2TMx29Y2cpZ3SphzsfebeSeSGaNER9Q
# eIEGc8Jn5dnZrPbq7fvyWtYvvzLlkk5Dzgb+ltr/3MVaA3VPQw8JReIcD3RAsjjx
# TqpF5Uzok06ysL9OGzZ/ZJYMmIQY0i2nwLspvc00m/wAiI0f4A4jM4MZhdyjEGjK
# eVyUnbBJY4q7rnPlJXdblusoXk/j40qZZ9A/uKFEsLqqdjlginpDLAvjoD9Vbppw
# gPrdrRV/2jFKbBOkhowrv2tJIpe781YEbjnyxH9XTglIxLcn0YWAoe2eGO+62Uwh
# KQo5z38p9nD/6R3SzSutu+HTmdjbYgTAmaNtFov+2JNb6D/jWUfTSWkyOlVewqFJ
# ad3R3vTl0RKz2S4B5FgNfZ5krDYSRokBXVxDOJzqG0ZSdiKlzZ0Xnr41GVs22r38
# pBTypEnmG+LD1Kp5NELS6DFwIwEDHV6W4EYeTpG/9y+hdCgLGX2QAqvnC18CRnsU
# efqFLRoNxPsvdHmyd9qR/dLQmdMx7WhJFt+IMltYuCEL8RoTnDNhgWeyU+EeQWv5
# QyRpHxBn/Ywve0XkIuW/hwRpL8Ctc/mNZ3MZAfyXW0ZgBIRrK8Q0YIXcWpuyysIx
# 0TjAwTOcWGk6wll5j4pVwDfJ8txuJaVLMIO3r2oKS3HdZ3Q5zaGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MDYxOTMzMTVaMC8GCSqGSIb3DQEJBDEiBCCuiqU2
# adr2Dp/yjK/2hmbEHd+zRpYxgqEJcU0jsGG61DANBgkqhkiG9w0BAQEFAASCAgB8
# /wLpUhcj5wY8vguzNhlWurUTRmopbLzdNqyWUHZzQD7LhYxJRic4ruDBondbLxIr
# PkG3PqAlKFDMHnframt84ynnzyQ+r3WIcNMBtXZWHKYrfJHWlot3hfRsqjczfWd9
# NOepNwkmNodZa9xhu2BkBW4cy2A84IWRkHWwJsj7scAyza/AjEIzDz46ymaHXGpq
# pbiZiA0k/AvkVst/GKFs3n+kbm0B7+0QU1VBN4l3dNsJp2VNcnxHwUklZ7BeNXTv
# zN7e5F8u8YgzZSwzJvMpL9LapEJsgSZjgnczjAVqgQ1yhOEOkGzrqpZe01pze3AT
# zuYIxs3MuC1WtsFuEBGJ6SiUCI0PJ61vUCq2bbHsUe92M62foruEF240Gz5JIKAl
# etzoga4ZuqjkiFmCzAIz6kj/hKPj+8gaYAoBc6E593TqMAqXIj0O8ZaIz6JOSYQ4
# evGyCeXNiJ5meE/9BdnjycQ6WU3WJO9+eGadt7O/UqA9Xoq+wGCcDalNJVFipqVM
# ssXwKyEINFLMAOjgYe3/ohoJzmXkO7u19VnfqEw4jPRi+4ANBFQBsXKxBvzaS2RC
# 0JQshLZu8ydZPSxpzvmRcvLuL7IqCMhVJoxZCOsD5qaj0BViKUyL4VzUPICzhjTK
# aQUgRrHqZSTezGHiELCFRnpBIS48zY/3UpzDwEMF0g==
# SIG # End signature block
