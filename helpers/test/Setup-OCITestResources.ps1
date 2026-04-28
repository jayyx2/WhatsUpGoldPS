<#
.SYNOPSIS
    Creates minimal OCI Always Free test resources for WUG OCI discovery E2E testing.

.DESCRIPTION
    Creates resources that the OCI discovery provider (DiscoveryProvider-OCI.ps1) and
    OCIHelpers.ps1 can discover and exercise:

      - VCN + public subnet + internet gateway + route table + security list
      - 1x Ampere A1 Flex VM (VM.Standard.A1.Flex, 1 OCPU / 6 GB, Always Free)
      - 1x Autonomous Database (Always Free tier, OLTP)
      - 1x Flexible Load Balancer (10 Mbps, Always Free)

    All resources are tagged wug-test=true for easy identification and teardown.
    Resource OCIDs are saved to oci-test-state.json for teardown.

    Uses the OCI CLI -- no OCI PowerShell modules required.
    The OCI CLI must be installed and configured (oci setup config).

.PARAMETER CompartmentId
    The OCID of the compartment to create resources in.
    Use the tenancy OCID for the root compartment.

.PARAMETER SshPublicKeyFile
    Path to your SSH public key file for VM access.
    Default: ~/.ssh/id_rsa.pub

.PARAMETER AvailabilityDomain
    Override the availability domain. Auto-detected if not specified.

.PARAMETER Prefix
    Name prefix for all resources. Default: wug-test

.PARAMETER StateFile
    Path to save the state file for teardown. Default: $env:TEMP\WhatsUpGoldPS\oci-test-state.json

.EXAMPLE
    .\Setup-OCITestResources.ps1 -CompartmentId "ocid1.compartment.oc1..aaa..."

.EXAMPLE
    .\Setup-OCITestResources.ps1 -CompartmentId $env:OCI_COMPARTMENT_ID -SshPublicKeyFile "C:\Users\me\.ssh\id_rsa.pub"

