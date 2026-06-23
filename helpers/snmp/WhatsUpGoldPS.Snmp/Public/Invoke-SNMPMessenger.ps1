function Get-SNMP {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Target,
        [object]$Version = 'V2',
        [string]$Community = 'public',
        [Parameter(Mandatory)] [object[]]$Variables,
        [int]$Port = 161,
        [int]$Timeout = 5000
    )

    return [Lextm.SharpSnmpLib.Messaging.Messenger]::Get(
        (ConvertTo-SnmpVersionCode -Version $Version),
        (ConvertTo-SnmpIpEndPoint -Target $Target -Port $Port),
        (ConvertTo-SnmpOctetString -Value $Community),
        (ConvertTo-SnmpVariableList -Variables $Variables),
        $Timeout
    )
}

function Get-SNMPAsync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Target,
        [object]$Version = 'V2',
        [string]$Community = 'public',
        [Parameter(Mandatory)] [object[]]$Variables,
        [int]$Port = 161,
        [switch]$Wait
    )

    $task = [Lextm.SharpSnmpLib.Messaging.Messenger]::GetAsync(
        (ConvertTo-SnmpVersionCode -Version $Version),
        (ConvertTo-SnmpIpEndPoint -Target $Target -Port $Port),
        (ConvertTo-SnmpOctetString -Value $Community),
        (ConvertTo-SnmpVariableList -Variables $Variables)
    )

    return Wait-SnmpTaskResult -Task $task -Wait:$Wait
}

function Set-SNMP {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Target,
        [object]$Version = 'V2',
        [string]$Community = 'public',
        [Parameter(Mandatory)] [object[]]$Variables,
        [int]$Port = 161,
        [int]$Timeout = 5000
    )

    return [Lextm.SharpSnmpLib.Messaging.Messenger]::Set(
        (ConvertTo-SnmpVersionCode -Version $Version),
        (ConvertTo-SnmpIpEndPoint -Target $Target -Port $Port),
        (ConvertTo-SnmpOctetString -Value $Community),
        (ConvertTo-SnmpVariableList -Variables $Variables),
        $Timeout
    )
}

function Set-SNMPAsync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Target,
        [object]$Version = 'V2',
        [string]$Community = 'public',
        [Parameter(Mandatory)] [object[]]$Variables,
        [int]$Port = 161,
        [switch]$Wait
    )

    $task = [Lextm.SharpSnmpLib.Messaging.Messenger]::SetAsync(
        (ConvertTo-SnmpVersionCode -Version $Version),
        (ConvertTo-SnmpIpEndPoint -Target $Target -Port $Port),
        (ConvertTo-SnmpOctetString -Value $Community),
        (ConvertTo-SnmpVariableList -Variables $Variables)
    )

    return Wait-SnmpTaskResult -Task $task -Wait:$Wait
}

function Invoke-SNMPWalk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Target,
        [Parameter(Mandatory)] [object]$Table,
        [object]$Version = 'V2',
        [string]$Community = 'public',
        [int]$Port = 161,
        [int]$Timeout = 5000,
        [object]$WalkMode = 'WithinSubtree'
    )

    $list = [System.Collections.Generic.List[Lextm.SharpSnmpLib.Variable]]::new()
    $count = [Lextm.SharpSnmpLib.Messaging.Messenger]::Walk(
        (ConvertTo-SnmpVersionCode -Version $Version),
        (ConvertTo-SnmpIpEndPoint -Target $Target -Port $Port),
        (ConvertTo-SnmpOctetString -Value $Community),
        (ConvertTo-SnmpObjectIdentifierInternal -Value $Table),
        $list,
        $Timeout,
        (ConvertTo-SnmpWalkMode -Mode $WalkMode)
    )

    [PSCustomObject]@{ Count = $count; Variables = $list }
}

function Invoke-SNMPWalkAsync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Target,
        [Parameter(Mandatory)] [object]$Table,
        [object]$Version = 'V2',
        [string]$Community = 'public',
        [int]$Port = 161,
        [object]$WalkMode = 'WithinSubtree',
        [switch]$Wait
    )

    $list = [System.Collections.Generic.List[Lextm.SharpSnmpLib.Variable]]::new()
    $task = [Lextm.SharpSnmpLib.Messaging.Messenger]::WalkAsync(
        (ConvertTo-SnmpVersionCode -Version $Version),
        (ConvertTo-SnmpIpEndPoint -Target $Target -Port $Port),
        (ConvertTo-SnmpOctetString -Value $Community),
        (ConvertTo-SnmpObjectIdentifierInternal -Value $Table),
        $list,
        (ConvertTo-SnmpWalkMode -Mode $WalkMode)
    )

    if ($Wait) {
        $count = $task.GetAwaiter().GetResult()
        return [PSCustomObject]@{ Count = $count; Variables = $list }
    }

    return [PSCustomObject]@{ Task = $task; Variables = $list }
}

function Invoke-SNMPBulkWalk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Target,
        [Parameter(Mandatory)] [object]$Table,
        [object]$Version = 'V2',
        [string]$Community = 'public',
        [string]$ContextName = '',
        [int]$Port = 161,
        [int]$Timeout = 5000,
        [int]$MaxRepetitions = 10,
        [object]$WalkMode = 'WithinSubtree',
        [Lextm.SharpSnmpLib.Security.IPrivacyProvider]$Privacy = $null,
        [Lextm.SharpSnmpLib.Messaging.ISnmpMessage]$Report = $null
    )

    $list = [System.Collections.Generic.List[Lextm.SharpSnmpLib.Variable]]::new()
    $count = [Lextm.SharpSnmpLib.Messaging.Messenger]::BulkWalk(
        (ConvertTo-SnmpVersionCode -Version $Version),
        (ConvertTo-SnmpIpEndPoint -Target $Target -Port $Port),
        (ConvertTo-SnmpOctetString -Value $Community),
        (ConvertTo-SnmpOctetString -Value $ContextName),
        (ConvertTo-SnmpObjectIdentifierInternal -Value $Table),
        $list,
        $Timeout,
        $MaxRepetitions,
        (ConvertTo-SnmpWalkMode -Mode $WalkMode),
        $Privacy,
        $Report
    )

    [PSCustomObject]@{ Count = $count; Variables = $list }
}

