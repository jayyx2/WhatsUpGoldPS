function New-WUGDevice {
    param (
        [Parameter(Mandatory = $true)] [string] $displayName,
        [Parameter(Mandatory = $true)] [string] $DeviceAddress,
        [Parameter()] [string] $deviceType,
        [Parameter()] [string] $PollInterval = 60,
        [Parameter()] [string] $PrimaryRole = "Device",
        [Parameter()] [string[]] $SubRoles,
        [Parameter()] [string] $snmpOid,
        [Parameter()] [string] $SNMPPort,
        [Parameter()] [string] $OS,
        [Parameter()] [string] $Brand,
        [Parameter()] [string] $ActionPolicy,
        [Parameter()] [string] $Note,
        [Parameter()] [string] $AutoRefresh,
        [Parameter()] [string[]] $Credentials,
        [Parameter()] [string[]] $Interfaces,
        [Parameter()] [string[]] $Attributes,
        [Parameter()] [string[]] $CustomLinks,
        [Parameter()] [string[]] $ActiveMonitors,
        [Parameter()] [string[]] $PerformanceMonitors,
        [Parameter()] [string[]] $PassiveMonitors,
        [Parameter()] [string[]] $Dependencies,
        [Parameter()] [string[]] $NCMTasks,
        [Parameter()] [string[]] $ApplicationProfiles,
        [Parameter()] [string[]] $Layer2Data,
        [Parameter()] [array] $Groups
    )

    #Global variables error checking
    if (-not $global:WUGBearerHeaders) { Write-Error -Message "Authorization header not set, running Connect-WUGServer"; Connect-WUGServer; }
    if ((Get-Date) -ge $global:expiry) { Write-Error -Message "Token expired, running Connect-WUGServer"; Connect-WUGServer; }
    if (-not $global:WhatsUpServerBaseURI) { Write-Error "Base URI not found. running Connect-WUGServer"; Connect-WUGServer; }
    #End global variables error checking

    $options = @("all")
    if ($ApplyL2) { $options += "l2" }
    if ($Update) { $options += "update" }
    if ($UpdateInterfaceState) { $options += "update-interface-state" }
    if ($UpdateInterfaceNames) { $options += "update-interface-names" }
    if ($UpdateActiveMonitors) { $options += "update-active-monitors" }

    $template = @{
        templateId = "WhatsUpGoldPS"
        displayName = "${displayName}"
        deviceType = "Workstation"
        snmpOid = ""
        snmpPort = ""
        pollInterval = "${PollInterval}"
        primaryRole = "Device"
        subRoles = @("Resource Attributes", "Resource Monitors")
        os = ""
        brand = ""
        actionPolicy = ""
        note = "${note}"
        autoRefresh = "True"
        credentials = @()
        interfaces = @(
            @{
              defaultInterface = "true"
              pollUsingNetworkName = "false"
              networkAddress = "0.0.0.0"
              networkName = "0.0.0.0"
            }
        )
        attributes = @()
        customLinks = @()
        activeMonitors = @()
        performanceMonitors = @()
        passiveMonitors = @()
        dependencies = @()
        ncmTasks = @()
        applicationProfiles = @()
        layer2Data = ""
        groups = @(@{
            name='My Network'
        })
    }

    $jsonBody = $template | ConvertTo-Json -Compress

    $body = "{
        `"options`":[`"all`"],
        `"templates`":[${jsonBody}]
    }"

    try {
        $result = Get-WUGAPIResponse -uri "${global:WhatsUpServerBaseURI}/api/v1/devices/-/config/template" -method "PATCH" -body $body
        return $result.data
    }
    catch {
        Write-Error $_
    }
}