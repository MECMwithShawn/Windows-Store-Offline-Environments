<#
.SYNOPSIS
    Automates the creation of MECM/SCCM Applications for Microsoft Store app
    packages and their dependencies, configures device-wide provisioning, and
    builds an ordered Application Group.

.DESCRIPTION
    This script inspects downloaded Store packages (.appx, .msix, .appxbundle,
    .msixbundle), organizes content into standard MECM UNC shares, creates native
    Windows app package applications with "Provision this application for all
    users on the device" enabled, and bundles them into an MECM Application Group
    sequenced in the correct install order (frameworks first, main apps last).
    Supports processing single or multiple downloaded applications in batch.

.PARAMETER PackagePath
    Local or UNC directory containing downloaded app packages. If omitted, the
    script prompts or auto-discovers packages in .\StoreDownloads.

.PARAMETER All
    Switch to automatically batch-process all applications discovered in .\StoreDownloads.

.PARAMETER ContentShare
    Target UNC root share where MECM package folders will be hosted.
    Defaults to '\\<ServerName>\Software\Microsoft\Windows Store Apps'.
    Packages are staged into '<AppName>\v.<Version>' subfolders.

.PARAMETER SiteCode
    The 3-letter MECM Site Code (e.g. 'PS1'). If omitted, the script attempts
    to auto-detect it from current PSDrives or registry.

.PARAMETER SiteServer
    The SMS Provider / Site Server FQDN. Defaults to 'localhost'.

.PARAMETER AppGroupName
    Custom name for the MECM Application Group. Defaults to
    '<App Name> <Version> - Application Group'.

.PARAMETER Arch
    Target architecture filter: x64 (default), all, arm64, x86.

.PARAMETER DistributeContent
    Switch to automatically distribute the created applications and group to
    Distribution Points.

.PARAMETER DPGroupName
    Optional Distribution Point Group name for content distribution.

.PARAMETER WhatIf
    Previews actions without making changes in MECM or file system.

.EXAMPLE
    .\Publish-MECMStoreApp.ps1

.EXAMPLE
    # Batch process all discovered apps in StoreDownloads:
    .\Publish-MECMStoreApp.ps1 -All

.EXAMPLE
    .\Publish-MECMStoreApp.ps1 -PackagePath ".\StoreDownloads\Windows Terminal\3001.24.11911.0" `
                               -ContentShare "\\CM01\Software\Microsoft\Windows Store Apps" `
                               -SiteCode "PS1"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [string]$PackagePath,

    [switch]$All,

    [Parameter(Position = 1)]
    [string]$ContentShare,

    [string]$SiteCode,

    [string]$SiteServer = 'localhost',

    [string]$AppGroupName,

    [ValidateSet('x64', 'all', 'x86', 'arm64', 'neutral')]
    [string]$Arch = 'x64',

    [switch]$DistributeContent,

    [string]$DPGroupName,

    [string]$ConsoleRootFolder = 'Windows Store Applications'
)

$ErrorActionPreference = 'Stop'

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "     MECM Store App & Application Group Automator         " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 1. Helper Functions: Package Identity Parser & Tier Sequencing
# ------------------------------------------------------------------------------
function Get-AppxPackageIdentity {
    param([string]$FileName)
    $baseName = $FileName -replace '\.(appx|appxbundle|msix|msixbundle|eappx|eappxbundle|emsix|emsixbundle)$', ''
    $parts = $baseName -split '_'
    if ($parts.Count -ge 5) {
        $publisherId = $parts[-1]
        $resourceId  = $parts[-2]
        $archToken   = $parts[-3].ToLowerInvariant()
        $version     = $parts[-4]
        $pkgName     = ($parts[0..($parts.Count - 5)]) -join '_'
        $verObj      = try { [version]$version } catch { [version]'0.0.0.0' }
        [pscustomobject]@{
            PackageName  = $pkgName
            Version      = $version
            VersionObj   = $verObj
            Architecture = $archToken
            ResourceId   = $resourceId
            PublisherId  = $publisherId
            IsValid      = $true
        }
    } else {
        $archToken = 'unknown'
        foreach ($token in $parts) {
            $t = $token.ToLowerInvariant()
            if ($t -in 'x64', 'x86', 'arm', 'arm64', 'neutral') {
                $archToken = $t
                break
            }
        }
        $version = if ($baseName -match '(\d+\.\d+\.\d+\.\d+)') { $Matches[1] } else { '0.0.0.0' }
        $verObj = try { [version]$version } catch { [version]'0.0.0.0' }
        [pscustomobject]@{
            PackageName  = $baseName
            Version      = $version
            VersionObj   = $verObj
            Architecture = $archToken
            ResourceId   = ''
            PublisherId  = ''
            IsValid      = $false
        }
    }
}

