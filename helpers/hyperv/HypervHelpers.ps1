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
