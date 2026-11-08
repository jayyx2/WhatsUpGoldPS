#requires -Version 5.1
function Deploy-DashboardWebConfig {
    <#
    .SYNOPSIS
        Deploys the shared WUG dashboard anonymous-access restriction.
    .PARAMETER Path
        Existing dashboard directory.
    .PARAMETER ProtectStaticFiles
        Enable managed authorization for static files, deny anonymous users first,
        disable directory browsing and block JSON requests for dashboard packs.
    .EXAMPLE
        Deploy-DashboardWebConfig -Path C:\WUG\Html\NmConsole\dashboards
    .NOTES
        Requires inherited WUG Forms authentication. Failures terminate.
    .LINK
        ..\interfaces\README.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$ProtectStaticFiles
    )
    $webConfigPath = Join-Path $Path 'web.config'
    $webConfigContent = @'
<?xml version="1.0" encoding="UTF-8"?>
<!--
    Deployed by WhatsUpGoldPS dashboard helpers.
    Denies anonymous access so users must authenticate through the
    WhatsUp Gold web console before viewing dashboard reports.
    Delete this file to restore anonymous access to this folder.
-->
<configuration>
  <system.web>
    <authorization>
      <deny users="?" />
    </authorization>
    <customErrors mode="On">
      <error statusCode="401" redirect="/NmConsole" />
    </customErrors>
  </system.web>
</configuration>
'@
    if ($ProtectStaticFiles) {
        $webConfigContent = @'
<?xml version="1.0" encoding="UTF-8"?>
<!-- WhatsUpGoldPS owned dashboard pack: inherited WUG Forms authentication required. -->
<configuration>
  <system.web>
    <authorization>
      <deny users="?" />
      <allow users="*" />
    </authorization>
  </system.web>
  <system.webServer>
    <modules runAllManagedModulesForAllRequests="true" />
    <directoryBrowse enabled="false" />
    <security>
      <requestFiltering>
        <fileExtensions>
          <remove fileExtension=".json" />
          <add fileExtension=".json" allowed="false" />
        </fileExtensions>
      </requestFiltering>
    </security>
  </system.webServer>
</configuration>
'@
    }
    if (-not (Test-Path -LiteralPath $webConfigPath) -or [IO.File]::ReadAllText($webConfigPath) -cne $webConfigContent) {
        [IO.File]::WriteAllText($webConfigPath, $webConfigContent, [Text.UTF8Encoding]::new($true))
    }
    if ([IO.File]::ReadAllText($webConfigPath) -cne $webConfigContent) {
        throw "Dashboard web.config verification failed: $webConfigPath"
    }
    Write-Verbose "Deployed dashboard authentication configuration: $webConfigPath"
}

function Get-WUGDashboardGroupPageName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Group page names cannot be blank.' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Name.Trim().ToLowerInvariant()))
        'group-' + [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant() + '.html'
    }
    finally { $hash.Dispose() }
}

function Get-WUGDashboardPackFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourcePath)
    $decoded = Get-Content -LiteralPath (Join-Path $SourcePath 'groups.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $groups = @($decoded)
    if ($groups.Count -eq 0) { throw 'The source pack contains no groups.' }
    $seen = @{}
    for ($i = 0; $i -lt $groups.Count; $i++) {
        $name = 'group-{0:D2}.html' -f ($i + 1)
        if ($groups[$i].PSObject.Properties['PageName']) {
            $expected = Get-WUGDashboardGroupPageName -Name $groups[$i].Name
            if ($groups[$i].PageName -cne $expected) { throw 'Invalid stable group page name in manifest.' }
            $name = $expected
        }
        if ($seen.ContainsKey($name)) { throw "Duplicate page name in manifest: $name" }
        $seen[$name] = $true
        $name
    }
    'index.html'
}

function Assert-WUGDashboardRegularPath {
    param([Parameter(Mandatory)][string]$Path, [switch]$Directory)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        ($Directory -and -not $item.PSIsContainer) -or
        (-not $Directory -and $item.PSIsContainer)) {
        throw "Publishing path has an unexpected type or is a reparse point: $Path"
    }
}

function Get-WUGDashboardPublishedFiles {
    param([Parameter(Mandatory)][string]$Path)
    @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | Where-Object {
        $_.Name -eq 'web.config' -or $_.Name -eq 'index.html' -or
        $_.Name -match '^group-(?:[0-9]{2,}|[a-f0-9]{64})\.html$'
    } | ForEach-Object {
        Assert-WUGDashboardRegularPath -Path $_.FullName
        $_.Name
    })
}