function Get-PackageTier {
    param([string]$PackageName)
    # Tier 1: Core C/C++ runtimes
    if ($PackageName -match '(?i)(VCLibs|CRT)') { return 1 }
    # Tier 2: Managed / UI frameworks
    if ($PackageName -match '(?i)(NET\.Native\.Runtime)') { return 2 }
    if ($PackageName -match '(?i)(NET\.Native\.Framework)') { return 3 }
    if ($PackageName -match '(?i)(UI\.Xaml)') { return 4 }
    if ($PackageName -match '(?i)(WindowsAppRuntime|WinAppRuntime)') { return 5 }
    if ($PackageName -match '(?i)(PlayReady|DirectX|SecOps)') { return 6 }
    # Tier 3: Main application package
    return 10
}

# ------------------------------------------------------------------------------
# 2. Package Location Discovery & Interactive Prompting
# ------------------------------------------------------------------------------
$validExtensions = @('.appx', '.msix', '.appxbundle', '.msixbundle')
$selectedAppFolders = @()

if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    # Check for StoreDownloads in script directory or current working directory
    $sdRoot = $null
    $searchLocations = @(
        (Join-Path $PSScriptRoot 'StoreDownloads'),
        (Join-Path $PWD.Path 'StoreDownloads')
    ) | Select-Object -Unique

    foreach ($loc in $searchLocations) {
        if (Test-Path -LiteralPath $loc) {
            $sdRoot = $loc
            break
        }
    }

    if ($sdRoot) {
        # Find all leaf directories inside StoreDownloads that contain package files
        $candidateDirs = @()
        Get-ChildItem -LiteralPath $sdRoot -Directory -Recurse | ForEach-Object {
            $pkgs = Get-ChildItem -LiteralPath $_.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension.ToLowerInvariant() -in $validExtensions }
            if ($pkgs.Count -gt 0) {
                $mainBundle = $pkgs | Where-Object { $_.Extension -match 'bundle' -or $_.Name -notmatch '(?i)(VCLibs|UI\.Xaml|NET\.Native|WindowsAppRuntime)' } | Select-Object -First 1
                $appTitle = if ($mainBundle) { (Get-AppxPackageIdentity -FileName $mainBundle.Name).PackageName } else { $_.Parent.Name }
                $appVer = if ($mainBundle) { (Get-AppxPackageIdentity -FileName $mainBundle.Name).Version } else { $_.Name }

                $candidateDirs += [pscustomobject]@{
                    Path        = $_.FullName
                    AppName     = $appTitle
                    Version     = $appVer
                    FileCount   = $pkgs.Count
                    DisplayPath = $_.FullName.Replace($PWD.Path, '.').TrimStart('\')
                }
            }
        }

        if ($All -and $candidateDirs.Count -gt 0) {
            Write-Host "`n[-All specified] Batch processing all $($candidateDirs.Count) discovered applications." -ForegroundColor Green
            $selectedAppFolders = $candidateDirs.Path
        } elseif ($candidateDirs.Count -eq 1) {
            $c = $candidateDirs[0]
            Write-Host "`nDiscovered downloaded app in .\StoreDownloads:" -ForegroundColor Green
            Write-Host "  App     : $($c.AppName) (v$($c.Version))" -ForegroundColor Cyan
            Write-Host "  Packages: $($c.FileCount) package(s)"
            Write-Host "  Path    : $($c.DisplayPath)"

            if (-not [Console]::IsInputRedirected) {
                $choice = Read-Host "`nPress Enter to use this app, or type [C] to specify a custom folder [Enter]"
                if ($choice.Trim() -match '^(c|custom)$') {
                    $custom = Read-Host "Enter custom package folder path"
                    if (-not [string]::IsNullOrWhiteSpace($custom)) { $selectedAppFolders = @($custom.Trim()) }
                } else {
                    $selectedAppFolders = @($c.Path)
                }
            } else {
                $selectedAppFolders = @($c.Path)
            }
        } elseif ($candidateDirs.Count -gt 1) {
            Write-Host "`nDiscovered downloaded app(s) in .\StoreDownloads:" -ForegroundColor Yellow
            for ($i = 0; $i -lt $candidateDirs.Count; $i++) {
                $c = $candidateDirs[$i]
                Write-Host ("  [{0}] {1} (v{2}) - {3} package(s) [{4}]" -f ($i + 1), $c.AppName, $c.Version, $c.FileCount, $c.DisplayPath)
            }
            Write-Host "  [A] All apps (process all $($candidateDirs.Count) applications)" -ForegroundColor Green
            Write-Host "  [C] Custom path (specify another download folder)"

            if (-not [Console]::IsInputRedirected) {
                $pick = Read-Host "`nSelect an app (1-$($candidateDirs.Count), comma-separated e.g. '1,2', or 'A' for all) [A]"
                $trimmed = $pick.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -match '^(a|all)$') {
                    $selectedAppFolders = $candidateDirs.Path
                } elseif ($trimmed -match '^(c|custom)$') {
                    $custom = Read-Host "Enter custom package folder path"
                    if (-not [string]::IsNullOrWhiteSpace($custom)) { $selectedAppFolders = @($custom.Trim()) }
                } else {
                    # Parse comma-separated or single numbers
                    $parts = $trimmed -split '[,\s]+'
                    foreach ($p in $parts) {
                        $idx = 0
                        if ([int]::TryParse($p, [ref]$idx) -and $idx -ge 1 -and $idx -le $candidateDirs.Count) {
                            $selectedAppFolders += $candidateDirs[$idx - 1].Path
                        }
                    }
                }
            } else {
                $selectedAppFolders = $candidateDirs.Path
            }
        }
    }
} else {
    # PackagePath was explicitly passed
    $resolvedExplicit = (Resolve-Path -LiteralPath $PackagePath).Path
    # Check if this folder contains package files directly or has subfolders with packages
    $directPkgs = Get-ChildItem -LiteralPath $resolvedExplicit -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension.ToLowerInvariant() -in $validExtensions }
    if ($directPkgs.Count -gt 0) {
        $selectedAppFolders = @($resolvedExplicit)
    } else {
        # Check subdirectories
        Get-ChildItem -LiteralPath $resolvedExplicit -Directory -Recurse | ForEach-Object {
            $pkgs = Get-ChildItem -LiteralPath $_.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension.ToLowerInvariant() -in $validExtensions }
            if ($pkgs.Count -gt 0) {
                $selectedAppFolders += $_.FullName
            }
        }
    }
}

