<#
.SYNOPSIS
    End-to-end integration test harness for every WhatsUpGoldPS cmdlet.

.DESCRIPTION
    Invoke-WUGModuleTest connects to a WhatsUp Gold server, creates temporary test
    devices and resources, exercises every module cmdlet against the live API, records
    pass/fail for each endpoint, cleans up all test artefacts, and prints a summary.

    The script is interactive only for the initial server and credential prompt.
    Everything else runs automatically with -Confirm:$false on all write operations.

.PARAMETER ServerUri
    The WhatsUp Gold server hostname or IP. If omitted you will be prompted.

.PARAMETER Credential
    A PSCredential for authentication. If omitted you will be prompted via Get-Credential.

.PARAMETER Port
    API port. Default 9644.

.PARAMETER Protocol
    http or https. Default https.

.PARAMETER IgnoreSSLErrors
    Pass -IgnoreSSLErrors to Connect-WUGServer when set.

.EXAMPLE
    .\Invoke-WUGModuleTest.ps1
    # Prompts for server and credentials, then runs all tests.

.EXAMPLE
    .\Invoke-WUGModuleTest.ps1 -ServerUri "wug.lab.local" -Credential (Get-Credential)

.NOTES
    Author : Jason Alberino (jason@wug.ninja)
    Created: 2026-03-08
    Requires: WhatsUpGoldPS module loaded or available in $env:PSModulePath.
#>
[CmdletBinding()]
param(
    [string]$ServerUri,
    [PSCredential]$Credential,
    [int]$Port = 9644,
    [ValidateSet('http', 'https')]
    [string]$Protocol = 'https',
    [switch]$IgnoreSSLErrors
)

#region ── Helpers ────────────────────────────────────────────────────────────
$script:TestResults = [System.Collections.Generic.List[PSCustomObject]]::new()

function Record-Test {
    param(
        [string]$Cmdlet,
        [string]$Endpoint,
        [string]$Status,        # Pass | Fail | Skipped
        [string]$Detail = ''
    )
    $script:TestResults.Add([PSCustomObject]@{
        Cmdlet   = $Cmdlet
        Endpoint = $Endpoint
        Status   = $Status
        Detail   = $Detail
    })
    $color = switch ($Status) { 'Pass' { 'Green' } 'Fail' { 'Red' } default { 'Yellow' } }
    Write-Host "  [$Status] $Cmdlet  ($Endpoint)  $Detail" -ForegroundColor $color
}

function Invoke-Test {
    <#
    .SYNOPSIS Helper that runs a script block and records the result.
    #>
    param(
        [string]$Cmdlet,
        [string]$Endpoint,
        [scriptblock]$Test
    )
    try {
        $null = & $Test
        Record-Test -Cmdlet $Cmdlet -Endpoint $Endpoint -Status 'Pass'
    }
    catch {
        Record-Test -Cmdlet $Cmdlet -Endpoint $Endpoint -Status 'Fail' -Detail $_.Exception.Message
    }
}
#endregion

#region ── Module import ──────────────────────────────────────────────────────
if (-not (Get-Module -Name WhatsUpGoldPS)) {
    try   { Import-Module WhatsUpGoldPS -ErrorAction Stop }
    catch { Write-Error "Cannot load WhatsUpGoldPS module: $_"; return }
}
#endregion

#region ── Prompt for connection details ──────────────────────────────────────
if (-not $ServerUri) {
    $ServerUri = Read-Host "Enter WhatsUp Gold server hostname or IP"
}
if (-not $Credential) {
    $Credential = Get-Credential -Message "Enter WhatsUp Gold credentials"
}
#endregion

#region ── Connect ────────────────────────────────────────────────────────────
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " WhatsUpGoldPS End-to-End Test Suite" -ForegroundColor Cyan
Write-Host "============================================================`n" -ForegroundColor Cyan

$connectParams = @{
    serverUri  = $ServerUri
    Credential = $Credential
    Port       = $Port
    Protocol   = $Protocol
}
if ($IgnoreSSLErrors) { $connectParams['IgnoreSSLErrors'] = $true }

Write-Host "[1/10] Connecting to $ServerUri ..." -ForegroundColor Cyan
Invoke-Test -Cmdlet 'Connect-WUGServer' -Endpoint 'POST /token' -Test {
    Connect-WUGServer @connectParams -ErrorAction Stop
    if (-not $global:WUGBearerHeaders) { throw "No bearer headers after connect" }
}
#endregion

