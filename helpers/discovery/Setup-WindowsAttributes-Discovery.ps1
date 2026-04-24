<#
.SYNOPSIS
    Discovers Windows system information via WMI and updates WhatsUp Gold
    device attributes with the collected data.

.DESCRIPTION
    This helper connects to Windows servers via WMI (Get-WmiObject) to collect
    system-level information such as OS version, service pack, hardware model,
    CPU, RAM, serial number, domain, last boot time, and installed roles/features.
    It then creates or updates device attributes in WhatsUp Gold using
    Set-WUGDeviceAttribute so that this information is always visible in the
    WUG console without manual data entry.

    Uses the shared Windows WMI credential vault (Windows.WMI.Credential.N)
    so credentials entered for Setup-WindowsDiskIO-Discovery are reused here
    and vice versa. Multi-credential fallback on access-denied errors.

    Attributes collected per device:
      - Windows.OSName           (e.g. Microsoft Windows Server 2022 Standard)
      - Windows.OSVersion        (e.g. 10.0.20348)
      - Windows.OSBuild          (e.g. 20348)
      - Windows.ServicePack      (e.g. 0)
      - Windows.Architecture     (e.g. 64-bit)
      - Windows.Manufacturer     (e.g. QEMU, Dell Inc.)
      - Windows.Model            (e.g. Standard PC, PowerEdge R740)
      - Windows.SerialNumber     (e.g. VMware-42 1a ...)
      - Windows.IsVirtualMachine (e.g. True)
      - Windows.BIOSVersion      (e.g. Dell Inc. 2.14.1 (2025-08-20))
      - Windows.Motherboard      (e.g. Dell Inc. 0CNCJW)
      - Windows.TotalMemoryGB    (e.g. 16)
      - Windows.FreeMemoryGB     (e.g. 8.42)
      - Windows.RAMSticks        (e.g. 4)
      - Windows.RAMSpeedMHz      (e.g. 3200)
      - Windows.CPUName          (e.g. Intel Xeon E5-2680 v4)
      - Windows.CPUCores         (e.g. 4)
      - Windows.CPULogical       (e.g. 8)
      - Windows.CPUSpeedMHz      (e.g. 2400)
      - Windows.GPUName          (e.g. NVIDIA Tesla T4)
      - Windows.GPUMemoryMB      (e.g. 16384)
      - Windows.GPUResolution    (e.g. 1920x1080)
      - Windows.Domain           (e.g. wugninja.local)
      - Windows.LastBootTime     (e.g. 2026-04-01 08:32:15)
      - Windows.LastReboot       (e.g. 0 months, 8 days, 3 hours ago)
      - Windows.InstallDate      (e.g. 2025-11-12)
      - Windows.SystemType       (e.g. x64-based PC)
      - Windows.LastLogonUser    (e.g. DOMAIN\jsmith)
      - Windows.LastLogonTime    (e.g. 2026-04-09 14:22:01)
      - Windows.DiskCount        (e.g. 3)
      - Windows.TotalDiskGB      (e.g. 1024)
      - Windows.DiskSummary      (e.g. Samsung SSD 970 -- 477 GB (SSD) | ...)
      - Windows.NetworkAdapters  (e.g. 2)
      - Windows.RunningServices  (e.g. 87)
      - Windows.StoppedServices  (e.g. 42)
      - Windows.InstalledSoftware (e.g. 134)

    Prerequisites:
      1. WhatsUpGoldPS module loaded and connected (Connect-WUGServer)
      2. WMI/DCOM or WinRM access to target Windows servers
      3. Credentials with admin access on target servers

.PARAMETER DeviceId
    One or more WUG device IDs to scan. When omitted, devices are resolved
    automatically from a Windows device group (see DeviceGroupSearch).

.PARAMETER Credential
    One or more PSCredentials for WMI access to the target Windows servers.
    Multiple credentials are tried in order per device. If omitted, resolved
    from the shared DPAPI vault (Windows.WMI.Credential.N).

.PARAMETER DeviceGroupSearch
    Search string used to find a WUG device group containing Windows devices.
    Default: 'Windows Infrastructure'.

.PARAMETER DeviceGroupId
    Explicit WUG device group ID. Overrides DeviceGroupSearch.

.PARAMETER WindowsOnly
    When enabled (default), only devices whose role or description contains
    'Windows' are scanned.

.PARAMETER AttributePrefix
    Prefix for all attribute names. Default: 'Windows'.

.PARAMETER IncludeAttribute
    Array of specific attribute keys to collect. Default: all.
    Use to limit which WMI classes are queried per device.
    Valid values: All, OSName, OSVersion, OSBuild, ServicePack, Architecture,
    Manufacturer, Model, SerialNumber, IsVirtualMachine, BIOSVersion,
    Motherboard, TotalMemoryGB, FreeMemoryGB, RAMSticks, RAMSpeedMHz,
    CPUName, CPUCores, CPULogical, CPUSpeedMHz, GPUName, GPUMemoryMB,
    GPUResolution, Domain, LastBootTime, LastReboot, InstallDate, SystemType,
    LastLogonUser, LastLogonTime, DiskCount, TotalDiskGB, DiskSummary,
    NetworkAdapters, RunningServices, StoppedServices, InstalledSoftware.

.PARAMETER Action
    What to do with discovery results. When specified, skips the interactive menu.
    Valid values: PushToWUG, ExportJSON, ExportCSV, ShowTable, Dashboard, DashboardAndPush, None.
    PushToWUG requires devices resolved from WhatsUp Gold (not standalone -Target mode).

.PARAMETER Target
    Windows host(s) to scan via WMI -- IP address or FQDN. Accepts multiple values.
    Enables standalone mode (no WhatsUp Gold connection needed for device resolution).
    PushToWUG action is not available in standalone -Target mode.

.PARAMETER DryRun
    Show what attributes would be set without making changes.

.PARAMETER NonInteractive
    Suppress interactive prompts. Uses cached vault credentials.

.PARAMETER WUGServer
    WhatsUp Gold server address. Default: resolved from vault.

.PARAMETER WUGCredential
    PSCredential for authenticating to WhatsUp Gold. When supplied, bypasses
    the vault-based WUG server resolution and connects directly.

.EXAMPLE
    .\Setup-WindowsAttributes-Discovery.ps1

    Interactive mode -- resolves creds from vault, scans all Windows devices,
    updates attributes in WUG.