function Assert-WUGDashboardRecoveryTree {
    param([string]$Path)
    Assert-WUGDashboardRegularPath -Path $Path -Directory
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Recovery path is a reparse point: $($item.FullName)" }
        if ($item.PSIsContainer) { Assert-WUGDashboardRecoveryTree -Path $item.FullName }
    }
}

function New-WUGDashboardPrivateDirectory {
    param([string]$Path)
    # Create with a restrictive ACL, rather than briefly inheriting web/report access.
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    foreach ($sid in @($identity, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    $null = [IO.Directory]::CreateDirectory($Path, $acl)
}

function Restore-WUGDashboardPack {
    param([string]$Destination, [string]$TransactionPath)
    $pending = Join-Path $TransactionPath 'pending.txt'
    Assert-WUGDashboardRegularPath -Path $pending
    $mode = [IO.File]::ReadAllText($pending)
    if ($mode -notin @('existing', 'new')) { throw 'Invalid dashboard recovery journal.' }
    $backup = Join-Path $TransactionPath 'backup'
    Assert-WUGDashboardRegularPath -Path $backup -Directory
    $manifest = Join-Path $TransactionPath 'snapshot.txt'
    Assert-WUGDashboardRegularPath -Path $manifest
    $entries = @([IO.File]::ReadAllLines($manifest))
    $hashes = @{}
    foreach ($entry in $entries) {
        if ($entry -notmatch '^(web\.config|index\.html|group-(?:[0-9]{2,}|[a-f0-9]{64})\.html)\|([A-Fa-f0-9]{64})$') {
            throw 'Invalid dashboard backup manifest.'
        }
        $name = $Matches[1]; $expected = $Matches[2]
        if ($hashes.ContainsKey($name)) { throw 'Duplicate dashboard backup entry.' }
        $file = Join-Path $backup $name
        Assert-WUGDashboardRegularPath -Path $file
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256 -ErrorAction Stop).Hash -ne $expected) {
            throw "Dashboard backup verification failed: $name"
        }
        $hashes[$name] = $expected
    }
    if ($mode -eq 'existing' -and -not $hashes.ContainsKey('web.config')) {
        throw 'Dashboard recovery is missing its original protection configuration.'
    }
    if (Test-Path -LiteralPath $Destination) {
        Assert-WUGDashboardRegularPath -Path $Destination -Directory
    }
    else { $null = New-Item -ItemType Directory -Path $Destination -ErrorAction Stop }
    $current = @(Get-WUGDashboardPublishedFiles -Path $Destination)
    Deploy-DashboardWebConfig -Path $Destination -ProtectStaticFiles -ErrorAction Stop
    foreach ($name in @($hashes.Keys | Where-Object { $_ -ne 'web.config' }) + @('web.config')) {
        if (-not $hashes.ContainsKey($name)) { continue }
        $file = Join-Path $Destination $name
        Copy-Item -LiteralPath (Join-Path $backup $name) -Destination $file -Force -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256 -ErrorAction Stop).Hash -ne $hashes[$name]) {
            throw "Restored dashboard verification failed: $name"
        }
    }
    foreach ($name in $current) {
        if ($name -ne 'web.config' -and -not $hashes.ContainsKey($name)) {
            Remove-Item -LiteralPath (Join-Path $Destination $name) -Force -ErrorAction Stop
        }
    }
    # A failed first publish remains an empty, protected, owned directory.
    Remove-Item -LiteralPath $pending -Force -ErrorAction Stop
}

