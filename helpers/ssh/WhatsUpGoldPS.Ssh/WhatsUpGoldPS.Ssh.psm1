<#
.SYNOPSIS
    WhatsUpGoldPS.Ssh module - SSH command execution via SSH.NET (Renci.SshNet).

.DESCRIPTION
    Provides PowerShell 5.1-compatible SSH session management and command execution
    using the SSH.NET library. Follows the same pattern as WhatsUpGoldPS.Snmp.

    Functions:
      Import-SshNet          Load the Renci.SshNet.dll assembly
      New-SshSession         Create an authenticated SSH session
      Invoke-SshCommand      Execute a command on an open session
      Close-SshSession       Disconnect and dispose a session
      Test-SshConnection     Quick connectivity + auth check

.NOTES
    Encoding: UTF-8 with BOM
    Requires: PowerShell 5.1+, Renci.SshNet.dll in lib\Release\
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# Assembly loading
# ============================================================================
$script:SshNetLoaded = $false

function Import-SshNet {
    <#
    .SYNOPSIS
        Loads the SSH.NET (Renci.SshNet) assembly, selecting the best
        target framework for the current PowerShell runtime.
    .DESCRIPTION
        Tries framework folders in preference order:
          netstandard2.0  (.NET Core / PowerShell 7+)
          net40           (.NET Framework / Windows PowerShell 5.1)
        Loads the SshNet.Security.Cryptography dependency first, then
        Renci.SshNet.dll. Safe to call multiple times.
    .OUTPUTS
        [bool] $true if the assembly is loaded.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($script:SshNetLoaded) { return $true }

    $releaseRoot = Join-Path $PSScriptRoot 'lib\Release'

    # Framework preference order: highest/newest first, always.
    # netstandard2.0 is the newer build and works on both PS 5.1 (.NET 4.6.1+) and PS 7+.
    # net40 is the legacy fallback for older .NET Framework environments.
    $frameworkCandidates = @('netstandard2.0', 'net40')

    $availableFrameworks = @(
        Get-ChildItem -Path $releaseRoot -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name
    )

    $selectedFramework = $null
    $loadFailures = [System.Collections.Generic.List[string]]::new()

    foreach ($tfm in $frameworkCandidates) {
        if ($tfm -notin $availableFrameworks) { continue }

        $tfmDir = Join-Path $releaseRoot $tfm
        $sshDll = Join-Path $tfmDir 'Renci.SshNet.dll'
        $cryptoDll = Join-Path $tfmDir 'SshNet.Security.Cryptography.dll'

        if (-not (Test-Path -LiteralPath $sshDll)) { continue }

        try {
            # Load crypto dependency first
            if (Test-Path -LiteralPath $cryptoDll) {
                if (-not ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'SshNet.Security.Cryptography' })) {
                    Add-Type -Path $cryptoDll -ErrorAction Stop
                    Write-Verbose "[SSH] Loaded SshNet.Security.Cryptography ($tfm)"
                }
            }

            # Load SSH.NET
            Add-Type -Path $sshDll -ErrorAction Stop
            $script:SshNetLoaded = $true
            $selectedFramework = $tfm
            Write-Verbose "[SSH] Loaded Renci.SshNet ($tfm) from: $sshDll"
            break
        }
        catch {
            $loadFailures.Add("${tfm}: $($_.Exception.Message)")
            Write-Verbose "[SSH] Failed loading $tfm, trying next: $_"
        }
    }

    if (-not $script:SshNetLoaded) {
        # Check if already loaded by another module
        if ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Renci.SshNet' }) {
            $script:SshNetLoaded = $true
            Write-Verbose "[SSH] Renci.SshNet already loaded in AppDomain."
            return $true
        }

        $failMsg = "Could not load SSH.NET for this PowerShell runtime.`n"
        $failMsg += "Available frameworks: $($availableFrameworks -join ', ')`n"
        if ($loadFailures.Count -gt 0) {
            $failMsg += "Failures:`n  " + ($loadFailures -join "`n  ")
        }
        throw $failMsg
    }

    return $true
}

