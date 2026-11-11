<#
.SYNOPSIS
    Removes one Microsoft Store (AppX / MSIX) app from a device for all users.
    Intended for MECM Run Scripts (runs as Local SYSTEM, 64-bit).

.DESCRIPTION
    Removes the provisioned (all users) copy and every registered or staged
    copy of ONE package, then verifies nothing is left.

    Normal apps are removed with the supported cmdlets.

    Newer Windows builds flag some apps (for example Microsoft.DesktopAppInstaller,
    which ships winget) as NonRemovable and refuse removal with 0x80070032 /
    0x80073CFA. Those are left untouched unless -ForceProtected Yes is passed.
    The forced path writes temporary "EndOfLife" markers under
    HKLM\...\Appx\AppxAllUserStore\EndOfLife, removes the package, then deletes
    the markers so the app can be installed again. That path is UNSUPPORTED by
    Microsoft: it bypasses an OS protection.

    Always refused, forced or not:
      - wildcards or anything that is not one exact package name
      - framework packages (VCLibs, UI.Xaml, WindowsAppRuntime, .NET Native)
      - packages signed as part of Windows (SignatureKind = System)
      - packages another installed package depends on

    If the device is still targeted by a Required MECM deployment of the app,
    MECM reinstalls it at the next application evaluation.

.PARAMETER Name
    Exact package name, for example Microsoft.WindowsNotepad or
    Microsoft.DesktopAppInstaller. Not the display name, no wildcards.

.PARAMETER ForceProtected
    Yes = also remove a package Windows flags NonRemovable (unsupported).
    No (default) = report it and change nothing.

.OUTPUTS
    Text lines for the Run Scripts output pane. The last line starts with
    SUCCESS, REFUSED or FAILED.
    Exit code 0 = removed or not present, 1 = failed, 2 = refused (nothing changed).
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [ValidateSet('Yes', 'No')]
    [string]$ForceProtected = 'No'
)

$ErrorActionPreference = 'Stop'
# MECM Run Scripts does not run this file directly: it wraps it as
#   Invoke-Command -ScriptBlock { & 'script.ps1' <params> | ConvertTo-Json -Compress }
# In that form a plain "exit N" only ends the script and PowerShell.exe still
# returns 0. SetShouldExit makes the process return N after the output has been
# sent; "exit N" keeps the code correct when the file is run directly.
function Exit-Script {
    param([int]$Code)
    $Host.SetShouldExit($Code)
    exit $Code
}
$EolRoot  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\EndOfLife'
$Problems = @()
$Markers  = @()
$Name     = $Name.Trim()

function Get-TargetPackages {
    # Main and Bundle are listed separately; a plain Get-AppxPackage hides the bundle.
    $all = @()
    foreach ($type in 'Bundle', 'Main') {
        $all += @(Get-AppxPackage -AllUsers -Name $Name -PackageTypeFilter $type -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -eq $Name } |
                  ForEach-Object { [pscustomobject]@{ Type = $type; Package = $_ } })
    }
    return $all
}

function Get-TargetProvisioned {
    @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $Name })
}

function Get-Hresult {
    param($ErrorRecord)
    $m = [regex]::Match([string]$ErrorRecord.Exception.Message, '0x[0-9A-Fa-f]{8}')
    if ($m.Success) { return $m.Value }
    return ('0x{0:X8}' -f $ErrorRecord.Exception.HResult)
}

function Stop-Refused {
    param([string]$Reason)
    Write-Output "REFUSED: $Reason Nothing was changed."
    Exit-Script 2
}

# --- Guards: decide before changing anything -----------------------------------
if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{2,}$') {
    Stop-Refused "'$Name' is not one exact package name (letters, digits, dots and hyphens only, no wildcards)."
}

$who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Output "Running as $who on $env:COMPUTERNAME (build $([Environment]::OSVersion.Version.Build)); target: $Name; ForceProtected=$ForceProtected"

$found = @(Get-TargetPackages)
$prov  = @(Get-TargetProvisioned)

# Frameworks are NOT returned by the Main/Bundle filters above, so they must be
# looked up on their own and BEFORE anything else: a framework can have a
# provisioned copy while $found is empty.
$fw = @(Get-AppxPackage -AllUsers -Name $Name -PackageTypeFilter Framework -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $Name })
if ($fw.Count -gt 0) {
    Stop-Refused "$Name is a framework package. Frameworks are shared by other apps and are never removed by this script."
}

if ($found.Count -eq 0 -and $prov.Count -eq 0) {
    Write-Output "SUCCESS: $Name is not present. Nothing to remove."
    Exit-Script 0
}

if ($found.Count -eq 0) {
    # Provisioned entry with no registered or staged package: its type cannot be checked.
    Stop-Refused "$Name has a provisioned entry but no installed package to inspect, so it cannot be confirmed as a normal app."
}

foreach ($f in $found) {
    Write-Output ("Found [{0}] {1} NonRemovable={2} Signature={3}" -f $f.Type, $f.Package.PackageFullName, $f.Package.NonRemovable, $f.Package.SignatureKind)
}

