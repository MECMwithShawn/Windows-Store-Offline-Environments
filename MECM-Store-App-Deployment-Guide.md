# Deploying Microsoft Store Apps in MECM (Offline / Disconnected)

A practical guide to turning the packages produced by `Download-StoreApp.ps1` into Microsoft Endpoint Configuration Manager (MECM/SCCM) applications, then bundling them into an **Application Group** that installs in the correct order - for fully disconnected, air-gapped deployment.

The **primary method** configures each app and each dependency as native *Windows app package* applications, then uses an **Application Group** to set install order and deploy them as a unit. A **PowerShell provisioning** method is included as an [alternative](#alternative-powershell-provisioning) for edge cases.

This guide assumes the device is the install target and the MECM client runs install commands as **SYSTEM**.

---

## Table of contents

- [Overview](#overview)
- [Mental Model: Traditional MSI vs. APPX/MSIX](#mental-model-traditional-msi-vs-appxmsix-why-provision-for-all-users-matters)
- [Prerequisites](#prerequisites)
- [Content source layout](#content-source-layout)
- [Step 1 - Create the dependency applications](#step-1--create-the-dependency-applications)
- [Step 2 - Create the main app applications](#step-2--create-the-main-app-applications)
- [Step 3 - Distribute content](#step-3--distribute-content)
- [Step 4 - Create the Application Group and set order](#step-4--create-the-application-group-and-set-order)
- [Step 5 - Deploy the Application Group](#step-5--deploy-the-application-group)
- [Install order rules](#install-order-rules)
- [Sharing frameworks across apps](#sharing-frameworks-across-apps)
- [Optional: deployment type dependencies](#optional-deployment-type-dependencies)
- [Updating to a new version](#updating-to-a-new-version)
- [Verification and troubleshooting](#verification-and-troubleshooting)
- [Uninstall behavior](#uninstall-behavior)
- [Alternative: PowerShell provisioning](#alternative-powershell-provisioning)
- [Quick reference](#quick-reference)

---

## Overview

The native *Windows app package (\*.appx, \*.appxbundle, \*.msixbundle)* deployment type lets MECM read each package's manifest and auto-create its name, version, and detection rule - no scripting required. You create one application per package: each framework dependency (`Microsoft.VCLibs`, `Microsoft.UI.Xaml`, `Microsoft.WindowsAppRuntime`, `Microsoft.NET.Native.Framework`, `Microsoft.NET.Native.Runtime`) and each main app (Windows Terminal, Company Portal, etc.). You then add them all to an Application Group and arrange the order so frameworks install before the apps that need them, and deploy the group.

### Automated Setup (Recommended)
You can automate this entire workflow (staging UNC content, creating applications with **"Provision this application for all users on the device"**, and building the sequenced Application Group) using **[`Publish-MECMStoreApp.ps1`](Publish-MECMStoreApp.ps1)**:

```powershell
.\Publish-MECMStoreApp.ps1 `
    -PackagePath ".\StoreDownloads\Windows Terminal\3001.24.11911.0" `
    -ContentShare "\\Server\Source$\StoreApps" `
    -SiteCode "PS1" `
    -DistributeContent -DPGroupName "All DPs"
```

To perform these steps manually in the Configuration Manager console, follow Steps 1 through 5 below.

---

## Prerequisites

- Packages downloaded with `Download-StoreApp.ps1`, e.g. `…\Windows Terminal\1.22.12111.0\` containing the main bundle and its dependency `.appx` files.
- A content source share reachable by the MECM site/DP, referenced by **UNC path** (not a local drive).
- Rights to read the share ACL and, if repair is approved, permission to run `Grant-SmbShareAccess` on the share server. Remote share servers also require CIM administrative access.
- MECM current branch **2107 or later** (required for Application Groups and ordered installs) and clients on a matching version.
- Target devices allow sideloaded/provisioned signed packages (default on supported Windows 10/11; enforce via policy in your base image if locked down). Store packages are Microsoft-signed, so the signing chain is trusted on a standard image.

### Content-share permission preflight

Before staging content, `Publish-MECMStoreApp.ps1` resolves the share portion of
the configured UNC path and verifies these minimum SMB share permissions:

| Account | Minimum share right | Stronger accepted rights |
|---|---|---|
| `Everyone` | Read | Change or Full |
| `BUILTIN\Administrators` | Change | Full |

If a required Allow entry is missing, the script prompts once before applying
only the missing grant. Declining the repair, a failed grant, or an explicit Deny
entry stops staging before content is written. Use `-WhatIf` to preview the
permission changes. The equivalent manual commands are:

```powershell
Grant-SmbShareAccess -Name "Software" -AccountName "Everyone" -AccessRight Read -Force
Grant-SmbShareAccess -Name "Software" -AccountName "BUILTIN\Administrators" -AccessRight Change -Force
```

The preflight checks the **SMB share ACL**, not NTFS permissions. Maintain NTFS
ACLs separately, and replace broad principals with organization-approved groups
if policy does not permit `Everyone: Read`.

---

## Mental Model: Traditional MSI vs. APPX/MSIX (Why "Provision for all users" matters)

Understanding the distinction between per-user registration and device-wide provisioning is critical for device-targeted offline deployments:

| Deployment Model | Traditional MSI / EXE | APPX / MSIX - Provisioned (Recommended) | APPX / MSIX - Not Provisioned |
|---|---|---|---|
| **Scope** | Machine / system | Device-wide provisioning | Per-user registration |
| **MECM Concept** | `Install for system` + `Whether or not a user is logged on` | **"Provision this application for all users on the device"** | Provision option is not selected |
| **User Logged On?** | Not required for a system-context deployment | **Not required**. Package is staged/provisioned at the device level so it is available to all users (existing & new) | **Required**. Registration is associated with user context; fails or skips without active user session |
| **Best Mental Model** | Machine install | **Device-wide app provisioning** | Per-user app registration |

### Why Device-Wide Provisioning is Essential for Application Groups:
When an Application Group is deployed to a **Device Collection** (e.g. during imaging, task sequences, or maintenance windows), the install runs as **SYSTEM**. 
- If **"Provision this application for all users on the device"** is **enabled**, DISM / AppX stages the framework and app packages globally across the OS. The Application Group succeeds regardless of whether anyone is logged on.
- If this option is omitted, MECM attempts per-user registration in the SYSTEM profile, which will either fail or leave the app completely unavailable to interactive users.

> [!TIP]
> **Policy & Content Note**: Changing the provisioning setting updates the application/CI policy metadata in MECM. If the package binary files on disk did not change, you do **not** need to redistribute content to DPs. Simply initiate a **Machine Policy Retrieval & Evaluation Cycle** on target clients so they retrieve the updated metadata.

---

## Content source layout

Because each package becomes its own application, give each one its own source folder containing a single package file. Frameworks are shared, so keep them in a common area:

```text
\\Server\Source$\StoreApps\
├─ _Frameworks\
│  ├─ VCLibs.140.00.x64\
│  │  └─ Microsoft.VCLibs.140.00_14.0.33519.0_x64__8wekyb3d8bbwe.appx
│  ├─ UI.Xaml.2.8.x64\
│  │  └─ Microsoft.UI.Xaml.2.8_8.2501.31001.0_x64__8wekyb3d8bbwe.appx
│  ├─ WindowsAppRuntime.1.5.x64\
│  │  └─ Microsoft.WindowsAppRuntime.1.5_5001.70.1338.0_x64__8wekyb3d8bbwe.msix
│  ├─ NET.Native.Framework.2.2.x64\
│  │  └─ Microsoft.NET.Native.Framework.2.2_2.2.29512.0_x64__8wekyb3d8bbwe.appx
│  └─ NET.Native.Runtime.2.2.x64\
│     └─ Microsoft.NET.Native.Runtime.2.2_2.2.28604.0_x64__8wekyb3d8bbwe.appx
├─ WindowsTerminal\
│  └─ Microsoft.WindowsTerminal_1.22.12111.0_x64__8wekyb3d8bbwe.msixbundle
└─ CompanyPortal\
   └─ Microsoft.CompanyPortal_…_x64__8wekyb3d8bbwe.msixbundle
```

> A native *Windows app package* application points at exactly one package file as its content, which is why each `.appx` / bundle lives in its own folder.

---

## Step 1 - Create the dependency applications

Do this once per framework; you'll reuse them across every app that needs them.

1. **Software Library → Application Management → Applications → Create Application.**
2. Select **Automatically detect information from installation files**.
3. Type: **Windows app package (\*.appx, \*.appxbundle, \*.msix, \*.msixbundle)**.
4. Location: the UNC path to the framework's `.appx` / `.msix`, e.g. `\\Server\Source$\StoreApps\_Frameworks\VCLibs.140.00.x64\Microsoft.VCLibs.140.00_…_x64__8wekyb3d8bbwe.appx`.
5. MECM reads the manifest and fills in name, publisher, version, and a detection rule automatically. Finish the wizard.
6. Open the created Application → **Deployment Types** tab → right-click the deployment type → **Properties**:
   - Navigate to the **User Experience** tab.
   - Check **[X] Provision this application for all users on the device**.
   - Click **OK**.

Repeat for UI.Xaml, Windows App Runtime, .NET Native Framework, and .NET Native Runtime (matching your target architecture).

---

## Step 2 - Create the main app applications

1. **Create Application → Automatically detect information from installation files.**
2. Type: **Windows app package**.
3. Location: the UNC path to the app's `.msixbundle` / `.msix`.
4. MECM auto-fills name/version/detection. Finish the wizard.
5. Open the Application → **Deployment Types** → **Properties**:
   - Navigate to the **User Experience** tab.
   - Check **[X] Provision this application for all users on the device**.
   - Click **OK**.

> [!NOTE]
> **Automated Device-Wide Provisioning**:
> When using `Publish-MECMStoreApp.ps1`, device-level provisioning (`[X] Provision this application for all users on the device`) is **fully automated** via the official Configuration Manager AppManagement SDK (`Microsoft.ConfigurationManagement.ApplicationManagement.Win8Installer.dll` and `SccmSerializer`). If creating applications manually via the MECM Console GUI, simply navigate to the **User Experience** tab and check **[X] Provision this application for all users on the device**.

Repeat for each app. At this point you have separate applications for every framework and every app, each configured for system-level provisioning.

---

## Step 3 - Distribute content

Right-click each application (frameworks and apps) → **Distribute Content** → select your distribution point(s) / DP group. Verify under **Monitoring → Content Status** that distribution succeeded before deploying. In disconnected sites, confirm the content reached the local DP.

---

## Step 4 - Create the Application Group and set order

The Application Group bundles the applications and **controls the order they install** (top to bottom).

1. **Software Library → Application Management → Application Groups → Create Application Group.**
2. **General:** name it (e.g. *Store Apps - Standard Build*), set publisher/version.
3. **Application Group:** click **Add**, select every framework and app, then use **Move Up / Move Down** to order them:
   - Frameworks first (VCLibs, UI.Xaml, .NET Native Runtime, .NET Native Framework)
   - Main apps last (Windows Terminal, Company Portal, …)
4. Finish the wizard.

The group references the existing applications; members do **not** need their own separate deployments.

---

## Step 5 - Deploy the Application Group

1. Right-click the Application Group → **Deploy.**
2. Target a **device collection** (installs run for system).
3. Purpose: **Required** for automated build deployment, or **Available** for on-demand via Software Center.
4. Set schedule and user experience, then finish.

The client installs each member in the defined order and reports compliance for the group as a whole.

---

## Install order rules

MECM Application Groups execute installations **strictly top-to-bottom** (and perform uninstalls in **reverse order**, bottom-to-top).

### 1. The 3-Tier Hierarchy: "Foundation First, Consumer Last"

Always arrange members following this sequence:

```text
┌────────────────────────────────────────────────────────┐
│ 1. Core C/C++ Runtimes (e.g., VCLibs, CRT)             │
├────────────────────────────────────────────────────────┤
│ 2. Managed / UI Frameworks (NET.Native, UI.Xaml,       │
│    WindowsAppRuntime)                                  │
├────────────────────────────────────────────────────────┤
│ 3. Main Application Packages (Terminal, Portal, etc.)  │
└────────────────────────────────────────────────────────┘
```

#### Example Application Group Order:
1. `Microsoft.VCLibs.140.00.x64`
2. `Microsoft.NET.Native.Runtime.2.2.x64`
3. `Microsoft.NET.Native.Framework.2.2.x64`
4. `Microsoft.UI.Xaml.2.8.x64`
5. `Microsoft.WindowsAppRuntime.1.5.x64` *(if applicable)*
6. `Microsoft.WindowsTerminal` *(Main App)*
7. `Microsoft.CompanyPortal` *(Main App)*

### 2. How to Identify What an App Needs

- **Check the Download Folder**: `Download-StoreApp.ps1` downloads only the exact dependency `.appx` files required by that specific app into its version folder. Every dependency `.appx` staged alongside the main package must be ordered above the app in the group.
- **Inspect Manifest (Deep Check)**: To review dependencies directly within an `.msix` or `.msixbundle`, extract it with `Expand-Archive` and check the `<Dependencies>` node inside `AppxManifest.xml`.

### 3. Key Rules for Multi-App Groups

- **Shared Frameworks Appear Once**: If multiple apps require `VCLibs.140.00`, place it once near the top. MECM installs it on first pass; subsequent apps detect it and skip reinstalling.
- **Distinct Majors Are Separate Applications**: Different framework major versions (e.g. `UI.Xaml.2.4` vs `UI.Xaml.2.8`) are distinct packages that can coexist side-by-side. Create separate applications for each required major version and list them above the apps.
- **Group Failure Behavior**: If any member in the group fails, the entire group is marked failed and subsequent members may be aborted. Validate group order in a lab collection first.

---

## Sharing frameworks across apps

Create each shared framework once as its own application and reuse it; don't duplicate it per app. This works because of detection: the framework application's auto-created detection rule matches the package family name and version, so MECM installs it only if it isn't already present. Once a framework like VCLibs is on the device, every other app that references it sees detection satisfied and skips reinstalling.

There are two ways to share it:

- **Application Group ordering:** list the shared framework once, ordered above every app that uses it. MECM installs it on first encounter and the apps below consume it.
- **Deployment-type Dependencies (Auto Install):** each app's deployment type references the same framework application. Many apps can point at that one dependency app, and MECM dedupes automatically, installing the framework once if missing and skipping it otherwise, regardless of how many apps depend on it. The relationship is explicit per app, so correct sequencing doesn't depend on remembering the group order.

Most setups use both: deployment-type dependencies to model "this app needs these frameworks" (the sharing and dedup), and the Application Group for the overall build sequence and single-deployment reporting.

**Version caveat:** keep one application per unique framework identity. The same name + version + architecture shared across apps is one application. Different majors (e.g. UI.Xaml 2.4 vs 2.8) are separate packages that can coexist, so each is its own application and an app references whichever it actually needs.

---

## Optional: deployment type dependencies

For stricter, app-level enforcement (independent of group order), you can declare dependencies directly on a main app's deployment type:

1. Open the app → deployment type → **Properties → Dependencies → Add.**
2. Create a dependency group, add the required framework applications, and enable **Auto Install**.

MECM then installs those frameworks before the app whenever it deploys - even outside the group. This complements the Application Group; many shops use group ordering for the build sequence and deployment-type dependencies as a safety net. Use one as your primary control to avoid confusion.

---

## Updating to a new version

When a new build ships, re-run `Download-StoreApp.ps1` for the app. The downloader caches by file size, so it fetches only the new packages and places them in a new version subfolder (e.g. `…\Windows Terminal\<new version>\`). Existing versions are left untouched. From MECM you then either:

- Update the existing application's deployment type **content location** to point at the new version folder, then **Update Content** and redistribute; or
- Create a **new application version** for the new package and use **Supersedence** to replace the old one. This gives a cleaner audit trail and supports phased replacement.

If the package identity changed, re-check the Application Group membership and order. Frameworks change infrequently, so update them the same way only when an app requires a newer dependency.

---

## Verification and troubleshooting

Check installed state on a target device:

```powershell
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like '*Terminal*'
Get-AppxPackage -AllUsers -Name Microsoft.WindowsTerminal | Select Name, Version, Status
```

Key client logs (`…\CCM\Logs`):

| Log | Shows |
|---|---|
| `AppEnforce.log` | Install/uninstall execution and exit codes |
| `AppDiscovery.log` | Detection results |
| `AppIntentEval.log` | Deployment/group evaluation and ordering |
| `C:\Windows\Logs\DISM\dism.log` | Underlying appx/provisioning errors |

Common issues:

- **0x80073CF3 (dependency missing):** a framework the app needs wasn't installed first. Check the group order, the architecture match, and that the framework application distributed successfully.
- **0x800B0109 / trust errors:** the signing chain isn't trusted on the device image.
- **Detection flaps or never satisfies:** rare with auto-detection; if you edited the rule, ensure it matches the package family name and version.
- **Installed but not visible to a logged-on user:** device-context installs provision for new profiles and the device; an existing session may need a logon cycle.

---

## Uninstall behavior

Deploying the group as **Uninstall**, or removing each application, reverses the install order. Frameworks are shared, so MECM won't remove a framework that another deployed app still depends on (when modeled via deployment-type dependencies). Remove frameworks manually only when nothing else needs them.

For test-environment object cleanup, `Remove-MECMStoreApp.ps1` only selects
applications and Application Groups carrying the toolkit description marker
`[WindowsStoreOfflineToolkit:v2]`. Exact descriptions written by the earlier
release are retained as a compatibility path. Application names, partial name
matches, and generic AppX/MSIX deployment types are not sufficient ownership
evidence; for example, an unrelated `Notepad++` application is excluded.

Always run cleanup with `-WhatIf` first. `-AppName` filters only within the
toolkit-owned inventory, `-All` includes only toolkit-owned MECM objects, and
share-wide staged-content cleanup occurs only when all-object cleanup was
explicitly selected.

---

## Alternative: PowerShell provisioning

Use this when you'd rather have a single self-contained installer per app, or when the native type misbehaves with a particular package. Each app folder holds its main package, its dependency `.appx` files, and the three scripts below; the install script provisions the app and its dependencies together.

**Install-StoreApp.ps1**

```powershell
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$frameworkPattern = 'VCLibs|UI\.Xaml|NET\.Native'

$packages = Get-ChildItem -Path $root -File |
    Where-Object { $_.Extension -in '.msixbundle','.appxbundle','.msix','.appx' }
$main = $packages | Where-Object { $_.Name -notmatch $frameworkPattern } | Select-Object -First 1
$deps = $packages | Where-Object { $_.Name -match  $frameworkPattern }
if (-not $main) { throw "No main package found in $root" }

$params = @{ Online = $true; PackagePath = $main.FullName; SkipLicense = $true }
if ($deps) { $params.DependencyPackagePath = $deps.FullName }
Add-AppxProvisionedPackage @params | Out-Null
```

**Detect-StoreApp.ps1** (set `$packageName` to the package identity name)

```powershell
$packageName = 'Microsoft.WindowsTerminal'
$found = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $packageName }
if ($found) { Write-Output 'Installed' }
```

**Uninstall-StoreApp.ps1**

```powershell
$ErrorActionPreference = 'SilentlyContinue'
$packageName = 'Microsoft.WindowsTerminal'
Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $packageName } |
    Remove-AppxProvisionedPackage -Online
Get-AppxPackage -AllUsers -Name $packageName | Remove-AppxPackage -AllUsers
```

Create the application with a **Script Installer** deployment type:

- Install: `powershell.exe -ExecutionPolicy Bypass -File Install-StoreApp.ps1`
- Uninstall: `powershell.exe -ExecutionPolicy Bypass -File Uninstall-StoreApp.ps1`
- Detection: custom PowerShell script (`Detect-StoreApp.ps1`)
- User experience: **Install for system**, **Whether or not a user is logged on**

`-SkipLicense` is used because offline license XML isn't available; the Microsoft-signed packages remain trusted.

---

## Quick reference

| Task | Location / command |
|---|---|
| Automated Creation | `.\Publish-MECMStoreApp.ps1 -All` (auto-provisions and groups apps) |
| Testing Cleanup | `.\Remove-MECMStoreApp.ps1 -All -RemoveStagedContent` |
| Create app or dependency | Applications → Create Application → Windows app package |
| Distribute | Right-click app → Distribute Content |
| Create group | Application Groups → Create Application Group |
| Set order | Group wizard → Move Up / Move Down (frameworks first) |
| Deploy | Right-click group → Deploy → device collection → Required |
| Deployment-type dependency | Deployment type → Properties → Dependencies → Auto Install |
| Verify | `Get-AppxProvisionedPackage -Online`, `Get-AppxPackage -AllUsers` |
| Logs | `…\CCM\Logs\AppEnforce.log`, `AppDiscovery.log`, `AppIntentEval.log` |

---

*Companion to `Download-StoreApp.ps1`. Validate in a lab collection before production deployment.*