# ============================================================================
# Session management
# ============================================================================
function New-SshSession {
    <#
    .SYNOPSIS
        Creates and opens an SSH connection to a remote host.
    .PARAMETER HostName
        Target hostname or IP address.
    .PARAMETER Port
        SSH port. Default: 22.
    .PARAMETER Username
        SSH username.
    .PARAMETER Password
        SSH password (plaintext string).
    .PARAMETER SecurePassword
        SSH password as SecureString.
    .PARAMETER KeyFile
        Path to a private key file for key-based auth.
    .PARAMETER KeyPassphrase
        Passphrase for the private key (if encrypted).
    .PARAMETER TimeoutSeconds
        Connection timeout in seconds. Default: 30.
    .OUTPUTS
        Renci.SshNet.SshClient - the connected session object.
    .EXAMPLE
        $session = New-SshSession -HostName '192.168.1.100' -Username 'admin' -Password 'secret'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [int]$Port = 22,

        [Parameter(Mandatory = $true)]
        [string]$Username,

        [string]$Password,

        [System.Security.SecureString]$SecurePassword,

        [string]$KeyFile,

        [string]$KeyPassphrase,

        [int]$TimeoutSeconds = 30
    )

    Import-SshNet | Out-Null

    # Resolve password
    $plainPassword = $Password
    if (-not $plainPassword -and $SecurePassword) {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        try {
            $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    # Build authentication methods
    $authMethods = [System.Collections.Generic.List[Renci.SshNet.AuthenticationMethod]]::new()

    if ($KeyFile -and (Test-Path -LiteralPath $KeyFile)) {
        if ($KeyPassphrase) {
            $pkFile = New-Object Renci.SshNet.PrivateKeyFile($KeyFile, $KeyPassphrase)
        }
        else {
            $pkFile = New-Object Renci.SshNet.PrivateKeyFile($KeyFile)
        }
        $authMethods.Add((New-Object Renci.SshNet.PrivateKeyAuthenticationMethod($Username, $pkFile)))
        Write-Verbose "[SSH] Using key-based auth: $KeyFile"
    }

    if ($plainPassword) {
        $authMethods.Add((New-Object Renci.SshNet.PasswordAuthenticationMethod($Username, $plainPassword)))
        Write-Verbose "[SSH] Using password auth for user: $Username"
    }

    if ($authMethods.Count -eq 0) {
        throw "No authentication method provided. Supply -Password, -SecurePassword, or -KeyFile."
    }

    # Create connection info and client
    $connInfo = New-Object Renci.SshNet.ConnectionInfo($HostName, $Port, $Username, $authMethods.ToArray())
    $connInfo.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

    $client = New-Object Renci.SshNet.SshClient($connInfo)

    try {
        $client.Connect()
        Write-Verbose "[SSH] Connected to ${HostName}:${Port} as $Username"
        return $client
    }
    catch {
        $client.Dispose()
        throw "SSH connection to ${HostName}:${Port} failed: $_"
    }
}

function Invoke-SshCommand {
    <#
    .SYNOPSIS
        Executes a command on an open SSH session and returns the output.
    .PARAMETER Session
        An open SshClient object from New-SshSession.
    .PARAMETER Command
        The command string to execute.
    .PARAMETER TimeoutSeconds
        Command execution timeout. Default: 60.
    .OUTPUTS
        PSCustomObject with properties: ExitCode, Output, Error
    .EXAMPLE
        $result = Invoke-SshCommand -Session $session -Command 'nvidia-smi --query-gpu=name --format=csv,noheader'
        $result.Output
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [int]$TimeoutSeconds = 60
    )

    if (-not $Session.IsConnected) {
        throw "SSH session is not connected."
    }

    $cmd = $Session.CreateCommand($Command)
    $cmd.CommandTimeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

    try {
        $cmd.Execute() | Out-Null
        $output = $cmd.Result
        $error_ = $cmd.Error

        return [PSCustomObject]@{
            ExitCode = $cmd.ExitStatus
            Output   = if ($output) { $output.TrimEnd("`r", "`n") } else { '' }
            Error    = if ($error_) { $error_.TrimEnd("`r", "`n") } else { '' }
        }
    }
    finally {
        $cmd.Dispose()
    }
}