.EXAMPLE
    .\Setup-WindowsAttributes-Discovery.ps1 -DeviceId 163,173 -NonInteractive

    Scans specific devices non-interactively using vault credentials.

.EXAMPLE
    .\Setup-WindowsAttributes-Discovery.ps1 -DryRun

    Preview what attributes would be set without making changes.

.EXAMPLE
    .\Setup-WindowsAttributes-Discovery.ps1 -IncludeAttribute OSName,TotalMemoryGB,CPUName

    Only collect OS name, RAM, and CPU info.

.EXAMPLE
    .\Setup-WindowsAttributes-Discovery.ps1 -Target '10.0.0.5','10.0.0.6' -Action Dashboard

    Standalone mode -- scans hosts directly and generates an HTML dashboard.

.EXAMPLE
    .\Setup-WindowsAttributes-Discovery.ps1 -Target '10.0.0.5' -Action ExportJSON -NonInteractive

    Scans a host and exports results to JSON. No WUG connection required.

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: WhatsUpGoldPS module, PowerShell 5.1+
    Encoding: UTF-8 with BOM
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int[]]$DeviceId,

    [PSCredential[]]$Credential,

    [string]$DeviceGroupSearch = 'Windows Infrastructure',

    [string]$DeviceGroupId,

    [bool]$WindowsOnly = $true,

    [string]$AttributePrefix = 'Windows',

    [ValidateSet('All', 'OSName', 'OSVersion', 'OSBuild', 'ServicePack', 'Architecture',
                 'Manufacturer', 'Model', 'SerialNumber', 'IsVirtualMachine', 'BIOSVersion',
                 'Motherboard', 'TotalMemoryGB', 'FreeMemoryGB', 'RAMSticks', 'RAMSpeedMHz',
                 'CPUName', 'CPUCores', 'CPULogical', 'CPUSpeedMHz', 'GPUName', 'GPUMemoryMB',
                 'GPUResolution', 'Domain', 'LastBootTime', 'LastReboot', 'InstallDate',
                 'SystemType', 'LastLogonUser', 'LastLogonTime', 'DiskCount', 'TotalDiskGB',
                 'DiskSummary', 'NetworkAdapters', 'RunningServices', 'StoppedServices',
                 'InstalledSoftware')]
    [string[]]$IncludeAttribute,

    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'ShowTable', 'Dashboard', 'DashboardAndPush', 'None')]
    [string]$Action,

    [string[]]$Target,

    [switch]$DryRun,

    [switch]$NonInteractive,

    [string]$WUGServer,

    [PSCredential]$WUGCredential,

    [string]$OutputPath
)

# --- Load discovery helpers (vault, credential resolver) ----------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$discoveryHelpersPath = Join-Path $scriptDir 'DiscoveryHelpers.ps1'
if (Test-Path $discoveryHelpersPath) {
    . $discoveryHelpersPath
}
else {
    Write-Error "DiscoveryHelpers.ps1 not found at '$discoveryHelpersPath'. Cannot continue."
    return
}

# Load dynamic dashboard generator (fallback)
$dynDashPath = Join-Path (Split-Path $scriptDir -Parent) 'reports\Export-DynamicDashboardHtml.ps1'
if (Test-Path $dynDashPath) { . $dynDashPath }

# Load provider-specific Windows dashboard functions
$winProviderPath = Join-Path $scriptDir 'DiscoveryProvider-Windows.ps1'
if (Test-Path $winProviderPath) { . $winProviderPath }

