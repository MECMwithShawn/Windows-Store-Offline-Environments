<#
.SYNOPSIS
    Applies icons to existing MECM Store Applications and Application Groups
    by extracting logos directly from the staged MSIX/AppX package files.

.DESCRIPTION
    This is a non-destructive metadata-only update. No applications, deployments,
    or content are modified. It locates the staged package files on the UNC
    Content Share, extracts the highest-resolution logo from each package's
    AppxManifest.xml, and sets it via Set-CMApplication / Set-CMApplicationGroup.

    Run this against objects that already exist in MECM — no redeploy needed.

.PARAMETER AppName
    One or more application name patterns to target (e.g. 'Microsoft.WindowsNotepad').
    If omitted, all discovered Store Applications and Application Groups are updated.

.PARAMETER ContentShare
    UNC root share where packages were staged.
    Defaults to '\\<ServerName>\Software\Microsoft\Windows Store Apps'.

.PARAMETER SiteCode
    The 3-letter MECM Site Code (e.g. 'CHQ'). Auto-detected if omitted.

.PARAMETER SiteServer
    The SMS Provider / Site Server hostname or FQDN. Defaults to 'localhost'.

.PARAMETER SkipApplications
    Only set icons on Application Groups; skip individual Applications.

.PARAMETER SkipGroups
    Only set icons on individual Applications; skip Application Groups.

.PARAMETER WhatIf
    Preview which icons would be applied without making any changes.

.EXAMPLE
    # Update icons on everything
    .\Set-MECMStoreAppIcons.ps1

.EXAMPLE
    # Target a specific app
    .\Set-MECMStoreAppIcons.ps1 -AppName 'Microsoft.WindowsNotepad'

.EXAMPLE
    # Application Groups only, custom share
    .\Set-MECMStoreAppIcons.ps1 -SkipApplications -ContentShare '\\CM01\Software\Microsoft\Windows Store Apps'
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Position = 0)]
    [string[]]$AppName,

    [string]$ContentShare,

    [string]$SiteCode,

    [string]$SiteServer = 'localhost',

    [switch]$SkipApplications,

    [switch]$SkipGroups
)

$ErrorActionPreference = 'Stop'

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "        MECM Store App Icon Patch Utility                 " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 1. Connect to MECM
# ------------------------------------------------------------------------------
function Connect-MECM {
    param([string]$SiteCode, [string]$SiteServer)

    if (-not (Get-Module -Name ConfigurationManager)) {
        $modulePath = $null
        if ($env:SMS_ADMIN_UI_PATH) {
            $modulePath = Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1'
        }
        if (-not $modulePath -or -not (Test-Path $modulePath)) {
            $candidates = @(
                "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1",
                "C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\ConfigurationManager.psd1",
                "C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
            )
            foreach ($c in $candidates) {
                if (Test-Path $c) { $modulePath = $c; break }
            }
        }
        if ($modulePath -and (Test-Path $modulePath)) {
            Write-Host "Importing ConfigurationManager module..." -ForegroundColor Cyan
            Import-Module $modulePath -Force
        } else {
            throw "ConfigurationManager PowerShell module not found."
        }
    }

    if ([string]::IsNullOrWhiteSpace($SiteCode)) {
        $cmDrives = Get-PSDrive -PSProvider CMSite -ErrorAction SilentlyContinue
        if ($cmDrives) {
            $SiteCode = $cmDrives[0].Name
        } else {
            $regSite = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction SilentlyContinue).'Site Code'
            if ($regSite) { $SiteCode = $regSite }
        }
    }
    if ([string]::IsNullOrWhiteSpace($SiteCode)) {
        $SiteCode = (Read-Host "Enter MECM Site Code (e.g. CHQ)").Trim()
    }
    if ([string]::IsNullOrWhiteSpace($SiteCode)) {
        throw "Could not determine MECM Site Code."
    }

    if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        $server = if ($SiteServer -and $SiteServer -ne 'localhost') { $SiteServer } else { $env:COMPUTERNAME }
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $server -Description "MECM Site Drive" -Scope Global | Out-Null
    }

    Set-Location "$($SiteCode):" -ErrorAction Stop
    Write-Host "Connected to MECM Site: $SiteCode" -ForegroundColor Green
    return $SiteCode
}

$connectedSite = Connect-MECM -SiteCode $SiteCode -SiteServer $SiteServer

