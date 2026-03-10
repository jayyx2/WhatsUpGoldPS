function Connect-HypervHost {
    <#
    .SYNOPSIS
        Creates a CIM session to a remote Hyper-V host.
    .DESCRIPTION
        Establishes a CIM session using WSMan (default) or DCOM for older hosts.
        Returns a CIMSession object used by all other helper functions.
    .PARAMETER ComputerName
        The hostname or IP of the Hyper-V host.
    .PARAMETER Credential
        PSCredential for authentication.
    .PARAMETER UseDCOM
        Use DCOM instead of WSMan (for older hosts without WinRM).
    .EXAMPLE
        $cred = Get-Credential
        $session = Connect-HypervHost -ComputerName "hyperv01.lab.local" -Credential $cred
        Creates a CIM session to the specified Hyper-V host using WSMan.
    .EXAMPLE
        $session = Connect-HypervHost -ComputerName "hyperv01" -Credential $cred -UseDCOM
        Creates a CIM session using DCOM for compatibility with older hosts.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [switch]$UseDCOM
    )

    $sessionOption = if ($UseDCOM) {
        New-CimSessionOption -Protocol Dcom
    } else {
        New-CimSessionOption -Protocol Wsman
    }

    try {
        $session = New-CimSession -ComputerName $ComputerName -Credential $Credential -SessionOption $sessionOption -ErrorAction Stop
        Write-Verbose "Connected to Hyper-V host: $ComputerName"
        return $session
    }
    catch {
        throw "Failed to connect to $ComputerName : $($_.Exception.Message)"
    }
}

function Get-HypervHostDetail {
    <#
    .SYNOPSIS
        Gathers detailed information about a Hyper-V host.
    .PARAMETER CimSession
        An active CIM session to the Hyper-V host.
    .EXAMPLE
        $session = Connect-HypervHost -ComputerName "hyperv01" -Credential $cred
        Get-HypervHostDetail -CimSession $session
        Returns OS, CPU, RAM, and uptime details for the Hyper-V host.
    .EXAMPLE
        $session = Connect-HypervHost -ComputerName "hyperv01" -Credential $cred
        $hostInfo = Get-HypervHostDetail -CimSession $session
        $hostInfo.IPAddress
        Retrieves and displays the primary IP address of the Hyper-V host.
    #>
    param(
        [Parameter(Mandatory)][Microsoft.Management.Infrastructure.CimSession]$CimSession
    )

    $computerName = $CimSession.ComputerName

    # OS info
    $os = Get-CimInstance -CimSession $CimSession -ClassName Win32_OperatingSystem
    # Computer system
    $cs = Get-CimInstance -CimSession $CimSession -ClassName Win32_ComputerSystem
    # Processor
    $cpu = Get-CimInstance -CimSession $CimSession -ClassName Win32_Processor | Select-Object -First 1

    # Get IP from active network adapters
    try {
        $netConfigs = Get-CimInstance -CimSession $CimSession -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True"
        $ip = $netConfigs |
            ForEach-Object { $_.IPAddress } |
            Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' } |
            Select-Object -First 1
        if (-not $ip) { $ip = "N/A" }
    }
    catch {
        $ip = "N/A"
    }

    # CPU count
    $cpuCount = @(Get-CimInstance -CimSession $CimSession -ClassName Win32_Processor).Count

    [PSCustomObject]@{
        Type             = "Hyper-V Host"
        HostName         = $computerName
        IPAddress        = $ip
        OSName           = "$($os.Caption)"
        OSVersion        = "$($os.Version)"
        OSBuild          = "$($os.BuildNumber)"
        Manufacturer     = "$($cs.Manufacturer)"
        Model            = "$($cs.Model)"
        Domain           = "$($cs.Domain)"
        CPUModel         = "$($cpu.Name)"
        CPUSockets       = "$cpuCount"
        CPUCores         = "$($cpu.NumberOfCores)"
        CPULogical       = "$($cpu.NumberOfLogicalProcessors)"
        RAM_TotalGB      = "$([math]::Round($cs.TotalPhysicalMemory / 1GB, 2))"
        RAM_FreeGB       = "$([math]::Round($os.FreePhysicalMemory / 1MB, 2))"
        Uptime           = "$([math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)) hours"
        Status           = if ($os.Status -eq "OK") { "running" } else { "$($os.Status)" }
    }
}

function Get-HypervVMs {
    <#
    .SYNOPSIS
        Returns a list of VMs on the Hyper-V host.
    .PARAMETER CimSession
        An active CIM session to the Hyper-V host.
    .EXAMPLE
        $session = Connect-HypervHost -ComputerName "hyperv01" -Credential $cred
        $vms = Get-HypervVMs -CimSession $session
        Returns all VMs on the Hyper-V host.
    .EXAMPLE
        Get-HypervVMs -CimSession $session | Where-Object { $_.State -eq "Running" }
        Returns only running VMs on the host.
    #>
    param(
        [Parameter(Mandatory)][Microsoft.Management.Infrastructure.CimSession]$CimSession
    )

    Get-VM -CimSession $CimSession
}

