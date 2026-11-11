<#
.SYNOPSIS
    Force-removes Microsoft App Installer (winget) from a device.
    Intended for MECM Run Scripts (runs as Local SYSTEM, 64-bit).

.DESCRIPTION
    Newer Windows builds flag Microsoft.DesktopAppInstaller as NonRemovable and
    refuse Remove-AppxPackage with 0x80070032 / 0x80073CFA. This script:

      1. Writes an "EndOfLife" marker for every user + package under
         HKLM\...\Appx\AppxAllUserStore\EndOfLife, which lets Windows remove a
         protected package. UNSUPPORTED by Microsoft - it bypasses an OS
         protection.
      2. Removes the provisioned (all users) copy so new profiles do not get it.
      3. Removes every registered / staged copy (bundle first, then main).
      4. Deletes the EndOfLife markers again, so App Installer can be
         reinstalled later.
      5. Verifies nothing is left and reports.

    If the device is still targeted by a Required MECM deployment of App
    Installer, MECM reinstalls it at the next application evaluation. Remove the
    device from that deployment first.

.OUTPUTS
    Text lines for the Run Scripts output pane. Last line starts with
    SUCCESS or FAILED. Exit code 0 = removed (or was not present), 1 = failed.
#>

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
$AppName  = 'Microsoft.DesktopAppInstaller'
$EolRoot  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\EndOfLife'
$Problems = @()
$Markers  = @()

function Get-AppInstallerPackages {
    # Main and Bundle are listed separately; a plain Get-AppxPackage hides the bundle.
    $all = @()
    foreach ($type in 'Bundle', 'Main') {
        $all += @(Get-AppxPackage -AllUsers -Name $AppName -PackageTypeFilter $type -ErrorAction SilentlyContinue |
                  ForEach-Object { [pscustomobject]@{ Type = $type; Package = $_ } })
    }
    return $all
}

function Get-Hresult {
    param($ErrorRecord)
    $m = [regex]::Match([string]$ErrorRecord.Exception.Message, '0x[0-9A-Fa-f]{8}')
    if ($m.Success) { return $m.Value }
    return ('0x{0:X8}' -f $ErrorRecord.Exception.HResult)
}

try {
    $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Output "Running as $who on $env:COMPUTERNAME (build $([Environment]::OSVersion.Version.Build))"

    $found = @(Get-AppInstallerPackages)
    $prov  = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $AppName })

    if ($found.Count -eq 0 -and $prov.Count -eq 0) {
        Write-Output 'SUCCESS: App Installer (winget) is not present. Nothing to remove.'
        Exit-Script 0
    }

    foreach ($f in $found) {
        Write-Output ("Found [{0}] {1} NonRemovable={2}" -f $f.Type, $f.Package.PackageFullName, $f.Package.NonRemovable)
    }

    # --- 1. EndOfLife markers: every known user SID x every package -----------
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
    Write-Output "EndOfLife markers written: $($Markers.Count) ($($sids.Count) user SIDs)"

    # --- 2. Provisioned (all users) copy ---------------------------------------
    foreach ($p in $prov) {
        try {
            $null = Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName
            Write-Output "Deprovisioned: $($p.PackageName)"
        } catch {
            # DISM can report an error here even when the entry is removed; verified below.
            Write-Output "Deprovision reported $(Get-Hresult $_) for $($p.PackageName) (checked again below)"
        }
    }

    # --- 3. Registered / staged copies: bundle first, then main ----------------
    foreach ($pass in 1, 2) {
        $current = @(Get-AppInstallerPackages)
        if ($current.Count -eq 0) { break }
        foreach ($f in $current) {
            $full = $f.Package.PackageFullName
            try {
                Remove-AppxPackage -Package $full -AllUsers
                Write-Output "Removed for all users: [$($f.Type)] $full"
            } catch {
                $hr = Get-Hresult $_
                if ($pass -eq 2) { Write-Output "All-users removal failed ($hr): $full" }
                # Fall back to each user that still has it.
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
    # --- 4. Remove the markers so App Installer can be installed again ---------
    foreach ($key in $Markers) {
        Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($sidKey in @(Get-ChildItem -LiteralPath $EolRoot -ErrorAction SilentlyContinue)) {
        if (-not (Get-ChildItem -LiteralPath $sidKey.PSPath -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $sidKey.PSPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- 5. Verify -----------------------------------------------------------------
$leftPkgs = @(Get-AppInstallerPackages)
$leftProv = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $AppName })
$leftEol  = @(Get-ChildItem -LiteralPath $EolRoot -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "$AppName*" })

foreach ($f in $leftPkgs) {
    $users = ($f.Package.PackageUserInformation | ForEach-Object { "$($_.UserSecurityId.Sid)=$($_.InstallState)" }) -join ','
    Write-Output "STILL PRESENT: [$($f.Type)] $($f.Package.PackageFullName) [$users]"
}
foreach ($p in $leftProv) { Write-Output "STILL PROVISIONED: $($p.PackageName)" }
foreach ($e in $leftEol)  { Write-Output "MARKER NOT CLEANED: $($e.Name)" }
foreach ($x in $Problems) { Write-Output "PROBLEM: $x" }

if ($leftPkgs.Count -gt 0 -or $leftProv.Count -gt 0) {
    Write-Output 'FAILED: App Installer (winget) removal incomplete.'
    Exit-Script 1
}

Write-Output 'SUCCESS: App Installer (winget) removed for all users and deprovisioned.'
Exit-Script 0
