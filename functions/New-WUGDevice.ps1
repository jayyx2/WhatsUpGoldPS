function New-WUGDevice {
    param (
        [Parameter()] [string] $displayName,
        [Parameter(Mandatory = $true)] [string] $DeviceAddress,
        [Parameter()] [string] $deviceType,
        [Parameter()] [string] $PollInterval,
        [Parameter()] [string] $PrimaryRole,
        [Parameter()] [string[]] $SubRoles,
        [Parameter()] [string] $snmpOid,
        [Parameter()] [string] $SNMPPort,
        [Parameter()] [string] $OS,
        [Parameter()] [string] $Brand,
        [Parameter()] [string] $ActionPolicy,
        [Parameter()] [string] $Note,
        [Parameter()] [string] $AutoRefresh,
        [Parameter()] [hashtable[]] $Credentials,
        [Parameter()] [hashtable[]] $Interfaces,
        [Parameter()] [hashtable[]] $Attributes,
        [Parameter()] [hashtable[]] $CustomLinks,
        [Parameter()] [hashtable[]] $ActiveMonitors,
        [Parameter()] [hashtable[]] $PerformanceMonitors,
        [Parameter()] [hashtable[]] $PassiveMonitors,
        [Parameter()] [hashtable[]] $Dependencies,
        [Parameter()] [hashtable[]] $NCMTasks,
        [Parameter()] [hashtable[]] $ApplicationProfiles,
        [Parameter()] [string] $Layer2Data,
        [Parameter()] [hashtable[]] $Groups
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
        templateId = 0
        displayName = ""
        deviceType = ""
        snmpOid = ""
        snmpPort = ""
        pollInterval = 60
        primaryRole = ""
        subRoles = @()
        os = ""
        brand = ""
        actionPolicy = ""
        note = ""
        autoRefresh = $true
        credentials = @()
        interfaces = @(@{})
        attributes = @(@{})
        customLinks = @(@{})
        activeMonitors = @(@{})
        performanceMonitors = @(@{})
        passiveMonitors = @(@{})
        dependencies = @(@{})
        ncmTasks = @(@{})
        applicationProfiles = @(@{})
        layer2Data = ""
        groups = @({@{parents='My Network'; name='Discovered Devices';}})
    }
    $body = $template | ConvertTo-Json -Depth 99
    return $body

    if ($displayName) {$template.displayName = $displayName}
    if ($Note) {$template.note = $Note}
    if ($templateId) {$template.templateId = $templateId}
    if ($snmpOid) {$template.snmpOid = $snmpOid}
    if ($deviceType) {$template.deviceType = $deviceType}
    if ($snmpPort) {$template.snmpPort = $snmpPort}
    if ($pollInterval) {$template.pollInterval = $pollInterval}
    if ($primaryRole) {$template.primaryRole = $primaryRole}
    if ($subRoles) {$template.subRoles = $subRoles}
    if ($os) {$template.os = $os}
    if ($brand) {$template.brand = $brand}
    if ($actionPolicy) {$template.actionPolicy = $actionPolicy}
    if ($autoRefresh) {$template.autoRefresh = $autoRefresh}
    if ($credentials) {$template.credentials = $credentials}
    if ($interfaces) {$template.interfaces = $interfaces}
    if ($attributes) {$template.attributes = $attributes}
    if ($customLinks) {$template.customLinks = $customLinks}
    if ($activeMonitors) {$template.activeMonitors = $activeMonitors}
    if ($performanceMonitors) {$template.performanceMonitors = $performanceMonitors}
    if ($passiveMonitors) {$template.passiveMonitors = $passiveMonitors}
    if ($dependencies) {$template.dependencies = $dependencies}
    if ($ncmTasks) {$template.ncmTasks = $ncmTasks}
    if ($applicationProfiles) {$template.applicationProfiles = $applicationProfiles}
    if ($layer2Data) {$template.layer2Data = $layer2Data}
    if ($groups){$template.groups = $groups}
    $jsonBody = $template | ConvertTo-Json -Depth 10
    $body = "{
        `"options`":[`"all`"],
        `"templates`":[${jsonBody}]
    }"
    $body
    try {
        $result = Get-WUGAPIResponse -uri "${global:WhatsUpServerBaseURI}/api/v1/devices/-/config/template" -method "PATCH" -body $body
        return $result.data
    }
    catch {
        Write-Error $_
    }
}