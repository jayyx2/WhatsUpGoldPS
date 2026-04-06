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

#region -- Helpers ------------------------------------------------------------
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

#region -- Module import ------------------------------------------------------
if (-not (Get-Module -Name WhatsUpGoldPS)) {
    try   { Import-Module WhatsUpGoldPS -ErrorAction Stop }
    catch { Write-Error "Cannot load WhatsUpGoldPS module: $_"; return }
}
#endregion

#region -- Prompt for connection details --------------------------------------
if (-not $ServerUri) {
    $ServerUri = Read-Host "Enter WhatsUp Gold server hostname or IP"
}
if (-not $Credential) {
    $Credential = Get-Credential -Message "Enter WhatsUp Gold credentials"
}
#endregion

#region -- Connect ------------------------------------------------------------
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " WhatsUpGoldPS End-to-End Test Suite" -ForegroundColor Cyan
Write-Host "============================================================`n" -ForegroundColor Cyan

$connectParams = @{
    serverUri       = $ServerUri
    Credential      = $Credential
    Port            = $Port
    Protocol        = $Protocol
    IgnoreSSLErrors = $true
}

Write-Host "[1/12] Connecting to $ServerUri ..." -ForegroundColor Cyan
Invoke-Test -Cmdlet 'Connect-WUGServer' -Endpoint 'POST /token' -Test {
    Connect-WUGServer @connectParams -ErrorAction Stop
    if (-not $global:WUGBearerHeaders) { throw "No bearer headers after connect" }
}

# Abort early if authentication failed - no point running 130+ tests against a dead connection
if (-not $global:WUGBearerHeaders) {
    Write-Host "`n  FATAL: Authentication failed. Cannot continue." -ForegroundColor Red
    Write-Host "  Check server URI, credentials, and SSL/port settings.`n" -ForegroundColor Red
    $script:TestResults | Format-Table -AutoSize -Property Cmdlet, Endpoint, Status, Detail
    return
}
#endregion

#region -- System / Product tests ---------------------------------------------
Write-Host "`n[2/12] Testing system/product endpoints ..." -ForegroundColor Cyan

Invoke-Test -Cmdlet 'Get-WUGProduct' -Endpoint 'GET /product/*' -Test {
    $p = Get-WUGProduct -ErrorAction Stop
    if (-not $p.version) { throw "No version returned" }
}
#endregion

#region -- Device Group tests -------------------------------------------------
Write-Host "`n[3/12] Testing device-group endpoints ..." -ForegroundColor Cyan

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
    Invoke-Test -Cmdlet 'Get-WUGDeviceGroup (children detail)' -Endpoint 'GET /device-groups/{id}/children?view=detail' -Test {
        Get-WUGDeviceGroup -ConfigGroupId 0 -Children -View detail -ErrorAction Stop | Out-Null
    }
    Invoke-Test -Cmdlet 'Get-WUGDeviceGroup (children search)' -Endpoint 'GET /device-groups/{id}/children?search=...' -Test {
        Get-WUGDeviceGroup -ConfigGroupId 0 -Children -SearchValue "test" -ErrorAction Stop | Out-Null
    }
    Invoke-Test -Cmdlet 'Get-WUGDeviceGroup (children groupType)' -Endpoint 'GET /device-groups/{id}/children?groupType=static_group' -Test {
        Get-WUGDeviceGroup -ConfigGroupId 0 -Children -GroupType static_group -ErrorAction Stop | Out-Null
    }
    Invoke-Test -Cmdlet 'Get-WUGDeviceGroup (children returnHierarchy)' -Endpoint 'GET /device-groups/{id}/children?returnHierarchy=true' -Test {
        Get-WUGDeviceGroup -ConfigGroupId 0 -Children -ReturnHierarchy -ErrorAction Stop | Out-Null
    }
    Invoke-Test -Cmdlet 'Get-WUGDeviceGroup (definition)' -Endpoint 'GET /device-groups/{id}/definition' -Test {
        $def = Get-WUGDeviceGroup -ConfigGroupId $script:TestGroupId -Definition -ErrorAction Stop
        if (-not $def) { throw "No definition returned" }
    }
    Invoke-Test -Cmdlet 'Get-WUGDeviceGroup (status)' -Endpoint 'GET /device-groups/{id}/status' -Test {
        Get-WUGDeviceGroup -ConfigGroupId $script:TestGroupId -GroupStatus -ErrorAction Stop | Out-Null
    }
    # Set-WUGDeviceGroup - Properties (update definition)
    Invoke-Test -Cmdlet 'Set-WUGDeviceGroup (rename)' -Endpoint 'PUT /device-groups/{id}/definition' -Test {
        Set-WUGDeviceGroup -GroupId $script:TestGroupId -Description "Renamed by test" -Confirm:$false -ErrorAction Stop | Out-Null
    }

    # Set-WUGDeviceGroup - PollNow
    Invoke-Test -Cmdlet 'Set-WUGDeviceGroup (pollNow)' -Endpoint 'PUT /device-groups/{id}/poll-now' -Test {
        Set-WUGDeviceGroup -GroupId $script:TestGroupId -PollNow -Confirm:$false -ErrorAction Stop | Out-Null
    }

    # Set-WUGDeviceGroup - Refresh with options
    Invoke-Test -Cmdlet 'Set-WUGDeviceGroup (refresh)' -Endpoint 'PUT /device-groups/{id}/refresh' -Test {
        Set-WUGDeviceGroup -GroupId $script:TestGroupId -Refresh -Confirm:$false -ErrorAction Stop | Out-Null
    }

    # Set-WUGDeviceGroup - ListDeviceIds (deduplicated)
    Invoke-Test -Cmdlet 'Set-WUGDeviceGroup (listDeviceIds)' -Endpoint 'GET /device-groups/{id}/devices/-' -Test {
        $ids = Set-WUGDeviceGroup -GroupId $script:TestGroupId -ListDeviceIds -ErrorAction Stop
        # Empty group is fine - just verify it runs without error
    }
}
#endregion

#region -- Credential library tests -------------------------------------------
Write-Host "`n[4/12] Testing credential endpoints ..." -ForegroundColor Cyan

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

#region -- Device Role library tests ------------------------------------------
Write-Host "`n[5/12] Testing device-role library endpoints ..." -ForegroundColor Cyan

$script:TestRoleId = $null

Invoke-Test -Cmdlet 'Get-WUGRole (list)' -Endpoint 'GET /device-role/-' -Test {
    $roles = Get-WUGRole -Limit 5 -ErrorAction Stop
    if ($null -eq $roles) { throw "Null result" }
    # Capture a role ID for subsequent tests
    if ($roles.Count -gt 0) {
        $script:TestRoleId = if ($roles[0].id) { "$($roles[0].id)" } else { "$($roles[0])" }
    }
}

if ($script:TestRoleId) {
    Invoke-Test -Cmdlet 'Get-WUGRole (byId)' -Endpoint 'GET /device-role/{roleId}' -Test {
        Get-WUGRole -RoleId $script:TestRoleId -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGRole (byId summary)' -Endpoint 'GET /device-role/{roleId}?view=summary' -Test {
        Get-WUGRole -RoleId $script:TestRoleId -View summary -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGRole (assignments byId)' -Endpoint 'GET /device-role/{roleId}/assignments/-' -Test {
        Get-WUGRole -RoleId $script:TestRoleId -Assignments -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGRole (template byId)' -Endpoint 'GET /device-role/{roleId}/config/template' -Test {
        Get-WUGRole -RoleId $script:TestRoleId -Template -ErrorAction Stop | Out-Null
    }
}

Invoke-Test -Cmdlet 'Get-WUGRole (list filtered)' -Endpoint 'GET /device-role/-?kind=role' -Test {
    Get-WUGRole -Kind role -Limit 5 -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGRole (allAssignments)' -Endpoint 'GET /device-role/-/assignments/-' -Test {
    Get-WUGRole -AllAssignments -Limit 5 -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGRole (allAssignments kind)' -Endpoint 'GET /device-role/-/assignments/-?kind=role' -Test {
    Get-WUGRole -AllAssignments -AssignmentKind role -Limit 5 -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGRole (allTemplates)' -Endpoint 'GET /device-role/-/config/template' -Test {
    Get-WUGRole -AllTemplates -Limit 5 -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGRole (allTemplates kind)' -Endpoint 'GET /device-role/-/config/template?kind=role' -Test {
    Get-WUGRole -AllTemplates -TemplateKind role -Limit 5 -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGRole (percentVars)' -Endpoint 'GET /device-role/-/percentVariables' -Test {
    Get-WUGRole -PercentVariables -Choice monitoredDevice -ErrorAction Stop | Out-Null
}

# -- Import / Export device role templates ------------------------------------
Invoke-Test -Cmdlet 'Import-WUGRoleTemplate (verify)' -Endpoint 'POST /device-role/-/config/import/verify' -Test {
    $pkg = '{"pkg":{"package":{"name":"test"}},"apply":{}}'
    Import-WUGRoleTemplate -Body $pkg -Verify -Confirm:$false -ErrorAction Stop | Out-Null
}

# Disabled - API returns 400 regardless of body shape; revisit when WUG documents the correct request format
#Invoke-Test -Cmdlet 'Export-WUGRoleTemplate (content)' -Endpoint 'POST /device-role/-/config/export/content' -Test {
#    $roles = Get-WUGRole -Limit 1 -ErrorAction Stop
#    if ($null -eq $roles -or $roles.Count -eq 0) { throw "No roles available" }
#    $roleId = if ($roles[0].id) { "$($roles[0].id)" } else { "$($roles[0])" }
#    $exportBody = @{
#        roles = @(@{ id = $roleId })
#    } | ConvertTo-Json -Depth 5
#    Export-WUGRoleTemplate -Body $exportBody -Content -Confirm:$false -ErrorAction Stop | Out-Null
#}

# -- Community device role template import (helper script) --------------------
Invoke-Test -Cmdlet 'Import-CommunityDeviceRoleTemplates (listOnly)' -Endpoint 'GitHub API (list)' -Test {
    $helperPath = Join-Path $PSScriptRoot '..\templates\Import-CommunityDeviceRoleTemplates.ps1'
    if (-not (Test-Path $helperPath)) { throw "Helper script not found at $helperPath" }
    & $helperPath -ListOnly -ErrorAction Stop
}

Invoke-Test -Cmdlet 'Import-CommunityDeviceRoleTemplates (single)' -Endpoint 'POST /device-role/-/config/import' -Test {
    $helperPath = Join-Path $PSScriptRoot '..\templates\Import-CommunityDeviceRoleTemplates.ps1'
    & $helperPath -TemplateNames "WhatsUp Gold" -ErrorAction Stop
}

