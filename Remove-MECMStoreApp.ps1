<#
.SYNOPSIS
    Cleans up and removes MECM/SCCM Store Applications, Application Groups,
    Console Folders, and staged content for testing and environment resets.

.DESCRIPTION
    This utility script automates the complete cleanup of MECM Store Application
    testing artifacts. It safely removes:
      1. MECM Application Groups (and any active group deployments)
      2. MECM Store Applications & Dependency Frameworks (and active deployments)
      3. MECM Admin Console Folders (both Application and Application Group hierarchies)
      4. Staged package files on the UNC Content Share (optional)

    Supports targeted cleanup of specific applications, interactive multi-select,
    or complete environment wipe with -All.

.PARAMETER AppName
    One or more application names or patterns to remove (e.g. 'Microsoft.WindowsNotepad', 'Microsoft.WindowsTerminal').
    If omitted and -All is not specified, an interactive menu is displayed.

.PARAMETER FrameworkName
    One or more framework names or patterns to remove. Shared frameworks are
    blocked unless -RemoveSharedFrameworks is also specified.

.PARAMETER All
    Removes all Microsoft Store applications, framework dependencies, application groups,
    and associated console folders created in MECM.

.PARAMETER IncludeFrameworks
    Switch to also delete shared framework dependencies (Microsoft.VCLibs, Microsoft.UI.Xaml,
    Microsoft.WindowsAppRuntime). Automatically enabled with -All. Frameworks still in use are excluded.

.PARAMETER RemoveSharedFrameworks
    Allows removal of a selected framework even when another non-selected MECM
    application or Application Group references it. Use only after reviewing the warning.

.PARAMETER RemoveStagedContent
    Switch to also delete the staged package folders from the UNC Content Share.

.PARAMETER ContentShare
    UNC root share path where packages were staged.
    Defaults to '\\<ServerName>\Software\Microsoft\Windows Store Apps'.

.PARAMETER SiteCode
    The 3-letter MECM Site Code (e.g. 'CHQ'). Auto-detected if omitted.

.PARAMETER SiteServer
    The SMS Provider / Site Server hostname or FQDN. Defaults to 'localhost'.

.PARAMETER KeepFolders
    Switch to preserve console folder structures while removing applications and groups.

.PARAMETER Force
    Bypasses confirmation prompts before deleting objects.

.PARAMETER WhatIf
    Previews actions without making changes in MECM or the file system.

.EXAMPLE
    # Interactive menu:
    .\Remove-MECMStoreApp.ps1

.EXAMPLE
    # Remove a single application and its group:
    .\Remove-MECMStoreApp.ps1 -AppName "Microsoft.WindowsNotepad" -Force

.EXAMPLE
    # Complete cleanup of all Store apps, groups, folders, and staged content:
    .\Remove-MECMStoreApp.ps1 -All -RemoveStagedContent -Force

.EXAMPLE
    # Preview removal of all Store apps without deleting:
    .\Remove-MECMStoreApp.ps1 -All -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0, ValueFromPipeline = $true)]
    [string[]]$AppName,

    [string[]]$FrameworkName,

    [switch]$All,

    [switch]$IncludeFrameworks,

    [switch]$RemoveSharedFrameworks,

    [switch]$RemoveStagedContent,

    [string]$ContentShare,

    [string]$SiteCode,

    [string]$SiteServer = 'localhost',

    [switch]$KeepFolders,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

Write-Host "==========================================================" -ForegroundColor Red
Write-Host "     MECM Store App & Group Testing Cleanup Utility       " -ForegroundColor Red
Write-Host "==========================================================" -ForegroundColor Red

# ------------------------------------------------------------------------------
# 1. Connect to MECM / Configuration Manager
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
            Write-Host "Importing ConfigurationManager module from: $modulePath" -ForegroundColor Cyan
            Import-Module $modulePath -Force
        } else {
            throw "ConfigurationManager PowerShell module not found. Run on a machine with MECM Admin Console installed."
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
            $enteredSite = Read-Host "Enter MECM Site Code (e.g. CHQ)"
            if (-not [string]::IsNullOrWhiteSpace($enteredSite)) {
                $SiteCode = $enteredSite.Trim()
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($SiteCode)) {
        throw "Could not determine MECM Site Code. Specify -SiteCode (e.g. -SiteCode 'CHQ')."
    }

    if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        $server = if ($SiteServer) { $SiteServer } else { 'localhost' }
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $server -Description "MECM Site Drive" -Scope Global -ErrorAction Stop | Out-Null
    }

    Set-Location "$($SiteCode):" -ErrorAction Stop
    Write-Host "Connected to MECM Site: $SiteCode" -ForegroundColor Green
    return $SiteCode
}