#region ── System / Product tests ─────────────────────────────────────────────
Write-Host "`n[2/10] Testing system/product endpoints ..." -ForegroundColor Cyan

Invoke-Test -Cmdlet 'Get-WUGProduct' -Endpoint 'GET /product/*' -Test {
    $p = Get-WUGProduct -ErrorAction Stop
    if (-not $p.version) { throw "No version returned" }
}
#endregion

#region ── Device Group tests ─────────────────────────────────────────────────
Write-Host "`n[3/10] Testing device-group endpoints ..." -ForegroundColor Cyan

$script:TestGroupId = $null

Invoke-Test -Cmdlet 'Get-WUGDeviceGroup (search)' -Endpoint 'GET /device-groups/-' -Test {
    $groups = Get-WUGDeviceGroup -Limit 5 -ErrorAction Stop
    if (-not $groups) { throw "No groups returned" }
}

Invoke-Test -Cmdlet 'Get-WUGDeviceGroup (byId 0)' -Endpoint 'GET /device-groups/{id}' -Test {
    $g = Get-WUGDeviceGroup -GroupId 0 -ErrorAction Stop
    if (-not $g) { throw "Root group not found" }
}

# Create a test group under root (0)
Invoke-Test -Cmdlet 'Add-WUGDeviceGroup' -Endpoint 'POST /device-groups/{id}/children' -Test {
    $name = "WUGPS-Test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $result = Add-WUGDeviceGroup -ParentGroupId 0 -Name $name -Description "Automated test group" -Confirm:$false -ErrorAction Stop
    if (-not $result) { throw "No result from Add-WUGDeviceGroup" }
    $script:TestGroupId = if ($result.id) { $result.id } elseif ($result.groupId) { $result.groupId } else { $result }
}

if ($script:TestGroupId) {
    Invoke-Test -Cmdlet 'Get-WUGDeviceGroup (children)' -Endpoint 'GET /device-groups/{id}/children' -Test {
        Get-WUGDeviceGroup -ConfigGroupId 0 -Children -ErrorAction Stop | Out-Null
    }
    Invoke-Test -Cmdlet 'Get-WUGDeviceGroup (status)' -Endpoint 'GET /device-groups/{id}/status' -Test {
        Get-WUGDeviceGroup -ConfigGroupId $script:TestGroupId -GroupStatus -ErrorAction Stop | Out-Null
    }
    # Set-WUGDeviceGroup requires -Credentials or -Role switch with a -Body JSON payload
    Invoke-Test -Cmdlet 'Set-WUGDeviceGroup (credentials)' -Endpoint 'PUT /device-groups/{id}/config/credentials' -Test {
        $body = @{ credentialIds = @() } | ConvertTo-Json -Depth 4
        Set-WUGDeviceGroup -GroupId $script:TestGroupId -Credentials -Body $body -Confirm:$false -ErrorAction Stop | Out-Null
    }
}
#endregion

#region ── Credential library tests ───────────────────────────────────────────
Write-Host "`n[4/10] Testing credential endpoints ..." -ForegroundColor Cyan

Invoke-Test -Cmdlet 'Get-WUGCredential (list)' -Endpoint 'GET /credentials/-' -Test {
    $creds = Get-WUGCredential -Limit 5 -ErrorAction Stop
    if ($null -eq $creds) { throw "Null result" }
}

Invoke-Test -Cmdlet 'Get-WUGCredential (allAssignments)' -Endpoint 'GET /credentials/-/assignments/-' -Test {
    Get-WUGCredential -AllAssignments -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGCredential (allTemplates)' -Endpoint 'GET /credentials/-/config/template' -Test {
    Get-WUGCredential -AllCredentialTemplates -ErrorAction Stop | Out-Null
}

# Single credential by ID (pick the first one available)
$script:TestCredentialId = $null
Invoke-Test -Cmdlet 'Get-WUGCredential (byId)' -Endpoint 'GET /credentials/{id}' -Test {
    $firstCred = Get-WUGCredential -Limit 1 -View id -ErrorAction Stop
    if (-not $firstCred) { throw "No credentials in library to test with" }
    $script:TestCredentialId = if ($firstCred[0].id) { "$($firstCred[0].id)" } else { "$($firstCred[0])" }
    Get-WUGCredential -CredentialId $script:TestCredentialId -ErrorAction Stop | Out-Null
}