# -- Set-WUGRole (enable/disable/restore) ------------------------------------
if ($script:TestRoleId) {
    Invoke-Test -Cmdlet 'Set-WUGRole (disable)' -Endpoint 'PUT /device-role/{roleId}/disable' -Test {
        Set-WUGRole -RoleId $script:TestRoleId -DisableRole -Confirm:$false -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Set-WUGRole (enable)' -Endpoint 'PUT /device-role/{roleId}/enable' -Test {
        Set-WUGRole -RoleId $script:TestRoleId -EnableRole -Confirm:$false -ErrorAction Stop | Out-Null
    }
}
#endregion

#region -- Monitor template library tests -------------------------------------
Write-Host "`n[6/12] Testing monitor template endpoints ..." -ForegroundColor Cyan

Invoke-Test -Cmdlet 'Get-WUGActiveMonitor (templates)' -Endpoint 'GET /monitors/-' -Test {
    $mons = Get-WUGActiveMonitor -IncludeAssignments -Limit 5 -ErrorAction Stop
    if ($null -eq $mons) { throw "Null result" }
}

Invoke-Test -Cmdlet 'Get-WUGMonitorTemplate (types)' -Endpoint 'GET /monitors/-/config/supported-types' -Test {
    Get-WUGMonitorTemplate -SupportedTypes -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGMonitorTemplate (allTemplates)' -Endpoint 'GET /monitors/-/config/template' -Test {
    Get-WUGMonitorTemplate -AllMonitorTemplates -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Import-WUGMonitorTemplate (clone)' -Endpoint 'PATCH /monitors/-/config/template' -Test {
    $allTemplates = Get-WUGMonitorTemplate -AllMonitorTemplates -ErrorAction Stop
    $suffix = "_test$(Get-Date -Format 'yyyyMMddHHmmss')"

    # Build a minimal clone body with one monitor from each available type, renamed to avoid duplicates
    $cloneBody = @{}

    if ($allTemplates.activeMonitors) {
        # Pick the first active monitor that has no sensitive-data error
        $errorNames = @()
        if ($allTemplates.errors) {
            $errorNames = $allTemplates.errors | ForEach-Object {
                if ($_ -match '^Monitor,\s*(.+?)\s+of type') { $Matches[1] }
            }
        }
        $safeActive = $allTemplates.activeMonitors | Where-Object { $_.name -notin $errorNames } | Select-Object -First 1
        if ($safeActive) {
            $safeActive = $safeActive.PSObject.Copy()
            $safeActive.name = "$($safeActive.name)$suffix"
            $cloneBody['activeMonitors'] = @($safeActive)
        }
    }

    if ($allTemplates.passiveMonitors) {
        $safePassive = $allTemplates.passiveMonitors | Select-Object -First 1
        if ($safePassive) {
            $safePassive = $safePassive.PSObject.Copy()
            $safePassive.name = "$($safePassive.name)$suffix"
            $cloneBody['passiveMonitors'] = @($safePassive)
        }
    }

    if ($allTemplates.performanceMonitors) {
        $safePerf = $allTemplates.performanceMonitors | Select-Object -First 1
        if ($safePerf) {
            $safePerf = $safePerf.PSObject.Copy()
            $safePerf.name = "$($safePerf.name)$suffix"
            $cloneBody['performanceMonitors'] = @($safePerf)
        }
    }

    if ($cloneBody.Keys.Count -eq 0) { throw "No monitor templates available for clone test" }

    $json = $cloneBody | ConvertTo-Json -Depth 20
    Import-WUGMonitorTemplate -Body $json -Options clone -Confirm:$false -ErrorAction Stop | Out-Null
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

# -- Add-WUGMonitorTemplate (bulk create) ------------------------------------
$script:BulkMonitorNames = [System.Collections.Generic.List[string]]::new()
Invoke-Test -Cmdlet 'Add-WUGMonitorTemplate (bulk active)' -Endpoint 'PATCH /monitors/-/config/template' -Test {
    $bulkName = "WUGPS-BulkTest-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $activeTempl = @(@{
        name = $bulkName
        description = 'Bulk create test'
        monitorTypeInfo = @{ baseType = 'active'; classId = '490fee51-e638-4136-823f-d572d347bbf1' }  # Ping
        propertyBags = @(
            @{ name = 'Ping:Timeout';  value = '1000' }
            @{ name = 'Ping:Retries';  value = '1' }
            @{ name = 'Ping:PayloadSize'; value = '32' }
        )
        useInDiscovery = $false
    })
    $result = Add-WUGMonitorTemplate -ActiveMonitors $activeTempl -Confirm:$false -ErrorAction Stop
    if (-not $result) { throw "No result" }
    $script:BulkMonitorNames.Add($bulkName)
}

# -- Set-WUGMonitorTemplate (unassign all) -----------------------------------
Invoke-Test -Cmdlet 'Set-WUGMonitorTemplate (unassignAll)' -Endpoint 'DELETE /monitors/-/assignments/-' -Test {
    Set-WUGMonitorTemplate -UnassignAll -Search 'WUGPS-BulkTest-' -Confirm:$false -ErrorAction Stop | Out-Null
}
#endregion

#region -- Device creation & CRUD tests ---------------------------------------
Write-Host "`n[7/12] Creating test device and running device CRUD ..." -ForegroundColor Cyan

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

# -- Create test credentials and assign to device -----------------------------
$script:TestCredentialIds = [System.Collections.Generic.List[string]]::new()

if ($script:TestDeviceId) {
    # SNMP v2 credential (needed for SNMP monitors)
    Invoke-Test -Cmdlet 'Add-WUGCredential (snmpV2)' -Endpoint 'POST /credentials/-' -Test {
        $cred = Add-WUGCredential -Name "WUGPS-Test-SNMPv2-$(Get-Date -Format 'yyyyMMddHHmmss')" -Type snmpV2 `
            -SnmpReadCommunity 'public' -Confirm:$false -ErrorAction Stop
        if (-not $cred) { throw "No result" }
        $credId = if ($cred.idMap) { $cred.idMap.resultId } elseif ($cred.credentialId) { $cred.credentialId } elseif ($cred.id) { $cred.id } else { "$cred" }
        $script:TestCredentialIds.Add("$credId")
    }

    # Windows credential (needed for WMI, Performance Counter, Process, Service monitors)
    Invoke-Test -Cmdlet 'Add-WUGCredential (windows)' -Endpoint 'POST /credentials/-' -Test {
        $cred = Add-WUGCredential -Name "WUGPS-Test-Windows-$(Get-Date -Format 'yyyyMMddHHmmss')" -Type windows `
            -WindowsUser '.\wugtest' -WindowsPassword 'TestPass123!' `
            -Confirm:$false -ErrorAction Stop
        if (-not $cred) { throw "No result" }
        $credId = if ($cred.idMap) { $cred.idMap.resultId } elseif ($cred.credentialId) { $cred.credentialId } elseif ($cred.id) { $cred.id } else { "$cred" }
        $script:TestCredentialIds.Add("$credId")
    }

    # SSH credential (needed for SSH monitors)
    Invoke-Test -Cmdlet 'Add-WUGCredential (ssh)' -Endpoint 'POST /credentials/-' -Test {
        $cred = Add-WUGCredential -Name "WUGPS-Test-SSH-$(Get-Date -Format 'yyyyMMddHHmmss')" -Type ssh `
            -SshUsername 'wugtest' -SshPassword 'TestPass123!' -SshEnablePassword '' -Confirm:$false -ErrorAction Stop
        if (-not $cred) { throw "No result" }
        $credId = if ($cred.idMap) { $cred.idMap.resultId } elseif ($cred.credentialId) { $cred.credentialId } elseif ($cred.id) { $cred.id } else { "$cred" }
        $script:TestCredentialIds.Add("$credId")
    }

    # Assign all test credentials to the test device
    foreach ($credId in $script:TestCredentialIds) {
        Invoke-Test -Cmdlet "Set-WUGDeviceCredential (assign $credId)" -Endpoint 'PUT /devices/{id}/credentials/-' -Test {
            $result = Set-WUGDeviceCredential -DeviceId "$($script:TestDeviceId)" -CredentialId $credId -Assign -ErrorAction Stop
            if (-not $result) { throw "No result" }
        }
    }
}