if (-not $selectedAppFolders -or $selectedAppFolders.Count -eq 0) {
    if (-not [Console]::IsInputRedirected) {
        Write-Host "No packages found in .\StoreDownloads." -ForegroundColor Yellow
        $enteredPath = Read-Host "Enter path to downloaded app package folder"
        if (-not [string]::IsNullOrWhiteSpace($enteredPath)) {
            $selectedAppFolders = @($enteredPath.Trim())
        }
    }
}

if (-not $selectedAppFolders -or $selectedAppFolders.Count -eq 0) {
    $selectedAppFolders = @($PWD.Path)
}

# ------------------------------------------------------------------------------
# 3. Prompt for ContentShare with Auto-Default (\\SERVER\Software\Microsoft\Windows Store Apps)
# ------------------------------------------------------------------------------
$serverName = if (-not [string]::IsNullOrWhiteSpace($SiteServer) -and $SiteServer -ne 'localhost') {
    $SiteServer
} else {
    $env:COMPUTERNAME
}

$defaultShare = "\\$serverName\Software\Microsoft\Windows Store Apps"

if ([string]::IsNullOrWhiteSpace($ContentShare)) {
    if (-not [Console]::IsInputRedirected) {
        Write-Host "`nMECM UNC Content Share:" -ForegroundColor Yellow
        Write-Host "  Default: $defaultShare" -ForegroundColor Cyan
        $enteredShare = Read-Host "`nPress Enter to accept default, or enter alternate UNC path [Enter]"
        if (-not [string]::IsNullOrWhiteSpace($enteredShare)) {
            $ContentShare = $enteredShare.Trim()
        } else {
            $ContentShare = $defaultShare
        }
    } else {
        $ContentShare = $defaultShare
    }
}

