<#
.SYNOPSIS
Connects to a WhatsUp Gold (WUG) server and obtains an OAuth 2.0 authorization token.

.DESCRIPTION
The Connect-WUGServer function establishes a connection to a WhatsUp Gold server using the specified parameters,
and obtains an authorization token using the OAuth 2.0 password grant type flow. The function validates the
input parameters and handles credential input, and also allows for ignoring SSL certificate validation errors.
The authorization token is stored in a global variable for subsequent API requests.

When called with no parameters, the function checks the DPAPI vault for a previously saved connection.
If found, it prompts to reuse, reset, or enter new connection details. Successful connections are
automatically saved to the vault for future use. The vault is stored at
%LOCALAPPDATA%\DiscoveryHelpers\Vault and is interoperable with the DiscoveryHelpers credential vault.

.PARAMETER serverUri
The URI of the WhatsUp Gold server to connect to.

.PARAMETER Protocol
The protocol to use for the connection (http or https). Default is https.

.PARAMETER Username
Plaintext username to use for authentication. Required when using the UserPassSet parameter set. For best security, use -Crdential

.PARAMETER Password
Plaintext password to use for authentication. Required when using the UserPassSet parameter set. For best security, use -Credential

.PARAMETER Credential
A PSCredential object containing the username and password for authentication. Required when using the CredentialSet parameter set.

.PARAMETER TokenEndpoint
The endpoint for obtaining the OAuth 2.0 authorization token. Default is "/api/v1/token".

.PARAMETER Port
The TCPIP port to use for the connection. Default is 9644.

.PARAMETER IgnoreSSLErrors
A switch that allows for ignoring SSL certificate validation errors. WARNING: Use this option with caution
For best security, use a valid certificate

.EXAMPLE
Connect-WUGServer -serverUri "whatsup.example.com" -Username "admin" -Password "mypassword"
Connects to the WhatsUp Gold server at "https://whatsup.example.com:9644" with the provided credentials, and obtains an
OAuth 2.0 authorization token.

$Cred = Get-Credential
Connect-WUGServer -serverUri 192.168.1.250 -Credential $Cred -IgnoreSSLErrors

.EXAMPLE
Connect-WUGServer
When called with no parameters, checks the vault for a saved connection. If found, prompts to use it.
If no saved connection exists, interactively prompts for server, port, protocol, and credentials.

.NOTES
Author: Jason Alberino (jason@wug.ninja)
Last Modified: 2024-09-26

.LINK
# Link to related documentation or resources
https://docs.ipswitch.com/NM/WhatsUpGold2024/02_Guides/rest_api/index.html#section/Handling-Session-Tokens