function Invoke-SNMPBulkWalkAsync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Target,
        [Parameter(Mandatory)] [object]$Table,
        [object]$Version = 'V2',
        [string]$Community = 'public',
        [string]$ContextName = '',
        [int]$Port = 161,
        [int]$MaxRepetitions = 10,
        [object]$WalkMode = 'WithinSubtree',
        [Lextm.SharpSnmpLib.Security.IPrivacyProvider]$Privacy = $null,
        [Lextm.SharpSnmpLib.Messaging.ISnmpMessage]$Report = $null,
        [switch]$Wait
    )

    $list = [System.Collections.Generic.List[Lextm.SharpSnmpLib.Variable]]::new()
    $task = [Lextm.SharpSnmpLib.Messaging.Messenger]::BulkWalkAsync(
        (ConvertTo-SnmpVersionCode -Version $Version),
        (ConvertTo-SnmpIpEndPoint -Target $Target -Port $Port),
        (ConvertTo-SnmpOctetString -Value $Community),
        (ConvertTo-SnmpOctetString -Value $ContextName),
        (ConvertTo-SnmpObjectIdentifierInternal -Value $Table),
        $list,
        $MaxRepetitions,
        (ConvertTo-SnmpWalkMode -Mode $WalkMode),
        $Privacy,
        $Report
    )

    if ($Wait) {
        $count = $task.GetAwaiter().GetResult()
        return [PSCustomObject]@{ Count = $count; Variables = $list }
    }

    return [PSCustomObject]@{ Task = $task; Variables = $list }
}

function Get-SNMPTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Target,
        [Parameter(Mandatory)] [object]$Table,
        [object]$Version = 'V2',
        [string]$Community = 'public',
        [int]$Port = 161,
        [int]$Timeout = 5000,
        [int]$MaxRepetitions = 10
    )

    return [Lextm.SharpSnmpLib.Messaging.Messenger]::GetTable(
        (ConvertTo-SnmpVersionCode -Version $Version),
        (ConvertTo-SnmpIpEndPoint -Target $Target -Port $Port),
        (ConvertTo-SnmpOctetString -Value $Community),
        (ConvertTo-SnmpObjectIdentifierInternal -Value $Table),
        $Timeout,
        $MaxRepetitions
    )
}

function Send-SNMPTrapV1 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Receiver,
        [Parameter(Mandatory)] [object]$Agent,
        [string]$Community = 'public',
        [Parameter(Mandatory)] [object]$Enterprise,
        [Lextm.SharpSnmpLib.GenericCode]$Generic = [Lextm.SharpSnmpLib.GenericCode]::ColdStart,
        [int]$Specific = 0,
        [uint32]$Timestamp = 0,
        [object[]]$Variables = @(),
        [int]$Port = 162
    )

    [Lextm.SharpSnmpLib.Messaging.Messenger]::SendTrapV1(
        (ConvertTo-SnmpEndPoint -Target $Receiver -Port $Port),
        ([System.Net.IPAddress]::Parse([string]$Agent)),
        (ConvertTo-SnmpOctetString -Value $Community),
        (ConvertTo-SnmpObjectIdentifierInternal -Value $Enterprise),
        $Generic,
        $Specific,
        $Timestamp,
        (ConvertTo-SnmpVariableList -Variables $Variables)
    )
}

function Send-SNMPTrapV1Async {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Receiver,
        [Parameter(Mandatory)] [object]$Agent,
        [string]$Community = 'public',
        [Parameter(Mandatory)] [object]$Enterprise,
        [Lextm.SharpSnmpLib.GenericCode]$Generic = [Lextm.SharpSnmpLib.GenericCode]::ColdStart,
        [int]$Specific = 0,
        [uint32]$Timestamp = 0,
        [object[]]$Variables = @(),
        [int]$Port = 162,
        [switch]$Wait
    )

    $task = [Lextm.SharpSnmpLib.Messaging.Messenger]::SendTrapV1Async(
        (ConvertTo-SnmpEndPoint -Target $Receiver -Port $Port),
        ([System.Net.IPAddress]::Parse([string]$Agent)),
        (ConvertTo-SnmpOctetString -Value $Community),
        (ConvertTo-SnmpObjectIdentifierInternal -Value $Enterprise),
        $Generic,
        $Specific,
        $Timestamp,
        (ConvertTo-SnmpVariableList -Variables $Variables)
    )

    return Wait-SnmpTaskResult -Task $task -Wait:$Wait
}

function Send-SNMPTrapV2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$RequestId,
        [Parameter(Mandatory)] [object]$Receiver,
        [object]$Version = 'V2',
        [string]$Community = 'public',
        [Parameter(Mandatory)] [object]$Enterprise,
        [uint32]$Timestamp = 0,
        [object[]]$Variables = @(),
        [int]$Port = 162
    )

    [Lextm.SharpSnmpLib.Messaging.Messenger]::SendTrapV2(
        $RequestId,
        (ConvertTo-SnmpVersionCode -Version $Version),
        (ConvertTo-SnmpEndPoint -Target $Receiver -Port $Port),
        (ConvertTo-SnmpOctetString -Value $Community),
        (ConvertTo-SnmpObjectIdentifierInternal -Value $Enterprise),
        $Timestamp,
        (ConvertTo-SnmpVariableList -Variables $Variables)
    )
}