# Connect
$connectedSite = Connect-MECM -SiteCode $SiteCode -SiteServer $SiteServer
$wmiNamespace = "root\sms\site_$connectedSite"

# ------------------------------------------------------------------------------
# 2. Discover Existing Store Applications & Groups
# ------------------------------------------------------------------------------
Write-Host "`nScanning MECM for Store Applications and Application Groups..." -ForegroundColor Cyan

$allGroups = @(Get-CMApplicationGroup -ErrorAction SilentlyContinue)
$allApps = @(Get-CMApplication -ErrorAction SilentlyContinue)

$frameworkKeywords = @('VCLibs', 'UI.Xaml', 'NET.Native', 'WindowsAppRuntime', 'WinAppRuntime')
$toolkitMarkerPattern = '^\[WindowsStoreOfflineToolkit:v\d+\]\s+'

function Get-CMObjectDescription {
    param([object]$InputObject)

    foreach ($propertyName in 'LocalizedDescription', 'Description') {
        $property = $InputObject.PSObject.Properties[$propertyName]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    return ''
}

function Test-ToolkitOwnedApplication {
    param([object]$Application)

    $description = Get-CMObjectDescription -InputObject $Application
    return ($description -match $toolkitMarkerPattern -or
        $description -match '^Offline Windows Store Package \([^)]+\)$')
}

function Test-ToolkitOwnedApplicationGroup {
    param([object]$ApplicationGroup)

    $description = Get-CMObjectDescription -InputObject $ApplicationGroup
    return ($description -match $toolkitMarkerPattern -or
        $description -match '^Offline deployment group for .+ and required dependencies$')
}

function Test-CMObjectReferencesApplication {
    param(
        [object]$InputObject,
        [object]$Application
    )

    $xmlProperty = $InputObject.PSObject.Properties['SDMPackageXML']
    if (-not $xmlProperty -or [string]::IsNullOrWhiteSpace([string]$xmlProperty.Value)) { return $false }

    foreach ($identifier in @($Application.ModelName, $Application.CI_UniqueID)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$identifier) -and
            [string]$xmlProperty.Value -match [regex]::Escape([string]$identifier)) {
            return $true
        }
    }
    return $false
}

function Get-FrameworkConsumers {
    param(
        [object]$Framework,
        [object[]]$Applications,
        [object[]]$ApplicationGroups,
        [object[]]$SelectedApplications,
        [object[]]$SelectedApplicationGroups
    )

    $consumers = @()
    foreach ($application in $Applications) {
        if ($application -eq $Framework -or $SelectedApplications -contains $application) { continue }
        if (Test-CMObjectReferencesApplication -InputObject $application -Application $Framework) {
            $consumers += "Application: $($application.LocalizedDisplayName)"
        }
    }
    foreach ($group in $ApplicationGroups) {
        if ($SelectedApplicationGroups -contains $group) { continue }
        if (Test-CMObjectReferencesApplication -InputObject $group -Application $Framework) {
            $consumers += "Application Group: $($group.LocalizedDisplayName)"
        }
    }
    return @($consumers | Select-Object -Unique)
}

function Get-AssociatedFrameworks {
    param(
        [object[]]$Frameworks,
        [object[]]$Applications,
        [object[]]$ApplicationGroups
    )

    $associated = @()
    foreach ($framework in $Frameworks) {
        $isAssociated = $false
        foreach ($application in $Applications) {
            if (Test-CMObjectReferencesApplication -InputObject $application -Application $framework) {
                $isAssociated = $true
                break
            }
        }
        if (-not $isAssociated) {
            foreach ($group in $ApplicationGroups) {
                if (Test-CMObjectReferencesApplication -InputObject $group -Application $framework) {
                    $isAssociated = $true
                    break
                }
            }
        }
        if ($isAssociated) { $associated += $framework }
    }
    return @($associated | Select-Object -Unique)
}

$discoveredGroups = @($allGroups | Where-Object { Test-ToolkitOwnedApplicationGroup -ApplicationGroup $_ })