# -- Device GET operations ----------------------------------------------------
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

    # -- Interface CRUD -------------------------------------------------------
    $script:TestInterfaceId = $null
    Invoke-Test -Cmdlet 'Add-WUGDeviceInterface' -Endpoint 'POST /devices/{id}/interfaces/-' -Test {
        $result = Add-WUGDeviceInterface -DeviceId $script:TestDeviceId -Address '10.99.99.99' -HostName 'TestInterface' -Confirm:$false -ErrorAction Stop
        if (-not $result) { throw "No result" }
        $script:TestInterfaceId = if ($result.interfaceId) { "$($result.interfaceId)" } elseif ($result.id) { "$($result.id)" } elseif ($result.idMap) { "$($result.idMap.resultId)" } else { "$result" }
    }

    if ($script:TestInterfaceId) {
        Invoke-Test -Cmdlet 'Set-WUGDeviceInterface' -Endpoint 'PUT /devices/{id}/interfaces/{iId}' -Test {
            Set-WUGDeviceInterface -DeviceId $script:TestDeviceId -InterfaceId $script:TestInterfaceId -NetworkName 'RenamedInterface' -Confirm:$false -ErrorAction Stop | Out-Null
        }

        Invoke-Test -Cmdlet 'Remove-WUGDeviceInterface (byId)' -Endpoint 'DELETE /devices/{id}/interfaces/{iId}' -Test {
            Remove-WUGDeviceInterface -DeviceId $script:TestDeviceId -InterfaceId $script:TestInterfaceId -Confirm:$false -ErrorAction Stop | Out-Null
        }
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

    Invoke-Test -Cmdlet 'Set-WUGDevicePollingConfig' -Endpoint 'PUT /devices/{id}/config/polling' -Test {
        Set-WUGDevicePollingConfig -DeviceId $script:TestDeviceId -PollingIntervalSeconds 300 -Confirm:$false -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceGroupMembership' -Endpoint 'GET /devices/{id}/group/-' -Test {
        Get-WUGDeviceGroupMembership -DeviceId "$($script:TestDeviceId)" -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceGroupMembership (isMember)' -Endpoint 'GET /devices/{id}/group/{gid}/is-member' -Test {
        Get-WUGDeviceGroupMembership -DeviceId "$($script:TestDeviceId)" -IsMember -TargetGroupId 0 -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceRole' -Endpoint 'GET /devices/{id}/roles/-' -Test {
        Get-WUGDeviceRole -DeviceId "$($script:TestDeviceId)" -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Set-WUGDeviceRole (setKind)' -Endpoint 'PUT /devices/{id}/roles/{kind}' -Test {
        $roles = @(Get-WUGRole -Kind role -Limit 1 -ErrorAction Stop)
        if ($roles -and $roles.Count -gt 0) {
            $roleId = if ($roles[0].id) { "$($roles[0].id)" } else { "$($roles[0])" }
            Set-WUGDeviceRole -DeviceId "$($script:TestDeviceId)" -SetDeviceRoleKind -RoleKind primary -RoleValue $roleId -Confirm:$false -ErrorAction Stop | Out-Null
        } else { throw "No roles available" }
    }

    # -- Device SET/UPDATE operations -----------------------------------------
    Invoke-Test -Cmdlet 'Set-WUGDeviceProperties' -Endpoint 'PUT /devices/{id}/properties' -Test {
        Set-WUGDeviceProperties -DeviceId $script:TestDeviceId -note "Updated by test at $(Get-Date -Format 'HH:mm:ss')" -Confirm:$false -ErrorAction Stop | Out-Null
    }

    # -- Attributes -----------------------------------------------------------
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

    # Remove-WUGDeviceAttribute - use -All (attribute IDs are not reliably returned by the add/get APIs)
    Invoke-Test -Cmdlet 'Remove-WUGDeviceAttribute (all)' -Endpoint 'DELETE /devices/{id}/attributes/-' -Test {
        Remove-WUGDeviceAttribute -DeviceId $script:TestDeviceId -All -Confirm:$false -ErrorAction Stop | Out-Null
    }

    # -- Maintenance ----------------------------------------------------------
    Invoke-Test -Cmdlet 'Set-WUGDeviceMaintenance (enable)' -Endpoint 'PUT /devices/-/maintenance' -Test {
        Set-WUGDeviceMaintenance -DeviceId $script:TestDeviceId -Enabled $true -Reason "Test maintenance" -TimeInterval "30m" -Confirm:$false -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceMaintenanceSchedule' -Endpoint 'GET /devices/{id}/config/maintenance' -Test {
        Get-WUGDeviceMaintenanceSchedule -DeviceId $script:TestDeviceId -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Set-WUGDeviceMaintenance (disable)' -Endpoint 'PUT /devices/-/maintenance' -Test {
        Set-WUGDeviceMaintenance -DeviceId $script:TestDeviceId -Enabled $false -Reason "Test done" -Confirm:$false -ErrorAction Stop | Out-Null
    }

    # Single-device maintenance uses PUT /devices/{id}/config/maintenance auto-routing
    Invoke-Test -Cmdlet 'Set-WUGDeviceMaintenance (single-device)' -Endpoint 'PUT /devices/{id}/config/maintenance' -Test {
        Set-WUGDeviceMaintenance -DeviceId $script:TestDeviceId -Enabled $true -Reason "Single device test" -TimeInterval "15m" -Confirm:$false -ErrorAction Stop | Out-Null
        Set-WUGDeviceMaintenance -DeviceId $script:TestDeviceId -Enabled $false -Reason "Cleanup" -Confirm:$false -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Set-WUGDeviceMaintenanceSchedule (daily)' -Endpoint 'PUT /devices/{id}/config/maintenance/schedule' -Test {
        Set-WUGDeviceMaintenanceSchedule -DeviceId $script:TestDeviceId -ScheduleType Daily -StartTimeHour 2 -EndTimeHour 4 -Confirm:$false -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Set-WUGDeviceMaintenanceSchedule (delete)' -Endpoint 'PUT /devices/{id}/config/maintenance/schedule' -Test {
        Set-WUGDeviceMaintenanceSchedule -DeviceId $script:TestDeviceId -DeleteAllSchedules -Confirm:$false -ErrorAction Stop | Out-Null
    }

    # -- Monitors on device ---------------------------------------------------
    Invoke-Test -Cmdlet 'Get-WUGActiveMonitor (device)' -Endpoint 'GET /devices/{id}/monitors/-' -Test {
        $devMons = Get-WUGActiveMonitor -DeviceId "$($script:TestDeviceId)" -ErrorAction Stop
        if ($null -eq $devMons) { throw "Null result" }
    }

    # Assign test monitor to device (if we created one)
    $script:TestAssignmentId = $null
    if ($script:TestMonitorId) {
        Invoke-Test -Cmdlet 'Add-WUGActiveMonitorToDevice' -Endpoint 'POST /devices/{id}/monitors/-' -Test {
            $result = Add-WUGActiveMonitorToDevice -DeviceId $script:TestDeviceId -MonitorId ([int]$script:TestMonitorId) -Comment "Test assignment" -ErrorAction Stop
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

    # -- Group membership -----------------------------------------------------
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

        # Re-add to test device-side removal
        Add-WUGDeviceGroupMember -GroupId $script:TestGroupId -DeviceId "$($script:TestDeviceId)" -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Invoke-Test -Cmdlet 'Remove-WUGDeviceGroupMember (fromDevice)' -Endpoint 'DELETE /devices/{id}/group/{gid}' -Test {
            Remove-WUGDeviceGroupMember -FromDeviceId "$($script:TestDeviceId)" -FromGroupId ([int]$script:TestGroupId) -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }

    # -- Polling - use ByGroup (single-device POST may 404 on some WUG versions)
    if ($script:TestGroupId) {
        Invoke-Test -Cmdlet 'Invoke-WUGDevicePollNow (byGroup)' -Endpoint 'PUT /device-groups/{id}/poll-now' -Test {
            Invoke-WUGDevicePollNow -GroupId ([int]$script:TestGroupId) -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }

    # -- Refresh - use ByGroup (PATCH /devices/refresh may 405 on some WUG versions)
    if ($script:TestGroupId) {
        Invoke-Test -Cmdlet 'Invoke-WUGDeviceRefresh (byGroup)' -Endpoint 'PUT /device-groups/{id}/refresh' -Test {
            Invoke-WUGDeviceRefresh -GroupId ([int]$script:TestGroupId) -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }

    # Single-device refresh uses PUT /devices/{id}/refresh auto-routing
    Invoke-Test -Cmdlet 'Invoke-WUGDeviceRefresh (single-device)' -Endpoint 'PUT /devices/{id}/refresh' -Test {
        Invoke-WUGDeviceRefresh -DeviceId $script:TestDeviceId -Confirm:$false -ErrorAction Stop | Out-Null
    }

    # -- Device Scan ----------------------------------------------------------
    Invoke-Test -Cmdlet 'Get-WUGDeviceScan (list)' -Endpoint 'GET /device-scans/-' -Test {
        Get-WUGDeviceScan -Limit 5 -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceScan (activeOnly)' -Endpoint 'GET /device-scans/- (active)' -Test {
        Get-WUGDeviceScan -ActiveOnly true -Limit 5 -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceScan (model filter)' -Endpoint 'GET /device-scans/- (model)' -Test {
        Get-WUGDeviceScan -Model newDevice -Limit 5 -ErrorAction Stop | Out-Null
    }

    # -- Add-WUGDevice (scan-based) ------------------------------------------
    $script:ScanDeviceId = $null
    Invoke-Test -Cmdlet 'Add-WUGDevice (scan)' -Endpoint 'PATCH /device-groups/{id}/newDevice' -Test {
        $scanResult = Add-WUGDevice -IpOrName '127.0.0.2' -GroupId 0 -Confirm:$false -ErrorAction Stop
        if (-not $scanResult) { throw "No result from Add-WUGDevice" }
        # The API returns a scan/discovery result - capture the scan ID if available
        $script:AddDeviceScanResult = $scanResult
    }

    if ($script:AddDeviceScanResult) {
        # Wait for scan to process
        Write-Host "  Waiting 8 seconds for discovery scan ..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 8

        # Try to retrieve the scan status using the most recent scan
        Invoke-Test -Cmdlet 'Get-WUGDeviceScan (recent scan)' -Endpoint 'GET /device-scans/- (recent)' -Test {
            $scans = Get-WUGDeviceScan -Model newDevice -Limit 1 -ErrorAction Stop
            if (-not $scans) { throw "No scans found" }
        }
    }
}
#endregion

#region -- Performance monitor tests ------------------------------------------
Write-Host "`n[8/12] Testing Add-WUGPerformanceMonitor ..." -ForegroundColor Cyan

$script:PerfMonitorIds = [System.Collections.Generic.List[string]]::new()

if ($script:TestDeviceId) {

    # -- Per-type basic assignment (9 types) ----------------------------------
    Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitor (RestApi)' -Endpoint 'POST /monitors/- + POST /devices/{id}/monitors/-' -Test {
        $r = Add-WUGPerformanceMonitor -DeviceId $script:TestDeviceId -Type RestApi -RestApiUrl 'https://localhost/api/health' -RestApiJsonPath '$.status' -Confirm:$false -ErrorAction Stop
        if (-not $r -or -not $r.MonitorId) { throw "No result or MonitorId returned" }
        $script:PerfMonitorIds.Add("$($r.MonitorId)")
    }

    Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitor (PowerShell)' -Endpoint 'POST /monitors/- + POST /devices/{id}/monitors/-' -Test {
        $r = Add-WUGPerformanceMonitor -DeviceId $script:TestDeviceId -Type PowerShell -ScriptText '$Context.SetValue(1)' -Confirm:$false -ErrorAction Stop
        if (-not $r -or -not $r.MonitorId) { throw "No result or MonitorId returned" }
        $script:PerfMonitorIds.Add("$($r.MonitorId)")
    }

    Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitor (WmiRaw)' -Endpoint 'POST /monitors/- + POST /devices/{id}/monitors/-' -Test {
        $r = Add-WUGPerformanceMonitor -DeviceId $script:TestDeviceId -Type WmiRaw -WmiRawRelativePath 'Win32_PerfRawData_PerfOS_Memory' -WmiRawPropertyName 'AvailableBytes' -WmiRawDisplayname 'Memory \\ Available Bytes' -Confirm:$false -ErrorAction Stop
        if (-not $r -or -not $r.MonitorId) { throw "No result or MonitorId returned" }
        $script:PerfMonitorIds.Add("$($r.MonitorId)")
    }

    Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitor (WmiFormatted)' -Endpoint 'POST /monitors/- + POST /devices/{id}/monitors/-' -Test {
        $r = Add-WUGPerformanceMonitor -DeviceId $script:TestDeviceId -Type WmiFormatted -WmiFormattedRelativePath 'Win32_PerfFormattedData_PerfOS_Memory' -WmiFormattedPropertyName 'AvailableMBytes' -WmiFormattedDisplayname 'Memory \\ Available MBytes' -Confirm:$false -ErrorAction Stop
        if (-not $r -or -not $r.MonitorId) { throw "No result or MonitorId returned" }
        $script:PerfMonitorIds.Add("$($r.MonitorId)")
    }

    Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitor (WinPerfCounter)' -Endpoint 'POST /monitors/- + POST /devices/{id}/monitors/-' -Test {
        $r = Add-WUGPerformanceMonitor -DeviceId $script:TestDeviceId -Type WindowsPerformanceCounter -PerfCounterCategory 'Processor' -PerfCounterName '% Processor Time' -Confirm:$false -ErrorAction Stop
        if (-not $r -or -not $r.MonitorId) { throw "No result or MonitorId returned" }
        $script:PerfMonitorIds.Add("$($r.MonitorId)")
    }

    Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitor (Ssh)' -Endpoint 'POST /monitors/- + POST /devices/{id}/monitors/-' -Test {
        $r = Add-WUGPerformanceMonitor -DeviceId $script:TestDeviceId -Type Ssh -SshCommand 'cat /proc/loadavg | awk ''{print $1}''' -Confirm:$false -ErrorAction Stop
        if (-not $r -or -not $r.MonitorId) { throw "No result or MonitorId returned" }
        $script:PerfMonitorIds.Add("$($r.MonitorId)")
    }

    Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitor (Snmp)' -Endpoint 'POST /monitors/- + POST /devices/{id}/monitors/-' -Test {
        $r = Add-WUGPerformanceMonitor -DeviceId $script:TestDeviceId -Type Snmp -SnmpOID '1.3.6.1.4.1.9.9.13.1.4.1.3' -Confirm:$false -ErrorAction Stop
        if (-not $r -or -not $r.MonitorId) { throw "No result or MonitorId returned" }
        $script:PerfMonitorIds.Add("$($r.MonitorId)")
    }

    Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitor (AzureMetrics)' -Endpoint 'POST /monitors/- + POST /devices/{id}/monitors/-' -Test {
        $r = Add-WUGPerformanceMonitor -DeviceId $script:TestDeviceId -Type AzureMetrics `
            -AzureResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/test-vnet' `
            -AzureResourceMetric 'PacketsInDDoS' `
            -AzureResourceType 'Microsoft.Network/virtualNetworks' `
            -AzureSubscriptionId '00000000-0000-0000-0000-000000000000' `
            -AzureResourceName 'test-vnet' `
            -AzureResourceGroup 'test-rg' `
            -Confirm:$false -ErrorAction Stop
        if (-not $r -or -not $r.MonitorId) { throw "No result or MonitorId returned" }
        $script:PerfMonitorIds.Add("$($r.MonitorId)")
    }

    Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitor (CloudWatch)' -Endpoint 'POST /monitors/- + POST /devices/{id}/monitors/-' -Test {
        $r = Add-WUGPerformanceMonitor -DeviceId $script:TestDeviceId -Type CloudWatch -CloudWatchNamespace 'AWS/Usage' -CloudWatchMetric 'CallCount' -CloudWatchRegion 'us-east-1' -Confirm:$false -ErrorAction Stop
        if (-not $r -or -not $r.MonitorId) { throw "No result or MonitorId returned" }
        $script:PerfMonitorIds.Add("$($r.MonitorId)")
    }

    # -- Required field validation (mandatory params - PowerShell enforces) ---
    Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitor (RestApi mandatory params)' -Endpoint '(validation)' -Test {
        $param = (Get-Command Add-WUGPerformanceMonitor).Parameters['RestApiUrl']
        $isMandatory = $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }
        if (-not $isMandatory) { throw "RestApiUrl should be a mandatory parameter" }
    }

    Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitor (WmiRaw mandatory params)' -Endpoint '(validation)' -Test {
        $param = (Get-Command Add-WUGPerformanceMonitor).Parameters['WmiRawRelativePath']
        $isMandatory = $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }
        if (-not $isMandatory) { throw "WmiRawRelativePath should be a mandatory parameter" }
    }

    # -- Invalid Type --------------------------------------------------
    Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitor (invalid type)' -Endpoint '(validation)' -Test {
        $threw = $false
        try { Add-WUGPerformanceMonitor -DeviceId $script:TestDeviceId -Type 'NonExistentType' -Confirm:$false -ErrorAction Stop 2>$null }
        catch { $threw = $true }
        if (-not $threw) { throw "Expected parameter validation error but none occurred" }
    }

    # -- Invalid DeviceId -----------------------------------------------------
    Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitor (invalid device)' -Endpoint 'POST /monitors/- + POST /devices/{id}/monitors/-' -Test {
        $threw = $false
        try { Add-WUGPerformanceMonitor -DeviceId ([int]::MaxValue) -Type Snmp -SnmpOID '1.3.6.1.4.1.9.9.13.1.4.1.3' -Confirm:$false -ErrorAction Stop 2>$null }
        catch { $threw = $true }
        if (-not $threw) { Write-Verbose "Function did not throw - acceptable if it returned warning or failed assignment" }
    }

    # -- Pipeline input -------------------------------------------------------
    Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitor (pipeline)' -Endpoint 'POST /monitors/- + POST /devices/{id}/monitors/-' -Test {
        $obj = [PSCustomObject]@{ DeviceId = $script:TestDeviceId }
        $r = $obj | Add-WUGPerformanceMonitor -Type Snmp -SnmpOID '1.3.6.1.2.1.1.3.0' -Confirm:$false -ErrorAction Stop
        if (-not $r -or -not $r.MonitorId) { throw "No result from pipeline input" }
        $script:PerfMonitorIds.Add("$($r.MonitorId)")
    }

    # -- Get-WUGPerformanceMonitor (library) ----------------------------------
    Invoke-Test -Cmdlet 'Get-WUGPerformanceMonitor (library)' -Endpoint 'GET /monitors/-?type=performance' -Test {
        $perfMons = Get-WUGPerformanceMonitor -Limit 5 -ErrorAction Stop
        if ($null -eq $perfMons) { throw "Null result" }
    }

    Invoke-Test -Cmdlet 'Get-WUGPerformanceMonitor (search)' -Endpoint 'GET /monitors/-?type=performance&search=...' -Test {
        Get-WUGPerformanceMonitor -Search 'PerfMon-' -Limit 5 -ErrorAction Stop | Out-Null
    }

    # -- Get-WUGPerformanceMonitor (device) -----------------------------------
    Invoke-Test -Cmdlet 'Get-WUGPerformanceMonitor (device)' -Endpoint 'GET /devices/{id}/monitors/-' -Test {
        Get-WUGPerformanceMonitor -DeviceId "$($script:TestDeviceId)" -ErrorAction Stop | Out-Null
    }

    # -- Set-WUGPerformanceMonitor --------------------------------------------
    if ($script:PerfMonitorIds.Count -gt 0) {
        Invoke-Test -Cmdlet 'Set-WUGPerformanceMonitor (update)' -Endpoint 'PUT /monitors/{id}?type=performance' -Test {
            Set-WUGPerformanceMonitor -MonitorId ([int]$script:PerfMonitorIds[0]) -Description 'Updated by test' -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }
}
else {
    Record-Test -Cmdlet 'Add-WUGPerformanceMonitor (all)' -Endpoint '(skipped)' -Status 'Skipped' -Detail 'No test device available'
}
#endregion

#region -- Assign performance monitors to device tests ------------------------
Write-Host "`n--- Phase [8.5/12] Add-WUGPerformanceMonitorToDevice ---" -ForegroundColor Cyan
if ($script:TestDeviceId) {
    # Create 5 perf monitors in library ONLY (no device assignment) for assignment testing.
    # Remove-WUGActiveMonitor -RemoveAssignments does not reliably unassign performance monitors,
    # so we create fresh library-only entries via direct API call and assign them here.
    $script:PerfMonAssignIds = [System.Collections.Generic.List[string]]::new()
    $snmpClassId = '2f300544-cba3-4341-9b05-2d1786f68e07'
    $irmParams = @{ Headers = $global:WUGBearerHeaders; ContentType = 'application/json'; Method = 'POST' }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $irmParams['SkipCertificateCheck'] = $true }
    for ($i = 1; $i -le 5; $i++) {
        $monName = "PerfMon-Assign-Test$i-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $payload = @{
            allowSystemMonitorCreation = $true
            name = $monName
            description = "PerfMonToDevice test monitor $i"
            monitorTypeInfo = @{ baseType = 'performance'; classId = $snmpClassId }
            propertyBags = @(
                @{ name = 'SNMP:OID'; value = "1.3.6.1.2.1.1.3.$i" }
                @{ name = 'SNMP:Instance'; value = '0' }
                @{ name = 'SNMP:UseRawValues'; value = '1' }
                @{ name = 'SNMP:Retries'; value = '1' }
                @{ name = 'SNMP:Timeout'; value = '3' }
            )
            useInDiscovery = $false
        } | ConvertTo-Json -Depth 5
        $uri = "$($global:WhatsUpServerBaseURI)/api/v1/monitors/-"
        try {
            $r = Invoke-RestMethod -Uri $uri @irmParams -Body $payload -ErrorAction Stop
            if ($r.data.successful -eq 1) { $script:PerfMonAssignIds.Add("$($r.data.idMap.resultId)") }
        } catch { Write-Warning "Failed to create PerfMonAssign monitor $i : $_" }
    }

    if ($script:PerfMonAssignIds.Count -ge 5) {
        # Single assignment
        Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitorToDevice (single)' -Endpoint 'POST /devices/{id}/monitors/-' -Test {
            $result = Add-WUGPerformanceMonitorToDevice -DeviceId $script:TestDeviceId -MonitorId ([int]$script:PerfMonAssignIds[0]) -ErrorAction Stop
            if (-not $result) { throw "No result" }
        }

        # Multiple monitors to single device
        Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitorToDevice (multi-monitor)' -Endpoint 'POST /devices/{id}/monitors/-' -Test {
            $ids = @($script:PerfMonAssignIds[1], $script:PerfMonAssignIds[2]) | ForEach-Object { [int]$_ }
            $result = Add-WUGPerformanceMonitorToDevice -DeviceId $script:TestDeviceId -MonitorId $ids -PollingIntervalMinutes 10 -ErrorAction Stop
            if (-not $result) { throw "No result" }
        }

        # Pipeline input
        Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitorToDevice (pipeline)' -Endpoint 'POST /devices/{id}/monitors/-' -Test {
            $obj = [PSCustomObject]@{ DeviceId = $script:TestDeviceId }
            $result = $obj | Add-WUGPerformanceMonitorToDevice -MonitorId ([int]$script:PerfMonAssignIds[3]) -ErrorAction Stop
            if (-not $result) { throw "No result from pipeline input" }
        }

        # Disabled assignment (separate monitor so no unassign needed)
        Invoke-Test -Cmdlet 'Add-WUGPerformanceMonitorToDevice (disabled)' -Endpoint 'POST /devices/{id}/monitors/-' -Test {
            $result = Add-WUGPerformanceMonitorToDevice -DeviceId $script:TestDeviceId -MonitorId ([int]$script:PerfMonAssignIds[4]) -Enabled false -ErrorAction Stop
            if (-not $result) { throw "No result" }
        }
    }
    else {
        Record-Test -Cmdlet 'Add-WUGPerformanceMonitorToDevice (all - insufficient monitors)' -Endpoint '(skipped)' -Status 'Skipped' -Detail "Only $($script:PerfMonAssignIds.Count) of 5 library monitors created"
    }
}
else {
    Record-Test -Cmdlet 'Add-WUGPerformanceMonitorToDevice (all - no device)' -Endpoint '(skipped)' -Status 'Skipped' -Detail 'No test device available'
}
#endregion