# ------------------------------------------------------------------------------
# 2. Resolve Content Share + pre-flight accessibility check
# ------------------------------------------------------------------------------
$serverName = if ($SiteServer -and $SiteServer -ne 'localhost') { $SiteServer } else { $env:COMPUTERNAME }
$defaultShare = "\\$serverName\Software\Microsoft\Windows Store Apps"
$targetShare  = if (-not [string]::IsNullOrWhiteSpace($ContentShare)) { $ContentShare } else { $defaultShare }
Write-Host "Content Share: $targetShare" -ForegroundColor Cyan

$shareAccessible = [System.IO.Directory]::Exists($targetShare)
if ($shareAccessible) {
    try {
        $topLevel = [System.IO.Directory]::GetDirectories($targetShare) | ForEach-Object { [System.IO.Path]::GetFileName($_) }
        Write-Host "  Share accessible. Top-level folders: $($topLevel -join ', ')" -ForegroundColor DarkGray
    } catch {
        Write-Host "  Share accessible but could not list contents." -ForegroundColor DarkYellow
    }
} else {
    Write-Warning "  Share NOT accessible: $targetShare"
    Write-Warning "  Strategies 2 & 3 will be skipped. Strategy 1 (SDMPackageXML) and Strategy 4 (local StoreDownloads) will still be attempted."
}

# Local StoreDownloads folder (next to this script) — used as final fallback
$localDownloads = Join-Path $PSScriptRoot 'StoreDownloads'
$localDownloadsOk = [System.IO.Directory]::Exists($localDownloads)
if ($localDownloadsOk) {
    Write-Host "  Local StoreDownloads folder found: $localDownloads" -ForegroundColor DarkGray
}

