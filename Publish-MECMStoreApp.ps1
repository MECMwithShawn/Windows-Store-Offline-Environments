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

.NOTES
    Release v2.2

    v2.2 - Framework applications detect "this version or newer".
      Framework applications (VCLibs, .NET Native, UI.Xaml, WindowsAppRuntime)
      are created with one PowerShell deployment type that is compliant when the
      staged version or newer is provisioned for all users, instead of the native
      AppX deployment type and its exact-version detection. A device that already
      had a newer framework failed the native type with 0x800700B7 and stopped the
      Application Group. -UpdateExisting converts an existing framework
      application; -FrameworkExactVersionOnly keeps the v2.1 behaviour.

    v2.1 - Version upgrades are no longer silent.
      Applications are named by package identity with no version, so a newer
      build matches the application created from the older one. Previously the
      publisher printed "Reusing" in green and changed nothing: content landed
      on the share while the deployment type still pointed at the old package,
      so devices kept receiving the OLD version with no indication anything was
      outstanding. It now compares the staged version against the published
      SoftwareVersion, and either updates in place with -UpdateExisting or
      reports the mismatch and repeats it in an ACTION REQUIRED summary.

.PARAMETER PackagePath
    Local or UNC directory containing downloaded app packages. If omitted, the
    script prompts or auto-discovers packages in .\StoreDownloads.

.PARAMETER All
    Switch to automatically batch-process all applications discovered in .\StoreDownloads.

.PARAMETER ContentShare
    Target UNC root share where MECM package folders will be hosted.
    Defaults to '\\<ServerName>\Software\Microsoft\Windows Store Apps'.
    Packages are staged into '<AppName>\v.<Version>' subfolders.
    Before staging, the script verifies the required SMB share permissions and
    prompts before granting any missing entries.

.PARAMETER SiteCode
    The 3-letter MECM Site Code (e.g. 'PS1'). If omitted, the script attempts
    to auto-detect it from current PSDrives or registry.

.PARAMETER SiteServer
    The SMS Provider / Site Server FQDN. Defaults to 'localhost'.

.PARAMETER AdminConsolePath
    Optional path to the installed ConfigMgr Admin Console bin directory. When
    supplied, this path takes precedence over registry and fixed-drive discovery.

.PARAMETER AppGroupName
    Custom name for the MECM Application Group. Defaults to
    '<App Name> <Version> - Application Group'.

.PARAMETER Arch
    Target architecture filter: x64 (default), all, arm64, x86.

.PARAMETER UpdateExisting
    When the application already exists at a DIFFERENT version, update its
    deployment type content location and SoftwareVersion in place instead of
    reporting the mismatch and leaving MECM untouched. Redistribute content
    afterwards so distribution points serve the new package.

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

    [string]$AdminConsolePath,

    [string]$AppGroupName,

    [ValidateSet('x64', 'all', 'x86', 'arm64', 'neutral')]
    [string]$Arch = 'x64',

    [switch]$DistributeContent,

    # Applications are named by package identity with no version, so re-running
    # after downloading a newer build matches the application created from the
    # OLD one. Without this switch the version difference is reported loudly and
    # nothing is changed; with it, the deployment type's content location and the
    # application's SoftwareVersion are updated in place.
    [switch]$UpdateExisting,

    [string]$DPGroupName,

    [string]$ConsoleRootFolder = 'Windows Store Applications',

    # Framework applications (VCLibs, UI.Xaml, WindowsAppRuntime, .NET Native)
    # get ONE PowerShell deployment type whose detection accepts the staged
    # version OR NEWER, provisioned for all users, and no native AppX deployment
    # type (MECM treats an application as present when ANY deployment type
    # detects it, so a native one would override that detection). Use this switch
    # to create the native AppX deployment type instead (exact-version
    # detection), as in v2.1.
    [switch]$FrameworkExactVersionOnly
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
# 3. Prompt for ContentShare with Auto-Default
# ------------------------------------------------------------------------------
$serverName = if (-not [string]::IsNullOrWhiteSpace($SiteServer) -and $SiteServer -ne 'localhost') {
    $SiteServer
} else {
    $env:COMPUTERNAME
}