if (@($found | Where-Object { $_.Package.IsFramework }).Count -gt 0) {
    Stop-Refused "$Name is a framework package. Frameworks are shared by other apps and are never removed by this script."
}
if (@($found | Where-Object { "$($_.Package.SignatureKind)" -eq 'System' }).Count -gt 0) {
    Stop-Refused "$Name is signed as part of Windows (SignatureKind = System) and is never removed by this script."
}
$dependents = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne $Name -and @($_.Dependencies | ForEach-Object { $_.Name }) -contains $Name } |
                ForEach-Object { $_.Name } | Select-Object -Unique)
if ($dependents.Count -gt 0) {
    Stop-Refused "$Name is required by: $($dependents -join ', ')."
}

$isProtected = (@($found | Where-Object { $_.Package.NonRemovable }).Count -gt 0)
if ($isProtected -and $ForceProtected -ne 'Yes') {
    Stop-Refused "Windows flags $Name as NonRemovable on this build. Run again with ForceProtected = Yes to force removal (unsupported by Microsoft)."
}

# --- Removal ---------------------------------------------------------------------
try {
    if ($isProtected) {
        # EndOfLife markers: every known user SID x every package.
        $sids = @('S-1-5-18')
        $sids += @($found | ForEach-Object { $_.Package.PackageUserInformation } | ForEach-Object { $_.UserSecurityId.Sid })
        $sids += @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue |
                   ForEach-Object { $_.PSChildName } | Where-Object { $_ -like 'S-1-5-21-*' })
        $sids = @($sids | Where-Object { $_ } | Select-Object -Unique)

        foreach ($sid in $sids) {
            foreach ($f in $found) {
                $key = Join-Path (Join-Path $EolRoot $sid) $f.Package.PackageFullName
                try {
                    if (-not (Test-Path -LiteralPath $key)) {
                        $null = New-Item -Path $key -Force
                        $Markers += $key
                    }
                } catch {
                    $Problems += "EndOfLife marker for $sid : $($_.Exception.Message)"
                }
            }
        }
        Write-Output "Protected package: EndOfLife markers written: $($Markers.Count) ($($sids.Count) user SIDs)"
    }

    # Provisioned (all users) copy.
    foreach ($p in $prov) {
        try {
            $null = Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName
            Write-Output "Deprovisioned: $($p.PackageName)"
        } catch {
            # DISM can report an error here even when the entry is removed; verified below.
            Write-Output "Deprovision reported $(Get-Hresult $_) for $($p.PackageName) (checked again below)"
        }
    }

    # Registered / staged copies: bundle first, then main. Second pass reports what still fails.
    foreach ($pass in 1, 2) {
        $current = @(Get-TargetPackages)
        if ($current.Count -eq 0) { break }
        foreach ($f in $current) {
            $full = $f.Package.PackageFullName
            if (-not (Get-AppxPackage -AllUsers -Name $Name -PackageTypeFilter $f.Type -ErrorAction SilentlyContinue | Where-Object { $_.PackageFullName -eq $full })) { continue }
            try {
                Remove-AppxPackage -Package $full -AllUsers
                Write-Output "Removed for all users: [$($f.Type)] $full"
            } catch {
                $hr = Get-Hresult $_
                if ($pass -eq 2) { Write-Output "All-users removal failed ($hr): $full" }
                foreach ($u in @($f.Package.PackageUserInformation)) {
                    $sid = $u.UserSecurityId.Sid
                    if ($sid -eq 'S-1-5-18') { continue }
                    try {
                        Remove-AppxPackage -Package $full -User $sid
                        Write-Output "Removed for $sid : $full"
                    } catch {
                        if ($pass -eq 2) { Write-Output "Per-user removal failed ($(Get-Hresult $_)) for $sid : $full" }
                    }
                }
            }
        }
    }
}
catch {
    $Problems += "Unexpected error: $($_.Exception.Message)"
}
finally {
    # Remove the markers so the app can be installed again.
    foreach ($key in $Markers) {
        Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($sidKey in @(Get-ChildItem -LiteralPath $EolRoot -ErrorAction SilentlyContinue)) {
        if (-not (Get-ChildItem -LiteralPath $sidKey.PSPath -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $sidKey.PSPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Verify ----------------------------------------------------------------------
$leftPkgs = @(Get-TargetPackages)
$leftProv = @(Get-TargetProvisioned)
$leftEol  = @($Markers | Where-Object { Test-Path -LiteralPath $_ })

foreach ($f in $leftPkgs) {
    $users = ($f.Package.PackageUserInformation | ForEach-Object { "$($_.UserSecurityId.Sid)=$($_.InstallState)" }) -join ','
    Write-Output "STILL PRESENT: [$($f.Type)] $($f.Package.PackageFullName) [$users]"
}
foreach ($p in $leftProv) { Write-Output "STILL PROVISIONED: $($p.PackageName)" }
foreach ($e in $leftEol)  { Write-Output "MARKER NOT CLEANED: $e" }
foreach ($x in $Problems) { Write-Output "PROBLEM: $x" }

if ($leftPkgs.Count -gt 0 -or $leftProv.Count -gt 0) {
    Write-Output "FAILED: $Name removal incomplete."
    Exit-Script 1
}

Write-Output "SUCCESS: $Name removed for all users and deprovisioned."
Exit-Script 0