#region -- Active monitor (extended types) tests ------------------------------
Write-Host "`n[9/12] Testing Add-WUGActiveMonitor (extended types) ..." -ForegroundColor Cyan

$script:ActiveMonitorTestNames = [System.Collections.Generic.List[string]]::new()
$script:FirstExtActiveMonId = $null

# -- Per-type basic creation (11 extended types) ------------------------------
Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (Dns)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_dns_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type Dns -Name $monName -DnsDomain 'example.com' -DnsRecordType a -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
    $script:FirstExtActiveMonId = if ($r.monitorId) { "$($r.monitorId)" } elseif ($r.id) { "$($r.id)" } else { "$r" }
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (FileContent)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_filecontent_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type FileContent -Name $monName -FileContentFolderPath 'C:\Logs' -FileContentPattern 'ERROR' -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (FileProperties)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_fileprops_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type FileProperties -Name $monName -FilePropertiesPath 'C:\Windows\System32\drivers\etc\hosts' -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (Folder)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_folder_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type Folder -Name $monName -FolderPath 'C:\Temp' -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (HttpContent)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_http_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type HttpContent -Name $monName -HttpContentUrl 'https://localhost/' -HttpContentContent 'OK' -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (NetworkStatistics)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_netstat_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type NetworkStatistics -Name $monName -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (PingJitter)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_jitter_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type PingJitter -Name $monName -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (PowerShell)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_ps_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type PowerShell -Name $monName -PowerShellScriptText '$context.SetResult(0, "OK")' -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (RestApi)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_restapi_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type RestApi -Name $monName -RestApiUrl 'https://localhost/api/health' -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (Ssh)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_ssh_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type Ssh -Name $monName -SshCommand 'uptime' -SshExpectedOutput 'load average' -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