# =============================================================================
# Attribute definitions: key -> WMI query info
# =============================================================================
# Simple entries: Class + Property (+ optional Transform)
# Compute entries: Compute scriptblock receives ($wmiCache, $devIP, $tryCred)
#   and returns the value directly. Use for multi-object or registry queries.
$script:AttributeDefinitions = [ordered]@{
    # --- Identity / OS ---
    OSName        = @{ Class = 'Win32_OperatingSystem'; Property = 'Caption' }
    OSVersion     = @{ Class = 'Win32_OperatingSystem'; Property = 'Version' }
    OSBuild       = @{ Class = 'Win32_OperatingSystem'; Property = 'BuildNumber' }
    ServicePack   = @{ Class = 'Win32_OperatingSystem'; Property = 'ServicePackMajorVersion' }
    Architecture  = @{ Class = 'Win32_OperatingSystem'; Property = 'OSArchitecture' }
    Manufacturer  = @{ Class = 'Win32_ComputerSystem';  Property = 'Manufacturer' }
    Model         = @{ Class = 'Win32_ComputerSystem';  Property = 'Model' }
    SerialNumber  = @{ Class = 'Win32_BIOS';            Property = 'SerialNumber' }
    IsVirtualMachine = @{ Compute = {
        param($cache, $ip, $cred)
        $cs = $cache['Win32_ComputerSystem']
        if ($cs -is [System.Array]) { $cs = $cs[0] }
        $isVM = ($cs.Model -match 'Virtual|VMware|HVM|KVM|BHYVE' -or
                 $cs.Manufacturer -match 'VMware|Microsoft Corporation|Xen|QEMU|innotek|Parallels')
        "$isVM"
    }}
    BIOSVersion   = @{ Compute = {
        param($cache, $ip, $cred)
        $b = $cache['Win32_BIOS']
        if ($b -is [System.Array]) { $b = $b[0] }
        $dateStr = ''
        if ($b.ReleaseDate) {
            try { $dateStr = " ($([Management.ManagementDateTimeConverter]::ToDateTime($b.ReleaseDate).ToString('yyyy-MM-dd')))" } catch {}
        }
        "$($b.Manufacturer) $($b.SMBIOSBIOSVersion)$dateStr".Trim()
    }}
    Motherboard   = @{ Compute = {
        param($cache, $ip, $cred)
        $mb = $cache['Win32_BaseBoard']
        if ($mb -is [System.Array]) { $mb = $mb[0] }
        if ($mb) { "$($mb.Manufacturer) $($mb.Product)".Trim() } else { '' }
    }}
    # --- Memory ---
    TotalMemoryGB = @{ Class = 'Win32_ComputerSystem';  Property = 'TotalPhysicalMemory'; Transform = { param($v) [Math]::Round([double]$v / 1GB) } }
    FreeMemoryGB  = @{ Class = 'Win32_OperatingSystem';  Property = 'FreePhysicalMemory'; Transform = { param($v) [Math]::Round([double]$v / 1MB, 2) } }
    RAMSticks     = @{ Compute = {
        param($cache, $ip, $cred)
        $sticks = $cache['Win32_PhysicalMemory']
        if (-not $sticks) { return '0' }
        if ($sticks -is [System.Array]) { "$($sticks.Count)" } else { '1' }
    }}
    RAMSpeedMHz   = @{ Compute = {
        param($cache, $ip, $cred)
        $sticks = $cache['Win32_PhysicalMemory']
        if (-not $sticks) { return '' }
        $first = if ($sticks -is [System.Array]) { $sticks[0] } else { $sticks }
        if ($first.Speed) { "$($first.Speed)" } else { '' }
    }}
    # --- CPU ---
    CPUName       = @{ Class = 'Win32_Processor';       Property = 'Name' }
    CPUCores      = @{ Class = 'Win32_Processor';       Property = 'NumberOfCores' }
    CPULogical    = @{ Class = 'Win32_Processor';       Property = 'NumberOfLogicalProcessors' }
    CPUSpeedMHz   = @{ Class = 'Win32_Processor';       Property = 'MaxClockSpeed' }
    # --- GPU ---
    GPUName       = @{ Compute = {
        param($cache, $ip, $cred)
        $g = $cache['Win32_VideoController']
        if (-not $g) { return '' }
        if ($g -is [System.Array]) { $g = $g[0] }
        if ($g.Name) { "$($g.Name)".Trim() } else { '' }
    }}
    GPUMemoryMB   = @{ Compute = {
        param($cache, $ip, $cred)
        $g = $cache['Win32_VideoController']
        if (-not $g) { return '' }
        if ($g -is [System.Array]) { $g = $g[0] }
        if ($g.AdapterRAM) { "$([Math]::Round([double]$g.AdapterRAM / 1MB))" } else { '' }
    }}
    GPUResolution = @{ Compute = {
        param($cache, $ip, $cred)
        $g = $cache['Win32_VideoController']
        if (-not $g) { return '' }
        if ($g -is [System.Array]) { $g = $g[0] }
        if ($g.CurrentHorizontalResolution -and $g.CurrentVerticalResolution) {
            "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)"
        } else { '' }
    }}
    # --- Identity continued ---
    Domain        = @{ Class = 'Win32_ComputerSystem';  Property = 'Domain' }
    LastBootTime  = @{ Class = 'Win32_OperatingSystem';  Property = 'LastBootUpTime'; Transform = { param($v) if ($v) { try { [Management.ManagementDateTimeConverter]::ToDateTime($v).ToString('yyyy-MM-dd HH:mm:ss') } catch { "$v" } } else { '' } } }
    LastReboot    = @{ Class = 'Win32_OperatingSystem';  Property = 'LastBootUpTime'; Transform = {
        param($v)
        if ($v) {
            try {
                $bootDt = [Management.ManagementDateTimeConverter]::ToDateTime($v)
                $ts = [int]((Get-Date) - $bootDt).TotalSeconds
                $units = [ordered]@{ year = 31536000; month = 2592000; day = 86400; hour = 3600 }
                $parts = @()
                foreach ($u in $units.Keys) {
                    $n = [Math]::Floor($ts / $units[$u])
                    $ts = $ts % $units[$u]
                    if ($n -gt 0) { $parts += "$n $u$(if ($n -ne 1) { 's' })" }
                }
                if ($parts.Count -eq 0) { $parts += '0 hours' }
                ($parts -join ', ') + ' ago'
            } catch { "$v" }
        } else { '' }
    }}
    InstallDate   = @{ Class = 'Win32_OperatingSystem';  Property = 'InstallDate'; Transform = { param($v) if ($v) { try { [Management.ManagementDateTimeConverter]::ToDateTime($v).ToString('yyyy-MM-dd') } catch { "$v" } } else { '' } } }
    SystemType    = @{ Class = 'Win32_ComputerSystem';  Property = 'SystemType' }
    LastLogonUser = @{ Class = 'Win32_ComputerSystem';  Property = 'UserName' }
    LastLogonTime = @{ Class = 'Win32_OperatingSystem';  Property = 'LocalDateTime'; Transform = {
        param($v)
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }}
    # --- Disks ---
    DiskCount     = @{ Compute = {
        param($cache, $ip, $cred)
        $d = $cache['Win32_DiskDrive']
        if (-not $d) { return '0' }
        if ($d -is [System.Array]) { "$($d.Count)" } else { '1' }
    }}
    TotalDiskGB   = @{ Compute = {
        param($cache, $ip, $cred)
        $d = $cache['Win32_DiskDrive']
        if (-not $d) { return '0' }
        $arr = if ($d -is [System.Array]) { $d } else { @($d) }
        $total = ($arr | ForEach-Object { [double]$_.Size } | Measure-Object -Sum).Sum
        "$([Math]::Round($total / 1GB))"
    }}
    DiskSummary   = @{ Compute = {
        param($cache, $ip, $cred)
        $d = $cache['Win32_DiskDrive']
        if (-not $d) { return '' }
        $arr = if ($d -is [System.Array]) { $d } else { @($d) }
        $parts = $arr | ForEach-Object {
            $sizeGB = [Math]::Round([double]$_.Size / 1GB)
            $media  = if ($_.MediaType -match 'SSD|Solid') { 'SSD' } elseif ($_.MediaType -match 'Fixed') { 'HDD' } else { $_.MediaType }
            "$($_.Model) -- $sizeGB GB ($media)"
        }
        $parts -join ' | '
    }}
    # --- Network ---
    NetworkAdapters = @{ Compute = {
        param($cache, $ip, $cred)
        $n = $cache['Win32_NetworkAdapterConfiguration']
        if (-not $n) { return '0' }
        $arr = if ($n -is [System.Array]) { $n } else { @($n) }
        $enabled = @($arr | Where-Object { $_.IPEnabled })
        "$($enabled.Count)"
    }}
    # --- Services ---
    RunningServices = @{ Compute = {
        param($cache, $ip, $cred)
        $s = $cache['Win32_Service']
        if (-not $s) { return '0' }
        $arr = if ($s -is [System.Array]) { $s } else { @($s) }
        "$(@($arr | Where-Object { $_.State -eq 'Running' }).Count)"
    }}
    StoppedServices = @{ Compute = {
        param($cache, $ip, $cred)
        $s = $cache['Win32_Service']
        if (-not $s) { return '0' }
        $arr = if ($s -is [System.Array]) { $s } else { @($s) }
        "$(@($arr | Where-Object { $_.State -eq 'Stopped' }).Count)"
    }}
    # --- Software (registry-based, fast -- avoids Win32_Product) ---
    InstalledSoftware = @{ Compute = {
        param($cache, $ip, $cred)
        try {
            $isLocalConn = ($ip -eq 'localhost' -or $ip -eq '127.0.0.1' -or $ip -eq '::1' -or $ip -eq $env:COMPUTERNAME -or $ip -eq '.')
            if ($isLocalConn) {
                $wmiList = Get-WmiObject -List -Namespace root\default -ErrorAction Stop
            } else {
                $wmiList = Get-WmiObject -List -Namespace root\default -ComputerName $ip -Credential $cred -ErrorAction Stop
            }
            $reg = $wmiList | Where-Object { $_.Name -eq 'StdRegProv' }
            $HKLM = [UInt32]'0x80000002'
            $count = 0
            foreach ($regPath in @(
                'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            )) {
                $subkeys = $reg.EnumKey($HKLM, $regPath)
                if ($subkeys.sNames) {
                    foreach ($key in $subkeys.sNames) {
                        $dn = $reg.GetStringValue($HKLM, "$regPath\$key", 'DisplayName')
                        if ($dn.sValue) { $count++ }
                    }
                }
            }
            "$count"
        }
        catch {
            Write-Verbose "  Registry software count failed on ${ip}: $_"
            ''
        }
    }}
}

# Resolve which attributes to collect
if ($IncludeAttribute -and $IncludeAttribute -contains 'All') {
    $activeAttributes = $script:AttributeDefinitions
}
elseif ($IncludeAttribute) {
    $activeAttributes = [ordered]@{}
    foreach ($key in $IncludeAttribute) {
        if ($script:AttributeDefinitions.Contains($key)) {
            $activeAttributes[$key] = $script:AttributeDefinitions[$key]
        }
    }
}
else {
    $activeAttributes = $script:AttributeDefinitions
}

if ($activeAttributes.Count -eq 0) {
    Write-Error "No valid attributes selected. Exiting."
    return
}

# Figure out which WMI classes we actually need to query
# Simple attrs declare a Class; Compute attrs may reference classes implicitly.
# We build the list from simple attrs, then add the extra classes that Compute
# entries depend on (declared in the definitions via naming convention).
$requiredClasses = [System.Collections.Generic.List[string]]::new()
foreach ($def in $activeAttributes.Values) {
    if ($def.Class -and -not $requiredClasses.Contains($def.Class)) {
        $requiredClasses.Add($def.Class)
    }
}
# Extra classes needed by Compute attributes when they are active
$computeClassDeps = @{
    IsVirtualMachine  = @('Win32_ComputerSystem')
    BIOSVersion       = @('Win32_BIOS')
    Motherboard       = @('Win32_BaseBoard')
    RAMSticks         = @('Win32_PhysicalMemory')
    RAMSpeedMHz       = @('Win32_PhysicalMemory')
    GPUName           = @('Win32_VideoController')
    GPUMemoryMB       = @('Win32_VideoController')
    GPUResolution     = @('Win32_VideoController')
    DiskCount         = @('Win32_DiskDrive')
    TotalDiskGB       = @('Win32_DiskDrive')
    DiskSummary       = @('Win32_DiskDrive')
    NetworkAdapters   = @('Win32_NetworkAdapterConfiguration')
    RunningServices   = @('Win32_Service')
    StoppedServices   = @('Win32_Service')
}
foreach ($key in $activeAttributes.Keys) {
    if ($computeClassDeps.ContainsKey($key)) {
        foreach ($cls in $computeClassDeps[$key]) {
            if (-not $requiredClasses.Contains($cls)) {
                $requiredClasses.Add($cls)
            }
        }
    }
}

# =============================================================================
# Preflight: WUG connection (only needed when resolving devices from WUG or pushing)
# =============================================================================
$needsWUG = (-not $Target) -or ($Action -eq 'PushToWUG') -or ($Action -eq 'DashboardAndPush')
if ($needsWUG) {
if (-not $global:WUGBearerHeaders -or -not $global:WhatsUpServerBaseURI) {
    if ($WUGCredential) {
        # Direct credential supplied -- bypass vault resolution
        $wugUri = if ($WUGServer) { $WUGServer } else { 'https://localhost:9644' }
        try {
            Connect-WUGServer -serverUri $wugUri -Credential $WUGCredential -IgnoreSSLErrors
            Write-Host "Connected to WhatsUp Gold." -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to connect to WhatsUp Gold: $_"
            return
        }
    }
    else {
    Write-Host "Not connected to WhatsUp Gold. Resolving from vault..." -ForegroundColor Yellow
    $wugSplat = @{ Name = 'WUG.Server'; CredType = 'WUGServer'; ProviderLabel = 'WhatsUp Gold' }
    if ($NonInteractive) { $wugSplat.NonInteractive = $true }
    $wugResolved = Resolve-DiscoveryCredential @wugSplat
    if (-not $wugResolved) {
        Write-Error "No WhatsUp Gold server credentials available. Run Connect-WUGServer or configure the vault."
        return
    }
    $wugConnSplat = @{}
    if ($wugResolved -is [hashtable]) {
        $wugConnSplat.Server = $wugResolved.Server
        if ($wugResolved.Port)     { $wugConnSplat.Port = $wugResolved.Port }
        if ($wugResolved.Protocol) { $wugConnSplat.Protocol = $wugResolved.Protocol }
        if ($wugResolved.Credential) { $wugConnSplat.Credential = $wugResolved.Credential }
        if ($wugResolved.IgnoreSSL) { $wugConnSplat.IgnoreSSL = $true }
    }
    elseif ($WUGServer) {
        $wugConnSplat.Server = $WUGServer
    }
    try {
        Connect-WUGServer @wugConnSplat
        Write-Host "Connected to WhatsUp Gold." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to WhatsUp Gold: $_"
        return
    }
    }
}
} # end needsWUG

# =============================================================================
# Resolve WMI credentials (shared Windows vault, multi-credential support)
# =============================================================================
$credentialList = [System.Collections.Generic.List[PSCredential]]::new()

if ($Credential) {
    foreach ($c in $Credential) { $credentialList.Add($c) }
}
else {
    $credIndex = 1
    $wmiVaultName = "Windows.WMI.Credential.$credIndex"
    $credSplat = @{ Name = $wmiVaultName; CredType = 'PSCredential'; ProviderLabel = "Windows WMI #$credIndex" }
    if ($NonInteractive) { $credSplat.NonInteractive = $true }
    $firstCred = Resolve-DiscoveryCredential @credSplat
    if (-not $firstCred) {
        Write-Error "No WMI credentials available. Provide -Credential or configure the vault."
        return
    }
    $credentialList.Add($firstCred)

    if (-not $NonInteractive) {
        while ($true) {
            Write-Host ""
            Write-Host "  Credential #$($credentialList.Count) loaded: $($credentialList[-1].UserName)" -ForegroundColor Gray
            Write-Host "  Add another credential to try if this one fails on some servers?" -ForegroundColor Cyan
            $addMore = Read-Host -Prompt "  [Y]es / [N]o (default: N)"
            if ($addMore -notmatch '^[Yy]') { break }

            $credIndex++
            $wmiVaultName = "Windows.WMI.Credential.$credIndex"
            $credSplat = @{ Name = $wmiVaultName; CredType = 'PSCredential'; ProviderLabel = "Windows WMI #$credIndex" }
            $nextCred = Resolve-DiscoveryCredential @credSplat
            if ($nextCred) {
                $credentialList.Add($nextCred)
            }
            else {
                Write-Host "  Skipped." -ForegroundColor Yellow
                break
            }
        }
    }
    else {
        while ($true) {
            $credIndex++
            $wmiVaultName = "Windows.WMI.Credential.$credIndex"
            $credSplat = @{ Name = $wmiVaultName; CredType = 'PSCredential'; NonInteractive = $true }
            $nextCred = Resolve-DiscoveryCredential @credSplat
            if ($nextCred) {
                $credentialList.Add($nextCred)
            }
            else {
                break
            }
        }
    }
}

Write-Host ""
Write-Host "  Credentials to try ($($credentialList.Count)):" -ForegroundColor Cyan
for ($ci = 0; $ci -lt $credentialList.Count; $ci++) {
    Write-Host "    [$($ci + 1)] $($credentialList[$ci].UserName)" -ForegroundColor Gray
}

# =============================================================================
# STEP 1: Resolve target devices (smart Windows group detection)
# =============================================================================
Write-Host ""
Write-Host "=== Windows Attributes Discovery ===" -ForegroundColor Cyan
Write-Host ""

$standaloneMode = $false
if ($Target) {
    # Standalone mode: scan specified hosts directly (no WUG device lookup)
    $standaloneMode = $true
    Write-Host "Standalone mode: scanning $($Target.Count) specified host(s)..." -ForegroundColor Cyan
    $devices = @()
    $targetId = 0
    foreach ($t in $Target) {
        $targetId++
        $devices += [PSCustomObject]@{
            id             = "target-$targetId"
            displayName    = $t
            hostName       = $t
            networkAddress = $t
            role           = 'Windows'
        }
    }
}
elseif ($DeviceId) {
    Write-Host "Fetching $($DeviceId.Count) specified device(s) from WhatsUp Gold..." -ForegroundColor Cyan
    $devices = @()
    foreach ($dId in $DeviceId) {
        try {
            $dev = Get-WUGDevice -DeviceId $dId
            if ($dev) { $devices += $dev }
        }
        catch {
            Write-Warning "Could not retrieve device ID ${dId}: $_"
        }
    }
}
else {
    $resolvedGroupId = $null

    if ($DeviceGroupId) {
        $resolvedGroupId = $DeviceGroupId
        Write-Host "Using explicit device group ID: $resolvedGroupId" -ForegroundColor Cyan
    }
    elseif ($DeviceGroupSearch) {
        Write-Host "Searching for device group matching '$DeviceGroupSearch'..." -ForegroundColor Cyan
        try {
            $matchingGroups = @(Get-WUGDeviceGroup -SearchValue $DeviceGroupSearch)
            if ($matchingGroups.Count -eq 1) {
                $resolvedGroupId = $matchingGroups[0].id
                Write-Host "  Found group: '$($matchingGroups[0].name)' (ID: $resolvedGroupId)" -ForegroundColor Green
            }
            elseif ($matchingGroups.Count -gt 1) {
                Write-Host "  Found $($matchingGroups.Count) matching groups:" -ForegroundColor Cyan
                for ($gi = 0; $gi -lt $matchingGroups.Count; $gi++) {
                    $g = $matchingGroups[$gi]
                    $devCount = if ($g.deviceCount) { $g.deviceCount } else { '?' }
                    Write-Host "    [$($gi + 1)] $($g.name) (ID: $($g.id), Devices: $devCount)" -ForegroundColor White
                }
                if (-not $NonInteractive) {
                    Write-Host ""
                    $groupChoice = Read-Host -Prompt "  Select group number [default: 1]"
                    if (-not $groupChoice) { $groupChoice = '1' }
                    $groupIdx = [int]$groupChoice - 1
                    if ($groupIdx -ge 0 -and $groupIdx -lt $matchingGroups.Count) {
                        $resolvedGroupId = $matchingGroups[$groupIdx].id
                        Write-Host "  Selected: '$($matchingGroups[$groupIdx].name)' (ID: $resolvedGroupId)" -ForegroundColor Green
                    }
                    else {
                        Write-Warning "Invalid selection. Using first match."
                        $resolvedGroupId = $matchingGroups[0].id
                    }
                }
                else {
                    $resolvedGroupId = $matchingGroups[0].id
                    Write-Host "  Auto-selected: '$($matchingGroups[0].name)' (ID: $resolvedGroupId)" -ForegroundColor Gray
                }
            }
            else {
                Write-Host "  No groups matching '$DeviceGroupSearch'. Falling back to all devices." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Warning "Failed to search device groups: $_. Falling back to all devices."
        }
    }

    if (-not $resolvedGroupId) { $resolvedGroupId = '-1' }
    Write-Host "Fetching devices from group $resolvedGroupId..." -ForegroundColor Cyan
    $devices = @(Get-WUGDevice -DeviceGroupID $resolvedGroupId)

    if ($WindowsOnly -and $devices.Count -gt 0) {
        $preCount = $devices.Count
        $devices = @($devices | Where-Object {
            ($_.role -and $_.role -match 'Windows') -or
            ($_.description -and $_.description -match 'Windows')
        })
        $filtered = $preCount - $devices.Count
        if ($filtered -gt 0) {
            Write-Host "  Filtered to Windows devices: $($devices.Count) of $preCount (skipped $filtered non-Windows)." -ForegroundColor Gray
        }
    }
}

if (-not $devices -or $devices.Count -eq 0) {
    Write-Error "No devices found. Exiting."
    return
}

Write-Host "Found $($devices.Count) device(s)." -ForegroundColor Green
Write-Host "Attributes to collect: $($activeAttributes.Count) ($($activeAttributes.Keys -join ', '))" -ForegroundColor Gray
Write-Host "WMI classes needed: $($requiredClasses -join ', ')" -ForegroundColor Gray
Write-Host ""

# =============================================================================
# STEP 2: Scan each device via WMI and collect attribute data
# =============================================================================
$deviceAttrs  = @{}   # devId -> hashtable of attrKey -> value
$deviceInfo   = @{}   # devId -> @{ Name; IP }
$scannedCount = 0
$failedDevices = 0

$scanIndex = 0
foreach ($dev in $devices) {
    $scanIndex++
    $devId   = $dev.id
    $devName = if ($dev.displayName) { $dev.displayName } else { $dev.hostName }
    $devIP   = $dev.networkAddress

    if (-not $devIP) {
        Write-Warning "Device '$devName' (ID: $devId) has no network address. Skipping."
        continue
    }

    $deviceInfo[$devId] = @{ Name = $devName; IP = $devIP }

    $pct = [Math]::Round(($scanIndex / $devices.Count) * 100)
    Write-Progress -Activity "Scanning devices via WMI" `
        -Status "$devName ($devIP) [$scanIndex of $($devices.Count)]" `
        -PercentComplete $pct

    Write-Host "  [$scanIndex/$($devices.Count)] $devName ($devIP)..." -ForegroundColor Gray -NoNewline

    # Try each credential
    $scanSuccess = $false
    for ($ci = 0; $ci -lt $credentialList.Count; $ci++) {
        $tryCred = $credentialList[$ci]
        if ($credentialList.Count -gt 1 -and $ci -gt 0) {
            Write-Host "" -NoNewline
            Write-Host "    Retrying with credential #$($ci + 1) ($($tryCred.UserName))..." -ForegroundColor DarkGray -NoNewline
        }

        try {
            # Query each required WMI class once per device, cache results
            # WMI does not allow explicit credentials for local connections
            $isLocal = ($devIP -eq 'localhost' -or $devIP -eq '127.0.0.1' -or $devIP -eq '::1' -or $devIP -eq $env:COMPUTERNAME -or $devIP -eq '.')
            $wmiCache = @{}
            foreach ($cls in $requiredClasses) {
                if ($isLocal) {
                    $wmiCache[$cls] = Get-WmiObject -Class $cls -ErrorAction Stop
                } else {
                    $wmiCache[$cls] = Get-WmiObject -Class $cls -ComputerName $devIP -Credential $tryCred -ErrorAction Stop
                }
            }

            # Extract attribute values
            $attrs = [ordered]@{}
            foreach ($key in $activeAttributes.Keys) {
                $def = $activeAttributes[$key]

                if ($def.Compute) {
                    # Compute-style: pass full cache + connection info + local flag
                    try {
                        $val = & $def.Compute $wmiCache $devIP $tryCred $isLocal
                    }
                    catch {
                        Write-Verbose "  Compute failed for '$key' on ${devIP}: $_"
                        $val = ''
                    }
                }
                else {
                    # Simple Class+Property style
                    $wmiObj = $wmiCache[$def.Class]
                    if (-not $wmiObj) { $attrs[$key] = ''; continue }

                    # Some classes return arrays (e.g. Win32_Processor) -- take first
                    $obj = if ($wmiObj -is [System.Array]) { $wmiObj[0] } else { $wmiObj }

                    $rawVal = $obj.($def.Property)
                    if ($def.Transform) {
                        $val = & $def.Transform $rawVal
                    }
                    else {
                        $val = if ($null -ne $rawVal) { "$rawVal".Trim() } else { '' }
                    }
                }
                $attrs[$key] = $val
            }

            $deviceAttrs[$devId] = $attrs
            $scannedCount++
            $credLabel = if ($credentialList.Count -gt 1) { " [cred #$($ci + 1)]" } else { '' }
            Write-Host " OK ($($attrs.Count) attrs)$credLabel" -ForegroundColor Green
            $scanSuccess = $true
            break
        }
        catch [System.UnauthorizedAccessException] {
            if ($ci -lt ($credentialList.Count - 1)) {
                Write-Verbose "Credential #$($ci + 1) access denied on ${devIP}. Trying next."
                continue
            }
            Write-Host " access denied (all $($credentialList.Count) credential(s) failed)." -ForegroundColor Red
            $failedDevices++
        }
        catch [System.Runtime.InteropServices.COMException] {
            $comMsg = $_.Exception.Message
            if ($comMsg -match 'Access is denied|0x80070005') {
                if ($ci -lt ($credentialList.Count - 1)) {
                    Write-Verbose "Credential #$($ci + 1) COM access denied on ${devIP}. Trying next."
                    continue
                }
                Write-Host " access denied (all $($credentialList.Count) credential(s) failed)." -ForegroundColor Red
            }
            else {
                Write-Host " WMI/RPC unavailable." -ForegroundColor Red
            }
            $failedDevices++
        }
        catch {
            Write-Host " failed: $($_.Exception.Message)" -ForegroundColor Red
            $failedDevices++
            break
        }
    }
}

Write-Progress -Activity "Scanning devices via WMI" -Completed

if ($deviceAttrs.Count -eq 0) {
    Write-Warning "No device attributes collected. Nothing to do."
    return
}

# =============================================================================
# Summary
# =============================================================================
Write-Host ""
Write-Host "--- Scan Summary ---" -ForegroundColor Cyan
Write-Host "  Devices scanned OK:    $scannedCount" -ForegroundColor White
Write-Host "  Devices failed:        $failedDevices" -ForegroundColor $(if ($failedDevices -gt 0) { 'Red' } else { 'Gray' })
Write-Host "  Attributes per device: $($activeAttributes.Count)" -ForegroundColor White
Write-Host ""

# Show collected data
foreach ($devId in ($deviceAttrs.Keys | Sort-Object)) {
    $info = $deviceInfo[$devId]
    Write-Host "  $($info.Name) ($($info.IP)):" -ForegroundColor White
    foreach ($key in $deviceAttrs[$devId].Keys) {
        $attrName = "${AttributePrefix}.${key}"
        $attrVal  = $deviceAttrs[$devId][$key]
        Write-Host "    $attrName = $attrVal" -ForegroundColor Gray
    }
}
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY RUN] No changes made." -ForegroundColor Yellow
    return
}