function Get-HypervVMDetail {
    <#
    .SYNOPSIS
        Gathers detailed information about a single Hyper-V VM.
    .PARAMETER CimSession
        An active CIM session to the Hyper-V host.
    .PARAMETER VM
        A VM object returned by Get-VM.
    .EXAMPLE
        $session = Connect-HypervHost -ComputerName "hyperv01" -Credential $cred
        $vms = Get-HypervVMs -CimSession $session
        Get-HypervVMDetail -CimSession $session -VM $vms[0]
        Returns detailed information (IP, CPU, memory, disks, NICs) for the first VM.
    .EXAMPLE
        Get-HypervVMs -CimSession $session | ForEach-Object { Get-HypervVMDetail -CimSession $session -VM $_ }
        Returns detailed information for every VM on the host.
    #>
    param(
        [Parameter(Mandatory)][Microsoft.Management.Infrastructure.CimSession]$CimSession,
        [Parameter(Mandatory)]$VM
    )

    $hostName = $CimSession.ComputerName

    # Network adapters and IP
    $nics = Get-VMNetworkAdapter -CimSession $CimSession -VM $VM -ErrorAction SilentlyContinue
    $ip = $nics |
        ForEach-Object { $_.IPAddresses } |
        Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' } |
        Select-Object -First 1
    if (-not $ip) { $ip = "N/A" }

    # VHDs
    $vhds = Get-VMHardDiskDrive -CimSession $CimSession -VM $VM -ErrorAction SilentlyContinue
    $vhdCount = @($vhds).Count
    $totalDiskGB = 0
    foreach ($vhd in $vhds) {
        try {
            $vhdInfo = Get-VHD -CimSession $CimSession -Path $vhd.Path -ErrorAction SilentlyContinue
            if ($vhdInfo) { $totalDiskGB += $vhdInfo.Size / 1GB }
        }
        catch { }
    }

    # Memory
    $memAssigned = if ($VM.MemoryAssigned) { [math]::Round($VM.MemoryAssigned / 1GB, 2) } else { 0 }
    $memStartup  = if ($VM.MemoryStartup)  { [math]::Round($VM.MemoryStartup / 1GB, 2) }  else { 0 }
    $memDynamic  = $VM.DynamicMemoryEnabled

    # Snapshots / checkpoints
    $snapshots = @(Get-VMSnapshot -CimSession $CimSession -VM $VM -ErrorAction SilentlyContinue)

    # Integration services
    $intSvc = Get-VMIntegrationService -CimSession $CimSession -VM $VM -ErrorAction SilentlyContinue
    $heartbeat = ($intSvc | Where-Object { $_.Name -eq "Heartbeat" }).PrimaryStatusDescription

    [PSCustomObject]@{
        Name              = "$($VM.Name)"
        VMId              = "$($VM.VMId)"
        Host              = $hostName
        State             = "$($VM.State)"
        Status            = "$($VM.Status)"
        IPAddress         = $ip
        Generation        = "$($VM.Generation)"
        Version           = "$($VM.Version)"
        Uptime            = "$($VM.Uptime)"
        CPUCount          = "$($VM.ProcessorCount)"
        CPUUsagePct       = "$($VM.CPUUsage)%"
        MemoryAssignedGB  = "$memAssigned"
        MemoryStartupGB   = "$memStartup"
        DynamicMemory     = "$memDynamic"
        DiskCount         = "$vhdCount"
        DiskTotalGB       = "$([math]::Round($totalDiskGB, 2))"
        NicCount          = "$(@($nics).Count)"
        SwitchNames       = ($nics | ForEach-Object { $_.SwitchName } | Select-Object -Unique) -join ", "
        VLanIds           = ($nics | ForEach-Object { $_.VlanSetting.AccessVlanId } | Where-Object { $_ } | Select-Object -Unique) -join ", "
        SnapshotCount     = "$($snapshots.Count)"
        Heartbeat         = if ($heartbeat) { "$heartbeat" } else { "N/A" }
        ReplicationState  = "$($VM.ReplicationState)"
        Notes             = if ($VM.Notes) { "$($VM.Notes.Substring(0, [math]::Min(200, $VM.Notes.Length)))" } else { "" }
    }
}

