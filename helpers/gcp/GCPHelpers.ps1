# =============================================================================
# GCP Helpers for WhatsUpGoldPS
# Requires the GoogleCloud PowerShell module and the gcloud CLI.
# Install the module:
#   Install-Module -Name GoogleCloud -Scope CurrentUser -Force
# Install the gcloud CLI:
#   https://cloud.google.com/sdk/docs/install
# Authenticate:
#   gcloud auth activate-service-account --key-file="path/to/service-account-key.json"
#   gcloud config set project YOUR_PROJECT_ID
# =============================================================================

function Connect-GCPAccount {
    <#
    .SYNOPSIS
        Authenticates to GCP using a service account key file via the gcloud CLI.
    .DESCRIPTION
        Activates a service account, sets the default project, and validates
        connectivity. Requires the gcloud CLI to be installed and in PATH.
    .PARAMETER KeyFilePath
        Path to the service account JSON key file.
    .PARAMETER Project
        The GCP project ID to set as default.
    .EXAMPLE
        Connect-GCPAccount -KeyFilePath "C:\keys\service-account.json" -Project "my-gcp-project-123"
        Authenticates to GCP using the specified service account key and sets the default project.
    .EXAMPLE
        Connect-GCPAccount -KeyFilePath $env:GCP_KEY_FILE -Project $env:GCP_PROJECT
        Authenticates using paths from environment variables.
    #>
    param(
        [Parameter(Mandatory)][string]$KeyFilePath,
        [Parameter(Mandatory)][string]$Project
    )

    if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
        throw "gcloud CLI is not installed or not in PATH. Install from: https://cloud.google.com/sdk/docs/install"
    }

    if (-not (Test-Path $KeyFilePath)) {
        throw "Service account key file not found: $KeyFilePath"
    }

    # Activate service account
    $result = & gcloud auth activate-service-account --key-file="$KeyFilePath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to activate service account: $result"
    }

    # Set default project
    & gcloud config set project $Project 2>&1 | Out-Null

    # Validate connectivity
    try {
        $projectInfo = & gcloud projects describe $Project --format=json 2>&1 | ConvertFrom-Json
        if (-not $projectInfo.projectId) { throw "No project info returned" }
        Write-Verbose "Connected to GCP project $($projectInfo.projectId) ($($projectInfo.name))"
    }
    catch {
        throw "Failed to validate GCP connectivity: $($_.Exception.Message)"
    }
}

function Get-GCPAccessToken {
    <#
    .SYNOPSIS
        Returns a current OAuth2 access token from gcloud for REST API calls.
    .EXAMPLE
        $token = Get-GCPAccessToken
        Returns a bearer token string for use in REST API Authorization headers.
    #>

    $token = & gcloud auth print-access-token 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to get access token: $token"
    }
    return $token.Trim()
}

function Get-GCPProjects {
    <#
    .SYNOPSIS
        Returns all accessible GCP projects.
    .EXAMPLE
        Get-GCPProjects
        Returns all GCP projects accessible to the authenticated service account.
    .EXAMPLE
        Get-GCPProjects | Where-Object { $_.State -eq "ACTIVE" }
        Returns only active GCP projects.
    #>

    $json = & gcloud projects list --format=json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to list projects: $json" }

    $projects = $json | ConvertFrom-Json
    foreach ($p in $projects) {
        [PSCustomObject]@{
            ProjectId   = "$($p.projectId)"
            ProjectName = "$($p.name)"
            State       = "$($p.lifecycleState)"
            CreateTime  = "$($p.createTime)"
        }
    }
}

