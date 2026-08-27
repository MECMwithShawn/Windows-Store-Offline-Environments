# Changelog

All notable changes to the Windows Store Offline Environments toolkit.

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
