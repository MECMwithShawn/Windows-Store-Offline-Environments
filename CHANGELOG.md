# Changelog

All notable changes to the Windows Store Offline Environments toolkit.

---

## Unreleased

### App Installer / winget can be downloaded by name

`Download-StoreApp.ps1`

App Installer (ProductId `9NBLGGH4NNS1`, the package that ships winget) is not
returned by Store search, so `-Id winget` and `-Id Microsoft.DesktopAppInstaller`
ended in "No Store matches". Name input is now resolved in this order: a small
alias table (`winget`, `App Installer`), then a DisplayCatalog lookup of a dotted
package name as `<Name>_8wekyb3d8bbwe`, then Store search as before.

### Framework applications detect "this version or newer"

`Publish-MECMStoreApp.ps1`

The native AppX deployment type detects the exact package version. A device
that already had a newer framework provisioned (for example UI.Xaml 2.8
8.2511.26001.0 when MECM publishes 8.2501.31001.0) was evaluated NotInstalled;
MECM then tried to provision the older package, Windows refused it with
`0x800700B7`, and the Application Group stopped at that member, so the main app
was never evaluated.

Framework applications (VCLibs, .NET Native, UI.Xaml, WindowsAppRuntime) now get
a second, priority-1 deployment type, `<App> - Script (version or newer)`:

- Detection: compliant only when that package name and architecture is
  provisioned for all users (`Get-AppxProvisionedPackage -Online`) at the staged
  version or newer. Per-user or SYSTEM-staged copies do not count.
- Install: `Add-AppxProvisionedPackage -Online -PackagePath .\<file> -SkipLicense`,
  as System, from the same content folder as the native deployment type.

The native AppX deployment type is unchanged and stays at priority 2. The script
deployment type is added when an application is created, when its first
deployment type is created, and is re-pointed with `-UpdateExisting`. An
existing, unchanged application is left as it is and the run prints a notice.
`-FrameworkExactVersionOnly` restores the v2.1 behaviour. `-WhatIf` prints each
generated deployment type, including its detection script.

---

## v2.1

Two defects, both of the same kind: an operation that reported success while
leaving the environment in a state nobody was told about.

### Version upgrades no longer publish silently

`Publish-MECMStoreApp.ps1`

Applications are named by package identity with **no version**
(`Microsoft.WindowsTerminal`, not `Microsoft.WindowsTerminal 1.24.x`), so a newly
downloaded build matches the application created from the older one.

Before this release, re-running the publisher after downloading a new version:

1. copied the new package to the content share under `v.<newversion>`
2. found the existing application and its deployment type
3. printed **`already exists in MECM with deployment type. Reusing.`** in green
4. changed nothing - no content-location update, no `SoftwareVersion` update

The deployment type still pointed at the previous package, so **devices kept
receiving the old version**, while the operator saw a green success line and
fresh content sitting on the share. The manual console fix was documented in the
deployment guide, but nothing in the run indicated it was now required.

The publisher now compares the staged version against the application's
published `SoftwareVersion`:

- **`-UpdateExisting`** (new switch) updates the deployment type's content
  location via `Set-CMWindowsAppxDeploymentType` and the application's
  `SoftwareVersion` via `Set-CMApplication`, then reminds you to redistribute
  content so distribution points serve the new package.
- **Without it**, the version difference is reported at the point it is found
  *and* repeated in an **ACTION REQUIRED** block at the end of the run, naming
  every affected application as `published X -> staged Y`. A warning printed
  mid-run scrolls away on a multi-application publish; the summary is what stops
  someone walking away believing the new build shipped.
- The closing line is now conditional - `Completed with actions outstanding`
  rather than an unconditional "All applications processed and provisioned
  successfully."

Matching versions still report `Reusing` in green, because there the message is
true.

### Toolkit ownership marker accepts dotted versions

`Remove-MECMStoreApp.ps1`

The remover proves ownership from the `[WindowsStoreOfflineToolkit:vN]`
description marker and **never** from an object's name. Its pattern was
`^\[WindowsStoreOfflineToolkit:v\d+\]\s+`, which matches `v2` but **not** `v2.1`.

Stamping this release's marker without widening that pattern would have made the
remover stop recognising every object the publisher creates - a silent refusal to
clean anything, on a script whose entire safety model rests on that marker. The
pattern is now `v[\d.]+`, which matches both, so objects created by earlier
releases stay removable.

### Documentation

- `README.md` - release badge, an upgrade example, and a warning explaining why
  upgrades need `-UpdateExisting`
- `MECM-Store-App-Deployment-Guide.md` - *Updating to a new version* rewritten
  around the scripted path, with the manual console options kept
- `IA-REVIEW.md` - marker description updated to the dotted form
- Release notes added to each script's comment-based help

### Unchanged by design

- **Detection remains native AppX identity** (`Add-CMAppxDeploymentType`), which
  exposes no version literal and is therefore structurally immune to the
  bundle-versus-inner-version mismatch that produces `0x87D00324` ("installed but
  not detected"). Script-based detection with a version literal would reintroduce
  it.
- **"Provision this application for all users on the device"** stays enabled on
  every deployment type.
- **No application deployment is created.** The publisher creates applications,
  deployment types and Application Groups and distributes content; deploying to a
  collection stays a deliberate console decision.
- `Download-StoreApp.ps1` is functionally unchanged in this release.

---

## v2.0

- Toolkit ownership marker (`[WindowsStoreOfflineToolkit:v2]`) written into
  application and Application Group descriptions, so cleanup can prove ownership
  rather than inferring it from names
- Content-share permission preflight before staging
- Application icons extracted from package payloads
- Console folder hierarchies for Applications and Application Groups