# Classify only applications created by this toolkit
$discoveredStoreApps = @()
$discoveredFrameworks = @()

foreach ($a in $allApps) {
    if (-not (Test-ToolkitOwnedApplication -Application $a)) { continue }

    $name = $a.LocalizedDisplayName
    $isFw = $false
    foreach ($kw in $frameworkKeywords) {
        if ($name -match "(?i)$kw") { $isFw = $true; break }
    }

    if ($isFw) {
        $discoveredFrameworks += $a
    } else {
        $discoveredStoreApps += $a
    }
}

# ------------------------------------------------------------------------------
# 3. Interactive Selection (if AppName not specified and not -All)
# ------------------------------------------------------------------------------
$selectedAppsToRemove = @()
$selectedGroupsToRemove = @()
$removeAllDiscovered = $All.IsPresent

if (-not $All -and (-not $AppName -or $AppName.Count -eq 0) -and
    (-not $FrameworkName -or $FrameworkName.Count -eq 0)) {
    if ($discoveredStoreApps.Count -eq 0 -and $discoveredGroups.Count -eq 0 -and $discoveredFrameworks.Count -eq 0) {
        Write-Host "No Store Applications or Application Groups found in MECM." -ForegroundColor Yellow
        if ($KeepFolders) {
            # Nothing at all to do
            return
        }
        Write-Host "Proceeding to console folder cleanup..." -ForegroundColor Cyan
        # Skip interactive menu — no apps to select; fall through to folder cleanup below
    } else {
        Write-Host "`nDiscovered MECM Store Items:" -ForegroundColor Yellow
        Write-Host "--- Application Groups ---" -ForegroundColor Cyan
        for ($i = 0; $i -lt $discoveredGroups.Count; $i++) {
            Write-Host ("  [G{0}] Group: {1}" -f ($i + 1), $discoveredGroups[$i].LocalizedDisplayName)
        }

        Write-Host "--- Store Applications ---" -ForegroundColor Cyan
        for ($i = 0; $i -lt $discoveredStoreApps.Count; $i++) {
            Write-Host ("  [A{0}] App  : {1}" -f ($i + 1), $discoveredStoreApps[$i].LocalizedDisplayName)
        }

        if ($discoveredFrameworks.Count -gt 0) {
            Write-Host ("--- Framework Dependencies ({0} found) ---" -f $discoveredFrameworks.Count) -ForegroundColor DarkGray
            for ($i = 0; $i -lt $discoveredFrameworks.Count; $i++) {
                Write-Host ("  [FW{0}] FW   : {1}" -f ($i + 1), $discoveredFrameworks[$i].LocalizedDisplayName) -ForegroundColor DarkGray
            }
        }

        Write-Host "`nCleanup Options:" -ForegroundColor Yellow
        Write-Host "  [A] ALL Store Applications, Groups, Folders, and Frameworks" -ForegroundColor Red
        Write-Host "  [G] All Application Groups ONLY" -ForegroundColor Yellow
        Write-Host "  [F] Clean Empty Console Folders ONLY" -ForegroundColor Green
        Write-Host "  [1..N] Enter specific items (e.g. 'A1, FW1, G1' or app names)"

        $choice = Read-Host "`nEnter selection [A]"
        $trimmed = $choice.Trim()

        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -match '^(a|all)$') {
            $selectedAppsToRemove = $discoveredStoreApps
            $selectedGroupsToRemove = $discoveredGroups
            $removeAllDiscovered = $true
        } elseif ($trimmed -match '^(g|groups)$') {
            $selectedGroupsToRemove = $discoveredGroups
        } elseif ($trimmed -match '^(f|folders)$') {
            # Folder cleanup only — nothing to add to selected lists
        } else {
            $parts = $trimmed -split '[,\s]+'
            foreach ($p in $parts) {
                if ($p -match '^fw(\d+)$') {
                    $idx = [int]$Matches[1] - 1
                    if ($idx -ge 0 -and $idx -lt $discoveredFrameworks.Count) {
                        $selectedAppsToRemove += $discoveredFrameworks[$idx]
                    }
                } elseif ($p -match '^g(\d+)$') {
                    $idx = [int]$Matches[1] - 1
                    if ($idx -ge 0 -and $idx -lt $discoveredGroups.Count) {
                        $selectedGroupsToRemove += $discoveredGroups[$idx]
                    }
                } elseif ($p -match '^a(\d+)$') {
                    $idx = [int]$Matches[1] - 1
                    if ($idx -ge 0 -and $idx -lt $discoveredStoreApps.Count) {
                        $selectedAppsToRemove += $discoveredStoreApps[$idx]
                    }
                } else {
                    # Match by string name
                    $matchedApp = $discoveredStoreApps | Where-Object { $_.LocalizedDisplayName -like "*$p*" }
                    if ($matchedApp) { $selectedAppsToRemove += $matchedApp }
                    $matchedGrp = $discoveredGroups | Where-Object { $_.LocalizedDisplayName -like "*$p*" }
                    if ($matchedGrp) { $selectedGroupsToRemove += $matchedGrp }
                }
            }
        }
    } # end else (apps/groups were found — interactive menu complete)
} elseif ($All) {
    $selectedAppsToRemove = $discoveredStoreApps
    $selectedGroupsToRemove = $discoveredGroups
} else {
    # Explicit app/framework patterns specified
    foreach ($pattern in $AppName) {
        $matchedApps = $discoveredStoreApps | Where-Object { $_.LocalizedDisplayName -like "*$pattern*" }
        $selectedAppsToRemove += $matchedApps
    }
    foreach ($pattern in $FrameworkName) {
        $matchedFrameworks = $discoveredFrameworks | Where-Object { $_.LocalizedDisplayName -like "*$pattern*" }
        $selectedAppsToRemove += $matchedFrameworks
    }
}