# =============================================================================
# STEP 3: Action routing (menu or -Action parameter)
# =============================================================================
if ($OutputPath) {
    $OutputDir = $OutputPath
} else {
    $OutputDir = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Output'
}
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$choice = $null
if ($Action) {
    switch ($Action) {
        'PushToWUG'        { $choice = '1' }
        'ExportJSON'       { $choice = '2' }
        'ExportCSV'        { $choice = '3' }
        'ShowTable'        { $choice = '4' }
        'Dashboard'        { $choice = '5' }
        'None'             { $choice = '6' }
        'DashboardAndPush' { $choice = '7' }
    }
}

if (-not $choice) {
    Write-Host "What would you like to do with the collected attributes?" -ForegroundColor Cyan
    if ($standaloneMode) {
        Write-Host "  [1] Push to WhatsUp Gold (not available in standalone mode)" -ForegroundColor DarkGray
    }
    else {
        Write-Host "  [1] Push attributes to WhatsUp Gold"
    }
    Write-Host "  [2] Export to JSON file"
    Write-Host "  [3] Export to CSV file"
    Write-Host "  [4] Show full table in console"
    Write-Host "  [5] Generate HTML dashboard (inventory report)"
    Write-Host "  [6] Exit (do nothing)"
    if (-not $standaloneMode) {
        Write-Host "  [7] Dashboard + Push to WUG"
    }
    Write-Host ""
    $choice = Read-Host -Prompt "Choice [1-7]"
}