function Close-SshSession {
    <#
    .SYNOPSIS
        Disconnects and disposes an SSH session.
    .PARAMETER Session
        The SshClient object to close.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Session
    )

    try {
        if ($Session.IsConnected) {
            $Session.Disconnect()
        }
    }
    catch { }
    finally {
        $Session.Dispose()
        Write-Verbose "[SSH] Session closed."
    }
}

function Test-SshConnection {
    <#
    .SYNOPSIS
        Tests SSH connectivity and authentication to a host.
    .PARAMETER HostName
        Target hostname or IP address.
    .PARAMETER Port
        SSH port. Default: 22.
    .PARAMETER Username
        SSH username.
    .PARAMETER Password
        SSH password.
    .PARAMETER SecurePassword
        SSH password as SecureString.
    .PARAMETER KeyFile
        Path to a private key file.
    .PARAMETER TimeoutSeconds
        Connection timeout. Default: 10.
    .OUTPUTS
        [bool] $true if connection succeeds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [int]$Port = 22,

        [Parameter(Mandatory = $true)]
        [string]$Username,

        [string]$Password,

        [System.Security.SecureString]$SecurePassword,

        [string]$KeyFile,

        [int]$TimeoutSeconds = 10
    )

    try {
        $splat = @{
            HostName       = $HostName
            Port           = $Port
            Username       = $Username
            TimeoutSeconds = $TimeoutSeconds
        }
        if ($Password)       { $splat['Password'] = $Password }
        if ($SecurePassword) { $splat['SecurePassword'] = $SecurePassword }
        if ($KeyFile)        { $splat['KeyFile'] = $KeyFile }

        $session = New-SshSession @splat
        Close-SshSession -Session $session
        return $true
    }
    catch {
        Write-Verbose "[SSH] Connection test failed for ${HostName}:${Port} - $_"
        return $false
    }
}