function Send-SNMPTrapV2Async {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$RequestId,
        [Parameter(Mandatory)] [object]$Receiver,
        [object]$Version = 'V2',
        [string]$Community = 'public',
        [Parameter(Mandatory)] [object]$Enterprise,
        [uint32]$Timestamp = 0,
        [object[]]$Variables = @(),
        [int]$Port = 162,
        [switch]$Wait
    )

    $task = [Lextm.SharpSnmpLib.Messaging.Messenger]::SendTrapV2Async(
        $RequestId,
        (ConvertTo-SnmpVersionCode -Version $Version),
        (ConvertTo-SnmpEndPoint -Target $Receiver -Port $Port),
        (ConvertTo-SnmpOctetString -Value $Community),
        (ConvertTo-SnmpObjectIdentifierInternal -Value $Enterprise),
        $Timestamp,
        (ConvertTo-SnmpVariableList -Variables $Variables)
    )

    return Wait-SnmpTaskResult -Task $task -Wait:$Wait
}

function Send-SNMPInform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$RequestId,
        [Parameter(Mandatory)] [object]$Receiver,
        [object]$Version = 'V2',
        [string]$Community = 'public',
        [string]$ContextName = '',
        [Parameter(Mandatory)] [object]$Enterprise,
        [uint32]$Timestamp = 0,
        [object[]]$Variables = @(),
        [int]$Port = 162,
        [int]$Timeout = 5000,
        [Lextm.SharpSnmpLib.Security.IPrivacyProvider]$Privacy = $null,
        [Lextm.SharpSnmpLib.Messaging.ISnmpMessage]$Report = $null
    )

    [Lextm.SharpSnmpLib.Messaging.Messenger]::SendInform(
        $RequestId,
        (ConvertTo-SnmpVersionCode -Version $Version),
        (ConvertTo-SnmpIpEndPoint -Target $Receiver -Port $Port),
        (ConvertTo-SnmpOctetString -Value $Community),
        (ConvertTo-SnmpOctetString -Value $ContextName),
        (ConvertTo-SnmpObjectIdentifierInternal -Value $Enterprise),
        $Timestamp,
        (ConvertTo-SnmpVariableList -Variables $Variables),
        $Timeout,
        $Privacy,
        $Report
    )
}

function Send-SNMPInformAsync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$RequestId,
        [Parameter(Mandatory)] [object]$Receiver,
        [object]$Version = 'V2',
        [string]$Community = 'public',
        [string]$ContextName = '',
        [Parameter(Mandatory)] [object]$Enterprise,
        [uint32]$Timestamp = 0,
        [object[]]$Variables = @(),
        [int]$Port = 162,
        [Lextm.SharpSnmpLib.Security.IPrivacyProvider]$Privacy = $null,
        [Lextm.SharpSnmpLib.Messaging.ISnmpMessage]$Report = $null,
        [switch]$Wait
    )

    $task = [Lextm.SharpSnmpLib.Messaging.Messenger]::SendInformAsync(
        $RequestId,
        (ConvertTo-SnmpVersionCode -Version $Version),
        (ConvertTo-SnmpIpEndPoint -Target $Receiver -Port $Port),
        (ConvertTo-SnmpOctetString -Value $Community),
        (ConvertTo-SnmpOctetString -Value $ContextName),
        (ConvertTo-SnmpObjectIdentifierInternal -Value $Enterprise),
        $Timestamp,
        (ConvertTo-SnmpVariableList -Variables $Variables),
        $Privacy,
        $Report
    )

    return Wait-SnmpTaskResult -Task $task -Wait:$Wait
}

function Get-SNMPErrorMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$ObjectIdentifier
    )

    return [Lextm.SharpSnmpLib.Messaging.Messenger]::GetErrorMessage(
        (ConvertTo-SnmpObjectIdentifierInternal -Value $ObjectIdentifier)
    )
}

function Get-SNMPNextDiscovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Lextm.SharpSnmpLib.SnmpType]$Type
    )

    return [Lextm.SharpSnmpLib.Messaging.Messenger]::GetNextDiscovery($Type)
}

function Get-SNMPLibraryAvailability {
    [CmdletBinding()]
    param()

    return Get-SnmpLibraryAvailabilityInternal
}