# -- Missing core types (TcpIp, SNMP constant, SNMP range, SNMPTable, Process, Certificate, Service, WMIFormatted, Ftp) --

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (TcpIp)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_tcpip_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type TcpIp -Name $monName -TcpIpPort 443 -TcpIpProtocol SSL -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (SNMP constant)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_snmp_const_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type SNMP -Name $monName -SnmpOID '1.3.6.1.2.1.1.7.0' -SnmpCheckType constant -SnmpValue 72 -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (SNMP range)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_snmp_range_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type SNMP -Name $monName -SnmpOID '1.3.6.1.2.1.1.7.0' -SnmpCheckType range -SnmpLowValue 0 -SnmpHighValue 100 -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (SNMPTable)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_snmptable_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type SNMPTable -Name $monName `
        -SnmpTableDiscOID '1.3.6.1.2.1.25.4.2.1.2' -SnmpTableDiscOperator equals -SnmpTableDiscValue 'svchost.exe' `
        -SnmpTableMonitoredOID '1.3.6.1.2.1.25.4.2.1.7' -SnmpTableMonitorOperator constant -SnmpTableMonitoredValue '1' `
        -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (Process)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_process_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type Process -Name $monName -ProcessName 'svchost.exe' -ProcessDownIfRunning 'false' -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (Certificate)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_cert_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type Certificate -Name $monName -CertOption url -CertPath 'https://localhost' -CertExpiresDays 30 -CertCheckExpires 'true' -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (Service)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_service_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type Service -Name $monName -ServiceDisplayName 'Windows Update' -ServiceInternalName 'wuauserv' -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (WMIFormatted)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_wmi_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type WMIFormatted -Name $monName `
        -WMIFormattedRelativePath 'Win32_PerfFormattedData_PerfOS_Memory' `
        -WMIFormattedPerformanceCounter 'Available MBytes' -WMIFormattedPerformanceInstance 'NULL' `
        -WMIFormattedCheckType constant -WMIFormattedConstantValue 0 `
        -WMIFormattedPropertyName 'AvailableMBytes' -WMIFormattedComputerName 'localhost' `
        -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (Ftp)' -Endpoint 'POST /monitors/-' -Test {
    $monName = "_test_activemon_ftp_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $r = Add-WUGActiveMonitor -Type Ftp -Name $monName -FtpUsername 'anonymous' -FtpPassword 'test@test.com' -Confirm:$false -ErrorAction Stop
    if (-not $r) { throw "No monitor ID returned" }
    $script:ActiveMonitorTestNames.Add($monName)
}

# -- Assign extended active monitors to device --------------------------------
if ($script:TestDeviceId -and $script:FirstExtActiveMonId) {
    Invoke-Test -Cmdlet 'Add-WUGActiveMonitorToDevice (extended)' -Endpoint 'POST /devices/{id}/monitors/-' -Test {
        $result = Add-WUGActiveMonitorToDevice -DeviceId $script:TestDeviceId -MonitorId ([int]$script:FirstExtActiveMonId) -ErrorAction Stop
        if (-not $result) { throw "No result" }
    }
}

# -- Validation: mandatory parameter declarations -----------------------------
Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (Ssh mandatory params)' -Endpoint '(validation)' -Test {
    $param = (Get-Command Add-WUGActiveMonitor).Parameters['SshExpectedOutput']
    $isMandatory = $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }
    if (-not $isMandatory) { throw "SshExpectedOutput should be a mandatory parameter" }
}

Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (RestApi mandatory params)' -Endpoint '(validation)' -Test {
    $param = (Get-Command Add-WUGActiveMonitor).Parameters['RestApiUrl']
    $isMandatory = $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }
    if (-not $isMandatory) { throw "RestApiUrl should be a mandatory parameter" }
}

# -- Validation: invalid type -------------------------------------------------
Invoke-Test -Cmdlet 'Add-WUGActiveMonitor (invalid type)' -Endpoint '(validation)' -Test {
    $threw = $false
    try { Add-WUGActiveMonitor -Type 'NotAType' -Name '_test_should_fail' -Confirm:$false -ErrorAction Stop 2>$null }
    catch { $threw = $true }
    if (-not $threw) { throw "Expected parameter validation error but none occurred" }
}
#endregion

#region -- Reports (device-level) ---------------------------------------------
Write-Host "`n[10/12] Testing device report endpoints ..." -ForegroundColor Cyan

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

    # -- Report parameter variations ------------------------------------------
    Invoke-Test -Cmdlet 'Get-WUGDeviceReport (lastNHours)' -Endpoint 'GET /devices/{id}/reports/cpu (lastN)' -Test {
        Get-WUGDeviceReport -DeviceId $script:TestDeviceId -ReportType Cpu -Range lastNHours -RangeN 4 -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceReport (lastWeek)' -Endpoint 'GET /devices/{id}/reports/memory (lastWeek)' -Test {
        Get-WUGDeviceReport -DeviceId $script:TestDeviceId -ReportType Memory -Range lastWeek -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceReport (custom range)' -Endpoint 'GET /devices/{id}/reports/cpu (custom)' -Test {
        $start = (Get-Date).AddDays(-7).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $end = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Get-WUGDeviceReport -DeviceId $script:TestDeviceId -ReportType Cpu -Range custom -RangeStartUtc $start -RangeEndUtc $end -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceReport (threshold)' -Endpoint 'GET /devices/{id}/reports/cpu (threshold)' -Test {
        Get-WUGDeviceReport -DeviceId $script:TestDeviceId -ReportType Cpu -Range today -ApplyThreshold true -OverThreshold true -ThresholdValue 90 -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceReport (sorted)' -Endpoint 'GET /devices/{id}/reports/cpu (sorted)' -Test {
        Get-WUGDeviceReport -DeviceId $script:TestDeviceId -ReportType Cpu -Range today -SortBy deviceName -SortByDir asc -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceReport (rollup)' -Endpoint 'GET /devices/{id}/reports/cpu (rollup)' -Test {
        Get-WUGDeviceReport -DeviceId $script:TestDeviceId -ReportType Cpu -Range today -RollupByDevice true -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceReport (lastNDays)' -Endpoint 'GET /devices/{id}/reports/disk (lastNDays)' -Test {
        Get-WUGDeviceReport -DeviceId $script:TestDeviceId -ReportType Disk -Range lastNDays -RangeN 3 -ErrorAction Stop | Out-Null
    }

    Invoke-Test -Cmdlet 'Get-WUGDeviceReport (pipeline)' -Endpoint 'GET /devices/{id}/reports/ping (pipeline)' -Test {
        $script:TestDeviceId | Get-WUGDeviceReport -ReportType PingAvailability -Range today -ErrorAction Stop | Out-Null
    }
}
#endregion

#region -- Reports (group-level) ----------------------------------------------
Write-Host "`n[11/12] Testing device-group report endpoints ..." -ForegroundColor Cyan

# Use root group (0) for group reports - always exists and has aggregated data

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

# -- Group report parameter variations ----------------------------------------
Invoke-Test -Cmdlet 'Get-WUGDeviceGroupReport (hierarchy)' -Endpoint 'GET /device-groups/{id}/reports/cpu (hierarchy)' -Test {
    Get-WUGDeviceGroupReport -GroupId 0 -ReportType Cpu -Range today -ReturnHierarchy true -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGDeviceGroupReport (lastNHours)' -Endpoint 'GET /device-groups/{id}/reports/memory (lastN)' -Test {
    Get-WUGDeviceGroupReport -GroupId 0 -ReportType Memory -Range lastNHours -RangeN 6 -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGDeviceGroupReport (custom range)' -Endpoint 'GET /device-groups/{id}/reports/disk (custom)' -Test {
    $start = (Get-Date).AddDays(-7).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $end = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Get-WUGDeviceGroupReport -GroupId 0 -ReportType Disk -Range custom -RangeStartUtc $start -RangeEndUtc $end -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGDeviceGroupReport (threshold)' -Endpoint 'GET /device-groups/{id}/reports/cpu (threshold)' -Test {
    Get-WUGDeviceGroupReport -GroupId 0 -ReportType Cpu -Range today -ApplyThreshold true -OverThreshold true -ThresholdValue 90 -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGDeviceGroupReport (sorted)' -Endpoint 'GET /device-groups/{id}/reports/ping (sorted)' -Test {
    Get-WUGDeviceGroupReport -GroupId 0 -ReportType PingAvailability -Range today -SortBy deviceName -SortByDir asc -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGDeviceGroupReport (rollup)' -Endpoint 'GET /device-groups/{id}/reports/memory (rollup)' -Test {
    Get-WUGDeviceGroupReport -GroupId 0 -ReportType Memory -Range lastWeek -RollupByDevice true -ErrorAction Stop | Out-Null
}