# De-duplicate
$selectedAppsToRemove = @($selectedAppsToRemove | Select-Object -Unique)
$selectedGroupsToRemove = @($selectedGroupsToRemove | Select-Object -Unique)

# Also automatically add owned groups that contain selected main apps to prevent
# foreign key errors. Framework-only selection must not auto-select its consumers.
foreach ($appObj in @($selectedAppsToRemove | Where-Object { $discoveredFrameworks -notcontains $_ })) {
    foreach ($grp in $discoveredGroups) {
        if ($selectedGroupsToRemove -notcontains $grp) {
            # Check if group references this app
            $grpFull = Get-CMApplicationGroup -Name $grp.LocalizedDisplayName -ErrorAction SilentlyContinue
            if ($grpFull -and $grpFull.SDMPackageXML -match [regex]::Escape($appObj.ModelName)) {
                $selectedGroupsToRemove += $grp
            }
        }
    }
}
$selectedGroupsToRemove = @($selectedGroupsToRemove | Select-Object -Unique)

# Resolve dependency frameworks associated with the selected apps and groups.
$selectedMainApps = @($selectedAppsToRemove | Where-Object { $discoveredFrameworks -notcontains $_ })
$associatedFrameworks = @(Get-AssociatedFrameworks -Frameworks $discoveredFrameworks `
    -Applications $selectedMainApps -ApplicationGroups $selectedGroupsToRemove)

if ($associatedFrameworks.Count) {
    Write-Host "`nAssociated Frameworks:" -ForegroundColor Cyan
    foreach ($framework in $associatedFrameworks) {
        $consumers = @(Get-FrameworkConsumers -Framework $framework `
            -Applications $allApps -ApplicationGroups $allGroups `
            -SelectedApplications $selectedAppsToRemove -SelectedApplicationGroups $selectedGroupsToRemove)
        if ($consumers.Count) {
            Write-Host "  [SHARED] $($framework.LocalizedDisplayName)" -ForegroundColor Red
            foreach ($consumer in $consumers) { Write-Host "           $consumer" -ForegroundColor Red }
        } else {
            Write-Host "  [EXCLUSIVE] $($framework.LocalizedDisplayName)" -ForegroundColor Green
        }

        if ($selectedAppsToRemove -contains $framework -or $removeAllDiscovered -or $IncludeFrameworks) { continue }
        if ($consumers.Count -and -not $RemoveSharedFrameworks) {
            Write-Warning "'$($framework.LocalizedDisplayName)' is shared and will not be offered for deletion without -RemoveSharedFrameworks."
            continue
        }
        if (-not $Force -and -not $WhatIfPreference -and -not [Console]::IsInputRedirected) {
            $frameworkChoice = Read-Host "Delete associated framework '$($framework.LocalizedDisplayName)'? (y/N)"
            if ($frameworkChoice.Trim() -match '^(?i)y(?:es)?$') {
                $selectedAppsToRemove += $framework
            }
        } else {
            Write-Host "  Not selected. Use -IncludeFrameworks or -FrameworkName to include it." -ForegroundColor DarkGray
        }
    }
} else {
    Write-Host "`nAssociated Frameworks: None detected for the selected applications/groups." -ForegroundColor DarkGray
}