# ------------------------------------------------------------------------------
# 3. Icon extraction helper
# ------------------------------------------------------------------------------
function Get-AppxPackageIcon {
    param([Parameter(Mandatory)][string]$PackagePath)

    # --- Bundle Support ---
    # Bundles don't contain AppxManifest.xml directly; we must extract an inner package
    if ($PackagePath -match '\.(msixbundle|appxbundle)$') {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
            # Prefer x64, fallback to neutral, then anything
            $innerEntry = $zip.Entries | Where-Object { $_.FullName -like "*x64.msix" -or $_.FullName -like "*x64.appx" } | Select-Object -First 1
            if (-not $innerEntry) {
                $innerEntry = $zip.Entries | Where-Object { $_.FullName -like "*neutral.msix" -or $_.FullName -like "*neutral.appx" } | Select-Object -First 1
            }
            if (-not $innerEntry) {
                $innerEntry = $zip.Entries | Where-Object { $_.FullName -like "*.msix" -or $_.FullName -like "*.appx" } | Select-Object -First 1
            }

            if ($innerEntry) {
                $tempInner = Join-Path $env:TEMP $innerEntry.FullName
                $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($tempInner))
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($innerEntry, $tempInner, $true)
                $zip.Dispose()

                # Recursively process the extracted inner package
                $iconPath = Get-AppxPackageIcon -PackagePath $tempInner

                # Cleanup inner package
                try { Remove-Item -LiteralPath $tempInner -Force -ErrorAction SilentlyContinue } catch {}
                return $iconPath
            }
            $zip.Dispose()
            return $null
        } catch {
            Write-Verbose "Bundle extraction failed for '$PackagePath': $($_.Exception.Message)"
            if ($zip) { try { $zip.Dispose() } catch {} }
            return $null
        }
    }

    # --- Standard AppX / MSIX Support ---
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)

        $manifestEntry = $zip.Entries | Where-Object { $_.FullName -match 'AppxManifest\.xml$' } | Select-Object -First 1
        if (-not $manifestEntry) { $zip.Dispose(); return $null }

        $reader = New-Object System.IO.StreamReader($manifestEntry.Open())
        [xml]$manifest = $reader.ReadToEnd()
        $reader.Dispose()

        # --- PREFERRED: Extract EXE Icon for premium 3D look ---
        # Traditional EXEs usually contain beautiful 3D icons, whereas UWP PNGs are often flat.
        $exeName = $manifest.Package.Applications.Application.Executable | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($exeName)) {
            $exeBase = [System.IO.Path]::GetFileName($exeName)
            $targetExe = $null
            $tempExe = $null

            # 1. Prefer System32 if the EXE exists there (e.g., Windows 11 Notepad 3D execution alias)
            $sys32Path = Join-Path $env:windir "System32\$exeBase"
            if (Test-Path -LiteralPath $sys32Path -ErrorAction SilentlyContinue) {
                $targetExe = $sys32Path
            } else {
                # 2. Fall back to extracting the EXE directly from the MSIX package (e.g., Windows Terminal)
                $exeEntry = $zip.Entries | Where-Object { ($_.FullName -replace '\\','/') -like "*$exeBase" } | Select-Object -First 1
                if ($exeEntry) {
                    $tempExe = Join-Path $env:TEMP "MECM_$exeBase"
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($exeEntry, $tempExe, $true)
                    $targetExe = $tempExe
                }
            }

            if ($targetExe) {
                try {
                    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
                    $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($targetExe)
                    
                    $iconDir  = Join-Path $env:TEMP 'MECMIcons'
                    $null     = [System.IO.Directory]::CreateDirectory($iconDir)
                    $safeBase = [System.IO.Path]::GetFileNameWithoutExtension($PackagePath) -replace '[^A-Za-z0-9_\-]', '_'
                    $iconPath = Join-Path $iconDir "${safeBase}_exe.png"
                    
                    $icon.ToBitmap().Save($iconPath, [System.Drawing.Imaging.ImageFormat]::Png)
                    $icon.Dispose()
                    if ($tempExe) { Remove-Item -LiteralPath $tempExe -Force -ErrorAction SilentlyContinue }
                    
                    $zip.Dispose()
                    return $iconPath
                } catch {
                    # Silent fallback to flat PNGs if EXE extraction fails
                    if ($tempExe) { try { Remove-Item -LiteralPath $tempExe -Force -ErrorAction SilentlyContinue } catch {} }
                }
            }
        }

        # --- FALLBACK: Extract flat UWP PNG from MSIX ---
        $candidateLogoPaths = @()
        
        try { $candidateLogoPaths += (Select-Xml -Xml $manifest -XPath '//@Square150x150Logo').Node.Value | Select-Object -First 1 } catch {}
        try { $candidateLogoPaths += (Select-Xml -Xml $manifest -XPath '//*[local-name()="Properties"]/*[local-name()="Logo"]').Node.InnerText.Trim() | Select-Object -First 1 } catch {}
        try { $candidateLogoPaths += (Select-Xml -Xml $manifest -XPath '//@Square44x44Logo').Node.Value | Select-Object -First 1 } catch {}

        $candidateLogoPaths = @($candidateLogoPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        $iconPath = $null

        $allMatches = @()
        foreach ($rawLogoPath in $candidateLogoPaths) {
            $rawLogoPath = $rawLogoPath -replace '\\', '/'
            $logoDir  = ([System.IO.Path]::GetDirectoryName($rawLogoPath) -replace '\\', '/')
            $logoBase = [System.IO.Path]::GetFileNameWithoutExtension($rawLogoPath)
            $logoExt  = [System.IO.Path]::GetExtension($rawLogoPath)

            $pattern = if ([string]::IsNullOrEmpty($logoDir)) { "$logoBase*$logoExt" } else { "$logoDir/$logoBase*$logoExt" }
            $allMatches += @($zip.Entries | Where-Object { ($_.FullName -replace '\\','/') -like $pattern })
        }

        $bestEntry = $allMatches | Sort-Object {
            $score = 0
            if ($_.Name -match 'targetsize-(\d+)') {
                $score = [int]$Matches[1] + 1000
                if ($_.Name -match 'unplated') { $score += 500 }
            }
            elseif ($_.Name -match '\.scale-?(\d+)\.') { $score = [int]$Matches[1] }
            elseif ($_.Name -match '_scale(\d+)')  { $score = [int]$Matches[1] }
            else { $score = 100 }
            $score
        } -Descending | Where-Object {
            # Prevent exceeding MECM's 512x512 limit
            if ($_.Name -match '150x150' -and $_.Name -match 'scale-?(\d+)') {
                [int]$Matches[1] -le 200
            } elseif ($_.Name -match 'targetsize-(\d+)') {
                [int]$Matches[1] -le 512
            } else { $true }
        } | Select-Object -First 1

        if ($bestEntry) {
            $iconDir  = Join-Path $env:TEMP 'MECMIcons'
            $null     = [System.IO.Directory]::CreateDirectory($iconDir)
            $safeBase = [System.IO.Path]::GetFileNameWithoutExtension($PackagePath) -replace '[^A-Za-z0-9_\-]', '_'
            $logoExt  = [System.IO.Path]::GetExtension($bestEntry.Name)
            $iconPath = Join-Path $iconDir "$safeBase$logoExt"

            $es = $bestEntry.Open()
            $fs = [System.IO.File]::Create($iconPath)
            $es.CopyTo($fs)
            $fs.Dispose(); $es.Dispose()
        }

        $zip.Dispose()
        return $iconPath
    } catch {
        Write-Verbose "Get-AppxPackageIcon failed for '$PackagePath': $($_.Exception.Message)"
        if ($zip) { try { $zip.Dispose() } catch {} }
        return $null
    }
}

