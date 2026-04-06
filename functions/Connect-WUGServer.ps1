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

        # Warn if plaintext username/password parameters are used
        if ($PSCmdlet.ParameterSetName -eq 'UserPassSet') {
            Write-Warning "Plaintext -Username/-Password detected. These values may appear in PSReadLine history and script logs. Prefer -Credential (PSCredential) or vault-based connection (no parameters) instead."
        }

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
                # Verify integrity (HMAC-SHA256 if key exists, fall back to SHA-256 for legacy)
                if ($obj.Integrity) {
                    $intInput = "$($obj.Encrypted)|$($env:COMPUTERNAME)|$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
                    $hmacKeyFile = Join-Path (Split-Path $Path -Parent) '.vault-hmac.key'
                    $verifyHash = $null
                    if (Test-Path $hmacKeyFile) {
                        try {
                            $hmacEnc = [System.IO.File]::ReadAllText($hmacKeyFile).Trim()
                            $hmacSS = ConvertTo-SecureString -String $hmacEnc
                            $hmacBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($hmacSS)
                            try { $hmacB64 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($hmacBstr) }
                            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($hmacBstr) }
                            $hmacKeyBytes = [Convert]::FromBase64String($hmacB64)
                            $hmacB64 = $null
                            $hmac = New-Object System.Security.Cryptography.HMACSHA256
                            $hmac.Key = $hmacKeyBytes
                            $hBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($intInput))
                            $hmac.Dispose()
                            for ($j = 0; $j -lt $hmacKeyBytes.Length; $j++) { $hmacKeyBytes[$j] = 0 }
                            $verifyHash = [BitConverter]::ToString($hBytes) -replace '-', ''
                        }
                        catch { $verifyHash = $null }
                    }
                    if (-not $verifyHash) {
                        # Legacy fallback: plain SHA-256 (for creds saved before HMAC migration)
                        $sha = [System.Security.Cryptography.SHA256]::Create()
                        $hBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($intInput))
                        $sha.Dispose()
                        $verifyHash = [BitConverter]::ToString($hBytes) -replace '-', ''
                    }
                    if ($obj.Integrity -ne $verifyHash) {
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
                catch { Write-Warning "Could not restrict vault directory ACL: $_. Credentials may be accessible to other users on this system." }
            }
            $combined = "$Server|$ConnPort|$Proto|$User|$Pass"
            $ss = ConvertTo-SecureString $combined -AsPlainText -Force
            $encrypted = ConvertFrom-SecureString -SecureString $ss
            # HMAC-SHA256 integrity using a DPAPI-protected random key
            $hmacKeyFile = Join-Path $VaultDir '.vault-hmac.key'
            $hmacKeyBytes = $null
            if (Test-Path $hmacKeyFile) {
                try {
                    $hmacEnc = [System.IO.File]::ReadAllText($hmacKeyFile).Trim()
                    $hmacSS = ConvertTo-SecureString -String $hmacEnc
                    $hmacBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($hmacSS)
                    try { $hmacB64 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($hmacBstr) }
                    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($hmacBstr) }
                    $hmacKeyBytes = [Convert]::FromBase64String($hmacB64)
                    $hmacB64 = $null
                }
                catch { $hmacKeyBytes = $null }
            }
            if (-not $hmacKeyBytes) {
                # Generate and DPAPI-protect a new HMAC key
                $hmacKeyBytes = New-Object byte[] 32
                $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
                $rng.GetBytes($hmacKeyBytes)
                $rng.Dispose()
                $hmacB64 = [Convert]::ToBase64String($hmacKeyBytes)
                $hmacSS = ConvertTo-SecureString $hmacB64 -AsPlainText -Force
                $hmacEnc = ConvertFrom-SecureString -SecureString $hmacSS
                [System.IO.File]::WriteAllText($hmacKeyFile, $hmacEnc, [System.Text.UTF8Encoding]::new($true))
                $hmacB64 = $null
            }
            $intInput = "$encrypted|$($env:COMPUTERNAME)|$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
            $hmac = New-Object System.Security.Cryptography.HMACSHA256
            $hmac.Key = $hmacKeyBytes
            $hBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($intInput))
            $hmac.Dispose()
            for ($i = 0; $i -lt $hmacKeyBytes.Length; $i++) { $hmacKeyBytes[$i] = 0 }
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
        # WARNING: On PowerShell 5.1, SSL bypass is process-wide and cannot be scoped per-request.
        # This affects all .NET HTTP connections in this process until Disconnect-WUGServer is called.
        # On PowerShell 7+, SkipCertificateCheck is scoped via PSDefaultParameterValues.
        if ($IgnoreSSLErrors -and $Protocol -eq "https") {
            if ($PSVersionTable.PSEdition -eq 'Core') { 
                $Script:PSDefaultParameterValues["invoke-restmethod:SkipCertificateCheck"] = $true
                $Script:PSDefaultParameterValues["invoke-webrequest:SkipCertificateCheck"] = $true
            } else {
                # Scope SSL bypass to the WUG server hostname only (PS 5.1 limitation: callback is process-wide,
                # but we check the hostname inside), so other HTTPS connections are still validated.
                $global:_WUGAllowedSSLHosts = @($serverUri.ToLower())
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
                    param($sender, $certificate, $chain, $sslPolicyErrors)
                    if ($sslPolicyErrors -eq [System.Net.Security.SslPolicyErrors]::None) { return $true }
                    # Only bypass for the WUG server hostname
                    if ($sender -is [System.Net.HttpWebRequest]) {
                        $reqHost = ([System.Uri]$sender.RequestUri).Host.ToLower()
                        if ($global:_WUGAllowedSSLHosts -contains $reqHost) { return $true }
                    }
                    return $false
                }
            }
            Write-Warning "Ignoring SSL certificate validation errors for $serverUri. Use Disconnect-WUGServer to restore validation."
        }    
    
        # Set variables
        $global:IgnoreSSLErrors = $IgnoreSSLErrors
        $global:WhatsUpServerBaseURI = "${Protocol}://${serverUri}:${Port}"
        $global:tokenUri = "${global:WhatsUpServerBaseURI}${TokenEndpoint}"
        $global:WUGBearerHeaders = @{"Content-Type" = "application/json" }
        $encUser = [System.Uri]::EscapeDataString($Username)
        $encPass = [System.Uri]::EscapeDataString($Password)
        $tokenBody = "grant_type=password&username=${encUser}&password=${encPass}"
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
        # Output connection status
        Write-Host "Connected to ${serverUri} as `"${Username}`". Token expires at ${global:expiry} UTC." -ForegroundColor Green

        # Save connection to vault after successful authentication
        # IMPORTANT: Must save BEFORE clearing $Password from memory
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

        # Clear plaintext credential variables from memory
        $tokenBody = $null
        $Password = $null
    }
}
# SIG # Begin signature block
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCeS4Q4ykonRbwz
# eOngfXsodrEa6bCDMQr+oEEKsA4HtqCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgK5h66pomTRyvD/5z60cN3iePOJeJBM35
# VUYaLo6sWfgwDQYJKoZIhvcNAQEBBQAEggIAe5mquLlljEtz5dFVUG4guUkym7Ii
# fvxFote2O87iYhEyviM4FR92Z6XXqwCnYtUF+JA0tjvYGrBaha2G39WrtR6SMtpu
# 0sNQf2KVIRY058iEL1PbedC3Lf7+ZTaN92VytloXpcWhR5TWyrOpoBDeLBeWW5k5
# rJJy9+HngjBsif16zpnm4iICImL3K7Pga2AILmADJvdJ+MUB6y/APipZKpcaDtbW
# qPaQp1u6cCjwDLJReYyKL6NezpS7rrXBZXitju5m3Cl39PGSJbG1KoNAqLcFsJpi
# sO4RBvNeJsqEJZu9J11jvRPLHaT3z1KfdPPJ1FfRG7bz/5Xv4bb+T7mThWl/fg18
# QMZLBQKbgZZnjL2xf8OGyrjJJIj274Y4aorcDeajZD1e1Llxvkp273S2CT6gbwMm
# D5m4RcYExgpwyzxBbPHx45begqa0yVTmux9hZmwmGfA5LRYIz5pSkNOINDq+Klqe
# MF7IlVgxnxN8fyVqdPlMEiIVXl3yoYikvweGweuZ86AY085so4+OpOYTA0Y9xxpi
# At4TGiz7wuLFFxMK9w124QBHsFA4SG4G8x8dsT9lnGgVeUtAiNj85pXUhqv+TW99
# CdlbgmGMPsMOcp3gDvei1eXE6BdIn5jeYg7W8zv8OJdUGw+4zZxHEf931FWG3G0+
# 7ZlOCvPl5R+ZWGw=
# SIG # End signature block