if ($removeAllDiscovered) {
    $selectedAppsToRemove = @($selectedAppsToRemove + $discoveredFrameworks | Select-Object -Unique)
} elseif ($IncludeFrameworks) {
    $selectedAppsToRemove = @($selectedAppsToRemove + $associatedFrameworks | Select-Object -Unique)
} else {
    $selectedAppsToRemove = @($selectedAppsToRemove | Select-Object -Unique)
}

# Block shared frameworks unless the operator explicitly overrides the safeguard.
$selectedFrameworks = @($selectedAppsToRemove | Where-Object { $discoveredFrameworks -contains $_ })
foreach ($framework in $selectedFrameworks) {
    $consumers = @(Get-FrameworkConsumers -Framework $framework `
        -Applications $allApps -ApplicationGroups $allGroups `
        -SelectedApplications $selectedAppsToRemove -SelectedApplicationGroups $selectedGroupsToRemove)
    if (-not $consumers.Count) { continue }

    $consumerText = ($consumers | ForEach-Object { "  - $_" }) -join "`n"
    Write-Warning "Framework '$($framework.LocalizedDisplayName)' is referenced by non-selected MECM objects:`n$consumerText"
    if (-not $RemoveSharedFrameworks) {
        Write-Warning "Framework '$($framework.LocalizedDisplayName)' was removed from the deletion list. Specify -RemoveSharedFrameworks only after confirming those consumers can tolerate its removal."
        $selectedAppsToRemove = @($selectedAppsToRemove | Where-Object { $_ -ne $framework })
    } else {
        Write-Warning "-RemoveSharedFrameworks is set; '$($framework.LocalizedDisplayName)' remains in the deletion list despite active references."
    }
}

# ------------------------------------------------------------------------------
# 4. Summary Confirmation
# ------------------------------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Yellow
Write-Host "                 ITEMS TO BE REMOVED                     " -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Yellow

if ($selectedGroupsToRemove.Count -gt 0) {
    Write-Host "Application Groups ($($selectedGroupsToRemove.Count)):" -ForegroundColor Magenta
    foreach ($g in $selectedGroupsToRemove) {
        Write-Host "  [-] $($g.LocalizedDisplayName)"
    }
} else {
    Write-Host "Application Groups: (None)" -ForegroundColor DarkGray
}

$selectedFrameworks = @($selectedAppsToRemove | Where-Object { $discoveredFrameworks -contains $_ })
$selectedMainApps = @($selectedAppsToRemove | Where-Object { $discoveredFrameworks -notcontains $_ })

if ($selectedMainApps.Count -gt 0) {
    Write-Host "`nApplications ($($selectedMainApps.Count)):" -ForegroundColor Cyan
    foreach ($a in $selectedMainApps) {
        Write-Host "  [-] $($a.LocalizedDisplayName)"
    }
} else {
    Write-Host "Applications: (None)" -ForegroundColor DarkGray
}