Invoke-Test -Cmdlet 'Get-WUGDeviceGroupReport (pipeline)' -Endpoint 'GET /device-groups/{id}/reports/stateChange (pipeline)' -Test {
    @(0) | Get-WUGDeviceGroupReport -ReportType StateChange -Range today -ErrorAction Stop | Out-Null
}
#endregion

#region -- Passive monitor tests ----------------------------------------------
Write-Host "`n--- Phase [10.5/12] Passive Monitor CRUD (Add/Get/Set/Remove) ---" -ForegroundColor Cyan

$script:PassiveMonitorIds = [System.Collections.Generic.List[string]]::new()
$script:PassiveMonitorNames = [System.Collections.Generic.List[string]]::new()

if ($script:TestDeviceId) {
    # -- SNMP Trap creation ---------------------------------------------------
    Invoke-Test -Cmdlet 'Add-WUGPassiveMonitor (SnmpTrap basic)' -Endpoint 'POST /monitors/-' -Test {
        $monName = "WhatsUpGoldPS-Test-SnmpTrap-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $r = Add-WUGPassiveMonitor -Type SnmpTrap -Name $monName -SnmpTrapExpression 'test trap pattern' -Confirm:$false -ErrorAction Stop
        if (-not $r -or -not $r.MonitorId) { throw "No result or MonitorId returned" }
        $script:PassiveMonitorIds.Add("$($r.MonitorId)")
        $script:PassiveMonitorNames.Add($monName)
    }

    Invoke-Test -Cmdlet 'Add-WUGPassiveMonitor (SnmpTrap enterprise)' -Endpoint 'POST /monitors/-' -Test {
        $monName = "WhatsUpGoldPS-Test-SnmpTrapEnt-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $r = Add-WUGPassiveMonitor -Type SnmpTrap -Name $monName -SnmpTrapOID '1.3.6.1.4.1.9.9.13.1.4.1.3' -SnmpTrapSpecificType '1' -SnmpTrapExpression 'enterprise match' -SnmpTrapMatchCase '1' -SnmpTrapInvertResult '1' -Confirm:$false -ErrorAction Stop
        if (-not $r -or -not $r.MonitorId) { throw "No result or MonitorId returned" }
        $script:PassiveMonitorIds.Add("$($r.MonitorId)")
        $script:PassiveMonitorNames.Add($monName)
    }

    # Create a 3rd SNMP trap for pipeline testing
    Invoke-Test -Cmdlet 'Add-WUGPassiveMonitor (SnmpTrap pipeline)' -Endpoint 'POST /monitors/-' -Test {
        $monName = "WhatsUpGoldPS-Test-SnmpTrapPipe-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $r = Add-WUGPassiveMonitor -Type SnmpTrap -Name $monName -SnmpTrapExpression 'pipeline test pattern' -Confirm:$false -ErrorAction Stop
        if (-not $r -or -not $r.MonitorId) { throw "No result or MonitorId returned" }
        $script:PassiveMonitorIds.Add("$($r.MonitorId)")
        $script:PassiveMonitorNames.Add($monName)
    }

    # -- Assign to device -----------------------------------------------------
    if ($script:PassiveMonitorIds.Count -ge 3) {
        Invoke-Test -Cmdlet 'Add-WUGPassiveMonitorToDevice (single)' -Endpoint 'POST /devices/{id}/monitors/-' -Test {
            $result = Add-WUGPassiveMonitorToDevice -DeviceId $script:TestDeviceId -MonitorId ([int]$script:PassiveMonitorIds[0]) -ErrorAction Stop
            if (-not $result) { throw "No result" }
        }

        Invoke-Test -Cmdlet 'Add-WUGPassiveMonitorToDevice (pipeline)' -Endpoint 'POST /devices/{id}/monitors/-' -Test {
            $obj = [PSCustomObject]@{ DeviceId = $script:TestDeviceId }
            $result = $obj | Add-WUGPassiveMonitorToDevice -MonitorId ([int]$script:PassiveMonitorIds[2]) -ErrorAction Stop
            if (-not $result) { throw "No result from pipeline input" }
        }
    }
    elseif ($script:PassiveMonitorIds.Count -gt 0) {
        Invoke-Test -Cmdlet 'Add-WUGPassiveMonitorToDevice (single fallback)' -Endpoint 'POST /devices/{id}/monitors/-' -Test {
            $result = Add-WUGPassiveMonitorToDevice -DeviceId $script:TestDeviceId -MonitorId ([int]$script:PassiveMonitorIds[0]) -ErrorAction Stop
            if (-not $result) { throw "No result" }
        }
    }

    # -- Validation: invalid type ---------------------------------------------
    Invoke-Test -Cmdlet 'Add-WUGPassiveMonitor (invalid type)' -Endpoint '(validation)' -Test {
        $threw = $false
        try { Add-WUGPassiveMonitor -Type 'NonExistentType' -Name 'bad' -Confirm:$false -ErrorAction Stop 2>$null }
        catch { $threw = $true }
        if (-not $threw) { throw "Expected parameter validation error but none occurred" }
    }

    # -- Syslog passive monitors ---------------------------------------------
    Invoke-Test -Cmdlet 'Add-WUGPassiveMonitor (Syslog)' -Endpoint 'POST /monitors/-' -Test {
        $monName = "WhatsUpGoldPS-Test-Syslog-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $r = Add-WUGPassiveMonitor -Type Syslog -Name $monName -SyslogExpression "error|critical" -Confirm:$false -ErrorAction Stop
        if (-not $r) { throw "No result" }
        $script:PassiveMonitorIds.Add("$($r.MonitorId)")
        $script:PassiveMonitorNames.Add($monName)
    }

    Invoke-Test -Cmdlet 'Add-WUGPassiveMonitor (Syslog case-sensitive)' -Endpoint 'POST /monitors/-' -Test {
        $monName = "WhatsUpGoldPS-Test-SyslogCase-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $r = Add-WUGPassiveMonitor -Type Syslog -Name $monName -SyslogExpression "CRITICAL" -SyslogMatchCase '1' -Confirm:$false -ErrorAction Stop
        if (-not $r) { throw "No result" }
        $script:PassiveMonitorIds.Add("$($r.MonitorId)")
        $script:PassiveMonitorNames.Add($monName)
    }

    # -- WinEvent passive monitors --------------------------------------------
    Invoke-Test -Cmdlet 'Add-WUGPassiveMonitor (WinEvent)' -Endpoint 'POST /monitors/-' -Test {
        $monName = "WhatsUpGoldPS-Test-WinEvent-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $r = Add-WUGPassiveMonitor -Type WinEvent -Name $monName -WinEventExpression "Application Error" -Confirm:$false -ErrorAction Stop
        if (-not $r) { throw "No result" }
        $script:PassiveMonitorIds.Add("$($r.MonitorId)")
        $script:PassiveMonitorNames.Add($monName)
    }

    Invoke-Test -Cmdlet 'Add-WUGPassiveMonitor (WinEvent inverted)' -Endpoint 'POST /monitors/-' -Test {
        $monName = "WhatsUpGoldPS-Test-WinEventInv-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $r = Add-WUGPassiveMonitor -Type WinEvent -Name $monName -WinEventExpression "Healthy" -WinEventInvertResult '1' -Confirm:$false -ErrorAction Stop
        if (-not $r) { throw "No result" }
        $script:PassiveMonitorIds.Add("$($r.MonitorId)")
        $script:PassiveMonitorNames.Add($monName)
    }

    # -- Assign remaining passive monitors to device --------------------------
    if ($script:PassiveMonitorIds.Count -ge 2) {
        Invoke-Test -Cmdlet 'Add-WUGPassiveMonitorToDevice (multi-monitor)' -Endpoint 'POST /devices/{id}/monitors/-' -Test {
            $ids = $script:PassiveMonitorIds | ForEach-Object { [int]$_ }
            $result = Add-WUGPassiveMonitorToDevice -DeviceId $script:TestDeviceId -MonitorId $ids -ErrorAction Stop
            if (-not $result) { throw "No result" }
        }
    }

    # -- Get-WUGPassiveMonitor (library) --------------------------------------
    Invoke-Test -Cmdlet 'Get-WUGPassiveMonitor (library all)' -Endpoint 'GET /monitors/-?type=passive' -Test {
        $result = Get-WUGPassiveMonitor -ErrorAction Stop
        if (-not $result) { throw "No passive monitors returned from library" }
    }

    Invoke-Test -Cmdlet 'Get-WUGPassiveMonitor (library search)' -Endpoint 'GET /monitors/-?type=passive&search=...' -Test {
        $result = Get-WUGPassiveMonitor -Search "WhatsUpGoldPS-Test-" -ErrorAction Stop
        if (-not $result) { throw "No passive monitors returned for search" }
    }

    Invoke-Test -Cmdlet 'Get-WUGPassiveMonitor (library details view)' -Endpoint 'GET /monitors/-?type=passive&view=details' -Test {
        $result = Get-WUGPassiveMonitor -View details -Search "WhatsUpGoldPS-Test-" -ErrorAction Stop
        if (-not $result) { throw "No passive monitors returned with details view" }
        # details view should include propertyBags
        $first = @($result)[0]
        if (-not $first.propertyBags) { throw "Details view did not return propertyBags" }
    }

    # -- Get-WUGPassiveMonitor (by ID) ----------------------------------------
    if ($script:PassiveMonitorIds.Count -gt 0) {
        Invoke-Test -Cmdlet 'Get-WUGPassiveMonitor (by ID)' -Endpoint 'GET /monitors/{monitorId}?type=passive' -Test {
            $result = Get-WUGPassiveMonitor -MonitorId $script:PassiveMonitorIds[0] -View details -ErrorAction Stop
            if (-not $result) { throw "No result returned for monitor by ID" }
        }
    }

    # -- Get-WUGPassiveMonitor (device assignments) ---------------------------
    Invoke-Test -Cmdlet 'Get-WUGPassiveMonitor (device)' -Endpoint 'GET /devices/{id}/monitors/-?type=passive' -Test {
        $result = Get-WUGPassiveMonitor -DeviceId "$($script:TestDeviceId)" -ErrorAction Stop
        if (-not $result) { throw "No passive monitor assignments returned for device" }
        $first = @($result)[0]
        if (-not $first.DeviceMonitorAssignmentId) { throw "Missing DeviceMonitorAssignmentId in device result" }
    }

    Invoke-Test -Cmdlet 'Get-WUGPassiveMonitor (device search)' -Endpoint 'GET /devices/{id}/monitors/-?type=passive&search=...' -Test {
        $result = Get-WUGPassiveMonitor -DeviceId "$($script:TestDeviceId)" -Search "WhatsUpGoldPS-Test-" -ErrorAction Stop
        if (-not $result) { throw "No results for device passive monitor search" }
    }

    # -- Set-WUGPassiveMonitor (update library definition) --------------------
    if ($script:PassiveMonitorIds.Count -gt 0) {
        Invoke-Test -Cmdlet 'Set-WUGPassiveMonitor (update description)' -Endpoint 'PUT /monitors/{id}?type=passive' -Test {
            Set-WUGPassiveMonitor -MonitorId $script:PassiveMonitorIds[0] -Description "Updated by E2E test at $(Get-Date -Format 'HH:mm:ss')" -Confirm:$false -ErrorAction Stop | Out-Null
        }

        Invoke-Test -Cmdlet 'Set-WUGPassiveMonitor (update name)' -Endpoint 'PUT /monitors/{id}?type=passive' -Test {
            $newName = "WhatsUpGoldPS-Test-Renamed-$(Get-Date -Format 'yyyyMMddHHmmss')"
            Set-WUGPassiveMonitor -MonitorId $script:PassiveMonitorIds[0] -Name $newName -Confirm:$false -ErrorAction Stop | Out-Null
            # Update tracked name so cleanup can find it
            $script:PassiveMonitorNames[0] = $newName
        }

        Invoke-Test -Cmdlet 'Set-WUGPassiveMonitor (no params warning)' -Endpoint '(validation)' -Test {
            # Should produce a warning but not throw
            Set-WUGPassiveMonitor -MonitorId $script:PassiveMonitorIds[0] -Confirm:$false -ErrorAction Stop 3>$null
        }
    }

    # -- Remove-WUGPassiveMonitor (by ID) -------------------------------------
    # Remove the last monitor individually to test ById, rest will be cleaned up by search
    if ($script:PassiveMonitorIds.Count -ge 2) {
        $removeByIdTarget = $script:PassiveMonitorIds[$script:PassiveMonitorIds.Count - 1]
        Invoke-Test -Cmdlet 'Remove-WUGPassiveMonitor (by ID)' -Endpoint 'DELETE /monitors/{id}?type=passive' -Test {
            Remove-WUGPassiveMonitor -MonitorId $removeByIdTarget -FailIfInUse $false -Confirm:$false -ErrorAction Stop | Out-Null
        }
        # Remove from tracking so cleanup doesn't try again
        $script:PassiveMonitorIds.RemoveAt($script:PassiveMonitorIds.Count - 1)
        $script:PassiveMonitorNames.RemoveAt($script:PassiveMonitorNames.Count - 1)
    }
}
else {
    Record-Test -Cmdlet 'Add-WUGPassiveMonitor (all)' -Endpoint '(skipped)' -Status 'Skipped' -Detail 'No test device available'
}
#endregion