# ------------------------------------------------------------------------------
# 4. Find best MSIX for a given app — four strategies, most-reliable first
#    Uses .NET IO methods (not Get-ChildItem) to avoid CM PSDrive provider conflicts.
# ------------------------------------------------------------------------------
function Find-PackageFiles {
    # Recursively find package files under a directory using .NET IO — CM-drive safe
    param([string]$SearchRoot)
    $results = @()
    try {
        $di = New-Object System.IO.DirectoryInfo($SearchRoot)
        if (-not $di.Exists) { return $results }
        foreach ($ext in @('*.msix','*.appx','*.msixbundle','*.appxbundle')) {
            try {
                $results += $di.GetFiles($ext, [System.IO.SearchOption]::AllDirectories)
            } catch { }   # permission errors, etc.
        }
    } catch { }
    return $results
}

function Find-StagedPackage {
    param(
        [string]$AppBaseName,
        [string]$Share,
        [string]$LocalDownloads,
        [bool]$ShareAccessible
    )

    # Strip arch suffix e.g. " (x64)"
    $cleanName = ($AppBaseName -replace '\s*\((x64|x86|arm64|neutral)\)$', '').Trim()

    # --- Strategy 1: Parse SDMPackageXML on the Application object ---
    try {
        $fullApp = Get-CMApplication -Name $AppBaseName -ErrorAction SilentlyContinue
        if ($fullApp -and -not [string]::IsNullOrWhiteSpace($fullApp.SDMPackageXML)) {
            [xml]$appXml = $fullApp.SDMPackageXML
            $locationNodes = $appXml.SelectNodes('//*[local-name()="Location"]')
            foreach ($locNode in $locationNodes) {
                $contentLoc = $locNode.InnerText.Trim()
                if ([string]::IsNullOrWhiteSpace($contentLoc)) { continue }
                Write-Verbose "    [Strategy 1] Trying XML content path: $contentLoc"
                if ([System.IO.Directory]::Exists($contentLoc)) {
                    $files = Find-PackageFiles -SearchRoot $contentLoc |
                             Where-Object { $_.Name -notmatch '_License|_CustomLicense' } |
                             Sort-Object LastWriteTime -Descending
                    if ($files) {
                        Write-Verbose "    [Strategy 1 - SDMPackageXML] Found: $($files[0].FullName)"
                        return $files[0].FullName
                    } else {
                        Write-Verbose "    [Strategy 1] Path exists but no package files found in: $contentLoc"
                    }
                } else {
                    Write-Verbose "    [Strategy 1] Path not accessible: $contentLoc"
                }
            }
        } else {
            Write-Verbose "    [Strategy 1] SDMPackageXML not available for '$AppBaseName'"
        }
    } catch { Write-Verbose "    [Strategy 1] Error: $($_.Exception.Message)" }

    # --- Strategy 2: Expected subfolder structure under the share ---
    if ($ShareAccessible) {
        $searchRoots = @(
            [System.IO.Path]::Combine($Share, $cleanName),
            [System.IO.Path]::Combine($Share, '_Frameworks', $cleanName)
        )
        foreach ($root in $searchRoots) {
            Write-Verbose "    [Strategy 2] Checking: $root"
            if (-not [System.IO.Directory]::Exists($root)) {
                Write-Verbose "    [Strategy 2] Not found: $root"
                continue
            }
            $files = Find-PackageFiles -SearchRoot $root |
                     Where-Object { $_.Name -notmatch '_License|_CustomLicense' } |
                     Sort-Object LastWriteTime -Descending
            if ($files) {
                Write-Verbose "    [Strategy 2 - Share subfolder] Found: $($files[0].FullName)"
                return $files[0].FullName
            } else {
                Write-Verbose "    [Strategy 2] No package files under: $root"
            }
        }

        # --- Strategy 3: Full recursive share scan ---
        Write-Verbose "    [Strategy 3] Scanning entire share for: $cleanName*"
        $files = Find-PackageFiles -SearchRoot $Share |
                 Where-Object { $_.Name -like "$cleanName*" -and $_.Name -notmatch '_License|_CustomLicense' } |
                 Sort-Object LastWriteTime -Descending
        if ($files) {
            Write-Verbose "    [Strategy 3 - Full share scan] Found: $($files[0].FullName)"
            return $files[0].FullName
        } else {
            Write-Verbose "    [Strategy 3] No match found in share for: $cleanName*"
        }
    } else {
        Write-Verbose "    [Strategy 2+3] Skipped - share not accessible"
    }

    # --- Strategy 4: Local StoreDownloads folder (next to this script) ---
    if (-not [string]::IsNullOrWhiteSpace($LocalDownloads) -and [System.IO.Directory]::Exists($LocalDownloads)) {
        Write-Verbose "    [Strategy 4] Scanning local StoreDownloads for: $cleanName*"
        $files = Find-PackageFiles -SearchRoot $LocalDownloads |
                 Where-Object { $_.Name -like "$cleanName*" -and $_.Name -notmatch '_License|_CustomLicense' } |
                 Sort-Object LastWriteTime -Descending
        if ($files) {
            Write-Verbose "    [Strategy 4 - Local StoreDownloads] Found: $($files[0].FullName)"
            return $files[0].FullName
        } else {
            Write-Verbose "    [Strategy 4] No match found in StoreDownloads for: $cleanName*"
        }
    } else {
        Write-Verbose "    [Strategy 4] Skipped - StoreDownloads not found at: $LocalDownloads"
    }

    return $null
}


