# Lessons Learned: MECM Store App Offline Environments

This document serves as a technical post-mortem and knowledge base, capturing the undocumented edge-cases, workarounds, and hard lessons learned while building this offline Store App deployment toolkit.

---

## 1. The "Tiny Icon" Phenomenon (Plated vs. Unplated PNGs)
When extracting icons directly from an `.msix` or `.appx` package, picking the highest resolution logo (e.g., `Square150x150Logo.scale-400.png`) seems logical but results in **microscopic, tiny icons** when viewed in Software Center.

* **The Cause:** UWP/Store apps use two distinct types of image assets:
  * **Scale Tiles (`.scale-XXX`)**: Designed for Windows Start Menu Tiles. They feature a tiny logo floating in the center of a massive transparent box (the "plate"). When MECM shrinks a 300x300 plated tile down to 64x64, the actual logo becomes smaller than 10x10 pixels.
  * **Targetsize Icons (`.targetsize-XXX_unplated`)**: Designed for taskbars and lists. These have zero padding and fill the entire image boundary.
* **The Solution:** Always search the package entries for `targetsize` and `unplated` keywords. The script now aggregates all matches and scores them, heavily prioritizing a `targetsize-256_unplated` asset over a `scale-200` asset.

## 2. Premium 3D Icons vs. Flat UWP Silhouettes
Even with unplated PNGs, Windows 11 UWP apps (like Notepad) often ship with very simple, flat, monochromatic `.png` assets in their `.msix` container, which look dull in Software Center. However, the premium, shadowed 3D icons are usually stored inside the application's executable file (`.exe`).

* **The Cause:** The OS maintains rich 3D `.ico` files in the execution aliases (e.g., `C:\Windows\System32\notepad.exe`) or directly in the binary, while the Store XML manifest relies on the flat SVG/PNGs.
* **The Solution:** The script employs a cascading fallback strategy for premium icons:
  1. Parse `AppxManifest.xml` to find the `Executable="..."` filename.
  2. Check if that exact executable exists in `C:\Windows\System32\` (e.g., the Windows 11 execution alias). If found, use `[System.Drawing.Icon]` to extract the premium 3D icon.
  3. If not in System32 (e.g., Windows Terminal), extract the `.exe` directly out of the `.msix` ZIP archive and pull its `.ico` via System.Drawing.
  4. Only fall back to the flat UWP PNGs if no executable exists (e.g., Framework packages like `VCLibs`).

## 3. MECM's Strict 512x512 Icon Limit
MECM Software Center enforces a strict maximum image dimension of **512x512 pixels** for Application icons.
* **The Cause:** Extracting a `Square150x150Logo` at `scale-400` yields a 600x600 pixel image. Passing this file path to `Set-CMApplication` will cause the cmdlet to silently drop the icon or throw cryptic WMI constraint violations.
* **The Solution:** The script strictly filters candidate PNGs to ensure they never exceed the 512px threshold (e.g., capping 150x150 tiles at `scale-200`).

## 4. The PowerShell CM Provider (`CHQ:`) Path Bug
Standard PowerShell cmdlets (`Get-ChildItem`, `Test-Path`) fail catastrophically when attempting to resolve or query UNC paths if the user's current working directory is inside the MECM Site drive (e.g., `CHQ:\`).
* **The Cause:** The Configuration Manager PowerShell provider hijacks path resolution and incorrectly parses UNC network shares as CM-provider drives, throwing `Illegal characters in path` or `Provider not found` errors.
* **The Solution:** Completely abandon PowerShell file cmdlets when interacting with the file system during an MECM session. Instead, rely exclusively on raw .NET Base Class Library methods (`[System.IO.Directory]::GetFiles()`, `[System.IO.File]::Exists()`).

## 5. MSIX/AppX Bundle Internal Architecture
Attempting to read `AppxManifest.xml` from an `.msixbundle` or `.appxbundle` file will fail because it does not exist at the root.
* **The Cause:** Bundles are outer wrappers containing multiple inner `.msix` payloads (one for each architecture). The root only contains an `AppxMetadata/AppxBundleManifest.xml` which lacks icon declarations.
* **The Solution:** You must parse the bundle XML, find the payload matching the desired architecture (e.g., `x64.msix`), extract that inner ZIP to a temp folder, and *then* recursively parse its `AppxManifest.xml` to find the assets.

## 6. Native AppX Deployment vs. Wrapper Scripts
Historically, administrators wrote custom wrapper scripts (like `Install-StoreAppOffline.ps1`) to handle installing `.appx` dependencies and executing `Add-AppxProvisionedPackage`. 
* **The Lesson:** This is entirely obsolete for MECM. By using `Add-CMAppxDeploymentType`, MECM natively registers the package as a Windows Store app deployment. If the "Provision this application for all users" flag is set, the `ccmexec` client natively handles extracting the dependencies, matching the architecture, and executing the machine-wide provisioning directly. Bundling these deployment types into a native **Application Group** handles the install sequencing perfectly.

## 7. Application Group vs. Application XML Parsing
When trying to dynamically read the members of an MECM Application Group (to assign them a group icon), the standard XML parsing logic fails.
* **The Cause:** Standard Deployment Types use `<ApplicationRef>` to link items in their `SDMPackageXML`. Application Groups do not use this; they track nested applications using `<ObjectId>` tags.
* **The Solution:** Use Regex to extract the IDs from `<ObjectId>` nodes and match them against `Get-CMApplication -Id` to reliably map group members back to their underlying application objects.