if ($script:TestCredentialId) {
    Invoke-Test -Cmdlet 'Get-WUGCredential (assignments)' -Endpoint 'GET /credentials/{id}/assignments/-' -Test {
        Get-WUGCredential -CredentialId $script:TestCredentialId -Assignments -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGCredential (template)' -Endpoint 'GET /credentials/{id}/config/template' -Test {
        Get-WUGCredential -CredentialId $script:TestCredentialId -CredentialTemplate -ErrorAction Stop | Out-Null
    }
}
#endregion

#region ── Device Role library tests ──────────────────────────────────────────
Write-Host "`n[5/10] Testing device-role library endpoints ..." -ForegroundColor Cyan

Invoke-Test -Cmdlet 'Get-WUGDeviceRole (list)' -Endpoint 'GET /device-role/-' -Test {
    $roles = Get-WUGDeviceRole -Limit 5 -ErrorAction Stop
    if ($null -eq $roles) { throw "Null result" }
}

Invoke-Test -Cmdlet 'Get-WUGDeviceRole (allAssignments)' -Endpoint 'GET /device-role/-/assignments/-' -Test {
    Get-WUGDeviceRole -AllAssignments -Limit 5 -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGDeviceRole (allTemplates)' -Endpoint 'GET /device-role/-/config/template' -Test {
    Get-WUGDeviceRole -AllTemplates -Limit 5 -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGDeviceRole (percentVars)' -Endpoint 'GET /device-role/-/percent-variables' -Test {
    Get-WUGDeviceRole -PercentVariables -Choice monitoredDevice -ErrorAction Stop | Out-Null
}
#endregion

#region ── Monitor template library tests ─────────────────────────────────────
Write-Host "`n[6/10] Testing monitor template endpoints ..." -ForegroundColor Cyan

Invoke-Test -Cmdlet 'Get-WUGActiveMonitor (templates)' -Endpoint 'GET /monitors/-' -Test {
    $mons = Get-WUGActiveMonitor -Limit 5 -ErrorAction Stop
    if ($null -eq $mons) { throw "Null result" }
}

Invoke-Test -Cmdlet 'Get-WUGMonitorTemplate (types)' -Endpoint 'GET /monitors/-/config/supported-types' -Test {
    Get-WUGMonitorTemplate -SupportedTypes -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGMonitorTemplate (allTemplates)' -Endpoint 'GET /monitors/-/config/template' -Test {
    Get-WUGMonitorTemplate -AllMonitorTemplates -ErrorAction Stop | Out-Null
}

# Create a test Ping monitor in the library and capture its name for cleanup
$script:TestMonitorId   = $null
$script:TestMonitorName = "WUGPS-TestPing-$([guid]::NewGuid().ToString('N').Substring(0,8))"

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (Ping)' -Endpoint 'POST /monitors/-' -Test {
    $result = Add-WUGActiveMonitor -Type Ping -Name $script:TestMonitorName -Confirm:$false -ErrorAction Stop
    if (-not $result) { throw "No result from Add-WUGActiveMonitor" }
    $script:TestMonitorId = if ($result.monitorId) { "$($result.monitorId)" } elseif ($result.id) { "$($result.id)" } else { "$result" }
}

if ($script:TestMonitorId) {
    Invoke-Test -Cmdlet 'Get-WUGActiveMonitor (byMonitorId)' -Endpoint 'GET /monitors/{monitorId}' -Test {
        Get-WUGActiveMonitor -MonitorId $script:TestMonitorId -ErrorAction Stop | Out-Null
    }

    # Get-WUGMonitorTemplate requires -MonitorTemplate switch + -MonitorId (string)
    Invoke-Test -Cmdlet 'Get-WUGMonitorTemplate (byId)' -Endpoint 'GET /monitors/{id}/config/template' -Test {
        Get-WUGMonitorTemplate -MonitorTemplate -MonitorId $script:TestMonitorId -ErrorAction Stop | Out-Null
    }
}
#endregion

#region ── Device creation & CRUD tests ───────────────────────────────────────
Write-Host "`n[7/10] Creating test device and running device CRUD ..." -ForegroundColor Cyan

