#requires -Version 5.1

function Get-InterfaceGroupLocalExportHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Path.ToUpperInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-InterfaceGroupLocalExportPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$Directory)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($Directory -and -not $item.PSIsContainer) { throw "Expected a directory at '$Path'." }
    if (-not $Directory -and $item.PSIsContainer) { throw "Expected a file at '$Path'." }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to use a reparse point in local interface export: $Path"
    }
}

function Test-InterfaceGroupLocalExportCancellation {
    [CmdletBinding()]
    param([string]$CancellationPath)
    if ($CancellationPath -and (Test-Path -LiteralPath $CancellationPath)) {
        throw [OperationCanceledException]::new("Interface grouping cancelled by signal file: $CancellationPath")
    }
}

function New-InterfaceGroupLocalExportDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Assert-InterfaceGroupLocalExportPath -Path $Path -Directory
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    }
    Assert-InterfaceGroupLocalExportPath -Path $Path -Directory
}

function Write-InterfaceGroupLocalExportJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 20),
            [Text.UTF8Encoding]::new($true))
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop }
    }
}

function Test-InterfaceGroupLocalExportManagedName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -in @('index.html', 'groups.json', 'changes.json', 'changes.csv', 'inventory-snapshot.json') -or
        $Name -match '^group-[A-Za-z0-9._-]+\.html$')
}

function Get-InterfaceGroupLocalExportOwnership {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OwnershipPath, [Parameter(Mandatory)][string]$OutputDirectory)
    if (-not (Test-Path -LiteralPath $OwnershipPath)) { return $null }
    Assert-InterfaceGroupLocalExportPath -Path $OwnershipPath
    $owner = Get-Content -LiteralPath $OwnershipPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($owner.Version -ne 1 -or [IO.Path]::GetFullPath([string]$owner.OutputDirectory) -ine $OutputDirectory -or
        $null -eq $owner.Files) {
        throw "Invalid local interface export ownership record: $OwnershipPath"
    }
    $seen = @{}
    foreach ($entry in @($owner.Files)) {
        $name = [string]$entry.Name
        if ([IO.Path]::GetFileName($name) -cne $name -or -not (Test-InterfaceGroupLocalExportManagedName -Name $name) -or
            $seen.ContainsKey($name.ToLowerInvariant()) -or [string]$entry.Hash -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "Unsafe or invalid filename in local interface export ownership record: $name"
        }
        $seen[$name.ToLowerInvariant()] = $true
        $path = Join-Path $OutputDirectory $name
        Assert-InterfaceGroupLocalExportPath -Path $path
        if (-not (Test-Path -LiteralPath $path) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ine [string]$entry.Hash) {
            throw "Previously managed local interface export file is missing or changed: $path"
        }
    }
    return $owner
}

