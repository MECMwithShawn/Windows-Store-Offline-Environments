<#
.SYNOPSIS
    Downloads Microsoft Store app packages and their dependencies by querying the
    anonymous FE3 (Windows Update delivery) SOAP service. No Microsoft account
    or auth required.

.DESCRIPTION
    Pipeline:
      1. Resolve a Store URL / ProductId to a WuCategoryId via DisplayCatalog.
      2. GetCookie         -> session cookie from FE3.
      3. SyncUpdates       -> list of package update identities + AppxMetadata.
      4. GetExtendedUpdateInfo2 -> real download URLs, matched to filenames by
         SHA-256 file digest.
      5. Download .appx / .appxbundle / .msix / .msixbundle (+ dependencies).

.PARAMETER Id
    A Store product link, a 12-char ProductId (e.g. 9WZDNCRFJBMP), or a
    PackageFamilyName. Examples:
      https://apps.microsoft.com/detail/9WZDNCRFJBMP
      9WZDNCRFJBMP
      Microsoft.WindowsCalculator_8wekyb3d8bbwe

.PARAMETER Ring
    Release ring: Retail (default), RP, WIS, WIF.

.PARAMETER Arch
    Architecture filter for downloads: x64 (default), all, x86, arm, arm64, neutral.

.PARAMETER OutDir
    Output folder. Defaults to .\StoreDownloads

.EXAMPLE
    .\Download-StoreApp.ps1 -Id 9WZDNCRFJBMP

.EXAMPLE
    .\Download-StoreApp.ps1 -Id 9WZDNCRFJBMP -Arch all

.NOTES
    Run on a machine WITH internet (e.g. your staging host), then move the
    resulting packages into your disconnected MECM environment. The FE3 endpoint
    and DisplayCatalog must be reachable.
#>