# ------------------------------------------------------------------------------
# 5. Discover target objects in MECM
# ------------------------------------------------------------------------------
Write-Host "`nScanning MECM for Store Applications and Application Groups..." -ForegroundColor Cyan

$allApps    = @(Get-CMApplication -Fast -ErrorAction SilentlyContinue)
$allGroups  = @(Get-CMApplicationGroup -ErrorAction SilentlyContinue)

# Filter to requested names if -AppName was given
if ($AppName -and $AppName.Count -gt 0) {
    $allApps   = @($allApps   | Where-Object { $n = $_.LocalizedDisplayName; $AppName | Where-Object { $n -like "*$_*" } })
    $allGroups = @($allGroups | Where-Object { $n = $_.LocalizedDisplayName; $AppName | Where-Object { $n -like "*$_*" } })
}

Write-Host "  Found $($allApps.Count) Application(s) and $($allGroups.Count) Application Group(s)" -ForegroundColor Gray

# ------------------------------------------------------------------------------
# 6. Apply icons to Applications
# ------------------------------------------------------------------------------
$appIconMap = @{}   # AppName -> iconPath  (reused for groups below)

if (-not $SkipApplications -and $allApps.Count -gt 0) {
    Write-Host "`n[1/2] Setting Application icons..." -ForegroundColor Cyan

    foreach ($app in $allApps) {
        $appDisplayName = $app.LocalizedDisplayName
        Write-Host "  Processing: $appDisplayName" -ForegroundColor Gray

        # Find a staged package file for this app
        $pkgPath = Find-StagedPackage -AppBaseName $appDisplayName -Share $targetShare -LocalDownloads $localDownloads -ShareAccessible $shareAccessible
        if (-not $pkgPath) {
            Write-Host "    [SKIP] No staged package found under: $targetShare" -ForegroundColor DarkYellow
            continue
        }

        Write-Verbose "    Package: $pkgPath"
        $iconPath = Get-AppxPackageIcon -PackagePath $pkgPath

        if (-not $iconPath) {
            Write-Host "    [SKIP] Could not extract icon from package." -ForegroundColor DarkYellow
            continue
        }

        $appIconMap[$appDisplayName] = $iconPath

        if ($PSCmdlet.ShouldProcess($appDisplayName, "Set-CMApplication -IconLocationFile")) {
            try {
                Set-CMApplication -Name $appDisplayName -IconLocationFile $iconPath -ErrorAction Stop
                Write-Host "    [OK] Icon applied: $([System.IO.Path]::GetFileName($iconPath))" -ForegroundColor Green
            } catch {
                Write-Warning "    Could not set icon on '$appDisplayName': $($_.Exception.Message)"
            }
        }
    }
}