function Invoke-SshShellCommand {
    <#
    .SYNOPSIS
        Runs commands through an interactive SSH shell instead of the exec channel.
    .DESCRIPTION
        Many network operating systems refuse exec-channel commands and require a
        real terminal: enable mode, menu systems, control characters such as
        Ctrl+Z, and pager prompts like --More--. This function allocates a shell,
        waits for prompts, answers the pager automatically, and returns the
        collected output.

        Each entry in -Step is either a plain string (sent followed by Enter) or a
        hashtable supporting:
          Send       Text or control character to transmit.
          NoNewline  Send without a trailing Enter (use for Ctrl+Z and menu keys).
          WaitFor    Regex to wait for instead of the normal prompt.
          DelayMs    Extra pause after sending.
          Collect    Set to $false to discard this step's output (setup commands).
    .PARAMETER PromptPattern
        Regex identifying the device prompt. Default matches a trailing > or #.
    .PARAMETER MorePattern
        Regex for pager prompts. A space is sent whenever it matches.
    .EXAMPLE
        Invoke-SshShellCommand -Session $s -Step 'terminal length 0','show running-config'
    .EXAMPLE
        # Escape a menu with Ctrl+Z, then collect the config
        Invoke-SshShellCommand -Session $s -Step @(
            @{ Send = [char]26; NoNewline = $true; Collect = $false },
            'show running-config'
        )
    .EXAMPLE
        # Enter enable mode first
        Invoke-SshShellCommand -Session $s -EnablePassword $secure -Step 'show running-config'
    .OUTPUTS
        PSCustomObject with Output and Steps.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        [object[]]$Step,

        [string]$PromptPattern = '(?m)^[^\r\n]*[>#]\s*$',

        [string]$MorePattern = '--\s?More\s?--|---- More ----|<--- More --->',

        [System.Security.SecureString]$EnablePassword,

        [string]$EnableCommand = 'enable',

        [int]$TimeoutSeconds = 60,

        [int]$SettleMilliseconds = 400
    )

    if (-not $Session.IsConnected) { throw 'SSH session is not connected.' }

    $stream = $Session.CreateShellStream('vt100', 240, 200, 1024, 768, 131072)
    try {
        $readUntil = {
            param([string]$Pattern, [int]$Seconds)

            $builder = New-Object System.Text.StringBuilder
            $deadline = (Get-Date).AddSeconds($Seconds)
            $lastData = Get-Date

            while ((Get-Date) -lt $deadline) {
                $chunk = $stream.Read()
                if ($chunk) {
                    [void]$builder.Append($chunk)
                    $lastData = Get-Date
                    $text = $builder.ToString()

                    if ($MorePattern -and [regex]::IsMatch($text, $MorePattern)) {
                        $stream.Write(' ')
                        $stream.Flush()
                        $cleaned = [regex]::Replace($text, $MorePattern, '')
                        [void]$builder.Clear()
                        [void]$builder.Append($cleaned)
                        continue
                    }
                    if ($Pattern -and [regex]::IsMatch($text, $Pattern)) { break }
                }
                else {
                    # No prompt match but the device stopped talking: treat as done.
                    if ($Pattern -and ((Get-Date) - $lastData).TotalMilliseconds -gt ($SettleMilliseconds * 6)) { break }
                    Start-Sleep -Milliseconds 100
                }
            }
            return $builder.ToString()
        }

        $null = & $readUntil $PromptPattern 10

        if ($EnablePassword) {
            $stream.WriteLine($EnableCommand)
            $stream.Flush()
            $null = & $readUntil '(?i)password' 15
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($EnablePassword)
            try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            $stream.WriteLine($plain)
            $stream.Flush()
            $plain = $null
            $null = & $readUntil $PromptPattern 15
        }

        $collected = New-Object System.Text.StringBuilder
        $stepResults = [System.Collections.Generic.List[object]]::new()

        foreach ($item in $Step) {
            $send = $null
            $noNewline = $false
            $waitFor = $PromptPattern
            $delayMs = 0
            $collect = $true

            if ($item -is [System.Collections.IDictionary]) {
                $send = [string]$item['Send']
                if ($item.Contains('NoNewline')) { $noNewline = [bool]$item['NoNewline'] }
                if ($item['WaitFor']) { $waitFor = [string]$item['WaitFor'] }
                if ($item['DelayMs']) { $delayMs = [int]$item['DelayMs'] }
                if ($item.Contains('Collect')) { $collect = [bool]$item['Collect'] }
            }
            else {
                $send = [string]$item
            }

            if ($noNewline) { $stream.Write($send) } else { $stream.WriteLine($send) }
            $stream.Flush()
            if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }

            $output = & $readUntil $waitFor $TimeoutSeconds

            $lines = @($output -split "`r?`n")
            if ($lines.Count -gt 0 -and $send -and $lines[0].Trim() -eq $send.Trim()) {
                $lines = @($lines[1..($lines.Count - 1)])
            }
            if ($lines.Count -gt 0 -and $lines[-1] -match '[>#]\s*$') {
                $lines = @($lines[0..($lines.Count - 2)])
            }
            $clean = ($lines -join "`n")

            $stepResults.Add([pscustomobject]@{ Command = $send; Output = $clean })
            if ($collect) {
                if ($collected.Length -gt 0) { [void]$collected.Append("`n") }
                [void]$collected.Append($clean)
            }
        }

        return [pscustomobject]@{
            Output = $collected.ToString()
            Steps  = @($stepResults)
        }
    }
    finally {
        $stream.Dispose()
    }
}

