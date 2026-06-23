function Import-SharpSnmpLib {
    [CmdletBinding()]
    param(
        [string[]]$PreferredFramework
    )

    $pkg = Get-SharpSnmpLibPackageLocal

    $releaseRoot = Join-Path $pkg.ExtractPath 'Release'
    if (-not (Test-Path -LiteralPath $releaseRoot -PathType Container)) {
        throw "No 'Release' folder found in extracted package at $($pkg.ExtractPath)."
    }

    $availableFrameworks = @(
        Get-ChildItem -Path $releaseRoot -Directory -ErrorAction Stop |
            Select-Object -ExpandProperty Name
    )

    $frameworkCandidates =
        if ($PreferredFramework) {
            $validatedPreferred = @(
                $PreferredFramework |
                    Where-Object { $_ -match '^[A-Za-z0-9][A-Za-z0-9.-]*$' } |
                    Where-Object { $availableFrameworks -contains $_ } |
                    Select-Object -Unique
            )

            if (-not $validatedPreferred) {
                throw @"
No valid preferred framework values were provided.
Valid values from package: $($availableFrameworks -join ', ')
"@
            }

            $validatedPreferred
        }
        else {
            @(
                Get-PreferredSharpSnmpTargetFramework |
                    Where-Object { $availableFrameworks -contains $_ } |
                    Select-Object -Unique
            )
        }

    if (-not $frameworkCandidates) {
        $frameworkCandidates = $availableFrameworks
    }

    $selectedDll = $null
    $selectedFrameworkPath = $null
    $loadFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($tfm in $frameworkCandidates) {
        $candidate = Join-Path $releaseRoot $tfm
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
            continue
        }

        $dll = Get-ChildItem -Path $candidate -Filter 'SharpSnmpLib.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $dll) {
            continue
        }

        try {
            Write-Verbose "Loading DLL for framework '$tfm': $($dll.FullName)"
            Add-Type -Path $dll.FullName -ErrorAction Stop
            $selectedDll = $dll.FullName
            $selectedFrameworkPath = $candidate
            break
        }
        catch {
            $loadFailures.Add("${tfm}: $($_.Exception.Message)")
            Write-Verbose "Failed loading framework '$tfm'. Trying next candidate."
        }
    }

    if (-not $selectedDll) {
        $available = Get-ChildItem -Path $releaseRoot -Directory | Select-Object -ExpandProperty Name
        throw @"
Could not load a compatible SharpSnmpLib.dll for this PowerShell runtime.

Attempt order:
$($frameworkCandidates -join ', ')

Available target frameworks in package:
$($available -join ', ')

Load failures:
$($loadFailures -join [Environment]::NewLine)

PowerShell runtime:
PSEdition = $($PSVersionTable.PSEdition)
Framework = $([System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)
"@
    }

    $ignoredProDllNames = [System.Collections.Generic.List[string]]::new()
    if ($selectedFrameworkPath) {
        $proDlls = Get-ChildItem -Path $selectedFrameworkPath -Filter 'SharpSnmpPro*.dll' -File -ErrorAction SilentlyContinue
        foreach ($proDll in $proDlls) {
            $ignoredProDllNames.Add($proDll.Name)
        }
    }

    if ($ignoredProDllNames.Count -gt 0) {
        Write-Warning "Ignoring unsupported SharpSnmpPro assemblies in bundled package: $($ignoredProDllNames -join ', ')"
    }

    $mibResolverMode = 'BuiltIn'

    $script:SharpSnmpLibLoadInfo = [PSCustomObject]@{
        ReleaseTag         = $pkg.ReleaseTag
        ReleaseUrl         = $pkg.ReleaseUrl
        DllPath            = $selectedDll
        ExtractPath        = $pkg.ExtractPath
        FrameworkPath      = $selectedFrameworkPath
        SharpSnmpProDlls   = @()
        MibResolverMode    = $mibResolverMode
    }

    return $script:SharpSnmpLibLoadInfo
}