function Get-HypervDashboard {
    <#
    .SYNOPSIS
        Builds a flat dashboard view combining Hyper-V hosts and their VMs.
    .DESCRIPTION
        Connects to one or more Hyper-V hosts, gathers host details and VM
        details, then returns a unified collection of objects suitable for
        rendering in an interactive Bootstrap Table dashboard. Each row
        represents a VM enriched with its parent host context including
        host CPU model, RAM, OS, and IP address.
    .PARAMETER CimSessions
        One or more active CIM sessions to Hyper-V hosts. Create sessions
        using Connect-HypervHost.
    .EXAMPLE
        $session = Connect-HypervHost -ComputerName "hyperv01" -Credential $cred
        Get-HypervDashboard -CimSessions $session

        Returns a flat dashboard view of all VMs across the specified host.
    .EXAMPLE
        $sessions = @("hyperv01","hyperv02") | ForEach-Object { Connect-HypervHost -ComputerName $_ -Credential $cred }
        $dashboard = Get-HypervDashboard -CimSessions $sessions

        Returns a unified view across multiple Hyper-V hosts.
    .EXAMPLE
        $cred = Get-Credential
        $sessions = @("hyperv01","hyperv02") | ForEach-Object { Connect-HypervHost -ComputerName $_ -Credential $cred }
        $data = Get-HypervDashboard -CimSessions $sessions
        Export-HypervDashboardHtml -DashboardData $data -OutputPath "C:\Reports\hyperv.html"
        Start-Process "C:\Reports\hyperv.html"

        End-to-end: connect to hosts, gather dashboard data, export HTML, and open in browser.
    .OUTPUTS
        PSCustomObject[]
        Each object contains VM details enriched with host context: VMName, State, Status,
        IPAddress, Host, HostIP, HostOS, HostCPUModel, HostRAM_TotalGB, HostRAM_FreeGB,
        Generation, CPUCount, CPUUsagePct, MemoryAssignedGB, MemoryStartupGB, DynamicMemory,
        DiskCount, DiskTotalGB, NicCount, SwitchNames, VLanIds, SnapshotCount, Heartbeat,
        ReplicationState, Uptime, Notes.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+, Hyper-V PowerShell module, CIM sessions to target hosts.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    param(
        [Parameter(Mandatory)]$CimSessions
    )

    if ($CimSessions -isnot [System.Collections.IEnumerable] -or $CimSessions -is [string]) {
        $CimSessions = @($CimSessions)
    }

    $results = @()

    foreach ($session in $CimSessions) {
        $hostDetail = Get-HypervHostDetail -CimSession $session
        $vms = Get-HypervVMs -CimSession $session

        foreach ($vm in $vms) {
            $vmDetail = Get-HypervVMDetail -CimSession $session -VM $vm

            $results += [PSCustomObject]@{
                VMName            = $vmDetail.Name
                State             = $vmDetail.State
                Status            = $vmDetail.Status
                IPAddress         = $vmDetail.IPAddress
                Host              = $hostDetail.HostName
                HostIP            = $hostDetail.IPAddress
                HostOS            = $hostDetail.OSName
                HostCPUModel      = $hostDetail.CPUModel
                HostRAM_TotalGB   = $hostDetail.RAM_TotalGB
                HostRAM_FreeGB    = $hostDetail.RAM_FreeGB
                Generation        = $vmDetail.Generation
                CPUCount          = $vmDetail.CPUCount
                CPUUsagePct       = $vmDetail.CPUUsagePct
                MemoryAssignedGB  = $vmDetail.MemoryAssignedGB
                MemoryStartupGB   = $vmDetail.MemoryStartupGB
                DynamicMemory     = $vmDetail.DynamicMemory
                DiskCount         = $vmDetail.DiskCount
                DiskTotalGB       = $vmDetail.DiskTotalGB
                NicCount          = $vmDetail.NicCount
                SwitchNames       = $vmDetail.SwitchNames
                VLanIds           = $vmDetail.VLanIds
                SnapshotCount     = $vmDetail.SnapshotCount
                Heartbeat         = $vmDetail.Heartbeat
                ReplicationState  = $vmDetail.ReplicationState
                Uptime            = "$($vmDetail.Uptime)"
                Notes             = $vmDetail.Notes
            }
        }
    }

    return $results
}

