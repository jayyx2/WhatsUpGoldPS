<#
.SYNOPSIS
    NVIDIA GPU discovery, dashboards, and WUG onboarding (GPU Health active monitor, per-GPU SSH performance monitors, GPU inventory attributes).

.DESCRIPTION
    SSHes to Linux hosts, runs nvidia-smi to discover GPUs, and optionally:
      - Creates a WUG SSH active monitor for GPU status & availability ('GPU Health')
      - Creates WUG SSH performance monitors: per-GPU core metrics (GPU0..GPU3
        utilization, memory utilization, VRAM used %, temperature, power draw)
        plus host-wide totals/averages for the remaining metrics
      - Writes GPU inventory to WUG device attributes (<AttributePrefix>.GPUCount,
        .DriverVersion, .CudaVersion, .GPU0.Model, .GPU0.Serial, ...) and sets the
        device OS role from uname (Linux / Unix) when WUG has none
      - Generates an HTML dashboard of GPU inventory
      - Exports GPU data to JSON/CSV

    All monitors are shared library monitors with no host-specific values, so they
    are reused on every GPU host; each host is assigned only the GPU indexes it has.
    A host where SSH works but nvidia-smi fails is still added with GPU Health only,
    which shows down with the nvidia-smi error.

    Actions:
      PushToWUG         Validate every monitor command over SSH, then create the
                        WUG SSH credential/device (if missing), shared library
                        monitors, and device assignments for commands that passed.
      ExportJSON        Export GPU inventory to JSON.
      ExportCSV         Export GPU inventory to CSV.
      ShowTable         Display GPU info in console.
      Dashboard         Generate HTML GPU dashboard.
      DashboardAndPush  Dashboard + create WUG monitors.
      Validate          Run every monitor command over SSH and report results (no WUG changes).
      None              Discover only (test connectivity).

    N/A handling:
      nvidia-smi prints 'N/A' / '[N/A]' / '[Not Supported]' for fields a GPU or
      driver does not expose. Those are shown as 'N/A (reported by nvidia-smi)'
      in the inventory and as status 'NotReported' during validation, which is
      different from 'Unknown (not returned)' (we never got a value) and from
      'NvidiaSmiError' (nvidia-smi itself failed). Monitor commands skip N/A
      GPUs instead of counting them as 0.

    awk portability:
      Monitor commands use only POSIX awk features and LC_ALL=C, and are tested
      with gawk, mawk, nawk and busybox awk. Validation reports which awk each
      host uses.

.PARAMETER Target
    One or more Linux host IPs or hostnames with NVIDIA GPUs.

.PARAMETER Action
    What to do after discovery.

.PARAMETER SshUsername
    SSH username for connecting to targets.

.PARAMETER SshPassword
    SSH password (plaintext). Use -SshSecurePassword for interactive input.

.PARAMETER SshSecurePassword
    SSH password as SecureString.

.PARAMETER SshKeyFile
    Path to SSH private key file for key-based auth.

.PARAMETER SshPort
    SSH port. Default: 22.

.PARAMETER VaultName
    DPAPI vault bundle name for SSH credentials. Default: NvidiaSmi.Ssh.

.PARAMETER WUGServer
    WhatsUp Gold server for PushToWUG actions.

.PARAMETER WUGCredential
    PSCredential for WUG authentication.

.PARAMETER NamePrefix
    Prefix for WUG monitor names. Default: 'GPU' (e.g. 'GPU0 Utilization %', 'GPU Memory Used MB', 'GPU Health').

.PARAMETER MaxGpuCount
    Number of per-GPU library monitor sets to support (GPU0 .. GPU<n-1>). Default: 4.
    A host with more GPUs is still covered by the host-wide monitors and GPU Health.

.PARAMETER AttributePrefix
    Prefix for the WUG device attributes written by PushToWUG. Default: 'NVIDIA'
    (e.g. 'NVIDIA.GPUCount', 'NVIDIA.GPU0.Serial'). Only changed values are written.

.PARAMETER SkipDeviceAttributes
    Do not write device attributes or set the OS role during PushToWUG.

.PARAMETER PollingIntervalMinutes
    Polling interval for WUG performance monitors. Default: 5.

.PARAMETER OutputPath
    Output directory for exports and dashboards.

.PARAMETER NonInteractive
    Suppress prompts. Requires direct parameters or saved vault credentials.

.EXAMPLE
    .\Setup-NvidiaSmi-Discovery.ps1 -Target '192.168.1.100' -SshUsername 'admin' -SshPassword 'pass' -Action Dashboard

.EXAMPLE
    .\Setup-NvidiaSmi-Discovery.ps1 -Target '192.168.1.100','192.168.1.101' -Action PushToWUG -NonInteractive

.EXAMPLE
    .\Setup-NvidiaSmi-Discovery.ps1 -Target '192.168.1.100' -Action Validate -NonInteractive
    # Shows each monitor's live value or why it would be skipped, without touching WUG.

.NOTES
    Author  : jason@wug.ninja
    Requires: PowerShell 5.1+, WhatsUpGoldPS.Ssh module, nvidia-smi on target hosts
    Encoding: UTF-8 with BOM
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Target,

    [ValidateSet('PushToWUG', 'ExportJSON', 'ExportCSV', 'ShowTable', 'Dashboard', 'DashboardAndPush', 'Validate', 'None')]
    [string]$Action,

    [string]$SshUsername,

    [string]$SshPassword,

    [System.Security.SecureString]$SshSecurePassword,

    [string]$SshKeyFile,

    [int]$SshPort = 22,

    [int]$TimeoutSeconds = 30,

    [string]$VaultName = 'NvidiaSmi.Ssh',

    [string]$WUGServer,

    [PSCredential]$WUGCredential,

    [string]$NamePrefix = 'GPU',

    [ValidateRange(1, 16)]
    [int]$MaxGpuCount = 4,

    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$AttributePrefix = 'NVIDIA',

    [switch]$SkipDeviceAttributes,

    [ValidateRange(1, 1440)]
    [int]$PollingIntervalMinutes = 5,

    [string]$OutputPath,

    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ============================================================================
# Dot-source dependencies
# ============================================================================
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent

. (Join-Path $scriptDir 'DiscoveryHelpers.ps1')

# Load SSH module
$sshModulePath = Join-Path (Split-Path $scriptDir -Parent) 'ssh\WhatsUpGoldPS.Ssh\WhatsUpGoldPS.Ssh.psd1'
if (-not (Get-Module -Name 'WhatsUpGoldPS.Ssh')) {
    if (Test-Path $sshModulePath) {
        Import-Module $sshModulePath -Force -ErrorAction Stop
        Write-Verbose "[NvidiaSmi] Loaded WhatsUpGoldPS.Ssh module"
    }
    else {
        throw "WhatsUpGoldPS.Ssh module not found at: $sshModulePath"
    }
}
Import-SshNet | Out-Null

# ============================================================================
# GPU monitor definitions
# ============================================================================
# Each metric is one nvidia-smi field. Commands are generated by
# New-NvidiaSmiMonitorCommand so every monitor shares the same portable awk
# program and N/A handling. Monitor names carry no host-specific data, so the
# same library monitors are reused on every GPU host.
#
# Per-GPU metrics get one library monitor per GPU index (GPU0 .. GPU<MaxGpuCount-1>),
# queried with 'nvidia-smi -i <index>'; a host is assigned only the indexes it has.
$script:GpuPerGpuMetricDefs = @(
    @{ Name = 'Utilization %';        Field = 'utilization.gpu';          Aggregate = 'Avg';   Unit = '%'; Description = 'GPU {0} core utilization percent.' }
    @{ Name = 'Memory Utilization %'; Field = 'utilization.memory';       Aggregate = 'Avg';   Unit = '%'; Description = 'GPU {0} memory controller utilization percent.' }
    @{ Name = 'VRAM Used %';          Field = 'memory.used,memory.total'; Aggregate = 'Ratio'; Unit = '%'; Description = 'GPU {0} used VRAM percent.' }
    @{ Name = 'Temperature C';        Field = 'temperature.gpu';          Aggregate = 'Max';   Unit = 'C'; Description = 'GPU {0} core temperature in Celsius.' }
    @{ Name = 'Power Draw W';         Field = 'power.draw';               Aggregate = 'Sum';   Unit = 'W'; Description = 'GPU {0} power draw in watts.' }
)
# Host-wide metrics aggregate across every GPU on the host.
$script:GpuHostMetricDefs = @(
    @{ Name = 'Memory Used MB';        Field = 'memory.used';         Aggregate = 'Sum'; Unit = 'MB';  Description = 'Total GPU memory used in MiB across all GPUs.' }
    @{ Name = 'Memory Free MB';        Field = 'memory.free';         Aggregate = 'Sum'; Unit = 'MB';  Description = 'Total GPU memory free in MiB across all GPUs.' }
    @{ Name = 'Memory Total MB';       Field = 'memory.total';        Aggregate = 'Sum'; Unit = 'MB';  Description = 'Total GPU memory in MiB across all GPUs.' }
    @{ Name = 'Power Limit W';         Field = 'power.limit';         Aggregate = 'Sum'; Unit = 'W';   Description = 'Total configured GPU power limit in watts across all GPUs.' }
    @{ Name = 'Core Clock MHz';        Field = 'clocks.gr';           Aggregate = 'Avg'; Unit = 'MHz'; Description = 'Average graphics/core clock in MHz across all GPUs.' }
    @{ Name = 'Memory Clock MHz';      Field = 'clocks.mem';          Aggregate = 'Avg'; Unit = 'MHz'; Description = 'Average memory clock in MHz across all GPUs.' }
    @{ Name = 'Fan Speed %';           Field = 'fan.speed';           Aggregate = 'Avg'; Unit = '%';   Description = 'Average fan speed percent. GPUs that nvidia-smi reports as N/A (e.g. passively cooled) are excluded, not counted as 0.' }
    @{ Name = 'Encoder Utilization %'; Field = 'utilization.encoder'; Aggregate = 'Avg'; Unit = '%';   Description = 'Average video encoder utilization percent across all GPUs.' }
    @{ Name = 'Decoder Utilization %'; Field = 'utilization.decoder'; Aggregate = 'Avg'; Unit = '%';   Description = 'Average video decoder utilization percent across all GPUs.' }
)