# Handle DashboardAndPush: run Dashboard then PushToWUG sequentially
if ($choice -eq '7') {
    $actionsToRun = @('5', '1')
} else {
    $actionsToRun = @($choice)
}

# Build export-friendly data for JSON/CSV/Table/Dashboard
# Attribute keys that hold numeric values (cast for dashboard thresholds)
$numericAttrs = @('TotalMemoryGB', 'FreeMemoryGB', 'RAMSticks', 'RAMSpeedMHz',
    'CPUCores', 'CPULogical', 'CPUSpeedMHz', 'GPUMemoryMB',
    'DiskCount', 'TotalDiskGB', 'NetworkAdapters',
    'RunningServices', 'StoppedServices', 'InstalledSoftware')

$exportData = @()
foreach ($devId in ($deviceAttrs.Keys | Sort-Object)) {
    $info  = $deviceInfo[$devId]
    $attrs = $deviceAttrs[$devId]
    $row   = [ordered]@{
        DeviceId = $devId
        Host     = $info.Name
        IP       = $info.IP
    }
    foreach ($key in $attrs.Keys) {
        $val = $attrs[$key]
        if ($numericAttrs -contains $key -and $val -match '^\d+(\.\d+)?$') {
            $row["${AttributePrefix}.${key}"] = [double]$val
        }
        else {
            $row["${AttributePrefix}.${key}"] = $val
        }
    }
    $exportData += [PSCustomObject]$row
}