function Get-GCPComputeInstances {
    <#
    .SYNOPSIS
        Returns all Compute Engine VM instances in the specified project.
    .DESCRIPTION
        Uses Get-GceInstance from the GoogleCloud module to enumerate all VMs
        across all zones, returning a simplified collection with key properties.
    .PARAMETER Project
        The GCP project ID. If omitted, uses the default gcloud project.
    .EXAMPLE
        Get-GCPComputeInstances
        Returns all Compute Engine VMs in the default project.
    .EXAMPLE
        Get-GCPComputeInstances -Project "my-gcp-project-123"
        Returns all VMs in the specified project.
    .EXAMPLE
        Get-GCPComputeInstances | Where-Object { $_.Status -eq "RUNNING" }
        Returns only running VM instances.
    #>
    param(
        [string]$Project
    )

    $splat = @{}
    if ($Project) { $splat["Project"] = $Project }

    $instances = Get-GceInstance @splat -ErrorAction Stop
    foreach ($inst in $instances) {
        # Extract zone short name
        $zone = if ($inst.Zone) { ($inst.Zone -split '/')[-1] } else { "N/A" }
        $region = if ($zone -ne "N/A") { $zone -replace '-[a-z]$', '' } else { "N/A" }

        # Network interfaces
        $primaryNic = $inst.NetworkInterfaces | Select-Object -First 1
        $internalIP = if ($primaryNic.NetworkIP) { "$($primaryNic.NetworkIP)" } else { "N/A" }

        # External IP (from access configs)
        $externalIP = "N/A"
        if ($primaryNic.AccessConfigs) {
            $natIP = ($primaryNic.AccessConfigs | Where-Object { $_.NatIP } | Select-Object -First 1).NatIP
            if ($natIP) { $externalIP = "$natIP" }
        }

        # Disks
        $diskCount = @($inst.Disks).Count
        $bootDisk = $inst.Disks | Where-Object { $_.Boot -eq $true } | Select-Object -First 1
        $bootDiskType = if ($bootDisk.Interface) { "$($bootDisk.Interface)" } else { "N/A" }

        # Machine type short name
        $machineType = if ($inst.MachineType) { ($inst.MachineType -split '/')[-1] } else { "N/A" }

        # Tags
        $tags = if ($inst.Tags -and $inst.Tags.Items) { $inst.Tags.Items -join ", " } else { "" }

        # Labels
        $labels = if ($inst.Labels) {
            ($inst.Labels.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "; "
        } else { "" }

        # Service accounts
        $serviceAccounts = if ($inst.ServiceAccounts) {
            ($inst.ServiceAccounts | ForEach-Object { $_.Email }) -join ", "
        } else { "N/A" }

        # Network name
        $networkName = if ($primaryNic.Network) { ($primaryNic.Network -split '/')[-1] } else { "N/A" }
        $subnetName  = if ($primaryNic.Subnetwork) { ($primaryNic.Subnetwork -split '/')[-1] } else { "N/A" }

        [PSCustomObject]@{
            Name            = "$($inst.Name)"
            InstanceId      = "$($inst.Id)"
            MachineType     = $machineType
            Status          = "$($inst.Status)"
            Zone            = $zone
            Region          = $region
            InternalIP      = $internalIP
            ExternalIP      = $externalIP
            Network         = $networkName
            Subnet          = $subnetName
            DiskCount       = "$diskCount"
            BootDiskType    = $bootDiskType
            Tags            = $tags
            Labels          = $labels
            ServiceAccounts = $serviceAccounts
            CreationTime    = if ($inst.CreationTimestamp) { "$($inst.CreationTimestamp)" } else { "N/A" }
            Description     = if ($inst.Description) { "$($inst.Description.Substring(0, [math]::Min(200, $inst.Description.Length)))" } else { "" }
        }
    }
}

function Get-GCPCloudSQLInstances {
    <#
    .SYNOPSIS
        Returns all Cloud SQL instances in the specified project.
    .PARAMETER Project
        The GCP project ID.
    .EXAMPLE
        Get-GCPCloudSQLInstances
        Returns all Cloud SQL instances in the default project.
    .EXAMPLE
        Get-GCPCloudSQLInstances -Project "my-gcp-project-123"
        Returns all Cloud SQL instances in the specified project with IP, tier, and status.
    .EXAMPLE
        Get-GCPCloudSQLInstances | Where-Object { $_.DatabaseVersion -like "MYSQL*" }
        Returns only MySQL Cloud SQL instances.
    #>
    param(
        [string]$Project
    )

    $splat = @{ ErrorAction = "Stop" }
    if ($Project) { $splat["Project"] = $Project }

    $instances = Get-GcSqlInstance @splat
    foreach ($db in $instances) {
        # IP addresses
        $publicIP  = "N/A"
        $privateIP = "N/A"
        if ($db.IpAddresses) {
            foreach ($addr in $db.IpAddresses) {
                if ($addr.Type -eq "PRIMARY")  { $publicIP  = "$($addr.IpAddress)" }
                if ($addr.Type -eq "PRIVATE")  { $privateIP = "$($addr.IpAddress)" }
            }
        }

        [PSCustomObject]@{
            InstanceName    = "$($db.Name)"
            DatabaseVersion = "$($db.DatabaseVersion)"
            Tier            = "$($db.Settings.Tier)"
            State           = "$($db.State)"
            Region          = "$($db.Region)"
            GceZone         = if ($db.GceZone) { "$($db.GceZone)" } else { "N/A" }
            PublicIP        = $publicIP
            PrivateIP       = $privateIP
            DataDiskSizeGB  = if ($db.Settings.DataDiskSizeGb) { "$($db.Settings.DataDiskSizeGb)" } else { "N/A" }
            DataDiskType    = if ($db.Settings.DataDiskType) { "$($db.Settings.DataDiskType)" } else { "N/A" }
            BackupEnabled   = if ($null -ne $db.Settings.BackupConfiguration.Enabled) { "$($db.Settings.BackupConfiguration.Enabled)" } else { "N/A" }
            HA              = if ($db.Settings.AvailabilityType) { "$($db.Settings.AvailabilityType)" } else { "N/A" }
            StorageAutoResize = if ($null -ne $db.Settings.StorageAutoResize) { "$($db.Settings.StorageAutoResize)" } else { "N/A" }
            ConnectionName  = if ($db.ConnectionName) { "$($db.ConnectionName)" } else { "N/A" }
            SelfLink        = if ($db.SelfLink) { "$($db.SelfLink)" } else { "N/A" }
        }
    }
}

function Get-GCPForwardingRules {
    <#
    .SYNOPSIS
        Returns all forwarding rules (load balancer frontends) in the project.
    .DESCRIPTION
        Uses the gcloud CLI to enumerate global and regional forwarding rules,
        which represent load balancer entry points with IP addresses.
    .PARAMETER Project
        The GCP project ID.
    .EXAMPLE
        Get-GCPForwardingRules
        Returns all global and regional forwarding rules (load balancer frontends) in the default project.
    .EXAMPLE
        Get-GCPForwardingRules -Project "my-gcp-project-123"
        Returns all forwarding rules in the specified project.
    .EXAMPLE
        Get-GCPForwardingRules | Where-Object { $_.Scheme -eq "EXTERNAL" }
        Returns only external-facing forwarding rules.
    #>
    param(
        [string]$Project
    )

    $projectArg = if ($Project) { "--project=$Project" } else { "" }

    # Global forwarding rules
    $globalJson = if ($projectArg) {
        & gcloud compute forwarding-rules list --global --format=json $projectArg 2>&1
    } else {
        & gcloud compute forwarding-rules list --global --format=json 2>&1
    }

    # Regional forwarding rules
    $regionalJson = if ($projectArg) {
        & gcloud compute forwarding-rules list --format=json $projectArg 2>&1
    } else {
        & gcloud compute forwarding-rules list --format=json 2>&1
    }

    $allRules = @()
    foreach ($json in @($globalJson, $regionalJson)) {
        if ($LASTEXITCODE -eq 0 -and $json) {
            try {
                $rules = $json | ConvertFrom-Json
                $allRules += $rules
            }
            catch { }
        }
    }

    # Deduplicate by selfLink
    $seen = @{}
    foreach ($rule in $allRules) {
        $key = "$($rule.selfLink)"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $region = if ($rule.region) { ($rule.region -split '/')[-1] } else { "global" }

        [PSCustomObject]@{
            Name         = "$($rule.name)"
            IPAddress    = if ($rule.IPAddress) { "$($rule.IPAddress)" } else { "N/A" }
            IPProtocol   = if ($rule.IPProtocol) { "$($rule.IPProtocol)" } else { "N/A" }
            PortRange    = if ($rule.portRange) { "$($rule.portRange)" } else { "N/A" }
            Target       = if ($rule.target) { ($rule.target -split '/')[-1] } else { "N/A" }
            Region       = $region
            Network      = if ($rule.network) { ($rule.network -split '/')[-1] } else { "N/A" }
            Scheme       = if ($rule.loadBalancingScheme) { "$($rule.loadBalancingScheme)" } else { "N/A" }
            SelfLink     = "$($rule.selfLink)"
        }
    }
}

function Get-GCPCloudMonitoringMetrics {
    <#
    .SYNOPSIS
        Returns recent Cloud Monitoring metric data for a GCP resource.
    .DESCRIPTION
        Queries the Cloud Monitoring API v3 for time series data.
        Uses the gcloud access token for authentication.
    .PARAMETER Project
        The GCP project ID.
    .PARAMETER ResourceType
        The monitored resource type (e.g. gce_instance, cloudsql_database).
    .PARAMETER ResourceLabels
        Hashtable of resource labels to filter on (e.g. @{instance_id="123456"}).
    .PARAMETER MetricTypes
        Array of metric type strings to retrieve. If omitted, uses sensible defaults.
    .EXAMPLE
        Get-GCPCloudMonitoringMetrics -Project "my-project" -ResourceType "gce_instance" -ResourceLabels @{instance_id="1234567890"}
        Returns default Compute Engine metrics (CPU, network, disk) for the specified VM instance.
    .EXAMPLE
        Get-GCPCloudMonitoringMetrics -Project "my-project" -ResourceType "cloudsql_database" -ResourceLabels @{database_id="my-project:mydb"}
        Returns default Cloud SQL metrics (CPU, memory, disk utilization) for the specified database.
    .EXAMPLE
        Get-GCPCloudMonitoringMetrics -Project "my-project" -ResourceType "gce_instance" -ResourceLabels @{instance_id="123"} -MetricTypes @("compute.googleapis.com/instance/cpu/utilization")
        Returns only CPU utilization metrics for the specified instance.
    #>
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$ResourceType,
        [Parameter(Mandatory)][hashtable]$ResourceLabels,
        [string[]]$MetricTypes
    )

    # Default metrics per resource type
    if (-not $MetricTypes) {
        $MetricTypes = switch ($ResourceType) {
            "gce_instance" {
                @("compute.googleapis.com/instance/cpu/utilization",
                  "compute.googleapis.com/instance/network/received_bytes_count",
                  "compute.googleapis.com/instance/network/sent_bytes_count",
                  "compute.googleapis.com/instance/disk/read_ops_count",
                  "compute.googleapis.com/instance/disk/write_ops_count",
                  "compute.googleapis.com/instance/uptime")
            }
            "cloudsql_database" {
                @("cloudsql.googleapis.com/database/cpu/utilization",
                  "cloudsql.googleapis.com/database/memory/utilization",
                  "cloudsql.googleapis.com/database/disk/utilization",
                  "cloudsql.googleapis.com/database/network/connections",
                  "cloudsql.googleapis.com/database/up")
            }
            default { @() }
        }
    }

    $token = Get-GCPAccessToken
    $headers = @{ Authorization = "Bearer $token" }
    $baseUri = "https://monitoring.googleapis.com/v3/projects/$Project/timeSeries"

    $endTime   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $startTime = (Get-Date).AddHours(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    $results = @()
    foreach ($metricType in $MetricTypes) {
        try {
            # Build filter
            $filterParts = @("metric.type = `"$metricType`"", "resource.type = `"$ResourceType`"")
            foreach ($label in $ResourceLabels.GetEnumerator()) {
                $filterParts += "resource.labels.$($label.Key) = `"$($label.Value)`""
            }
            $filter = $filterParts -join " AND "

            $uri = "${baseUri}?filter=$([System.Uri]::EscapeDataString($filter))&interval.startTime=$startTime&interval.endTime=$endTime&aggregation.alignmentPeriod=300s&aggregation.perSeriesAligner=ALIGN_MEAN"

            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop

            $lastValue = "N/A"
            $unit = "N/A"
            if ($response.timeSeries) {
                $series = $response.timeSeries | Select-Object -First 1
                $unit = if ($series.unit) { "$($series.unit)" } else { "N/A" }
                $latest = $series.points | Select-Object -First 1
                if ($latest.value) {
                    if ($null -ne $latest.value.doubleValue) {
                        $lastValue = "$([math]::Round($latest.value.doubleValue, 4))"
                    }
                    elseif ($null -ne $latest.value.int64Value) {
                        $lastValue = "$($latest.value.int64Value)"
                    }
                }
            }

            # Friendly metric name from the full type
            $shortName = ($metricType -split '/')[-1]

            $results += [PSCustomObject]@{
                MetricType  = $metricType
                MetricName  = $shortName
                LastValue   = $lastValue
                Unit        = $unit
            }
        }
        catch {
            Write-Verbose "Could not retrieve metric $metricType : $($_.Exception.Message)"
        }
    }

    return $results
}

function Resolve-GCPResourceIP {
    <#
    .SYNOPSIS
        Resolves an IP address for a GCP resource.
    .DESCRIPTION
        For Compute Engine VMs returns external IP (preferred) or internal IP.
        For Cloud SQL returns public IP (preferred) or private IP.
        For forwarding rules returns the rule IP address.
    .PARAMETER ResourceType
        The type of resource: ComputeEngine, CloudSQL, or ForwardingRule.
    .PARAMETER Resource
        The resource object from the corresponding Get-GCP* function.
    .EXAMPLE
        $vms = Get-GCPComputeInstances
        $ip = Resolve-GCPResourceIP -ResourceType "ComputeEngine" -Resource $vms[0]
        Resolves the IP for the first Compute Engine VM (prefers external IP).
    .EXAMPLE
        $dbs = Get-GCPCloudSQLInstances
        Resolve-GCPResourceIP -ResourceType "CloudSQL" -Resource $dbs[0]
        Resolves the IP for a Cloud SQL instance (prefers public IP).
    .EXAMPLE
        $rules = Get-GCPForwardingRules
        Resolve-GCPResourceIP -ResourceType "ForwardingRule" -Resource $rules[0]
        Returns the IP address of the first forwarding rule.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet("ComputeEngine", "CloudSQL", "ForwardingRule")][string]$ResourceType,
        [Parameter(Mandatory)]$Resource
    )

    $ip = $null

    switch ($ResourceType) {
        "ComputeEngine" {
            if ($Resource.ExternalIP -and $Resource.ExternalIP -ne "N/A") {
                $ip = $Resource.ExternalIP
            }
            elseif ($Resource.InternalIP -and $Resource.InternalIP -ne "N/A") {
                $ip = $Resource.InternalIP
            }
        }
        "CloudSQL" {
            if ($Resource.PublicIP -and $Resource.PublicIP -ne "N/A") {
                $ip = $Resource.PublicIP
            }
            elseif ($Resource.PrivateIP -and $Resource.PrivateIP -ne "N/A") {
                $ip = $Resource.PrivateIP
            }
        }
        "ForwardingRule" {
            if ($Resource.IPAddress -and $Resource.IPAddress -ne "N/A") {
                $ip = $Resource.IPAddress
            }
        }
    }

    return $ip
}

function Get-GCPDashboard {
    <#
    .SYNOPSIS
        Builds a unified dashboard view of GCP Compute, Cloud SQL, and Forwarding Rules.
    .DESCRIPTION
        Queries the specified project for Compute Engine VMs, Cloud SQL instances,
        and forwarding rules then returns a flat collection suitable for Bootstrap
        Table display. Each row contains resource type, name, status, resolved IP,
        region, zone, machine type, network, disk count, labels, and creation time.
    .PARAMETER Project
        The GCP project ID. If omitted, uses the default gcloud project.
    .PARAMETER IncludeCloudSQL
        Include Cloud SQL instances in the results. Defaults to $true.
    .PARAMETER IncludeForwardingRules
        Include forwarding rules (load balancers) in the results. Defaults to $true.
    .EXAMPLE
        Get-GCPDashboard

        Returns all Compute, Cloud SQL, and forwarding rule resources in the default project.
    .EXAMPLE
        Get-GCPDashboard -Project "my-project" -IncludeCloudSQL $false

        Returns only Compute and forwarding rule resources.
    .EXAMPLE
        Connect-GCPAccount -KeyFilePath "C:\keys\sa.json" -Project "my-project"
        $data = Get-GCPDashboard -Project "my-project"
        Export-GCPDashboardHtml -DashboardData $data -OutputPath "C:\Reports\gcp.html"
        Start-Process "C:\Reports\gcp.html"

        End-to-end: authenticate with service account, gather data, export HTML, and open in browser.
    .OUTPUTS
        PSCustomObject[]
        Each object contains: ResourceType, Name, Status, IPAddress, InternalIP,
        Region, Zone, MachineType, Network, DiskCount, Labels, CreationTime.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+, GoogleCloud PowerShell module, gcloud CLI authenticated.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    param(
        [string]$Project,
        [bool]$IncludeCloudSQL = $true,
        [bool]$IncludeForwardingRules = $true
    )

    $results = @()

    # Compute Engine VMs
    try {
        $instances = Get-GCPComputeInstances -Project $Project
        foreach ($inst in $instances) {
            $ip = Resolve-GCPResourceIP -ResourceType "ComputeEngine" -Resource $inst
            $results += [PSCustomObject]@{
                ResourceType = "Compute"
                Name         = $inst.Name
                Status       = $inst.Status
                IPAddress    = if ($ip) { $ip } else { "N/A" }
                InternalIP   = $inst.InternalIP
                Region       = $inst.Region
                Zone         = $inst.Zone
                MachineType  = $inst.MachineType
                Network      = $inst.Network
                DiskCount    = $inst.DiskCount
                Labels       = $inst.Labels
                CreationTime = $inst.CreationTime
            }
        }
    }
    catch { Write-Warning "Compute query failed: $($_.Exception.Message)" }

    # Cloud SQL
    if ($IncludeCloudSQL) {
        try {
            $dbs = Get-GCPCloudSQLInstances -Project $Project
            foreach ($db in $dbs) {
                $ip = Resolve-GCPResourceIP -ResourceType "CloudSQL" -Resource $db
                $results += [PSCustomObject]@{
                    ResourceType = "CloudSQL"
                    Name         = $db.InstanceName
                    Status       = $db.State
                    IPAddress    = if ($ip) { $ip } else { "N/A" }
                    InternalIP   = $db.PrivateIP
                    Region       = $db.Region
                    Zone         = $db.GceZone
                    MachineType  = $db.Tier
                    Network      = "N/A"
                    DiskCount    = $db.DataDiskSizeGB
                    Labels       = ""
                    CreationTime = "N/A"
                }
            }
        }
        catch { Write-Warning "Cloud SQL query failed: $($_.Exception.Message)" }
    }

    # Forwarding Rules
    if ($IncludeForwardingRules) {
        try {
            $rules = Get-GCPForwardingRules -Project $Project
            foreach ($rule in $rules) {
                $ip = Resolve-GCPResourceIP -ResourceType "ForwardingRule" -Resource $rule
                $results += [PSCustomObject]@{
                    ResourceType = "ForwardingRule"
                    Name         = $rule.Name
                    Status       = $rule.Scheme
                    IPAddress    = if ($ip) { $ip } else { "N/A" }
                    InternalIP   = "N/A"
                    Region       = $rule.Region
                    Zone         = "N/A"
                    MachineType  = "$($rule.IPProtocol) $($rule.PortRange)"
                    Network      = $rule.Network
                    DiskCount    = "N/A"
                    Labels       = ""
                    CreationTime = "N/A"
                }
            }
        }
        catch { Write-Warning "Forwarding rules query failed: $($_.Exception.Message)" }
    }

    return $results
}

function Export-GCPDashboardHtml {
    <#
    .SYNOPSIS
        Renders GCP dashboard data into a self-contained HTML file.
    .DESCRIPTION
        Takes the output of Get-GCPDashboard and generates a Bootstrap-based
        HTML report with sortable, searchable, and exportable tables. The report
        uses Bootstrap 5 and Bootstrap-Table for interactive filtering, sorting,
        column toggling, and CSV/JSON export.
    .PARAMETER DashboardData
        Array of PSCustomObject from Get-GCPDashboard containing Compute, Cloud SQL,
        and forwarding rule details.
    .PARAMETER OutputPath
        File path for the output HTML file. Parent directory must exist.
    .PARAMETER ReportTitle
        Title shown in the report header. Defaults to "GCP Dashboard".
    .PARAMETER TemplatePath
        Optional path to a custom HTML template. If omitted, uses the
        GCP-Dashboard-Template.html in the same directory as this script.
    .EXAMPLE
        $data = Get-GCPDashboard -Project "my-project"
        Export-GCPDashboardHtml -DashboardData $data -OutputPath "C:\Reports\gcp.html"

        Exports the dashboard data to an HTML file using the default template.
    .EXAMPLE
        Export-GCPDashboardHtml -DashboardData $data -OutputPath "$env:TEMP\gcp.html" -ReportTitle "Prod GCP"

        Exports with a custom report title.
    .EXAMPLE
        Connect-GCPAccount -KeyFilePath "C:\keys\sa.json" -Project "my-project"
        $data = Get-GCPDashboard -Project "my-project"
        Export-GCPDashboardHtml -DashboardData $data -OutputPath "C:\Reports\gcp.html"
        Start-Process "C:\Reports\gcp.html"

        Full pipeline: authenticate, gather, export, and open the report in a browser.
    .OUTPUTS
        System.Void
        Writes an HTML file to the path specified by OutputPath.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Date    : 2025-07-15
        Requires: PowerShell 5.1+, GCP-Dashboard-Template.html in the script directory.
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DashboardData,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = "GCP Dashboard",
        [string]$TemplatePath
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path $PSScriptRoot "GCP-Dashboard-Template.html"
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
        if ($prop.Name -eq 'Status') {
            $col.formatter = 'formatStatus'
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
    Write-Verbose "GCP Dashboard HTML written to $OutputPath"
}

# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDMqInuGNOYRn/f
# /ngGfTYA+64PiiO1gfKzsYcLPwOS9qCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgkpW+PKcx1LON/aITuRiHdlF3YJb7CS3p
# Qd/xnFEO2N4wDQYJKoZIhvcNAQEBBQAEggIAFfPhKG+dYsT7d7zsJ2fjs9V1iczG
# CdlCTznN3EmUJJxnv4LT9EsrBGijm+ecrzIB8S6T7Ag8t1g8FPGnqqG0V7SMzC2l
# VGeEXSpWIP+xSU5+aeNUM7KsVekPM9QpacmIlgTDEoJzQcA+/PYhGd2kA1LzTz6p
# ni/Zmd2IK23G6nX6FrvIt7OmSQeEaepVPhOkIHG4WEPpaCUtEgmyuQPawL+L9Dbv
# 03YGfazD36pXICYnKX66bidWfFaRXrIFzFd+8+8dacYM1LHo0xROrz93Iu5K24xV
# W5fU1+9KiEoN16NzIUnzugZ1eYOH7BHxMZZl70Fft6mOa9hgZ/1F/D8yXVgXpf/i
# mGU5eVVwdGUd3HLJfLybjbe3ekTgGpSMQPvIKq/gXIaWXQMavHP28b1/BE7BW9vd
# c6iXLD6vK+Bi6nh/CrIig1RAWc2XkxRUMqr3cASnL4x/zxltl/Bag0xBrCMWsKml
# MW7orptLavt0KtHX//127x81GIx0m5o3qQwXbqHJY1gNNDSe8Hr8H6dSV00ADYTn
# 6DbaHBtCzlXO99VfudBw/qLlZpkTJ+2mB4x1Y6Yscct7areNYw4qqRCfzF46Mzjr
# 30EYoXun5Q4SqdfBzT25biSud5umcQjdE8VLUaavyZWKMvrua+JeLJM5fVDmp6To
# QtDg43tqOIxJKQg=
# SIG # End signature block