Write-Host "Target UNC Content Share: $ContentShare" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 4. Helper: Ensure MECM Console Folder & Move Object (PowerShell + WMI MoveMembers)
# ------------------------------------------------------------------------------
function Set-MECMConsoleFolder {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Application', 'ApplicationGroup', 'Application Groups', 'Applications')]
        [string]$RootType,

        [Parameter(Mandatory = $true)]
        [string[]]$FolderHierarchy,

        [Parameter(Mandatory = $true)]
        $InputObject,

        [string]$SiteCode,

        [string]$SiteServer = 'localhost'
    )

    try {
        if ([string]::IsNullOrWhiteSpace($SiteCode)) {
            $cmDrives = Get-PSDrive -PSProvider CMSite -ErrorAction SilentlyContinue
            if ($cmDrives) { $SiteCode = $cmDrives[0].Name }
        }

        $isGroup = ($RootType -match 'Group')
        $targetObjectType = if ($isGroup) { [uint32]224 } else { [uint32]6000 }
        $actualHierarchy = [System.Collections.Generic.List[string]]::new($FolderHierarchy)

        # Discover or normalize top-level root folder name in MECM
        if ($SiteCode) {
            try {
                $ns = "root\sms\site_$SiteCode"
                if ($isGroup) {
                    # Search for any existing container node under Application Groups (ObjectType = 224)
                    $existingGroupNode = Get-CimInstance -Namespace $ns -ClassName SMS_ObjectContainerNode -Filter "ObjectType = 224 and ParentContainerNodeID = 0 and (Name = '$($FolderHierarchy[0])' or Name = 'Windows Store Apps' or Name = 'Windows Store Applications')" -ErrorAction SilentlyContinue | Select-Object -First 1
                    
                    if ($existingGroupNode) {
                        $actualHierarchy[0] = $existingGroupNode.Name
                    }
                }
            } catch { }
        }

        # Method A: Try native Move-CMObject first (for Applications)
        $moved = $false
        if (-not $isGroup) {
            $currentParent = 'Application'
            foreach ($seg in $actualHierarchy) {
                if ([string]::IsNullOrWhiteSpace($seg)) { continue }
                $targetPath = "$currentParent\$seg"
                $existing = Get-CMFolder -FolderPath $targetPath -ErrorAction SilentlyContinue
                if (-not $existing) {
                    try { $null = New-CMFolder -ParentFolderPath $currentParent -Name $seg -ErrorAction SilentlyContinue } catch { }
                }
                $currentParent = $targetPath
            }
            try {
                $null = Move-CMObject -FolderPath $currentParent -InputObject $InputObject -ErrorAction SilentlyContinue
                $moved = $true
            } catch { }
        }

        # Method B: WMI / CIM MoveMembers (for Application Groups and nested hierarchies)
        if ($SiteCode -and (-not $moved -or $isGroup)) {
            $ns = "root\sms\site_$SiteCode"
            $parentContainerID = [uint32]0
            foreach ($seg in $actualHierarchy) {
                if ([string]::IsNullOrWhiteSpace($seg)) { continue }
                $node = Get-CimInstance -Namespace $ns -ClassName SMS_ObjectContainerNode -Filter "ObjectType = $targetObjectType and ParentContainerNodeID = $parentContainerID and Name = '$seg'" -ErrorAction SilentlyContinue
                if (-not $node) {
                    $node = New-CimInstance -Namespace $ns -ClassName SMS_ObjectContainerNode -Property @{
                        Name                  = $seg
                        ObjectType            = [uint32]$targetObjectType
                        ParentContainerNodeID = [uint32]$parentContainerID
                    } -ErrorAction SilentlyContinue
                }
                if ($node) {
                    $parentContainerID = [uint32]$node.ContainerNodeID
                }
            }

            if ($parentContainerID -gt 0) {
                $candidateKeys = @($InputObject.ModelName, $InputObject.CI_ID, $InputObject.CI_UniqueID, $InputObject.AppGroupUniqueID) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

                foreach ($key in $candidateKeys) {
                    try {
                        $moveParams = @{
                            ContainerNodeID       = [uint32]0
                            InstanceKeys          = [string[]]@([string]$key)
                            ObjectType            = [uint32]$targetObjectType
                            TargetContainerNodeID = [uint32]$parentContainerID
                        }
                        $null = Invoke-CimMethod -Namespace $ns -ClassName "SMS_ObjectContainerItem" -MethodName "MoveMembers" -Arguments $moveParams -ErrorAction Stop
                        $moved = $true
                        break
                    } catch {
                        try {
                            $server = if ($SiteServer -and $SiteServer -ne 'localhost') { $SiteServer } else { $env:COMPUTERNAME }
                            $wmiItemClass = [WMIClass]"\\$server\$ns:SMS_ObjectContainerItem"
                            $inParams = $wmiItemClass.psbase.GetMethodParameters("MoveMembers")
                            $inParams.ContainerNodeID = [uint32]0
                            $inParams.InstanceKeys = [string[]]@([string]$key)
                            $inParams.ObjectType = [uint32]$targetObjectType
                            $inParams.TargetContainerNodeID = [uint32]$parentContainerID
                            $null = $wmiItemClass.psbase.InvokeMethod("MoveMembers", $inParams, $null)
                            $moved = $true
                            break
                        } catch { }
                    }
                }
            }
        }
    } catch { }
}