# ============================================================================
# Export
# ============================================================================
Export-ModuleMember -Function @(
    'Import-SshNet',
    'New-SshSession',
    'Invoke-SshCommand',
    'Invoke-SshShellCommand',
    'Close-SshSession',
    'Test-SshConnection'
)

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA25ZwZQ5Cbarea
# +n0qGzhPYXMrQcvm8CQ0oRVmKeAxuKCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjYgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSb
# TGWz/TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP
# 0BMxt9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3
# BSkUxDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNF
# KZZEeoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbj
# brEOvZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26Q
# ZYMn/FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRs
# IolvykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/S
# cpaZCZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5
# prW83vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0
# ODjdzi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwrocz
# k9icflf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLa
# DXQIENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEt
# rfGhz45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAd
# ZkfHhHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAY
# yzSA02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8
# pD7KVyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v
# 5jhtKVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeS
# WmvKqzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR
# 5eHs0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZ
# EbGRsMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjW
# agkJNt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvd
# N8yWQPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCDz8ULwIJqYefwrI8k4zwaHp5KZfPzxH1MSH4mIHUw0SDANBgkqhkiG9w0BAQEF
# AASCAgAFg5HDgbcTMjGZ+132g71UzgZCe0cNxE0tQxwmbIXFObWlDLaYCf8P+cmb
# pMsLbQJPecXLcCt+yXEPWhg6wNpd86bUDbc+S4uGV1rIPgf8C5l8IjD+CInPnN2Q
# Vyw6aYkUxV6E7I8n1cvCX/yTbLJgX3vLwS/JsJju4tdNYv77Or6c7s8XxSOhLA2T
# 9IEZBpJ0HntBKShsmThrqCMlLIdLdiPRUQso7GNFZJyq67xyFo5i5dBrQ9+dW+/8
# wplsalSgFVhkRXktDyMZrvwtsjTu4WHtv0p+4H1Zp0BE/9m3QlE6TvD8fBImS3lF
# Um2XGd3WsaOzH5JiLlDbY4Q8AKb9wxj0QLCtIO9ColbjGo4oibvqMj93o1sjOKgy
# D1O3++WD3H75865GepUply0PbtD8R6X/W35tS6QaKjbHj1DTE0+259lUILSEDh5U
# F1qVC1QB8JQAVlvkcvTHyIf4ViQ1DwnifVvBy2Ft81ELu/cwBD53JuXtB4RKx17H
# Bu9PzLnbHGDMdTyeH0sK8zAPvtINff34NG+8Y00jQ1LYPbQpKnrFyOJOSy0UKvv8
# MvIArtNGsxPR7RgqMVojThgdYBaXtOItWq/TSt9mH12NU6wns1I69GmXkYUx3U/S
# Q8Gfd+qwVHOlODBwZ04rEtgO8wREezsWfPrn1A7mxTZSoMNm9qGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA5MjkxOTM3MzBaMC8GCSqGSIb3DQEJBDEiBCAH2pAY
# I6eWMvLOaRXGL4Wivk0KAIwcadAzT4B3RmfyPTANBgkqhkiG9w0BAQEFAASCAgAp
# uWFcGC+N8XlqWW3GTPaqVEA4Iu8kJ91GzNpqbZOI+SjfaZpyoE28eVPLl4KKji3A
# 0jrKRzHLs3TSJgzdzFiZfIbo40Z/GNUx04RTdEETFJN9hVfs9T94e3uzA/glaFJ7
# /U2zZkoVMhQSJryhGD10TQVO2PLDQMz+651JBwY50zQ8mGaloGdfxIvDI+HDvqgI
# khyrHoplhYWVhYQEvz+9plLs+AOGjZio/2U+Awh40tX8wNUnpfUI9rk8fnbTklUM
# qd1/WnEjtHlDE1xspwNCCKZkk0OBKl7YUC84mddx9kURlqn6IMTSAWIYKcn3zZ5p
# ExIUxxuZtsNx1yqhpefdkC2/Xp5jtPJ0fn6tNjG5TqacL1m2bbSEAg1Nsv/QoNgC
# kh3N6oNymk9cpFrj7UubsDlhT5FdJnjSEqWZtQW5RPsm7FdkH67uDj9I7aUiO/YM
# JEugqrADdRaGPeEWQLIpT8VBpJBwQshCESq3r25uLeVONQF8oPCxMXjVATpoZLc7
# fnmr+HEl/atrkoh0oyY7xKsH9f1AXiD+83bn0UQ0QaEDLd/CrJhCsRU3Y0okP3WV
# 7dfoJ8Tz235Gdy9XNBLa1VCAKLuQtluERxkE39Y7mH2w8QeLv9/Nhm9KNDoIOOcy
# GZYqpz6d2EDpMaqcrFoLkHHnCHHQEJs15bNiKb4zKQ==
# SIG # End signature block