# GPU status & availability (SSH active monitor). Prints GPU_HEALTH_OK only when
# nvidia-smi initializes, no GPU reports lost/ERR!/requires reset, and nvidia-smi
# sees at least as many GPUs as the PCI bus has NVIDIA display/3D controllers
# (class 0x0300/0x0302, read from sysfs so lspci is not required). Otherwise it
# prints GPU_HEALTH_FAIL plus the reason. Comparing against PCI instead of a fixed
# count keeps the monitor reusable on any host. POSIX sh + awk (bash and dash tested).
$script:GpuHealthCommand = @'
p=0; for d in /sys/bus/pci/devices/*; do v=$(cat "$d/vendor" 2>/dev/null); c=$(cat "$d/class" 2>/dev/null); case "$v:$c" in 0x10de:0x0300*|0x10de:0x0302*) p=$((p+1));; esac; done; o=$(LC_ALL=C nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>&1); r=$?; n=$(printf '%s\n' "$o" | LC_ALL=C awk '/^[0-9]+, /{n++} END{print n+0}'); if [ $r -ne 0 ]; then echo "GPU_HEALTH_FAIL nvidia-smi exit $r: $(printf '%s' "$o" | head -n 1)"; elif printf '%s' "$o" | grep -Eqi 'lost|ERR!|requires reset|Unknown Error|Unable to determine'; then echo "GPU_HEALTH_FAIL $(printf '%s' "$o" | grep -Ei 'lost|ERR!|requires reset|Unknown Error|Unable to determine' | head -n 1)"; elif [ "$n" -eq 0 ]; then echo "GPU_HEALTH_FAIL no GPUs reported by nvidia-smi (PCI shows $p)"; elif [ "$n" -lt "$p" ]; then echo "GPU_HEALTH_FAIL nvidia-smi sees $n of $p NVIDIA GPU(s) on PCI"; else echo "GPU_HEALTH_OK $n of $p GPU(s)"; fi
'@.Trim()
$script:GpuHealthDef = @{
    Kind           = 'Active'
    MonitorName    = "$NamePrefix Health"
    Command        = $script:GpuHealthCommand
    ExpectedOutput = 'GPU_HEALTH_OK'
    Description    = 'NVIDIA GPU status and availability over SSH: up when nvidia-smi initializes, no GPU is lost/ERR!/requires reset, and nvidia-smi sees every NVIDIA GPU on the PCI bus. The down reason is in the monitor output.'
}

# nvidia-smi prints these instead of a number when a GPU/driver does not expose a field.
$script:NvidiaSmiNotReportedPattern = '^\[?(N/A|Not Supported)\]?$'

function New-NvidiaSmiMonitorCommand {
    <#
    .SYNOPSIS
        Builds the SSH command for one GPU metric.
    .DESCRIPTION
        The awk program sticks to POSIX features (ERE match, printf, exit in END)
        so it behaves the same under gawk, mawk, busybox awk and BSD awk. Rows
        whose value is not numeric (N/A, [N/A], [Not Supported]) are skipped
        instead of being coerced to 0. When no GPU returns a number the command
        prints nothing and exits 3, so WUG shows a failed poll rather than a fake 0.
        LC_ALL=C keeps the decimal separator a '.' regardless of host locale.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Field,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Avg', 'Sum', 'Max', 'Ratio')]
        [string]$Aggregate,

        # When set, query only this GPU (nvidia-smi -i). A missing index makes nvidia-smi
        # print nothing to stdout, so the command exits 3 and WUG shows a failed poll.
        [Nullable[int]]$GpuIndex
    )

    # No {n} intervals: older mawk builds do not support them.
    $num = '/^-?[0-9]+(\.[0-9]+)?$/'
    $none = 'exit 3'
    $body = switch ($Aggregate) {
        'Avg'   { '$1 ~ ' + $num + ' { s += $1; n++ } END { if (n > 0) printf "%.2f\n", s / n; else ' + $none + ' }' }
        'Sum'   { '$1 ~ ' + $num + ' { s += $1; n++ } END { if (n > 0) printf "%.2f\n", s; else ' + $none + ' }' }
        'Max'   { '$1 ~ ' + $num + ' { if (n == 0 || $1 > m) m = $1; n++ } END { if (n > 0) printf "%.2f\n", m; else ' + $none + ' }' }
        'Ratio' { '$1 ~ ' + $num + ' && $2 ~ ' + $num + ' { u += $1; t += $2 } END { if (t > 0) printf "%.2f\n", (u / t) * 100; else ' + $none + ' }' }
    }

    $select = if ($null -ne $GpuIndex) { "-i $GpuIndex " } else { '' }
    return "LC_ALL=C nvidia-smi $select--query-gpu=$Field --format=csv,noheader,nounits | LC_ALL=C awk -F', *' '$body'"
}

$gpuMonitorList = [System.Collections.Generic.List[hashtable]]::new()
for ($gpuIdx = 0; $gpuIdx -lt $MaxGpuCount; $gpuIdx++) {
    foreach ($metric in $script:GpuPerGpuMetricDefs) {
        $gpuMonitorList.Add(@{
            Kind        = 'Performance'
            MonitorName = "$NamePrefix$gpuIdx $($metric.Name)"
            Field       = $metric.Field
            GpuIndex    = $gpuIdx
            Unit        = $metric.Unit
            Description = ($metric.Description -f $gpuIdx) + " (nvidia-smi index $gpuIdx)"
            Command     = New-NvidiaSmiMonitorCommand -Field $metric.Field -Aggregate $metric.Aggregate -GpuIndex $gpuIdx
        })
    }
}
foreach ($metric in $script:GpuHostMetricDefs) {
    $gpuMonitorList.Add(@{
        Kind        = 'Performance'
        MonitorName = "$NamePrefix $($metric.Name)"
        Field       = $metric.Field
        GpuIndex    = $null
        Unit        = $metric.Unit
        Description = $metric.Description
        Command     = New-NvidiaSmiMonitorCommand -Field $metric.Field -Aggregate $metric.Aggregate
    })
}
$script:GpuMonitorDefs = @($gpuMonitorList)

function ConvertTo-NvidiaSmiDisplayValue {
    <#
    .SYNOPSIS
        Makes it obvious when a value is N/A because nvidia-smi said so, versus missing because we never got it.
    #>
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return 'Unknown (not returned)' }
    $v = $Value.Trim()
    if ($v -eq '') { return 'Unknown (not returned)' }
    if ($v -match $script:NvidiaSmiNotReportedPattern) { return 'N/A (reported by nvidia-smi)' }
    return $v
}

# ============================================================================
# Credential resolution (vault-backed, same pattern as CUCM/WLC)
# ============================================================================
function Get-NvidiaSmiResolvedSshSettings {
    [CmdletBinding()]
    param()

    $saved = $null
    if ($VaultName) {
        try {
            $saved = Get-DiscoveryCredential -Name $VaultName -ErrorAction SilentlyContinue
        }
        catch { $saved = $null }
    }

    if ($saved) {
        $savedUser = if ($saved.ContainsKey('Username')) { [string]$saved['Username'] } else { '' }
        Write-Host "  Vault: $VaultName" -ForegroundColor DarkGray
        Write-Host "  Found: SSH credentials for user '$savedUser'" -ForegroundColor Green

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

    # Resolve username
    $resolvedUsername = $SshUsername
    if ([string]::IsNullOrWhiteSpace($resolvedUsername) -and $saved -and $saved.ContainsKey('Username')) {
        $resolvedUsername = [string]$saved['Username']
    }
    if ([string]::IsNullOrWhiteSpace($resolvedUsername)) {
        if ($NonInteractive) { throw 'SSH username is required for non-interactive discovery.' }
        $resolvedUsername = Read-Host -Prompt 'SSH username'
    }

    # Resolve password
    $resolvedPassword = $SshPassword
    if ([string]::IsNullOrWhiteSpace($resolvedPassword) -and $SshSecurePassword) {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SshSecurePassword)
        try { $resolvedPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if ([string]::IsNullOrWhiteSpace($resolvedPassword) -and $saved -and $saved.ContainsKey('Password')) {
        $resolvedPassword = [string]$saved['Password']
    }

    # Resolve key file
    $resolvedKeyFile = $SshKeyFile
    if ([string]::IsNullOrWhiteSpace($resolvedKeyFile) -and $saved -and $saved.ContainsKey('KeyFile')) {
        $resolvedKeyFile = [string]$saved['KeyFile']
    }

    # Prompt for password if no auth method available
    if ([string]::IsNullOrWhiteSpace($resolvedPassword) -and [string]::IsNullOrWhiteSpace($resolvedKeyFile)) {
        if ($NonInteractive) { throw 'SSH password or key file is required for non-interactive discovery.' }
        $secPwd = Read-Host -AsSecureString -Prompt 'SSH password'
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPwd)
        try { $resolvedPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    # Save to vault
    if (-not $NonInteractive -and $VaultName) {
        $fields = [ordered]@{
            Username = ConvertTo-SecureString -String $resolvedUsername -AsPlainText -Force
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedPassword)) {
            $fields['Password'] = ConvertTo-SecureString -String $resolvedPassword -AsPlainText -Force
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedKeyFile)) {
            $fields['KeyFile'] = ConvertTo-SecureString -String $resolvedKeyFile -AsPlainText -Force
        }
        $fields['Port'] = ConvertTo-SecureString -String ([string]$SshPort) -AsPlainText -Force
        Save-DiscoveryCredential -Name $VaultName -Fields $fields -Description 'NvidiaSmi SSH settings' -Force | Out-Null
    }

    return [ordered]@{
        Username = $resolvedUsername
        Password = $resolvedPassword
        KeyFile  = $resolvedKeyFile
        Port     = $SshPort
        Timeout  = $TimeoutSeconds
    }
}

# ============================================================================
# Discovery: SSH to host, run nvidia-smi, parse GPU info
# ============================================================================
function New-NvidiaSmiSshSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$SshSettings,

        # Authenticate with the password only, the same way WUG will poll.
        [switch]$PasswordOnly
    )

    $splat = @{
        HostName       = $HostName
        Port           = $SshSettings.Port
        Username       = $SshSettings.Username
        TimeoutSeconds = $SshSettings.Timeout
    }
    if ($SshSettings.Password) { $splat['Password'] = $SshSettings.Password }
    if ($SshSettings.KeyFile -and -not $PasswordOnly) { $splat['KeyFile'] = $SshSettings.KeyFile }

    return New-SshSession @splat
}

function Get-NvidiaSmiFailureText {
    param($Result)

    $text = (@($Result.Error, $Result.Output) | Where-Object { $_ }) -join ' '
    $text = ($text -replace '\s+', ' ').Trim()
    if (-not $text) { $text = '(no output)' }
    return $text
}

function Get-NvidiaGpuInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$SshSettings
    )

    $session = New-NvidiaSmiSshSession -HostName $HostName -SshSettings $SshSettings

    try {
        $nameResult = Invoke-SshCommand -Session $session -Command 'LC_ALL=C nvidia-smi --query-gpu=index,name,uuid,memory.total,driver_version --format=csv,noheader,nounits'
        if ($nameResult.ExitCode -ne 0) {
            throw "nvidia-smi exited $($nameResult.ExitCode) on ${HostName}: $(Get-NvidiaSmiFailureText $nameResult)"
        }

        $gpuList = [System.Collections.Generic.List[object]]::new()
        foreach ($line in ($nameResult.Output -split "`n")) {
            $line = $line.Trim()
            if (-not $line) { continue }
            $parts = @($line -split ',\s*')
            $gpuList.Add([PSCustomObject]@{
                Host          = $HostName
                Index         = if ($parts.Count -gt 0) { $parts[0].Trim() } else { '' }
                Name          = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
                UUID          = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
                MemoryTotalMB = if ($parts.Count -gt 3) { ConvertTo-NvidiaSmiDisplayValue $parts[3] } else { 'Unknown (not returned)' }
                DriverVersion = if ($parts.Count -gt 4) { ConvertTo-NvidiaSmiDisplayValue $parts[4] } else { 'Unknown (not returned)' }
            })
        }
        $gpus = @($gpuList)

        # Static details for device attributes. If an older driver rejects one field the
        # whole query fails, so fall back to one field at a time.
        $detailFields = [ordered]@{
            'serial'              = 'Serial'
            'vbios_version'       = 'VBIOS'
            'pci.bus_id'          = 'PciBusId'
            'power.limit'         = 'PowerLimitW'
            'pcie.link.gen.max'   = 'PcieGenMax'
            'pcie.link.width.max' = 'PcieWidthMax'
            'compute_cap'         = 'ComputeCap'
            'ecc.mode.current'    = 'EccMode'
            'persistence_mode'    = 'PersistenceMode'
        }
        $detailKeys = @($detailFields.Keys)
        $detailResult = Invoke-SshCommand -Session $session -Command "LC_ALL=C nvidia-smi --query-gpu=index,$($detailKeys -join ',') --format=csv,noheader,nounits"
        $detailQueries = [System.Collections.Generic.List[object]]::new()
        if ($detailResult.ExitCode -eq 0) {
            $detailQueries.Add([PSCustomObject]@{ Keys = $detailKeys; Result = $detailResult })
        }
        else {
            Write-Verbose "Combined detail query failed on ${HostName}; querying fields one at a time: $(Get-NvidiaSmiFailureText $detailResult)"
            foreach ($k in $detailKeys) {
                $r = Invoke-SshCommand -Session $session -Command "LC_ALL=C nvidia-smi --query-gpu=index,$k --format=csv,noheader,nounits"
                if ($r.ExitCode -eq 0) { $detailQueries.Add([PSCustomObject]@{ Keys = @($k); Result = $r }) }
            }
        }
        foreach ($gpu in $gpus) {
            foreach ($k in $detailKeys) { $gpu | Add-Member -NotePropertyName $detailFields[$k] -NotePropertyValue 'Unknown (field not supported by this driver)' -Force }
        }
        foreach ($q in $detailQueries) {
            $fieldKeys = @($q.Keys)
            foreach ($detailLine in @($q.Result.Output -split "`n")) {
                $parts = @($detailLine.Trim() -split ',\s*')
                if (-not $parts[0]) { continue }
                $gpu = $gpus | Where-Object { $_.Index -eq $parts[0].Trim() } | Select-Object -First 1
                if (-not $gpu) { continue }
                for ($f = 0; $f -lt $fieldKeys.Count; $f++) {
                    $raw = if ($parts.Count -gt ($f + 1)) { $parts[$f + 1] } else { $null }
                    $gpu | Add-Member -NotePropertyName $detailFields[$fieldKeys[$f]] -NotePropertyValue (ConvertTo-NvidiaSmiDisplayValue $raw) -Force
                }
            }
        }

        # Utilization snapshot for the dashboard, matched to the inventory by GPU index.
        $snapFields = @('GpuUtil', 'MemUtil', 'MemUsedMB', 'MemFreeMB', 'TempC', 'PowerW', 'FanPct')
        $utilResult = Invoke-SshCommand -Session $session -Command 'LC_ALL=C nvidia-smi --query-gpu=index,utilization.gpu,utilization.memory,memory.used,memory.free,temperature.gpu,power.draw,fan.speed --format=csv,noheader,nounits'
        if ($utilResult.ExitCode -eq 0) {
            foreach ($utilLine in @($utilResult.Output -split "`n")) {
                $parts = @($utilLine.Trim() -split ',\s*')
                if (-not $parts[0]) { continue }
                $gpu = $gpus | Where-Object { $_.Index -eq $parts[0].Trim() } | Select-Object -First 1
                if (-not $gpu) { continue }
                for ($f = 0; $f -lt $snapFields.Count; $f++) {
                    $raw = if ($parts.Count -gt ($f + 1)) { $parts[$f + 1] } else { $null }
                    $gpu | Add-Member -NotePropertyName $snapFields[$f] -NotePropertyValue (ConvertTo-NvidiaSmiDisplayValue $raw) -Force
                }
            }
        }
        else {
            Write-Warning "Utilization snapshot failed on ${HostName} (exit $($utilResult.ExitCode)): $(Get-NvidiaSmiFailureText $utilResult)"
        }

        return $gpus
    }
    finally {
        Close-SshSession -Session $session
    }
}

function Get-NvidiaSmiHostFacts {
    <#
    .SYNOPSIS
        OS/kernel/CUDA facts for a host. Runs even when nvidia-smi is broken, so a failed host still gets its OS set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$SshSettings
    )

    # POSIX sh + sed only; os-release is sourced in a subshell so it cannot affect the rest.
    $cmd = 'echo "SYSNAME=$(uname -s)"; echo "KERNEL=$(uname -r)"; echo "NODENAME=$(uname -n)"; ' +
        'if [ -r /etc/os-release ]; then (. /etc/os-release; echo "OSNAME=${PRETTY_NAME:-$NAME}"); fi; ' +
        'echo "CUDA=$(LC_ALL=C nvidia-smi 2>/dev/null | sed -n ''s/.*CUDA Version: *\([0-9][0-9.]*\).*/\1/p'' | head -n 1)"'

    $session = New-NvidiaSmiSshSession -HostName $HostName -SshSettings $SshSettings
    try {
        $r = Invoke-SshCommand -Session $session -Command $cmd
    }
    finally {
        Close-SshSession -Session $session
    }

    $facts = [ordered]@{ SysName = ''; Kernel = ''; NodeName = ''; OSName = ''; CudaVersion = '' }
    $map = @{ SYSNAME = 'SysName'; KERNEL = 'Kernel'; NODENAME = 'NodeName'; OSNAME = 'OSName'; CUDA = 'CudaVersion' }
    foreach ($line in @($r.Output -split "`n")) {
        if ($line -match '^([A-Z]+)=(.*)$' -and $map.ContainsKey($Matches[1])) { $facts[$map[$Matches[1]]] = $Matches[2].Trim() }
    }
    return $facts
}

