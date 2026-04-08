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

.EXAMPLE
Connect-WUGServer -AutoConnect -IgnoreSSLErrors
Automatically uses the saved vault connection without prompting. Ideal for non-interactive/scheduled use.
Fails with an error if no saved connection exists.

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
        [string]$Password,

        # AutoConnect: use saved vault connection without prompting (for non-interactive/scheduled use)
        [Parameter(ParameterSetName = 'VaultSet')]
        [switch]$AutoConnect
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
                if ($AutoConnect) {
                    # Non-interactive: auto-use saved connection without prompting
                    $serverUri = $saved.Server
                    $Port = $saved.Port
                    $Protocol = $saved.Protocol
                    $Credential = $saved.Credential
                    $IgnoreSSLErrors = [switch]$true
                    $Username = $Credential.GetNetworkCredential().UserName
                    $Password = $Credential.GetNetworkCredential().Password
                    $_fromVault = $true
                    $useExisting = $true
                    Write-Host "  Auto-connecting to WUG: $preview" -ForegroundColor Cyan
                }
                else {
                    Write-Host ''
                    Write-Host "  Saved WUG connection found in vault:" -ForegroundColor Cyan
                    Write-Host "  $preview" -ForegroundColor Green
                    Write-Host ''
                    $choice = Read-Host -Prompt "  [Y] Use saved  [N] New connection  [R] Reset"
                    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = 'Y' }
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
            }
            if ($AutoConnect -and -not $useExisting) {
                throw "No saved WUG connection in vault. Run Connect-WUGServer interactively first to save a connection, or pass -Credential."
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
# MIIrwgYJKoZIhvcNAQcCoIIrszCCK68CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD35uu3jZHADgkX
# FqNvKBoHAuyGwQ6TgkJfJJ8dnwY7jqCCJNcwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggYUMIID/KADAgECAhB6I67a
# U2mWD5HIPlz0x+M/MA0GCSqGSIb3DQEBDAUAMFcxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28gUHVibGljIFRp
# bWUgU3RhbXBpbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1
# OTU5WjBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSww
# KgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjCCAaIw
# DQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAM2Y2ENBq26CK+z2M34mNOSJjNPv
# IhKAVD7vJq+MDoGD46IiM+b83+3ecLvBhStSVjeYXIjfa3ajoW3cS3ElcJzkyZlB
# nwDEJuHlzpbN4kMH2qRBVrjrGJgSlzzUqcGQBaCxpectRGhhnOSwcjPMI3G0hedv
# 2eNmGiUbD12OeORN0ADzdpsQ4dDi6M4YhoGE9cbY11XxM2AVZn0GiOUC9+XE0wI7
# CQKfOUfigLDn7i/WeyxZ43XLj5GVo7LDBExSLnh+va8WxTlA+uBvq1KO8RSHUQLg
# zb1gbL9Ihgzxmkdp2ZWNuLc+XyEmJNbD2OIIq/fWlwBp6KNL19zpHsODLIsgZ+WZ
# 1AzCs1HEK6VWrxmnKyJJg2Lv23DlEdZlQSGdF+z+Gyn9/CRezKe7WNyxRf4e4bwU
# trYE2F5Q+05yDD68clwnweckKtxRaF0VzN/w76kOLIaFVhf5sMM/caEZLtOYqYad
# tn034ykSFaZuIBU9uCSrKRKTPJhWvXk4CllgrwIDAQABo4IBXDCCAVgwHwYDVR0j
# BBgwFoAU9ndq3T/9ARP/FqFsggIv0Ao9FCUwHQYDVR0OBBYEFF9Y7UwxeqJhQo1S
# gLqzYZcZojKbMA4GA1UdDwEB/wQEAwIBhjASBgNVHRMBAf8ECDAGAQH/AgEAMBMG
# A1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYEVR0gADBMBgNVHR8ERTBD
# MEGgP6A9hjtodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1l
# U3RhbXBpbmdSb290UjQ2LmNybDB8BggrBgEFBQcBAQRwMG4wRwYIKwYBBQUHMAKG
# O2h0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY1RpbWVTdGFtcGlu
# Z1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNv
# bTANBgkqhkiG9w0BAQwFAAOCAgEAEtd7IK0ONVgMnoEdJVj9TC1ndK/HYiYh9lVU
# acahRoZ2W2hfiEOyQExnHk1jkvpIJzAMxmEc6ZvIyHI5UkPCbXKspioYMdbOnBWQ
# Un733qMooBfIghpR/klUqNxx6/fDXqY0hSU1OSkkSivt51UlmJElUICZYBodzD3M
# /SFjeCP59anwxs6hwj1mfvzG+b1coYGnqsSz2wSKr+nDO+Db8qNcTbJZRAiSazr7
# KyUJGo1c+MScGfG5QHV+bps8BX5Oyv9Ct36Y4Il6ajTqV2ifikkVtB3RNBUgwu/m
# SiSUice/Jp/q8BMk/gN8+0rNIE+QqU63JoVMCMPY2752LmESsRVVoypJVt8/N3qQ
# 1c6FibbcRabo3azZkcIdWGVSAdoLgAIxEKBeNh9AQO1gQrnh1TA8ldXuJzPSuALO
# z1Ujb0PCyNVkWk7hkhVHfcvBfI8NtgWQupiaAeNHe0pWSGH2opXZYKYG4Lbukg7H
# pNi/KqJhue2Keak6qH9A8CeEOB7Eob0Zf+fU+CCQaL0cJqlmnx9HCDxF+3BLbUuf
# rV64EbTI40zqegPZdA+sXCmbcZy6okx/SjwsusWRItFA3DE8MORZeFb6BmzBtqKJ
# 7l939bbKBy2jvxcJI98Va95Q5JnlKor3m0E7xpMeYRriWklUPsetMSf2NvUQa/E5
# vVyefQIwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqGSIb3DQEB
# DAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLTAr
# BgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0NjAeFw0y
# MTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENv
# ZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIB
# gQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZGbEN4QMgC
# sJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3haT29PST
# ahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/tfCK6cPu
# YHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06ShdnRqtZl
# V59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5pledi9lC
# BbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7IH60B+Ja7
# TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGgW+ufflcZ
# /ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+QOfdRrJZ
# b1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAgNpFcF4Xm
# MB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8EBAMCAYYw
# EgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAbBgNVHSAE
# FDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9j
# cmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9vdFI0Ni5j
# cmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0LnNlY3Rp
# Z28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdjMCMGCCsG
# AQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOC
# AgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9hcpkOTz5
# jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCymlaS98+Qp
# oBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+vd0xqlqd
# 099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4iTAWS+MVX
# eNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09Jlo8BMe8
# 0jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6bxuSKcut
# isqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3sTCggkHS
# RqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z1NZJ6ctu
# MFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls/GDnVNue
# KjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9ShQoPzmC
# cn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIEpqADAgEC
# AhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcNMjkwNDIx
# MjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGljdXQxFzAV
# BgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJlcmlubzCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b5TBj3I0V
# V/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3/1NK570Z
# BCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9gSjQSAE5
# Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JOxolpx+7R
# VjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10nVI7HW3e
# E8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYYx6IGrEA8
# 09R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J4S0eDEFI
# A3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IKMEsJ4v4G
# gx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZIzVZOFKu9
# BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2u3+F4SaP
# lxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy+jZctF6V
# vxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQPKssghyi4
# 7G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIBibAwDgYD
# VR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMw
# SgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYXaHR0cHM6
# Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FS
# MzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDovL2NydC5z
# ZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5jcnQwIwYI
# KwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3DQEBDAUA
# A4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK4o9SIefy
# e18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJFyJxRGft
# kdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNayomm7aWL
# AnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwISOX6sKS7C
# Km9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS6OJwlArc
# bFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvfFxJ9uu5t
# NiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tWiEv3rtVA
# pmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl6XE9Gw/T
# d6WKKKswggZiMIIEyqADAgECAhEApCk7bh7d16c0CIetek63JDANBgkqhkiG9w0B
# AQwFADBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSww
# KgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjAeFw0y
# NTAzMjcwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMHIxCzAJBgNVBAYTAkdCMRcwFQYD
# VQQIEw5XZXN0IFlvcmtzaGlyZTEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTAw
# LgYDVQQDEydTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIFNpZ25lciBSMzYw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDThJX0bqRTePI9EEt4Egc8
# 3JSBU2dhrJ+wY7JgReuff5KQNhMuzVytzD+iXazATVPMHZpH/kkiMo1/vlAGFrYN
# 2P7g0Q8oPEcR3h0SftFNYxxMh+bj3ZNbbYjwt8f4DsSHPT+xp9zoFuw0HOMdO3sW
# eA1+F8mhg6uS6BJpPwXQjNSHpVTCgd1gOmKWf12HSfSbnjl3kDm0kP3aIUAhsodB
# YZsJA1imWqkAVqwcGfvs6pbfs/0GE4BJ2aOnciKNiIV1wDRZAh7rS/O+uTQcb6JV
# zBVmPP63k5xcZNzGo4DOTV+sM1nVrDycWEYS8bSS0lCSeclkTcPjQah9Xs7xbOBo
# CdmahSfg8Km8ffq8PhdoAXYKOI+wlaJj+PbEuwm6rHcm24jhqQfQyYbOUFTKWFe9
# 01VdyMC4gRwRAq04FH2VTjBdCkhKts5Py7H73obMGrxN1uGgVyZho4FkqXA8/uk6
# nkzPH9QyHIED3c9CGIJ098hU4Ig2xRjhTbengoncXUeo/cfpKXDeUcAKcuKUYRNd
# GDlf8WnwbyqUblj4zj1kQZSnZud5EtmjIdPLKce8UhKl5+EEJXQp1Fkc9y5Ivk4A
# ZacGMCVG0e+wwGsjcAADRO7Wga89r/jJ56IDK773LdIsL3yANVvJKdeeS6OOEiH6
# hpq2yT+jJ/lHa9zEdqFqMwIDAQABo4IBjjCCAYowHwYDVR0jBBgwFoAUX1jtTDF6
# omFCjVKAurNhlxmiMpswHQYDVR0OBBYEFIhhjKEqN2SBKGChmzHQjP0sAs5PMA4G
# A1UdDwEB/wQEAwIGwDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUF
# BwMIMEoGA1UdIARDMEEwNQYMKwYBBAGyMQECAQMIMCUwIwYIKwYBBQUHAgEWF2h0
# dHBzOi8vc2VjdGlnby5jb20vQ1BTMAgGBmeBDAEEAjBKBgNVHR8EQzBBMD+gPaA7
# hjlodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBp
# bmdDQVIzNi5jcmwwegYIKwYBBQUHAQEEbjBsMEUGCCsGAQUFBzAChjlodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBpbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQACgT6khnJRIfllqS49Uorh5ZvMSxNEk4SNsi7qvu+bNdcuknHg
# XIaZyqcVmhrV3PHcmtQKt0blv/8t8DE4bL0+H0m2tgKElpUeu6wOH02BjCIYM6HL
# InbNHLf6R2qHC1SUsJ02MWNqRNIT6GQL0Xm3LW7E6hDZmR8jlYzhZcDdkdw0cHhX
# jbOLsmTeS0SeRJ1WJXEzqt25dbSOaaK7vVmkEVkOHsp16ez49Bc+Ayq/Oh2BAkST
# Fog43ldEKgHEDBbCIyba2E8O5lPNan+BQXOLuLMKYS3ikTcp/Qw63dxyDCfgqXYU
# hxBpXnmeSO/WA4NwdwP35lWNhmjIpNVZvhWoxDL+PxDdpph3+M5DroWGTc1ZuDa1
# iXmOFAK4iwTnlWDg3QNRsRa9cnG3FBBpVHnHOEQj4GMkrOHdNDTbonEeGvZ+4nSZ
# XrwCW4Wv2qyGDBLlKk3kUW1pIScDCpm/chL6aUbnSsrtbepdtbCLiGanKVR/KC1g
# sR0tC6Q0RfWOI4owggaCMIIEaqADAgECAhA2wrC9fBs656Oz3TbLyXVoMA0GCSqG
# SIb3DQEBDAUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKTmV3IEplcnNleTEU
# MBIGA1UEBxMLSmVyc2V5IENpdHkxHjAcBgNVBAoTFVRoZSBVU0VSVFJVU1QgTmV0
# d29yazEuMCwGA1UEAxMlVVNFUlRydXN0IFJTQSBDZXJ0aWZpY2F0aW9uIEF1dGhv
# cml0eTAeFw0yMTAzMjIwMDAwMDBaFw0zODAxMTgyMzU5NTlaMFcxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28g
# UHVibGljIFRpbWUgU3RhbXBpbmcgUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCIndi5RWedHd3ouSaBmlRUwHxJBZvMWhUP2ZQQRLRBQIF3
# FJmp1OR2LMgIU14g0JIlL6VXWKmdbmKGRDILRxEtZdQnOh2qmcxGzjqemIk8et8s
# E6J+N+Gl1cnZocew8eCAawKLu4TRrCoqCAT8uRjDeypoGJrruH/drCio28aqIVEn
# 45NZiZQI7YYBex48eL78lQ0BrHeSmqy1uXe9xN04aG0pKG9ki+PC6VEfzutu6Q3I
# cZZfm00r9YAEp/4aeiLhyaKxLuhKKaAdQjRaf/h6U13jQEV1JnUTCm511n5avv4N
# +jSVwd+Wb8UMOs4netapq5Q/yGyiQOgjsP/JRUj0MAT9YrcmXcLgsrAimfWY3MzK
# m1HCxcquinTqbs1Q0d2VMMQyi9cAgMYC9jKc+3mW62/yVl4jnDcw6ULJsBkOkrcP
# LUwqj7poS0T2+2JMzPP+jZ1h90/QpZnBkhdtixMiWDVgh60KmLmzXiqJc6lGwqoU
# qpq/1HVHm+Pc2B6+wCy/GwCcjw5rmzajLbmqGygEgaj/OLoanEWP6Y52Hflef3XL
# vYnhEY4kSirMQhtberRvaI+5YsD3XVxHGBjlIli5u+NrLedIxsE88WzKXqZjj9Zi
# 5ybJL2WjeXuOTbswB7XjkZbErg7ebeAQUQiS/uRGZ58NHs57ZPUfECcgJC+v2wID
# AQABo4IBFjCCARIwHwYDVR0jBBgwFoAUU3m/WqorSs9UgOHYm8Cd8rIDZsswHQYD
# VR0OBBYEFPZ3at0//QET/xahbIICL9AKPRQlMA4GA1UdDwEB/wQEAwIBhjAPBgNV
# HRMBAf8EBTADAQH/MBMGA1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYE
# VR0gADBQBgNVHR8ESTBHMEWgQ6BBhj9odHRwOi8vY3JsLnVzZXJ0cnVzdC5jb20v
# VVNFUlRydXN0UlNBQ2VydGlmaWNhdGlvbkF1dGhvcml0eS5jcmwwNQYIKwYBBQUH
# AQEEKTAnMCUGCCsGAQUFBzABhhlodHRwOi8vb2NzcC51c2VydHJ1c3QuY29tMA0G
# CSqGSIb3DQEBDAUAA4ICAQAOvmVB7WhEuOWhxdQRh+S3OyWM637ayBeR7djxQ8Si
# hTnLf2sABFoB0DFR6JfWS0snf6WDG2gtCGflwVvcYXZJJlFfym1Doi+4PfDP8s0c
# qlDmdfyGOwMtGGzJ4iImyaz3IBae91g50QyrVbrUoT0mUGQHbRcF57olpfHhQESt
# z5i6hJvVLFV/ueQ21SM99zG4W2tB1ExGL98idX8ChsTwbD/zIExAopoe3l6JrzJt
# Pxj8V9rocAnLP2C8Q5wXVVZcbw4x4ztXLsGzqZIiRh5i111TW7HV1AtsQa6vXy63
# 3vCAbAOIaKcLAo/IU7sClyZUk62XD0VUnHD+YvVNvIGezjM6CRpcWed/ODiptK+e
# vDKPU2K6synimYBaNH49v9Ih24+eYXNtI38byt5kIvh+8aW88WThRpv8lUJKaPn3
# 7+YHYafob9Rg7LyTrSYpyZoBmwRWSE4W6iPjB7wJjJpH29308ZkpKKdpkiS9WNsf
# /eeUtvRrtIEiSJHN899L1P4l6zKVsdrUu1FX1T/ubSrsxrYJD+3f3aKg6yxdbugo
# t06YwGXXiy5UUGZvOu3lXlxA+fC13dQ5OlL2gIb5lmF6Ii8+CQOYDwXM+yd9dbmo
# cQsHjcRPsccUd5E9FiswEqORvz8g3s+jR3SFCgXhN4wz7NgAnOgpCdUo4uDyllU9
# PzGCBkEwggY9AgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3RpZ28g
# TGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5nIENB
# IFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgorBgEE
# AYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwG
# CisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCvi+hM
# 1QBDpjhZbMvm4s02pW0RlXVpMMQSQcmJWL/f7TANBgkqhkiG9w0BAQEFAASCAgAB
# u/riat75EtJKvUvioCQ8GSUw2oLOhwRyqsbMjBarvAup6ZlYJlDw5zRRUr+eCq0o
# scNH/Ip8eSJ8pxwgQGZNrhEF4ZRScsWSJQHIQ6Stmft80q5pXRCAM/pugLACmdmq
# 04QIUpj5Hmd3V2+vUex1oridso4ZnfaBWAD3FM+6Q9p3SlhqOZNJSVOrvlrGBolB
# zMnSqZ6IS4Xv1Iwr874s8rd30zvhiSrknyzPNzZlhYm0mjEIwpUj6LWj9td1huJ5
# fFmcxIifslZFGZXw7yE36Hr1IIdtJwff2eAbJFX7Naa4o36s/WMGcgju5G9TfS6S
# ZXEKPoaYx2gGUDSCS6O/ip/F7nqGEAx4NDWRdD2gFAb20QFRu6cca4P/GEKx/UR9
# VSAtl8wWCCJLqXsVkylZ/w45/BqvaiOXC2LqoUBIRgqqP6D111W+NMTbz79+JU8G
# z0GVFiEDQuOfaXZFkkrC/KtW/x/3DlwHzMuKGw9gAD4dHjJ3eeuiucfHZGmlKRGI
# 7gWdzREZWl/N7+ldfRwLkC0l/BNW7Jmo/suCNyNyBPYibaUJmbtJz/Dg8giff2aI
# jXIwyrkGmxR27fESRTWJCZwyk3NyG0J4ejLuu+EU+CFhJB5UWDoQzLfaZjSSSiNg
# RumjME4ZBIDMDwrEX8FV3Q0rcGITPSPT4vr3dAt9ZKGCAyMwggMfBgkqhkiG9w0B
# CQYxggMQMIIDDAIBATBqMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdv
# IExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcg
# Q0EgUjM2AhEApCk7bh7d16c0CIetek63JDANBglghkgBZQMEAgIFAKB5MBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDQwNzExNTEz
# NFowPwYJKoZIhvcNAQkEMTIEMFBeHG59DrYybDfJouLZ1d4GhDnDyT7QbUujpCwq
# i/ny8/VSdCE4BxAo/pYXjrS7FzANBgkqhkiG9w0BAQEFAASCAgAIb+M+/dN7dTLx
# 9NK6Z2T3TdONiFNSy7yfoXBtqANpfV/JQQSyeVOE60fTzdFNBOMGAlyRTuaZdv6G
# 2zwx6VeBjTPN4Q7V91AUdw8/+Hy/5ZPttqvQ46IPVPDDT+Fs+aIt5dJ7p6wtLDIR
# W7MLQSOD3PK/TSD/iIp+yEputf35UXg15fQdl6QqS1smpxV+jAMLqP1In6b2ue2l
# wElWSy/LU8qL4L2cE+k3tMCX5sxwgAudTBQD28b8G1PMlV6hyKKVNFeWqW73tM/a
# YCyYtCktoy6lccxiBjl/GNhXj9ThTMUV+ja8Yu2RdRe/u1Lw7BCme1tu0Y9+Pmpo
# UqPd1h2wp4XyARHc7aiWxjixhVPg/xmkaP1DEyo4alrRmYdSMoAatdNjqtVetIyQ
# qnBo3alx/itrCk1O4IqVBuCq7KyPOSO6KSz8sOMD4wGPFWpVYUNXKWLrpGApBmNm
# xltD2c2CV4vow1x0yTk/31fKoezJD2JcgWH88X/LqsfuDCFL5AVatRzAnNqetrHa
# KApg3DDlVK03XTdVuURoToKVASrNWu5PGjkqLhpipn7wtZPnXMM8YWLwwW5D5vIu
# T8jH0xm/StftHWdsry6tfuKJm2j7adqjgpnSKELK2OLOmkUK8eBo3zZXvpzNpmp9
# MHSgUE/ifwwK06m8AwTBlq5sYYYBeQ==
# SIG # End signature block
