# SNMPv3 Engine ID Discovery Cache
# Caches the discovery report per target endpoint to avoid repeated
# cryptographic handshakes. This is critical for slow devices (e.g. old
# Cisco Call Manager) where re-discovery on every request kills performance.

if (-not (Get-Variable -Name SNMPv3EngineCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:SNMPv3EngineCache = @{}
}

function Get-SNMPv3CachedDiscovery {
    <#
    .SYNOPSIS
        Returns a cached SNMPv3 discovery report for the given endpoint, or performs
        discovery and caches it if no valid entry exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Target,

        [int]$Port = 161,

        [int]$Timeout = 10000
    )

    $cacheKey = "${Target}:${Port}"

    if ($script:SNMPv3EngineCache.ContainsKey($cacheKey)) {
        $entry = $script:SNMPv3EngineCache[$cacheKey]
        # Cache entries expire after 5 minutes to handle engine time drift
        $age = (Get-Date) - $entry.Timestamp
        if ($age.TotalSeconds -lt 300) {
            Write-Verbose "SNMPv3 engine cache HIT for $cacheKey (age: $([int]$age.TotalSeconds)s)"
            return $entry.Report
        }
        Write-Verbose "SNMPv3 engine cache EXPIRED for $cacheKey (age: $([int]$age.TotalSeconds)s)"
        $script:SNMPv3EngineCache.Remove($cacheKey)
    }

    Write-Verbose "SNMPv3 engine cache MISS for $cacheKey -- performing discovery"
    $discovery = [Lextm.SharpSnmpLib.Messaging.Messenger]::GetNextDiscovery(
        [Lextm.SharpSnmpLib.SnmpType]::GetRequestPdu
    )
    $endpoint = New-Object System.Net.IPEndPoint (
        [System.Net.IPAddress]::Parse($Target)
    ), $Port

    $reportMsg = $discovery.GetResponse($Timeout, $endpoint)

    $script:SNMPv3EngineCache[$cacheKey] = @{
        Report    = $reportMsg
        Timestamp = Get-Date
    }

    return $reportMsg
}

function Clear-SNMPv3EngineCache {
    <#
    .SYNOPSIS
        Clears the SNMPv3 engine discovery cache. Optionally clear only a specific target.
    #>
    [CmdletBinding()]
    param(
        [string]$Target,
        [int]$Port = 161
    )

    if ($Target) {
        $cacheKey = "${Target}:${Port}"
        if ($script:SNMPv3EngineCache.ContainsKey($cacheKey)) {
            $script:SNMPv3EngineCache.Remove($cacheKey)
            Write-Verbose "Cleared SNMPv3 engine cache for $cacheKey"
        }
    } else {
        $script:SNMPv3EngineCache = @{}
        Write-Verbose 'Cleared entire SNMPv3 engine cache'
    }
}

function Get-SNMPv3EngineCacheStatus {
    <#
    .SYNOPSIS
        Returns current cache entries for diagnostics.
    #>
    [CmdletBinding()]
    param()

    foreach ($key in $script:SNMPv3EngineCache.Keys) {
        $entry = $script:SNMPv3EngineCache[$key]
        $age = (Get-Date) - $entry.Timestamp
        [PSCustomObject]@{
            Endpoint  = $key
            AgeSeconds = [int]$age.TotalSeconds
            Expired   = ($age.TotalSeconds -ge 300)
        }
    }
}