function Get-NvidiaSmiDeviceAttributeMap {
    <#
    .SYNOPSIS
        Builds the WUG device attribute name/value map for one host from the discovery plan entry.
        Values we never got are left out (so an older good value is not overwritten); values
        nvidia-smi reported as N/A are written as 'N/A (reported by nvidia-smi)'.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Device,

        [Parameter(Mandatory = $true)]
        [string]$Prefix
    )

    $attrs = [ordered]@{}
    $add = {
        param($Name, $Value, $Unit)
        if ($null -eq $Value) { return }
        $v = ([string]$Value).Trim()
        if (-not $v -or $v -like 'Unknown*') { return }
        if ($Unit -and $v -match '^-?[0-9]+(\.[0-9]+)?$') { $v = '{0:0.##} {1}' -f [double]$v, $Unit }
        $attrs["$Prefix.$Name"] = $v
    }

    $facts = if ($Device.Contains('HostFacts')) { $Device.HostFacts } else { $null }
    if ($Device.Contains('ScanError')) {
        $err = [string]$Device.ScanError
        if ($err -match '^nvidia-smi exited (\d+) on [^:]+:\s*(.*)$') { $err = "nvidia-smi exit $($Matches[1]): $($Matches[2])" }
        & $add 'Status' "FAIL - $err"
    }
    else {
        $gpus = @($Device.Gpus)
        & $add 'Status' "OK - $($gpus.Count) GPU(s) responding to nvidia-smi"
        & $add 'GPUCount' $gpus.Count
        & $add 'GPUModels' ((@($gpus | Group-Object Name | ForEach-Object { "$($_.Count)x $($_.Name)" })) -join '; ')
        $mem = @($gpus | Where-Object { [string]$_.MemoryTotalMB -match '^[0-9]+(\.[0-9]+)?$' } | ForEach-Object { [double]$_.MemoryTotalMB })
        if ($mem.Count -gt 0) {
            $totalMb = ($mem | Measure-Object -Sum).Sum
            & $add 'TotalVRAM' ('{0:0.#} GB ({1:0} MB)' -f ($totalMb / 1024), $totalMb)
        }
        $drivers = @($gpus | ForEach-Object { [string]$_.DriverVersion } | Where-Object { $_ } | Select-Object -Unique)
        & $add 'DriverVersion' ($drivers -join ', ')

        foreach ($gpu in $gpus) {
            $g = "GPU$($gpu.Index)"
            & $add "$g.Model" $gpu.Name
            foreach ($p in @(
                    @('Serial', 'Serial', $null), @('UUID', 'UUID', $null), @('PciBusId', 'PciBusId', $null),
                    @('VRAM', 'MemoryTotalMB', 'MB'), @('VBIOS', 'VBIOS', $null), @('PowerLimit', 'PowerLimitW', 'W'),
                    @('ComputeCapability', 'ComputeCap', $null), @('ECCMode', 'EccMode', $null), @('PersistenceMode', 'PersistenceMode', $null))) {
                if ($gpu.PSObject.Properties[$p[1]]) { & $add "$g.$($p[0])" $gpu.($p[1]) $p[2] }
            }
            if ($gpu.PSObject.Properties['PcieGenMax'] -and [string]$gpu.PcieGenMax -match '^[0-9]+$' -and [string]$gpu.PcieWidthMax -match '^[0-9]+$') {
                & $add "$g.PCIeLink" "Gen$($gpu.PcieGenMax) x$($gpu.PcieWidthMax) (max)"
            }
        }
    }
    if ($facts) {
        & $add 'CudaVersion' $facts.CudaVersion
        & $add 'HostOS' $facts.OSName
        & $add 'HostKernel' $facts.Kernel
    }
    & $add 'LastInventory' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    return $attrs
}