# We create a device via Add-WUGDeviceTemplate using the loopback address
$script:TestDeviceId = $null
$script:TestDeviceDisplayName = "WUGPS-TestDevice-$([guid]::NewGuid().ToString('N').Substring(0,8))"

Invoke-Test -Cmdlet 'Add-WUGDeviceTemplate' -Endpoint 'POST /devices/-/config/template' -Test {
    $params = @{
        DeviceAddress  = '127.0.0.1'
        displayName    = $script:TestDeviceDisplayName
        primaryRole    = 'Device'
        ActiveMonitors = @('Ping')
        note           = "Auto-created by Invoke-WUGModuleTest on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    }
    $result = Add-WUGDeviceTemplate @params -Confirm:$false -ErrorAction Stop
    if (-not $result) { throw "No result" }
    $script:TestDeviceId = $result.idMap.resultId
    if (-not $script:TestDeviceId) { throw "No resultId in response" }
}

# Allow async scan to finish
if ($script:TestDeviceId) {
    Write-Host "  Waiting 5 seconds for async device provisioning ..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
}

# ── Device GET operations ────────────────────────────────────────────────────
if ($script:TestDeviceId) {
    Invoke-Test -Cmdlet 'Get-WUGDevice (byId)' -Endpoint 'GET /devices/{id}' -Test {
        $d = Get-WUGDevice -DeviceId $script:TestDeviceId -ErrorAction Stop
        if (-not $d) { throw "Device not returned" }
    }

    Invoke-Test -Cmdlet 'Get-WUGDevice (search)' -Endpoint 'GET /device-groups/{id}/devices/-' -Test {
        $d = Get-WUGDevice -SearchValue $script:TestDeviceDisplayName -ErrorAction Stop
        if (-not $d) { throw "Search returned nothing" }
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceProperties' -Endpoint 'GET /devices/{id}/properties' -Test {
        $p = Get-WUGDeviceProperties -DeviceId $script:TestDeviceId -ErrorAction Stop
        if (-not $p) { throw "No properties" }
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceStatus' -Endpoint 'GET /devices/{id}/status' -Test {
        Get-WUGDeviceStatus -DeviceId $script:TestDeviceId -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceInterface' -Endpoint 'GET /devices/{id}/interfaces/-' -Test {
        Get-WUGDeviceInterface -DeviceId $script:TestDeviceId -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceCredential' -Endpoint 'GET /devices/{id}/credentials' -Test {
        Get-WUGDeviceCredential -DeviceId $script:TestDeviceId -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceTemplate' -Endpoint 'GET /devices/{id}/config/template' -Test {
        Get-WUGDeviceTemplate -DeviceId $script:TestDeviceId -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDevicePollingConfig' -Endpoint 'GET /devices/{id}/config/polling' -Test {
        Get-WUGDevicePollingConfig -DeviceId $script:TestDeviceId -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceGroupMembership' -Endpoint 'GET /devices/{id}/device-groups/-' -Test {
        Get-WUGDeviceGroupMembership -DeviceId "$($script:TestDeviceId)" -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceRole (deviceRoles)' -Endpoint 'GET /devices/{id}/roles/-' -Test {
        Get-WUGDeviceRole -DeviceRoles -DeviceId "$($script:TestDeviceId)" -ErrorAction Stop | Out-Null
    }

    # ── Device SET/UPDATE operations ─────────────────────────────────────────
    Invoke-Test -Cmdlet 'Set-WUGDeviceProperties' -Endpoint 'PUT /devices/{id}/properties' -Test {
        Set-WUGDeviceProperties -DeviceId $script:TestDeviceId -note "Updated by test at $(Get-Date -Format 'HH:mm:ss')" -Confirm:$false -ErrorAction Stop | Out-Null
    }

    # ── Attributes ───────────────────────────────────────────────────────────
    Invoke-Test -Cmdlet 'Set-WUGDeviceAttribute (add)' -Endpoint 'POST /devices/{id}/attributes/-' -Test {
        Set-WUGDeviceAttribute -DeviceId $script:TestDeviceId -Name "WUGPSTest" -Value "TestValue1" -Confirm:$false -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceAttribute' -Endpoint 'GET /devices/{id}/attributes/-' -Test {
        $attrs = Get-WUGDeviceAttribute -DeviceId $script:TestDeviceId -ErrorAction Stop
        if ($null -eq $attrs) { throw "Null result" }
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceAttribute (byName)' -Endpoint 'GET /devices/{id}/attributes/- (names)' -Test {
        Get-WUGDeviceAttribute -DeviceId $script:TestDeviceId -Names "WUGPSTest" -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Set-WUGDeviceAttribute (update)' -Endpoint 'PUT /devices/{id}/attributes/{id}' -Test {
        Set-WUGDeviceAttribute -DeviceId $script:TestDeviceId -Name "WUGPSTest" -Value "TestValue2" -Confirm:$false -ErrorAction Stop | Out-Null
    }

    # Remove-WUGDeviceAttribute — use -All (attribute IDs are not reliably returned by the add/get APIs)
    Invoke-Test -Cmdlet 'Remove-WUGDeviceAttribute (all)' -Endpoint 'DELETE /devices/{id}/attributes/-' -Test {
        Remove-WUGDeviceAttribute -DeviceId $script:TestDeviceId -All -Confirm:$false -ErrorAction Stop | Out-Null
    }

    # ── Maintenance ──────────────────────────────────────────────────────────
    Invoke-Test -Cmdlet 'Set-WUGDeviceMaintenance (enable)' -Endpoint 'PUT /devices/-/maintenance' -Test {
        Set-WUGDeviceMaintenance -DeviceId $script:TestDeviceId -Enabled $true -Reason "Test maintenance" -TimeInterval "30m" -Confirm:$false -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceMaintenanceSchedule' -Endpoint 'GET /devices/{id}/config/maintenance' -Test {
        Get-WUGDeviceMaintenanceSchedule -DeviceId $script:TestDeviceId -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Set-WUGDeviceMaintenance (disable)' -Endpoint 'PUT /devices/-/maintenance' -Test {
        Set-WUGDeviceMaintenance -DeviceId $script:TestDeviceId -Enabled $false -Reason "Test done" -Confirm:$false -ErrorAction Stop | Out-Null
    }

    # ── Monitors on device ───────────────────────────────────────────────────
    Invoke-Test -Cmdlet 'Get-WUGActiveMonitor (device)' -Endpoint 'GET /devices/{id}/monitors/-' -Test {
        $devMons = Get-WUGActiveMonitor -DeviceId "$($script:TestDeviceId)" -ErrorAction Stop
        if ($null -eq $devMons) { throw "Null result" }
    }

    # Assign test monitor to device (if we created one)
    $script:TestAssignmentId = $null
    if ($script:TestMonitorId) {
        Invoke-Test -Cmdlet 'Add-WUGActiveMonitorToDevice' -Endpoint 'POST /devices/{id}/monitors/-' -Test {
            $result = Add-WUGActiveMonitorToDevice -DeviceId "$($script:TestDeviceId)" -MonitorId "$($script:TestMonitorId)" -Comment "Test assignment" -Confirm:$false -ErrorAction Stop
            if (-not $result) { throw "No result" }
            $script:TestAssignmentId = if ($result.assignmentId) { "$($result.assignmentId)" } elseif ($result.id) { "$($result.id)" } else { $null }
        }
    }

    if ($script:TestAssignmentId) {
        Invoke-Test -Cmdlet 'Get-WUGActiveMonitor (assignment)' -Endpoint 'GET /devices/{id}/monitors/{aId}' -Test {
            Get-WUGActiveMonitor -DeviceId "$($script:TestDeviceId)" -AssignmentId "$($script:TestAssignmentId)" -ErrorAction Stop | Out-Null
        }

        Invoke-Test -Cmdlet 'Remove-WUGDeviceMonitor (single)' -Endpoint 'DELETE /devices/{id}/monitors/{aId}' -Test {
            Remove-WUGDeviceMonitor -DeviceId "$($script:TestDeviceId)" -AssignmentId "$($script:TestAssignmentId)" -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }

    # ── Group membership ─────────────────────────────────────────────────────
    if ($script:TestGroupId) {
        Invoke-Test -Cmdlet 'Add-WUGDeviceGroupMember' -Endpoint 'POST /device-groups/{id}/devices/-' -Test {
            Add-WUGDeviceGroupMember -GroupId $script:TestGroupId -DeviceId "$($script:TestDeviceId)" -Confirm:$false -ErrorAction Stop | Out-Null
        }

        Invoke-Test -Cmdlet 'Get-WUGDeviceGroup (devices)' -Endpoint 'GET /device-groups/{id}/devices/-' -Test {
            Get-WUGDeviceGroup -ConfigGroupId $script:TestGroupId -GroupDevices -ErrorAction Stop | Out-Null
        }

        Invoke-Test -Cmdlet 'Remove-WUGDeviceGroupMember' -Endpoint 'DELETE /device-groups/{id}/devices/{dId}' -Test {
            Remove-WUGDeviceGroupMember -GroupId $script:TestGroupId -DeviceId "$($script:TestDeviceId)" -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }

    # ── Polling — use ByGroup (single-device POST may 404 on some WUG versions)
    if ($script:TestGroupId) {
        Invoke-Test -Cmdlet 'Invoke-WUGDevicePollNow (byGroup)' -Endpoint 'PUT /device-groups/{id}/poll-now' -Test {
            Invoke-WUGDevicePollNow -GroupId ([int]$script:TestGroupId) -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }

    # ── Refresh — use ByGroup (PATCH /devices/refresh may 405 on some WUG versions)
    if ($script:TestGroupId) {
        Invoke-Test -Cmdlet 'Invoke-WUGDeviceRefresh (byGroup)' -Endpoint 'PUT /device-groups/{id}/refresh' -Test {
            Invoke-WUGDeviceRefresh -GroupId ([int]$script:TestGroupId) -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }

    # ── Device Scan ──────────────────────────────────────────────────────────
    Invoke-Test -Cmdlet 'Get-WUGDeviceScan (list)' -Endpoint 'GET /device-scans/-' -Test {
        Get-WUGDeviceScan -Limit 5 -ErrorAction Stop | Out-Null
    }
}
#endregion

#region ── Reports (device-level) ─────────────────────────────────────────────
Write-Host "`n[8/10] Testing device report endpoints ..." -ForegroundColor Cyan

if ($script:TestDeviceId) {
    # Test the umbrella Get-WUGDeviceReport with each ReportType
    $deviceReportTypes = @('Cpu','Disk','DiskSpaceFree','Interface','InterfaceDiscards','InterfaceErrors','InterfaceTraffic','Memory','PingAvailability','PingResponseTime','StateChange')
    foreach ($rt in $deviceReportTypes) {
        Invoke-Test -Cmdlet "Get-WUGDeviceReport ($rt)" -Endpoint "GET /devices/{id}/reports/$rt" -Test ([scriptblock]::Create(
            "Get-WUGDeviceReport -DeviceId $($script:TestDeviceId) -ReportType $rt -Range today -ErrorAction Stop | Out-Null"
        ))
    }

    # Also test the individual typed cmdlets
    $reportCmdlets = @(
        @{ Cmdlet = 'Get-WUGDeviceReportCpu';                  Endpoint = 'GET /devices/{id}/reports/cpu' },
        @{ Cmdlet = 'Get-WUGDeviceReportMemory';               Endpoint = 'GET /devices/{id}/reports/memory' },
        @{ Cmdlet = 'Get-WUGDeviceReportDisk';                 Endpoint = 'GET /devices/{id}/reports/disk' },
        @{ Cmdlet = 'Get-WUGDeviceReportDiskSpaceFree';        Endpoint = 'GET /devices/{id}/reports/diskFree' },
        @{ Cmdlet = 'Get-WUGDeviceReportInterface';            Endpoint = 'GET /devices/{id}/reports/interface' },
        @{ Cmdlet = 'Get-WUGDeviceReportInterfaceTraffic';     Endpoint = 'GET /devices/{id}/reports/interfaceTraffic' },
        @{ Cmdlet = 'Get-WUGDeviceReportInterfaceErrors';      Endpoint = 'GET /devices/{id}/reports/interfaceErrors' },
        @{ Cmdlet = 'Get-WUGDeviceReportInterfaceDiscards';    Endpoint = 'GET /devices/{id}/reports/interfaceDiscards' },
        @{ Cmdlet = 'Get-WUGDeviceReportPingAvailability';     Endpoint = 'GET /devices/{id}/reports/ping/availability' },
        @{ Cmdlet = 'Get-WUGDeviceReportPingResponseTime';     Endpoint = 'GET /devices/{id}/reports/ping/responseTime' },
        @{ Cmdlet = 'Get-WUGDeviceReportStateChange';          Endpoint = 'GET /devices/{id}/reports/stateChange' }
    )

    foreach ($r in $reportCmdlets) {
        Invoke-Test -Cmdlet $r.Cmdlet -Endpoint $r.Endpoint -Test ([scriptblock]::Create(
            "& '$($r.Cmdlet)' -DeviceId $($script:TestDeviceId) -Range today -ErrorAction Stop | Out-Null"
        ))
    }
}
#endregion

#region ── Reports (group-level) ──────────────────────────────────────────────
Write-Host "`n[9/10] Testing device-group report endpoints ..." -ForegroundColor Cyan

# Use root group (0) for group reports — always exists and has aggregated data

# Test the umbrella Get-WUGDeviceGroupReport with each ReportType
$groupReportTypes = @('Cpu','Disk','DiskSpaceFree','Interface','InterfaceDiscards','InterfaceErrors','InterfaceTraffic','Memory','PingAvailability','PingResponseTime','StateChange','Maintenance')
foreach ($rt in $groupReportTypes) {
    Invoke-Test -Cmdlet "Get-WUGDeviceGroupReport ($rt)" -Endpoint "GET /device-groups/{id}/reports/$rt" -Test ([scriptblock]::Create(
        "Get-WUGDeviceGroupReport -GroupId 0 -ReportType $rt -Range today -ErrorAction Stop | Out-Null"
    ))
}

# Also test the individual typed cmdlets
$groupReportCmdlets = @(
    @{ Cmdlet = 'Get-WUGDeviceGroupReportCpu';                 Endpoint = 'GET /device-groups/{id}/reports/cpu' },
    @{ Cmdlet = 'Get-WUGDeviceGroupReportMemory';              Endpoint = 'GET /device-groups/{id}/reports/memory' },
    @{ Cmdlet = 'Get-WUGDeviceGroupReportDisk';                Endpoint = 'GET /device-groups/{id}/reports/disk' },
    @{ Cmdlet = 'Get-WUGDeviceGroupReportDiskSpaceFree';       Endpoint = 'GET /device-groups/{id}/reports/diskFree' },
    @{ Cmdlet = 'Get-WUGDeviceGroupReportInterface';           Endpoint = 'GET /device-groups/{id}/reports/interface' },
    @{ Cmdlet = 'Get-WUGDeviceGroupReportInterfaceTraffic';    Endpoint = 'GET /device-groups/{id}/reports/interfaceTraffic' },
    @{ Cmdlet = 'Get-WUGDeviceGroupReportInterfaceErrors';     Endpoint = 'GET /device-groups/{id}/reports/interfaceErrors' },
    @{ Cmdlet = 'Get-WUGDeviceGroupReportInterfaceDiscards';   Endpoint = 'GET /device-groups/{id}/reports/interfaceDiscards' },
    @{ Cmdlet = 'Get-WUGDeviceGroupReportPingAvailability';    Endpoint = 'GET /device-groups/{id}/reports/ping/availability' },
    @{ Cmdlet = 'Get-WUGDeviceGroupReportPingResponseTime';    Endpoint = 'GET /device-groups/{id}/reports/ping/responseTime' },
    @{ Cmdlet = 'Get-WUGDeviceGroupReportStateChange';         Endpoint = 'GET /device-groups/{id}/reports/stateChange' },
    @{ Cmdlet = 'Get-WUGDeviceGroupReportMaintenance';         Endpoint = 'GET /device-groups/{id}/reports/maintenance' }
)

foreach ($r in $groupReportCmdlets) {
    Invoke-Test -Cmdlet $r.Cmdlet -Endpoint $r.Endpoint -Test ([scriptblock]::Create(
        "& '$($r.Cmdlet)' -GroupId 0 -Range today -ErrorAction Stop | Out-Null"
    ))
}
#endregion

#region ── Cleanup ────────────────────────────────────────────────────────────
Write-Host "`n[10/10] Cleaning up test artefacts ..." -ForegroundColor Cyan

# Remove the test monitor from library via BySearch (ById DELETE may 405 on some WUG versions)
if ($script:TestMonitorName) {
    Invoke-Test -Cmdlet 'Remove-WUGActiveMonitor (bySearch)' -Endpoint 'DELETE /monitors/-' -Test {
        Remove-WUGActiveMonitor -Search $script:TestMonitorName -Type active -Confirm:$false -ErrorAction Stop | Out-Null
    }
}

# Remove the test device
if ($script:TestDeviceId) {
    Invoke-Test -Cmdlet 'Remove-WUGDevice' -Endpoint 'DELETE /devices/{id}' -Test {
        Remove-WUGDevice -DeviceId $script:TestDeviceId -Confirm:$false -ErrorAction Stop | Out-Null
    }
}

# Remove the test group
if ($script:TestGroupId) {
    Invoke-Test -Cmdlet 'Remove-WUGDeviceGroup' -Endpoint 'DELETE /device-groups/{id}' -Test {
        Remove-WUGDeviceGroup -GroupId $script:TestGroupId -Confirm:$false -ErrorAction Stop | Out-Null
    }
}

# Disconnect
Invoke-Test -Cmdlet 'Disconnect-WUGServer' -Endpoint '(session cleanup)' -Test {
    Disconnect-WUGServer -ErrorAction Stop
    if ($global:WUGBearerHeaders) { throw "Headers still set after disconnect" }
}
#endregion

#region ── Summary ────────────────────────────────────────────────────────────
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " TEST RESULTS SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$passed  = ($script:TestResults | Where-Object Status -eq 'Pass').Count
$failed  = ($script:TestResults | Where-Object Status -eq 'Fail').Count
$skipped = ($script:TestResults | Where-Object Status -eq 'Skipped').Count
$total   = $script:TestResults.Count

Write-Host "`n  Total : $total" -ForegroundColor White
Write-Host "  Pass  : $passed" -ForegroundColor Green
Write-Host "  Fail  : $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Skip  : $skipped" -ForegroundColor Yellow

if ($failed -gt 0) {
    Write-Host "`n  FAILED TESTS:" -ForegroundColor Red
    $script:TestResults | Where-Object Status -eq 'Fail' | ForEach-Object {
        Write-Host "    - $($_.Cmdlet)  [$($_.Endpoint)]" -ForegroundColor Red
        if ($_.Detail) { Write-Host "      $($_.Detail)" -ForegroundColor DarkRed }
    }
}

Write-Host "`n============================================================" -ForegroundColor Cyan

# Output structured results for programmatic consumption
$script:TestResults | Format-Table -AutoSize -Property Cmdlet, Endpoint, Status, Detail

# Return results object
$script:TestResults
#endregion

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDtWFwPxMl6S1ws
# fYMuYJZ1wFn6vZ8diFtHT8JiPH7R9aCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgFQDx02l6vFvWvi/rqShsOroQnYX+n/HZ
# bfozyoeNLI8wDQYJKoZIhvcNAQEBBQAEggIAion3p/TpF4GdqpBYH1FizK3pOMuq
# 0nV8MlW0MIThtv0aD/ZO5AuDFz6aLcWXpJWwap9jzYHIO3bXMpQOcID16F8x0jC8
# jBt32lo5WG+RNpot2JMHh0S1WC/OwK//L9ejAMkI1T5HPxVQ7+cTXrlcxp+ZQD7t
# azMvtDpb5COC45c5wc9nAPD+2pYA0kmk3FoNITt4jXekkApCk8s52kOhpr6cTjjN
# 7K+iZbJ25EFpXzmbegPBLi6yrm0cydUQv9Em+1NUeskklAt0D+9/jl8HVczDeTwN
# ZxvlH/KZHC94ewnI33q2AhBuakuy5D4uNzYVJxaeJguBMjOJKZ9B5RnmvpfYQizW
# 275cmj340OSV9AxqgdWea8UYW6AE1PcfCt8NF+ndpw78qt4SgwyTvN6PCmfmNksg
# cf7i7n0mg6VaDcalL/SqRMKQN+x6n79adBnvCv4NpTNLXEB9D+STPJtiH2Vyiz+5
# RYBdy/kWBU1HbUfOslouu6Efos5QGIto24v5JWlCFuZudz1YV6lbLYCGBqelbAro
# VR9JNrgUjvok3aI4hPLfpvfpVE49abxtsgVAUXXolZi9ys24JtkB6HDrqOwclPsU
# atRkgIpTJ975oPhTnEvUkyp7sgEGp/tpjPCejQP869wisCnAJUyu3uIN3EHHnqiq
# nbXYbDY1tu++Y6k=
# SIG # End signature block
