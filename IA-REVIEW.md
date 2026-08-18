# Information Assurance Review Package: Windows Store Offline Environments

**Document purpose:** Provide Information Assurance (IA) reviewers, ISSOs,
ISSMs, MECM administrators, and security engineers with a technical description
of the files, execution paths, data flows, network interactions, privileges,
security controls, and residual risks introduced by the **Windows Store Offline
Environments** toolkit.

**Target audience:** Organizations performing STIG-aligned or NIST SP 800-53
Rev. 5-aligned review before use on internet-connected staging systems or in
disconnected enterprise MECM environments.

**Version reviewed:** 2.0

**Release:** Release v2.0

**Source revision reviewed:** `dc1d14d0a0c0af2f412c03af165f110b989ee5b2`
(2026-08-18)

**Review method:** Static source and documentation review. No live Microsoft
delivery request, MECM object creation, package installation, or destructive
cleanup was executed as part of this review.

**Classification of this document:** UNCLASSIFIED // FOR OFFICIAL USE ONLY
(mark according to the reviewing organization's policy)

---

## 1. Executive Summary

### 1.1 System purpose

The toolkit supports a two-zone workflow for acquiring and deploying free
Microsoft Store packages where the destination environment cannot reach the
Microsoft Store:

1. On an internet-connected Windows staging workstation,
   `Download-StoreApp.ps1` resolves Store products and downloads Microsoft-signed
   APPX/MSIX packages and framework dependencies from Microsoft delivery
   services.
2. An administrator transfers the resulting package folders across the
   organization's approved boundary mechanism.
3. In the disconnected environment, `Publish-MECMStoreApp.ps1` stages packages
   on a UNC content source, creates native MECM applications and deployment
   types, enables device-wide provisioning, creates ordered Application Groups,
   and can distribute content.
4. `Set-MECMStoreAppIcons.ps1` can extract package artwork or executable icons
   and assign those icons to MECM objects.
5. `Remove-MECMStoreApp.ps1` can remove deployments, Application Groups,
   applications, console folders, and optionally staged content during testing
   or rollback.

### 1.2 What the toolkit is not

- It is not a persistent endpoint agent or Windows service.
- It does not bypass Microsoft Store licensing or download paid applications.
- It does not install credentials, API keys, certificates, scheduled tasks, or
  autorun entries.
- It is not fully offline during package acquisition. The download phase
  requires outbound HTTPS to Microsoft services and time-limited content URLs.
- It does not independently establish package trust. Windows/MECM ultimately
  enforces package signing, but the downloader does not currently perform a
  post-download SHA-256 or Authenticode validation step.
- It does not provide an approval decision for deployment. The Authorizing
  Official and adopting organization retain that responsibility.

### 1.3 Risk posture summary

| Area | Posture | Summary |
|---|---|---|
| Source code | MODERATE | Four readable PowerShell scripts; no compiled repository binaries or obfuscated logic. |
| Internet acquisition | MODERATE | Anonymous HTTPS calls to Microsoft endpoints; response-derived URLs are filtered, but downloaded bytes are not hash/signature verified by the script. |
| Credentials | LOW | No hardcoded credentials or interactive credential collection found. MECM access uses the operator's existing Windows/MECM context. |
| Privilege | MODERATE | Download can run unprivileged; publish, icon, distribution, and cleanup operations require MECM and share permissions. |
| Persistence | LOW | The toolkit installs no service, task, agent, or autorun mechanism. MECM objects and staged content intentionally persist. |
| Destructive capability | HIGH WHEN INVOKED | Cleanup can delete MECM deployments/objects and recursively remove staged content. `ShouldProcess`, confirmation, and `WhatIf` reduce but do not eliminate operator risk. |
| Data sensitivity | LOW | Processes package metadata, Microsoft-signed app content, MECM metadata, and administrator-selected paths; no business/user data is required. |
| Disconnected transfer | ORGANIZATION CONTROLLED | Media sanitization, malware scanning, hashing, chain of custody, and cross-domain transfer controls are external responsibilities. |

### 1.4 Review disposition

**CONDITIONALLY ACCEPTABLE FOR CONTROLLED PILOT USE.** Before production or
cross-domain use, close or formally accept the open findings in section 12,
especially package-integrity verification and destructive cleanup scoping.

---

## 2. System Architecture

### 2.1 Logical data flow

```text
Internet-connected staging workstation
  |
  | HTTPS: product lookup, search, FE3 SOAP, content download
  v
Microsoft DisplayCatalog / StoreEdge / FE3 / delivery CDN
  |
  | APPX/MSIX files + framework dependencies
  v
Local StoreDownloads directory
  |
  | Organization-approved transfer, scanning, and chain of custody
  v
Disconnected administration workstation / MECM site
  |
  | SMB to approved content-source UNC
  | MECM PowerShell provider / site server operations
  v
MECM applications, deployment types, Application Groups, and DPs
  |
  | Existing MECM content-distribution and client channels
  v
Managed Windows 10/11 devices
```

### 2.2 Trust boundaries

1. **Microsoft service boundary:** Product metadata and time-limited content URLs
   are accepted from Microsoft HTTPS endpoints.
2. **Staging boundary:** Downloaded files are written to an administrator-chosen
   local directory.
3. **Disconnected transfer boundary:** Files leave the connected system and are
   imported using organization-defined removable-media or transfer controls.
4. **MECM administrative boundary:** The operator's MECM RBAC role and content
   share ACL determine what the publishing and cleanup tools can change.
5. **Managed-device boundary:** MECM distributes and provisions signed packages
   using the site's existing client and distribution controls.

---

## 3. Complete Repository File Inventory

| Relative path | Purpose | Execution context | Persistent changes |
|---|---|---|---|
| `Download-StoreApp.ps1` | Resolves Store products, FE3 metadata, download URLs, package identities, architectures, and framework dependencies; downloads selected files. | Windows PowerShell 5.1 or PowerShell 7+; no elevation required for a user-writable output path. | Creates `StoreDownloads\<App>\<Version>` and package files; may write `SyncUpdates-dump.xml` on unexpected metadata. |
| `Publish-MECMStoreApp.ps1` | Copies packages to a UNC source, creates/updates native MECM applications and deployment types, enables all-user provisioning, creates Application Groups, assigns icons, and optionally distributes content. | MECM administrative workstation or site server under the invoking user's Windows/MECM permissions. | UNC content, applications, deployment types, console folders, groups, icon metadata, and optional DP distribution jobs. |
| `Remove-MECMStoreApp.ps1` | Removes selected or all discovered Store application deployments, groups, applications, folders, and optionally staged content. | MECM administrator with delete rights and share delete permissions. | Destructive removal of MECM and filesystem objects selected by parameters. |
| `Set-MECMStoreAppIcons.ps1` | Reads package manifests/assets or extracts executable icons and assigns them to MECM applications/groups. | MECM administrator; reads the content share and writes temporary icon files. | Updates MECM icon metadata; temporary files under `%TEMP%\MECMIcons`. |
| `README.md` | Functional overview, usage, endpoints, and examples. | Documentation only. | None. |
| `MECM-Store-App-Deployment-Guide.md` | Manual and automated deployment guidance. | Documentation only. | None. |
| `Lessons-Learned.md` | Implementation history and troubleshooting knowledge. | Documentation only. | None. |
| `.gitignore` | Excludes downloaded packages, dumps, logs, temporary files, and editor metadata. | Git tooling. | None at runtime. |
| `LICENSE` | MIT license. | Documentation/legal. | None. |
| `IA-REVIEW.md` | This assessment package. | Documentation/audit record. | None. |

No executable, DLL, module package, container image, compiled library, test
fixture, CI workflow, or package-manager lockfile is present in the reviewed
revision.

---

## 4. Component Behavior

### 4.1 `Download-StoreApp.ps1`

The downloader accepts Store URLs, Product IDs, Package Family Names, or search
terms. It:

1. Resolves names through the anonymous StoreEdge manifest-search endpoint.
2. Resolves Product IDs or Package Family Names through DisplayCatalog.
3. Requests an anonymous Windows Update cookie from FE3.
4. calls `SyncUpdates` for update identities and package metadata.
5. calls `GetExtendedUpdateInfo2` for time-limited content URLs.
6. Associates URLs with metadata using the response `FileDigest` identifier.
7. Filters package types, versions, frameworks, and architectures.
8. Writes packages beneath the selected output directory.
9. Retries failed content downloads up to three times.

Existing files are treated as cached when their size equals the expected size,
or when expected size is unknown and the file is non-empty. The script does not
calculate a final file digest or call `Get-AuthenticodeSignature`.

### 4.2 `Publish-MECMStoreApp.ps1`

The publisher parses package identity information, orders framework packages
before consuming apps, and stages each file into a versioned UNC hierarchy. It
uses the Configuration Manager PowerShell module and AppManagement SDK to:

- Create console folders.
- Create applications and native AppX deployment types.
- Set execution context for device-wide provisioning.
- Create sequenced Application Groups.
- Assign icons extracted from package content.
- Optionally start content distribution to a named DP group or DP.

The script supports PowerShell `ShouldProcess`; `-WhatIf` can preview changes.
Staged-file cache decisions are based on file length, not a cryptographic hash.

### 4.3 `Set-MECMStoreAppIcons.ps1`

The icon utility opens APPX/MSIX packages as ZIP archives, parses
`AppxManifest.xml`, handles nested bundles, and prefers an associated executable
icon when available. It falls back to suitable packaged PNG assets. Extracted
files are written under `%TEMP%` and the resulting icon path is supplied to MECM
cmdlets. Package content is treated as untrusted input and should be scanned
before this script is run.

### 4.4 `Remove-MECMStoreApp.ps1`

The cleanup utility discovers MECM applications and Application Groups, allows
interactive or parameter-based selection, removes deployments before their
objects, optionally removes empty console folders, and can delete staged UNC
content. It declares `ConfirmImpact = High`, supports `ShouldProcess`, and
provides `-WhatIf`; `-Force` bypasses prompts.

When `-RemoveStagedContent` is combined with `-All` (or a selection interpreted
as all discovered Store apps), the script recursively deletes every first-level
directory beneath the configured target share. The share must therefore be
dedicated to this toolkit and independently verified before execution.

---

## 5. Network and Communications Security

### 5.1 Outbound endpoints used during acquisition

| Destination | Protocol | Purpose |
|---|---|---|
| `displaycatalog.mp.microsoft.com` | HTTPS/TCP 443 | Product and Package Family Name lookup. |
| `storeedgefd.dsx.mp.microsoft.com` | HTTPS/TCP 443 | Anonymous Store product search. |
| `fe3.delivery.mp.microsoft.com` | HTTPS/TCP 443 | Windows Update FE3 SOAP operations (`GetCookie`, `SyncUpdates`, `GetExtendedUpdateInfo2`). |
| `*.delivery.mp.microsoft.com` | HTTPS expected/TCP 443 | Time-limited package content download. |
| `*.windowsupdate.com` | HTTPS expected/TCP 443 | Alternate Microsoft update content locations accepted by the script. |

The script has no listening port and creates no firewall rule. It sends Store
identifiers, release-ring selection, architecture preferences, fixed Windows
Update device attributes, and anonymous SOAP ticket data. It does not send user
credentials or repository secrets.

### 5.2 MECM-side communications

- SMB/TCP 445 from the administrative system to the configured content-source
  UNC path.
- Configuration Manager PowerShell provider and site-server communications as
  defined by the existing MECM architecture.
- Optional MECM distribution from the site to DPs using existing site roles and
  configured transport controls.

### 5.3 Inbound communications

None are created by this toolkit. It does not host HTTP, RPC, SMB, or other
network services.

### 5.4 Disconnected-network suitability

The publish, icon, and cleanup stages have no deliberate Internet dependency.
However, disconnected suitability depends on the adopting organization's
approved transfer process, package signature validation, malware scanning, and
root/intermediate certificate availability on destination devices.

---

## 6. Identity, Authentication, and Credentials

- No usernames, passwords, client secrets, API keys, access tokens, private
  certificates, or connection strings were found in the reviewed source.
- Microsoft acquisition calls are anonymous and use the Windows Update ticket
  structure embedded by the script.
- Access to the local output path uses the invoking user's filesystem token.
- Access to the UNC share uses the invoking user's Windows credentials; the
  scripts do not collect or persist alternate credentials.
- MECM changes execute under the invoking user's Configuration Manager RBAC and
  provider permissions.
- Target-device installation uses existing MECM client execution policy and is
  normally performed as SYSTEM when device-wide provisioning is selected.

**IA requirement:** Use a dedicated administrative account and least-privilege
MECM security role. Do not run the publishing or cleanup scripts from a routine
user account or with broader share permissions than required.

---

## 7. Privilege and Access-Control Requirements

| Operation | Minimum expected privilege |
|---|---|
| Download packages | Write permission to `OutDir`; outbound HTTPS access. |
| Read and transfer packages | Read permission to download output and access to the approved transfer mechanism. |
| Stage MECM content | Create/write permission beneath the dedicated content-source share. |
| Create applications/groups | MECM RBAC rights for applications, deployment types, folders, and Application Groups. |
| Distribute content | MECM distribution permissions for the selected DP/DP group. |
| Assign icons | Read access to packages and modify rights on target MECM objects. |
| Cleanup MECM objects | Delete rights for deployments, groups, applications, and folders. |
| Cleanup staged content | Recursive delete permission beneath the dedicated content-source root. |

No script enforces a specific security group or RBAC role. Enforcement is
delegated to Windows ACLs, share ACLs, and MECM RBAC.

---

## 8. File-System and Configuration Interactions

### 8.1 Local writes

| Path | Content | Retention |
|---|---|---|
| `<OutDir>\<App>\<Version>\*` | Downloaded APPX/MSIX bundles and dependencies. | Until manually removed. |
| `<OutDir>\SyncUpdates-dump.xml` | Unexpected FE3 response used for troubleshooting. | Manual; may contain update metadata and URLs. |
| `%TEMP%\MECMIcons\*` | Extracted PNG or executable-associated icons. | Not consistently removed at script completion. |
| `%TEMP%\MECM_*` and nested bundle extracts | Temporary package/executable content. | Best-effort deletion in normal/error paths. |

### 8.2 UNC writes

`Publish-MECMStoreApp.ps1` creates versioned package directories beneath
`ContentShare`, including a shared `_Frameworks` hierarchy. Existing destination
files with equal length are skipped; differing files are overwritten.

### 8.3 MECM writes

- Applications and native AppX deployment types.
- Device-wide provisioning execution-context metadata.
- Application Groups and ordered membership.
- Console-folder hierarchy and object placement.
- Application and Application Group icons.
- Optional content-distribution requests.

### 8.4 Registry, service, and task changes

None were found. The toolkit does not directly write the registry, install a
service, create a scheduled task, or configure an autorun entry.

---

## 9. Data Types and Protection Requirements

| Data type | Sensitivity | Protection consideration |
|---|---|---|
| Store product identifiers and metadata | Public/low | Retain only as operationally necessary. |
| APPX/MSIX package content | Public software, integrity-sensitive | Verify provenance, hash, and signing chain before boundary transfer and deployment. |
| Time-limited content URLs | Low to moderate | URLs may contain ephemeral authorization/query data; avoid unnecessary logging or ticket attachment. |
| FE3 troubleshooting XML | Low to moderate | Review before sharing because it may include response metadata and temporary URLs. |
| MECM names, site code, server names, UNC paths | Internal configuration | Do not publish environment-specific logs without sanitization. |
| Temporary executable/icon extracts | Untrusted content | Store on protected admin systems; remove after use; scan before execution or rendering. |

The toolkit does not intentionally process PII, PHI, CUI, classified data, or
end-user content.

---

## 10. External Dependencies and Supply Chain

### 10.1 Runtime dependencies

- Windows PowerShell 5.1 or PowerShell 7+.
- In-box .NET XML, ZIP, filesystem, networking, and drawing APIs.
- Microsoft Configuration Manager console and `ConfigurationManager.psd1` for
  MECM operations.
- Configuration Manager AppManagement SDK assemblies used to set the AppX
  execution context.
- Microsoft Store/Windows Update services during acquisition.
- Microsoft-signed APPX/MSIX packages and framework dependencies.

### 10.2 Dependencies not present

- No npm, pip, NuGet, Chocolatey, Winget, or PowerShell Gallery installation.
- No vendored third-party module or compiled binary in the repository.
- No external JavaScript, analytics, telemetry, advertising, or CDN-hosted UI.

### 10.3 Supply-chain controls required

1. Pin the reviewed Git commit or signed release tag.
2. Record SHA-256 hashes for the four scripts and the complete transfer set.
3. Verify Authenticode signatures for every APPX/MSIX package and bundle.
4. Validate package Publisher/PublisherId against the approved application list.
5. Scan transferred content using approved malware tooling on both sides of the
   boundary.
6. Preserve a signed manifest or equivalent chain-of-custody record.
7. Re-run review when Microsoft endpoint behavior or script logic changes.

---

## 11. Security Controls Present

| Control | Implementation |
|---|---|
| Human-readable source | Four PowerShell scripts; no obfuscation or repository binary payloads. |
| Parameter constraints | Release ring and architecture parameters use `ValidateSet`. |
| HTTPS service URLs | Catalog, search, and FE3 endpoints are declared as HTTPS. |
| Content-host filter | Response URLs are accepted only when matching Microsoft delivery or Windows Update patterns. |
| No embedded credentials | Static review found no operational credentials or secret storage. |
| Change preview | Publisher, icon tool, and cleanup tool implement `ShouldProcess`; `-WhatIf` is available. |
| Destructive confirmation | Cleanup declares `ConfirmImpact = High`; `-Force` is explicit. |
| Dependency ordering | Frameworks are ordered before consuming applications. |
| Architecture filtering | Default is x64 with neutral packages where appropriate. |
| Encrypted-copy exclusion | Encrypted package variants are excluded unless explicitly requested. |
| Retry cleanup | Failed partial downloads are removed before retry. |
| Native MECM deployment type | Uses MECM's AppX/MSIX deployment model and existing client enforcement. |
| No persistence mechanism | No services, scheduled tasks, or autorun changes. |

---

## 12. Findings and Required Actions

### IA-01 — Downloaded package integrity is not cryptographically verified

**Severity:** HIGH

**Confidence:** HIGH

**Status:** OPEN

FE3 metadata exposes a `FileDigest`, and the script uses that digest as a key to
associate a returned URL with package metadata. After download, however, the
script only treats the web request as successful; cached files are accepted by
length. It does not compute SHA-256, compare a trusted digest, or validate the
APPX/MSIX Authenticode signature and publisher.

**Impact:** A corrupted, substituted, stale, or locally modified same-size file
could pass the script's cache logic and be staged for MECM. Windows deployment
may reject an invalid signature, but that is a late control and does not provide
transfer-manifest evidence.

**Required action:** Add post-download and pre-publish validation that computes
and records SHA-256, verifies the digest against authoritative metadata where
the encoding is correctly interpreted, validates the package signature and
certificate chain, and checks the publisher against an allowlist. Treat any
validation failure as fatal.

### IA-02 — Destructive content cleanup has a broad share-wide mode

**Severity:** HIGH

**Confidence:** HIGH

**Status:** OPEN

When `Remove-MECMStoreApp.ps1` is run with staged-content removal and its
selection is interpreted as all applications, it recursively deletes every
first-level directory beneath `ContentShare`. `ShouldProcess`, high confirmation
impact, and `WhatIf` are present, but `-Force` can bypass confirmation.

**Impact:** A mistyped or shared UNC root can cause deletion of unrelated source
content and corresponding operational outage.

**Required action:** Require a toolkit-owned sentinel file and canonical path
validation before recursive deletion; refuse share roots and administrative
shares; enumerate the exact candidate paths; require a second explicit switch
for share-wide cleanup; and document tested restoration procedures. Use a
dedicated share or dedicated subdirectory with independent backups.

### IA-03 — Content URL allowlisting is pattern-based and permits `http*`

**Severity:** MEDIUM

**Confidence:** HIGH

**Status:** OPEN

The content filter uses wildcard string matching for host text and accepts a
scheme matching `http*`. It does not parse the URI and compare `Scheme`, exact
host, or a dot-boundary suffix.

**Impact:** If upstream response integrity were compromised or behavior changed,
a URL containing the approved hostname text in an untrusted host or using plain
HTTP could be accepted.

**Required action:** Parse every URL as `System.Uri`; require scheme `https`;
compare the normalized host to exact approved hosts or a dot-boundary Microsoft
suffix; reject userinfo, non-default ports, malformed URIs, and redirects to
unapproved hosts.

### IA-04 — Equal-size files are trusted as valid cache/staging matches

**Severity:** MEDIUM

**Confidence:** HIGH

**Status:** OPEN

Both download caching and UNC staging skip existing files based on length. File
length is not an integrity check.

**Impact:** A different file of equal size can remain in the pipeline without
being detected by these scripts.

**Required action:** Use SHA-256 comparison for cache and staging decisions and
persist a transfer manifest containing relative path, size, digest, publisher,
and signing status.

### IA-05 — Operational logging is console-only and not tamper-evident

**Severity:** MEDIUM

**Confidence:** HIGH

**Status:** OPEN

The scripts primarily emit `Write-Host`, warning, and verbose messages. They do
not create a structured, signed, append-only audit record of downloads,
validation decisions, MECM object changes, distribution requests, or deletions.

**Impact:** Change reconstruction depends on terminal capture, MECM logs, file
server logs, and operator notes.

**Required action:** Add structured JSON/CSV logging with UTC timestamps,
operator identity, host, script/commit version, parameters with sensitive query
data removed, target paths/object IDs, hashes, validation outcomes, and results.
Forward or archive logs under organizational retention controls.

### IA-06 — Repository scripts are unsigned and guidance uses execution-policy bypass

**Severity:** MEDIUM

**Confidence:** HIGH

**Status:** OPEN / ORGANIZATIONAL CONTROL

The repository distributes source scripts without Authenticode signatures, and
examples invoke PowerShell with `-ExecutionPolicy Bypass`.

**Impact:** Execution policy does not provide a trust decision, and modified
scripts may execute if operators rely on bypass-based instructions.

**Required action:** Sign approved scripts using organizational code-signing
PKI, deploy the issuing chain, enforce an appropriate PowerShell policy, enable
Script Block Logging and Module Logging, and replace bypass examples in the
production runbook.

### IA-07 — Temporary icon/executable artifacts are not centrally cleaned

**Severity:** LOW

**Confidence:** MEDIUM

**Status:** OPEN

Icon workflows extract data beneath `%TEMP%\MECMIcons` and may temporarily
extract executable content. Some temporary files are removed through best-effort
paths, but a final cleanup of the icon directory is not guaranteed.

**Impact:** Residual package artifacts can persist on an administrative system
and may be consumed by a later run.

**Required action:** Use a unique per-run temporary directory, validate the
resolved path remains under that directory, and delete it in a `finally` block.

---

## 13. Known Limitations and Compensating Controls

| Limitation | Compensating control |
|---|---|
| No package hash/signature verification in current scripts | Perform independent signature and SHA-256 validation before transfer and before publish; retain results. |
| Anonymous Microsoft endpoints may change without notice | Restrict egress, monitor failures, pin reviewed script versions, and re-review protocol changes. |
| Time-limited CDN URLs are operationally sensitive | Do not persist raw responses longer than needed; sanitize support bundles. |
| Cleanup can make broad changes | Dedicated share, `-WhatIf`, peer review, verified backup, maintenance window, and no `-Force` in production. |
| No built-in rollback transaction | Export MECM applications/groups and back up content before mutation; document restoration. |
| MECM permissions are environment-defined | Use least-privilege RBAC and separate publisher/remover roles where practical. |
| No automated test suite in the repository | Perform lab validation against a nonproduction MECM site for each release. |
| External Microsoft package dependencies | Maintain approved product/publisher inventory and destination certificate chain. |

---

## 14. Logging, Monitoring, and Audit Trail

### 14.1 Native evidence sources

| Source | Expected evidence |
|---|---|
| PowerShell Operational log | Script block/module activity when organizational logging is enabled. |
| MECM provider/site logs | Application, deployment type, group, content, and distribution operations. |
| Windows Security log | Administrative logon and share access, subject to audit policy. |
| File server auditing | UNC directory creation, writes, overwrites, and deletes. |
| Proxy/firewall logs | Microsoft endpoint destinations, time, source, and transferred volume. |
| Endpoint protection | File scanning and detections on staging/admin systems. |
| Change-management record | Approved products, versions, hashes, operator, transfer, and deployment window. |

### 14.2 Required audit configuration

1. Enable PowerShell Script Block Logging, Module Logging, and transcription on
   staging and MECM administrative systems according to policy.
2. Audit write/delete access on the dedicated content source.
3. Retain MECM administrative and distribution logs for the change-record period.
4. Capture firewall/proxy logs for acquisition endpoints.
5. Record source revision, script hashes, downloaded-package hashes, signing
   status, and transfer-media identifier in the change ticket.
6. Alert on use of `Remove-MECMStoreApp.ps1 -Force` or share-wide cleanup.

---

## 15. Incident Response Considerations

### 15.1 Suspected package compromise

1. Stop deployment and distribution of the affected application/group.
2. Record hashes and preserve the staging and transferred copies.
3. Compare Authenticode publisher, chain, timestamp, and SHA-256 against a fresh
   acquisition from an independently trusted system.
4. Review proxy, PowerShell, antimalware, file server, and MECM logs.
5. Remove or supersede affected content through the approved MECM process.
6. Assess devices that received the content and invoke organizational incident
   handling if package execution occurred.

### 15.2 Accidental cleanup or deletion

1. Stop further cleanup runs and preserve console/transcript evidence.
2. Identify the exact UNC root, deleted folders, MECM CI IDs, deployments, and
   groups from logs and backups.
3. Restore content from the verified source manifest or backup.
4. Restore/import MECM objects according to the site's recovery procedure.
5. Validate DP content and client policy before resuming deployment.

### 15.3 Unauthorized MECM change

1. Disable or restrict the implicated administrative account.
2. Review MECM RBAC assignments and provider/audit logs.
3. Compare current objects with approved exports and change records.
4. Revoke affected deployments and restore approved configuration.

---

## 16. Removal and Rollback

The toolkit itself is source code and requires no uninstall. Remove local script
copies and downloaded packages according to media and records-retention policy.

For toolkit-created MECM state:

1. Export or back up applications and Application Groups before removal.
2. Run `Remove-MECMStoreApp.ps1` with `-WhatIf` and capture the complete target
   list.
3. Obtain peer approval for the exact MECM objects and filesystem paths.
4. Remove deployments before groups/applications during an approved window.
5. Remove staged content only from a dedicated, verified toolkit root.
6. Validate that unrelated applications, groups, folders, source content, and DP
   content remain intact.
7. Restore from the export/backup if verification fails.

Do not use `-Force`, `-All`, and `-RemoveStagedContent` together in production
without an approved destructive-change procedure and tested recovery point.

---

## 17. NIST SP 800-53 Rev. 5 Mapping (Informative)

This mapping identifies relevant controls and expected evidence; it is not a
claim of compliance.

| Control | Applicability | Implementation/evidence |
|---|---|---|
| AC-2 Account Management | Administrative accounts are external to the toolkit. | AD and MECM account-management records. |
| AC-3 Access Enforcement | Filesystem/share ACLs and MECM RBAC govern access. | ACL exports and MECM security-role assignments. |
| AC-5 Separation of Duties | Acquisition, transfer approval, publishing, and cleanup should be separated. | Change workflow and role assignments. |
| AC-6 Least Privilege | Download needs no admin; mutation requires scoped MECM/share rights. | Tested RBAC role and ACL design. |
| AU-2 Event Logging | Native PowerShell, Windows, file server, proxy, and MECM logs apply. | Audit configuration and retained events. |
| AU-3 Content of Audit Records | Additional structured application logging is recommended. | Finding IA-05 and change records. |
| AU-6 Audit Review, Analysis, and Reporting | Review downloads, mutations, and cleanup events. | SOC/admin review procedure. |
| AU-9 Protection of Audit Information | Logs must be forwarded or access-controlled externally. | SIEM/log-server controls. |
| CM-2 Baseline Configuration | Pin commit, scripts, allowed endpoints, products, and publishers. | Approved baseline and hash manifest. |
| CM-3 Configuration Change Control | MECM mutations require approved change control. | Change ticket, `WhatIf` output, rollback record. |
| CM-5 Access Restrictions for Change | MECM RBAC and share ACLs restrict modification. | RBAC/ACL evidence. |
| CM-7 Least Functionality | No service, agent, listener, or package manager is introduced. | Repository inventory and static review. |
| CM-8 System Component Inventory | Packages and framework dependencies must be inventoried. | Transfer manifest and MECM application inventory. |
| IA-2 Identification and Authentication | Existing Windows and MECM identities are used. | AD authentication and MECM RBAC records. |
| SC-7 Boundary Protection | Acquisition egress must be limited to approved Microsoft services. | Firewall/proxy allowlist and logs. |
| SC-8 Transmission Confidentiality and Integrity | Acquisition uses HTTPS; SMB protections are environment-controlled. | TLS/proxy policy and SMB signing/encryption policy. |
| SC-18 Mobile Code | APPX/MSIX packages are executable content crossing a boundary. | Approved publisher list, signature validation, malware scan. |
| SI-2 Flaw Remediation | Store packages and toolkit revisions require controlled updates. | Patch/change process. |
| SI-3 Malicious Code Protection | Download and transfer content requires scanning. | Antimalware logs and transfer-station evidence. |
| SI-7 Software, Firmware, and Information Integrity | Current script lacks complete hash/signature enforcement. | Findings IA-01 and IA-04; proposed manifest. |
| SR-3 Supply Chain Controls and Processes | Microsoft/package provenance and toolkit source must be controlled. | Commit pinning, signing verification, transfer chain of custody. |
| SR-11 Component Authenticity | Validate APPX/MSIX signatures and publishers. | Signature reports and approved publisher list. |

---

## 18. IA Review Checklist

### 18.1 Source and documentation

- [ ] Confirm reviewed commit equals
  `dc1d14d0a0c0af2f412c03af165f110b989ee5b2` or document deltas.
- [ ] Review all four PowerShell files line-by-line.
- [ ] Review `README.md`, deployment guide, and lessons learned.
- [ ] Confirm no unreviewed binaries, modules, or generated scripts were added.
- [ ] Run an approved secret scanner and malware scanner.
- [ ] Parse all scripts without PowerShell syntax errors.

### 18.2 Acquisition boundary

- [ ] Restrict staging-system egress to approved Microsoft endpoints.
- [ ] Require HTTPS and validate redirects against the allowlist.
- [ ] Validate SHA-256 for every downloaded file.
- [ ] Validate Authenticode signature, certificate chain, and approved publisher.
- [ ] Review and sanitize `SyncUpdates-dump.xml` before sharing.
- [ ] Record product ID, version, architecture, filename, size, and hash.

### 18.3 Disconnected transfer

- [ ] Use an approved transfer system or removable-media process.
- [ ] Scan on both connected and disconnected sides.
- [ ] Verify the signed hash manifest after transfer.
- [ ] Preserve chain of custody and media identification.
- [ ] Confirm imported certificates and revocation policy meet local requirements.

### 18.4 MECM publication

- [ ] Use a dedicated least-privilege MECM role.
- [ ] Use a dedicated content-source root with restrictive ACLs.
- [ ] Run publish with `-WhatIf` and peer-review the output.
- [ ] Validate application names, versions, architecture, and dependency order.
- [ ] Confirm device-wide provisioning is authorized.
- [ ] Pilot on a nonproduction collection before broad deployment.
- [ ] Verify package install, detection, uninstall, and rollback behavior.

### 18.5 Cleanup and recovery

- [ ] Back up/export target MECM objects.
- [ ] Back up staged content or retain the verified transfer set.
- [ ] Run cleanup with `-WhatIf` and record exact targets.
- [ ] Verify the canonical content root is dedicated to this toolkit.
- [ ] Do not use `-Force` without approved emergency/destructive change authority.
- [ ] Test restoration of applications, groups, deployments, and content.

### 18.6 Production authorization

- [ ] All findings are remediated, mitigated, or formally accepted.
- [ ] ISSO/ISSM review is complete.
- [ ] Authorizing Official approval is recorded.
- [ ] Change window and rollback owner are assigned.
- [ ] Post-deployment review date is scheduled.

---

## 19. Document Control and Sign-off

| Field | Value |
|---|---|
| Toolkit | Windows Store Offline Environments |
| Toolkit version | 2.0 |
| Source revision | `dc1d14d0a0c0af2f412c03af165f110b989ee5b2` |
| IA document version | 1.0 |
| Last updated | 2026-08-18 |
| Review scope | Static source and documentation review |
| Classification | UNCLASSIFIED // FOR OFFICIAL USE ONLY (organization-defined) |
| Current disposition | Conditionally acceptable for controlled pilot; findings open |
| Next review | On source change, endpoint/protocol change, or annually |

### Points of contact

| Role | Name | Contact |
|---|---|---|
| Toolkit maintainer | Shawn Brooks / MECMwithShawn | *(organization to complete)* |
| MECM service owner | | |
| Content-share owner | | |
| Information System Security Officer | | |
| Information System Security Manager | | |
| Authorizing Official | | |

### Approval record

| Role | Decision | Name/signature | Date |
|---|---|---|---|
| Technical reviewer | Pending | | |
| IA/ISSO reviewer | Pending | | |
| System owner | Pending | | |
| Authorizing Official | Pending | | |

---

**Prepared for formal organizational review. This document does not itself
authorize deployment.**