if ($selectedFrameworks.Count -gt 0) {
    Write-Host "`nFrameworks ($($selectedFrameworks.Count)):" -ForegroundColor DarkYellow
    foreach ($framework in $selectedFrameworks) {
        Write-Host "  [-] $($framework.LocalizedDisplayName)" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "Frameworks: (None)" -ForegroundColor DarkGray
}

if (-not $KeepFolders) {
    Write-Host "`nConsole Folders: Empty Store folders will be cleaned up." -ForegroundColor Green
}

if ($RemoveStagedContent) {
    Write-Host "Staged UNC Content: Target package folders will be deleted." -ForegroundColor Red
}

if ($selectedGroupsToRemove.Count -eq 0 -and $selectedAppsToRemove.Count -eq 0 -and $KeepFolders) {
    Write-Host "`nNo items selected for removal. Exiting." -ForegroundColor Yellow
    return
}

if (-not $Force -and -not $WhatIfPreference) {
    if ([Console]::IsInputRedirected) {
        throw 'Interactive confirmation is required before removal. Rerun interactively, use -WhatIf to preview, or specify -Force for an approved unattended removal.'
    }

    $confirm = Read-Host "`nReview every item above. Type REMOVE to delete exactly these items"
    if ($confirm.Trim() -cne 'REMOVE') {
        Write-Host "Operation cancelled by user." -ForegroundColor Yellow
        return
    }
}

# ------------------------------------------------------------------------------
# 5. STEP 1: Delete Application Groups (and active deployments)
# ------------------------------------------------------------------------------
if ($selectedGroupsToRemove.Count -gt 0) {
    Write-Host "`n[1/4] Removing Application Groups..." -ForegroundColor Magenta

    foreach ($grp in $selectedGroupsToRemove) {
        $grpName = $grp.LocalizedDisplayName
        Write-Host "  Processing Group: $grpName" -ForegroundColor Cyan

        # Remove active deployments on group
        try {
            $deployments = Get-CMApplicationGroupDeployment -Name $grpName -ErrorAction SilentlyContinue
            if ($deployments) {
                foreach ($dep in $deployments) {
                    if ($PSCmdlet.ShouldProcess($dep.AssignmentName, "Remove Application Group Deployment")) {
                        Remove-CMApplicationGroupDeployment -InputObject $dep -Force -ErrorAction SilentlyContinue
                        Write-Host "    Removed deployment: $($dep.AssignmentName)" -ForegroundColor Gray
                    }
                }
            }
        } catch { }

        # Remove Application Group
        if ($PSCmdlet.ShouldProcess($grpName, "Delete Application Group from MECM")) {
            try {
                $grpDeleted = $false
                if ($grp -and $grp.CI_ID) {
                    try {
                        Remove-CMApplicationGroup -Id ([int]$grp.CI_ID) -Force -ErrorAction Stop
                        $grpDeleted = $true
                    } catch { }
                }
                if (-not $grpDeleted) {
                    try {
                        Remove-CMApplicationGroup -InputObject $grp -Force -ErrorAction Stop
                        $grpDeleted = $true
                    } catch { }
                }
                if (-not $grpDeleted) {
                    $strGrpName = [string]$grpName
                    Remove-CMApplicationGroup -Name $strGrpName -Force -ErrorAction Stop
                    $grpDeleted = $true
                }
                Write-Host "    [DELETED] Application Group: $grpName" -ForegroundColor Green
            } catch {
                Write-Warning "    Could not delete Application Group '$grpName': $($_.Exception.Message)"
            }
        }
    }
}

# ------------------------------------------------------------------------------
# 6. STEP 2: Delete Applications (and active deployments)
# ------------------------------------------------------------------------------
if ($selectedAppsToRemove.Count -gt 0) {
    Write-Host "`n[2/4] Removing Applications..." -ForegroundColor Cyan

    # Delete main applications first, then frameworks
    $sortedApps = $selectedAppsToRemove | Sort-Object {
        if ($_.LocalizedDisplayName -match '(?i)VCLibs|CRT') { return 10 }
        if ($_.LocalizedDisplayName -match '(?i)UI\.Xaml') { return 9 }
        if ($_.LocalizedDisplayName -match '(?i)WindowsAppRuntime') { return 8 }
        return 1
    }

    foreach ($app in $sortedApps) {
        $appName = [string]$app.LocalizedDisplayName
        Write-Host "  Processing Application: $appName" -ForegroundColor Cyan

        # Remove active deployments on app
        try {
            $deployments = Get-CMApplicationDeployment -Name $appName -ErrorAction SilentlyContinue
            if ($deployments) {
                foreach ($dep in $deployments) {
                    if ($PSCmdlet.ShouldProcess($dep.AssignmentName, "Remove Application Deployment")) {
                        Remove-CMApplicationDeployment -InputObject $dep -Force -ErrorAction SilentlyContinue
                        Write-Host "    Removed deployment: $($dep.AssignmentName)" -ForegroundColor Gray
                    }
                }
            }
        } catch { }

        # Remove Application
        if ($PSCmdlet.ShouldProcess($appName, "Delete Application from MECM")) {
            try {
                $appDeleted = $false
                if ($app -and $app.CI_ID) {
                    try {
                        Remove-CMApplication -Id ([int]$app.CI_ID) -Force -ErrorAction Stop
                        $appDeleted = $true
                    } catch { }
                }
                if (-not $appDeleted) {
                    try {
                        Remove-CMApplication -InputObject $app -Force -ErrorAction Stop
                        $appDeleted = $true
                    } catch { }
                }
                if (-not $appDeleted) {
                    $strAppName = [string]$appName
                    Remove-CMApplication -Name $strAppName -Force -ErrorAction Stop
                    $appDeleted = $true
                }
                Write-Host "    [DELETED] Application: $appName" -ForegroundColor Green
            } catch {
                Write-Warning "    Could not delete Application '$appName': $($_.Exception.Message)"
            }
        }
    }
}

# Allow WMI/MECM a moment to propagate deletions before querying folder contents
if (-not $KeepFolders -and ($selectedAppsToRemove.Count -gt 0 -or $selectedGroupsToRemove.Count -gt 0)) {
    Write-Host "`n  Waiting for MECM to propagate deletions..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
}

# ------------------------------------------------------------------------------
# 7. STEP 3: Clean up Empty MECM Console Folders
# ------------------------------------------------------------------------------
if (-not $KeepFolders) {
    Write-Host "`n[3/4] Cleaning Console Folders..." -ForegroundColor Yellow

    function Remove-EmptyConsoleFolderTree {
        param([uint32]$ObjectType, [string]$RootFolderName)

        try {
            $allNodes = @(Get-CimInstance -Namespace $wmiNamespace -ClassName SMS_ObjectContainerNode -Filter "ObjectType = $ObjectType" -ErrorAction SilentlyContinue)

            # Match root folder by name — support both 'Windows Store Apps' and 'Windows Store Applications' variants
            $rootNode = $allNodes | Where-Object { $_.ParentContainerNodeID -eq 0 -and $_.Name -like "*$RootFolderName*" } | Select-Object -First 1
            if (-not $rootNode) { return }

            # Build descendant list (deepest-first via post-order traversal)
            function Get-ChildNodes {
                param([uint32]$parentId)
                $children = [System.Collections.Generic.List[object]]::new()
                $direct = $allNodes | Where-Object { [uint32]$_.ParentContainerNodeID -eq $parentId }
                foreach ($d in $direct) {
                    foreach ($c in (Get-ChildNodes -parentId ([uint32]$d.ContainerNodeID))) {
                        $children.Add($c)
                    }
                    $children.Add($d)
                }
                return $children
            }

            $descendants = Get-ChildNodes -parentId ([uint32]$rootNode.ContainerNodeID)
            # Process deepest folders first, root folder last
            $nodesToDelete = [System.Collections.Generic.List[object]]::new()
            foreach ($d in $descendants) { $nodesToDelete.Add($d) }
            $nodesToDelete.Add($rootNode)

            foreach ($n in $nodesToDelete) {
                # Re-query live from WMI each iteration to reflect prior deletions
                $nodeId = [uint32]$n.ContainerNodeID

                $items    = @(Get-CimInstance -Namespace $wmiNamespace -ClassName SMS_ObjectContainerItem  -Filter "ContainerNodeID = $nodeId"       -ErrorAction SilentlyContinue)
                $subNodes = @(Get-CimInstance -Namespace $wmiNamespace -ClassName SMS_ObjectContainerNode  -Filter "ParentContainerNodeID = $nodeId"   -ErrorAction SilentlyContinue)

                if ($items.Count -eq 0 -and $subNodes.Count -eq 0) {
                    if ($PSCmdlet.ShouldProcess("$($n.Name) (ID: $nodeId)", "Delete empty console folder")) {
                        try {
                            # Use [int] cast — Remove-CMFolder -Id parameter is typed [int]
                            $nodeIdInt = [int]$nodeId
                            $fObj = Get-CMFolder -Id $nodeIdInt -ErrorAction SilentlyContinue
                            if ($fObj) {
                                Remove-CMFolder -InputObject $fObj -Force -ErrorAction SilentlyContinue
                                Write-Host "    [REMOVED FOLDER] $($n.Name)" -ForegroundColor Gray
                            } else {
                                # Fallback: remove directly via CIM if MECM cmdlet can't find it
                                $cimNode = Get-CimInstance -Namespace $wmiNamespace -ClassName SMS_ObjectContainerNode -Filter "ContainerNodeID = $nodeId" -ErrorAction SilentlyContinue
                                if ($cimNode) {
                                    Remove-CimInstance -InputObject $cimNode -ErrorAction SilentlyContinue
                                    Write-Host "    [REMOVED FOLDER via CIM] $($n.Name)" -ForegroundColor Gray
                                }
                            }
                        } catch { }
                    }
                } else {
                    if ($items.Count -gt 0) {
                        Write-Host "    [SKIPPED - still has $($items.Count) item(s)] $($n.Name)" -ForegroundColor DarkYellow
                    }
                }
            }
        } catch {
            Write-Warning "  Folder cleanup error: $($_.Exception.Message)"
        }
    }

    # Clean Application Group Folders (ObjectType 224)
    Remove-EmptyConsoleFolderTree -ObjectType 224 -RootFolderName "Windows Store"

    # Clean Application Folders (ObjectType 6000)
    Remove-EmptyConsoleFolderTree -ObjectType 6000 -RootFolderName "Windows Store"
}

# ------------------------------------------------------------------------------
# 8. STEP 4: Remove Staged Package Files on UNC Content Share (Optional)
# ------------------------------------------------------------------------------
if ($RemoveStagedContent) {
    Write-Host "`n[4/4] Cleaning Staged UNC Content Share..." -ForegroundColor Red

    $serverName = if (-not [string]::IsNullOrWhiteSpace($SiteServer) -and $SiteServer -ne 'localhost') {
        $SiteServer
    } else {
        $env:COMPUTERNAME
    }

    $defaultShare = "\\$serverName\Software\Microsoft\Windows Store Apps"
    $targetShare = if (-not [string]::IsNullOrWhiteSpace($ContentShare)) { $ContentShare } else { $defaultShare }

    Write-Host "  Target UNC Share: $targetShare" -ForegroundColor Cyan

    $contentExists = [System.IO.Directory]::Exists($targetShare)
    if (-not $contentExists -and (Test-Path -LiteralPath $targetShare)) {
        $contentExists = $true
    }

    if ($contentExists) {
        if ($removeAllDiscovered) {
            # Wipe subfolders in share
            Get-ChildItem -Path "Microsoft.PowerShell.Core\FileSystem::$targetShare" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                if ($PSCmdlet.ShouldProcess($_.FullName, "Delete staged content folder")) {
                    try {
                        [System.IO.Directory]::Delete($_.FullName, $true)
                        Write-Host "    [DELETED CONTENT] $($_.Name)" -ForegroundColor Green
                    } catch {
                        try {
                            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                            Write-Host "    [DELETED CONTENT] $($_.Name)" -ForegroundColor Green
                        } catch {
                            Write-Warning "    Could not delete '$($_.FullName)': $($_.Exception.Message)"
                        }
                    }
                }
            }
        } else {
            # Target specific application folders
            foreach ($app in $selectedAppsToRemove) {
                $rawName = ($app.LocalizedDisplayName -replace '\s*\((x64|x86|arm64|neutral)\)$', '').Trim()
                $targetAppFolder = Join-Path $targetShare $rawName
                if ([System.IO.Directory]::Exists($targetAppFolder)) {
                    if ($PSCmdlet.ShouldProcess($targetAppFolder, "Delete staged app content")) {
                        try {
                            [System.IO.Directory]::Delete($targetAppFolder, $true)
                            Write-Host "    [DELETED CONTENT] $rawName" -ForegroundColor Green
                        } catch {
                            try { Remove-Item -LiteralPath $targetAppFolder -Recurse -Force -ErrorAction SilentlyContinue } catch { }
                        }
                    }
                }
                # Check _Frameworks
                $fwFolder = Join-Path (Join-Path $targetShare '_Frameworks') $rawName
                if ([System.IO.Directory]::Exists($fwFolder)) {
                    if ($PSCmdlet.ShouldProcess($fwFolder, "Delete staged framework content")) {
                        try {
                            [System.IO.Directory]::Delete($fwFolder, $true)
                            Write-Host "    [DELETED CONTENT] _Frameworks\$rawName" -ForegroundColor Green
                        } catch {
                            try { Remove-Item -LiteralPath $fwFolder -Recurse -Force -ErrorAction SilentlyContinue } catch { }
                        }
                    }
                }
            }
        }
    } else {
        Write-Host "  Content Share path not accessible: $targetShare" -ForegroundColor DarkGray
    }
}

# ------------------------------------------------------------------------------
# 9. Summary Completion
# ------------------------------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "                CLEANUP COMPLETE                          " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "MECM test environment successfully cleaned.`n" -ForegroundColor Green