function Export-HypervDashboardHtml {
    <#
    .SYNOPSIS
        Renders Hyper-V dashboard data into a self-contained HTML file.
    .DESCRIPTION
        Takes the output of Get-HypervDashboard and generates a Bootstrap-based
        HTML report with sortable, searchable, and exportable tables. The report
        uses Bootstrap 5 and Bootstrap-Table for interactive filtering, sorting,
        column toggling, and CSV/JSON export.
    .PARAMETER DashboardData
        Array of PSCustomObject from Get-HypervDashboard containing VM and host details.
    .PARAMETER OutputPath
        File path for the output HTML file. Parent directory must exist.
    .PARAMETER ReportTitle
        Title shown in the report header. Defaults to "Hyper-V Dashboard".
    .PARAMETER TemplatePath
        Optional path to a custom HTML template. If omitted, uses the
        Hyperv-Dashboard-Template.html in the same directory as this script.
    .EXAMPLE
        $data = Get-HypervDashboard -CimSessions $sessions
        Export-HypervDashboardHtml -DashboardData $data -OutputPath "C:\Reports\hyperv.html"

        Exports the dashboard data to an HTML file using the default template.
    .EXAMPLE
        Export-HypervDashboardHtml -DashboardData $data -OutputPath "$env:TEMP\hyperv.html" -ReportTitle "Production Hyper-V"

        Exports with a custom report title.
    .EXAMPLE
        $cred = Get-Credential
        $sessions = @("hv01","hv02") | ForEach-Object { Connect-HypervHost -ComputerName $_ -Credential $cred }
        $data = Get-HypervDashboard -CimSessions $sessions
        Export-HypervDashboardHtml -DashboardData $data -OutputPath "C:\Reports\hyperv.html"
        Start-Process "C:\Reports\hyperv.html"

        Full pipeline: connect, gather, export, and open the report in a browser.
    .OUTPUTS
        System.Void
        Writes an HTML file to the path specified by OutputPath.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+, Hyperv-Dashboard-Template.html in the script directory.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = "Hyper-V Dashboard",
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot "Hyperv-Dashboard-Template.html"
    }

    if (-not (Test-Path $TemplatePath)) {
        throw "HTML template not found at $TemplatePath"
    }

    $firstObj = $DashboardData | Select-Object -First 1
    $columns = @()
    foreach ($prop in $firstObj.PSObject.Properties) {
        $col = @{
            field      = $prop.Name
            title      = ($prop.Name -creplace '([A-Z])', ' $1').Trim()
            sortable   = $true
            searchable = $true
        }
        if ($prop.Name -eq 'State') {
            $col.formatter = 'formatState'
        }
        if ($prop.Name -eq 'Heartbeat') {
            $col.formatter = 'formatHeartbeat'
        }
        $columns += $col
    }

    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
    $dataJson    = $DashboardData | ConvertTo-Json -Depth 5 -Compress

    $tableConfig = @"
        columns: $columnsJson,
        data: $dataJson
"@

    $html = Get-Content -Path $TemplatePath -Raw
    $html = $html -replace 'replaceThisHere', $tableConfig
    $html = $html -replace 'ReplaceYourReportNameHere', $ReportTitle
    $html = $html -replace 'ReplaceUpdateTimeHere', (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    Set-Content -Path $OutputPath -Value $html -Encoding UTF8
    Write-Verbose "Hyper-V Dashboard HTML written to $OutputPath"
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDQNU7EdzV2djTO
# h6qcp1ga0GlKUr6YVk6aKQ6KEGKKIKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgquFdO5KjyWRym39igUOTJG3jQhgHVL9L
# dQAhpusFkRgwDQYJKoZIhvcNAQEBBQAEggIAHd1KESTbM/AiiEf8R47e0h+CRBsd
# LCWnB2M0LEWbmBpu6Cql3UGLcRuV/W7Q5T2IphaXSA3s0I4jsKBbP33LbMi6+Haf
# 7+7CE4+voQbXc68ES0/lHByjPzEBht3oFE3SoP25MwchmC39DudK7S8k1nKoFw1y
# xiJF5yXB8p7hI29LCyA0AiJXM7FVjGmFCMaLK7xFtgahK34wTXaNxu0nU0+Svuf3
# wUztof8i914psd2pdi0lCMQXes5mgx4IlT+R1W91brCBi58QH8FujcgCnQxNog1q
# pMQ+Kzs+vkF7jZbsk788mYs5YuT5rettL+Q+JbzTxjxtMvkV34WOGxiP6ZihP5oI
# f8VtYMmfnKYMsUnGiFA/4FggSzMbDU+ezDNJZZnaUuV2CL2h3bdMlsqI5ni0y73d
# oqN8uZzXaOgfKwDTXvHNUOa+uZAQbF7Otxg0VmgCNMkna5TBNlrpobXD+8hR46GG
# T0SdcIIUm4gqZiOKJHx/PiHFPRM8Fg3eKwJa0aBvvJxd7rmtvaBsnXapemxb/Xsq
# XsNlCVch4K6cPKPFo3egt4V5K89eyouDfUEVTJuQrtK0o6uGMT+PhVTstueUi+jW
# WLFlwNyuKUeS4/xFl6a9Yji9z5ct6LN0Rd3RDjXWm4wDfrKo3ESFXBruPqe7s0BD
# 9tjbZWhiowWJ2LA=
# SIG # End signature block