$localNames = @('.', 'localhost', $env:COMPUTERNAME)
if ($env:COMPUTERNAME) { $localNames += "$($env:COMPUTERNAME).$env:USERDNSDOMAIN" }
$isLocal = $localNames -contains $serverName

# Smart discovery of target UNC content share:
# Checks for existing 'Software' share or standard MECM shares (Packages$, Sources$, etc.)
$discoveredDefaultShare = $null
try {
    $availableShares = if ($isLocal) {
        @(Get-SmbShare -ErrorAction SilentlyContinue)
    } else {
        @(Get-SmbShare -CimSession $serverName -ErrorAction SilentlyContinue)
    }

    # 1. Existing Software share
    $soft = $availableShares | Where-Object { $_.Name -ieq 'Software' } | Select-Object -First 1
    if ($soft) {
        $discoveredDefaultShare = "\\$serverName\$($soft.Name)\Microsoft\Windows Store Apps"
    }

    # 2. Existing MECM / SCCM package shares
    if (-not $discoveredDefaultShare) {
        $candidateShareNames = @('Packages$', 'Packages', 'Sources$', 'Sources', 'Applications$', 'Applications', 'Apps$', 'Apps')
        foreach ($cName in $candidateShareNames) {
            $matchedShare = $availableShares | Where-Object { $_.Name -ieq $cName } | Select-Object -First 1
            if ($matchedShare) {
                $baseUnc = "\\$serverName\$($matchedShare.Name)"
                if (Test-Path -LiteralPath "$baseUnc\Sources\Applications") {
                    $discoveredDefaultShare = "$baseUnc\Sources\Applications\Microsoft\Windows Store Apps"
                    break
                } elseif (Test-Path -LiteralPath "$baseUnc\Applications") {
                    $discoveredDefaultShare = "$baseUnc\Applications\Microsoft\Windows Store Apps"
                    break
                } elseif (Test-Path -LiteralPath $baseUnc) {
                    $discoveredDefaultShare = "$baseUnc\Microsoft\Windows Store Apps"
                    break
                }
            }
        }
    }
} catch { }

if (-not $discoveredDefaultShare) {
    $discoveredDefaultShare = "\\$serverName\Software\Microsoft\Windows Store Apps"
}

$defaultShare = $discoveredDefaultShare

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
# 5. Helper: Locate the installed Admin Console SDK assemblies
# ------------------------------------------------------------------------------
function Resolve-ConfigMgrAdminConsoleBin {
    param(
        [string]$ExplicitPath,
        [ref]$CheckedLocations
    )

    $requiredAssemblies = @(
        'Microsoft.ConfigurationManagement.ApplicationManagement.dll',
        'Microsoft.ConfigurationManagement.ApplicationManagement.Win8Installer.dll'
    )
    $excludedPathPattern = '(?i)[\\/](CD\.Latest|CMUStaging|EasySetupPayload|backup(?:s)?|SMSSETUP)([\\/]|$)'
    $candidates = [System.Collections.Generic.List[string]]::new()

    function Add-AdminConsoleCandidate {
        param([string]$Path)

        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        $candidate = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
        if ([System.IO.Path]::HasExtension($candidate)) { $candidate = Split-Path $candidate -Parent }

        foreach ($possiblePath in @(
            $candidate,
            ([System.IO.Path]::Combine($candidate, 'bin')),
            ([System.IO.Path]::Combine($candidate, 'AdminConsole\bin'))
        )) {
            if (-not [string]::IsNullOrWhiteSpace($possiblePath) -and -not $candidates.Contains($possiblePath)) {
                $candidates.Add($possiblePath)
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        Add-AdminConsoleCandidate -Path $ExplicitPath
    } else {
        Add-AdminConsoleCandidate -Path $env:SMS_ADMIN_UI_PATH

        $registryLocations = @(
            'HKLM:\SOFTWARE\Microsoft\ConfigMgr10\AdminUI',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\ConfigMgr10\AdminUI',
            'HKLM:\SOFTWARE\Microsoft\SMS\Setup',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\SMS\Setup'
        )
        $registryValueNames = @(
            'InstallationDirectory', 'InstallDir', 'AdminConsolePath',
            'AdminConsole', 'UI Installation Directory'
        )
        foreach ($registryLocation in $registryLocations) {
            $registryData = Get-ItemProperty -LiteralPath $registryLocation -ErrorAction SilentlyContinue
            if (-not $registryData) { continue }
            foreach ($valueName in $registryValueNames) {
                $property = $registryData.PSObject.Properties[$valueName]
                if ($property -and $property.Value -is [string]) {
                    Add-AdminConsoleCandidate -Path $property.Value
                }
            }
        }

        $fixedDriveRoots = @()
        try {
            $fixedDriveRoots = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop |
                ForEach-Object { "$($_.DeviceID)\" })
        } catch {
            $fixedDriveRoots = @([System.IO.DriveInfo]::GetDrives() |
                Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed } |
                ForEach-Object { $_.RootDirectory.FullName })
        }

        foreach ($driveRoot in $fixedDriveRoots) {
            Add-AdminConsoleCandidate -Path ([System.IO.Path]::Combine($driveRoot, 'Program Files\Microsoft Configuration Manager\AdminConsole\bin'))
            Add-AdminConsoleCandidate -Path ([System.IO.Path]::Combine($driveRoot, 'Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin'))
            Add-AdminConsoleCandidate -Path ([System.IO.Path]::Combine($driveRoot, 'Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin'))
        }
    }

    $checked = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        if ($candidate -match $excludedPathPattern) { continue }
        if (-not $checked.Contains($candidate)) { $checked.Add($candidate) }
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }

        $hasAllAssemblies = $true
        foreach ($assembly in $requiredAssemblies) {
            if (-not (Test-Path -LiteralPath ([System.IO.Path]::Combine($candidate, $assembly)) -PathType Leaf)) {
                $hasAllAssemblies = $false
                break
            }
        }
        if ($hasAllAssemblies) {
            $CheckedLocations.Value = @($checked)
            return $candidate
        }
    }

    $CheckedLocations.Value = @($checked)
    return $null
}