.NOTES
    All resources are OCI Always Free tier -- $0 cost.
    Resources created (all tagged wug-test=true):
      VCN:     wug-test-vcn           (10.0.0.0/16)
      Subnet:  wug-test-subnet-pub    (10.0.1.0/24, public)
      IGW:     wug-test-igw
      RT:      wug-test-rt
      SL:      wug-test-sl
      VM:      wug-test-vm-a1         (VM.Standard.A1.Flex 1 OCPU / 6 GB, Oracle Linux aarch64)
      ADB:     wug-test-adb           (Autonomous DB, Always Free, OLTP)
      LB:      wug-test-lb            (Flexible LB, 10 Mbps)

    Run Teardown-OCITestResources.ps1 to delete everything.

    Author: Jason Alberino (jason@wug.ninja)
    Encoding: UTF-8 with BOM
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CompartmentId,

    [string]$SshPublicKeyFile = (Join-Path $env:USERPROFILE '.ssh\id_rsa.pub'),

    [string]$AvailabilityDomain = '',

    [string]$Prefix = 'wug-test',

    [string]$StateFile = (Join-Path (Join-Path $env:TEMP 'WhatsUpGoldPS') 'oci-test-state.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure temp directory exists
$stateDir = Split-Path $StateFile -Parent
if (-not (Test-Path $stateDir)) { New-Item -Path $stateDir -ItemType Directory -Force | Out-Null }
$env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING = 'True'

# ---- Locate OCI CLI ----------------------------------------------------------

$script:OciExe = $null
foreach ($candidate in @(
    (Get-Command oci -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
    (Join-Path $env:USERPROFILE 'bin\oci.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\*\Scripts\oci.exe'),
    'C:\ProgramData\chocolatey\bin\oci.exe'
)) {
    if ($candidate -and (Test-Path $candidate)) { $script:OciExe = $candidate; break }
}
if (-not $script:OciExe) {
    throw "OCI CLI not found. Install it: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm"
}
Write-Host "OCI CLI: $script:OciExe" -ForegroundColor DarkGray

# ---- Helpers ----------------------------------------------------------------

function Invoke-Oci {
    param([string[]]$OciArgs)
    $rawOutput = & $script:OciExe @OciArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "OCI CLI error: $rawOutput" }
    # Filter out WARNING/INFO lines from stderr that break JSON parsing
    $jsonLines = $rawOutput | Where-Object {
        $line = "$_"
        $line -notmatch '^WARNING:' -and $line -notmatch '^INFO:' -and $line -ne ''
    }
    if ($jsonLines) { return ($jsonLines -join "`n" | ConvertFrom-Json) }
}

function Write-Step { param([string]$Msg) Write-Host "`n>> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "  OK: $Msg" -ForegroundColor Green }
function Write-Info { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor Gray }

function Save-State {
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
}

function Wait-ForState {
    param(
        [string]$ResourceType,
        [string]$Id,
        [string]$TargetState,
        [int]$TimeoutSec = 600
    )
    $elapsed = 0
    while ($elapsed -lt $TimeoutSec) {
        $current = switch ($ResourceType) {
            'instance' { (Invoke-Oci compute, instance, get, --instance-id, $Id).data.'lifecycle-state' }
            'database' { (Invoke-Oci db, autonomous-database, get, --autonomous-database-id, $Id).data.'lifecycle-state' }
            'lb'       { (Invoke-Oci lb, load-balancer, get, --load-balancer-id, $Id).data.'lifecycle-state' }
        }
        if ($current -eq $TargetState) { return }
        Write-Info "  Waiting for $ResourceType -> $TargetState (currently: $current)..."
        Start-Sleep -Seconds 15
        $elapsed += 15
    }
    throw "Timed out waiting for $ResourceType $Id -> $TargetState after ${TimeoutSec}s"
}

# ---- Preflight checks -------------------------------------------------------

# Validate SSH key
if (-not (Test-Path $SshPublicKeyFile)) {
    Write-Warning "SSH public key not found at $SshPublicKeyFile -- VMs will be created without SSH access."
    $sshKey = $null
}
else {
    $sshKey = (Get-Content $SshPublicKeyFile -Raw).Trim()
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  WUG OCI Test Resource Setup" -ForegroundColor Cyan
Write-Host "  (Always Free tier -- `$0 cost)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Compartment : $CompartmentId" -ForegroundColor White
Write-Host "Prefix      : $Prefix" -ForegroundColor White
Write-Host "State file  : $StateFile" -ForegroundColor White
Write-Host ""

$tags = '{"wug-test":"true"}'
$state = [ordered]@{
    CreatedAt     = (Get-Date -Format o)
    CompartmentId = $CompartmentId
    Prefix        = $Prefix
    Resources     = [ordered]@{}
}

# ---- Availability Domain -----------------------------------------------------

Write-Step "Resolving Availability Domains"
$allAds = (Invoke-Oci iam, availability-domain, list, --compartment-id, $CompartmentId).data
if (-not $AvailabilityDomain) {
    $AvailabilityDomain = $allAds[0].name
    Write-Info "Primary AD: $AvailabilityDomain (will try all $($allAds.Count) ADs if out of capacity)"
}
else {
    Write-Info "Using: $AvailabilityDomain"
}
$state.AvailabilityDomain = $AvailabilityDomain

# ---- Platform Image (aarch64, Oracle Linux for A1.Flex) ----------------------

Write-Step "Finding latest Oracle Linux aarch64 image for VM.Standard.A1.Flex"
$imgResp = Invoke-Oci compute, image, list, `
    --compartment-id, $CompartmentId, `
    --operating-system, 'Oracle Linux', `
    --shape, 'VM.Standard.A1.Flex', `
    --sort-by, 'TIMECREATED', `
    --sort-order, 'DESC', `
    --limit, '1'
if (-not $imgResp.data -or $imgResp.data.Count -eq 0) {
    throw "No Oracle Linux aarch64 image found for VM.Standard.A1.Flex in this region."
}
$imageId = $imgResp.data[0].id
$state.Resources['ImageId'] = $imageId
Write-Ok "$($imgResp.data[0].'display-name')"

# ---- VCN ---------------------------------------------------------------------

Write-Step "Creating VCN"
$vcn = (Invoke-Oci network, vcn, create, `
    --compartment-id, $CompartmentId, `
    --cidr-block, '10.0.0.0/16', `
    --display-name, "$Prefix-vcn", `
    --dns-label, 'wugtestvcn', `
    --freeform-tags, $tags `
).data
$state.Resources['VcnId'] = $vcn.id
Write-Ok "VCN: $($vcn.id)"
Save-State

# Internet Gateway
Write-Step "Creating Internet Gateway"
$igw = (Invoke-Oci network, internet-gateway, create, `
    --compartment-id, $CompartmentId, `
    --vcn-id, $vcn.id, `
    --is-enabled, 'true', `
    --display-name, "$Prefix-igw", `
    --freeform-tags, $tags `
).data
$state.Resources['IgwId'] = $igw.id
Write-Ok "IGW: $($igw.id)"
Save-State

# Route Table
Write-Step "Creating Route Table"
$routeRules = '[{"cidrBlock":"0.0.0.0/0","networkEntityId":"' + $igw.id + '"}]'
$rt = (Invoke-Oci network, route-table, create, `
    --compartment-id, $CompartmentId, `
    --vcn-id, $vcn.id, `
    --display-name, "$Prefix-rt", `
    --route-rules, $routeRules, `
    --freeform-tags, $tags `
).data
$state.Resources['RouteTableId'] = $rt.id
Write-Ok "Route Table: $($rt.id)"
Save-State

# Security List (SSH + HTTP + HTTPS + ICMP inbound, all outbound)
Write-Step "Creating Security List"
$ingressRules = @'
[
  {"source":"0.0.0.0/0","protocol":"6","isStateless":false,
   "tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
  {"source":"0.0.0.0/0","protocol":"6","isStateless":false,
   "tcpOptions":{"destinationPortRange":{"min":80,"max":80}}},
  {"source":"0.0.0.0/0","protocol":"6","isStateless":false,
   "tcpOptions":{"destinationPortRange":{"min":443,"max":443}}},
  {"source":"0.0.0.0/0","protocol":"1","isStateless":false,
   "icmpOptions":{"type":3,"code":4}}
]
'@
$egressRules = '[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]'

$sl = (Invoke-Oci network, security-list, create, `
    --compartment-id, $CompartmentId, `
    --vcn-id, $vcn.id, `
    --display-name, "$Prefix-sl", `
    --ingress-security-rules, $ingressRules, `
    --egress-security-rules, $egressRules, `
    --freeform-tags, $tags `
).data
$state.Resources['SecurityListId'] = $sl.id
Write-Ok "Security List: $($sl.id)"
Save-State

# Public Subnet
Write-Step "Creating Public Subnet"
$subnet = (Invoke-Oci network, subnet, create, `
    --compartment-id, $CompartmentId, `
    --vcn-id, $vcn.id, `
    --cidr-block, '10.0.1.0/24', `
    --display-name, "$Prefix-subnet-pub", `
    --dns-label, 'wugtestpub', `
    --route-table-id, $rt.id, `
    --security-list-ids, ('["' + $sl.id + '"]'), `
    --prohibit-public-ip-on-vnic, 'false', `
    --freeform-tags, $tags `
).data
$state.Resources['SubnetId'] = $subnet.id
Write-Ok "Subnet: $($subnet.id)"
Save-State

# ---- Compute: Ampere A1 Flex VM (Always Free) -------------------------------

Write-Step "Creating Ampere A1 Flex VM (VM.Standard.A1.Flex, 1 OCPU / 6 GB)"
$vmMetadata = '{}'
if ($sshKey) {
    $escapedKey = $sshKey -replace '"', '\"'
    $vmMetadata = '{"ssh_authorized_keys":"' + $escapedKey + '"}'
}

$shapeConfig = '{"ocpus":1,"memoryInGBs":6}'

# Try each AD in order -- "Out of host capacity" is common for Always Free
$adOrder = @($AvailabilityDomain) + ($allAds | ForEach-Object { $_.name } | Where-Object { $_ -ne $AvailabilityDomain })
$vm = $null
foreach ($tryAd in $adOrder) {
    Write-Info "Trying AD: $tryAd"
    try {
        $vm = (Invoke-Oci compute, instance, launch, `
            --compartment-id, $CompartmentId, `
            --availability-domain, $tryAd, `
            --shape, 'VM.Standard.A1.Flex', `
            --shape-config, $shapeConfig, `
            --display-name, "$Prefix-vm-a1", `
            --image-id, $imageId, `
            --subnet-id, $subnet.id, `
            --metadata, $vmMetadata, `
            --assign-public-ip, 'true', `
            --freeform-tags, $tags `
        ).data
        $AvailabilityDomain = $tryAd
        $state.AvailabilityDomain = $tryAd
        break
    }
    catch {
        if ("$_" -match 'Out of host capacity') {
            Write-Info "AD $tryAd is out of capacity, trying next..."
            continue
        }
        throw
    }
}
if (-not $vm) {
    throw "All availability domains are out of host capacity for VM.Standard.A1.Flex. Try again later."
}
$state.Resources['VmMicroId'] = $vm.id
Write-Ok "VM: $($vm.id) (AD: $AvailabilityDomain)"
Save-State

# ---- Autonomous Database (Always Free) --------------------------------------

Write-Step "Creating Autonomous Database (Always Free, OLTP)"
$dbPassword = 'WugTest_' + ([System.Guid]::NewGuid().ToString('N').Substring(0, 8)) + '1A!'

$adb = (Invoke-Oci db, autonomous-database, create, `
    --compartment-id, $CompartmentId, `
    --display-name, "$Prefix-adb", `
    --db-name, 'WUGTEST', `
    --admin-password, $dbPassword, `
    --cpu-core-count, '1', `
    --data-storage-size-in-tbs, '1', `
    --is-free-tier, 'true', `
    --db-workload, 'OLTP', `
    --freeform-tags, $tags `
).data
$state.Resources['AutonomousDbId'] = $adb.id
$state.Resources['AutonomousDbPassword'] = $dbPassword
Write-Ok "Autonomous DB: $($adb.id)"
Write-Info "Admin password saved to state file -- keep it safe!"
Save-State

# ---- Wait for VM to be RUNNING before creating LB ---------------------------

Write-Step "Waiting for VM to reach RUNNING state..."
Wait-ForState -ResourceType instance -Id $vm.id -TargetState RUNNING -TimeoutSec 600
Write-Ok "VM is RUNNING"

# Get VM's private IP for LB backend
$vnicAttachments = Invoke-Oci compute, vnic-attachment, list, `
    --compartment-id, $CompartmentId, `
    --instance-id, $vm.id
$vnicId = $vnicAttachments.data[0].'vnic-id'
$vnic = Invoke-Oci network, vnic, get, --vnic-id, $vnicId
$vmPrivateIp = $vnic.data.'private-ip'
$vmPublicIp = $vnic.data.'public-ip'
$state.Resources['VmPrivateIp'] = $vmPrivateIp
$state.Resources['VmPublicIp'] = $vmPublicIp
Write-Info "VM IPs: public=$vmPublicIp, private=$vmPrivateIp"
Save-State

# ---- Load Balancer (Flexible, 10 Mbps -- Always Free) -----------------------

Write-Step "Creating Flexible Load Balancer (10 Mbps)"

# Build LB creation JSON for complex parameters
$lbBackendSets = @"
{"wug-test-bs":{"policy":"ROUND_ROBIN","healthChecker":{"protocol":"TCP","port":80,"retries":3,"intervalInMillis":10000,"timeoutInMillis":3000},"backends":[{"ipAddress":"$vmPrivateIp","port":80,"weight":1}]}}
"@

$lbListeners = @"
{"wug-test-listener":{"protocol":"HTTP","port":80,"defaultBackendSetName":"wug-test-bs"}}
"@

$lbShapeDetails = '{"minimumBandwidthInMbps":10,"maximumBandwidthInMbps":10}'

$lb = (Invoke-Oci lb, load-balancer, create, `
    --compartment-id, $CompartmentId, `
    --display-name, "$Prefix-lb", `
    --shape-name, 'flexible', `
    --shape-details, $lbShapeDetails, `
    --subnet-ids, ('["' + $subnet.id + '"]'), `
    --backend-sets, $lbBackendSets, `
    --listeners, $lbListeners, `
    --is-private, 'false', `
    --freeform-tags, $tags `
).data
$state.Resources['LoadBalancerId'] = $lb.id
Write-Ok "Load Balancer: $($lb.id)"
Save-State

# Wait for LB to be ACTIVE
Write-Step "Waiting for Load Balancer to reach ACTIVE state..."
Wait-ForState -ResourceType lb -Id $lb.id -TargetState ACTIVE -TimeoutSec 600

# Get LB IP
$lbDetail = (Invoke-Oci lb, load-balancer, get, --load-balancer-id, $lb.id).data
$lbIp = 'N/A'
if ($lbDetail.'ip-addresses' -and $lbDetail.'ip-addresses'.Count -gt 0) {
    $lbIp = $lbDetail.'ip-addresses'[0].'ip-address'
    $state.Resources['LoadBalancerIp'] = $lbIp
}
Write-Ok "Load Balancer IP: $lbIp"
Save-State

# ---- Wait for Autonomous DB -------------------------------------------------

Write-Step "Waiting for Autonomous Database to reach AVAILABLE state..."
Wait-ForState -ResourceType database -Id $adb.id -TargetState AVAILABLE -TimeoutSec 900
Write-Ok "Autonomous DB is AVAILABLE"

# ---- Summary -----------------------------------------------------------------

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  All resources created successfully!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Resources created:" -ForegroundColor White
$state.Resources.GetEnumerator() | ForEach-Object {
    if ($_.Key -notmatch 'Password') {
        Write-Host ("  {0,-25} {1}" -f "$($_.Key):", $_.Value) -ForegroundColor White
    }
}
Write-Host ""
Write-Host "State saved to: $StateFile" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Run OCI discovery E2E test:" -ForegroundColor White
Write-Host "     .\helpers\test\Invoke-WUGDiscoveryE2ETest.ps1 -IncludeProvider OCI" -ForegroundColor DarkGray
Write-Host "  2. Or run the OCI dashboard directly:" -ForegroundColor White
Write-Host "     .\helpers\oci\Get-OCIDashboard.ps1" -ForegroundColor DarkGray
Write-Host "  3. When done, tear down:" -ForegroundColor White
Write-Host "     .\helpers\test\Teardown-OCITestResources.ps1" -ForegroundColor DarkGray
Write-Host ""

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA6FpjbBNKbOrqD
# f1DK/jqBg6Acq7R8SO6dCqdqCqDjOKCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCC843guBpynQsVKyls5piLuxhWE2t59er5dXvLTiFG8gTANBgkqhkiG9w0BAQEF
# AASCAgDAGTXhXUtAgcBEv28LwmbpiNHUb59UP5SBrtqs2/jLlfhvfLkc3YUgC8e5
# iOEriYvRPpSDB+tYnJoIqfx1NBWXmOQqVeuWpRx3AWto9kxR5ovid28675oKLJDb
# wCuauRbzMboxf4BKTE4oQuVM+5DavdhFP/3d/7Mg8J/+2aowxvNXY2ZhpnjR2ZRU
# qbb3ORp5mzElsEp/O8PSfHIDXlIKGA5S1nZbWTzgL9k6+SxKtvimRq/xwV5oTt3e
# NqYMUScnfFUyPJipNW4HFrc2nd9julZcobwiLitvQekEqpkMH7Tp3nbshimpNzz1
# /OlOXVXDQ6DRA6I/D7T5hCM8m018WoV1i01JGwW1ZiFcKrmwuikVaBrcfQAJLURK
# r0sUnrYE/nWAQwuyKPUP2wJAkXZ1WhfyrS1KYxnKs4mLo0BIiBCUw0TsLAmUk3HS
# ImfDihWJ3IGH1GJJY++fH/MV8nwemT3p7QjwY0ATQA3EgZ7Q16nvErQdh0u8CtrI
# HhPC9z0gcO0tYlpqz1QOVyfHA3rWimlnIPF0Ay1PnjrN8rA2Sbnk61v1UmRXi4Op
# HzmbDGSHR9e8k658U5gDAAZtdGazawkUm7yPSjy5w+T16CLfbcNEW9g/tiF7P8sV
# wokZqpdfgHuewxrA3btrRGGMBb+0DAHnl8NAeDlEOS93IfwfTKGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MjUxOTIzMDFaMC8GCSqGSIb3DQEJBDEiBCAQA9/C
# BNvkq8iSD45SD0Ro7NH4doOhj9G2ra3ssPtNwzANBgkqhkiG9w0BAQEFAASCAgAe
# DqkrotGVr9JKDqAqlapyUV82F00lPYbVc+w1hVGh/dtoI8bnUOT9h9qGKyTPkeI0
# 8ZWDlzGk87ebXikMQ9CX7d9hgoSZMn0VlMDirClo30UMdPu0ZwhQ4pyDqO6DgDRH
# parBjGZTKm287eA8fiPq3tUlowHfWXB4jyjD7FbRrl3/Nd6pTlfu4X9GawXo/fyc
# Cn2rQQCysVEj2i0gxEj0TaliVjwptvdOntIrYNPADNKmxyQi/opk7tpR9MMdclTG
# ljjE2I4YMKeLfeUJtCrBal9LIXHbDfexAtp2yYGbz2fex4sWHweQfbGuErDvQMSo
# aHesthH/uk6WLOYtWyUPmMK/3QhjofcVo5EvI9SsgEbA0FgBFe1ZKAWijLRqefzv
# RcIkWwPwanWXT4P9df911x7jvErDgC7e/FkU9F1P2V/1weFzOvFhgMUrLL2oO132
# fp1jxgGlPvyNPihDAkaApJik1ctJvYRxYXVPlQrKeXOizB/TfEcW5sELDvofQJuI
# 8fgrwHaFTPYPrKngSM/Anzhyr9gOcErcowyVmt2aUk8TzIWOCTv8JZXXVg8x0Sfw
# eHIj7dbDstafEGqjUb/9x47OFDiFXfeB2SXXU65RnO/x67wwS33aEvGg1gjXXqUX
# RXF4R46PuWdEbrdmZx/4hDiB5ADRsFMQ08k8gGYP0A==
# SIG # End signature block