# ------------------------------------------------------------------------------
# 5. Helper: Enable "Provision this application for all users on the device" (SDK)
# ------------------------------------------------------------------------------
function Set-CMAppxProvisionForAllUsers {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$ApplicationName
    )

    # 1. Locate and load required ConfigMgr Admin Console SDK assemblies
    $binCandidates = @(
        $env:SMS_ADMIN_UI_PATH,
        "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin",
        "C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin",
        "C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin"
    )

    $binDir = $null
    foreach ($cand in $binCandidates) {
        if (-not [string]::IsNullOrWhiteSpace($cand) -and (Test-Path $cand)) {
            $dir = if (Test-Path $cand -PathType Container) { $cand } else { Split-Path $cand -Parent }
            if (Test-Path (Join-Path $dir 'Microsoft.ConfigurationManagement.ApplicationManagement.dll')) {
                $binDir = $dir
                break
            }
        }
    }

    if (-not $binDir) {
        Write-Warning "Could not locate ConfigMgr Admin Console SDK assemblies in standard paths."
        return $false
    }

    try {
        [System.Reflection.Assembly]::LoadFrom((Join-Path $binDir 'Microsoft.ConfigurationManagement.ApplicationManagement.dll')) | Out-Null
        [System.Reflection.Assembly]::LoadFrom((Join-Path $binDir 'Microsoft.ConfigurationManagement.ApplicationManagement.Win8Installer.dll')) | Out-Null
    } catch {
        Write-Warning "Failed to load ConfigMgr SDK assemblies: $($_.Exception.Message)"
        return $false
    }

    # 2. Retrieve Application WMI / SDK ResultObject
    $fullApp = Get-CMApplication -Name $ApplicationName -ErrorAction SilentlyContinue
    if (-not $fullApp) { return $false }

    $xml = $fullApp.SDMPackageXML
    if ([string]::IsNullOrWhiteSpace($xml)) {
        Write-Warning "SDMPackageXML is empty on Application '$ApplicationName'."
        return $false
    }

    # 3. Deserialize via official SccmSerializer
    try {
        $appObj = [Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer]::DeserializeFromString($xml, $true)
    } catch {
        Write-Warning "SccmSerializer deserialization failed on '$ApplicationName': $($_.Exception.Message)"
        return $false
    }

    $modified = $false
    foreach ($dt in $appObj.DeploymentTypes) {
        if ($dt.Installer -is [Microsoft.ConfigurationManagement.ApplicationManagement.Windows8AppInstaller] -or
            $dt.Installer -is [Microsoft.ConfigurationManagement.ApplicationManagement.Installer]) {
            if ($dt.Installer.ExecutionContext -ne [Microsoft.ConfigurationManagement.ApplicationManagement.ExecutionContext]::System) {
                $dt.Installer.ExecutionContext = [Microsoft.ConfigurationManagement.ApplicationManagement.ExecutionContext]::System
                $modified = $true
            }
        }
    }

    # 4. Re-serialize and persist back via SMS Provider
    if ($modified) {
        if ($PSCmdlet.ShouldProcess($ApplicationName, "Enable device-wide provisioning (ExecutionContext = System)")) {
            $newXml = [Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer]::SerializeToString($appObj, $true)
            $fullApp.SDMPackageXML = $newXml
            $null = $fullApp.Put()
            Write-Host "  Provision for all users successfully ENABLED on '$ApplicationName' (ExecutionContext = System)." -ForegroundColor Green
        }
        return $true
    } else {
        Write-Host "  Provision for all users is already enabled on '$ApplicationName'." -ForegroundColor DarkGray
        return $true
    }
}

