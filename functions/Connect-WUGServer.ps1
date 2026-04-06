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
%LOCALAPPDATA%\WhatsUpGoldPS\DiscoveryHelpers\Vault and is interoperable with the DiscoveryHelpers credential vault.

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
        $vaultDir  = Join-Path $env:LOCALAPPDATA 'WhatsUpGoldPS\DiscoveryHelpers\Vault'
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
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBIkHwLBPbIbKLs
# U5yNZ8+zW46XrEtLzbEdxbHd72S/v6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# BCDr8JzQgl0uoiHJrpyiIuFsOFp4QYysZe454+tvnUb7IjANBgkqhkiG9w0BAQEF
# AASCAgCmZ4srfKQA3r6Z0XllBm2MY8tO5cY6HAguDcGHAvkTUu+SnRtOsYQ5R57K
# CKbKkF4IG0WOQ9AmKTYGHRE+iDBcBlRIgxyFdy5RIT6FklnvZFKx9j2W1RbZrn9h
# /xj7HQutuAz22w/cOtiNnBiTNZWuTr97pUg8ZWGqURzo8FR6gz8jnor1xxaZDQGL
# wz3xwJiXdsINZJlBbNgP+Bck5iNDcGdtxdsSKLVwIW3s+QpAwbECiy82YUjriLrW
# SGoMKj2bWoMlQ7+zJdqjc/QE4AAS/BzWDI8/mHnnpO7Scm/ccNRDN8F+DEQ2FInL
# NogmkXISyRcLbLahCuBgmd2vELvM/9wiEu0XcQlm058+QKXKWQs0QEsfuzD/hFAV
# Ar9M2bUOtTgP0Gi96MMS22PwjvABENsYQW92tduwrWaOw+1y+FF1zrHDyXUB4R+c
# VS2i+P2Lrsr/Tly65jrZgLd8BGdHFM2d/F2QG3mqGJDhavamUojKG6QinP5WxKLz
# WVvRL5biQl3jVMXT+WuGa1l9CqRxOLQ5ZePzWBv1VQSd4b+RpxiWR2YTsUteW7hu
# CJEiOF0AoEW5vtRkULAi0HuP9UENjtrxjO3my2H7cF7YA29BipV/Gh5ANjigYguh
# +4wSns/ekG+R6ofZUzjgyK61AALW4Fx+fqgKL81ExAsHJZGH2KGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA0MDYxOTMzMTBaMC8GCSqGSIb3DQEJBDEiBCAW+x65
# 2FyqKnfY2AsndTVEvYOuvFInD5NxHynIaWrHDjANBgkqhkiG9w0BAQEFAASCAgA4
# ZONlJQbBovT5xMOkXjd3qcNpF9SEjy6ev1EGMoR7muJ2kIUW6a39aoy4O+ASZLbF
# h3Epq8FmeZ7GtFl4gzLjbAjrivjHExwBWPLWbPBVEgmh5Rgsv45NyCPoCRBnI0zA
# 4HA8DF2RXEODWivyM2VMNnzeDm+KZfVl1BJqA1S8UsNk6bEVXAkWx2FC8ose7HuQ
# JPUclDKXGiKsn3kNuAznSGgP9XYGJyF8SAQ0qYYcJljG6JrpkTG7lxidHMQEoHq5
# UDaZlgHoDvRE/eSyLS5kPYX25exOGMK934vCWtb5dAY6fnNoB/ttAxqu4M9/6pol
# SVex+g+YSXMtBrBH7N8SPBTF2ycpxJk5PXKpLABgS7mMu5KxTj1Z1wIAGODJS8Ks
# GTE9VNnS+ByrBIh0q7KXhIFt9FePZrVQvFJAwWuCD4QIFAJTy1hCpglywKFOoGQi
# dTzkIiErlWAcMdSX2kQMlC4Amjl18hjgW+Ll8QsJULnSLMOucZzxXSgViqw6AykD
# 1dFqoBjQPrXq/9olSW/LcWU/BqjTWPMrc9TlTsD8jJjoWdox1MqsIuYxbdI97GLk
# Nok26qtctNrWO++7la80Zd0mx4SLC/kRO9PVsL3Qif2B9es8y7DD1meNb1zyVWhf
# qi6HI8DmZY0aoTguaZ5MZNwLZCQWyp2rVJxv7TtdbQ==
# SIG # End signature block