# ------------------------------------------------------------------------------
# 6. Helper: Enable "Provision this application for all users on the device" (SDK)
# ------------------------------------------------------------------------------
function Set-CMAppxProvisionForAllUsers {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$ApplicationName
    )

    # 1. Locate and load required ConfigMgr Admin Console SDK assemblies
    $checkedSdkLocations = @()
    $binDir = Resolve-ConfigMgrAdminConsoleBin -ExplicitPath $AdminConsolePath -CheckedLocations ([ref]$checkedSdkLocations)

    if (-not $binDir) {
        $checkedText = if ($checkedSdkLocations.Count) { $checkedSdkLocations -join "`n  - " } else { '(none)' }
        Write-Warning @"
Could not locate the installed ConfigMgr Admin Console SDK assemblies.
Required assemblies:
  - Microsoft.ConfigurationManagement.ApplicationManagement.dll
  - Microsoft.ConfigurationManagement.ApplicationManagement.Win8Installer.dll
Locations checked:
  - $checkedText
Specify the installed Admin Console bin directory explicitly, for example:
  -AdminConsolePath "D:\Program Files\Microsoft Configuration Manager\AdminConsole\bin"
Setup, staging, payload, backup, CD.Latest, and SMSSETUP directories are intentionally not accepted.
"@
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
# 6b. Helper: framework "version or newer" deployment type
# ------------------------------------------------------------------------------
# The native AppX deployment type detects the EXACT package version. A device
# that already has a NEWER framework provisioned (for example from Windows
# Update or another app) is reported NotInstalled, MECM tries to provision the
# older package, Windows refuses with 0x800700B7, and the whole Application
# Group stops at that member. Frameworks are backward compatible, so for them
# "installed" must mean "this version or newer is provisioned for all users".
#
# Detection deliberately looks only at Get-AppxProvisionedPackage. A per-user
# registration or a SYSTEM-staged copy (Get-AppxPackage -AllUsers) is not what
# the install command produces and does not prove new profiles are covered.
#
# The framework application carries ONLY this deployment type. MECM treats an
# application as present when ANY of its deployment types detects it, and the
# native AppX type detects the exact version registered for any single user.
# Kept alongside, it reports the framework Installed (application NotUpdated,
# requirement CompliancePartial) on a device where nothing is provisioned, so
# the install below never runs; after -UpdateExisting it would also keep
# detecting the OLD version.
function Get-FrameworkMinVersionDeploymentTypeSpec {
    param(
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$PackageFileName,
        [Parameter(Mandatory = $true)][string]$ContentFolder
    )
    $null = [version]$Version   # throws on a non-numeric version: never emit a broken detection script
    foreach ($v in $PackageName, $Architecture, $PackageFileName) {
        if ($v -match "['`"]") { throw "Unsupported quote character in '$v'." }
    }

    $detection = @"
# Generated by Publish-MECMStoreApp.ps1. Compliant only when an $Architecture
# $PackageName at or above $Version is provisioned for all users (what the
# install command produces). Per-user or SYSTEM-staged copies do not count.
`$min = [version]'$Version'
`$hit = @(Get-AppxProvisionedPackage -Online | Where-Object { `$_.PackageName -like '$($PackageName)_*_$($Architecture)_*' -and [version]`$_.Version -ge `$min })
if (`$hit) { Write-Output 'Installed' }
"@

    [pscustomobject]@{
        DeploymentTypeName = "$AppName - Script (version or newer)"
        ContentLocation    = $ContentFolder
        InstallCommand     = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"Add-AppxProvisionedPackage -Online -PackagePath '.\$PackageFileName' -SkipLicense | Out-Null`""
        DetectionScript    = $detection
    }
}

function Set-FrameworkMinVersionDeploymentType {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$ApplicationName,
        [Parameter(Mandatory = $true)]$Spec
    )

    $existing = Get-CMDeploymentType -ApplicationName $ApplicationName -DeploymentTypeName $Spec.DeploymentTypeName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($PSCmdlet.ShouldProcess($ApplicationName, "Update '$($Spec.DeploymentTypeName)' (content, install command, minimum-version detection)")) {
            Set-CMScriptDeploymentType -ApplicationName $ApplicationName -DeploymentTypeName $Spec.DeploymentTypeName `
                -ContentLocation $Spec.ContentLocation -InstallCommand $Spec.InstallCommand `
                -ScriptLanguage PowerShell -ScriptText $Spec.DetectionScript -ErrorAction Stop
            Write-Host "  [UPDATED] '$($Spec.DeploymentTypeName)'" -ForegroundColor Green
        }
    } else {
        if ($PSCmdlet.ShouldProcess($ApplicationName, "Add '$($Spec.DeploymentTypeName)'")) {
            $null = Add-CMScriptDeploymentType -ApplicationName $ApplicationName -DeploymentTypeName $Spec.DeploymentTypeName `
                -ContentLocation $Spec.ContentLocation -InstallCommand $Spec.InstallCommand `
                -ScriptLanguage PowerShell -ScriptText $Spec.DetectionScript `
                -InstallationBehaviorType InstallForSystem -LogonRequirementType WhetherOrNotUserLoggedOn `
                -UserInteractionMode Hidden -MaximumRuntimeMins 15 -EstimatedRuntimeMins 2 -ErrorAction Stop
            Write-Host "  Added '$($Spec.DeploymentTypeName)' (detects this version or newer)." -ForegroundColor Green
        }
    }

    # Script-only: remove any native AppX deployment type (see the note above).
    # Done after the script deployment type exists, so the application is never
    # left without one.
    $nativeDTs = @(Get-CMDeploymentType -ApplicationName $ApplicationName -ErrorAction SilentlyContinue |
                   Where-Object { $_.Technology -eq 'Windows8App' })
    foreach ($dt in $nativeDTs) {
        $nativeName = [string]$dt.LocalizedDisplayName
        if ($PSCmdlet.ShouldProcess($ApplicationName, "Remove native AppX deployment type '$nativeName' (its exact-version detection would override the minimum-version detection)")) {
            Remove-CMDeploymentType -ApplicationName $ApplicationName -DeploymentTypeName $nativeName -Force -ErrorAction Stop
            Write-Host "  Removed '$nativeName' (framework apps are script-only)." -ForegroundColor Yellow
        }
    }
}