function Copy-WUGDashboardPack {
    <#
    .SYNOPSIS
        Publishes an interface HTML pack into an owned NmConsole subdirectory.
    .DESCRIPTION
        Validates the source manifest and parent Forms authentication, installs
        static-file protection first, stages and verifies the complete HTML pack,
        then promotes pages under an exclusive destination-wide lock. A verified
        on-disk snapshot restores the previous managed pages on failure.
        Never publishes raw groups.json or replaces the NmConsole web.config.
    .PARAMETER SourcePath
        Generated pack directory containing index.html, groups.json and group pages.
    .PARAMETER NmConsolePath
        Existing local WUG Html\NmConsole directory. Auto-detected if omitted.
    .PARAMETER PackName
        Single URL-safe directory name under NmConsole\dashboards. Required.
    .EXAMPLE
        Copy-WUGDashboardPack -SourcePath C:\ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\AllInterfaces -PackName interfaces-all
    .NOTES
        Run on the WUG server with write permissions. Web authentication must be
        verified on the actual IIS site; a successful copy alone does not prove it.
        Promotion is per-file, NOT an atomic whole-pack switch: concurrent IIS
        readers can briefly see mixed versions. Ordinary failures roll back before
        returning; process termination leaves a pending journal recovered by the
        next non-WhatIf publish to the same destination, even from another source.
        Recovery files are kept outside the web in
        %ProgramData%\WhatsUpGoldPS\DashboardPublishing, keyed by destination.
        Newly created storage grants access only to the creating identity, SYSTEM
        and Administrators. Existing storage ACLs are preserved; administrators
        must maintain these restrictions. Cross-identity mutex/ACL access errors
        fail explicitly, without falling back to an uncoordinated publish.
        No JSON is copied to the web.
        Rollback failures terminate with both errors and retain the journal for
        retry; no unattended recovery service is installed. A failed first publish
        leaves an empty protected owned directory. The lock rejects overlapping
        publishes immediately, across source profiles and Windows processes.
        Recovery is not a power-loss durability guarantee or a defense against
        administrators modifying files concurrently outside this helper.
    .LINK
        ..\interfaces\README.md
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$NmConsolePath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$')][string]$PackName
    )
    $source = Get-Item -LiteralPath $SourcePath -ErrorAction Stop
    if (-not $source.PSIsContainer) { throw 'SourcePath must be a generated pack directory.' }
    Assert-WUGDashboardRegularPath -Path $source.FullName -Directory
    Assert-WUGDashboardRegularPath -Path (Join-Path $source.FullName 'groups.json')
    $names = @(Get-WUGDashboardPackFiles -SourcePath $source.FullName)
    foreach ($name in $names) {
        $file = Get-Item -LiteralPath (Join-Path $source.FullName $name) -ErrorAction Stop
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Source dashboard must be a regular file: $name"
        }
    }
    if (-not $NmConsolePath) {
        $candidates = @(
            (Join-Path ${env:ProgramFiles(x86)} 'Ipswitch\WhatsUp\Html\NmConsole'),
            (Join-Path $env:ProgramFiles 'Ipswitch\WhatsUp\Html\NmConsole')
        )
        $NmConsolePath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
        if (-not $NmConsolePath) {
            throw 'No local WUG NmConsole installation found. Run on the WUG server or supply -NmConsolePath.'
        }
    }
    $console = Get-Item -LiteralPath $NmConsolePath -ErrorAction Stop
    if (-not $console.PSIsContainer) { throw 'NmConsolePath must be an existing directory.' }
    $parentConfig = [xml](Get-Content -LiteralPath (Join-Path $console.FullName 'web.config') -Raw -ErrorAction Stop)
    $authentication = $parentConfig.SelectSingleNode('/configuration/system.web/authentication')
    if (-not $authentication -or $authentication.GetAttribute('mode') -ne 'Forms') {
        throw 'NmConsole web.config must declare Forms authentication. Inherited/custom IIS setups require administrator review before publishing.'
    }
    $dashboardRoot = Join-Path $console.FullName 'dashboards'
    $destination = Join-Path $dashboardRoot $PackName
    foreach ($path in @($console.FullName, $dashboardRoot, $destination)) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Publishing directory must not be a file or reparse point: $path"
            }
        }
    }
    if ($source.FullName.TrimEnd('\') -eq $destination.TrimEnd('\')) {
        throw 'Source and published destination must be different directories.'
    }
    if (-not $PSCmdlet.ShouldProcess($destination, 'Deploy authentication configuration and publish dashboard HTML pack')) { return }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $key = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(
            [IO.Path]::GetFullPath($destination).TrimEnd('\').ToUpperInvariant()))).Replace('-', '')
    }
    finally { $hash.Dispose() }
    try { $mutex = [Threading.Mutex]::new($false, "Global\WhatsUpGoldPS-Dashboard-$key") }
    catch { throw "Cannot acquire dashboard destination lock (check cross-identity permissions): $($_.Exception.Message)" }
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw "Dashboard destination is already being published: $destination" }
        # Recheck under the lock; never trust pre-lock ownership or path checks.
        foreach ($path in @($console.FullName, $dashboardRoot, $destination)) {
            if (Test-Path -LiteralPath $path) { Assert-WUGDashboardRegularPath -Path $path -Directory }
        }
        if (-not $env:ProgramData) { throw 'ProgramData is required for machine-local dashboard recovery storage.' }
        $programData = (Get-Item -LiteralPath $env:ProgramData -Force -ErrorAction Stop).FullName
        Assert-WUGDashboardRegularPath -Path $programData -Directory
        $webRoot = (Split-Path $console.FullName -Parent).TrimEnd('\')
        if ($programData.TrimEnd('\').StartsWith($webRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $programData.TrimEnd('\') -ieq $webRoot) {
            throw 'Dashboard recovery storage must be outside the web console.'
        }
        $productRoot = Join-Path $programData 'WhatsUpGoldPS'
        $storageRoot = Join-Path $productRoot 'DashboardPublishing'
        $transaction = Join-Path $storageRoot $key
        foreach ($path in @($productRoot, $storageRoot, $transaction)) {
            if (Test-Path -LiteralPath $path) { Assert-WUGDashboardRegularPath -Path $path -Directory }
            else { New-WUGDashboardPrivateDirectory -Path $path }
        }
        $owner = Join-Path $transaction 'owner.txt'
        if (Test-Path -LiteralPath $owner) {
            Assert-WUGDashboardRegularPath -Path $owner
            if ([IO.File]::ReadAllText($owner) -cne $destination.ToUpperInvariant()) { throw 'Dashboard recovery directory ownership mismatch.' }
        }
        elseif (@(Get-ChildItem -LiteralPath $transaction -Force -ErrorAction Stop).Count -gt 0) {
            throw 'Refusing an unowned dashboard recovery directory.'
        }
        else { [IO.File]::WriteAllText($owner, $destination.ToUpperInvariant(), [Text.UTF8Encoding]::new($true)) }
        Assert-WUGDashboardRecoveryTree -Path $transaction
        $pending = Join-Path $transaction 'pending.txt'
        $configPath = Join-Path $destination 'web.config'
        if (Test-Path -LiteralPath $destination) {
            $emptyInterruptedCreation = -not (Test-Path -LiteralPath $configPath) -and
                (Test-Path -LiteralPath $pending -PathType Leaf) -and
                [IO.File]::ReadAllText($pending) -ceq 'new' -and
                @(Get-ChildItem -LiteralPath $destination -Force -ErrorAction Stop).Count -eq 0
            if (-not $emptyInterruptedCreation) {
                if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
                    throw "Destination is not an owned dashboard pack; choose a new PackName: $destination"
                }
                Assert-WUGDashboardRegularPath -Path $configPath
                if (-not [IO.File]::ReadAllText($configPath).Contains('<!-- WhatsUpGoldPS owned dashboard pack: inherited WUG Forms authentication required. -->')) {
                    throw "Destination is not an owned dashboard pack; choose a new PackName: $destination"
                }
            }
            $null = Get-WUGDashboardPublishedFiles -Path $destination
        }
        if (Test-Path -LiteralPath $pending) {
            try { Restore-WUGDashboardPack -Destination $destination -TransactionPath $transaction }
            catch { throw "Dashboard pending recovery failed; journal retained at '$transaction': $($_.Exception.Message)" }
        }
        $stage = Join-Path $transaction 'stage'
        $backup = Join-Path $transaction 'backup'
        foreach ($path in @($stage, $backup)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop }
            $null = New-Item -ItemType Directory -Path $path -ErrorAction Stop
        }
        Deploy-DashboardWebConfig -Path $stage -ProtectStaticFiles -ErrorAction Stop
        $stagedHashes = @{}
        foreach ($name in $names) {
            $from = Join-Path $source.FullName $name
            Assert-WUGDashboardRegularPath -Path $from
            $stagedHashes[$name] = (Get-FileHash -LiteralPath $from -Algorithm SHA256 -ErrorAction Stop).Hash
            Copy-Item -LiteralPath $from -Destination (Join-Path $stage $name) -Force -ErrorAction Stop
        }
        # Validate the entire stage before touching any served HTML.
        foreach ($name in $names) {
            Assert-WUGDashboardRegularPath -Path (Join-Path $stage $name)
            if ((Get-FileHash -LiteralPath (Join-Path $stage $name) -Algorithm SHA256 -ErrorAction Stop).Hash -ne $stagedHashes[$name]) {
                throw "Staged dashboard verification failed: $name"
            }
        }
        $mode = 'new'
        $previous = @()
        if (Test-Path -LiteralPath $destination) {
            $mode = 'existing'
            $previous = @(Get-WUGDashboardPublishedFiles -Path $destination)
        }
        $snapshot = [Collections.Generic.List[string]]::new()
        foreach ($name in $previous) {
            $from = Join-Path $destination $name
            $expected = (Get-FileHash -LiteralPath $from -Algorithm SHA256 -ErrorAction Stop).Hash
            Copy-Item -LiteralPath $from -Destination (Join-Path $backup $name) -Force -ErrorAction Stop
            if ((Get-FileHash -LiteralPath (Join-Path $backup $name) -Algorithm SHA256 -ErrorAction Stop).Hash -ne $expected) {
                throw "Dashboard backup verification failed: $name"
            }
            $snapshot.Add("$name|$expected")
        }
        [IO.File]::WriteAllLines((Join-Path $transaction 'snapshot.txt'), $snapshot.ToArray(), [Text.UTF8Encoding]::new($true))
        $obsolete = @($previous | Where-Object { $_ -ne 'web.config' -and $names -notcontains $_ })
        [IO.File]::WriteAllText($pending, $mode, [Text.UTF8Encoding]::new($true))
        try {
            $null = New-Item -ItemType Directory -Path $destination -Force -ErrorAction Stop
            Deploy-DashboardWebConfig -Path $destination -ProtectStaticFiles -ErrorAction Stop
            foreach ($name in $names) {
                $to = Join-Path $destination $name
                Copy-Item -LiteralPath (Join-Path $stage $name) -Destination $to -Force -ErrorAction Stop
                if ((Get-FileHash -LiteralPath $to -Algorithm SHA256 -ErrorAction Stop).Hash -ne $stagedHashes[$name]) {
                    throw "Published file verification failed: $name"
                }
            }
            foreach ($name in $obsolete) {
                Remove-Item -LiteralPath (Join-Path $destination $name) -Force -ErrorAction Stop
            }
            Remove-Item -LiteralPath $pending -Force -ErrorAction Stop
        }
        catch {
            $publishError = $_.Exception.Message
            try { Restore-WUGDashboardPack -Destination $destination -TransactionPath $transaction }
            catch { throw "Dashboard publish failed: $publishError. ROLLBACK FAILED: $($_.Exception.Message). Recovery journal retained at '$transaction'." }
            throw "Dashboard publish failed; previous managed pack restored: $publishError"
        }
        [pscustomobject]@{
            PublishedPath = $destination
            PublishedIndexPath = Join-Path $destination 'index.html'
            RelativeUrl = "/NmConsole/dashboards/$PackName/index.html"
            FilesCopied = $names.Count
            ObsoletePagesRemoved = $obsolete.Count
            AuthenticationVerified = $false
        }
    }
    finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Test-WUGDashboardPackAccess {
    <#
    .SYNOPSIS
        Checks actual IIS anonymous blocking and optionally authenticated HTML access.
    .PARAMETER SourcePath
        Generated pack to compare with published HTML.
    .PARAMETER ConsoleUri
        HTTPS web console root, including /NmConsole, not the REST API port URL.
    .PARAMETER PackName
        Published dashboard directory name.
    .PARAMETER WebSession
        Existing authenticated WUG Forms WebRequestSession. API bearer headers are
        not a Forms session. Without this parameter only anonymous blocking is tested.
    .EXAMPLE
        Test-WUGDashboardPackAccess -SourcePath C:\ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\AllInterfaces -ConsoleUri https://wug.example.com/NmConsole -PackName interfaces-all -WebSession $session
    .NOTES
        Does not log in or persist credentials/cookies. Uses normal TLS validation.
        IIS errors, redirects unrelated to login, and HTML mismatches terminate.
    .LINK
        ..\interfaces\README.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][uri]$ConsoleUri,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$')][string]$PackName,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession
    )
    if ($ConsoleUri.Scheme -ne 'https' -or $ConsoleUri.AbsolutePath.TrimEnd('/') -ine '/NmConsole' -or
        $ConsoleUri.Query -or $ConsoleUri.Fragment -or $ConsoleUri.UserInfo) {
        throw 'ConsoleUri must be the HTTPS /NmConsole root without query, fragment or embedded credentials.'
    }
    $names = @(Get-WUGDashboardPackFiles -SourcePath $SourcePath)
    foreach ($name in $names) {
        $url = "$($ConsoleUri.AbsoluteUri.TrimEnd('/'))/dashboards/$PackName/$name"
        $status = 0
        $location = ''
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop
            $status = [int]$response.StatusCode
            $location = [string]$response.Headers['Location']
        }
        catch {
            if (-not $_.Exception.Response) { throw }
            $status = [int]$_.Exception.Response.StatusCode
            $location = [string]$_.Exception.Response.Headers['Location']
        }
        $loginRedirect = $false
        if ($status -eq 302 -and $location) {
            $redirect = [uri]::new([uri]$url, $location)
            $loginRedirect = $redirect.Authority -eq $ConsoleUri.Authority -and
                $redirect.Scheme -eq 'https' -and $redirect.AbsolutePath -match '(?i)^/NmConsole/(?:[^/]*login[^/]*|default\.aspx)$'
        }
        if ($status -notin @(401, 403) -and -not $loginRedirect) {
            throw "Anonymous dashboard access was not safely blocked: $name (HTTP $status, Location '$location')."
        }
        if ($WebSession) {
            $response = Invoke-WebRequest -Uri $url -WebSession $WebSession -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop
            $expected = [IO.File]::ReadAllText((Join-Path $SourcePath $name))
            if ([int]$response.StatusCode -ne 200 -or ([string]$response.Content).TrimStart([char]0xFEFF) -cne $expected.TrimStart([char]0xFEFF)) {
                throw "Authenticated dashboard content mismatch: $name"
            }
        }
    }
    if (-not $WebSession) {
        Write-Warning 'Anonymous blocking passed; authenticated access is NOT verified. Test after WUG Forms login before declaring E2E success.'
    }
    [pscustomobject]@{
        PagesChecked = $names.Count
        AnonymousBlocked = $true
        AuthenticatedAccessVerified = [bool]$WebSession
    }
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCxJPZzplxyiGW1
# GuwPBYqOYEH0iOVUnL98pPtLYH6BTKCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqG
# SIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0
# NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAw
# ggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZG
# bEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3
# haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/
# tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06S
# hdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5
# pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7I
# H60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGg
# W+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+
# QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAg
# NpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8E
# BAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAb
# BgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9v
# dFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0
# LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdj
# MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0B
# AQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9
# hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCym
# laS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+
# vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4i
# TAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09
# Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6
# bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3
# sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z
# 1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls
# /GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9
# ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+MIIE
# pqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNV
# BAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3Rp
# Z28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAwWhcN
# MjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVjdGlj
# dXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBBbGJl
# cmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYWkI5b
# 5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mwzPE3
# /1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1DeO9
# gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdbw+JO
# xolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1Bu10
# nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1kdHYY
# x6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0JBY+J
# 4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0dn+IK
# MEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRsCHZI
# zVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRUq6q2
# u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keELJNy
# +jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAWgBQP
# Kssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8GaSIB
# ibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYB
# BQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYX
# aHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8
# oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWdu
# aW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDov
# L2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3
# DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3wXEK
# 4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9vGWJ
# FyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUdvaNa
# yomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6LwIS
# OX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFOWKlS
# 6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7nbvf
# FxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6g7tW
# iEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7z+pl
# 6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphB
# cr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6p
# vF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHe
# HYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEd
# gkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjU
# jsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bR
# VFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeS
# LsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIV
# NSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL
# 6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2Zd
# SoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFU
# eEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEw
# DQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/
# T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQ
# E7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9r
# EVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y
# 1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gx
# dEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3t
# y9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcy
# tL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEB
# YTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud
# /v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiS
# uEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZP
# ubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsF
# ADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNV
# BAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hB
# MjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVowYzEL
# MAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJE
# aWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYg
# MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz
# /TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP0BMx
# t9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3BSkU
# xDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZE
# eoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbjbrEO
# vZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26QZYMn
# /FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRsIolv
# ykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZ
# CZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5prW8
# 3vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjd
# zi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwroczk9ic
# flf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0G
# A1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQG
# fHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYB
# BQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2Nz
# cC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEy
# NTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hB
# MjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcB
# MA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQI
# ENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEtrfGh
# z45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfH
# hHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA
# 02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8pD7K
# VyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v5jht
# KVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvK
# qzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR5eHs
# 0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZEbGR
# sMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjWagkJ
# Nt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvdN8yW
# QPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3Rp
# Z28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWduaW5n
# IENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAYBgor
# BgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEE
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCZ
# sYkFAW2C6kyMe/SaEzRmIfFZ53jnld4b/upA54q7/TANBgkqhkiG9w0BAQEFAASC
# AgCtBEsONb5t7dl+3HI/7SX5GZ0YJJGO9OsmOdwJcg9J0+tpfp5MRKn1dhlFOegN
# 993gNiP2KZ/t1o+nIHi+t7lbOy4NPuce0OUzp2OLqm1VcMFq6Bw59/C6al4TkruP
# 19UH48vyLXzjGVseetpaenuUEJ4XsOnAHSn/YLfZsPkp6ngADrDcPQuJLu1u552K
# DOSSSyBLR++dLIpnAekxXTC++CpGFLyBT6a01TxX70rTbsE5OMlfzqNonCbmaVO/
# 0HgsD7EMwhKXkNA+vZmq3JNtKUCOr471eJnx2O6BAgv+OcB+Nn1JDjMPGaJAOZQK
# LWUob2LqJc9Vp1rjKQhjyPH2tfx+GrV7xdIHhc63iOuOTEtPUYT0ePelzAXSWORy
# VEQeIPLilxHyxvi7aAkVjJF6sy+hzcHj9SvUjqIfjYo7YI8XQiWOuNUjWqCibCI7
# 1B5lypFBtjMyyz9saF437bAiK1H37oTCBFAhuM65yS4wVyG1dM0CzZ8RkO8Pye3r
# vysA8xEE9NGrf2Z2PB2ASL+gfBVIkdwi2nJSoy/qsmNeAJthThPkVox9yoBmGHuW
# SlyCBdAted1fVVaOadoOmktlTVwMIYMlNvGsqb87UjQWUzFfUdjyKdt6xRiQ1T41
# HW7UrzVeK7RkEgZS5Z9q+e9tK+CtpGNqdcf82+ziLiAsUaGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgxODIyNTFaMC8GCSqGSIb3DQEJBDEiBCAO04TwIJ7N
# l1WbkB88bU2MEEqPhV+D7Q3vOUSYPz9qyTANBgkqhkiG9w0BAQEFAASCAgBRdXOd
# hDgji6K6VIQQUF9x/mE8k8Y/0eDyB55iazo54M0mnZ8Z6ClEu+/IS8Q94gmcJp11
# t7CyP8fcy2mF3DDAOCdtCIWv6yB/0JvS9jLB66FPH0+vq9nFKnoGrtjOK/cR1I/I
# UsOPS2fJPJZimvzFQjUBW5CK5R8nJkRxVPzEyS5f/Up7XT3ZTTP2EkIy3zXXUWCV
# SlW72lTwC+r5PZzN+PL6qHz75B/MVUzV/aE9iLJE5Fx5piCqbj/HeM2waUJTFw+H
# KJrCITHRThNb1XP4G+eJLKyxFWefZX3UwHhcWOnP1CpQe45tlXN68C/OW78ltp9F
# qdha0HGXqP8kaRulVIbKwzG/j2WH8/MLiYX3kvVLFP0w1yarvdyLq6Vc6Iy6s3SX
# cg4mlToRFAJOBK42Cvo5imKEZThj0JVddCCrhSuSCOkJvnB4gYk8SuDc6zlxfwtJ
# V/GjwAmPgAkwfkD3X3cWd8+TlmGTQ27ZikuXxmWi2qbxPvNb9EGLldGoT3vRRZRb
# 0LO7TLEXHSdCBXRIP1snISQSyf9MLcTuwFdJjuCWC6uUNePaNn7EyNcNUsCqVUCG
# Y8tTkAtHmt2gG0GFgTWiKJbm9opSM5g7DXm5ZJ+yZsw51Mk4jW47m2oVuUz2klcC
# fhuONSPHwWPBwjuw79y9WpxJaUordonF2U4NUQ==
# SIG # End signature block