function Restore-InterfaceGroupLocalExportJournal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorageDirectory,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$OwnershipPath,
        [Parameter(Mandatory)][string]$JournalPath
    )
    if (-not (Test-Path -LiteralPath $JournalPath)) { return }
    Assert-InterfaceGroupLocalExportPath -Path $JournalPath
    $journal = Get-Content -LiteralPath $JournalPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($journal.Version -ne 1 -or [IO.Path]::GetFullPath([string]$journal.OutputDirectory) -ine $OutputDirectory -or
        [string]$journal.Phase -notin @('prepared', 'committing', 'committed') -or
        [IO.Path]::GetFullPath([string]$journal.BackupDirectory) -notlike ($StorageDirectory.TrimEnd('\') + '\backup-*')) {
        throw "Invalid local interface export recovery journal: $JournalPath"
    }
    $backupDirectory = [IO.Path]::GetFullPath([string]$journal.BackupDirectory)
    Assert-InterfaceGroupLocalExportPath -Path $backupDirectory -Directory
    if ($journal.Phase -eq 'committing') {
        try {
            foreach ($entry in @($journal.Files)) {
                $name = [string]$entry.Name
                if ([IO.Path]::GetFileName($name) -cne $name -or -not (Test-InterfaceGroupLocalExportManagedName -Name $name)) {
                    throw "Unsafe filename in local interface export recovery journal: $name"
                }
                $target = Join-Path $OutputDirectory $name
                Assert-InterfaceGroupLocalExportPath -Path $target
                if ($entry.Existed) {
                    $backup = Join-Path $backupDirectory ([string]$entry.BackupName)
                    Assert-InterfaceGroupLocalExportPath -Path $backup
                    if (-not (Test-Path -LiteralPath $backup)) { throw "Missing rollback copy: $backup" }
                    Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction Stop
                    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine [string]$entry.Hash) {
                        throw "Rollback verification failed for '$target'."
                    }
                }
                elseif (Test-Path -LiteralPath $target) {
                    Remove-Item -LiteralPath $target -Force -ErrorAction Stop
                }
            }
            if ($journal.HadOwnership) {
                $oldOwner = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$journal.PreviousOwnership))
                [IO.File]::WriteAllText($OwnershipPath, $oldOwner, [Text.UTF8Encoding]::new($true))
            }
            elseif (Test-Path -LiteralPath $OwnershipPath) {
                Remove-Item -LiteralPath $OwnershipPath -Force -ErrorAction Stop
            }
            if (-not $journal.HadDestination -and (Test-Path -LiteralPath $OutputDirectory) -and
                @(Get-ChildItem -LiteralPath $OutputDirectory -Force -ErrorAction Stop).Count -eq 0) {
                Remove-Item -LiteralPath $OutputDirectory -Force -ErrorAction Stop
            }
        }
        catch {
            throw "ROLLBACK FAILED; local interface export recovery journal retained at '$JournalPath'. $($_.Exception.Message)"
        }
    }
    Remove-Item -LiteralPath $JournalPath -Force -ErrorAction Stop
    Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction Stop
}