function Get-NvidiaSmiOSRoleName {
    param([AllowNull()][System.Collections.IDictionary]$HostFacts)
    if (-not $HostFacts -or -not $HostFacts.SysName) { return $null }
    if ($HostFacts.SysName -eq 'Linux') { return 'Linux' }
    if ($HostFacts.SysName -match 'BSD|SunOS|AIX|HP-UX|Darwin') { return 'Unix' }
    return $null
}

# ============================================================================
# Pre-validation: run every monitor command over SSH before touching WUG
# ============================================================================
function Test-NvidiaSmiMonitorCommands {
    <#
    .SYNOPSIS
        Runs each GPU monitor's raw nvidia-smi query and its exact WUG command on a host.
    .DESCRIPTION
        Status values:
          OK              Every GPU returned a number; the command output is numeric.
          Partial         Some GPUs reported N/A; the aggregate covers the rest.
          NotReported     nvidia-smi answered, but returned N/A / [Not Supported] for every GPU.
                          The field exists; this GPU/driver simply does not expose it.
          UnknownField    This nvidia-smi/driver version does not recognize the field name.
          NvidiaSmiError  nvidia-smi itself failed (NVML init, driver mismatch, GPU lost, ...).
          BadOutput       The monitor command did not print a single number.
          SshError        Could not connect / authenticate.
        Only OK and Partial performance monitors are created. The GPU Health active
        monitor is created when it reports Up or Down (Down is a real result: it is
        exactly what that monitor exists to alert on).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$SshSettings,

        # GPUs nvidia-smi reported on this host; per-GPU monitors above this are not checked.
        [int]$GpuCount = 0
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $newResult = {
        param($Def, $Status, $Value, $Detail)
        [PSCustomObject]@{
            Host    = $HostName
            Kind    = $Def.Kind
            Monitor = $Def.MonitorName
            Field   = if ($Def.ContainsKey('Field')) { $Def.Field } else { $null }
            Status  = $Status
            Value   = $Value
            Detail  = $Detail
            Command = $Def.Command
        }
    }
    $hostDefs = @($script:GpuMonitorDefs | Where-Object { $null -eq $_.GpuIndex -or $_.GpuIndex -lt $GpuCount })
    if ($GpuCount -gt $MaxGpuCount) {
        Write-Warning "$HostName has $GpuCount GPUs but per-GPU monitors exist only for GPU0..GPU$($MaxGpuCount - 1) (-MaxGpuCount $MaxGpuCount). The rest are covered by host-wide monitors and GPU Health."
    }

    # Validate with the credential WUG will actually use when a password is available.
    $passwordOnly = [bool]$SshSettings.Password
    try {
        $session = New-NvidiaSmiSshSession -HostName $HostName -SshSettings $SshSettings -PasswordOnly:$passwordOnly
    }
    catch {
        $why = if ($passwordOnly) { "Password login as '$($SshSettings.Username)' failed, so WUG will not be able to poll either: $_" } else { "$_" }
        $results.Add((& $newResult $script:GpuHealthDef 'SshError' $null $why))
        foreach ($def in $hostDefs) { $results.Add((& $newResult $def 'SshError' $null $why)) }
        return $results
    }

    try {
        $awkInfo = Invoke-SshCommand -Session $session -Command 'p=$(command -v awk) && { r=$(readlink -f "$p" 2>/dev/null || echo "$p"); echo "$r"; }'
        $awkName = if ($awkInfo.ExitCode -eq 0 -and $awkInfo.Output) { Split-Path -Leaf ($awkInfo.Output.Trim()) } else { $null }
        if ($awkName) {
            Write-Host "    awk on ${HostName}: $awkName" -ForegroundColor DarkGray
        }
        else {
            Write-Warning "No 'awk' on PATH for ${HostName}; every monitor command will fail."
        }

        $health = Invoke-SshCommand -Session $session -Command $script:GpuHealthDef.Command
        $healthText = ("$($health.Output)" -replace '\s+', ' ').Trim()
        if ($healthText -match '^GPU_HEALTH_OK') {
            $results.Add((& $newResult $script:GpuHealthDef 'Up' 'Up' ($healthText -replace '^GPU_HEALTH_OK\s*', '')))
        }
        elseif ($healthText -match '^GPU_HEALTH_FAIL') {
            $results.Add((& $newResult $script:GpuHealthDef 'Down' 'Down' (($healthText -replace '^GPU_HEALTH_FAIL\s*', '') + ' (monitor will be created and alert on this)')))
        }
        else {
            $results.Add((& $newResult $script:GpuHealthDef 'BadOutput' $null "Health command printed '$healthText' (exit $($health.ExitCode), stderr: $($health.Error))."))
        }

        foreach ($def in $hostDefs) {
            $select = if ($null -ne $def.GpuIndex) { "-i $($def.GpuIndex) " } else { '' }
            $raw = Invoke-SshCommand -Session $session -Command "LC_ALL=C nvidia-smi $select--query-gpu=$($def.Field) --format=csv,noheader,nounits"
            $rawText = Get-NvidiaSmiFailureText $raw

            if ($raw.ExitCode -ne 0) {
                if ($rawText -match 'not a valid field') {
                    $results.Add((& $newResult $def 'UnknownField' $null "This nvidia-smi/driver does not recognize field '$($def.Field)': $rawText"))
                }
                else {
                    $results.Add((& $newResult $def 'NvidiaSmiError' $null "nvidia-smi exited $($raw.ExitCode): $rawText"))
                }
                continue
            }

            # One row per GPU; a row is numeric only if every column is numeric.
            $rows = @($raw.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $naGpus = [System.Collections.Generic.List[string]]::new()
            $badRows = [System.Collections.Generic.List[string]]::new()
            for ($r = 0; $r -lt $rows.Count; $r++) {
                $gpuLabel = if ($null -ne $def.GpuIndex) { [string]$def.GpuIndex } else { [string]$r }
                $cols = @($rows[$r] -split ',\s*')
                if (@($cols | Where-Object { $_ -notmatch '^-?[0-9]+(\.[0-9]+)?$' }).Count -eq 0) { continue }
                if (@($cols | Where-Object { $_ -match $script:NvidiaSmiNotReportedPattern }).Count -gt 0) { $naGpus.Add($gpuLabel) }
                else { $badRows.Add("GPU ${gpuLabel}: '$($rows[$r])'") }
            }

            if ($rows.Count -eq 0) {
                $results.Add((& $newResult $def 'BadOutput' $null 'nvidia-smi returned no rows (no GPUs visible to this user?).'))
                continue
            }
            if ($badRows.Count -gt 0) {
                $results.Add((& $newResult $def 'NvidiaSmiError' $null "nvidia-smi returned a non-numeric error value: $($badRows -join '; ')"))
                continue
            }
            if ($naGpus.Count -eq $rows.Count) {
                $results.Add((& $newResult $def 'NotReported' 'N/A' "nvidia-smi returned 'N/A' for '$($def.Field)' on all $($rows.Count) GPU(s). The query worked; this GPU/driver just does not report the metric."))
                continue
            }

            $mon = Invoke-SshCommand -Session $session -Command $def.Command
            $value = $mon.Output.Trim()
            if ($mon.ExitCode -ne 0 -or $value -notmatch '^-?[0-9]+(\.[0-9]+)?$') {
                $results.Add((& $newResult $def 'BadOutput' $value "Monitor command exited $($mon.ExitCode) and printed '$value' (stderr: $($mon.Error)); WUG needs a single number."))
                continue
            }

            if ($naGpus.Count -gt 0) {
                $results.Add((& $newResult $def 'Partial' $value "nvidia-smi returned 'N/A' on GPU(s) $($naGpus -join ', '); those GPUs are left out of the aggregate (not counted as 0)."))
            }
            else {
                $results.Add((& $newResult $def 'OK' $value ''))
            }
        }
    }
    finally {
        Close-SshSession -Session $session
    }

    return $results
}

function Write-NvidiaSmiValidationReport {
    param([object[]]$Validation)

    foreach ($hostGroup in @($Validation | Group-Object Host)) {
        Write-Host "  $($hostGroup.Name)" -ForegroundColor White
        foreach ($v in $hostGroup.Group) {
            $color = switch ($v.Status) { 'OK' { 'Green' } 'Up' { 'Green' } 'Partial' { 'Yellow' } 'Down' { 'Magenta' } 'NotReported' { 'DarkYellow' } default { 'Red' } }
            $val = if ($null -ne $v.Value -and "$($v.Value)" -ne '') { $v.Value } else { '-' }
            Write-Host ('    {0,-28} {1,-14} {2,-10} {3}' -f $v.Monitor, $v.Status, $val, $v.Detail) -ForegroundColor $color
        }
    }
}

# ============================================================================
# WUG Push: SSH credential, devices, shared library monitors, assignments
# ============================================================================
function Push-NvidiaSmiToWUG {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$DevicePlan,

        [Parameter(Mandatory = $true)]
        [object[]]$Validation,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$SshSettings
    )

    # The shared WUG discovery helpers probe unset globals (e.g. $global:WUGBearerHeaders) and are
    # not written for strict mode; relax it for this function's scope only.
    Set-StrictMode -Off

    $repoRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent
    if (-not (Get-Command -Name 'Add-WUGPerformanceMonitor' -ErrorAction SilentlyContinue)) {
        $repoPsd1 = Join-Path $repoRoot 'WhatsUpGoldPS.psd1'
        if (Test-Path $repoPsd1) { Import-Module $repoPsd1 -Force -ErrorAction Stop }
        else { Import-Module WhatsUpGoldPS -ErrorAction Stop }
    }
    $apiResponsePath = Join-Path $repoRoot 'functions\Get-WUGAPIResponse.ps1'
    if (Test-Path $apiResponsePath) { . $apiResponsePath }

    if (-not (Connect-WUGDiscoveryServer -WUGServer $WUGServer -WUGCredential $WUGCredential)) {
        throw 'Could not connect to WhatsUp Gold.'
    }

    $stats = [ordered]@{ Devices = 0; Created = 0; Updated = 0; Assigned = 0; Skipped = 0; NotValidated = 0; Failed = 0; AttributesSet = 0; AttributesUnchanged = 0; OSRoleSet = 0 }

    # 1. WUG SSH credential (WUG SSH credentials are username/password only).
    $wugCredentialId = $null
    if ($SshSettings.Password) {
        $credentialName = "WhatsUpGoldPS NvidiaSmi SSH ($($SshSettings.Username))"
        $wugCredential = @(Get-WUGCredential -SearchValue $credentialName -Type ssh -View basic) |
            Where-Object { $_.name -eq $credentialName } | Select-Object -First 1
        if (-not $wugCredential -and $PSCmdlet.ShouldProcess($credentialName, 'Create WUG SSH credential')) {
            Write-Host "  Creating WUG SSH credential '$credentialName' ..." -ForegroundColor Yellow
            $wugCredential = Add-WUGCredential -Name $credentialName -Type ssh -SshUsername $SshSettings.Username `
                -SshPassword $SshSettings.Password -SshPort ([string]$SshSettings.Port) -Confirm:$false
        }
        if ($wugCredential) {
            $wugCredentialId = if ($wugCredential.PSObject.Properties['resourceId']) { [string]$wugCredential.resourceId } else { [string]$wugCredential.id }
            Write-Host "  SSH credential: $credentialName (ID $wugCredentialId)" -ForegroundColor Gray
        }
    }
    else {
        Write-Warning 'No SSH password in the vault/parameters. WUG SSH credentials are password-based, so each device must already have a WUG SSH credential assigned or the monitors will fail to poll.'
    }

    # 2. Resolve (or create) each device and read its current monitor assignments.
    $usableStatuses = @('OK', 'Partial', 'Up', 'Down')
    $deviceIds = [ordered]@{}
    $assignedByDevice = @{}
    $activeByDevice = @{}
    foreach ($targetAddress in @($DevicePlan.Keys)) {
        $okCount = @($Validation | Where-Object { $_.Host -eq $targetAddress -and $_.Status -in $usableStatuses }).Count
        if ($okCount -eq 0) {
            Write-Warning "  $targetAddress has no monitor commands that passed SSH validation; skipping it in WUG."
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($targetAddress, 'Resolve/create WUG device')) { continue }

        $deviceId = Resolve-WUGDiscoveryTargetDevice -Target $targetAddress -PrimaryRole 'Server' -CredentialId $wugCredentialId `
            -Note "Added by WhatsUpGoldPS NVIDIA GPU discovery ($($DevicePlan[$targetAddress].GpuCount) GPU(s))."
        if (-not $deviceId) { continue }
        $deviceIds[$targetAddress] = [int]$deviceId
        $stats.Devices++

        if (-not $wugCredentialId) {
            $hasSsh = $false
            try {
                $hasSsh = @(Get-WUGDeviceCredential -DeviceId $deviceId | Where-Object {
                    ($_.PSObject.Properties['type'] -and "$($_.type)" -match 'ssh') -or
                    ($_.PSObject.Properties['credentialType'] -and "$($_.credentialType)" -match 'ssh')
                }).Count -gt 0
            }
            catch { }
            if (-not $hasSsh) { Write-Warning "  Device $targetAddress (ID $deviceId) has no SSH credential in WUG; its GPU monitors will not poll until one is assigned." }
        }

        $assigned = @{}
        $activeAssigned = @{}
        try {
            foreach ($pair in @(@('performance', $assigned), @('active', $activeAssigned))) {
                $uri = "$($global:WhatsUpServerBaseURI)/api/v1/devices/$deviceId/monitors/-?type=$($pair[0])&view=basic&limit=500"
                foreach ($m in @((Get-WUGAPIResponse -Uri $uri -Method GET).data)) {
                    if ($m -and $m.PSObject.Properties['monitorTypeId'] -and $m.monitorTypeId) { $pair[1][[string]$m.monitorTypeId] = $true }
                }
            }
        }
        catch {
            Write-Warning "  Could not read monitors on device $deviceId; skipping it to avoid duplicate assignments: $_"
            $deviceIds.Remove($targetAddress)
            continue
        }
        $assignedByDevice[$targetAddress] = $assigned
        $activeByDevice[$targetAddress] = $activeAssigned
    }

    # 2b. OS role (only when WUG has none) and GPU inventory attributes (only values that changed).
    if (-not $SkipDeviceAttributes) {
        foreach ($targetAddress in @($deviceIds.Keys)) {
            $deviceId = $deviceIds[$targetAddress]
            $dev = $DevicePlan[$targetAddress]
            $facts = if ($dev.Contains('HostFacts')) { $dev.HostFacts } else { $null }

            $osRole = Get-NvidiaSmiOSRoleName -HostFacts $facts
            if ($osRole) {
                try {
                    $currentOs = @((Get-WUGAPIResponse -Uri "$($global:WhatsUpServerBaseURI)/api/v1/devices/$deviceId/roles/-?kind=os" -Method GET).data) |
                        Where-Object { $_.kind -eq 'os' } | Select-Object -First 1
                    $currentOsName = if ($currentOs) { [string]$currentOs.name } else { '' }
                    if ((-not $currentOsName -or $currentOsName -eq 'Not set') -and
                        $PSCmdlet.ShouldProcess("$targetAddress (ID $deviceId)", "Set OS role '$osRole'")) {
                        Set-WUGDeviceRole -SetDeviceRoleKind -DeviceId ([string]$deviceId) -RoleKind os -RoleValue $osRole -Confirm:$false -ErrorAction Stop | Out-Null
                        Write-Host "  [OS] $targetAddress -> $osRole" -ForegroundColor Green
                        $stats.OSRoleSet++
                    }
                    elseif ($currentOsName -and $currentOsName -ne 'Not set' -and $currentOsName -ne $osRole) {
                        Write-Verbose "$targetAddress already has OS role '$currentOsName'; leaving it."
                    }
                }
                catch { Write-Warning "  Could not set OS role on $targetAddress (ID $deviceId): $_" }
            }

            $attrs = Get-NvidiaSmiDeviceAttributeMap -Device $dev -Prefix $AttributePrefix
            $existingAttrs = @{}
            try {
                foreach ($a in @(Get-WUGDeviceAttribute -DeviceId $deviceId -NameContains "$AttributePrefix.")) {
                    if ($a -and $a.name) { $existingAttrs[[string]$a.name] = [string]$a.value }
                }
            }
            catch { Write-Verbose "Could not read attributes on device ${deviceId}: $_" }

            $changed = 0
            foreach ($attrName in @($attrs.Keys)) {
                $attrValue = [string]$attrs[$attrName]
                if ($existingAttrs.ContainsKey($attrName) -and $existingAttrs[$attrName] -ceq $attrValue) { $stats.AttributesUnchanged++; continue }
                if (-not $PSCmdlet.ShouldProcess("$targetAddress (ID $deviceId)", "Set attribute $attrName = $attrValue")) { continue }
                try {
                    Set-WUGDeviceAttribute -DeviceId $deviceId -Name $attrName -Value $attrValue -Confirm:$false -ErrorAction Stop | Out-Null
                    $stats.AttributesSet++
                    $changed++
                }
                catch { Write-Warning "  Failed to set attribute '$attrName' on $targetAddress (ID $deviceId): $_" }
            }
            Write-Host "  [ATTR] $targetAddress (ID $deviceId): $changed of $($attrs.Count) $AttributePrefix.* attribute(s) written" -ForegroundColor Gray
        }
    }

    if ($deviceIds.Count -eq 0) {
        Write-Warning 'No WUG devices to update.'
        return [PSCustomObject]$stats
    }

    # 3. GPU Health active monitor: one shared library monitor, assigned wherever it ran (Up or Down).
    $healthName = $script:GpuHealthDef.MonitorName
    $healthTargets = @($deviceIds.Keys | Where-Object {
        $t = $_
        @($Validation | Where-Object { $_.Host -eq $t -and $_.Monitor -eq $healthName -and $_.Status -in @('Up', 'Down') }).Count -gt 0
    })
    if ($healthTargets.Count -gt 0) {
        $healthBags = @(
            @{ name = 'MonSSH:Command';      value = $script:GpuHealthDef.Command }
            @{ name = 'MonSSH:Output';       value = $script:GpuHealthDef.ExpectedOutput }
            @{ name = 'MonSSH:Contains';     value = '1' }
            @{ name = 'MonSSH:Regex';        value = 'False' }
            @{ name = 'MonSSH:EOLChars';     value = 'None' }
            @{ name = 'MonSSH:CredentialID'; value = '-1' }
            @{ name = 'Cred:Type';           value = '64' }
        )
        $activeLibrary = Get-WUGMonitorLibraryMap -Type active -AsObject
        $healthId = $null
        if ($activeLibrary.ContainsKey($healthName)) {
            $existing = $activeLibrary[$healthName]
            $healthId = if ($existing.PSObject.Properties['monitorId'] -and $existing.monitorId) { $existing.monitorId } else { $existing.id }
            $currentCmd = $null
            if ($existing.PSObject.Properties['propertyBags']) {
                $bag = @($existing.propertyBags) | Where-Object { $_.name -eq 'MonSSH:Command' } | Select-Object -First 1
                if ($bag) { $currentCmd = [string]$bag.value }
            }
            if ($null -ne $currentCmd -and $currentCmd -ne $script:GpuHealthDef.Command -and
                $PSCmdlet.ShouldProcess($healthName, 'Update SSH command on existing library monitor')) {
                try {
                    Set-WUGActiveMonitor -Mode Library -MonitorId ([string]$healthId) -PropertyBags $healthBags -Confirm:$false -ErrorAction Stop | Out-Null
                    Write-Host "  [UPDATED] $healthName (library ID $healthId): command refreshed" -ForegroundColor Yellow
                    $stats.Updated++
                }
                catch { Write-Warning "  Could not update command on '$healthName': $_" }
            }
        }
        elseif ($PSCmdlet.ShouldProcess($healthName, 'Create SSH active monitor in library')) {
            try {
                $healthId = Add-WUGActiveMonitor -Type Ssh -Name $healthName -Description $script:GpuHealthDef.Description `
                    -SshCommand $script:GpuHealthDef.Command -SshExpectedOutput $script:GpuHealthDef.ExpectedOutput `
                    -SshContains '1' -SshUseRegex 'False' -SshEOLChars 'None' -SshCredentialID -1 -Confirm:$false -ErrorAction Stop
                if (-not $healthId) {
                    $refreshed = Get-WUGMonitorLibraryMap -Type active
                    if ($refreshed.ContainsKey($healthName)) { $healthId = $refreshed[$healthName] }
                }
                if ($healthId) {
                    Write-Host "  [CREATED] $healthName (active, library ID $healthId)" -ForegroundColor Green
                    $stats.Created++
                }
            }
            catch { Write-Warning "  Failed to create library monitor '$healthName': $_" }
        }

        if ($healthId) {
            foreach ($t in $healthTargets) {
                $deviceId = $deviceIds[$t]
                if ($activeByDevice[$t].ContainsKey([string]$healthId)) { $stats.Skipped++; continue }
                if (-not $PSCmdlet.ShouldProcess("$healthName -> $t (ID $deviceId)", 'Assign active monitor')) { continue }
                try {
                    Add-WUGActiveMonitorToDevice -DeviceId $deviceId -MonitorId ([int]$healthId) -ErrorAction Stop | Out-Null
                    $activeByDevice[$t][[string]$healthId] = $true
                    $stats.Assigned++
                }
                catch {
                    Write-Warning "  Failed to assign '$healthName' to $t (ID $deviceId): $_"
                    $stats.Failed++
                }
            }
        }
        elseif (-not $WhatIfPreference) {
            Write-Warning "  No library ID for '$healthName'; it will not be assigned."
            $stats.Failed += $healthTargets.Count
        }
    }

    # 4. Performance library pre-check: one shared monitor per metric (and per GPU index), reused across devices.
    $library = Get-WUGMonitorLibraryMap -Type performance -AsObject

    foreach ($def in $script:GpuMonitorDefs) {
        $monName = $def.MonitorName
        $targetsForMon = @($deviceIds.Keys | Where-Object {
            $t = $_
            @($Validation | Where-Object { $_.Host -eq $t -and $_.Monitor -eq $monName -and $_.Status -in @('OK', 'Partial') }).Count -gt 0
        })
        # Per-GPU monitors for indexes a host does not have are expected gaps, not validation failures.
        $applicable = @($deviceIds.Keys | Where-Object {
            $null -eq $def.GpuIndex -or $def.GpuIndex -lt [int]$DevicePlan[$_].GpuCount
        }).Count
        $stats.NotValidated += ($applicable - $targetsForMon.Count)
        if ($targetsForMon.Count -eq 0) {
            Write-Verbose "No host validated '$monName'; not creating it."
            continue
        }

        $monitorId = $null
        if ($library.ContainsKey($monName)) {
            $existing = $library[$monName]
            $monitorId = if ($existing.PSObject.Properties['monitorId'] -and $existing.monitorId) { $existing.monitorId } else { $existing.id }

            $currentCmd = $null
            if ($existing.PSObject.Properties['propertyBags']) {
                $bag = @($existing.propertyBags) | Where-Object { $_.name -eq 'RdcSSH:Command' } | Select-Object -First 1
                if ($bag) { $currentCmd = [string]$bag.value }
            }
            if ($null -ne $currentCmd -and $currentCmd -ne $def.Command -and
                $PSCmdlet.ShouldProcess($monName, 'Update SSH command on existing library monitor')) {
                try {
                    Set-WUGPerformanceMonitor -MonitorId ([string]$monitorId) -Type Ssh -SshCommand $def.Command -Confirm:$false -ErrorAction Stop | Out-Null
                    Write-Host "  [UPDATED] $monName (library ID $monitorId): command refreshed" -ForegroundColor Yellow
                    $stats.Updated++
                }
                catch {
                    Write-Warning "  Could not update command on '$monName': $_"
                }
            }
        }
        elseif ($PSCmdlet.ShouldProcess($monName, 'Create SSH performance monitor in library')) {
            try {
                $created = Add-WUGPerformanceMonitor -Type Ssh -Name $monName -Description $def.Description `
                    -SshCommand $def.Command -SshCommandType 'SingleCommand' -SshUseCustomRegex '0' `
                    -SshEOLChars 'None' -SshCredentialID '-1' -Confirm:$false -ErrorAction Stop
                if ($created -and $created.Success) { $monitorId = $created.MonitorId }
                if (-not $monitorId) {
                    $refreshed = Get-WUGMonitorLibraryMap -Type performance
                    if ($refreshed.ContainsKey($monName)) { $monitorId = $refreshed[$monName] }
                }
                if ($monitorId) {
                    Write-Host "  [CREATED] $monName (library ID $monitorId)" -ForegroundColor Green
                    $stats.Created++
                }
            }
            catch {
                Write-Warning "  Failed to create library monitor '$monName': $_"
            }
        }

        if (-not $monitorId) {
            if (-not $WhatIfPreference) {
                Write-Warning "  No library ID for '$monName'; it will not be assigned."
                $stats.Failed += $targetsForMon.Count
            }
            continue
        }

        # 4. Assign only where validated and not already assigned.
        foreach ($t in $targetsForMon) {
            $deviceId = $deviceIds[$t]
            if ($assignedByDevice[$t].ContainsKey([string]$monitorId)) {
                $stats.Skipped++
                continue
            }
            if (-not $PSCmdlet.ShouldProcess("$monName -> $t (ID $deviceId)", 'Assign performance monitor')) { continue }
            try {
                Add-WUGPerformanceMonitorToDevice -DeviceId $deviceId -MonitorId ([int]$monitorId) `
                    -PollingIntervalMinutes $PollingIntervalMinutes -ErrorAction Stop | Out-Null
                $assignedByDevice[$t][[string]$monitorId] = $true
                $stats.Assigned++
            }
            catch {
                Write-Warning "  Failed to assign '$monName' to $t (ID $deviceId): $_"
                $stats.Failed++
            }
        }
    }

    return [PSCustomObject]$stats
}

# ============================================================================
# Main execution
# ============================================================================
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

Write-Host '=== NVIDIA GPU Discovery ===' -ForegroundColor Cyan
Write-Host "Targets: $($Target -join ', ')" -ForegroundColor Cyan
Write-Host ''

$sshSettings = Get-NvidiaSmiResolvedSshSettings
if (-not $sshSettings) {
    Write-Error 'No SSH credentials available. Exiting.'
    return
}

Write-Host "  SSH User: $($sshSettings.Username)  Port: $($sshSettings.Port)" -ForegroundColor DarkGray
Write-Host ''

# Discover GPUs on each target
$devicePlan = [ordered]@{}
foreach ($targetAddress in $Target) {
    Write-Host "  Scanning $targetAddress ..." -ForegroundColor DarkGray -NoNewline
    try {
        $gpus = @(Get-NvidiaGpuInventory -HostName $targetAddress -SshSettings $sshSettings)
    }
    catch {
        Write-Host ' FAILED' -ForegroundColor Red
        $scanError = $_.Exception.Message
        Write-Warning "SSH/nvidia-smi error for ${targetAddress}: $scanError"
        # SSH worked but nvidia-smi did not: keep the host so GPU Health can monitor (and alert on) it.
        if ($scanError -match '^nvidia-smi exited') {
            $devicePlan[$targetAddress] = [ordered]@{
                Name      = $targetAddress
                IP        = $targetAddress
                GpuCount  = 0
                Gpus      = @()
                ScanError = $scanError
            }
        }
        continue
    }
    Write-Host " $($gpus.Count) GPU(s)" -ForegroundColor $(if ($gpus.Count -gt 0) { 'Green' } else { 'Yellow' })

    if ($gpus.Count -eq 0) { continue }

    $devicePlan[$targetAddress] = [ordered]@{
        Name     = $targetAddress
        IP       = $targetAddress
        GpuCount = $gpus.Count
        Gpus     = $gpus
    }
}

if ($devicePlan.Count -eq 0) {
    Write-Warning 'No GPUs discovered on any target.'
    return
}

foreach ($targetAddress in @($devicePlan.Keys)) {
    try {
        $devicePlan[$targetAddress]['HostFacts'] = Get-NvidiaSmiHostFacts -HostName $targetAddress -SshSettings $sshSettings
    }
    catch { Write-Warning "Could not read OS/kernel/CUDA facts from ${targetAddress}: $($_.Exception.Message)" }
}

Write-Host ''
Write-Host 'Discovery complete!' -ForegroundColor Green
foreach ($device in $devicePlan.Values) {
    if ($device.Contains('HostFacts') -and $device.HostFacts) {
        $hf = $device.HostFacts
        $cudaText = if ($hf.CudaVersion) { "CUDA $($hf.CudaVersion)" } else { 'CUDA unknown (nvidia-smi did not report it)' }
        Write-Host "  $($device.Name): $($hf.OSName) | kernel $($hf.Kernel) | $cudaText" -ForegroundColor DarkGray
    }
    if ($device.Contains('ScanError')) {
        Write-Host "  $($device.Name): nvidia-smi failed; only GPU Health will be monitored (it will show down)." -ForegroundColor Yellow
        continue
    }
    Write-Host "  $($device.Name): $($device.GpuCount) GPU(s)" -ForegroundColor White
    foreach ($gpu in $device.Gpus) {
        $fmt = {
            param($Prop, $Unit)
            if (-not $gpu.PSObject.Properties[$Prop]) { return 'unavailable (snapshot query failed)' }
            $v = [string]$gpu.$Prop
            if ($v -match '^-?[0-9]+(\.[0-9]+)?$') { return "$v$Unit" }
            return $v
        }
        Write-Host "    [$($gpu.Index)] $($gpu.Name) - $($gpu.MemoryTotalMB) MB - Util: $(& $fmt 'GpuUtil' '%')  Temp: $(& $fmt 'TempC' 'C')  Fan: $(& $fmt 'FanPct' '%')" -ForegroundColor DarkGray
    }
}

# Action selection
$choice = $null
if ($Action) {
    switch ($Action) {
        'PushToWUG'       { $choice = '1' }
        'ExportJSON'      { $choice = '2' }
        'ExportCSV'       { $choice = '3' }
        'ShowTable'       { $choice = '4' }
        'Dashboard'       { $choice = '5' }
        'None'            { $choice = '6' }
        'DashboardAndPush' { $choice = '7' }
        'Validate'        { $choice = '8' }
    }
}

if (-not $choice -and $NonInteractive) { $choice = '5' }

if (-not $choice) {
    Write-Host ''
    Write-Host 'What would you like to do?' -ForegroundColor Cyan
    Write-Host '  [1] Push GPU monitors to WhatsUp Gold'
    Write-Host '  [2] Export inventory to JSON'
    Write-Host '  [3] Export inventory to CSV'
    Write-Host '  [4] Show GPU table in console'
    Write-Host '  [5] Generate HTML dashboard'
    Write-Host '  [6] Exit (do nothing)'
    Write-Host '  [7] Dashboard + Push to WUG'
    Write-Host '  [8] Validate monitor commands over SSH (no WUG changes)'
    Write-Host ''
    $choice = Read-Host -Prompt 'Choice [1-8]'
}

if ($choice -eq '7') {
    $actionsToRun = @('5', '1')
}
else {
    $actionsToRun = @($choice)
}

$validation = $null
foreach ($currentChoice in $actionsToRun) {
    switch ($currentChoice) {
        { $_ -in @('1', '8') } {
            Write-Host ''
            Write-Host 'Validating monitor commands over SSH...' -ForegroundColor Cyan
            $validationList = [System.Collections.Generic.List[object]]::new()
            foreach ($targetAddress in @($devicePlan.Keys)) {
                foreach ($v in @(Test-NvidiaSmiMonitorCommands -HostName $targetAddress -SshSettings $sshSettings -GpuCount ([int]$devicePlan[$targetAddress].GpuCount))) { $validationList.Add($v) }
            }
            $validation = @($validationList)
            Write-NvidiaSmiValidationReport -Validation $validation
            $usable = @($validation | Where-Object { $_.Status -in @('OK', 'Partial', 'Up', 'Down') }).Count
            Write-Host "  $usable of $($validation.Count) host/monitor combination(s) passed; only those will be created." -ForegroundColor Gray
        }
        '1' {
            Write-Host ''
            Write-Host 'Creating WUG SSH active/performance monitors...' -ForegroundColor Cyan
            $result = Push-NvidiaSmiToWUG -DevicePlan $devicePlan -Validation $validation -SshSettings $sshSettings
            Write-Host ''
            Write-Host 'WUG monitor sync complete!' -ForegroundColor Green
            Write-Host "  Devices processed       : $($result.Devices)" -ForegroundColor White
            Write-Host "  Library monitors created: $($result.Created)" -ForegroundColor White
            Write-Host "  Library monitors updated: $($result.Updated)" -ForegroundColor White
            Write-Host "  Assigned to devices     : $($result.Assigned)" -ForegroundColor White
            Write-Host "  Already assigned        : $($result.Skipped)" -ForegroundColor DarkGray
            Write-Host "  Skipped (failed SSH validation): $($result.NotValidated)" -ForegroundColor DarkGray
            if (-not $SkipDeviceAttributes) {
                Write-Host "  Device attributes written: $($result.AttributesSet) (unchanged: $($result.AttributesUnchanged))" -ForegroundColor White
                Write-Host "  OS roles set            : $($result.OSRoleSet)" -ForegroundColor White
            }
            if ($result.Failed -gt 0) {
                Write-Host "  Failed                  : $($result.Failed)" -ForegroundColor Red
            }
        }
        '2' {
            $jsonPath = Join-Path $OutputPath "NvidiaSmi-Inventory-$(Get-Date -Format yyyyMMdd-HHmmss).json"
            $allGpus = @()
            foreach ($dev in $devicePlan.Values) { $allGpus += $dev.Gpus }
            $allGpus | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath
            Write-Host "JSON exported: $jsonPath" -ForegroundColor Green
        }
        '3' {
            $csvPath = Join-Path $OutputPath "NvidiaSmi-Inventory-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
            $allGpus = @()
            foreach ($dev in $devicePlan.Values) { $allGpus += $dev.Gpus }
            $allGpus | Export-Csv -Path $csvPath -NoTypeInformation
            Write-Host "CSV exported: $csvPath" -ForegroundColor Green
        }
        '4' {
            foreach ($dev in $devicePlan.Values) {
                $dev.Gpus | Format-Table Host, Index, Name, MemoryTotalMB, GpuUtil, MemUtil, TempC, PowerW -AutoSize
            }
        }
        '5' {
            Write-Host ''
            Write-Host 'Generating dashboard...' -ForegroundColor Cyan

            $allGpus = @()
            foreach ($dev in $devicePlan.Values) { $allGpus += $dev.Gpus }

            $summaryPath = Join-Path $OutputPath 'NvidiaSmi-gpu-inventory-summary.json'
            $allGpus | ConvertTo-Json -Depth 5 | Set-Content -Path $summaryPath
            Write-Host "  Summary JSON: $summaryPath ($($allGpus.Count) GPUs)" -ForegroundColor DarkGray

            # Use dynamic dashboard generator if available
            $dynDashPath = Join-Path (Split-Path $scriptDir -Parent) 'reports\Export-DynamicDashboardHtml.ps1'
            if (Test-Path $dynDashPath) {
                . $dynDashPath
                $dashPath = Join-Path $OutputPath 'nvidiasmi-dashboard-gpu.html'
                $allGpus | Export-DynamicDashboardHtml `
                    -ReportTitle 'NVIDIA GPU Inventory' `
                    -OutputPath $dashPath
                Write-Host "  Dashboard: $dashPath" -ForegroundColor Green
            }
            else {
                Write-Host '  Dynamic dashboard generator not found. Summary JSON exported instead.' -ForegroundColor Yellow
            }

            # Copy to NmConsole if available
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
                $dashFiles = @(Get-ChildItem $OutputPath -Filter 'nvidiasmi-dashboard-*.html' -ErrorAction SilentlyContinue)
                foreach ($df in $dashFiles) {
                    try {
                        Copy-Item -LiteralPath $df.FullName -Destination (Join-Path $wugDashDir $df.Name) -Force
                        Write-Host "  Copied to WUG: $(Join-Path $wugDashDir $df.Name)" -ForegroundColor Green
                    }
                    catch { Write-Warning "Could not copy dashboard: $_" }
                }
            }
        }
        default {
            Write-Host 'Discovery completed.' -ForegroundColor Yellow
        }
    }
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCw9sngfp5x9tqi
# BGpM5wfAOl1vxkfXvYSe3n4uk62fBqCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqG
# SIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0
# NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAw
# ggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZG
# bEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3
# haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/
# tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06S
# hdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5
# pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7I
# H60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGg
# W+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+
# QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAg
# NpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8E
# BAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAb
# BgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9v
# dFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0
# LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdj
# MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0B
# AQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9
# hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCym
# laS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+
# vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4i
# TAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09
# Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6
# bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3
# sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z
# 1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls
# /GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9
# ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIE
# pqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNV
# BAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3Rp
# Z28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcN
# MjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGlj
# dXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJl
# cmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b
# 5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3
# /1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9
# gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JO
# xolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10
# nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYY
# x6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J
# 4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IK
# MEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZI
# zVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2
# u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy
# +jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQP
# Kssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIB
# ibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYB
# BQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYX
# aHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8
# oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWdu
# aW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDov
# L2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK
# 4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJ
# FyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNa
# yomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwIS
# OX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS
# 6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvf
# FxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tW
# iEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl
# 6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphB
# cr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6p
# vF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHe
# HYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEd
# gkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjU
# jsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bR
# VFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeS
# LsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIV
# NSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL
# 6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2Zd
# SoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFU
# eEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEw
# DQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/
# T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQ
# E7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9r
# EVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y
# 1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gx
# dEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3t
# y9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcy
# tL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEB
# YTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud
# /v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiS
# uEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZP
# ubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsF
# ADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNV
# BAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hB
# MjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVowYzEL
# MAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJE
# aWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYg
# MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz
# /TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP0BMx
# t9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3BSkU
# xDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZE
# eoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbjbrEO
# vZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26QZYMn
# /FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRsIolv
# ykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZ
# CZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5prW8
# 3vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjd
# zi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwroczk9ic
# flf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0G
# A1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQG
# fHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYB
# BQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2Nz
# cC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEy
# NTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hB
# MjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcB
# MA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQI
# ENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEtrfGh
# z45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfH
# hHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA
# 02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8pD7K
# VyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v5jht
# KVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvK
# qzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR5eHs
# 0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZEbGR
# sMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjWagkJ
# Nt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvdN8yW
# QPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgor
# BgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEE
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCx
# M8Vqc4OmIRq7TszhpquM5EApyopyFVALHmOeNbnIazANBgkqhkiG9w0BAQEFAASC
# AgDAJidUjBKJaBMtx64Roo8G1WquT6v4PPPnFwyCGI3va9cmAQl0gTNnxxK7DUQl
# 4MW4UUNXmEQ8xpNK7L2O4TV6yWnsMxkpr7sauJH6YvdTX99112SBMISNsr9gHbiE
# Gdf/XiTuJR06/fWykxA6oMCuEEYtIK8l0vbzPCFV2nbp+rMx0y7TPyIQEjki4sQd
# MlD2pYfiSYzLnS6U4poL7T0YHC93PP3xE4iAtIHv+hJaR1FbzAHd10XctJqgVEEp
# W4DLi7AN/o+h2HcHlBe1RCzH0i3mefBdevpUu0SxqrkmxZfzz5sVgn5sb8jU7Z+A
# Fxsoj2i1ofIDY2/Pzv9o3+hZlG3IxGlTU4Sz94XPo54qAev+W9h/qEYQlugw8j+n
# 69Awm9JI63RFRRtIIrlLHr9iCxchBvOltTCXSj7fkv9X0QT+G+4a6SgUK3Q4S57I
# FYxO9r+k+0BS7j+IC88y+hjd+oeWEOOZDa3bMWRMBSWPT5Sgs2+tcDVItaZco7Ev
# 2ItivtM9H0/O8mpxJe64wuf++EpyJUPXvE7GLyyRj/bIz/nB5NAFkoQyo4eGcE2E
# OTIfGEsNJ0bHdO4GnDMsCyL1o81bS/w6SYzKcpn9etBU2OpnsOcIutMLHfvr/qXb
# pDl071vovcwHnLATujHLh/Lu+2U6taaq2SA5D9umpjuaH6GCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTMxMzA2NTJaMC8GCSqGSIb3DQEJBDEiBCBy/GVNYUZX
# 0dwJBP7c7JXL9r9KEJJyfTOFU+O6ITTZZDANBgkqhkiG9w0BAQEFAASCAgB8jDkM
# p0Vb/I9CYcevOFPUisk+i+Q/Slt4LOHaX2fBEvx+a06q05b6k7OENJboDl9RmSYX
# tLt3Q9/ZGQX27tfxJe0jBcRgFiavTHbAb9TSqs91wENh6hMvQ/56fnUtzpHe38jV
# +AoE3dAMH3uo/bAhTucj0Rc9BJRAKFiWx8n2OR2bogdq+PuebKxTN/i13gz/Cyzl
# BniNRdDmLZRFLpIUshW2Dn5ATK0lZ935Be9e8wX/QZaNtQRquo8BZzPMoczxbiXf
# AQpl16JqlV617oV+e3k2hdzmuN57wjJpS+t2Ls7TJEYtSmSvjpj6nk1oqvwG7N2G
# /ANP5Y7AN3Tw3VGncdMBlILFkPUKMOkiV/99L3Tn8NIO/Y0jdr1fQPWgNZv5L0jL
# 2OTnSNkgDzh7LPerYF1tyeFt9XikBISAehPnXlKfyPmj/zhPIkpcCvSkLhJgTtpd
# a+EtGW/sMuB2IZhQtZ+EvwJ2AcsCoHS10Ba+M1Jl3CCnJ5xD3upN/t7YGSDGao1t
# D3LFXfknJL4wCKYQ8uOC/I+67zR795Jx0WEKI9WbtQ1XDkocJg6e6hflaM2YDjiw
# U/0vAIlLjVQr5/F/p8bQOJkkARGdlzQ3t/IRYuFN6Vs2FO/3EI9nV+/RApWjXcni
# EI8Go8wPo12SVH2o2GTbdLDTGEVOW6Wn04iNMw==
# SIG # End signature block