# SIG # Begin signature block
# MIIr1gYJKoZIhvcNAQcCoIIrxzCCK8MCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU8fSFH4F2a5gLYGQeUjhq7cRm
# lsaggiUNMIIFbzCCBFegAwIBAgIQSPyTtGBVlI02p8mKidaUFjANBgkqhkiG9w0B
# AQwFADB7MQswCQYDVQQGEwJHQjEbMBkGA1UECAwSR3JlYXRlciBNYW5jaGVzdGVy
# MRAwDgYDVQQHDAdTYWxmb3JkMRowGAYDVQQKDBFDb21vZG8gQ0EgTGltaXRlZDEh
# MB8GA1UEAwwYQUFBIENlcnRpZmljYXRlIFNlcnZpY2VzMB4XDTIxMDUyNTAwMDAw
# MFoXDTI4MTIzMTIzNTk1OVowVjELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDEtMCsGA1UEAxMkU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IFJvb3QgUjQ2MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAjeeUEiIE
# JHQu/xYjApKKtq42haxH1CORKz7cfeIxoFFvrISR41KKteKW3tCHYySJiv/vEpM7
# fbu2ir29BX8nm2tl06UMabG8STma8W1uquSggyfamg0rUOlLW7O4ZDakfko9qXGr
# YbNzszwLDO/bM1flvjQ345cbXf0fEj2CA3bm+z9m0pQxafptszSswXp43JJQ8mTH
# qi0Eq8Nq6uAvp6fcbtfo/9ohq0C/ue4NnsbZnpnvxt4fqQx2sycgoda6/YDnAdLv
# 64IplXCN/7sVz/7RDzaiLk8ykHRGa0c1E3cFM09jLrgt4b9lpwRrGNhx+swI8m2J
# mRCxrds+LOSqGLDGBwF1Z95t6WNjHjZ/aYm+qkU+blpfj6Fby50whjDoA7NAxg0P
# OM1nqFOI+rgwZfpvx+cdsYN0aT6sxGg7seZnM5q2COCABUhA7vaCZEao9XOwBpXy
# bGWfv1VbHJxXGsd4RnxwqpQbghesh+m2yQ6BHEDWFhcp/FycGCvqRfXvvdVnTyhe
# Be6QTHrnxvTQ/PrNPjJGEyA2igTqt6oHRpwNkzoJZplYXCmjuQymMDg80EY2NXyc
# uu7D1fkKdvp+BRtAypI16dV60bV/AK6pkKrFfwGcELEW/MxuGNxvYv6mUKe4e7id
# FT/+IAx1yCJaE5UZkADpGtXChvHjjuxf9OUCAwEAAaOCARIwggEOMB8GA1UdIwQY
# MBaAFKARCiM+lvEH7OKvKe+CpX/QMKS0MB0GA1UdDgQWBBQy65Ka/zWWSC8oQEJw
# IDaRXBeF5jAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zATBgNVHSUE
# DDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEMGA1Ud
# HwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwuY29tb2RvY2EuY29tL0FBQUNlcnRpZmlj
# YXRlU2VydmljZXMuY3JsMDQGCCsGAQUFBwEBBCgwJjAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuY29tb2RvY2EuY29tMA0GCSqGSIb3DQEBDAUAA4IBAQASv6Hvi3Sa
# mES4aUa1qyQKDKSKZ7g6gb9Fin1SB6iNH04hhTmja14tIIa/ELiueTtTzbT72ES+
# BtlcY2fUQBaHRIZyKtYyFfUSg8L54V0RQGf2QidyxSPiAjgaTCDi2wH3zUZPJqJ8
# ZsBRNraJAlTH/Fj7bADu/pimLpWhDFMpH2/YGaZPnvesCepdgsaLr4CnvYFIUoQx
# 2jLsFeSmTD1sOXPUC4U5IOCFGmjhp0g4qdE2JXfBjRkWxYhMZn0vY86Y6GnfrDyo
# XZ3JHFuu2PMvdM+4fvbXg50RlmKarkUT2n/cR/vfw1Kf5gZV6Z2M8jpiUbzsJA8p
# 1FiAhORFe1rYMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG
# 9w0BAQwFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkw
# FwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1
# cmVkIElEIFJvb3QgQ0EwHhcNMjIwODAxMDAwMDAwWhcNMzExMTA5MjM1OTU5WjBi
# MQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3
# d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3Qg
# RzQwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC/5pBzaN675F1KPDAi
# MGkz7MKnJS7JIT3yithZwuEppz1Yq3aaza57G4QNxDAf8xukOBbrVsaXbR2rsnny
# yhHS5F/WBTxSD1Ifxp4VpX6+n6lXFllVcq9ok3DCsrp1mWpzMpTREEQQLt+C8weE
# 5nQ7bXHiLQwb7iDVySAdYyktzuxeTsiT+CFhmzTrBcZe7FsavOvJz82sNEBfsXpm
# 7nfISKhmV1efVFiODCu3T6cw2Vbuyntd463JT17lNecxy9qTXtyOj4DatpGYQJB5
# w3jHtrHEtWoYOAMQjdjUN6QuBX2I9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsD
# dV14Ztk6MUSaM0C/CNdaSaTC5qmgZ92kJ7yhTzm1EVgX9yRcRo9k98FpiHaYdj1Z
# XUJ2h4mXaXpI8OCiEhtmmnTK3kse5w5jrubU75KSOp493ADkRSWJtppEGSt+wJS0
# 0mFt6zPZxd9LBADMfRyVw4/3IbKyEbe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hk
# pjPRiQfhvbfmQ6QYuKZ3AeEPlAwhHbJUKSWJbOUOUlFHdL4mrLZBdd56rF+NP8m8
# 00ERElvlEFDrMcXKchYiCd98THU/Y+whX8QgUWtvsauGi0/C1kVfnSD8oR7FwI+i
# sX4KJpn15GkvmB0t9dmpsh3lGwIDAQABo4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB
# /zAdBgNVHQ4EFgQU7NfjgtJxXWRM3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAUReui
# r/SSy4IxLVGLp6chnfNtyA8wDgYDVR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0w
# azAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUF
# BzAChjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVk
# SURSb290Q0EuY3J0MEUGA1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAowCDAG
# BgRVHSAAMA0GCSqGSIb3DQEBDAUAA4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9
# mqyhhyzshV6pGrsi+IcaaVQi7aSId229GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxS
# A8hO0Cre+i1Wz/n096wwepqLsl7Uz9FDRJtDIeuWcqFItJnLnU+nBgMTdydE1Od/
# 6Fmo8L8vC6bp8jQ87PcDx4eo0kxAGTVGamlUsLihVo7spNU96LHc/RzY9HdaXFSM
# b++hUD38dglohJ9vytsgjTVgHAIDyyCwrFigDkBjxZgiwbJZ9VVrzyerbHbObyMt
# 9H5xaiNrIv8SuFQtJ37YOtnwtoeW/VvRXKwYw02fc7cBqZ9Xql4o4rmUMIIGGjCC
# BAKgAwIBAgIQYh1tDFIBnjuQeRUgiSEcCjANBgkqhkiG9w0BAQwFADBWMQswCQYD
# VQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMS0wKwYDVQQDEyRTZWN0
# aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAw
# WhcNMzYwMzIxMjM1OTU5WjBUMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGln
# byBMaW1pdGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcg
# Q0EgUjM2MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAmyudU/o1P45g
# BkNqwM/1f/bIU1MYyM7TbH78WAeVF3llMwsRHgBGRmxDeEDIArCS2VCoVk4Y/8j6
# stIkmYV5Gej4NgNjVQ4BYoDjGMwdjioXan1hlaGFt4Wk9vT0k2oWJMJjL9G//N52
# 3hAm4jF4UjrW2pvv9+hdPX8tbbAfI3v0VdJiJPFy/7XwiunD7mBxNtecM6ytIdUl
# h08T2z7mJEXZD9OWcJkZk5wDuf2q52PN43jc4T9OkoXZ0arWZVeffvMr/iiIROSC
# zKoDmWABDRzV/UiQ5vqsaeFaqQdzFf4ed8peNWh1OaZXnYvZQgWx/SXiJDRSAolR
# zZEZquE6cbcH747FHncs/Kzcn0Ccv2jrOW+LPmnOyB+tAfiWu01TPhCr9VrkxsHC
# 5qFNxaThTG5j4/Kc+ODD2dX/fmBECELcvzUHf9shoFvrn35XGf2RPaNTO2uSZ6n9
# otv7jElspkfK9qEATHZcodp+R4q2OIypxR//YEb3fkDn3UayWW9bAgMBAAGjggFk
# MIIBYDAfBgNVHSMEGDAWgBQy65Ka/zWWSC8oQEJwIDaRXBeF5jAdBgNVHQ4EFgQU
# DyrLIIcouOxvSK4rVKYpqhekzQwwDgYDVR0PAQH/BAQDAgGGMBIGA1UdEwEB/wQI
# MAYBAf8CAQAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwGwYDVR0gBBQwEjAGBgRVHSAA
# MAgGBmeBDAEEATBLBgNVHR8ERDBCMECgPqA8hjpodHRwOi8vY3JsLnNlY3RpZ28u
# Y29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYuY3JsMHsGCCsGAQUF
# BwEBBG8wbTBGBggrBgEFBQcwAoY6aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0
# aWdvUHVibGljQ29kZVNpZ25pbmdSb290UjQ2LnA3YzAjBggrBgEFBQcwAYYXaHR0
# cDovL29jc3Auc2VjdGlnby5jb20wDQYJKoZIhvcNAQEMBQADggIBAAb/guF3YzZu
# e6EVIJsT/wT+mHVEYcNWlXHRkT+FoetAQLHI1uBy/YXKZDk8+Y1LoNqHrp22AKMG
# xQtgCivnDHFyAQ9GXTmlk7MjcgQbDCx6mn7yIawsppWkvfPkKaAQsiqaT9DnMWBH
# VNIabGqgQSGTrQWo43MOfsPynhbz2Hyxf5XWKZpRvr3dMapandPfYgoZ8iDL2OR3
# sYztgJrbG6VZ9DoTXFm1g0Rf97Aaen1l4c+w3DC+IkwFkvjFV3jS49ZSc4lShKK6
# BrPTJYs4NG1DGzmpToTnwoqZ8fAmi2XlZnuchC4NPSZaPATHvNIzt+z1PHo35D/f
# 7j2pO1S8BCysQDHCbM5Mnomnq5aYcKCsdbh0czchOm8bkinLrYrKpii+Tk7pwL7T
# jRKLXkomm5D1Umds++pip8wH2cQpf93at3VDcOK4N7EwoIJB0kak6pSzEu4I64U6
# gZs7tS/dGNSljf2OSSnRr7KWzq03zl8l75jy+hOds9TWSenLbjBQUGR96cFr6lEU
# fAIEHVC1L68Y1GGxx4/eRI82ut83axHMViw1+sVpbPxg51Tbnio1lB93079WPFnY
# aOvfGAA0e0zcfF/M9gXr+korwQTh2Prqooq2bYNMvUoUKD85gnJ+t0smrWrb8dee
# 2CvYZXD5laGtaAxOfy/VKNmwuWuAh9kcMIIGPjCCBKagAwIBAgIQB5zg5NEUf4XN
# OXPPdi036zANBgkqhkiG9w0BAQwFADBUMQswCQYDVQQGEwJHQjEYMBYGA1UEChMP
# U2VjdGlnbyBMaW1pdGVkMSswKQYDVQQDEyJTZWN0aWdvIFB1YmxpYyBDb2RlIFNp
# Z25pbmcgQ0EgUjM2MB4XDTI2MDIwOTAwMDAwMFoXDTI5MDQyMTIzNTk1OVowVTEL
# MAkGA1UEBhMCVVMxFDASBgNVBAgMC0Nvbm5lY3RpY3V0MRcwFQYDVQQKDA5KYXNv
# biBBbGJlcmlubzEXMBUGA1UEAwwOSmFzb24gQWxiZXJpbm8wggIiMA0GCSqGSIb3
# DQEBAQUAA4ICDwAwggIKAoICAQDzemjeAdcmFpCOW+UwY9yNFVf6XhE6x2+hGOAR
# xsbfAKfnk/lqRKSchLUWD8RJjSS9wN/AZIO5sMzxN/9TSue9GQQrgY0gJ+JkgyIC
# Ll2Z78gTvVtTkLOXeuzJSS1ABLn5dfLTq90k9Q3jvYEo0EgBOTapdEA8T55vdzmQ
# aJ/hc9wphPs9zMAHtoeCnbUQJwqsDPv1e4gXW8PiTsaJacfu0VYxsj66ExDSBt6X
# v4Srz2+dNZX/LgQAAy3Y2a+YqfLyFm3/Oe2MNQbtdJ1SOx1t3hPApef/3da4mx5c
# 080C37bVvpPg2hbCmQQS+epeGAJSFUbKzohNZHR2GMeiBqxAPNPUe/k2QPQ8xqsh
# Yr/apiQGy+Hw8HrQ3siKvjs7c9S7xHcvEXHdCQWPieEtHgxBSAN19DfFXC3gMGmy
# m/QI7pSl8FHqgiS7ze/QifdFE2W9viPrWpo9HZ/iCjBLCeL+BoMe9rMRa/ful84q
# HbU4OS7n9sXevj4YWpjsRdqcfSzm4QSyxDMkbAh2SM1WThSrvQaR0B+7nxgfkmvN
# E5YtP+ixMp/fmzGFotrbZ+pSzj04VzIkGqKEVKuqtrt/heEmj5cVRSyOziVTIWq+
# p1uo6AbxC0yT5gDUjIw0kRQ3x0QnRm2bC/5HhCyTcvo2XLRelb8UBIxTPP22s7uq
# mIawOwIDAQABo4IBiTCCAYUwHwYDVR0jBBgwFoAUDyrLIIcouOxvSK4rVKYpqhek
# zQwwHQYDVR0OBBYEFOmBdKNA+QFYSh21aHK/BmkiAYmwMA4GA1UdDwEB/wQEAwIH
# gDAMBgNVHRMBAf8EAjAAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMEoGA1UdIARDMEEw
# NQYMKwYBBAGyMQECAQMCMCUwIwYIKwYBBQUHAgEWF2h0dHBzOi8vc2VjdGlnby5j
# b20vQ1BTMAgGBmeBDAEEATBJBgNVHR8EQjBAMD6gPKA6hjhodHRwOi8vY3JsLnNl
# Y3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ0NBUjM2LmNybDB5Bggr
# BgEFBQcBAQRtMGswRAYIKwYBBQUHMAKGOGh0dHA6Ly9jcnQuc2VjdGlnby5jb20v
# U2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FSMzYuY3J0MCMGCCsGAQUFBzABhhdo
# dHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAYEABCLJuMZz
# nf7WTFaysIt3aAF7wsDgP0WEJxSQ+0f20kEbt8FxCuKPUiHn8ntfAf6uH4QZITQC
# bhL00ABn6m26caMNNyeT6w06dVjwlm1yl/Ds/bxliRcicURn7ZHc2eeyRNNLMpxD
# EvFwsCzvT99jMkfWfVEa6Yizyfa0I3xzG9QVHb2jWsqJpu2liwJw/l+45uqPLDU+
# QJ9XMBAKG+6G1gzOrF/d8KYcCTQSQLLR/Ts7Oi8CEjl+rCkuwipvTdyqfITlLntG
# RwLWXRZeqObtdsMvs84nhhCOdHypze+xXzShTlipUujicJQK3GxXoAeSvPS3BOYj
# UpmjN1TAdgA1dRRHIxkh8OJU4NVsfljADHZf+5273xcSfbrubTYk+eAdLPpWTvx8
# 7cF2EFHM3bBaJ96Y7Da7JPWZWpQYuUh5CLvheoO7VohL967VQKZiUZy5FK9l6tmu
# J27JVAreIyrOVF+FdZ0l/DjPvgF6MlRjvok4+8/qZelxPRsP03eliiirMIIGtDCC
# BJygAwIBAgIQDcesVwX/IZkuQEMiDDpJhjANBgkqhkiG9w0BAQsFADBiMQswCQYD
# VQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGln
# aWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwHhcN
# MjUwNTA3MDAwMDAwWhcNMzgwMTE0MjM1OTU5WjBpMQswCQYDVQQGEwJVUzEXMBUG
# A1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQg
# RzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExMIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtHgx0wqYQXK+PEbAHKx126NGaHS0URed
# Ta2NDZS1mZaDLFTtQ2oRjzUXMmxCqvkbsDpz4aH+qbxeLho8I6jY3xL1IusLopuW
# 2qftJYJaDNs1+JH7Z+QdSKWM06qchUP+AbdJgMQB3h2DZ0Mal5kYp77jYMVQXSZH
# ++0trj6Ao+xh/AS7sQRuQL37QXbDhAktVJMQbzIBHYJBYgzWIjk8eDrYhXDEpKk7
# RdoX0M980EpLtlrNyHw0Xm+nt5pnYJU3Gmq6bNMI1I7Gb5IBZK4ivbVCiZv7PNBY
# qHEpNVWC2ZQ8BbfnFRQVESYOszFI2Wv82wnJRfN20VRS3hpLgIR4hjzL0hpoYGk8
# 1coWJ+KdPvMvaB0WkE/2qHxJ0ucS638ZxqU14lDnki7CcoKCz6eum5A19WZQHkqU
# JfdkDjHkccpL6uoG8pbF0LJAQQZxst7VvwDDjAmSFTUms+wV/FbWBqi7fTJnjq3h
# j0XbQcd8hjj/q8d6ylgxCZSKi17yVp2NL+cnT6Toy+rN+nM8M7LnLqCrO2JP3oW/
# /1sfuZDKiDEb1AQ8es9Xr/u6bDTnYCTKIsDq1BtmXUqEG1NqzJKS4kOmxkYp2WyO
# Di7vQTCBZtVFJfVZ3j7OgWmnhFr4yUozZtqgPrHRVHhGNKlYzyjlroPxul+bgIsp
# zOwbtmsgY1MCAwEAAaOCAV0wggFZMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0O
# BBYEFO9vU0rp5AZ8esrikFb2L9RJ7MtOMB8GA1UdIwQYMBaAFOzX44LScV1kTN8u
# Zz/nupiuHA9PMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDCDB3
# BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0
# LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDov
# L2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmwwIAYD
# VR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4IC
# AQAXzvsWgBz+Bz0RdnEwvb4LyLU0pn/N0IfFiBowf0/Dm1wGc/Do7oVMY2mhXZXj
# DNJQa8j00DNqhCT3t+s8G0iP5kvN2n7Jd2E4/iEIUBO41P5F448rSYJ59Ib61eoa
# lhnd6ywFLerycvZTAz40y8S4F3/a+Z1jEMK/DMm/axFSgoR8n6c3nuZB9BfBwAQY
# K9FHaoq2e26MHvVY9gCDA/JYsq7pGdogP8HRtrYfctSLANEBfHU16r3J05qX3kId
# +ZOczgj5kjatVB+NdADVZKON/gnZruMvNYY2o1f4MXRJDMdTSlOLh0HCn2cQLwQC
# qjFbqrXuvTPSegOOzr4EWj7PtspIHBldNE2K9i697cvaiIo2p61Ed2p8xMJb82Yo
# sn0z4y25xUbI7GIN/TpVfHIqQ6Ku/qjTY6hc3hsXMrS+U0yy+GWqAXam4ToWd2UQ
# 1KYT70kZjE4YtL8Pbzg0c1ugMZyZZd/BdHLiRu7hAWE6bTEm4XYRkA6Tl4KSFLFk
# 43esaUeqGkH/wyW4N7OigizwJWeukcyIPbAvjSabnf7+Pu0VrFgoiovRDiyx3zEd
# mcif/sYQsfch28bZeUz2rtY/9TCA6TD8dC3JE3rYkrhLULy7Dc90G6e8BlqmyIjl
# gp2+VqsS9/wQD7yFylIz0scmbKvFoW2jNrbM1pD2T7m3XDCCBu0wggTVoAMCAQIC
# EAqA7xhLjfEFgtHEdqeVdGgwDQYJKoZIhvcNAQELBQAwaTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTAeFw0y
# NTA2MDQwMDAwMDBaFw0zNjA5MDMyMzU5NTlaMGMxCzAJBgNVBAYTAlVTMRcwFQYD
# VQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgU0hBMjU2IFJT
# QTQwOTYgVGltZXN0YW1wIFJlc3BvbmRlciAyMDI1IDEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQDQRqwtEsae0OquYFazK1e6b1H/hnAKAd/KN8wZQjBj
# MqiZ3xTWcfsLwOvRxUwXcGx8AUjni6bz52fGTfr6PHRNv6T7zsf1Y/E3IU8kgNke
# ECqVQ+3bzWYesFtkepErvUSbf+EIYLkrLKd6qJnuzK8Vcn0DvbDMemQFoxQ2Dsw4
# vEjoT1FpS54dNApZfKY61HAldytxNM89PZXUP/5wWWURK+IfxiOg8W9lKMqzdIo7
# VA1R0V3Zp3DjjANwqAf4lEkTlCDQ0/fKJLKLkzGBTpx6EYevvOi7XOc4zyh1uSqg
# r6UnbksIcFJqLbkIXIPbcNmA98Oskkkrvt6lPAw/p4oDSRZreiwB7x9ykrjS6GS3
# NR39iTTFS+ENTqW8m6THuOmHHjQNC3zbJ6nJ6SXiLSvw4Smz8U07hqF+8CTXaETk
# VWz0dVVZw7knh1WZXOLHgDvundrAtuvz0D3T+dYaNcwafsVCGZKUhQPL1naFKBy1
# p6llN3QgshRta6Eq4B40h5avMcpi54wm0i2ePZD5pPIssoszQyF4//3DoK2O65Uc
# k5Wggn8O2klETsJ7u8xEehGifgJYi+6I03UuT1j7FnrqVrOzaQoVJOeeStPeldYR
# NMmSF3voIgMFtNGh86w3ISHNm0IaadCKCkUe2LnwJKa8TIlwCUNVwppwn4D3/Pt5
# pwIDAQABo4IBlTCCAZEwDAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQU5Dv88jHt/f3X
# 85FxYxlQQ89hjOgwHwYDVR0jBBgwFoAU729TSunkBnx6yuKQVvYv1Ensy04wDgYD
# VR0PAQH/BAQDAgeAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMIGVBggrBgEFBQcB
# AQSBiDCBhTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMF0G
# CCsGAQUFBzAChlFodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5jcnQwXwYD
# VR0fBFgwVjBUoFKgUIZOaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEuY3JsMCAG
# A1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOC
# AgEAZSqt8RwnBLmuYEHs0QhEnmNAciH45PYiT9s1i6UKtW+FERp8FgXRGQ/YAavX
# zWjZhY+hIfP2JkQ38U+wtJPBVBajYfrbIYG+Dui4I4PCvHpQuPqFgqp1PzC/ZRX4
# pvP/ciZmUnthfAEP1HShTrY+2DE5qjzvZs7JIIgt0GCFD9ktx0LxxtRQ7vllKluH
# WiKk6FxRPyUPxAAYH2Vy1lNM4kzekd8oEARzFAWgeW3az2xejEWLNN4eKGxDJ8WD
# l/FQUSntbjZ80FU3i54tpx5F/0Kr15zW/mJAxZMVBrTE2oi0fcI8VMbtoRAmaasl
# NXdCG1+lqvP4FbrQ6IwSBXkZagHLhFU9HCrG/syTRLLhAezu/3Lr00GrJzPQFnCE
# H1Y58678IgmfORBPC1JKkYaEt2OdDh4GmO0/5cHelAK2/gTlQJINqDr6JfwyYHXS
# d+V08X1JUPvB4ILfJdmL+66Gp3CSBXG6IwXMZUXBhtCyIaehr0XkBoDIGMUG1dUt
# wq1qmcwbdUfcSYCn+OwncVUXf53VJUNOaMWMts0VlRYxe5nK+At+DI96HAlXHAL5
# SlfYxJ7La54i71McVWRP66bW+yERNpbJCjyCYG2j+bdpxo/1Cy4uPcU3AWVPGrbn
# 5PhDBf3Froguzzhk++ami+r3Qrx5bIbY3TVzgiFI7Gq3zWcxggYzMIIGLwIBATBo
# MFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNV
# BAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYCEAec4OTRFH+F
# zTlzz3YtN+swCQYFKw4DAhoFAKB4MBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAw
# GQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisG
# AQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFCiOjMpfuJllwwJSDKAUwyZSIuZwMA0G
# CSqGSIb3DQEBAQUABIICAD+4HOg1jXXOJfoXoXDh5IrPk1waO3Yj47rXDWz/YM+j
# Ex9GL6pcEPCuONDxJA3FO/JNPzFkcNqRg5qI4uLF3jcdGSdl2hNY+OKn2CeVaeWK
# w8WQiF4pb0OXIlEuynpuUxnN4GsvqKhLQBXUVIoP9psgkMyaLl5tNt/0vTO2bEGO
# SDD8Bm4kwvAFMQRH4hgZc4didzaU+nzN8rOw9Bw1xuTLyBBXWGgroEHlOxrCDLVt
# OE0fCfmnQuQO7BSVOrMKHS7FlvGw3jD+kQ+TBuWZ/OQGmE9jlyCu64kuk6ir80Ev
# 1VHUgoTdOUjaD0jul5PQotjZT5FoTOnj697BM57Dgsw1o2FrCm3+TnycirzzVwTA
# NBeyEVZGdHJgfav40IiNWS+DoewIbBKDtV0j+nmceuw6OBIMC6CMjK4Ld1N3ywWM
# mnuee5S+5znyj94Q/73O0889UO0t0p23/zi5RUn9qYrsWp9nfNcnmN2bK6OtqcSp
# EIscns4HFkgt/doummaDl60Ytp6HAHcEnvs7XEhtT9K3AvDQtRVTH60RA7NXKaCd
# jt4vtbJOzJ0YjZUF6x18aM/YsmXKBUWyCVb7CgKTy7c6l2GydNny4Ljmm3iEqLmB
# eLiVrLybCsUI7lr4+zE8GjogIIEyIq04MZHNLRdAMT9Vub1Fk3vt4dBthF+gY9Om
# oYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMPAgEBMH0waTELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVz
# dGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMQIQCoDv
# GEuN8QWC0cR2p5V0aDANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkq
# hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDYyMzAwMzgzNVowLwYJKoZIhvcN
# AQkEMSIEIF5v1PbmelCxwvWE8BkK0Pg9t7duHkuYKup19C4fqh1bMA0GCSqGSIb3
# DQEBAQUABIICABGjIr+FTpWZaJbr98pPcr5/S1TqQGqqTiumgvNAU3U+Qsdfwv51
# IJw2UoIHLzVdrp1zQELb1jKWx/Ax6tBXWHrcqa7v8KzToUkig5JnJIBpTGhqK9QJ
# 24BZbrxjarVeAK8mMMJJv9l7Gbg1UMPvAgqSPsQN6BIwh9x66wy1tZ7R/mrAJuAG
# POzF8MZNjZNfzaoeQ1vmIkeyyjgAIrfD2OK0ijV1DYgdwi68kyXXWM2EbaotCmQJ
# ZFChL5Diau6acfR1eaqKIqgufIgnyZkxpBqy4QxjtsKkWUKMeNjwfZZFckQ5OzAB
# sLqwOS+eVOi7b2b937YBXgiv0Nm9f2Dq7pB19Vth6t49b3Z7Wv9qUq0JI/4i0/YT
# LxK6+i141x2OQ118ECJ00KkK0mWCPYYLhsJTC428FEh7lQ6nN20mD3fLghZFHiRM
# XsnokF1L6EdupM2TnR8IRGx9ckBPkU/hdsorKCyDrdygxS5LzJ2c9bAmnjYJLYj5
# dr7B4PJUVX9TtFsvjRve+3AgLEndtBBaywqsG+u+7piZ6kCwhcQjoWU78FExP8ZA
# 3Y+W+ySKl5waRkUg4B5mLyNFR3Msh/DHUBtPAxEenBJFDr1BOuo/nk2TL5+RyBZO
# bRQGUs6PP2XuexqgfjoUOjSh7hzT6Mhp5JBgZZNIFjB1apltT+0hbBME
# SIG # End signature block