[CmdletBinding()]
param(
    # One or more Store URLs / ProductIds / PackageFamilyNames. If omitted,
    # the script prompts interactively.
    [string[]]$Id,

    [ValidateSet('Retail','RP','WIS','WIF')]
    [string]$Ring = 'Retail',

    [ValidateSet('all','x64','x86','arm','arm64','neutral')]
    [string]$Arch = 'x64',

    [string]$OutDir = (Join-Path $PWD 'StoreDownloads'),

    # By default keep only the newest build of each package family and skip
    # encrypted (.eappx*/.emsix*) copies. Use these to get everything.
    [switch]$AllVersions,
    [switch]$IncludeEncrypted,

    # Download only the main app package, skipping framework dependencies
    # (.NET.Native, VCLibs, UI.Xaml, WindowsAppRuntime). Use when targets already have them.
    [switch]$MainPackageOnly,

    # Collapse each framework LINE to its newest major (e.g. Framework 1.7+2.2
    # -> 2.2 only, UI.Xaml 2.4+2.8 -> 2.8 only). Smaller set, but may drop a
    # framework an app actually requires. Off by default.
    [switch]$LatestFrameworkOnly,

    # Re-download even if a matching file is already present on disk.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13 } catch { }

$FE3 = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx'

# --- Anonymous WU ticket (the trick that lets this work with no account) ------
$AnonTicket = @'
<TicketType Name="AAD" Version="1.0" Policy="MBI_SSL"></TicketType>
'@

function New-SoapHeader {
    param([string]$Action)
    $msgId = [guid]::NewGuid().ToString()
    $created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $expires = (Get-Date).ToUniversalTime().AddMinutes(7).ToString('yyyy-MM-ddTHH:mm:ssZ')
@"
  <s:Header>
    <a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/$Action</a:Action>
    <a:MessageID>urn:uuid:$msgId</a:MessageID>
    <a:To s:mustUnderstand="1">$FE3</a:To>
    <o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
      <Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
        <Created>$created</Created>
        <Expires>$expires</Expires>
      </Timestamp>
      <wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization">
        $AnonTicket
      </wuws:WindowsUpdateTicketsToken>
    </o:Security>
  </s:Header>
"@
}

function Invoke-FE3 {
    param([string]$Action, [string]$Body)
    $envelope = @"
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing">
$(New-SoapHeader -Action $Action)
  <s:Body>
$Body
  </s:Body>
</s:Envelope>
"@
    $resp = Invoke-WebRequest -Uri $FE3 -Method Post -ContentType 'application/soap+xml; charset=utf-8' `
        -Body $envelope -UseBasicParsing
    return [xml]$resp.Content
}

# --- Parse AppX / MSIX package full name into identity fields -----------------
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
        # Fallback for non-standard names
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

# --- 1. Resolve ProductId -> WuCategoryId ------------------------------------
function Resolve-CategoryId {
    param([string]$Identifier)

    $productId = $null
    if ($Identifier -match '^[0-9A-Za-z]{12,}$') {
        $productId = $Identifier                       # bare ProductId (12+ chars)
    } elseif ($Identifier -match '(?i)/([0-9A-Z]{12,})') {
        $productId = $Matches[1]                        # ProductId inside a Store URL
    } elseif ($Identifier -notmatch '_') {
        $productId = $null                              # let PFN/lookup handle the rest
    }
    if (-not $productId) {
        # Treat as PackageFamilyName -> look up via DisplayCatalog PFN endpoint
        $pfnUri = "https://displaycatalog.mp.microsoft.com/v7.0/products/lookup?market=US&languages=en-US&value=$Identifier&alternateId=PackageFamilyName&fieldsTemplate=details"
        $pfn = Invoke-RestMethod -Uri $pfnUri -UseBasicParsing
        if ($pfn -and $pfn.Products -and $pfn.Products.Count -gt 0) {
            $productId = $pfn.Products[0].ProductId
        }
    }
    if (-not $productId) { throw "Could not resolve a ProductId from '$Identifier'." }

    $uri = "https://displaycatalog.mp.microsoft.com/v7.0/products/$productId`?market=US&languages=en-US&fieldsTemplate=details"
    $cat = Invoke-RestMethod -Uri $uri -UseBasicParsing
    $wuCat = $null
    $pfn = $null
    if ($cat.Product.DisplaySkuAvailabilities -and $cat.Product.DisplaySkuAvailabilities.Count -gt 0) {
        $sku = $cat.Product.DisplaySkuAvailabilities[0].Sku
        if ($sku.Properties -and $sku.Properties.FulfillmentData) {
            $wuCat = $sku.Properties.FulfillmentData.WuCategoryId
            $pfn = $sku.Properties.FulfillmentData.PackageFamilyName
        }
    }
    if (-not $wuCat) {
        $wuCat = ($cat.Product.Properties.PSObject.Properties |
                  Where-Object Name -eq 'WuCategoryId').Value
    }
    if (-not $wuCat) { throw "No WuCategoryId found for ProductId $productId (app may not be free/store-delivered)." }
    $mainName = if ($pfn) { ($pfn -split '_')[0] } else { $null }
    [pscustomobject]@{
        ProductId  = $productId
        CategoryId = $wuCat
        Name       = $cat.Product.LocalizedProperties[0].ProductTitle
        MainName   = $mainName
    }
}

# --- 2. GetCookie -------------------------------------------------------------
function Get-FE3Cookie {
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $body = @"
    <GetCookie xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
      <lastChange>2015-10-21T17:01:07.1472913Z</lastChange>
      <currentTime>$now</currentTime>
      <protocolVersion>1.81</protocolVersion>
    </GetCookie>
"@
    $xml = Invoke-FE3 -Action 'GetCookie' -Body $body
    return $xml.Envelope.Body.GetCookieResponse.GetCookieResult.EncryptedData
}

# --- 3. SyncUpdates -----------------------------------------------------------
function Get-SyncUpdates {
    param([string]$Cookie, [string]$CategoryId, [string]$Ring)

    $body = @"
    <SyncUpdates xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
      <cookie>
        <Expiration>2099-01-01T00:00:00Z</Expiration>
        <EncryptedData>$Cookie</EncryptedData>
      </cookie>
      <parameters>
        <ExpressQuery>false</ExpressQuery>
        <InstalledNonLeafUpdateIDs>
          <int>1</int><int>2</int><int>3</int><int>11</int><int>19</int>
          <int>2359974</int><int>5169044</int><int>8788830</int><int>23110993</int>
          <int>23110995</int><int>59830006</int><int>59830007</int><int>59830008</int>
          <int>60484010</int><int>62450018</int><int>62450019</int><int>62450020</int>
          <int>104433538</int><int>104900364</int><int>105489019</int><int>117765322</int>
          <int>129905029</int><int>130040031</int><int>132387090</int><int>132393049</int>
          <int>133399034</int><int>138537048</int>
        </InstalledNonLeafUpdateIDs>
        <OtherCachedUpdateIDs></OtherCachedUpdateIDs>
        <SkipSoftwareSync>false</SkipSoftwareSync>
        <NeedTwoGroupOutOfScopeUpdates>true</NeedTwoGroupOutOfScopeUpdates>
        <FilterAppCategoryIds>
          <CategoryIdentifier><Id>$CategoryId</Id></CategoryIdentifier>
        </FilterAppCategoryIds>
        <TreatAppCategoryIdsAsInstalled>true</TreatAppCategoryIdsAsInstalled>
        <AlsoPerformRegularSync>false</AlsoPerformRegularSync>
        <ComputerSpec></ComputerSpec>
        <ExtendedUpdateInfoParameters>
          <XmlUpdateFragmentTypes>
            <XmlUpdateFragmentType>Extended</XmlUpdateFragmentType>
            <XmlUpdateFragmentType>LocalizedProperties</XmlUpdateFragmentType>
            <XmlUpdateFragmentType>Eula</XmlUpdateFragmentType>
            <XmlUpdateFragmentType>Published</XmlUpdateFragmentType>
            <XmlUpdateFragmentType>Core</XmlUpdateFragmentType>
          </XmlUpdateFragmentTypes>
          <Locales><string>en-US</string><string>en</string></Locales>
        </ExtendedUpdateInfoParameters>
        <ClientPreferredLanguages><string>en-US</string></ClientPreferredLanguages>
        <ProductsParameters>
          <SyncCurrentVersionOnly>false</SyncCurrentVersionOnly>
          <DeviceAttributes>E:BranchReadinessLevel=CB&amp;CurrentBranch=$Ring&amp;OEMModel=&amp;FlightRing=$Ring&amp;AttrDataVer=130&amp;InstallLanguage=en-US&amp;OSUILocale=en-US&amp;InstallationType=Client&amp;FlightingBranchName=&amp;App=WU_STORE&amp;ProcessorManufacturer=GenuineIntel&amp;OSVersion=10.0.22631.0&amp;DeviceFamily=Windows.Desktop</DeviceAttributes>
          <CallerAttributes>E:Interactive=1&amp;IsSeeker=1&amp;Acquisition=1&amp;SheddingAware=1&amp;Id=Acquisition%3BMicrosoft.WindowsStore_8wekyb3d8bbwe</CallerAttributes>
          <Products></Products>
        </ProductsParameters>
      </parameters>
    </SyncUpdates>
"@
    return Invoke-FE3 -Action 'SyncUpdates' -Body $body
}

# --- 4. GetExtendedUpdateInfo2 (real URLs) -----------------------------------
function Get-DownloadUrls {
    param([string]$UpdateID, [string]$RevisionNumber, [string]$Ring)
    $body = @"
    <GetExtendedUpdateInfo2 xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
      <updateIDs>
        <UpdateIdentity>
          <UpdateID>$UpdateID</UpdateID>
          <RevisionNumber>$RevisionNumber</RevisionNumber>
        </UpdateIdentity>
      </updateIDs>
      <infoTypes>
        <XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType>
        <XmlUpdateFragmentType>FileDecryption</XmlUpdateFragmentType>
        <XmlUpdateFragmentType>EsrpDecryptionInformation</XmlUpdateFragmentType>
        <XmlUpdateFragmentType>PiecesHashUrl</XmlUpdateFragmentType>
        <XmlUpdateFragmentType>BlockMapUrl</XmlUpdateFragmentType>
      </infoTypes>
      <deviceAttributes>E:BranchReadinessLevel=CB&amp;CurrentBranch=$Ring&amp;FlightRing=$Ring&amp;App=WU_STORE&amp;OSVersion=10.0.22631.0&amp;DeviceFamily=Windows.Desktop</deviceAttributes>
    </GetExtendedUpdateInfo2>
"@
    $xml = Invoke-FE3 -Action 'GetExtendedUpdateInfo2' -Body $body
    $result = @{}
    $fileLocations = $xml.Envelope.Body.GetExtendedUpdateInfo2Response.GetExtendedUpdateInfo2Result.FileLocations.FileLocation
    if ($fileLocations) {
        foreach ($loc in $fileLocations) {
            if ($loc.Url -and ($loc.Url -like 'http*://*delivery.mp.microsoft.com*' -or $loc.Url -like 'http*://*.windowsupdate.com*')) {
                $result[$loc.FileDigest] = $loc.Url
            }
        }
    }
    return $result
}

# =============================== MAIN =========================================
# Search the Microsoft Store by name (anonymous WinGet msstore endpoint).
function Search-StoreApp {
    param([string]$Term)
    $uri  = 'https://storeedgefd.dsx.mp.microsoft.com/v9.0/manifestSearch'
    $body = @{ Query = @{ KeyWord = $Term; MatchType = 'Substring' } } | ConvertTo-Json
    $resp = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body $body
    if ($resp -and $resp.Data) {
        $resp.Data | Where-Object { $_.PackageIdentifier } | ForEach-Object {
            [pscustomobject]@{ Id = $_.PackageIdentifier; Name = $_.PackageName }
        }
    }
}

function Invoke-AppDownload {
    param([string]$Id)
    Write-Host "Resolving '$Id' ..." -ForegroundColor Cyan
    $info = Resolve-CategoryId -Identifier $Id
    Write-Host "  App        : $($info.Name)"
    Write-Host "  ProductId  : $($info.ProductId)"
    Write-Host "  CategoryId : $($info.CategoryId)"

    # Per-app subfolder named after the app (invalid filename chars stripped).
    $folderName = if ($info.Name) { $info.Name } else { $info.ProductId }
    $folderName = ($folderName -replace '[\\/:*?"<>|]', '').Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($folderName)) { $folderName = $info.ProductId }
    $appDir = Join-Path $OutDir $folderName

    Write-Host "Getting FE3 cookie ..." -ForegroundColor Cyan
    $cookie = Get-FE3Cookie

    Write-Host "Syncing updates (ring: $Ring) ..." -ForegroundColor Cyan
    $sync = Get-SyncUpdates -Cookie $cookie -CategoryId $info.CategoryId -Ring $Ring

    # UpdateIdentity and the appx File metadata live in SEPARATE <Xml> fragments
    # (NewUpdates vs ExtendedUpdateInfo), linked by a numeric <ID>. Walk every
    # node that has both a child <ID> and a child <Xml>, parse the escaped
    # fragment, and bucket identities and files by that numeric ID, then join.
    $idMap   = @{}   # numericID -> @{ UpdateID; Revision }
    $fileMap = @{}   # numericID -> @{ digest = filename }

    foreach ($node in $sync.SelectNodes("//*[*[local-name()='ID'] and *[local-name()='Xml']]")) {
        $numId = $node.SelectSingleNode("*[local-name()='ID']").InnerText
        $xmlEl = $node.SelectSingleNode("*[local-name()='Xml']")
        if (-not $xmlEl) { continue }
        $fragText = $xmlEl.InnerText
        if ([string]::IsNullOrWhiteSpace($fragText)) { continue }
        try { $frag = [xml]("<root>$fragText</root>") } catch { continue }

        $idNode = $frag.SelectSingleNode("//*[local-name()='UpdateIdentity']")
        if ($idNode -and $idNode.GetAttribute('UpdateID')) {
            $idMap[$numId] = [pscustomobject]@{
                UpdateID = $idNode.GetAttribute('UpdateID')
                Revision = $idNode.GetAttribute('RevisionNumber')
            }
        }

        $fm = @{}
        foreach ($f in $frag.SelectNodes("//*[local-name()='File']")) {
            $name   = $f.GetAttribute('FileName')
            $digest = $f.GetAttribute('Digest')
            if ($name -match '\.(appx|appxbundle|msix|msixbundle|eappx|eappxbundle|emsix|emsixbundle)$') {
                $ext = $Matches[1]
                # Prefer the real package full name (contains version + arch) when present
                $isi = $f.GetAttribute('InstallerSpecificIdentifier')
                $friendly = if ($isi) { "$isi.$ext" } else { $name }
                $size = 0L; [void][long]::TryParse($f.GetAttribute('Size'), [ref]$size)
                $fm[$digest] = [pscustomobject]@{ Name = $friendly; Size = $size }
            }
        }
        if ($fm.Count -gt 0) { $fileMap[$numId] = $fm }
    }

    $packages = @()
    foreach ($numId in $fileMap.Keys) {
        if ($idMap.ContainsKey($numId)) {
            $packages += [pscustomobject]@{
                UpdateID = $idMap[$numId].UpdateID
                Revision = $idMap[$numId].Revision
                Files    = $fileMap[$numId]
            }
        }
    }

    if ($packages.Count -eq 0) {
        $dump = Join-Path $PWD 'SyncUpdates-dump.xml'
        $sync.OuterXml | Out-File -FilePath $dump -Encoding UTF8
        throw "Joined 0 packages (ids:$($idMap.Count) fileSets:$($fileMap.Count)). Raw response saved to $dump."
    }

    # Resolve URLs and match to filenames by digest, one package at a time so a
    # single faulting update does not abort the whole run.
    $downloads = @()
    foreach ($pkg in ($packages | Sort-Object UpdateID -Unique)) {
        try {
            $urls = Get-DownloadUrls -UpdateID $pkg.UpdateID -RevisionNumber $pkg.Revision -Ring $Ring
        } catch {
            Write-Warning "Skipped $($pkg.UpdateID): $($_.Exception.Message)"
            continue
        }
        foreach ($digest in $pkg.Files.Keys) {
            if ($urls.ContainsKey($digest)) {
                $entry = $pkg.Files[$digest]
                $name  = $entry.Name
                $ident = Get-AppxPackageIdentity -FileName $name

                # Filter by parsed package architecture token
                if ($Arch -eq 'neutral') {
                    if ($ident.Architecture -ne 'neutral') { continue }
                } elseif ($Arch -ne 'all') {
                    if ($ident.Architecture -ne $Arch -and $ident.Architecture -ne 'neutral') { continue }
                }

                $downloads += [pscustomobject]@{
                    Name     = $name
                    Url      = $urls[$digest]
                    Size     = $entry.Size
                    Identity = $ident
                }
            }
        }
    }

    $downloads = $downloads | Sort-Object Name -Unique

    if (-not $IncludeEncrypted) {
        $downloads = $downloads | Where-Object { $_.Name -notmatch '\.(eappx|eappxbundle|emsix|emsixbundle)$' }
    }

    if (-not $AllVersions) {
        # Package full name = Name_Version_Arch_ResourceId_PublisherId.ext
        # Family = Name + Arch + PublisherId (version dropped); keep highest version.
        $keyOf = {
            param($item)
            $ident = if ($item.Identity) { $item.Identity } else { Get-AppxPackageIdentity -FileName $item.Name }
            $nm = $ident.PackageName
            # Aggressive: drop the trailing version-line from the name so e.g.
            # Microsoft.NET.Native.Framework.1.7 and .2.2 share one key.
            if ($LatestFrameworkOnly) { $nm = $nm -replace '\.\d+(\.\d+)*$', '' }
            "$nm|$($ident.Architecture)|$($ident.PublisherId)"
        }
        $verOf = {
            param($item)
            $ident = if ($item.Identity) { $item.Identity } else { Get-AppxPackageIdentity -FileName $item.Name }
            $ident.VersionObj
        }
        $downloads = $downloads |
            Group-Object { & $keyOf $_ } |
            ForEach-Object { $_.Group | Sort-Object { & $verOf $_ } -Descending | Select-Object -First 1 } |
            Sort-Object Name
    }

    if ($MainPackageOnly) {
        if (-not $info.MainName) { throw "Could not determine the main package name for -MainPackageOnly." }
        $downloads = $downloads | Where-Object { $_.Name -like "$($info.MainName)_*" }
    }

    if (-not $downloads -or @($downloads).Count -eq 0) { throw "Resolved 0 downloadable packages for arch '$Arch'. Try -Arch all." }

    # Nest files under the main app's version: OutDir\App Name\<version>\
    $mainPkg = $null
    if ($info.MainName) {
        $mainPkg = $downloads | Where-Object { $_.Name -like "$($info.MainName)_*" } | Select-Object -First 1
    }
    if ($mainPkg) {
        $ident = if ($mainPkg.Identity) { $mainPkg.Identity } else { Get-AppxPackageIdentity -FileName $mainPkg.Name }
        if ($ident.Version -and $ident.Version -ne '0.0.0.0') {
            $appDir = Join-Path $appDir $ident.Version
        }
    }
    $null = New-Item -ItemType Directory -Path $appDir -Force

    Write-Host "`nFound $($downloads.Count) package(s):" -ForegroundColor Green
    $downloads | ForEach-Object { Write-Host "  $($_.Name)" }

    foreach ($d in $downloads) {
        $out = Join-Path $appDir $d.Name
        if (-not $Force -and (Test-Path -LiteralPath $out)) {
            $have = (Get-Item -LiteralPath $out).Length
            # Skip when the existing file matches the expected size (or size unknown but non-empty).
            if (($d.Size -gt 0 -and $have -eq $d.Size) -or ($d.Size -le 0 -and $have -gt 0)) {
                Write-Host "Already present, skipping $($d.Name)" -ForegroundColor DarkGray
                continue
            }
            Write-Host "Size mismatch, re-downloading $($d.Name)" -ForegroundColor Yellow
        }
        Write-Host "Downloading $($d.Name) ..." -ForegroundColor Cyan
        
        $maxRetries = 3
        $downloadSuccess = $false
        $lastErr = $null
        
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                Invoke-WebRequest -Uri $d.Url -OutFile $out -UseBasicParsing -TimeoutSec 60
                $downloadSuccess = $true
                break
            } catch {
                $lastErr = $_.Exception.Message
                if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
                if ($attempt -lt $maxRetries) {
                    Write-Host "  Download attempt $attempt failed ($lastErr). Retrying in 2s..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                }
            }
        }

        if (-not $downloadSuccess) {
            throw "Failed downloading '$($d.Name)' after $maxRetries attempts: $lastErr"
        }
    }

    Write-Host "`nDone. Saved to: $appDir" -ForegroundColor Green
}