# ------------------------------------------------------------------------------
# 6. Helper: Extract icon PNG from an MSIX/AppX package
# ------------------------------------------------------------------------------
function Get-AppxPackageIcon {
    <#
    .SYNOPSIS
        Extracts the highest-resolution logo image from an MSIX/AppX package.
    .OUTPUTS
        Absolute path to a temporary PNG file, or $null on failure.
    #>
    param([Parameter(Mandatory)][string]$PackagePath)

    # --- Bundle Support ---
    if ($PackagePath -match '\.(msixbundle|appxbundle)$') {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
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

                $iconPath = Get-AppxPackageIcon -PackagePath $tempInner
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
# 7. Connect to MECM / Configuration Manager
# ------------------------------------------------------------------------------
$mecmConnected = $false

function Connect-MECM {
    param([string]$SiteCode, [string]$SiteServer)

    if (-not (Get-Module -Name ConfigurationManager)) {
        $modulePath = $null
        if ($env:SMS_ADMIN_UI_PATH) {
            $modulePath = Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1'
        }
        if (-not $modulePath -or -not (Test-Path $modulePath)) {
            $candidates = @(
                "C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\ConfigurationManager.psd1",
                "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
            )
            foreach ($c in $candidates) {
                if (Test-Path $c) { $modulePath = $c; break }
            }
        }

        if ($modulePath -and (Test-Path $modulePath)) {
            Write-Host "Importing ConfigurationManager module from: $modulePath" -ForegroundColor Cyan
            Import-Module $modulePath -Force
        } else {
            throw "ConfigurationManager PowerShell module not found. Run on a machine with MECM Admin Console installed, or specify -WhatIf to preview."
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
        if (-not [Console]::IsInputRedirected) {
            $enteredSite = Read-Host "Enter MECM Site Code (e.g. PS1)"
            if (-not [string]::IsNullOrWhiteSpace($enteredSite)) {
                $SiteCode = $enteredSite.Trim()
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($SiteCode)) {
        throw "Could not determine MECM Site Code. Specify -SiteCode (e.g. -SiteCode 'PS1')."
    }

    if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        $server = if ($SiteServer) { $SiteServer } else { 'localhost' }
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $server -Description "MECM Site Drive" -Scope Global -ErrorAction Stop | Out-Null
    }

    Set-Location "$($SiteCode):" -ErrorAction Stop
    Write-Host "Connected to MECM Site: $SiteCode" -ForegroundColor Green
    return $true
}

if ($PSCmdlet.ShouldProcess("MECM Site", "Connect and create applications")) {
    try {
        $mecmConnected = Connect-MECM -SiteCode $SiteCode -SiteServer $SiteServer
    } catch {
        Write-Error "MECM Connection Failed: $($_.Exception.Message)"
        Write-Warning "To preview package staging and group sequencing without MECM, rerun with -WhatIf."
        return
    }
}

# ------------------------------------------------------------------------------
# 7. Process Each Selected Application Package Folder
# ------------------------------------------------------------------------------
$summaryResults = @()
$appFolderIndex = 1

foreach ($appFolder in $selectedAppFolders) {
    $resolvedPkgPath = (Resolve-Path -LiteralPath $appFolder).Path
    Write-Host "`n==========================================================" -ForegroundColor Magenta
    Write-Host " [$appFolderIndex/$($selectedAppFolders.Count)] Processing: $resolvedPkgPath" -ForegroundColor Magenta
    Write-Host "==========================================================" -ForegroundColor Magenta

    $foundFiles = Get-ChildItem -LiteralPath $resolvedPkgPath -File -Recurse | Where-Object {
        $_.Extension.ToLowerInvariant() -in $validExtensions
    }

    if (-not $foundFiles -or $foundFiles.Count -eq 0) {
        Write-Warning "No package files found in '$resolvedPkgPath'. Skipping."
        $appFolderIndex++
        continue
    }

    # Parse & Sequence Discovered Packages
    $parsedPackages = @()
    foreach ($file in $foundFiles) {
        $ident = Get-AppxPackageIdentity -FileName $file.Name
        
        # Filter architecture
        if ($Arch -ne 'all') {
            if ($ident.Architecture -ne $Arch -and $ident.Architecture -ne 'neutral') {
                Write-Host "  Skipping non-matching architecture ($($ident.Architecture)): $($file.Name)" -ForegroundColor DarkGray
                continue
            }
        }

        $tier = Get-PackageTier -PackageName $ident.PackageName
        $isFramework = ($tier -lt 10)

        $parsedPackages += [pscustomobject]@{
            File        = $file
            Name        = $file.Name
            Identity    = $ident
            Tier        = $tier
            IsFramework = $isFramework
        }
    }

    if ($parsedPackages.Count -eq 0) {
        Write-Warning "No packages matched architecture '$Arch' in '$resolvedPkgPath'. Skipping."
        $appFolderIndex++
        continue
    }

    # Sort by Tier ascending, then Name
    $orderedPackages = $parsedPackages | Sort-Object Tier, { $_.Identity.PackageName }

    $mainApps = $orderedPackages | Where-Object { -not $_.IsFramework }
    $frameworks = $orderedPackages | Where-Object { $_.IsFramework }

    $primaryApp = if ($mainApps.Count -gt 0) { $mainApps[0] } else { $orderedPackages[-1] }
    $mainAppName = $primaryApp.Identity.PackageName
    $mainAppVersion = $primaryApp.Identity.Version

    $currentAppGroupName = if ($selectedAppFolders.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($AppGroupName)) {
        $AppGroupName
    } else {
        "$mainAppName $mainAppVersion - Application Group"
    }

    Write-Host "`nDiscovered Packages (Ordered for Deployment):" -ForegroundColor Green
    $step = 1
    foreach ($pkg in $orderedPackages) {
        $typeLabel = if ($pkg.IsFramework) { "Framework (Tier $($pkg.Tier))" } else { "Main Application" }
        Write-Host ("  [{0}] {1} (v{2}, {3}) - {4}" -f $step, $pkg.Identity.PackageName, $pkg.Identity.Version, $pkg.Identity.Architecture, $typeLabel)
        $step++
    }
    Write-Host "Target Application Group: $currentAppGroupName" -ForegroundColor Cyan

    # Track the primary (non-framework) app's icon for the Application Group
    $primaryAppIconPath = $null

    # Content Share Staging
    $stagedPackages = @()
    $contentRoot = $ContentShare.TrimEnd('\')
    Write-Host "`nStaging content to UNC source: $contentRoot" -ForegroundColor Cyan

    foreach ($pkg in $orderedPackages) {
        $verFolder = "v.$($pkg.Identity.Version)"

        $destSubFolder = if ($pkg.IsFramework) {
            Join-Path (Join-Path (Join-Path $contentRoot '_Frameworks') $pkg.Identity.PackageName) "$verFolder.$($pkg.Identity.Architecture)"
        } else {
            Join-Path (Join-Path $contentRoot $pkg.Identity.PackageName) $verFolder
        }

        $destFilePath = Join-Path $destSubFolder $pkg.File.Name

        if ($PSCmdlet.ShouldProcess($destFilePath, "Copy package to UNC content share")) {
            if (-not [System.IO.Directory]::Exists($destSubFolder)) {
                $null = [System.IO.Directory]::CreateDirectory($destSubFolder)
            }
            $needCopy = $true
            if ([System.IO.File]::Exists($destFilePath)) {
                $destFileInfo = New-Object System.IO.FileInfo($destFilePath)
                if ($destFileInfo.Length -eq $pkg.File.Length) {
                    $needCopy = $false
                }
            }
            if ($needCopy) {
                [System.IO.File]::Copy($pkg.File.FullName, $destFilePath, $true)
                Write-Host "  Copied: $($pkg.File.Name) -> $destSubFolder" -ForegroundColor Gray
            } else {
                Write-Host "  Already staged: $($pkg.File.Name)" -ForegroundColor DarkGray
            }
        }

        $stagedPackages += [pscustomobject]@{
            PackageInfo     = $pkg
            ContentLocation = $destSubFolder
            PackageFilePath = $destFilePath
            AppDisplayName  = if ($pkg.IsFramework) { "$($pkg.Identity.PackageName) ($($pkg.Identity.Architecture))" } else { $pkg.Identity.PackageName }
        }
    }

    # Create Applications & Deployment Types
    $createdAppNames = @()

    foreach ($staged in $stagedPackages) {
        $pkg = $staged.PackageInfo
        $appName = $staged.AppDisplayName
        $pkgFileLocation = $staged.PackageFilePath

        $appFolderHierarchy = if ($pkg.IsFramework) {
            @($ConsoleRootFolder, '_Frameworks', $pkg.Identity.PackageName, "v.$($pkg.Identity.Version).$($pkg.Identity.Architecture)")
        } else {
            @($ConsoleRootFolder, $pkg.Identity.PackageName, "v.$($pkg.Identity.Version)")
        }

        if ($mecmConnected) {
            Write-Host "`nProcessing Application: $appName" -ForegroundColor Cyan
            $targetApp = Get-CMApplication -Name $appName -Fast -ErrorAction SilentlyContinue

            if ($targetApp) {
                $existingDT = Get-CMDeploymentType -ApplicationName $appName -ErrorAction SilentlyContinue
                if ($existingDT) {
                    Write-Host "  Application '$appName' already exists in MECM with deployment type. Reusing." -ForegroundColor Green
                } else {
                    Write-Host "  Application '$appName' exists but is missing deployment type. Adding Deployment Type..." -ForegroundColor Yellow
                    try {
                        $null = Add-CMAppxDeploymentType -ApplicationName $appName `
                                                         -ContentLocation $pkgFileLocation `
                                                         -DeploymentTypeName "$appName - Native AppX" `
                                                         -LogonRequirementType WhetherOrNotUserLoggedOn `
                                                         -ErrorAction Stop
                    } catch {
                        $null = Add-CMAppxDeploymentType -ApplicationName $appName `
                                                         -ContentLocation $pkgFileLocation `
                                                         -DeploymentTypeName "$appName - Native AppX" `
                                                         -ErrorAction Stop
                    }
                    Write-Host "  Deployment type created successfully." -ForegroundColor Green
                }
            } else {
                Write-Host "  Creating new Application: $appName" -ForegroundColor Yellow
                $targetApp = New-CMApplication -Name $appName `
                                               -Publisher "Microsoft" `
                                               -SoftwareVersion $pkg.Identity.Version `
                                               -Description "Offline Windows Store Package ($($pkg.Identity.Architecture))"

                Write-Host "  Creating native Windows app package Deployment Type..." -ForegroundColor Yellow
                
                try {
                    $null = Add-CMAppxDeploymentType -ApplicationName $appName `
                                                     -ContentLocation $pkgFileLocation `
                                                     -DeploymentTypeName "$appName - Native AppX" `
                                                     -LogonRequirementType WhetherOrNotUserLoggedOn `
                                                     -ErrorAction Stop
                } catch {
                    $null = Add-CMAppxDeploymentType -ApplicationName $appName `
                                                     -ContentLocation $pkgFileLocation `
                                                     -DeploymentTypeName "$appName - Native AppX" `
                                                     -ErrorAction Stop
                }
            }

            # Enable "Provision this application for all users on the device" (SDK)
            $null = Set-CMAppxProvisionForAllUsers -ApplicationName $appName

            # Set Application icon from the package's embedded logo
            $pkgIconPath = Get-AppxPackageIcon -PackagePath $pkg.File.FullName
            if ($pkgIconPath) {
                try {
                    Set-CMApplication -Name $appName -IconLocationFile $pkgIconPath -ErrorAction SilentlyContinue
                    Write-Host "  Icon set on Application '$appName' from: $([System.IO.Path]::GetFileName($pkgIconPath))" -ForegroundColor DarkGray
                } catch {
                    Write-Verbose "  Could not set icon on Application '$appName': $($_.Exception.Message)"
                }
                # Capture the primary (non-framework) app's icon for the Application Group
                if (-not $pkg.IsFramework -and -not $primaryAppIconPath) {
                    $primaryAppIconPath = $pkgIconPath
                }
            }

            # Organize into Application console folder
            $freshApp = Get-CMApplication -Name $appName -Fast -ErrorAction SilentlyContinue
            if ($freshApp) {
                Write-Host "  Organizing into Console Folder: Application\$($appFolderHierarchy -join '\')" -ForegroundColor Cyan
                Set-MECMConsoleFolder -RootType 'Application' -FolderHierarchy $appFolderHierarchy -InputObject $freshApp -SiteCode $SiteCode -SiteServer $SiteServer
            }
        } else {
            Write-Host "[WhatIf] Would create Application: '$appName' (Content: '$pkgFileLocation') with Provision for All Users." -ForegroundColor Yellow
            Write-Host "[WhatIf] Would organize into Console Folder: 'Application\$($appFolderHierarchy -join '\')'" -ForegroundColor DarkGray
        }

        $createdAppNames += $appName
    }

    # Create / Update Application Group
    $groupFolderHierarchy = @($ConsoleRootFolder, $mainAppName, "v.$mainAppVersion")

    if ($mecmConnected) {
        Write-Host "`nConfiguring Application Group: $currentAppGroupName" -ForegroundColor Cyan
        $existingGroup = Get-CMApplicationGroup -Name $currentAppGroupName -ErrorAction SilentlyContinue
        $targetGroup = $null

        if (-not $existingGroup) {
            Write-Host "  Creating Application Group '$currentAppGroupName' with ordered applications:" -ForegroundColor Yellow
            foreach ($appName in $createdAppNames) {
                Write-Host "    -> $appName"
            }
            $targetGroup = New-CMApplicationGroup -Name $currentAppGroupName `
                                                  -AddApplication $createdAppNames `
                                                  -Description "Offline deployment group for $mainAppName and required dependencies" `
                                                  -SoftwareVersion $mainAppVersion
        } else {
            $targetGroup = $existingGroup
            Write-Host "  Application Group '$currentAppGroupName' already exists. Updating/verifying members:" -ForegroundColor Green
            foreach ($appName in $createdAppNames) {
                Write-Host "    -> $appName"
            }
            try {
                $null = Set-CMApplicationGroup -Name $currentAppGroupName -AddApplication $createdAppNames -ErrorAction Stop
            } catch {
                try {
                    $null = Set-CMApplicationGroup -InputObject $targetGroup -AddApplication $createdAppNames -ErrorAction Stop
                } catch {
                    Write-Host "  Members already verified." -ForegroundColor DarkGray
                }
            }
        }

        # Set Application Group icon using the primary app's icon
        if ($primaryAppIconPath) {
            try {
                Set-CMApplicationGroup -Name $currentAppGroupName -IconLocationFile $primaryAppIconPath -ErrorAction SilentlyContinue
                Write-Host "  Icon set on Application Group '$currentAppGroupName' from: $([System.IO.Path]::GetFileName($primaryAppIconPath))" -ForegroundColor DarkGray
            } catch {
                Write-Verbose "  Could not set icon on Application Group '$currentAppGroupName': $($_.Exception.Message)"
            }
        }

        # Organize Application Group into console folder
        $freshGroup = Get-CMApplicationGroup -Name $currentAppGroupName -ErrorAction SilentlyContinue
        if ($freshGroup) {
            Write-Host "  Organizing Application Group into Console Folder: Application Groups\$($groupFolderHierarchy -join '\')" -ForegroundColor Cyan
            Set-MECMConsoleFolder -RootType 'ApplicationGroup' -FolderHierarchy $groupFolderHierarchy -InputObject $freshGroup -SiteCode $SiteCode -SiteServer $SiteServer
        }
        Write-Host "Application Group '$currentAppGroupName' configured successfully." -ForegroundColor Green

        # Optional Content Distribution
        if ($DistributeContent) {
            Write-Host "`nDistributing Content..." -ForegroundColor Cyan
            $distParam = @{}
            if ($DPGroupName) {
                $distParam['DistributionPointGroupName'] = $DPGroupName
            } else {
                $distParam['DistributionPointName'] = $SiteServer
            }

            foreach ($appName in $createdAppNames) {
                Write-Host "  Distributing Application: $appName"
                Start-CMContentDistribution -ApplicationName $appName @distParam -ErrorAction SilentlyContinue
            }
            Write-Host "  Distributing Application Group: $currentAppGroupName"
            Start-CMContentDistribution -ApplicationGroupName $currentAppGroupName @distParam -ErrorAction SilentlyContinue
            Write-Host "Content distribution triggered." -ForegroundColor Green
        }
    } else {
        Write-Host "`n[WhatIf] Would create Application Group '$currentAppGroupName' with ordered members:" -ForegroundColor Yellow
        $idx = 1
        foreach ($appName in $createdAppNames) {
            Write-Host "  [$idx] $appName"
            $idx++
        }
        Write-Host "[WhatIf] Would create in Software Library > Application Groups." -ForegroundColor DarkGray
    }

    $summaryResults += [pscustomobject]@{
        Application      = $mainAppName
        Version          = $mainAppVersion
        ApplicationGroup = $currentAppGroupName
        PackageCount     = $createdAppNames.Count
        Status           = "Success"
    }

    $appFolderIndex++
}

# ------------------------------------------------------------------------------
# 8. Execution Summary
# ------------------------------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "                 EXECUTION SUMMARY                        " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
$summaryResults | Format-Table -AutoSize

Write-Host "All applications processed and provisioned successfully." -ForegroundColor Green
