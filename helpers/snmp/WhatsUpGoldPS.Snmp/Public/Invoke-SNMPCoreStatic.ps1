function Convert-SNMPByteTool {
    [CmdletBinding(DefaultParameterSetName = 'FromBytes')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'FromBytes')]
        [byte[]]$Bytes,

        [Parameter(ParameterSetName = 'FromBytes')]
        [int]$Length,

        [Parameter(Mandatory, ParameterSetName = 'FromEnumerable')]
        [System.Collections.Generic.IEnumerable[byte]]$InputBytes,

        [Parameter(Mandatory)]
        [Type]$Type
    )

    if ($PSCmdlet.ParameterSetName -eq 'FromEnumerable') {
        return [Lextm.SharpSnmpLib.ByteTool]::Convert($InputBytes, $Type)
    }

    if ($PSBoundParameters.ContainsKey('Length')) {
        return [Lextm.SharpSnmpLib.ByteTool]::Convert($Bytes, $Length, $Type)
    }

    return [Lextm.SharpSnmpLib.ByteTool]::Convert($Bytes, $Type)
}

function Convert-SNMPDecimal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [int]$Offset
    )

    return [Lextm.SharpSnmpLib.ByteTool]::ConvertDecimal($Text, $Offset)
}

function Pack-SNMPMessageBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [byte[]]$Body,

        [Parameter(Mandatory)]
        [byte]$LengthByte
    )

    return [Lextm.SharpSnmpLib.ByteTool]::PackMessage($Body, $LengthByte)
}

function New-SNMPData {
    [CmdletBinding(DefaultParameterSetName = 'FromBytesOffset')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'FromBytesOffset')]
        [byte[]]$Bytes,

        [Parameter(Mandatory, ParameterSetName = 'FromBytesOffset')]
        [int]$Offset,

        [Parameter(Mandatory, ParameterSetName = 'FromBytesLength')]
        [byte[]]$BytesWithLength,

        [Parameter(Mandatory, ParameterSetName = 'FromBytesLength')]
        [int]$Length,

        [Parameter(Mandatory, ParameterSetName = 'FromStream')]
        [System.IO.Stream]$Stream
    )

    switch ($PSCmdlet.ParameterSetName) {
        'FromBytesOffset' { return [Lextm.SharpSnmpLib.DataFactory]::CreateSnmpData($Bytes, $Offset) }
        'FromBytesLength' { return [Lextm.SharpSnmpLib.DataFactory]::CreateSnmpData($BytesWithLength, $Length) }
        'FromStream' { return [Lextm.SharpSnmpLib.DataFactory]::CreateSnmpData($Stream) }
    }
}

function ConvertTo-SNMPObjectIdentifier {
    [CmdletBinding(DefaultParameterSetName = 'FromString')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'FromString')]
        [string]$Text,

        [Parameter(Mandatory, ParameterSetName = 'FromUIntArray')]
        [uint32[]]$Ids
    )

    if ($PSCmdlet.ParameterSetName -eq 'FromUIntArray') {
        return [Lextm.SharpSnmpLib.ObjectIdentifier]::Convert($Ids)
    }

    return [Lextm.SharpSnmpLib.ObjectIdentifier]::Convert($Text)
}

function New-SNMPObjectIdentifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [uint32[]]$Ids
    )

    return [Lextm.SharpSnmpLib.ObjectIdentifier]::Create($Ids)
}

function AddTo-SNMPObjectIdentifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [uint32[]]$Ids,

        [Parameter(Mandatory)]
        [Lextm.SharpSnmpLib.ObjectIdentifier]$Value
    )

    [Lextm.SharpSnmpLib.ObjectIdentifier]::AppendTo($Ids, $Value)
}

function Test-SNMPOctetStringNullOrEmpty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Lextm.SharpSnmpLib.OctetString]$Value
    )

    return [Lextm.SharpSnmpLib.OctetString]::IsNullOrEmpty($Value)
}

function Convert-SNMPDataToBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Lextm.SharpSnmpLib.ISnmpData]$Data
    )

    return [Lextm.SharpSnmpLib.SnmpDataExtension]::ToBytes($Data)
}

function ConvertTo-SNMPIPAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Lextm.SharpSnmpLib.IP]$Ip
    )

    return [Lextm.SharpSnmpLib.Helper]::ToIPAddress($Ip)
}

function ConvertTo-SNMPPhysicalAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Lextm.SharpSnmpLib.OctetString]$OctetString
    )

    return [Lextm.SharpSnmpLib.Helper]::ToPhysicalAddress($OctetString)
}
