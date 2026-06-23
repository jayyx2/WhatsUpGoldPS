function Get-SNMPTableSharp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [string]$BaseOid,

        [string]$Community = 'public',

        [ValidateSet('V1', 'V2')]
        [string]$SnmpVersion = 'V2',

        [int]$Port = 161,
        [int]$Timeout = 5000
    )

    if (-not ('Lextm.SharpSnmpLib.Variable' -as [type])) {
        throw 'SharpSnmpLib is not loaded. Run Import-SharpSnmpLib first.'
    }

    $ip = [System.Net.IPAddress]::Parse($Target)
    $endpoint = [System.Net.IPEndPoint]::new($ip, $Port)
    $communityObj = [Lextm.SharpSnmpLib.OctetString]::new($Community)
    $rootOid = [Lextm.SharpSnmpLib.ObjectIdentifier]::new($BaseOid)

    $results = [System.Collections.Generic.List[Lextm.SharpSnmpLib.Variable]]::new()

    $versionCode =
        switch ($SnmpVersion) {
            'V1' { [Lextm.SharpSnmpLib.VersionCode]::V1 }
            'V2' { [Lextm.SharpSnmpLib.VersionCode]::V2 }
        }

    [Lextm.SharpSnmpLib.Messaging.Messenger]::Walk(
        $versionCode,
        $endpoint,
        $communityObj,
        $rootOid,
        $results,
        $Timeout,
        [Lextm.SharpSnmpLib.Messaging.WalkMode]::WithinSubtree
    )

    foreach ($item in $results) {
        [PSCustomObject]@{
            OID   = $item.Id.ToString()
            Type  = $item.Data.TypeCode.ToString()
            Value = $item.Data.ToString()
        }
    }
}