# ---- Driver: take -Id value(s) or prompt for one or more apps ----------------
$targets = @($Id | Where-Object { $_ })
if (-not $targets) {
    if ([Console]::IsInputRedirected) {
        Write-Host "No apps specified (-Id) and input is redirected." -ForegroundColor Yellow
        return
    }
    Write-Host "Enter a Store URL, ProductId, or PackageFamilyName for each app." -ForegroundColor Yellow
    Write-Host "Press Enter on a blank line when finished.`n"
    while ($true) {
        $entry = Read-Host "App"
        if ([string]::IsNullOrWhiteSpace($entry)) { break }
        $targets += $entry.Trim()
    }
}
if (-not $targets) { Write-Host "No apps specified." -ForegroundColor Yellow; return }

foreach ($t in $targets) {
    $resolved = $t
    $isDirect = ($t -match '^https?://') -or ($t -match '^[0-9A-Za-z]{12,}$') -or ($t -match '_')
    if (-not $isDirect) {
        try { $hits = @(Search-StoreApp -Term $t) }
        catch { Write-Warning "Search failed for '$t': $($_.Exception.Message)"; continue }
        if (-not $hits) { Write-Warning "No Store matches for '$t'."; continue }

        Write-Host "Matches for '$t':" -ForegroundColor Yellow
        for ($i = 0; $i -lt $hits.Count; $i++) {
            Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $hits[$i].Name, $hits[$i].Id)
        }
        $sel = Read-Host "Pick a number (blank to skip)"
        if ([string]::IsNullOrWhiteSpace($sel)) { continue }
        $idx = 0
        if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $hits.Count) {
            Write-Warning "Invalid selection."; continue
        }
        $resolved = $hits[$idx - 1].Id
    }
    try { Invoke-AppDownload -Id $resolved }
    catch { Write-Warning "Failed for '$resolved': $($_.Exception.Message)" }
    Write-Host ""
}
