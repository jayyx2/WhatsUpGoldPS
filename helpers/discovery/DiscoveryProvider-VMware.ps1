<#
.SYNOPSIS
    VMware vSphere discovery provider for infrastructure monitoring.

.DESCRIPTION
    Registers a VMware discovery provider that discovers ESXi hosts and
    virtual machines, then builds a monitor plan suitable for WhatsUp Gold
    REST API monitors or standalone use.

    Two collection methods:
      [1] VMware PowerCLI -- uses Connect-VIServer, Get-VMHost, Get-VM, etc.
      [2] REST API direct -- zero external dependencies, uses vCenter REST API

    The method is selected by the caller via Credential.UseRestApi = $true/$false.

    Discovery discovers:
      - ESXi hosts (IP, CPU, Memory, Storage, Version, Power State)
      - Virtual machines (IP, CPU, Memory, Guest OS, Tools Status)

    Authentication:
      PSCredential (username + password) stored in DPAPI vault.
      For WUG monitors, each device can be polled via standard SNMP/WMI
      or via custom REST API monitors pointing at vCenter API.

    Prerequisites:
      Module mode: VMware PowerCLI installed
      REST mode: No external dependencies (vSphere 6.5+ required)

.NOTES
    Author: Jason Alberino (jason@wug.ninja)
    Requires: DiscoveryHelpers.ps1 loaded first
    Encoding: UTF-8 with BOM
#>

# Ensure DiscoveryHelpers is available
if (-not (Get-Command -Name 'Register-DiscoveryProvider' -ErrorAction SilentlyContinue)) {
    $discoveryPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'DiscoveryHelpers.ps1'
    if (Test-Path $discoveryPath) {
        . $discoveryPath
    }
    else {
        throw "DiscoveryHelpers.ps1 not found. Load it before this provider."
    }
}

# Ensure VMwareHelpers is available
$vmwareHelpersPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) '..\vmware\VMwareHelpers.ps1'
if (Test-Path $vmwareHelpersPath) {
    . $vmwareHelpersPath
}

# ============================================================================
# VMware Discovery Provider
# ============================================================================