#region -- Previously-untested functions: Set-WUGDeviceTemplate, Set-WUGActiveMonitor, Set-WUGDeviceGroupMembership, Add-WUGDeviceTemplates, Remove-WUGDevices
Write-Host "`n--- Phase [11.5/12] Set-WUGDeviceTemplate, Set-WUGActiveMonitor, Set-WUGDeviceGroupMembership, Add-WUGDeviceTemplates, Remove-WUGDevices ---" -ForegroundColor Cyan

$script:BulkTestDeviceId = $null

if ($script:TestDeviceId) {
    # -- Set-WUGDeviceTemplate ------------------------------------------------
    Invoke-Test -Cmdlet 'Set-WUGDeviceTemplate' -Endpoint 'PATCH /devices/-/config/template' -Test {
        $template = Get-WUGDeviceTemplate -DeviceId $script:TestDeviceId -ErrorAction Stop
        if (-not $template) { throw "No template returned from Get-WUGDeviceTemplate" }
        $template.note = "Updated by Set-WUGDeviceTemplate E2E test at $(Get-Date -Format 'HH:mm:ss')"
        Set-WUGDeviceTemplate -DeviceId $script:TestDeviceId -Template $template -Confirm:$false -ErrorAction Stop | Out-Null
    }

    # -- Set-WUGActiveMonitor (Device mode: update existing assignment) -------
    # First ensure there is an active monitor assignment on the device by re-adding one
    $script:Phase11AssignmentId = $null
    # Query existing device monitor assignments (field is DeviceMonitorAssignmentId)
    $devMons = Get-WUGActiveMonitor -DeviceId "$($script:TestDeviceId)" -ErrorAction SilentlyContinue
    if ($devMons) {
        foreach ($m in @($devMons)) {
            if ($m.DeviceMonitorAssignmentId) { $script:Phase11AssignmentId = "$($m.DeviceMonitorAssignmentId)"; break }
        }
    }
    if (-not $script:Phase11AssignmentId -and $script:TestMonitorId) {
        # Try re-adding the test monitor
        $reAddResult = Add-WUGActiveMonitorToDevice -DeviceId $script:TestDeviceId -MonitorId ([int]$script:TestMonitorId) -ErrorAction SilentlyContinue
        if ($reAddResult) {
            $script:Phase11AssignmentId = if ($reAddResult.DeviceMonitorAssignmentId) { "$($reAddResult.DeviceMonitorAssignmentId)" } elseif ($reAddResult.id) { "$($reAddResult.id)" } else { $null }
        }
    }

    if ($script:Phase11AssignmentId) {
        Invoke-Test -Cmdlet 'Set-WUGActiveMonitor (Device update)' -Endpoint 'PUT /devices/{id}/monitors/{aId}' -Test {
            Set-WUGActiveMonitor -Mode Device -DeviceId $script:TestDeviceId -AssignmentId ([int]$script:Phase11AssignmentId) -Enabled "true" -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }
    else {
        Record-Test -Cmdlet 'Set-WUGActiveMonitor (Device update)' -Endpoint 'PUT /devices/{id}/monitors/{aId}' -Status 'Skipped' -Detail 'No monitor assignment available'
    }

    # -- Set-WUGActiveMonitor (Library mode: update monitor definition) -------
    if ($script:TestMonitorId) {
        Invoke-Test -Cmdlet 'Set-WUGActiveMonitor (Library update)' -Endpoint 'PUT /monitors/{id}?type=active' -Test {
            Set-WUGActiveMonitor -Mode Library -MonitorId "$($script:TestMonitorId)" -Description "Updated by E2E test" -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }

    # -- Set-WUGDeviceGroupMembership (Assign via PUT) ------------------------
    if ($script:TestGroupId) {
        Invoke-Test -Cmdlet 'Set-WUGDeviceGroupMembership (assign)' -Endpoint 'PUT /devices/{id}/group/-' -Test {
            $body = "`"$($script:TestGroupId)`""
            Set-WUGDeviceGroupMembership -DeviceId "$($script:TestDeviceId)" -Body $body -Confirm:$false -ErrorAction Stop | Out-Null
        }

        # Verify membership was set
        Invoke-Test -Cmdlet 'Set-WUGDeviceGroupMembership (verify)' -Endpoint 'GET /devices/{id}/group/{gid}/is-member' -Test {
            Get-WUGDeviceGroupMembership -DeviceId "$($script:TestDeviceId)" -IsMember -TargetGroupId ([int]$script:TestGroupId) -ErrorAction Stop | Out-Null
        }

        # Clean up: remove the device from the group
        Remove-WUGDeviceGroupMember -FromDeviceId "$($script:TestDeviceId)" -FromGroupId ([int]$script:TestGroupId) -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

        # -- Set-WUGDeviceGroupMembership (Batch via PATCH) -------------------
        Invoke-Test -Cmdlet 'Set-WUGDeviceGroupMembership (batch)' -Endpoint 'PATCH /devices/{id}/group/-' -Test {
            $body = @{ groupsToAdd = @("$($script:TestGroupId)") } | ConvertTo-Json -Depth 5
            Set-WUGDeviceGroupMembership -DeviceId "$($script:TestDeviceId)" -Batch -Body $body -Confirm:$false -ErrorAction Stop | Out-Null
        }

        # Clean up batch membership
        Remove-WUGDeviceGroupMember -FromDeviceId "$($script:TestDeviceId)" -FromGroupId ([int]$script:TestGroupId) -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }

    # -- Add-WUGDeviceTemplates (bulk device creation) ------------------------
    Invoke-Test -Cmdlet 'Add-WUGDeviceTemplates' -Endpoint 'PATCH /devices/-/config/template' -Test {
        $bulkDisplayName = "WUGPS-BulkTest-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $bulkTemplate = @{
            templateId     = "WUGPS-BulkTest"
            displayName    = $bulkDisplayName
            primaryRole    = "Device"
            subRoles       = @("Resource Attributes", "Resource Monitors")
            os             = "Not Set"
            brand          = "Not Set"
            note           = "Created by Add-WUGDeviceTemplates E2E test"
            autoRefresh    = "true"
            interfaces     = @(
                @{
                    defaultInterface     = "true"
                    pollUsingNetworkName = "false"
                    networkAddress       = "127.0.0.3"
                    networkName          = "127.0.0.3"
                }
            )
            activeMonitors = @(
                @{
                    classId = ''
                    name    = 'Ping'
                }
            )
            groups         = @(@{ name = 'My Network' })
        }

        $result = Add-WUGDeviceTemplates -deviceTemplates @($bulkTemplate) -Confirm:$false -ErrorAction Stop
        if (-not $result) { throw "No result from Add-WUGDeviceTemplates" }

        # Try to capture the created device ID for cleanup
        if ($result.idMap) {
            $script:BulkTestDeviceId = $result.idMap.resultId
        }
        elseif ($result -is [array] -and $result.Count -gt 0 -and $result[0].idMap) {
            $script:BulkTestDeviceId = $result[0].idMap.resultId
        }

        # If we could not capture from response, search for it
        if (-not $script:BulkTestDeviceId) {
            Start-Sleep -Seconds 3
            $found = Get-WUGDevice -SearchValue $bulkDisplayName -ErrorAction SilentlyContinue
            if ($found) {
                $script:BulkTestDeviceId = if ($found[0].id) { $found[0].id } elseif ($found[0]) { $found[0] } else { $null }
            }
        }
    }

    # -- Remove-WUGDevices (bulk removal) -------------------------------------
    # Create a second temporary device to test bulk removal
    $script:RemoveTestDeviceId = $null
    $removeTestName = "WUGPS-RemoveTest-$([guid]::NewGuid().ToString('N').Substring(0,8))"

    Invoke-Test -Cmdlet 'Remove-WUGDevices (setup)' -Endpoint 'POST /devices/-/config/template' -Test {
        $result = Add-WUGDeviceTemplate -DeviceAddress '127.0.0.4' -displayName $removeTestName `
            -primaryRole 'Device' -note "Temp device for Remove-WUGDevices test" -Confirm:$false -ErrorAction Stop
        if (-not $result) { throw "No result from setup device creation" }
        $script:RemoveTestDeviceId = $result.idMap.resultId
        if (-not $script:RemoveTestDeviceId) { throw "No resultId for remove test device" }
    }

    if ($script:RemoveTestDeviceId) {
        Start-Sleep -Seconds 2

        Invoke-Test -Cmdlet 'Remove-WUGDevices' -Endpoint 'PATCH /devices/- (delete)' -Test {
            $result = Remove-WUGDevices -DeviceId @([int]$script:RemoveTestDeviceId) -Confirm:$false -ErrorAction Stop
            if (-not $result.success) { throw "Remove-WUGDevices reported failure: $($result | ConvertTo-Json -Compress)" }
        }
    }
}
else {
    Record-Test -Cmdlet 'Set-WUGDeviceTemplate (all phase 11.5)' -Endpoint '(skipped)' -Status 'Skipped' -Detail 'No test device available'
}
#endregion

#region -- Cleanup ------------------------------------------------------------
Write-Host "`n[12/12] Cleaning up test artefacts ..." -ForegroundColor Cyan

# Remove passive monitors created during phase 10.5 (by name, then catch-all search)
if ($script:PassiveMonitorNames.Count -gt 0) {
    foreach ($pmName in $script:PassiveMonitorNames) {
        Invoke-Test -Cmdlet "Remove-WUGPassiveMonitor ($pmName)" -Endpoint 'DELETE /monitors/-?type=passive' -Test {
            Remove-WUGPassiveMonitor -Search $pmName -FailIfInUse $false -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }
}
# Catch-all: remove any leftover WhatsUpGoldPS-Test passive monitors from previous runs
Invoke-Test -Cmdlet 'Remove-WUGPassiveMonitor (catch-all cleanup)' -Endpoint 'DELETE /monitors/-?type=passive' -Test {
    Remove-WUGPassiveMonitor -Search "WhatsUpGoldPS-Test-" -FailIfInUse $false -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

# Remove bulk-created monitors from Add-WUGMonitorTemplate test
if ($script:BulkMonitorNames.Count -gt 0) {
    foreach ($bmName in $script:BulkMonitorNames) {
        Invoke-Test -Cmdlet "Remove-WUGActiveMonitor (bulkMon $bmName)" -Endpoint 'DELETE /monitors/-' -Test {
            Remove-WUGActiveMonitor -Search $bmName -Type active -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }
}

# Remove performance monitors created during phase 8 (use BySearch - ById endpoint only works for active monitors)
# Performance monitors auto-named: PerfMon-{Type}-Device{DeviceId}-{timestamp}
Invoke-Test -Cmdlet 'Remove-WUGActiveMonitor (perfMons by search)' -Endpoint 'DELETE /monitors/-?type=performance' -Test {
    Remove-WUGActiveMonitor -Search "PerfMon-" -Type performance -FailIfInUse $false -Confirm:$false -ErrorAction Stop | Out-Null
}

# Remove active monitors created during phase 9 (by search name)
if ($script:ActiveMonitorTestNames.Count -gt 0) {
    foreach ($amName in $script:ActiveMonitorTestNames) {
        Invoke-Test -Cmdlet "Remove-WUGActiveMonitor (activeMon $amName)" -Endpoint 'DELETE /monitors/-' -Test {
            Remove-WUGActiveMonitor -Search $amName -Type active -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }
}

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

# Remove the bulk-created device from Add-WUGDeviceTemplates test
if ($script:BulkTestDeviceId) {
    Invoke-Test -Cmdlet 'Remove-WUGDevice (bulk test device)' -Endpoint 'DELETE /devices/{id}' -Test {
        Remove-WUGDevice -DeviceId $script:BulkTestDeviceId -Confirm:$false -ErrorAction Stop | Out-Null
    }
}

# Remove the scan-created device (127.0.0.2) if it was added
if ($script:AddDeviceScanResult) {
    Invoke-Test -Cmdlet 'Remove-WUGDevice (scan device)' -Endpoint 'DELETE /devices/{id}' -Test {
        $scanDev = Get-WUGDevice -SearchValue '127.0.0.2' -ErrorAction SilentlyContinue
        if ($scanDev) {
            $scanDevId = if ($scanDev[0].id) { $scanDev[0].id } elseif ($scanDev[0]) { $scanDev[0] } else { $null }
            if ($scanDevId) {
                Remove-WUGDevice -DeviceId $scanDevId -Confirm:$false -ErrorAction Stop | Out-Null
            }
        }
    }
}

# Remove the test group
if ($script:TestGroupId) {
    Invoke-Test -Cmdlet 'Remove-WUGDeviceGroup' -Endpoint 'DELETE /device-groups/{id}' -Test {
        Remove-WUGDeviceGroup -GroupId $script:TestGroupId -Confirm:$false -ErrorAction Stop | Out-Null
    }
}

# Remove test credentials from library (unassign first, then delete)
if ($script:TestCredentialIds.Count -gt 0) {
    foreach ($credId in $script:TestCredentialIds) {
        # Unassign all device assignments before deleting
        Set-WUGCredential -CredentialId $credId -UnassignAll -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Invoke-Test -Cmdlet "Set-WUGCredential (delete $credId)" -Endpoint 'DELETE /credentials/{id}' -Test {
            Set-WUGCredential -CredentialId $credId -Remove -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }
}

# Disconnect
Invoke-Test -Cmdlet 'Disconnect-WUGServer' -Endpoint '(session cleanup)' -Test {
    Disconnect-WUGServer -ErrorAction Stop
    if ($global:WUGBearerHeaders) { throw "Headers still set after disconnect" }
}
#endregion

#region -- Summary ------------------------------------------------------------
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

#region -- HTML Dashboard -----------------------------------------------------
try {
    $templatePath = Join-Path $PSScriptRoot 'Test-Dashboard-Template.html'
    if (Test-Path $templatePath) {
        # Build Bootstrap Table columns JSON
        $columns = @(
            @{ field = 'Cmdlet';   title = 'Cmdlet';   sortable = $true; filterControl = 'input' }
            @{ field = 'Endpoint'; title = 'Endpoint'; sortable = $true; filterControl = 'input' }
            @{ field = 'Status';   title = 'Status';   sortable = $true; filterControl = 'select'; formatter = 'formatTestStatus' }
            @{ field = 'Detail';   title = 'Detail';   sortable = $true; filterControl = 'input' }
        )
        $columnsJson = ($columns | ConvertTo-Json -Depth 4 -Compress) -replace '"formatTestStatus"', 'formatTestStatus'

        # Build data JSON (escape for safe embedding)
        $dataRows = $script:TestResults | ForEach-Object {
            @{
                Cmdlet   = $_.Cmdlet
                Endpoint = $_.Endpoint
                Status   = $_.Status
                Detail   = $_.Detail
            }
        }
        $dataJson = @($dataRows) | ConvertTo-Json -Depth 4 -Compress
        if ($script:TestResults.Count -eq 1) { $dataJson = "[$dataJson]" }

        # Build the bootstrap-table init block
        $tableInit = "columns: $columnsJson,`n            data: $dataJson"

        # Read template and replace tokens
        $html = Get-Content $templatePath -Raw
        $html = $html -replace 'replaceThisHere', $tableInit
        $html = $html -replace 'ReplaceYourReportNameHere', 'WhatsUpGoldPS Test Results'
        $html = $html -replace 'ReplaceUpdateTimeHere', (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

        # Write dashboard to %TEMP%
        $dashboardPath = Join-Path $env:TEMP "WhatsUpGoldPS-TestResults-$(Get-Date -Format 'yyyyMMddHHmmss').html"
        $html | Out-File -FilePath $dashboardPath -Encoding utf8 -Force

        Write-Host "`n  Dashboard: $dashboardPath" -ForegroundColor Green
        Start-Process $dashboardPath
    }
    else {
        Write-Host "`n  [WARN] Dashboard template not found at: $templatePath" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "`n  [WARN] Dashboard generation failed: $($_.Exception.Message)" -ForegroundColor Yellow
}
#endregion

# Return results object
$script:TestResults
#endregion

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBSsGAHZFQfN+cI
# svB0Ju5To2is58YSKTuWl+wHHtJ2/qCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgvX2J5hPp3V8ApR5G0pZh4gBppyQvv1wO
# VvPQV6NwknIwDQYJKoZIhvcNAQEBBQAEggIA6n/5JoDdHukYj8BIzumiDojYIVit
# Q00NVCw7VQyQgo6qGX56tsoS9JMeG/9Kf6HJUkwlkgA0xHDaNoxz1H7nJp0XMs5f
# oC7lEf2pTIHo5/RifKuQwJbqIzQuh6/FZucljMF7oyBmZAaP6HNRIYUPtkNn/BIA
# vx3EJL/mwqM6sjrN/bKH3g5wuoCR0zawkcBnl4v2UctucMRgdHVpOpCIy7XT7uCU
# tWTwQXbIg/7G5r/8xg2jqdGM4XNoVdMvbuXdJFNENJ82bmDWnvUS9T1mYyeQPTw0
# smuY+S+g022Fxi67xYxS+2Use5Y6VTZfD2CLtEkvLs5dleQQ0XmgCWHk7PqiTRn2
# DQqk/Zk4ViKfBYo3hPYDT2r8ETuJ4MbTgr02Hwc95dWmNvwSstxBX+8v8A02xrsk
# k74RU3Fq0P3RbgkDMqH9p7CcwdvROevn1lGEWPajqv+3kV1kit4qt9wKQtJaBvat
# FQw2RgOr3XMFY5tz3N8QCAi2KpVBzxBv0LmDg6uZheRzvydtxusWlTCGPdgT7Q1L
# 3PAkkyBHg4lgRjz4BplGdSzQXvQvVM95OXZUItb5+I685m5q//oY/jqae/YtlTth
# 3iauAB/cNM1L+N0Cy9E4UPSf7bnUi7tzFnHvedSHWQvaP4ElQ77r3K0Jjid5jCBE
# eY2lchJkS6+3h3k=
# SIG # End signature block
