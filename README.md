# Windows Store Offline Environments

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%20Windows%2011-0078D6.svg)](https://www.microsoft.com/windows)
[![MECM / SCCM](https://img.shields.io/badge/Deployment-MECM%20%2F%20SCCM%20%7C%20Intune-238636.svg)](https://learn.microsoft.com/mem/configmgr/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A production-ready PowerShell toolset to download, stage, and deploy Microsoft Store app packages (`.msixbundle`, `.appxbundle`, `.msix`, `.appx`) **and their required framework dependencies** directly from Microsoft's Windows Update / FE3 delivery servers.

Built specifically for **disconnected, air-gapped, isolated, and enterprise MECM (SCCM) / Intune offline environments** without requiring a Microsoft account, Store client, or private API keys.

---

### Highlights & Key Features

- **Direct & Anonymous**: Fetches official packages straight from Microsoft delivery CDNs using anonymous Windows Update tickets.
- **Dependency Resolution**: Automatically resolves and downloads matching framework dependencies (`Microsoft.UI.Xaml`, `Microsoft.VCLibs`, `Microsoft.WindowsAppRuntime`, `Microsoft.NET.Native.Framework`, `Microsoft.NET.Native.Runtime`).
- **x64 Enterprise Default**: Intelligently filters for `x64` and `neutral` architecture packages to minimize download bloat and prevent DISM architecture mismatch errors.
- **MECM Application Group Architecture**: Includes complete guides and scripts for staging native *Windows app package* applications and sequencing them in Application Groups (dependencies first, consuming apps last).
- **Network Resilience**: Built-in 3x retry with backoff for CDN connection dropouts, file size caching, and input redirection safety for automation pipelines.

---

## Tools in this Repository

| Tool / Guide | Description |
|---|---|
| [`Download-StoreApp.ps1`](Download-StoreApp.ps1) | Downloads Store app packages and required framework dependencies directly from Microsoft delivery servers (defaults to `x64`). |
| [`Publish-MECMStoreApp.ps1`](Publish-MECMStoreApp.ps1) | Automates creating native MECM applications with "Provision for all users", stages content to UNC, and builds sequenced **Application Groups**. |
| [`Remove-MECMStoreApp.ps1`](Remove-MECMStoreApp.ps1) | Cleanup utility for testing: removes toolkit-owned Application Groups, Applications, Console Folders, and optional staged UNC content. |
| [`MECM-Store-App-Deployment-Guide.md`](MECM-Store-App-Deployment-Guide.md) | Comprehensive step-by-step guide for creating native MECM applications and sequencing them in an **Application Group**. |

---

## Table of Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Parameters (Download-StoreApp)](#parameters-Download-StoreApp)
- [Usage examples](#usage-examples)
- [Interactive search](#interactive-search)
- [Understanding the output](#understanding-the-output)
- [Disconnected MECM / Intune workflow](#disconnected-mecm--intune-workflow)
- [Troubleshooting](#troubleshooting)
- [Notes and limitations](#notes-and-limitations)
- [Disclaimer](#disclaimer)

---

## How it works

The download script reproduces the chain that the Store client itself uses against the **FE3 delivery service** (`fe3.delivery.mp.microsoft.com`):

1. **Resolve the product.** A name, Store URL, ProductId, or PackageFamilyName is resolved to a Windows Update **category id** via the public DisplayCatalog API (`displaycatalog.mp.microsoft.com`). Names are resolved through the anonymous WinGet *msstore* search endpoint (`storeedgefd.dsx.mp.microsoft.com/v9.0/manifestSearch`).
2. **GetCookie.** Requests an FE3 session cookie using an anonymous Windows Update ticket - this is what lets the whole flow run without credentials.
3. **SyncUpdates.** Returns the set of package update identities plus metadata for the category. The metadata fragments come back XML-escaped inside `<Xml>` elements and are parsed out.
4. **GetExtendedUpdateInfo2.** For each package, returns the real (time-limited) download URLs. URLs are matched back to filenames by their SHA-256 file digest, and the real package full name (with version + architecture) is parsed from the package identity.
5. **Download & Caching.** Each resolved `.appx` / `.appxbundle` / `.msix` / `.msixbundle` is verified and saved. Includes automatic retry logic with backoff for CDN connection resilience.

By default the script keeps only the **newest build of each package family**, filters for **`x64` + `neutral`** architectures, and skips encrypted (`.eappx*` / `.emsix*`) copies.

---

## Requirements

- Windows with **Windows PowerShell 5.1** or **PowerShell 7+**.
- Outbound internet access to `displaycatalog.mp.microsoft.com`, `fe3.delivery.mp.microsoft.com`, `storeedgefd.dsx.mp.microsoft.com`, and the `*.delivery.mp.microsoft.com` content hosts.
- No admin rights needed to download. (Installing/provisioning the packages later in the offline environment uses admin/SYSTEM rights).

---

## Quick start

Launch with a per-process execution policy bypass:

```powershell
# Download by Store ProductId (defaults to x64 + neutral dependencies)
powershell -ExecutionPolicy Bypass -File .\Download-StoreApp.ps1 -Id 9WZDNCRFJBMP
```

Or run with no `-Id` to interactively search the Microsoft Store by name:

```powershell
powershell -ExecutionPolicy Bypass -File .\Download-StoreApp.ps1
```

---

## Parameters (Download-StoreApp)

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Id` | string[] | *(prompt)* | One or more Store URLs, ProductIds, PackageFamilyNames, or search terms. If omitted, the script prompts interactively. |
| `-Ring` | string | `Retail` | Release ring: `Retail`, `RP`, `WIS`, `WIF`. |
| `-Arch` | string | `x64` | Architecture filter: `x64` (default), `all`, `x86`, `arm`, `arm64`, `neutral`. |
| `-OutDir` | string | `.\StoreDownloads` | Root output folder. Saved to `OutDir\<App Name>\<version>\`. |
| `-AllVersions` | switch | off | Keep every version returned instead of just the newest build per family. |
| `-IncludeEncrypted` | switch | off | Include encrypted `.eappx*` / `.emsix*` packages (not directly installable). |
| `-MainPackageOnly` | switch | off | Download only the main app package, skipping framework dependencies. Use when targets already have the frameworks. |
| `-LatestFrameworkOnly` | switch | off | Collapse each framework *line* to its newest major (e.g. `.NET.Native.Framework` 1.7 + 2.2 → 2.2 only). |
| `-Force` | switch | off | Re-download even if a matching file is already present. By default, existing files matching expected size are skipped. |

A ProductId is the 12-character code in a Store link, e.g. `https://apps.microsoft.com/detail/9WZDNCRFJBMP` → `9WZDNCRFJBMP`.

---

## Usage examples

Search by name and pick from an interactive list:

```powershell
powershell -ExecutionPolicy Bypass -File .\Download-StoreApp.ps1 -LatestFrameworkOnly
```

Download an app and its dependencies (x64 default):

```powershell
powershell -ExecutionPolicy Bypass -File .\Download-StoreApp.ps1 -Id 9WZDNCRFJBMP
```

Fetch all architectures (`x86`, `x64`, `arm`, `arm64`):

```powershell
powershell -ExecutionPolicy Bypass -File .\Download-StoreApp.ps1 -Id 9WZDNCRFJBMP -Arch all
```

Queue several apps at once into a custom root folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\Download-StoreApp.ps1 -Id 9WZDNCRFJBMP, 9N0DX20HK701 -OutDir D:\StorePkgs
```

Download only the main bundle (targets already have dependencies):

```powershell
powershell -ExecutionPolicy Bypass -File .\Download-StoreApp.ps1 -Id 9WZDNCRFJBMP -MainPackageOnly
```

---

## Interactive search

Run with no `-Id` and the script searches the Store and displays numbered choices:

```text
Enter a Store URL, ProductId, or PackageFamilyName for each app.
Press Enter on a blank line when finished.

App: Windows Terminal
App: 

Matches for 'Windows Terminal':
  [1] Windows Terminal           (9N0DX20HK701)
  [2] Windows Terminal Preview   (9N8G5RFZ9XK3)
Pick a number (blank to skip): 1
```

> [!TIP]
> **Which result to pick?**
> - Results are sorted by relevance and popularity—**`[1]` is almost always the official primary app**.
> - Look at the 12-character **ProductId** in parentheses (e.g. `9N0DX20HK701`). You can verify this against the Microsoft Store URL: `https://apps.microsoft.com/detail/9N0DX20HK701`.
> - **Skip search entirely**: If you already have the ProductId or Store URL, pass it directly with `-Id` to bypass interactive prompts:
>   ```powershell
>   .\Download-StoreApp.ps1 -Id 9N0DX20HK701
>   ```

---

## Automate MECM Application Groups (Publish-MECMStoreApp)

To automatically stage packages to your UNC source, create native MECM Applications for each package with **"Provision this application for all users on the device"** enabled, organize console folders (`Application\<App>\v.<Ver>` & `Application Groups\<App>\v.<Ver>`), and bundle them into sequenced **Application Groups**:

```powershell
# Interactive mode (prompts to pick an app, all apps [A], or custom folder):
powershell -ExecutionPolicy Bypass -File .\Publish-MECMStoreApp.ps1

# Batch process ALL downloaded apps in StoreDownloads in one command:
powershell -ExecutionPolicy Bypass -File .\Publish-MECMStoreApp.ps1 -All

# Target a specific app package folder and custom UNC share:
powershell -ExecutionPolicy Bypass -File .\Publish-MECMStoreApp.ps1 `
    -PackagePath ".\StoreDownloads\Windows Terminal\3001.24.11911.0" `
    -ContentShare "\\CM1\Software\Microsoft\Windows Store Apps" `
    -DistributeContent -DPGroupName "All DPs"

# Preview actions without making changes (Dry Run):
powershell -ExecutionPolicy Bypass -File .\Publish-MECMStoreApp.ps1 -All -WhatIf
```

> [!TIP]
> **Device-Wide Provisioning**: `Publish-MECMStoreApp.ps1` automatically configures **[X] Provision this application for all users on the device** on every deployment type via the official Configuration Manager AppManagement SDK (`Microsoft.ConfigurationManagement.ApplicationManagement.Win8Installer.dll` and `SccmSerializer`).

> [!IMPORTANT]
> **Content-share permission preflight**: Before writing package content, the publisher checks the SMB share identified by `-ContentShare`. `Everyone` must have at least **Read** and `BUILTIN\Administrators` must have at least **Change**. If either entry is missing, the script shows the missing rights and prompts before granting only those entries with `Grant-SmbShareAccess`. `-WhatIf` previews the grants without changing the share. Explicit Deny entries are never removed automatically, and staging stops if the required permissions remain unavailable. This validates the SMB share ACL only; configure NTFS permissions separately according to organizational policy.

---

## Understanding the output

Files are organized under `OutDir\<App Name>\<version>\` with their full package identity names:

```text
StoreDownloads\
└─ Windows Terminal\
   └─ 3001.24.11911.0\
      ├─ Microsoft.WindowsTerminal_3001.24.11911.0_neutral_~_8wekyb3d8bbwe.msixbundle
      ├─ Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64__8wekyb3d8bbwe.appx
      └─ Microsoft.UI.Xaml.2.8_8.2501.31001.0_x64__8wekyb3d8bbwe.appx
```

- Framework packages (`Microsoft.VCLibs.*`, `Microsoft.UI.Xaml.*`, `Microsoft.WindowsAppRuntime.*`, `Microsoft.NET.Native.*`) are **dependencies** required by the main application.
- `.msixbundle` / `.appxbundle` and the dependency `.appx` files are what you import or sideload.
- Re-runs are cached: files matching expected size are skipped automatically. Partial files are cleaned and retried.

---

## Disconnected MECM / Intune workflow

1. **Download**: On an internet-connected staging PC, run `Download-StoreApp.ps1` for each app you need (fetches main package + required dependencies).
2. **Transfer**: Copy the resulting package folders into your disconnected environment.
3. **Deploy via MECM**:
   - **Recommended (Automated)**: Run [`Publish-MECMStoreApp.ps1`](Publish-MECMStoreApp.ps1) to stage UNC content, create applications with device-wide provisioning, and build the sequenced **Application Group**.
   - **Testing Cleanup**: Use [`Remove-MECMStoreApp.ps1`](Remove-MECMStoreApp.ps1) during testing to delete toolkit-owned Application Groups, Applications, Console Folders, and staged packages. Current objects carry a `[WindowsStoreOfflineToolkit:v2]` description marker; the remover also recognizes the exact legacy descriptions created by earlier releases. Names alone are never treated as proof of ownership.

> [!CAUTION]
> **Removal confirmation and shared frameworks**: When an application or Application Group is selected, the remover discovers its associated frameworks, labels each one **EXCLUSIVE** or **SHARED**, lists any non-selected consumers, and asks whether eligible frameworks should also be deleted. The final plan separates groups, applications, and frameworks and requires the operator to type `REMOVE` exactly unless `-WhatIf` or the explicit unattended `-Force` switch is used. Target applications with `-AppName`; target frameworks with `-FrameworkName` or interactive `FW1`, `FW2`, and similar selectors. Shared frameworks are excluded by default; `-RemoveSharedFrameworks` is the explicit high-risk override.
   - **Manual Console Setup**: Follow the [MECM Store App Deployment Guide](MECM-Store-App-Deployment-Guide.md) to create native *Windows app package* applications and sequence them in an **Application Group**.

### Mental Model: MSI vs. APPX/MSIX (Device-Targeted Deployments)

| Deployment Model | Traditional MSI / EXE | APPX / MSIX - Provisioned (Recommended) | APPX / MSIX - Not Provisioned |
|---|---|---|---|
| **Scope** | Machine / system | Device-wide provisioning | Per-user registration |
| **MECM Concept** | `Install for system` + `Whether or not a user is logged on` | **"Provision this application for all users on the device"** | Provision option is not selected |
| **User Logged On?** | Not required for a system-context deployment | **Not required**. Package is staged/provisioned at the device level so it is available to all users (existing & new) | **Required**. Registration is associated with user context; fails or skips without active user session |
| **Best Mental Model** | Machine install | **Device-wide app provisioning** | Per-user app registration |

> [!IMPORTANT]
> **Recommended Configuration**: For device-targeted offline APPX/MSIX deployments, always enable **"Provision this application for all users on the device"** on the applicable deployment types. This aligns the Store app deployment with a machine-oriented deployment instead of relying on per-user registration.
>
> **Policy / Content Note**: Changing the provisioning setting updates application/CI policy metadata. If the package files on disk did not change, you do **not** need to redistribute content. Simply trigger a **Machine Policy Retrieval & Evaluation Cycle** on target clients.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `… is not digitally signed` | Run `Get-ChildItem -Recurse \| Unblock-File` or launch with `powershell -ExecutionPolicy Bypass -File …`. |
| `Could not resolve a ProductId from '<name>'` | The input was treated as a literal id. Run with no `-Id` and search by name, or pass the 12-char ProductId directly. |
| `Resolved 0 downloadable packages for arch 'x64'` | The app may only ship a 32-bit or neutral package. Try `-Arch all`. |
| `Connection timed out / failed to respond` | Transient CDN issue. `Download-StoreApp.ps1` will retry automatically up to 3 times with backoff. |
| `No WuCategoryId found …` | The product is not delivered through Store update services (e.g. paid Win32 listings). |
| Raw `SyncUpdates-dump.xml` written | Response shape was unexpected; check the saved dump for details. |

---

## Notes and limitations

- Downloads **free** Store packages only. It does not bypass licensing for paid apps.
- Uses Microsoft delivery endpoints.
- Results can be **region-filtered**; some apps only appear for certain markets.

---

## License

MIT - see [LICENSE](LICENSE).