foreach ($currentChoice in $actionsToRun) {
switch ($currentChoice) {
    '1' {
        # PushToWUG
        if ($standaloneMode) {
            Write-Warning "Push to WUG requires devices resolved from WhatsUp Gold. Omit -Target or use -DeviceId."
            continue
        }

        Write-Host "Updating device attributes in WhatsUp Gold..." -ForegroundColor Cyan

        $updatedCount = 0
        $errorCount   = 0
        $totalAttrs   = 0

        $devIndex = 0
        foreach ($devId in ($deviceAttrs.Keys | Sort-Object)) {
            $devIndex++
            $info  = $deviceInfo[$devId]
            $attrs = $deviceAttrs[$devId]

            $pct = [Math]::Round(($devIndex / $deviceAttrs.Count) * 100)
            Write-Progress -Activity "Updating device attributes" `
                -Status "$($info.Name) [$devIndex of $($deviceAttrs.Count)]" `
                -PercentComplete $pct

            foreach ($key in $attrs.Keys) {
                $attrName = "${AttributePrefix}.${key}"
                $attrVal  = $attrs[$key]
                $totalAttrs++

                if ([string]::IsNullOrEmpty($attrVal)) {
                    Write-Verbose "  Skipping empty attribute '$attrName' on $($info.Name)"
                    continue
                }

                if (-not $PSCmdlet.ShouldProcess("$($info.Name) (ID: $devId)", "Set attribute '$attrName' = '$attrVal'")) {
                    continue
                }

                try {
                    Set-WUGDeviceAttribute -DeviceId $devId -Name $attrName -Value $attrVal -Confirm:$false | Out-Null
                    $updatedCount++
                    Write-Verbose "  Set $attrName = $attrVal on $($info.Name)"
                }
                catch {
                    Write-Warning "  Failed to set '$attrName' on $($info.Name) (ID: ${devId}): $_"
                    $errorCount++
                }
            }

            # Stamp last-run timestamp per device
            $lastRunName = "${AttributePrefix}.LastRun"
            $lastRunVal  = (Get-Date).ToString('o')
            if ($PSCmdlet.ShouldProcess("$($info.Name) (ID: $devId)", "Set attribute '$lastRunName' = '$lastRunVal'")) {
                try {
                    Set-WUGDeviceAttribute -DeviceId $devId -Name $lastRunName -Value $lastRunVal -Confirm:$false | Out-Null
                    Write-Verbose "  Set $lastRunName = $lastRunVal on $($info.Name)"
                }
                catch {
                    Write-Warning "  Failed to set '$lastRunName' on $($info.Name) (ID: ${devId}): $_"
                }
            }
        }

        Write-Progress -Activity "Updating device attributes" -Completed

        Write-Host ""
        Write-Host "=== Windows Attributes Push Complete ===" -ForegroundColor Cyan
        Write-Host "  Devices processed:     $($deviceAttrs.Count)" -ForegroundColor Green
        Write-Host "  Attributes updated:    $updatedCount" -ForegroundColor Green
        Write-Host "  Attributes skipped:    $($totalAttrs - $updatedCount - $errorCount)" -ForegroundColor Gray
        Write-Host "  Errors:                $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { 'Red' } else { 'Gray' })
        Write-Host ""
    }
    '2' {
        # ExportJSON
        $jsonPath = Join-Path $OutputDir "WindowsAttributes-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $exportData | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding UTF8
        Write-Host "Exported to: $jsonPath" -ForegroundColor Green
    }
    '3' {
        # ExportCSV
        $csvPath = Join-Path $OutputDir "WindowsAttributes-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
        $exportData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Exported to: $csvPath" -ForegroundColor Green
    }
    '4' {
        # ShowTable
        $exportData | Format-Table -AutoSize
    }
    '5' {
        # Dashboard - generate HTML inventory report
        $dashPath = Join-Path $OutputDir 'WindowsAttributes-Dashboard.html'

        if (Get-Command -Name 'Export-WindowsAttributesDashboardHtml' -ErrorAction SilentlyContinue) {
            Export-WindowsAttributesDashboardHtml -DashboardData $exportData `
                -OutputPath $dashPath `
                -ReportTitle 'Windows Attributes Inventory'
        }
        elseif (Get-Command -Name 'Export-DynamicDashboardHtml' -ErrorAction SilentlyContinue) {
            $thresholds = @(
                @{ Field = 'Windows.FreeMemoryGB'; Warning = 4; Critical = 2; Invert = $true }
                @{ Field = 'Windows.StoppedServices'; Warning = 50; Critical = 80 }
            )
            Export-DynamicDashboardHtml -Data $exportData `
                -OutputPath $dashPath `
                -ReportTitle 'Windows Attributes Inventory' `
                -CardField @('Windows.IsVirtualMachine', 'Windows.Domain') `
                -ThresholdField $thresholds `
                -ExportPrefix 'WindowsAttributes'
        }
        else {
            Write-Warning "No dashboard function available. Exporting as JSON instead."
            $jsonPath = Join-Path $OutputDir "WindowsAttributes-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
            $exportData | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding UTF8
            Write-Host "JSON exported: $jsonPath" -ForegroundColor Green
            break
        }

        Write-Host "Dashboard generated: $dashPath" -ForegroundColor Green
        Write-Host "  Devices: $($deviceAttrs.Count) | Attributes: $($activeAttributes.Count)" -ForegroundColor Gray
    }
    '6' {
        Write-Host "No action taken." -ForegroundColor Gray
    }
    default {
        Write-Warning "Invalid choice '$currentChoice'."
    }
}
} # end foreach actionsToRun

Write-Host ""
Write-Host "=== Windows Attributes Discovery Complete ===" -ForegroundColor Cyan
Write-Host ""

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDQjqd18MuT+Qdv
# fjVppipEeIgLAAdF8jdZwNHBP0fbM6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCCl4xE9DCSuQEAHAOmAbqZc+WdjhZ+dWymgalCZthHuYjANBgkqhkiG9w0BAQEF
# AASCAgDdFq5vXheNLsJxzBF/luLd9gAazj1/p8Pd9cHPHFc6s9IUW69H2y4KQMxV
# iQibbTg9YZ6q2SoGz35WOd5dxahocUYxeK3bx3n6XWOg6yk8ljl+TDCc9OXUvGmM
# aesZ04MagwIz43y3zbWSYkihISR4yN2MrzpOlyDP2f6meOUmWsiBCTEBtBJJszDT
# pICvWCYzjHYfO/vvCiAwC38O2ZZHwuo9QtlF6QB40wRmsEtH6jlXzbRu25pqe1Xi
# c1eelG81lNnvqMjwJ5Ll7CT8afHxqTXjFulpgU1YxXbcf+2+4+0JCxM/yHQU8YyU
# PV8ccrYTGwXYjLfIu55cztTST+B18tsOJimseAXIWemWgc1ufT96LNTVU2UoGUeM
# /+u2NrzH3af7lEB3y3X5sQ8SPM9E4q31X/jE8sUb/gt4GF5D0bHCNYAkwvW6mDdB
# zFmHbRYpOn4WnCLtvCYuTmy+mx4QDTGS4wvJI2B7Pnj8RWl+DtEpkv2v3NW4WSH8
# cA9wUmOpoD/46jC51BUV9bdHK+ynivHhlRzbHZunULC9SPp9NPXrwZFG5ef/ecZV
# /QGl3jz8YII4f+O+DTGjT9PSoFBrjE1Dpp2hWF8QhimlTcP2EfMY136P2ZwguTGu
# jkqUwTjfks0A1ksR+OjSQgA3g4AtsloypEisEhUGMmgt2ZdE+KGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MTkwMDAzNDRaMC8GCSqGSIb3DQEJBDEiBCB2YzKb
# NfaiWA5EVr/VQHsDXOYeowuOr0Ox8qCiDMrH4TANBgkqhkiG9w0BAQEFAASCAgB4
# qtI7mh2uwgHXRd6x8mPHFCbIj/QsuNswZadnvaD7EOKhCB8uPfg6N/129rhyeE3T
# 0A7bb6m04S5XzTIVKEhdII0s0mwlXnoUvYcQCxa5WdeHCiNHrlmgWgXXmMhUjxfq
# YVoOUlnkQbOu/4P/su4cfxQYgPpYD7W9D+FgY53/1MT0iiLcvtHE/Au2i83vc7XI
# ZT+yKcmE4K3qiLrCZq8EMcD/KHc+r+L5lWQagXmdcTYEWL1OyzABy6LsTcGKt8TB
# 8xJED7xuhakrc4SjPkAyzZx6uiOWv9kZsJ2ICD8vT+xaJzl6fr0Nq4NIpYhN/GkV
# XQva0rC4Sh6c6q8ljNubmF2anSBch+cgNcPAwlusu4kXoDN5tsHb5F+8Ns9z5lDJ
# egHFYBKke8snJ5cTbyvKmx8zS82Yb2zDpD2bx1ZHpFoQpUMcFKMGl7qEvr+ATtFc
# Ula3My7YHKckg1JJH5tUzsOszV0ec87DR2xN/IoC3k+Z0PAUANyZjgRqvwZYP9uE
# TmuYewnNMmyRr2ZR0Yx+ZrXEuL/rfPXxxf8uoduWGQBkg/KKbCsrKdLaNWuyTIGS
# KKWMsMValY12JTeimiH5aUeetxRRMxvFZHie1f/NXJ///THFpdquYrBzQXXbiitE
# t2BNvJOvnqfc9BNsEy92oYnvGjvL9JntnGV/GKi9iQ==
# SIG # End signature block