# ------------------------------------------------------------------------------
# 7. Apply icons to Application Groups
#    Strategy: look up which apps are in each group, use the first non-framework
#    app's icon. Falls back to any icon already resolved above.
# ------------------------------------------------------------------------------
if (-not $SkipGroups -and $allGroups.Count -gt 0) {
    Write-Host "`n[2/2] Setting Application Group icons..." -ForegroundColor Cyan

    $fwKeywords = @('VCLibs','UI.Xaml','NET.Native','WindowsAppRuntime','WinAppRuntime')

    foreach ($grp in $allGroups) {
        $grpName = $grp.LocalizedDisplayName
        Write-Host "  Processing Group: $grpName" -ForegroundColor Gray

        $iconPath = $null

        # Parse member app names from the group's SDMPackageXML
        $grpFull = Get-CMApplicationGroup -Name $grpName -ErrorAction SilentlyContinue
        if ($grpFull -and $grpFull.SDMPackageXML) {
            $memberMatches = [regex]::Matches($grpFull.SDMPackageXML, '<ObjectId[^>]+LogicalName="([^"]+)"')
            $memberNames   = $memberMatches | ForEach-Object { $_.Groups[1].Value }

            # Try each member, preferring non-framework apps
            $orderedNames = $memberNames | Sort-Object {
                $n = $_
                if ($fwKeywords | Where-Object { $n -match "(?i)$_" }) { 1 } else { 0 }
            }

            foreach ($memberLogicalName in $orderedNames) {
                # Logical name may differ from display name; find the app object using -match for ModelName
                $memberApp = $allApps | Where-Object { $_.ModelName -match $memberLogicalName -or $_.LocalizedDisplayName -eq $memberLogicalName } | Select-Object -First 1
                if (-not $memberApp) {
                    # Try a broader search
                    $memberApp = Get-CMApplication -Fast -ErrorAction SilentlyContinue | Where-Object { $_.ModelName -match $memberLogicalName } | Select-Object -First 1
                }

                $memberDisplayName = if ($memberApp) { $memberApp.LocalizedDisplayName } else { $memberLogicalName }

                # Reuse icon already extracted, or find & extract now
                if ($appIconMap.ContainsKey($memberDisplayName)) {
                    $iconPath = $appIconMap[$memberDisplayName]
                } else {
                    $pkgPath = Find-StagedPackage -AppBaseName $memberDisplayName -Share $targetShare -LocalDownloads $localDownloads -ShareAccessible $shareAccessible
                    if ($pkgPath) {
                        $iconPath = Get-AppxPackageIcon -PackagePath $pkgPath
                        if ($iconPath) { $appIconMap[$memberDisplayName] = $iconPath }
                    }
                }

                # Stop at first non-framework icon found
                $isFw = $fwKeywords | Where-Object { $memberDisplayName -match "(?i)$_" }
                if ($iconPath -and -not $isFw) { break }
            }
        }

        # Last resort: pick any icon already in the map that matches the group name
        if (-not $iconPath) {
            $grpBaseName = ($grpName -replace '\s*-\s*Application Group.*$', '').Trim()
            $iconPath = $appIconMap.GetEnumerator() |
                        Where-Object { $_.Key -like "*$grpBaseName*" } |
                        Select-Object -First 1 -ExpandProperty Value
        }

        if (-not $iconPath) {
            Write-Host "    [SKIP] Could not resolve an icon for this group." -ForegroundColor DarkYellow
            continue
        }

        if ($PSCmdlet.ShouldProcess($grpName, "Set-CMApplicationGroup -IconLocationFile")) {
            try {
                Set-CMApplicationGroup -Name $grpName -IconLocationFile $iconPath -ErrorAction Stop
                Write-Host "    [OK] Icon applied: $([System.IO.Path]::GetFileName($iconPath))" -ForegroundColor Green
            } catch {
                Write-Warning "    Could not set icon on group '$grpName': $($_.Exception.Message)"
            }
        }
    }
}

# ------------------------------------------------------------------------------
# 8. Done
# ------------------------------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "                  ICON PATCH COMPLETE                     " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "Icons are stored in MECM's database. No redeploy needed.`n" -ForegroundColor Green