function Export-InterfaceGroupDashboards {
    <#
    .SYNOPSIS
        Generates local interface dashboards using a recoverable, staged export.
    .DESCRIPTION
        Stages under machine ProgramData, validates before promoting managed files,
        and journals rollback state so a later call can recover interrupted promotion.
        The grouping entry point owns .interface-grouping.lock; direct calls serialize
        against other direct calls only and must not overlap an entry-point run.
    .PARAMETER Groups
        Output from Select-InterfaceGroups.
    .PARAMETER OutputDirectory
        Destination directory for the local dashboard pack.
    .PARAMETER RangeLabel
        Human-readable report window.
    .PARAMETER Inventory
        Complete scope inventory for health totals and the comparison snapshot.
    .PARAMETER StaleAfterMinutes
        Traffic timestamp age threshold.
    .PARAMETER SnmpCoverage
        Optional device-ID to SNMP result map.
    .PARAMETER CollectionContext
        Optional collector provenance passed to a stage implementation that accepts it.
    .PARAMETER CancellationPath
        Optional signal-file path checked before staging and immediately before commit.
    .OUTPUTS
        The final index.html path.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Groups,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$RangeLabel = 'lastNHours (4)',
        [AllowEmptyCollection()][object[]]$Inventory,
        [ValidateRange(1, 525600)][int]$StaleAfterMinutes = 60,
        [hashtable]$SnmpCoverage,
        [hashtable]$CollectionContext,
        [string]$CancellationPath
    )

    if (-not (Get-Command -Name 'Write-InterfaceGroupDashboardStage' -ErrorAction SilentlyContinue)) {
        $helperPath = Join-Path $PSScriptRoot 'InterfaceGroupingHelpers.ps1'
        if (Test-Path -LiteralPath $helperPath) { . $helperPath }
    }
    if (-not (Get-Command -Name 'Write-InterfaceGroupDashboardStage' -ErrorAction SilentlyContinue)) {
        throw 'Write-InterfaceGroupDashboardStage is unavailable. Load the updated InterfaceGroupingHelpers.ps1 first.'
    }
    if (-not (Get-Command -Name 'Get-WUGDashboardGroupPageName' -ErrorAction SilentlyContinue)) {
        $dashboardHelpers = Join-Path (Split-Path $PSScriptRoot -Parent) 'reports\DashboardPublishingHelpers.ps1'
        if (Test-Path -LiteralPath $dashboardHelpers) { . $dashboardHelpers }
    }
    if (-not (Get-Command -Name 'Get-WUGDashboardGroupPageName' -ErrorAction SilentlyContinue)) {
        throw 'Get-WUGDashboardGroupPageName is unavailable; load the interface dashboard helpers.'
    }
    if (-not $PSBoundParameters.ContainsKey('Inventory')) {
        $Inventory = @($Groups | ForEach-Object { $_.Interfaces })
    }
    $destination = [IO.Path]::GetFullPath($OutputDirectory)
    if (-not $PSCmdlet.ShouldProcess($destination, 'Generate and promote local interface dashboards')) {
        return (Join-Path $destination 'index.html')
    }
    if ($CancellationPath -and (Test-Path -LiteralPath $CancellationPath)) {
        throw [OperationCanceledException]::new("Interface grouping cancelled by signal file: $CancellationPath")
    }

    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) { throw 'ProgramData is unavailable; refusing to stage in a user or temporary directory.' }
    $programData = [IO.Path]::GetFullPath($programData)
    $hash = Get-InterfaceGroupLocalExportHash -Path $destination
    $storage = Join-Path $programData "WhatsUpGoldPS\InterfaceGroups\LocalExport\$hash"
    $ownershipPath = Join-Path $storage 'ownership.json'
    $journalPath = Join-Path $storage 'pending.json'
    $mutexName = "Local\WhatsUpGoldPS.InterfaceGroupLocalExport.$hash"
    $mutex = New-Object Threading.Mutex($false, $mutexName)
    $locked = $false
    $stage = $null
    try {
        try { $locked = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw "Another direct local export is active for '$destination'." }

        if (Test-Path -LiteralPath $destination) { Assert-InterfaceGroupLocalExportPath -Path $destination -Directory }
        New-InterfaceGroupLocalExportDirectory -Path (Join-Path $programData 'WhatsUpGoldPS')
        New-InterfaceGroupLocalExportDirectory -Path (Join-Path $programData 'WhatsUpGoldPS\InterfaceGroups')
        New-InterfaceGroupLocalExportDirectory -Path (Join-Path $programData 'WhatsUpGoldPS\InterfaceGroups\LocalExport')
        New-InterfaceGroupLocalExportDirectory -Path $storage
        if (Test-Path -LiteralPath $journalPath) {
            Restore-InterfaceGroupLocalExportJournal -StorageDirectory $storage -OutputDirectory $destination `
                -OwnershipPath $ownershipPath -JournalPath $journalPath
        }
        $owner = Get-InterfaceGroupLocalExportOwnership -OwnershipPath $ownershipPath -OutputDirectory $destination
        if (-not $owner -and (Test-Path -LiteralPath $destination)) {
            foreach ($item in @(Get-ChildItem -LiteralPath $destination -Force -ErrorAction Stop)) {
                if (Test-InterfaceGroupLocalExportManagedName -Name $item.Name) {
                    throw "Unmarked local destination already contains a managed filename; refusing to overwrite '$($item.FullName)'."
                }
            }
        }

        $seenPages = @{}
        $desiredNames = [Collections.Generic.List[string]]::new()
        $desiredNames.Add('index.html')
        $desiredNames.Add('groups.json')
        $desiredNames.Add('changes.json')
        $desiredNames.Add('changes.csv')
        $desiredNames.Add('inventory-snapshot.json')
        foreach ($group in $Groups) {
            $page = Get-WUGDashboardGroupPageName -Name $group.Name
            if ($seenPages.ContainsKey($page.ToLowerInvariant())) { throw "Duplicate normalized group name: $($group.Name)" }
            $seenPages[$page.ToLowerInvariant()] = $true
            if ($page -notmatch '^group-[A-Za-z0-9._-]+\.html$') { throw "Unsafe generated group page name: $page" }
            $desiredNames.Add($page)
        }
        $desiredSet = @{}
        foreach ($name in $desiredNames) { $desiredSet[$name.ToLowerInvariant()] = $true }
        if (Test-Path -LiteralPath $destination) {
            foreach ($name in $desiredNames) {
                $candidate = Join-Path $destination $name
                if (Test-Path -LiteralPath $candidate) {
                    Assert-InterfaceGroupLocalExportPath -Path $candidate
                    $wasOwned = $false
                    if ($owner) {
                        $wasOwned = @($owner.Files | Where-Object { [string]$_.Name -ieq $name }).Count -gt 0
                    }
                    if (-not $wasOwned) { throw "Unowned destination file collision; refusing to overwrite '$candidate'." }
                }
            }
        }

        $stage = Join-Path $storage ('run-' + [guid]::NewGuid().ToString('N'))
        New-InterfaceGroupLocalExportDirectory -Path $stage
        $snapshot = Join-Path $destination 'inventory-snapshot.json'
        if (Test-Path -LiteralPath $snapshot) {
            Assert-InterfaceGroupLocalExportPath -Path $snapshot
            Copy-Item -LiteralPath $snapshot -Destination (Join-Path $stage 'inventory-snapshot.json') -Force -ErrorAction Stop
        }
        Test-InterfaceGroupLocalExportCancellation -CancellationPath $CancellationPath
        $stageCommand = Get-Command -Name 'Write-InterfaceGroupDashboardStage' -ErrorAction Stop
        $stageParameters = @{
            Groups = $Groups
            OutputDirectory = $stage
            RangeLabel = $RangeLabel
            Inventory = $Inventory
            StaleAfterMinutes = $StaleAfterMinutes
        }
        if ($PSBoundParameters.ContainsKey('SnmpCoverage')) { $stageParameters.SnmpCoverage = $SnmpCoverage }
        if ($stageCommand.Parameters.ContainsKey('CancellationPath')) {
            $stageParameters.CancellationPath = $CancellationPath
        }
        if ($PSBoundParameters.ContainsKey('CollectionContext') -and $stageCommand.Parameters.ContainsKey('CollectionContext')) {
            $stageParameters.CollectionContext = $CollectionContext
        }
        $null = Write-InterfaceGroupDashboardStage @stageParameters

        $manifestPath = Join-Path $stage 'groups.json'
        foreach ($required in @('index.html', 'groups.json', 'changes.json', 'changes.csv', 'inventory-snapshot.json')) {
            $file = Join-Path $stage $required
            Assert-InterfaceGroupLocalExportPath -Path $file
            if (-not (Test-Path -LiteralPath $file) -or (Get-Item -LiteralPath $file).Length -eq 0) {
                throw "Stage is missing or has an empty required file: $file"
            }
        }
        $groupData = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $manifestGroups = @($groupData)
        if ($manifestGroups.Count -ne $Groups.Count) { throw 'Staged groups.json does not match the selected group count.' }
        $validatedNames = @{}
        $expectedPages = @{}
        foreach ($group in $Groups) {
            $expectedPages[(Get-WUGDashboardGroupPageName -Name $group.Name).ToLowerInvariant()] = $true
        }
        foreach ($entry in $manifestGroups) {
            $page = [string]$entry.PageName
            if (-not $page) { $page = Get-WUGDashboardGroupPageName -Name $entry.Name }
            if ($page -notmatch '^group-[A-Za-z0-9._-]+\.html$' -or $validatedNames.ContainsKey($page.ToLowerInvariant())) {
                throw "Invalid or duplicate page in staged groups.json: $page"
            }
            if (-not $expectedPages.ContainsKey($page.ToLowerInvariant())) {
                throw "Unexpected page in staged groups.json: $page"
            }
            $validatedNames[$page.ToLowerInvariant()] = $true
            if (-not (Test-Path -LiteralPath (Join-Path $stage $page))) { throw "Staged group page is missing: $page" }
        }
        Get-Content -LiteralPath (Join-Path $stage 'changes.json') -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop | Out-Null
        $snapshotData = Get-Content -LiteralPath (Join-Path $stage 'inventory-snapshot.json') -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $snapshotData.SchemaVersion -and [int]$snapshotData.SchemaVersion -notin @(1, 2)) {
            throw "Unsupported staged inventory snapshot schema version: $($snapshotData.SchemaVersion)"
        }
        if (@($validatedNames.Keys).Count -ne @($desiredNames | Where-Object { $_ -like 'group-*.html' }).Count) {
            throw 'Staged group pages do not match the expected page set.'
        }
        $stagedHashes = @{}
        foreach ($name in $desiredNames) {
            $path = Join-Path $stage $name
            Assert-InterfaceGroupLocalExportPath -Path $path
            $stagedHashes[$name.ToLowerInvariant()] = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
        }

        $promoteNames = [Collections.Generic.List[string]]::new()
        foreach ($name in $desiredNames) { if (-not $promoteNames.Contains($name)) { $promoteNames.Add($name) } }
        if ($owner) {
            foreach ($entry in @($owner.Files)) {
                if (-not $desiredSet.ContainsKey(([string]$entry.Name).ToLowerInvariant())) {
                    $promoteNames.Add([string]$entry.Name)
                }
            }
        }
        $backupDirectory = Join-Path $storage ('backup-' + [guid]::NewGuid().ToString('N'))
        New-InterfaceGroupLocalExportDirectory -Path $backupDirectory
        $journalFiles = [Collections.Generic.List[object]]::new()
        $previousOwner = $null
        if (Test-Path -LiteralPath $ownershipPath) {
            $previousOwner = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
                [IO.File]::ReadAllText($ownershipPath)))
        }
        $counter = 0
        foreach ($name in $promoteNames) {
            $counter++
            $target = Join-Path $destination $name
            $exists = Test-Path -LiteralPath $target
            $entry = [ordered]@{ Name = $name; Existed = $exists; BackupName = ('file-{0:D4}.bak' -f $counter); Hash = '' }
            if ($exists) {
                Assert-InterfaceGroupLocalExportPath -Path $target
                $entry.Hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash
                Copy-Item -LiteralPath $target -Destination (Join-Path $backupDirectory $entry.BackupName) `
                    -Force -ErrorAction Stop
            }
            $journalFiles.Add([pscustomobject]$entry)
        }
        $journal = [pscustomobject]@{
            Version = 1
            Phase = 'prepared'
            OutputDirectory = $destination
            HadDestination = (Test-Path -LiteralPath $destination)
            BackupDirectory = $backupDirectory
            HadOwnership = ($null -ne $previousOwner)
            PreviousOwnership = $previousOwner
            Files = @($journalFiles)
        }
        Write-InterfaceGroupLocalExportJson -Path $journalPath -Value $journal
        try { Test-InterfaceGroupLocalExportCancellation -CancellationPath $CancellationPath }
        catch {
            Remove-Item -LiteralPath $journalPath -Force -ErrorAction Stop
            Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction Stop
            throw
        }
        $journal.Phase = 'committing'
        Write-InterfaceGroupLocalExportJson -Path $journalPath -Value $journal
        try {
            if (-not (Test-Path -LiteralPath $destination)) {
                New-InterfaceGroupLocalExportDirectory -Path $destination
            }
            foreach ($name in $desiredNames) {
                $source = Join-Path $stage $name
                $target = Join-Path $destination $name
                $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256 -ErrorAction Stop).Hash
                if ($sourceHash -ine $stagedHashes[$name.ToLowerInvariant()]) {
                    throw "Staged file changed after validation: '$source'."
                }
                Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
                if ((Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash -ine $stagedHashes[$name.ToLowerInvariant()]) {
                    throw "Promotion hash verification failed for '$target'."
                }
            }
            foreach ($entry in @($journalFiles | Where-Object { $_.Existed -and -not $desiredSet.ContainsKey(([string]$_.Name).ToLowerInvariant()) })) {
                Remove-Item -LiteralPath (Join-Path $destination $entry.Name) -Force -ErrorAction Stop
            }
            $ownedFiles = @($desiredNames | ForEach-Object {
                [pscustomobject]@{ Name = $_; Hash = $stagedHashes[$_.ToLowerInvariant()] }
            })
            Write-InterfaceGroupLocalExportJson -Path $ownershipPath -Value ([pscustomobject]@{
                Version = 1
                OutputDirectory = $destination
                Files = $ownedFiles
            })
        }
        catch {
            $failure = $_.Exception.Message
            try {
                Restore-InterfaceGroupLocalExportJournal -StorageDirectory $storage -OutputDirectory $destination `
                    -OwnershipPath $ownershipPath -JournalPath $journalPath
            }
            catch { throw "$failure; $($_.Exception.Message)" }
            throw $failure
        }
        $journal.Phase = 'committed'
        Write-InterfaceGroupLocalExportJson -Path $journalPath -Value $journal
        Remove-Item -LiteralPath $journalPath -Force -ErrorAction Stop
        Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction Stop
        return (Join-Path $destination 'index.html')
    }
    finally {
        if ($stage -and (Test-Path -LiteralPath $stage)) {
            try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop }
            catch { Write-Warning "Unable to remove local interface export stage '$stage': $($_.Exception.Message)" }
        }
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBaVGNv13tuueMV
# TURifreJD4yrB4ubn39t0I99FHbGW6CCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAG
# 6U4h6cjtng7iCFv0GuZ0pj5vgjPOMqAtSAh/Na/2GDANBgkqhkiG9w0BAQEFAASC
# AgBNgPDP9E+2Ln8Uhrs3FZX6Xq9bq3QjLuITm44Pqle2WWAkIyGdpSYvwMREl1V7
# LDclymyqWyYoJTe52SoLx+pq7pOgDI/MkL4G5fobwr1ngNnzcN6W2XnQIISS59Yg
# 7OA2CO9BBeiOZytMNOhNlg6szL03OhOLEwynixdEVL23SCTJ3s/ZM4+xPQpoGYuX
# 6p/h4wVeWhhslQrXfHyjw+kJJAXte40eVZjg3VTB5EIPO6vGMRqjYV21klYmVgLD
# +WiPdfgxbQ5yFs4aO8Ak9eG3jiFLF1KOB74l8jcZ0LGtk0qjD55TfhZWDhRa79Xg
# SqxLcR/WvavcyRdEv1p7bOgtssYxjrwfXtnf6L3WVV/Grrhhs4FOnw3TLZfDa31l
# 7KS30nf6UTe9RnLvOJyMuAZPdeW8+SkSFnA9a+nqdSrLhzrS+vU4fsfX51cfsVc9
# l0teubDlw4BXu2OHzNbizHkliCgsPUE0qef32iOsto/QPFgFFjSAvry54IBLoqd+
# DcA4gxrKCDb9zEYYK9zio6sSHrEMVzSl6Wm8ZS+R950X6TcZeBiu7aQTta2VQFP+
# ucctK+vlRfh2k0AOchaEE25CXBCRjm8twRWhLJ2N0Z/2XTIGYbFv0HgdC0+SD19E
# qT0BYgWYHCoPVIbH5k3deRpfzFO+FPQ80zc0pQPyAZKjhKGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgxOTA5MjFaMC8GCSqGSIb3DQEJBDEiBCA4x1CB5OBV
# Ilm8+vjt2lpxxFlmm+Rf16/Ruabt1YM1XDANBgkqhkiG9w0BAQEFAASCAgCBZjK0
# jf6IiE2f4deO6LzvS08juWAUn1M1bN/x4cG9b9441vOsEZchRGwQztvQG/weqBd4
# COLx+JdJGgtxPUuy5JFPdQBvTYxLHUDJ6aj+Ec3r9OXV8LEs/UALHrx1B+c+Q7gy
# pFZ5cdPmsclvsM7XZPd2hCKJkVOPicDYhlR7KUcPHxGlCth706/Wkky47hTG4mbW
# 5WxW9hcP0qPewv+CwFt5QuHtVBr+8KiPIgT+0SK7BN9h03e5c7PHs3t4ktAFPfo9
# kATUjIEP25ZhWGf+EC2/pGJn9zERA5qTpMIyPxBVQ+mv2IJvt2N0NzbUIz7g1IbM
# sJ2huSTDhGCsP/nO/7389cU6VH/HxBbXdK25MquI9ZHk5h64aRXJ2ZTO2rjss+kf
# IOvmnsko23y4dO5bbVXXjurOwVdlSEZ2/sw98cJzbLBz2yBxcBBtPvJXamG0GwdA
# QzznfXRlYgFBDQUbFNgUxR7gqhsdKc6Vsh1VcT/ikLuflcVTTeGh0hsbQmj2xzz7
# qAIKvTShav1ups/LaI+JHYC0hsNZjfUzhSWAmk2aqbn7pkfoYzRnyqOE3/pLJ1z6
# fTehmd9eCC74IkiRUpiyWLf69Y7KuPu5+pX9yWeVBTDvi8BF6Fs92xQ/W9MI7v5H
# HJOs2xwfw33uILIltmeSp062VNZn7d5Nr5udLA==
# SIG # End signature block