Register-DiscoveryProvider -Name 'VMware' `
    -MatchAttribute 'DiscoveryHelper.VMware' `
    -AuthType 'BasicAuth' `
    -DefaultPort 443 `
    -DefaultProtocol 'https' `
    -IgnoreCertErrors $true `
    -DiscoverScript {
        param($ctx)

        $items = @()
        $deviceIP   = $ctx.DeviceIP
        $ignoreCert = if ($ctx.IgnoreCertErrors) { '1' } else { '0' }

        # --- Resolve credential ---
        $cred = $null
        if ($ctx.Credential -and $ctx.Credential.PSCredential -and $ctx.Credential.PSCredential -is [PSCredential]) {
            $cred = $ctx.Credential.PSCredential
        }
        elseif ($ctx.Credential -and $ctx.Credential.Username -and $ctx.Credential.Password) {
            $secPwd = ConvertTo-SecureString $ctx.Credential.Password -AsPlainText -Force
            $cred = [PSCredential]::new($ctx.Credential.Username, $secPwd)
        }
        elseif ($ctx.Credential -and $ctx.Credential -is [PSCredential]) {
            $cred = $ctx.Credential
        }

        if (-not $cred) {
            Write-Warning "No valid VMware credential available."
            return $items
        }

        # Determine collection method
        $useRest = $false
        if ($ctx.Credential -and $ctx.Credential.UseRestApi) {
            $useRest = $ctx.Credential.UseRestApi
        }

        # ================================================================
        # Phase 1: Connect and enumerate
        # ================================================================
        $hostMap = @{}   # hostName -> @{ IP; Cluster; PowerState; Version; Build; ... }
        $vmMap   = @{}   # vmName -> @{ IP; ESXiHost; PowerState; GuestOS; ... }

        if ($useRest) {
            # --- REST API mode ---
            try {
                Write-Host "  Connecting to vCenter REST API at $deviceIP..." -ForegroundColor DarkGray
                $connParams = @{
                    Server     = $deviceIP
                    Credential = $cred
                    Port       = $ctx.Port
                    IgnoreSSLErrors = ($ignoreCert -eq '1')
                }
                Connect-VMwareREST @connParams
                Write-Host "  Connected to vCenter REST API." -ForegroundColor DarkGray
            }
            catch {
                Write-Warning "Failed to connect to VMware REST API $deviceIP : $_"
                return $items
            }

            try {
                # ----------------------------------------------------------
                # Step 1: Enumerate ESXi hosts
                # ----------------------------------------------------------
                Write-Host "  Enumerating ESXi hosts..." -ForegroundColor DarkGray
                $esxiHosts = @(Get-VMwareHostsREST)
                Write-Host "  Found $($esxiHosts.Count) ESXi host(s)." -ForegroundColor DarkGray

                # Build hostId -> hostName lookup
                $hostIdToName = @{}
                foreach ($esxi in $esxiHosts) {
                    $hostIdToName[$esxi.HostId] = $esxi.Name
                }

                # ----------------------------------------------------------
                # Step 2: Resolve cluster-to-host membership
                # ----------------------------------------------------------
                Write-Host "  Resolving cluster membership..." -ForegroundColor DarkGray
                $clusterHostMap = @{}  # hostName -> clusterName
                try {
                    $clusters = @(Get-VMwareClustersREST)
                    foreach ($c in $clusters) {
                        try {
                            $cHosts = @(Invoke-VMwareREST -Path "/api/vcenter/host?clusters=$($c.ClusterId)")
                            foreach ($ch in $cHosts) {
                                $hName = "$($ch.name)"
                                if ($hName) { $clusterHostMap[$hName] = "$($c.Name)" }
                            }
                        }
                        catch { }
                    }
                    Write-Host "  Found $($clusters.Count) cluster(s)." -ForegroundColor DarkGray
                }
                catch { Write-Host "  No cluster info available." -ForegroundColor DarkGray }

                # ----------------------------------------------------------
                # Step 3: Build host entries with cluster + DNS IP
                # ----------------------------------------------------------
                foreach ($esxi in $esxiHosts) {
                    Write-Host "    Host: $($esxi.Name)" -ForegroundColor DarkGray
                    # Resolve management IP via DNS
                    $mgmtIP = $null
                    try {
                        $resolved = [System.Net.Dns]::GetHostAddresses($esxi.Name) |
                            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                            Select-Object -First 1
                        if ($resolved) { $mgmtIP = $resolved.IPAddressToString }
                    }
                    catch { }

                    $clusterName = if ($clusterHostMap.ContainsKey($esxi.Name)) { $clusterHostMap[$esxi.Name] } else { 'N/A' }

                    $hostMap[$esxi.Name] = @{
                        IP          = $mgmtIP
                        Cluster     = $clusterName
                        PowerState  = "$($esxi.PowerState)"
                        Version     = 'N/A'
                        Build       = 'N/A'
                        CpuSockets  = 'N/A'
                        CpuCores    = 'N/A'
                        MemTotalGB  = 'N/A'
                        Manufacturer= 'N/A'
                        Model       = 'N/A'
                    }
                }

                # ----------------------------------------------------------
                # Step 4: Build VM-to-host mapping (query VMs per host)
                # ----------------------------------------------------------
                Write-Host "  Mapping VMs to ESXi hosts..." -ForegroundColor DarkGray
                $vmIdToHost = @{}  # vmMoRef -> hostName
                foreach ($esxi in $esxiHosts) {
                    try {
                        $hostVMs = @(Invoke-VMwareREST -Path "/api/vcenter/vm?hosts=$($esxi.HostId)")
                        foreach ($hv in $hostVMs) {
                            $vmIdToHost["$($hv.vm)"] = $esxi.Name
                        }
                        Write-Host "    $($esxi.Name): $($hostVMs.Count) VM(s)" -ForegroundColor DarkGray
                    }
                    catch { Write-Host "    $($esxi.Name): error querying VMs" -ForegroundColor DarkYellow }
                }

                # ----------------------------------------------------------
                # Step 5: Discover VMs with full details
                # ----------------------------------------------------------
                Write-Host "  Enumerating VMs..." -ForegroundColor DarkGray
                $allVMs = @(Get-VMwareVMsREST)
                $vmTotal = $allVMs.Count
                Write-Host "  Found $vmTotal VM(s). Resolving details (this may take a while)..." -ForegroundColor DarkGray
                $vmCount = 0
                foreach ($vm in $allVMs) {
                    $vmCount++
                    if ($vmCount % 50 -eq 0 -or $vmCount -eq $vmTotal) {
                        Write-Host "    VM $vmCount / $vmTotal ..." -ForegroundColor DarkGray
                    }
                    $vmDetail = Get-VMwareVMDetailREST -VMId $vm.VMId -VMName $vm.Name
                    $vmIP = $vmDetail.IPAddress
                    if (-not $vmIP) { $vmIP = $null }

                    # Look up host + cluster from our mappings
                    $vmHostName = if ($vmIdToHost.ContainsKey($vm.VMId)) { $vmIdToHost[$vm.VMId] } else { 'N/A' }
                    $vmCluster = if ($vmHostName -ne 'N/A' -and $clusterHostMap.ContainsKey($vmHostName)) { $clusterHostMap[$vmHostName] } else { 'N/A' }

                    $vmMap[$vm.Name] = @{
                        IP         = $vmIP
                        ESXiHost   = $vmHostName
                        Cluster    = $vmCluster
                        PowerState = "$($vmDetail.PowerState)"
                        GuestOS    = "$($vmDetail.GuestOS)"
                        ToolsStatus= "$($vmDetail.ToolsStatus)"
                        NumCPU     = "$($vmDetail.NumCPU)"
                        MemoryGB   = "$($vmDetail.MemoryGB)"
                        DiskCount  = "$($vmDetail.DiskCount)"
                        NicCount   = "$($vmDetail.NicCount)"
                    }
                }
            }
            catch {
                Write-Warning "Error during VMware REST enumeration: $_"
            }
            finally {
                Write-Host "  Disconnecting from vCenter REST API..." -ForegroundColor DarkGray
                try { Disconnect-VMwareREST } catch { }
            }
        }
        else {
            # --- PowerCLI module mode ---
            try {
                $connParams = @{
                    Server     = $deviceIP
                    Credential = $cred
                    Port       = $ctx.Port
                }
                if ($ignoreCert -eq '1') {
                    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session -ErrorAction SilentlyContinue | Out-Null
                }
                $viConn = Connect-VIServer @connParams -ErrorAction Stop
                Write-Verbose "Connected to VMware: $deviceIP ($($viConn.ProductLine) $($viConn.Version))"
            }
            catch {
                Write-Warning "Failed to connect to VMware $deviceIP : $_"
                return $items
            }

            try {
                # Discover ESXi hosts
                $esxiHosts = Get-VMHost -ErrorAction Stop
                foreach ($esxi in $esxiHosts) {
                    $mgmtIP = $null
                    try {
                        $mgmtIP = (Get-VMHostNetworkAdapter -VMHost $esxi -VMKernel -ErrorAction SilentlyContinue |
                            Where-Object { $_.ManagementTrafficEnabled } | Select-Object -First 1).IP
                    }
                    catch { }
                    if (-not $mgmtIP) { $mgmtIP = $null }

                    $clusterName = if ($esxi.Parent -and $esxi.Parent.GetType().Name -eq 'ClusterImpl') {
                        "$($esxi.Parent.Name)"
                    } else { 'N/A' }

                    $hostMap[$esxi.Name] = @{
                        IP          = $mgmtIP
                        Cluster     = $clusterName
                        PowerState  = "$($esxi.PowerState)"
                        Version     = "$($esxi.Version)"
                        Build       = "$($esxi.Build)"
                        CpuSockets  = "$($esxi.ExtensionData.Hardware.CpuInfo.NumCpuPackages)"
                        CpuCores    = "$($esxi.ExtensionData.Hardware.CpuInfo.NumCpuCores)"
                        MemTotalGB  = "$([math]::Round($esxi.MemoryTotalGB, 2))"
                        Manufacturer= "$($esxi.Manufacturer)"
                        Model       = "$($esxi.Model)"
                    }
                }

                # Discover VMs
                $allVMs = Get-VM -ErrorAction Stop
                foreach ($vm in $allVMs) {
                    $vmIP = $null
                    try {
                        $guest = $vm | Get-VMGuest -ErrorAction SilentlyContinue
                        $vmIP = $guest.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
                    }
                    catch { }

                    $vmHost = "$($vm.VMHost.Name)"
                    $clusterName = if ($vm.VMHost.Parent -and $vm.VMHost.Parent.GetType().Name -eq 'ClusterImpl') {
                        "$($vm.VMHost.Parent.Name)"
                    } else { 'N/A' }

                    $vmMap[$vm.Name] = @{
                        IP         = $vmIP
                        ESXiHost   = $vmHost
                        Cluster    = $clusterName
                        PowerState = "$($vm.PowerState)"
                        GuestOS    = "$($vm.ExtensionData.Config.GuestFullName)"
                        ToolsStatus= "$($vm.ExtensionData.Guest.ToolsStatus)"
                        NumCPU     = "$($vm.NumCpu)"
                        MemoryGB   = "$($vm.MemoryGB)"
                        DiskCount  = "$(@($vm | Get-HardDisk -ErrorAction SilentlyContinue).Count)"
                        NicCount   = "$(@($vm | Get-NetworkAdapter -ErrorAction SilentlyContinue).Count)"
                    }
                }
            }
            catch {
                Write-Warning "Error during VMware enumeration: $_"
            }
            finally {
                try { Disconnect-VIServer -Server $deviceIP -Confirm:$false -ErrorAction SilentlyContinue } catch { }
            }
        }

        Write-Host "  Topology: $($hostMap.Count) ESXi host(s), $($vmMap.Count) VM(s)" -ForegroundColor DarkGray

        # ================================================================
        # Phase 2: Build discovery plan
        # ================================================================
        $baseAttrs = @{
            'VMware.vCenter'    = $deviceIP
            'VMware.Port'       = [string]$ctx.Port
            'DiscoveryHelper.VMware' = 'true'
            'DiscoveryHelper.VMware.LastRun' = (Get-Date).ToUniversalTime().ToString('o')
        }

        # --- vCenter device (the API entry point) ---
        $vcAttrs = $baseAttrs.Clone()
        $vcAttrs['VMware.DeviceType'] = 'vCenter'

        $items += New-DiscoveredItem `
            -Name 'VMware - vCenter Status' `
            -ItemType 'ActiveMonitor' `
            -MonitorType 'PowerShell' `
            -MonitorParams @{
                Description = 'Monitors vCenter connectivity and service health'
            } `
            -UniqueKey "VMware:vcenter:active:status" `
            -Attributes $vcAttrs `
            -Tags @('vmware', 'vcenter')

        # --- Per-Host items ---
        foreach ($hostName in @($hostMap.Keys | Sort-Object)) {
            $hostInfo = $hostMap[$hostName]
            $hostIP   = $hostInfo.IP

            $hostAttrs = $baseAttrs.Clone()
            $hostAttrs['VMware.DeviceType'] = 'ESXiHost'
            $hostAttrs['VMware.HostName']   = $hostName
            $hostAttrs['VMware.Cluster']    = $hostInfo.Cluster
            $hostAttrs['VMware.PowerState'] = $hostInfo.PowerState
            $hostAttrs['VMware.Version']    = $hostInfo.Version
            $hostAttrs['VMware.Build']      = $hostInfo.Build
            if ($hostIP) { $hostAttrs['VMware.HostIP'] = $hostIP }

            $items += New-DiscoveredItem `
                -Name 'VMware - ESXi Host Status' `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'PowerShell' `
                -MonitorParams @{
                    Description = "Monitors ESXi host $hostName connectivity"
                } `
                -UniqueKey "VMware:host:${hostName}:active:status" `
                -Attributes $hostAttrs `
                -Tags @('vmware', 'esxi', $hostName, $(if ($hostIP) { $hostIP } else { 'no-ip' }))

            $hostPerfMonitors = @(
                @{ Name = 'VMware - Host CPU';    Key = 'cpu' }
                @{ Name = 'VMware - Host Memory'; Key = 'memory' }
                @{ Name = 'VMware - Host Network'; Key = 'network' }
                @{ Name = 'VMware - Host Disk';   Key = 'disk' }
            )
            foreach ($pm in $hostPerfMonitors) {
                $items += New-DiscoveredItem `
                    -Name $pm.Name `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'PowerShell' `
                    -MonitorParams @{
                        Description = "$($pm.Name) for host $hostName"
                    } `
                    -UniqueKey "VMware:host:${hostName}:perf:$($pm.Key)" `
                    -Attributes $hostAttrs `
                    -Tags @('vmware', 'esxi', $hostName, $(if ($hostIP) { $hostIP } else { 'no-ip' }))
            }
        }

        # --- Per-VM items ---
        foreach ($vmName in @($vmMap.Keys | Sort-Object)) {
            $vmInfo = $vmMap[$vmName]
            $vmIP   = $vmInfo.IP

            $vmAttrs = $baseAttrs.Clone()
            $vmAttrs['VMware.DeviceType']  = 'VM'
            $vmAttrs['VMware.VMName']      = $vmName
            $vmAttrs['VMware.ESXiHost']    = $vmInfo.ESXiHost
            $vmAttrs['VMware.Cluster']     = $vmInfo.Cluster
            $vmAttrs['VMware.PowerState']  = $vmInfo.PowerState
            $vmAttrs['VMware.GuestOS']     = $vmInfo.GuestOS
            $vmAttrs['VMware.ToolsStatus'] = $vmInfo.ToolsStatus
            $vmAttrs['VMware.NumCPU']      = $vmInfo.NumCPU
            $vmAttrs['VMware.MemoryGB']    = $vmInfo.MemoryGB
            if ($vmInfo.DiskCount) { $vmAttrs['VMware.DiskCount'] = $vmInfo.DiskCount }
            if ($vmInfo.NicCount)  { $vmAttrs['VMware.NicCount']  = $vmInfo.NicCount }
            if ($vmIP) { $vmAttrs['VMware.VMIP'] = $vmIP }

            $items += New-DiscoveredItem `
                -Name 'VMware - VM Status' `
                -ItemType 'ActiveMonitor' `
                -MonitorType 'PowerShell' `
                -MonitorParams @{
                    Description = "Monitors VM $vmName power state"
                } `
                -UniqueKey "VMware:vm:${vmName}:active:status" `
                -Attributes $vmAttrs `
                -Tags @('vmware', 'vm', $vmName, $(if ($vmIP) { $vmIP } else { 'no-ip' }), $vmInfo.ESXiHost)

            $vmPerfMonitors = @(
                @{ Name = 'VMware - VM CPU';     Key = 'cpu' }
                @{ Name = 'VMware - VM Memory';  Key = 'memory' }
                @{ Name = 'VMware - VM Network'; Key = 'network' }
                @{ Name = 'VMware - VM Disk';    Key = 'disk' }
            )
            foreach ($pm in $vmPerfMonitors) {
                $items += New-DiscoveredItem `
                    -Name $pm.Name `
                    -ItemType 'PerformanceMonitor' `
                    -MonitorType 'PowerShell' `
                    -MonitorParams @{
                        Description = "$($pm.Name) for VM $vmName"
                    } `
                    -UniqueKey "VMware:vm:${vmName}:perf:$($pm.Key)" `
                    -Attributes $vmAttrs `
                    -Tags @('vmware', 'vm', $vmName, $(if ($vmIP) { $vmIP } else { 'no-ip' }), $vmInfo.ESXiHost)
            }
        }

        $cred = $null; $secPwd = $null
        return $items
    }

# ==============================================================================
# Export-VMwareDiscoveryDashboardHtml
# ==============================================================================
function Export-VMwareDiscoveryDashboardHtml {
    <#
    .SYNOPSIS
        Generates a VMware dashboard HTML file from live vSphere data.
    .DESCRIPTION
        Reads the VMware dashboard template from the discovery directory,
        injects column definitions and row data as JSON, and writes the
        final HTML to OutputPath. Uses the same template as the standalone
        VMware dashboard but sourced from the discovery folder.
    .PARAMETER DashboardData
        Array of PSCustomObject rows — one per host or VM.
    .PARAMETER OutputPath
        File path for the generated HTML.
    .PARAMETER ReportTitle
        Dashboard title shown in header and browser tab.
    .PARAMETER TemplatePath
        Path to VMware-Dashboard-Template.html. Defaults to same directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'VMware vSphere Dashboard',
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot 'VMware-Dashboard-Template.html'
        if (-not (Test-Path $TemplatePath)) {
            $TemplatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'vmware\VMware-Dashboard-Template.html'
        }
    }
    if (-not (Test-Path $TemplatePath)) {
        Write-Error "Template not found: $TemplatePath"
        return
    }

    $titleMap = @{
        'Type'              = 'Type'
        'Name'              = 'Name'
        'PowerState'        = 'Power State'
        'IPAddress'         = 'IP Address'
        'Cluster'           = 'Cluster'
        'ESXiHost'          = 'ESXi Host'
        'GuestOS'           = 'Guest OS'
        'ToolsStatus'       = 'Tools Status'
        'CPU'               = 'CPU'
        'Memory'            = 'Memory'
        'CpuUsagePct'       = 'CPU %'
        'MemUsagePct'       = 'Mem %'
        'NetUsageKBps'      = 'Net KBps'
        'DiskUsageKBps'     = 'Disk KBps'
        'Hardware'          = 'Hardware'
        'VersionBuild'      = 'Version / Build'
        'Datastores'        = 'Datastores'
        'ProvisionedSpaceGB' = 'Provisioned GB'
        'UsedSpaceGB'       = 'Used GB'
        'NicCount'          = 'NICs'
        'DiskCount'         = 'Disks'
        'DiskLatencyMs'     = 'Disk Latency ms'
    }

    $firstObj = $DashboardData | Select-Object -First 1
    $columns = @()
    foreach ($prop in $firstObj.PSObject.Properties) {
        $title = if ($titleMap.ContainsKey($prop.Name)) { $titleMap[$prop.Name] } else { ($prop.Name -creplace '(?<=[a-z])([A-Z])', ' $1').Trim() }
        $col = @{
            field      = $prop.Name
            title      = $title
            sortable   = $true
            searchable = $true
        }
        if ($prop.Name -eq 'PowerState')  { $col.formatter = 'formatPowerState' }
        if ($prop.Name -eq 'ToolsStatus') { $col.formatter = 'formatToolsStatus' }
        if ($prop.Name -eq 'Type')        { $col.formatter = 'formatType' }
        $columns += $col
    }

    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
    $dataJson    = ConvertTo-Json -InputObject @($DashboardData) -Depth 5 -Compress

    $tableConfig = @"
        columns: $columnsJson,
        data: $dataJson
"@

    $html = Get-Content -Path $TemplatePath -Raw
    $html = $html -replace 'replaceThisHere', $tableConfig
    $html = $html -replace 'ReplaceYourReportNameHere', $ReportTitle
    $html = $html -replace 'ReplaceUpdateTimeHere', (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    $parentDir = Split-Path $OutputPath -Parent
    if ($parentDir -and -not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    Set-Content -Path $OutputPath -Value $html -Encoding UTF8
    Write-Verbose "Dashboard written to: $OutputPath"
    return $OutputPath
}

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDQN9prstfYTljB
# Uojn/nVAeMUuRLBdQNM+g/XNAc3eVqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCCT1HlWC3Qu4ARYc0HVUBdmwj+YAQWpUh1cDmqr+LJaPjANBgkqhkiG9w0BAQEF
# AASCAgAVzJewL9E4E9kWCwJwctTM1PzqV+YZWPeG3MH9gR7roTkIQpJWnN6CFxao
# CQGIl3F5DYa66qWBKsP9/3rgZuq3HE1SvXCoaPuwnQFW6YveZOoFHMrG89MdckKB
# TKDPqZ6nFLivMw2CoeII7EYzy1/fje0NWgM4t07TX2cehwc25NwPz9XmSntDCCSY
# f7BnXxi0Py1PbTSVlgBjJYPQopiAt+Hxyi/7sZZV9iG8mM2udqOV/gjZnW87bwQq
# 6IsiDQzJD7y7i0wN9xnYa7RE+Tb/xfjVkwVaYgfJI1256f5ZC5koVxMAZik0OBMC
# rWpoZJPW87Cq14R7Cj5TZkz0IZy9VFsqT8J9CmZYCw26c/N7yqKB7qBV+0/+aSfj
# +kcg1yptNoYOJWDfa+rutigQAEA/MeRl5R4/swx9Ybej+oTJF587kXcRRGOoXNzt
# qAt0omcN9cMYaghch+gcvNxizDbi69yDoiF+jZGhUtM0AezW4KuOwADtAELJknSM
# QpJLHO4AXu262oLvdgZrb1Z7MF7q5+VZ1u66wlhdzSw3u3KEjuezh0DtiMI//vLj
# waDc1yUcjYHJ7Eolg7h77RxgY6ofpC7/n3pg5LxKfvk67LkauooQiT075NRJ00Sz
# RA5iVn+TbLCKLOH0QrbuYYzwydhPCHRXabHDCRnjIIEj9dtYyKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MTkxNzIwMjhaMC8GCSqGSIb3DQEJBDEiBCBY65jS
# 5aE7W3r1yhzH2nNW44h/xqAVf0fGWGUutOH7ajANBgkqhkiG9w0BAQEFAASCAgCO
# 6n/XamjAvo4KEr+6kaJG6IGEcSLktdImtJlNrck/Z40v2c6feUAAYbmNp4vvOAR7
# zU4mJpsuLDoubPbeBwFGzD0KAOPqUjp4FgI8ZWBbG94aLVyP37/Ga5xwLw6PYf5Q
# 0FoFyaGkV1guaukyK/EbwBMfGOolbxrp3EoU5qSitBXmaSLNrJoK06SZ/9kKARwo
# i+sFBqxXm+SG5MYPGIBtT/mwJjy2VZG4PgEuDI5nfZVh6U0ITFhVWnV3UmovV8kf
# tc5+V5gBRqVPsd/7/NkqwQoK891F0Vd2Ibu+gP5hz5oxS5jgaRghzLzWIHVkLAkT
# /9tM7CrY5Vzr41K9PILqnSBajuBu4lB/dTA5H+6iPrbF0dyo3fBe89HLhMKNDOEv
# 3LhSgB4FnOrRe1IFpPHvNLQ/u1eHG74d7utEdqT6tvcjitGrejPXeeuGx8YbWBap
# zzuaby0IiO1UiERgCefhClYYimzAIJse4vS05DtFbL1zWvOCCmhUV01A4XyutPCy
# xtZxZJVM18NJimEKmWpiFDhoY5dAPj4/amPwVNzk0sh2202YFS4CwMhi4kfXSCDa
# 58hNaBNyOLyGN9lp3z79UJJqcQVypj59Um4Qk5RVqgdw+mNPVmDTw+xWDzDkazyN
# hKFlm1ZjEYVPEWKJeG0dBBSQVSdDMcTUQAopLSXHog==
# SIG # End signature block