#>
function Connect-WUGServer {
    [CmdletBinding(DefaultParameterSetName = 'VaultSet')]
    param (
        # Common Parameters for CredentialSet / UserPassSet
        [Parameter(Mandatory = $true, ParameterSetName = 'CredentialSet', ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Parameter(Mandatory = $true, ParameterSetName = 'UserPassSet', ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Parameter(ParameterSetName = 'VaultSet')]
        [string]$serverUri,

        [Parameter()]
        [ValidateSet("http", "https")]
        [string]$Protocol = "https",

        [Parameter()]
        [ValidatePattern("^(/[a-zA-Z0-9]+)+/?$")]
        [string]$TokenEndpoint = "/api/v1/token",

        [Parameter()]
        [ValidateRange(1, 65535)]
        [int32]$Port = 9644,

        [Parameter()]
        [switch]$IgnoreSSLErrors,

        # Unique Parameters for 'CredentialSet'
        [Parameter(Mandatory = $true, ParameterSetName = 'CredentialSet')]
        [System.Management.Automation.Credential()]
        [PSCredential]$Credential,

        # Unique Parameters for 'UserPassSet'
        [Parameter(Mandatory = $true, ParameterSetName = 'UserPassSet')]
        [string]$Username,

        [Parameter(Mandatory = $true, ParameterSetName = 'UserPassSet')]
        [string]$Password
    )
    
    begin {
        Write-Debug "Starting Connect-WUGServer function"

        # ── Vault helpers (DPAPI, interoperable with DiscoveryHelpers vault) ──
        $vaultDir  = Join-Path $env:LOCALAPPDATA 'DiscoveryHelpers\Vault'
        $vaultFile = Join-Path $vaultDir 'WUG.Server.cred'
        $_fromVault = $false

        # Read a saved WUG connection from the DPAPI vault
        function _GetSavedWUGConnection {
            param([string]$Path)
            if (-not (Test-Path $Path)) { return $null }
            try {
                $obj = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not $obj.Encrypted) { return $null }
                if ($obj.Encrypted -like 'AES256:*') {
                    Write-Warning "Vault credential is AES-encrypted. Use the DiscoveryHelpers to unlock, or reset."
                    return $null
                }
                # Verify integrity hash
                if ($obj.Integrity) {
                    $intInput = "$($obj.Encrypted)|$($env:COMPUTERNAME)|$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
                    $sha = [System.Security.Cryptography.SHA256]::Create()
                    $hBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($intInput))
                    $sha.Dispose()
                    $expected = [BitConverter]::ToString($hBytes) -replace '-', ''
                    if ($obj.Integrity -ne $expected) {
                        Write-Warning "Vault integrity check failed for WUG.Server. The file may have been tampered with."
                        return $null
                    }
                }
                # Decrypt DPAPI
                $ss = ConvertTo-SecureString -String $obj.Encrypted
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
                try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
                finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
                $parts = $plain -split '\|', 5
                if ($parts.Count -ge 5) {
                    $secPwd = ConvertTo-SecureString $parts[4] -AsPlainText -Force
                    return @{
                        Server     = $parts[0]
                        Port       = [int]$parts[1]
                        Protocol   = $parts[2]
                        Credential = [PSCredential]::new($parts[3], $secPwd)
                        IgnoreSSL  = $true
                    }
                }
                return $null
            }
            catch {
                Write-Warning "Could not read vault credential: $_"
                return $null
            }
        }

        # Save a WUG connection to the DPAPI vault
        function _SaveWUGConnection {
            param([string]$VaultDir, [string]$Path, [string]$Server, [int]$ConnPort, [string]$Proto, [string]$User, [string]$Pass)
            if (-not (Test-Path $VaultDir)) {
                New-Item -Path $VaultDir -ItemType Directory -Force | Out-Null
                try {
                    $acl = New-Object System.Security.AccessControl.DirectorySecurity
                    $acl.SetAccessRuleProtection($true, $false)
                    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $currentUser, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                    $acl.AddAccessRule($rule)
                    $sysRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        'SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                    $acl.AddAccessRule($sysRule)
                    Set-Acl -Path $VaultDir -AclObject $acl
                }
                catch { Write-Verbose "Could not restrict vault directory ACL: $_" }
            }
            $combined = "$Server|$ConnPort|$Proto|$User|$Pass"
            $ss = ConvertTo-SecureString $combined -AsPlainText -Force
            $encrypted = ConvertFrom-SecureString -SecureString $ss
            $intInput = "$encrypted|$($env:COMPUTERNAME)|$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $hBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($intInput))
            $sha.Dispose()
            $hash = [BitConverter]::ToString($hBytes) -replace '-', ''
            $credObj = [ordered]@{
                Name        = 'WUG.Server'
                Type        = 'Single'
                Description = "WUG ${Proto}://${Server}:${ConnPort} ($User)"
                CreatedUtc  = (Get-Date).ToUniversalTime().ToString('o')
                ExpiresUtc  = $null
                Machine     = $env:COMPUTERNAME
                User        = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                Integrity   = $hash
                Encrypted   = $encrypted
            }
            $json = $credObj | ConvertTo-Json -Depth 5
            [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($true))
        }

        # ── VaultSet: resolve connection from vault or interactive prompt ──
        if ($PSCmdlet.ParameterSetName -eq 'VaultSet' -and -not $PSBoundParameters.ContainsKey('serverUri')) {
            $saved = _GetSavedWUGConnection -Path $vaultFile
            $useExisting = $false
            if ($saved) {
                $preview = "Server=$($saved.Server):$($saved.Port) ($($saved.Protocol)), User=$($saved.Credential.UserName)"
                Write-Host ''
                Write-Host "  Saved WUG connection found in vault:" -ForegroundColor Cyan
                Write-Host "  $preview" -ForegroundColor Green
                Write-Host ''
                $choice = Read-Host -Prompt "  [Y] Use saved  [N] New connection  [R] Reset"
                switch -Regex ($choice) {
                    '^[Yy]' {
                        $serverUri = $saved.Server
                        $Port = $saved.Port
                        $Protocol = $saved.Protocol
                        $Credential = $saved.Credential
                        $IgnoreSSLErrors = [switch]$true
                        $Username = $Credential.GetNetworkCredential().UserName
                        $Password = $Credential.GetNetworkCredential().Password
                        $_fromVault = $true
                        $useExisting = $true
                        Write-Host "  Using saved connection." -ForegroundColor Green
                    }
                    '^[Rr]' {
                        Write-Host "  Removing saved connection..." -ForegroundColor Yellow
                        Remove-Item -Path $vaultFile -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            if (-not $useExisting) {
                Write-Host ''
                Write-Host "  WhatsUp Gold server connection:" -ForegroundColor Yellow
                $srvInput = Read-Host -Prompt "    Server hostname or IP"
                if ([string]::IsNullOrWhiteSpace($srvInput)) { throw "Server hostname or IP is required." }
                $serverUri = $srvInput.Trim()
                $pInput = Read-Host -Prompt "    Port [9644]"
                if (-not [string]::IsNullOrWhiteSpace($pInput)) { $Port = [int]$pInput }
                $prInput = Read-Host -Prompt "    Protocol [https]"
                if (-not [string]::IsNullOrWhiteSpace($prInput)) { $Protocol = $prInput.Trim().ToLower() }
                $Credential = Get-Credential -Message "WhatsUp Gold credentials for $serverUri"
                if (-not $Credential) { throw "Credentials are required." }
                $Username = $Credential.GetNetworkCredential().UserName
                $Password = $Credential.GetNetworkCredential().Password
                $sslInput = Read-Host -Prompt "    Ignore SSL errors? [Y/N] (default: Y)"
                if ($sslInput -match '^[Nn]') { $IgnoreSSLErrors = [switch]$false }
                else { $IgnoreSSLErrors = [switch]$true }
            }
        }

        Write-Debug "Server URI: $serverUri, Protocol: $Protocol, Port: $Port"
        
        # Input validation
        # Check if the hostname or IP address is resolvable
        $ip = $null
        try { 
            $ip = [System.Net.Dns]::GetHostAddresses($serverUri) 
        } catch { 
            throw "Cannot resolve hostname or IP address. Please enter a valid IP address or hostname." 
        }
        if ($null -eq $ip) { 
            throw "Cannot resolve hostname or IP address, ${serverUri}. Please enter a resolvable IP address or hostname." 
        }
    
        # Check if the port is open
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $connectResult = $tcpClient.BeginConnect($ip[0], $Port, $null, $null)
            $waitResult = $connectResult.AsyncWaitHandle.WaitOne(500)
            if (!$waitResult -or !$tcpClient.Connected) { 
                $tcpClient.Close(); 
                throw "The specified port, ${Port}, is not open or accepting connections." 
            } 
            $tcpClient.Close()
        }
        catch {
            throw "The specified port, $Port, is not open or accepting connections."
        }
    
        # Handle Credentials Based on Parameter Set
        switch ($PSCmdlet.ParameterSetName) {
            'CredentialSet' {
                Write-Debug "Using Credential parameter set."
                $Username = $Credential.GetNetworkCredential().UserName
                $Password = $Credential.GetNetworkCredential().Password
            }
            'UserPassSet' {
                Write-Debug "Using Username and Password parameter set."
                # Username and Password are already provided
            }
            'VaultSet' {
                Write-Debug "Using Vault parameter set. Credentials already resolved."
                # Username and Password were set during vault/interactive resolution above
            }
            default {
                throw "Invalid parameter set. Please specify either -Credential or both -Username and -Password."
            }
        }
    
        # SSL Certificate Validation Handling
        if ($IgnoreSSLErrors -and $Protocol -eq "https") {
            if ($PSVersionTable.PSEdition -eq 'Core') { 
                $Script:PSDefaultParameterValues["invoke-restmethod:SkipCertificateCheck"] = $true
                $Script:PSDefaultParameterValues["invoke-webrequest:SkipCertificateCheck"] = $true
            } else { 
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            }
            Write-Warning "Ignoring SSL certificate validation errors. Use this option with caution."
        }    
    
        # Set variables
        $global:IgnoreSSLErrors = $IgnoreSSLErrors
        $global:WhatsUpServerBaseURI = "${Protocol}://${serverUri}:${Port}"
        $global:tokenUri = "${global:WhatsUpServerBaseURI}${TokenEndpoint}"
        $global:WUGBearerHeaders = @{"Content-Type" = "application/json" }
        $tokenBody = "grant_type=password&username=${Username}&password=${Password}"
    }
    
    process {
        # Attempt to connect and retrieve the token
        try {
            $token = Invoke-RestMethod -Uri $global:tokenUri -Method Post -Headers $global:WUGBearerHeaders -Body $tokenBody
            # Check if the token contains all necessary fields
            if (-not $token.token_type -or -not $token.access_token -or -not $token.expires_in) {
                throw "Token retrieval was successful but did not contain all necessary fields (token_type, access_token, expires_in)."
            }
        }
        catch {
            if ($_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode.value__
                $statusDescription = $_.Exception.Response.StatusDescription
                $errorMsg = "Error: Response status code does not indicate success: $statusCode ($statusDescription).`nURI: $global:tokenUri"
            }
            else {
                $errorMsg = "Error: $($_.Exception.Message)`nURI: $global:tokenUri"
            }
            Write-Error $errorMsg
            throw $errorMsg
        }
        # Update the headers with the Authorization token for subsequent requests
        $global:WUGBearerHeaders["Authorization"] = "$($token.token_type) $($token.access_token)"
        # Store the token expiration
        $global:expiry = (Get-Date).AddSeconds($token.expires_in)
        # Store the refresh token
        $global:WUGRefreshToken = $token.refresh_token
    }

    end {
        # Output connection status and return the token details
        Write-Output "Connected to ${serverUri} to obtain authorization token for user `"${Username}`" which expires at ${global:expiry} UTC."

        # Save connection to vault after successful authentication
        if (-not $_fromVault) {
            try {
                _SaveWUGConnection -VaultDir $vaultDir -Path $vaultFile `
                    -Server $serverUri -ConnPort $Port -Proto $Protocol `
                    -User $Username -Pass $Password
                Write-Host "  Connection saved to vault." -ForegroundColor DarkGray
            }
            catch {
                Write-Verbose "Could not save connection to vault: $_"
            }
        }
    }
}
# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAkG2rd5knco7nY
# RJQjE6ArH/MuDSc5x9oWXrWy2K6mjKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgPQFnL6xGqZnTzRX4L1Sfiv8JwY9Iq21T
# 5NmyqEc8+xIwDQYJKoZIhvcNAQEBBQAEggIALiaDHbxIDEBKSG++44O+7YknXbiq
# 4aJUY4aSFEQebuv5Uuj19FtMqMbGQ0qt/l4ZVW0SVCppIy+Ce0LqiUxW1+Iuckvy
# 9a2WcFybf1omarTOEptZ44hocIp4WGz/EGiWnxWwEVJ30ZzAele1/nDHtyaBFmFe
# 89cR+CGPcVlrgr4r4ADbOhumnIkqtXTVxVGCqqPgDVW2qA23Mki22L3dxleEBZgE
# 6jV61Z4hb4cT8u8hrxm0LFKAj0I6+ZDs3ZSUpqT7Aa7Yo0nHi8b2d0/xYEqn4Ouq
# Cnl6LZxeBlaOD6pOb8HLduh5mneYmbYlCMTXh02j6BXn2MPZXMGimECrz1UtI85N
# jNBuh4/rk4E9p+jAYwt6yW6h4HdnPA/i7SZdpC6fQ/PS+eihGNZkt+y/QVL8Hsn4
# BmoOgowbjpKXHdLa/kWfSkMjhNzoY0bAbh4o6TiwXoCehoMPgo1iepwG5rK8ZS85
# 4EcktkpG+G12Tr17AKVPhGjcGwsYdmkY9wE2jNp5pv1TxNua/GeirdeR1d3S2HEG
# MHmtyKcvPzVT8NgVoldgUU4MDBwRDmPnGBKXcpIrkg6sw596gF+p1Wa1WvyMHMPk
# TKfSMOKpI/3t1ynNBUorbPL8VB5WRPKePqdRd3boPwuTajZKOUEv9kwKwy6xOIlY
# 1GkVY1rMfGwGHAw=
# SIG # End signature block