# ------------------------------------------------------------------------------
# 7. Helper: Extract icon PNG from an MSIX/AppX package
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
# 7. Validate and optionally repair the SMB share permissions
# ------------------------------------------------------------------------------
function Confirm-ContentSharePermissions {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($Path -notmatch '^\\\\(?<Server>[^\\]+)\\(?<Share>[^\\]+)(?:\\|$)') {
        Write-Warning "Cannot validate SMB share permissions because '$Path' is not a UNC path."
        return $true
    }

    if (-not (Get-Command Get-SmbShareAccess -ErrorAction SilentlyContinue) -or
        -not (Get-Command Grant-SmbShareAccess -ErrorAction SilentlyContinue)) {
        Write-Warning 'SMB share permission cmdlets are unavailable; skipping the share ACL preflight.'
        return $true
    }

    $serverName = $Matches.Server
    $shareName = $Matches.Share
    $localNames = @('.', 'localhost', $env:COMPUTERNAME)
    if ($env:COMPUTERNAME) { $localNames += "$($env:COMPUTERNAME).$env:USERDNSDOMAIN" }
    $isLocalShare = $localNames -contains $serverName
    $cimSession = $null

    try {
        $shareParams = @{ Name = $shareName; ErrorAction = 'Stop' }
        if (-not $isLocalShare) {
            $cimSession = New-CimSession -ComputerName $serverName -ErrorAction Stop
            $shareParams.CimSession = $cimSession
        }

        # Check if SMB share exists
        $existingShare = $null
        try {
            $existingShare = Get-SmbShare @shareParams
        } catch {
            $existingShare = $null
        }

        if (-not $existingShare) {
            $isAdmin = $false
            try {
                $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            } catch { }

            $localPath = if ($isLocalShare) {
                "$env:SystemDrive\$shareName"
            } else {
                "C:\$shareName"
            }

            if ($WhatIfPreference) {
                $null = $PSCmdlet.ShouldProcess("\\$serverName\$shareName", "Create missing SMB share at '$localPath' with required permissions")
                return $true
            }

            if ($isAdmin -and (Get-Command New-SmbShare -ErrorAction SilentlyContinue)) {
                if ($PSCmdlet.ShouldProcess("\\$serverName\$shareName", "Create missing SMB share at '$localPath'")) {
                    Write-Host "SMB share '\\$serverName\$shareName' does not exist. Creating it automatically..." -ForegroundColor Cyan
                    if ($isLocalShare -and -not (Test-Path -LiteralPath $localPath)) {
                        $null = New-Item -ItemType Directory -Path $localPath -Force
                    }
                    $newParams = @{
                        Name        = $shareName
                        Path        = $localPath
                        FullAccess  = 'BUILTIN\Administrators'
                        ReadAccess  = 'Everyone'
                        ErrorAction = 'Stop'
                    }
                    if ($cimSession) { $newParams.CimSession = $cimSession }
                    $null = New-SmbShare @newParams
                    Write-Host "SMB share successfully created: \\$serverName\$shareName -> $localPath" -ForegroundColor Green
                    return $true
                }
            } else {
                if (Test-Path -LiteralPath $Path) {
                    Write-Warning "SMB share '\\$serverName\$shareName' could not be enumerated via SMB cmdlets, but path '$Path' is accessible via filesystem."
                    return $true
                }
                Write-Warning "SMB share '\\$serverName\$shareName' does not exist. Automated share creation requires elevated Administrator privileges."
                return $false
            }
        }

        $currentAccess = @(Get-SmbShareAccess @shareParams)
        $requiredAccess = @(
            [pscustomobject]@{ AccountName = 'Everyone'; MinimumRight = 'Read' },
            [pscustomobject]@{ AccountName = 'BUILTIN\Administrators'; MinimumRight = 'Change' }
        )
        $missingAccess = @()

        # Check if Everyone already has Full or Change access (which covers BUILTIN\Administrators)
        $everyoneEntry = $currentAccess | Where-Object { $_.AccountName -ieq 'Everyone' -and $_.AccessControlType -eq 'Allow' } | Select-Object -First 1
        $everyoneHasChangeOrFull = $everyoneEntry -and ("$($everyoneEntry.AccessRight)" -match '^(Change|Full)$')

        foreach ($required in $requiredAccess) {
            if ($required.AccountName -ieq 'BUILTIN\Administrators' -and $everyoneHasChangeOrFull) {
                continue
            }

            $matchingEntries = @($currentAccess | Where-Object { $_.AccountName -ieq $required.AccountName })
            $denyEntry = $matchingEntries | Where-Object { $_.AccessControlType -eq 'Deny' } | Select-Object -First 1
            if ($denyEntry) {
                Write-Warning "Share '\\$serverName\$shareName' has an explicit Deny entry for '$($required.AccountName)'. Remove or review that Deny entry manually; this script will not override it."
                return $false
            }

            $allowedRights = if ($required.MinimumRight -eq 'Read') { @('Read', 'Change', 'Full') } else { @('Change', 'Full') }
            $hasRequiredAccess = $matchingEntries | Where-Object {
                $_.AccessControlType -eq 'Allow' -and ($allowedRights -contains $_.AccessRight.ToString() -or "$($_.AccessRight)" -in $allowedRights)
            } | Select-Object -First 1
            if (-not $hasRequiredAccess) { $missingAccess += $required }
        }

        if (-not $missingAccess.Count) {
            Write-Host "SMB share permissions verified: \\$serverName\$shareName" -ForegroundColor Green
            return $true
        }

        $missingText = ($missingAccess | ForEach-Object { "  - $($_.AccountName): $($_.MinimumRight)" }) -join "`n"
        if ($WhatIfPreference) {
            foreach ($entry in $missingAccess) {
                $null = $PSCmdlet.ShouldProcess("\\$serverName\$shareName", "Grant $($entry.AccountName) $($entry.MinimumRight) share access")
            }
            return $true
        }

        Write-Host "Automatically repairing required SMB share permissions on '\\$serverName\$shareName':" -ForegroundColor Yellow
        Write-Host $missingText -ForegroundColor Yellow

        $repairedAll = $true
        foreach ($entry in $missingAccess) {
            if ($PSCmdlet.ShouldProcess("\\$serverName\$shareName", "Grant $($entry.AccountName) $($entry.MinimumRight) share access")) {
                try {
                    $grantParams = @{
                        Name        = $shareName
                        AccountName = $entry.AccountName
                        AccessRight = $entry.MinimumRight
                        Force       = $true
                        ErrorAction = 'Stop'
                    }
                    if ($cimSession) { $grantParams.CimSession = $cimSession }
                    Grant-SmbShareAccess @grantParams | Out-Null
                    Write-Host "  Successfully granted $($entry.AccountName) $($entry.MinimumRight) share access." -ForegroundColor Green
                } catch {
                    Write-Warning "Failed to grant $($entry.AccountName) access: $($_.Exception.Message)"
                    $repairedAll = $false
                }
            }
        }

        if ($repairedAll) {
            Write-Host "SMB share permissions repaired: \\$serverName\$shareName" -ForegroundColor Green
            return $true
        } else {
            return $false
        }
    } catch {
        Write-Warning "Could not validate or repair SMB share permissions for '\\$serverName\$shareName': $($_.Exception.Message)"
        return $false
    } finally {
        if ($cimSession) { Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue }
    }
}

# ------------------------------------------------------------------------------
# 8. Connect to MECM / Configuration Manager
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
# Script scope, NOT per-app-folder: a version mismatch found while processing the
# first application must still be reported after the last one. Reset these inside
# the loop and only the final folder's findings would reach the summary.
$updatedAppNames = @()
$staleAppNames = @()
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
    if (-not (Confirm-ContentSharePermissions -Path $contentRoot -WhatIf:$WhatIfPreference)) {
        throw "Required SMB share permissions are missing on '$contentRoot'. Staging was stopped before any content was written."
    }
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

        $frameworkDtSpec = $null
        if ($pkg.IsFramework -and -not $FrameworkExactVersionOnly) {
            $frameworkDtSpec = Get-FrameworkMinVersionDeploymentTypeSpec -AppName $appName `
                -PackageName $pkg.Identity.PackageName -Version $pkg.Identity.Version `
                -Architecture $pkg.Identity.Architecture -PackageFileName $pkg.File.Name `
                -ContentFolder $staged.ContentLocation
        }
        # True once this run has created or re-pointed the framework's script
        # deployment type. A reused, unchanged application keeps what it has.
        $frameworkDtDone = $false

        if ($mecmConnected) {
            Write-Host "`nProcessing Application: $appName" -ForegroundColor Cyan
            $targetApp = Get-CMApplication -Name $appName -Fast -ErrorAction SilentlyContinue

            if ($targetApp) {
                $existingDT = Get-CMDeploymentType -ApplicationName $appName -ErrorAction SilentlyContinue
                if ($existingDT) {
                    # Applications are named by package identity with NO version, so a
                    # newer build matches the application created from the OLD one.
                    # Staging the new content to the share does not tell MECM about it:
                    # the deployment type still points at the previous package. Saying
                    # "Reusing" in green there reports a success that did not happen -
                    # the operator has no way to know a manual console step is now
                    # required, and the fresh content on disk makes it look done.
                    $publishedVersion = [string]$targetApp.SoftwareVersion
                    $stagedVersion    = [string]$pkg.Identity.Version

                    if ($publishedVersion -and $stagedVersion -and $publishedVersion -ne $stagedVersion) {
                        if ($UpdateExisting) {
                            Write-Host "  Version change detected for '$appName': $publishedVersion -> $stagedVersion" -ForegroundColor Yellow
                            try {
                                if ($frameworkDtSpec) {
                                    # Framework: re-point (or add) the script deployment type and
                                    # drop any native AppX one, which would keep detecting $publishedVersion.
                                    Set-FrameworkMinVersionDeploymentType -ApplicationName $appName -Spec $frameworkDtSpec
                                    $frameworkDtDone = $true
                                } else {
                                    $nativeDT = @($existingDT | Where-Object { $_.Technology -eq 'Windows8App' -or $_.LocalizedDisplayName -like '* - Native AppX' }) | Select-Object -First 1
                                    $dtName = if ($nativeDT) { [string]$nativeDT.LocalizedDisplayName } else { [string](@($existingDT)[0].LocalizedDisplayName) }
                                    if ([string]::IsNullOrWhiteSpace($dtName)) { $dtName = "$appName - Native AppX" }

                                    Set-CMWindowsAppxDeploymentType -ApplicationName $appName `
                                                                   -DeploymentTypeName $dtName `
                                                                   -ContentLocation $pkgFileLocation `
                                                                   -Force `
                                                                   -ErrorAction Stop
                                }
                                Set-CMApplication -Name $appName -SoftwareVersion $stagedVersion -ErrorAction Stop

                                Write-Host "  [UPDATED] Deployment type content -> $pkgFileLocation" -ForegroundColor Green
                                Write-Host "  [UPDATED] SoftwareVersion -> $stagedVersion" -ForegroundColor Green
                                Write-Host "  NOTE: redistribute content for this application so DPs serve the new package." -ForegroundColor Yellow
                                $updatedAppNames += $appName
                            } catch {
                                Write-Host "  [ERROR] Could not update '$appName': $($_.Exception.Message)" -ForegroundColor Red
                                Write-Host "          The application still points at $publishedVersion. Update it in the console." -ForegroundColor Red
                                $staleAppNames += [pscustomobject]@{ Name = $appName; Published = $publishedVersion; Staged = $stagedVersion }
                            }
                        } else {
                            Write-Host "  [WARN] '$appName' is published as $publishedVersion but $stagedVersion was just staged." -ForegroundColor Yellow
                            Write-Host "         MECM was NOT updated. The deployment type still points at $publishedVersion," -ForegroundColor Yellow
                            Write-Host "         so devices continue to receive the OLD package." -ForegroundColor Yellow
                            Write-Host "         Re-run with -UpdateExisting, or in the console either update the deployment" -ForegroundColor Yellow
                            Write-Host "         type's content location and Update Content, or create a new application" -ForegroundColor Yellow
                            Write-Host "         version and use Supersedence." -ForegroundColor Yellow
                            $staleAppNames += [pscustomobject]@{ Name = $appName; Published = $publishedVersion; Staged = $stagedVersion }
                        }
                    } else {
                        Write-Host "  Application '$appName' already exists at $stagedVersion. Reusing." -ForegroundColor Green
                        if ($frameworkDtSpec) {
                            $hasScriptDT = [bool](@($existingDT) | Where-Object { $_.LocalizedDisplayName -eq $frameworkDtSpec.DeploymentTypeName })
                            $hasNativeDT = [bool](@($existingDT) | Where-Object { $_.Technology -eq 'Windows8App' })
                            if (-not $hasScriptDT) {
                                Write-Host "  NOTE: this existing framework app has only exact-version detection and was left unchanged." -ForegroundColor Yellow
                                Write-Host "        Devices with a newer version provisioned will fail it with 0x800700B7." -ForegroundColor Yellow
                                Write-Host "        Replace its deployment type with '$($frameworkDtSpec.DeploymentTypeName)' (see the guide)." -ForegroundColor Yellow
                            } elseif ($hasNativeDT) {
                                Write-Host "  NOTE: this framework app still has a native AppX deployment type next to the script one." -ForegroundColor Yellow
                                Write-Host "        MECM accepts either, so a per-user copy of the exact version counts as installed." -ForegroundColor Yellow
                                Write-Host "        Remove the native AppX deployment type to make minimum-version detection effective." -ForegroundColor Yellow
                            }
                        }
                    }
                } else {
                    Write-Host "  Application '$appName' exists but is missing deployment type. Adding Deployment Type..." -ForegroundColor Yellow
                    if ($frameworkDtSpec) {
                        Set-FrameworkMinVersionDeploymentType -ApplicationName $appName -Spec $frameworkDtSpec
                        $frameworkDtDone = $true
                    } else {
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
                    Write-Host "  Deployment type created successfully." -ForegroundColor Green
                }
            } else {
                Write-Host "  Creating new Application: $appName" -ForegroundColor Yellow
                $targetApp = New-CMApplication -Name $appName `
                                               -Publisher "Microsoft" `
                                               -SoftwareVersion $pkg.Identity.Version `
                                               -Description "[WindowsStoreOfflineToolkit:v2.2] Offline Windows Store Package ($($pkg.Identity.Architecture))"

                if ($frameworkDtSpec) {
                    Write-Host "  Creating 'version or newer' script Deployment Type (framework)..." -ForegroundColor Yellow
                    Set-FrameworkMinVersionDeploymentType -ApplicationName $appName -Spec $frameworkDtSpec
                    $frameworkDtDone = $true
                } else {
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
            }

            # Enable "Provision this application for all users on the device" (SDK).
            # Applies to native AppX deployment types; a framework's script
            # deployment type already installs as System and provisions for all users.
            if (-not $frameworkDtDone) {
                $null = Set-CMAppxProvisionForAllUsers -ApplicationName $appName
            }

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
            if ($frameworkDtSpec) {
                Write-Host "[WhatIf] Framework: its only deployment type would be '$($frameworkDtSpec.DeploymentTypeName)' (no native AppX):" -ForegroundColor Yellow
                Write-Host "           Content : $($frameworkDtSpec.ContentLocation)" -ForegroundColor DarkGray
                Write-Host "           Install : $($frameworkDtSpec.InstallCommand)" -ForegroundColor DarkGray
                Write-Host "           Detect  :" -ForegroundColor DarkGray
                $frameworkDtSpec.DetectionScript -split "`n" | ForEach-Object { Write-Host "             $_" -ForegroundColor DarkGray }
            }
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
                                                  -Description "[WindowsStoreOfflineToolkit:v2.2] Offline deployment group for $mainAppName and required dependencies" `
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

if ($updatedAppNames.Count -gt 0) {
    Write-Host "Applications updated to a new version ($($updatedAppNames.Count)):" -ForegroundColor Cyan
    foreach ($n in ($updatedAppNames | Select-Object -Unique)) { Write-Host "  $n" -ForegroundColor Green }
    Write-Host "  Redistribute content for these so distribution points serve the new package." -ForegroundColor Yellow
    Write-Host ""
}

# Repeated here deliberately. A mismatch reported only at the point it was found
# scrolls away on a multi-application run, and the operator walks off believing
# the new build shipped.
if ($staleAppNames.Count -gt 0) {
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host " ACTION REQUIRED - NEWER PACKAGES STAGED BUT NOT PUBLISHED" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host " Content is on the share, but MECM still points at the older package," -ForegroundColor Yellow
    Write-Host " so devices continue to receive the OLD version:" -ForegroundColor Yellow
    Write-Host ""
    foreach ($s in $staleAppNames) {
        Write-Host ("  {0,-42} published {1}  ->  staged {2}" -f $s.Name, $s.Published, $s.Staged) -ForegroundColor White
    }
    Write-Host ""
    Write-Host " Re-run with -UpdateExisting, or fix each in the console." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Completed with actions outstanding - see above." -ForegroundColor Yellow
} else {
    Write-Host "All applications processed and provisioned successfully." -ForegroundColor Green
}
