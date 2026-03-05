<#
.SYNOPSIS
Advanced RAM OS Builder with Hardware Support
Creates a WinPE-based RAM Operating System — optionally using the machine's own WinRE WIM as the base (WiFi-capable, no ISO needed).

.DESCRIPTION
Builds a bootable WinPE ISO with optional WinRE base WIM support. Highlights:
- True RAM operation (WinPE runs from X:\; you can eject boot media after desktop loads)
- WinRE base mode (-UseWinRE): uses local winre.wim — WiFi drivers & MDM DLLs already present
- WiFi support via WirelessConnect.exe + 3 MDM DLLs (-IncludeWiFi, auto-enabled with -UseWinRE)
- Dell WinPE11 drivers injected correctly (CAB extracted, INF drivers added)
- WinXShell as primary lightweight shell + optional Explorer++ as file manager (no Microsoft explorer.exe)
- Chrome++ (Chrome Plus) with repo-faithful validation (version.dll next to chrome.exe)
- Chrome launcher puts profile/cache on X:\ (volatile)
- ADK detection via OSD module (Get-WindowsAdkPaths) with registry fallback
- Optional FBWF OC (off by default; not needed for eject-media)

.PARAMETER SourceISO
Path to Windows 10/11 ISO (any edition)

.PARAMETER WorkRoot
Build working directory (20GB free required)

.PARAMETER UseChromePlus
Download & integrate Chrome++ (Chrome Plus) and validate it

.PARAMETER ChromeOfflineInstallerPath
Path to Chrome offline installer (optional; used if Chrome++ package lacks chrome.exe)

.PARAMETER ChromePortablePath
Alternate to Chrome++: local Chrome portable archive (.zip/.7z/.exe) to integrate

.PARAMETER IncludeExplorerPlus
Include Explorer++ file manager

.PARAMETER IncludeDellDrivers
Inject Dell WinPE 11 driver pack

.PARAMETER WallpaperPath
Path to custom wallpaper image (.jpg/.jpeg/.png/.bmp)

.PARAMETER AccentColor
Hex RGB accent color (best-effort for DWM)

.PARAMETER OutputISOName
Output ISO filename

.PARAMETER RamdiskSizeMB
Overlay size used only when -EnableFBWF is specified

.PARAMETER ADKPath
Path to WinPE add-on (auto-detected if omitted)

.PARAMETER KeepMountedWIM
Preserve mounted WIM on failure (debugging)

.PARAMETER SkipCleanup
Skip cleanup after build

.PARAMETER WimIndex
Image index to mount in boot.wim (1=plain WinPE, 2=WinPE+Setup). Default: 1

.PARAMETER EnableFBWF
Add WinPE-FBWF OC (optional; typically not needed for eject-media)

.EXAMPLE
# Traditional mode (from ISO):
.\Build-Image.ps1 -SourceISO "C:\Win11.iso" -WorkRoot "D:\Build" -UseChromePlus -IncludeDellDrivers -IncludeExplorerPlus

.EXAMPLE
# WinRE mode (no ISO needed — uses local winre.wim, WiFi included):
.\Build-Image.ps1 -UseWinRE -WorkRoot "D:\Build" -UseChromePlus -IncludeDellDrivers

#>
[CmdletBinding()]
param(
  # Source ISO is required unless -UseWinRE is specified
  [Parameter(Mandatory = $false)]
  [ValidateScript({
      if ($_ -and -not (Test-Path "$_")) { throw "Source ISO not found: $_" }
      $true
    })]
  [string]$SourceISO = "",

  # Use the machine's local winre.wim as base WIM instead of boot.wim from an ISO.
  # Skips ISO extraction; boot files come from ADK media folder.
  # Automatically enables WiFi support (-IncludeWiFi).
  [Parameter(Mandatory = $false)] [switch]$UseWinRE,

  # Inject WiFi support: copies 3 MDM DLLs from local System32 + downloads WirelessConnect.exe.
  # Required DLLs: dmcmnutils.dll, mdmpostprocessevaluator.dll, mdmregistration.dll
  [Parameter(Mandatory = $false)] [switch]$IncludeWiFi,

  [Parameter(Mandatory = $true)]
  [ValidateScript({
      # Accept paths that don't exist yet — they'll be created during init
      $testPath = $_
      if (-not (Test-Path $testPath)) {
        # Ensure the parent or drive root exists and has enough space
        $parent = Split-Path $testPath -Parent
        if (-not $parent) { throw "Cannot determine parent directory for: $testPath" }
        while ($parent -and -not (Test-Path $parent)) { $parent = Split-Path $parent -Parent }
        if (-not $parent) { throw "No valid ancestor directory for: $testPath" }
      }
      $resolved = if (Test-Path $testPath) { (Resolve-Path $testPath).Path } else { [IO.Path]::GetFullPath($testPath) }
      $drive = Split-Path -Qualifier $resolved
      $free = ([System.IO.DriveInfo]::new("$drive\")).AvailableFreeSpace / 1GB
      if ($free -lt 20) { throw "Insufficient space on $drive ($([math]::Round($free,2)) GB, need 20+)" }
      $true
    })]
  [string]$WorkRoot,

  [Parameter(Mandatory = $false)] [switch]$UseChromePlus,

  [Parameter(Mandatory = $false)]
  [ValidateScript({
      if ($_) {
        if (-not (Test-Path "$_")) { throw "Chrome offline installer not found: $_" }
        $ext = [IO.Path]::GetExtension("$_").ToLower()
        if ($ext -notin @('.exe','.zip','.7z')) { throw "Offline installer must be .exe, .zip or .7z" }
      }
      $true
    })]
  [string]$ChromeOfflineInstallerPath = "",

  [Parameter(Mandatory = $false)]
  [ValidateScript({
      if ($_) {
        if (-not (Test-Path "$_")) { throw "Chrome portable path not found: $_" }
        $ext = [System.IO.Path]::GetExtension("$_").ToLower()
        if ($ext -notin @('.zip','.exe','.7z')) { throw "Chrome must be .zip, .7z or .exe" }
      }
      $true
    })]
  [string]$ChromePortablePath = "",

  [Parameter(Mandatory = $false)] [switch]$IncludeExplorerPlus,
  [Parameter(Mandatory = $false)] [switch]$IncludeDellDrivers,

  [Parameter(Mandatory = $false)]
  [ValidateScript({
      if ($_) {
        if (-not (Test-Path "$_")) { throw "Wallpaper not found: $_" }
        $ext = [System.IO.Path]::GetExtension("$_").ToLower()
        if ($ext -notin @('.jpg','.jpeg','.png','.bmp')) { throw "Wallpaper must be image file" }
      }
      $true
    })]
  [string]$WallpaperPath,

  [Parameter(Mandatory = $false)]
  [ValidatePattern('^[0-9A-Fa-f]{6}$')]
  [string]$AccentColor = "0078D7",

  [Parameter(Mandatory = $false)]
  [string]$OutputISOName = "RAMOS_Desktop.iso",

  [Parameter(Mandatory = $false)]
  [ValidateRange(1024,8192)]
  [uint64]$RamdiskSizeMB = 4096,

  [Parameter(Mandatory = $false)]
  [string]$ADKPath = "",# Will be auto-detected if not provided

  [Parameter(Mandatory = $false)] [switch]$KeepMountedWIM,
  [Parameter(Mandatory = $false)] [switch]$SkipCleanup,

  [Parameter(Mandatory = $false)]
  [ValidateSet(1,2)]
  [int]$WimIndex = 1,

  [Parameter(Mandatory = $false)]
  [switch]$EnableFBWF
)

#Requires -RunAsAdministrator

# Validate: need either -SourceISO or -UseWinRE
if (-not $UseWinRE -and [string]::IsNullOrWhiteSpace($SourceISO)) {
    throw "You must supply either -SourceISO <path> or -UseWinRE (to use the local machine's winre.wim)."
}

# ============================================
# OSD MODULE (optional but strongly recommended)
# Provides: Get-WindowsAdkPaths, Add-7Zip2BootImage, etc.
# Install: Install-Module OSD  /  Update-Module OSD
# ============================================
try {
    Import-Module OSD -MinimumVersion '23.0.0' -ErrorAction Stop
    $Script:OSDAvailable = $true
    Write-Host "[Init] OSD module loaded ($(( Get-Module OSD).Version))" -ForegroundColor DarkGray
} catch {
    $Script:OSDAvailable = $false
    Write-Host "[Init] OSD module not available — using built-in ADK detection fallback" -ForegroundColor Yellow
}
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Script:Config = @{
  StartTime = Get-Date
  LogFile = $null
  Paths = @{}
  Tools = @{}
  Apps = @{}
  Locale = (Get-Culture).Name.ToLower()
  Stats = @{
    Packages = 0
    Apps = 0
    DriversAdded = 0
  }
}

# Latest stable sources (with fallbacks where useful)
$Script:AppSources = @{
  # WinXShell - lightweight shell for WinPE (portable, no installation needed)
  WinXShell = "https://www.theoven.org/download/file.php?id=129&sid=a690ad357e3aaa6c4ddc557b07396bae"

  # IBM Semeru (prefer latest 8u482; fallback to previously-used 8u472)
  SemeruPrimary = "https://github.com/ibmruntimes/semeru8-binaries/releases/download/jdk8u482-b08_openj9-0.57.0/ibm-semeru-open-jdk_x64_windows_8u482b08_openj9-0.57.0.zip"
  SemeruFallback = "https://github.com/ibmruntimes/semeru8-binaries/releases/download/jdk8u472-b08_openj9-0.56.0/ibm-semeru-open-jdk_x64_windows_8u472b08_openj9-0.56.0-portable.zip"

  # Explorer++ official portable ZIP
  ExplorerPlusPlus = "https://github.com/derceg/explorerplusplus/releases/download/version-1.4.0/explorerpp_x64.zip"

  # Chrome++ (Chrome Plus) packaged as .7z; requires version.dll next to chrome.exe
  ChromePlus = "https://github.com/Bush2021/chrome_plus/releases/download/1.15.1/Chrome++_v1.15.1_x86_x64_arm64.7z"

  # Chrome program files — these are 7-zip SFX archives, NOT installers.
  # NEVER execute them as a process — that triggers a real Chrome install on the host.
  # Always extract with 7z only.
  #
  # Source 1: Bush2021/chrome_installer on GitHub — pre-extracted Chrome wrapped as 7z SFX
  #   Structure after extraction: Chrome-bin\<version>\chrome.exe
  ChromeUnpackedSFX = "https://github.com/Bush2021/chrome_installer/releases/download/145.0.7632.160/x64_145.0.7632.160_chrome_installer_uncompressed.exe"
  ChromeUnpackedSFX_CDN = "https://dl.google.com/release2/chrome/nuloamky47wcog6772kpqu2zyu_145.0.7632.160/145.0.7632.160_chrome_installer_uncompressed.exe"
  #
  # Source 2: PortableApps.com Google Chrome Portable — NSIS paf.exe, 7z-extractable.
  #   Structure after extraction: App\Chrome-bin\<version>\chrome.exe
  #   NEVER execute — always extract with 7z.
  ChromePortableApps = "https://portableapps.com/downloading/?a=GoogleChromePortable&s=s&p=&d=pa&n=Google%20Chrome%20Portable&f=GoogleChromePortable_145.0.7632.160_online.paf.exe"

  # Dell WinPE 11 driver pack A08 (Dec 23, 2025)
  DellWinPEDrivers = "https://downloads.dell.com/FOLDER14002062M/1/WinPE11.0-Drivers-A08-2V5TD.cab"

  # WirelessConnect.exe — GUI Wi-Fi SSID selector for WinRE/WinPE by Oliver Kieselbach
  # Placed at X:\Windows\WirelessConnect.exe; invoked by OSD Start-WinREWiFi -WirelessConnect
  WirelessConnect = "https://github.com/okieselbach/Helpers/raw/master/WirelessConnect/WirelessConnect/bin/Release/WirelessConnect.exe"

  # Minimal 7-zip standalone extractor (build-time only)
  SevenZipMini = "https://www.7-zip.org/a/7zr.exe"

  # Full 7-Zip portable (console + GUI) for injection into the image
  SevenZipExtra = "https://www.7-zip.org/a/7z2408-extra.7z"
  SevenZipFull = "https://www.7-zip.org/a/7z2408-x64.exe"
}

# Valid WinPE OCs per MS docs; language packs added when present
$Script:WinPEPackages = @(
  "WinPE-WMI",
  "WinPE-Scripting",
  "WinPE-PowerShell",
  "WinPE-HTA",
  "WinPE-NetFx",
  # TODO: WinPE-WOW64 - 32-bit subsystem support for 64-bit WinPE
  # Currently commented out as it may not be available in all ADK versions
  # See: https://github.com/slorelee/wimbuilder2/tree/master/Projects/WIN10XPE/01-Components/SysWOW64_Basic
  # Uncomment if you need 32-bit application support in 64-bit WinPE
  # "WinPE-WOW64",
  "WinPE-Fonts-Legacy",
  "WinPE-StorageWMI",
  "WinPE-DismCmdlets",
  "WinPE-FMAPI",
  "WinPE-WiFi-Package",  # ADK for Windows 10 package name
  "WinPE-WiFi",           # ADK for Windows 11 alternate name; loop skips whichever .cab is absent
  "WinPE-SRT"
)

# ============================================
# LOGGING
# ============================================
function Write-BuildLog {
  param(
    [Parameter(Mandatory = $true)] [string]$Message,
    [ValidateSet("Info","Success","Warning","Error")] [string]$Level = "Info"
  )
  $ts = Get-Date -Format "HH:mm:ss"
  $color = switch ($Level) {
    "Success" { "Green" }
    "Error" { "Red" }
    "Warning" { "Yellow" }
    default { "Cyan" }
  }
  Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
}

# ============================================
# SETUP
# ============================================
function Test-Administrator {
  $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object System.Security.Principal.WindowsPrincipal ($id)
  return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-BuildEnvironment {
  Write-BuildLog "Initializing RAM OS Builder..."

  # Verify Administrator privileges
  if (-not (Test-Administrator)) {
    throw "This script requires Administrator privileges. Please run PowerShell as Administrator and try again."
  }
  Write-BuildLog "Administrator privileges verified" -Level Info

  # Normalize and validate WorkRoot path
  $WorkRoot = "$WorkRoot".Replace('/','\').Trim()
  if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    throw "WorkRoot path is empty or invalid"
  }

  if (-not [System.IO.Path]::IsPathRooted($WorkRoot)) {
    $WorkRoot = Join-Path (Get-Location).Path $WorkRoot
  }
  $WorkRoot = $WorkRoot.TrimEnd('\')

  if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    throw "WorkRoot path resolved to empty value"
  }

  # Ensure WorkRoot exists (may have been a new path accepted by validation)
  if (-not (Test-Path $WorkRoot)) {
    New-Item -ItemType Directory -Path $WorkRoot -Force -ErrorAction Stop | Out-Null
  }

  # Build paths using explicit string concatenation (more reliable than Join-Path in PowerShell Core)
  $Script:Config.Paths = @{
    Root = $WorkRoot
    ISO = [System.IO.Path]::Combine($WorkRoot,"ISO_Source")
    Mount = [System.IO.Path]::Combine($WorkRoot,"Mount_WIM")
    Apps = [System.IO.Path]::Combine($WorkRoot,"Apps")
    Cache = [System.IO.Path]::Combine($WorkRoot,"Cache")
    Output = [System.IO.Path]::Combine($WorkRoot,"Output")
    Temp = [System.IO.Path]::Combine($WorkRoot,"Temp")
  }

  # Validate all paths before creating directories
  foreach ($key in $Script:Config.Paths.Keys) {
    $path = $Script:Config.Paths[$key]
    if ([string]::IsNullOrWhiteSpace($path)) {
      throw "Path '$key' resolved to empty value (WorkRoot='$WorkRoot')"
    }
  }

  # Create all directories
  foreach ($p in $Script:Config.Paths.Values) {
    if (-not (Test-Path $p)) {
      New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null
    }
  }

  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $Script:Config.LogFile = [System.IO.Path]::Combine($Script:Config.Paths.Output,"Build-$timestamp.log")
  if ([string]::IsNullOrWhiteSpace($Script:Config.LogFile)) {
    throw "LogFile path resolved to empty value"
  }

  Start-Transcript -Path $Script:Config.LogFile -ErrorAction Stop | Out-Null

  # -------------------------------------------------------
  # ADK detection - prefer OSD module (registry-based),
  # fall back to path-guessing if OSD is not installed.
  # -------------------------------------------------------
  if ($Script:OSDAvailable) {
    Write-BuildLog "Using OSD Get-WindowsAdkPaths for ADK detection..." -Level Info
    $adkPaths = Get-WindowsAdkPaths
    if (-not $adkPaths) { throw "OSD Get-WindowsAdkPaths returned nothing. Check that Windows ADK is installed." }

    $Script:Config.Tools = @{
      DISM           = $adkPaths.dismexe
      OSCDIMG        = $adkPaths.oscdimgexe
      WinPEOCs       = $adkPaths.WinPEOCs
      # Boot sector files — returned directly by OSD; stored for Build-FinalISO
      EtfsBootCom    = $adkPaths.etfsbootcom
      EfiSysNoprompt = $adkPaths.efisysnopromptbin
      # ADK media root (amd64\Media) — used to build ISO source structure in WinRE mode
      WinPEMedia     = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($adkPaths.WinPEOCs),"Media")
    }
    Write-BuildLog "ADK via OSD: DISM=$($Script:Config.Tools.DISM)" -Level Info
    Write-BuildLog "ADK via OSD: OSCDIMG=$($Script:Config.Tools.OSCDIMG)" -Level Info
    Write-BuildLog "ADK via OSD: WinPEOCs=$($Script:Config.Tools.WinPEOCs)" -Level Info
    Write-BuildLog "ADK via OSD: EtfsBootCom=$($Script:Config.Tools.EtfsBootCom)" -Level Info
  } else {
    Write-BuildLog "OSD unavailable — probing ADK paths by well-known locations..." -Level Warning
    $progFiles86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    $progFiles   = [Environment]::GetEnvironmentVariable("ProgramFiles")

    $candidates = @()
    foreach ($c in @(
      $ADKPath,
      (if ($progFiles86) { "$progFiles86\Windows Kits\11\Assessment and Deployment Kit\Windows Preinstallation Environment" }),
      (if ($progFiles86) { "$progFiles86\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment" }),
      (if ($progFiles)   { "$progFiles\Windows Kits\11\Assessment and Deployment Kit\Windows Preinstallation Environment" }),
      (if ($progFiles)   { "$progFiles\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment" })
    )) {
      if ($c -and $c.Length -gt 3 -and (Test-Path $c) -and $candidates -notcontains $c) { $candidates += $c }
    }

    if (-not $candidates) {
      throw "Windows ADK WinPE add-on not found. Install ADK from https://aka.ms/adk or install the OSD module (Install-Module OSD) for automatic detection."
    }

    $winpeAddOn = $candidates[0]
    $adkRoot    = Split-Path -Path $winpeAddOn -Parent
    if ([string]::IsNullOrWhiteSpace($adkRoot)) { throw "ADK Root path is empty after Split-Path. WinPE path was: '$winpeAddOn'" }

    Write-BuildLog "ADK Root (fallback): $adkRoot" -Level Info

    $Script:Config.Tools = @{
      DISM           = [System.IO.Path]::Combine($adkRoot,"Deployment Tools\amd64\DISM\dism.exe")
      OSCDIMG        = [System.IO.Path]::Combine($adkRoot,"Deployment Tools\amd64\Oscdimg\oscdimg.exe")
      WinPEOCs       = [System.IO.Path]::Combine($winpeAddOn,"amd64\WinPE_OCs")
      EtfsBootCom    = $null   # will be resolved from ISO source at build time
      EfiSysNoprompt = $null
      WinPEMedia     = [System.IO.Path]::Combine($winpeAddOn,"amd64\Media")
    }

    if (-not (Test-Path $Script:Config.Tools.DISM)) {
      try { $Script:Config.Tools.DISM = (Get-Command dism.exe -ErrorAction Stop).Source }
      catch { throw "DISM.exe not found. Ensure Windows ADK is installed or DISM is in PATH." }
    }
    if (-not (Test-Path $Script:Config.Tools.OSCDIMG)) {
      try { $Script:Config.Tools.OSCDIMG = (Get-Command oscdimg.exe -ErrorAction Stop).Source }
      catch { throw "OSCDIMG.exe not found. Ensure Windows ADK is installed." }
    }
  }

  if (-not (Test-Path $Script:Config.Tools.WinPEOCs)) {
    throw "WinPE optional components folder not found: $($Script:Config.Tools.WinPEOCs)`nEnsure Windows ADK with WinPE add-on is properly installed."
  }

  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
  $Script:State = @{ Mounted = $false }

  Write-BuildLog "Build environment initialized" -Level "Success"
}

function Invoke-Cleanup {
  param([switch]$Preserve)

  Write-BuildLog "Performing cleanup..."

  if ($Script:State.Mounted -and -not $Preserve) {
    & $Script:Config.Tools.DISM /Unmount-Image /MountDir:$Script:Config.Paths.Mount /Discard 2>&1 | Out-Null
    $Script:State.Mounted = $false
  }

  # Dismount ISO if still mounted (only applies to traditional ISO mode)
  if (-not [string]::IsNullOrWhiteSpace($SourceISO) -and (Test-Path $SourceISO)) {
    Get-DiskImage -ImagePath "$SourceISO" -ErrorAction SilentlyContinue | Dismount-DiskImage -ErrorAction SilentlyContinue | Out-Null
  }

  if (-not $SkipCleanup) {
    Remove-Item $Script:Config.Paths.Apps -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $Script:Config.Paths.Temp -Recurse -Force -ErrorAction SilentlyContinue
  }

  Stop-Transcript -ErrorAction SilentlyContinue
}

# ============================================
# ISO & WIM
# ============================================

# Locate the machine's own WinRE WIM (used when -UseWinRE is specified).
#
# Search strategy — modelled on the OSD module's Copy-WinREWIM / Get-WinREPartition:
#   0. OSD Copy-WinREWIM  — primary path; OSD handles all partition logic correctly
#   1. Well-known drive-letter paths (standard installs / in-place upgrades)
#   2. ReAgent.xml parsed for folder path, scanned against all lettered drives
#   3. Offset-based partition mount (OSD approach):
#        - Parse ReAgent.xml for WinreLocationOffset + WinreLocationId (disk)
#        - Find exact partition via Get-Partition | Where-Object Offset
#        - Assign drive letter with Set-Partition -NewDriveLetter  (OSD uses this)
#        - Copy winre.wim with robocopy, then remove drive letter
#   4. Broad drive scan (last resort)
function Get-WinRESource {
  Write-BuildLog "Locating local winre.wim..."

  # Staging directory — $Script:Config.Paths.Temp is always set by Initialize-BuildEnvironment
  $stageDir = $Script:Config.Paths.Temp
  New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

  # ── Tier 0: OSD Copy-WinREWIM ─────────────────────────────────────────────
  # OSD already implements the offset-based partition discovery and Set-Partition
  # drive-letter assignment in a battle-tested way.  Use it when available.
  if (Get-Command Copy-WinREWIM -Module OSD -ErrorAction SilentlyContinue) {
    Write-BuildLog "Using OSD Copy-WinREWIM..." -Level Info
    try {
      $wimFile = Copy-WinREWIM -DestinationDirectory $stageDir `
                               -DestinationFileName 'winre_extracted.wim' `
                               -ErrorAction Stop
      if ($wimFile -and (Test-Path $wimFile.FullName -ErrorAction SilentlyContinue)) {
        Write-BuildLog "Found winre.wim via OSD Copy-WinREWIM: $($wimFile.FullName)" -Level Success
        return $wimFile.FullName
      }
    } catch {
      Write-BuildLog "OSD Copy-WinREWIM failed: $_ — falling back to manual search" -Level Warning
    }
  }

  # ── Tier 1: well-known accessible drive-letter paths ─────────────────────
  foreach ($c in @(
    "$env:SystemRoot\System32\Recovery\Winre.wim",
    "$env:SystemDrive\Recovery\WindowsRE\Winre.wim",
    "$env:SystemDrive\Recovery\Winre.wim"
  )) {
    if (Test-Path $c -ErrorAction SilentlyContinue) {
      Write-BuildLog "Found winre.wim (tier 1, known path): $c" -Level Success
      return $c
    }
  }

  # ── Tier 2 + 3: ReAgent.xml → offset-based partition mount ───────────────
  # OSD approach: use WinreLocationOffset (partition byte offset) + WinreLocationId
  # (disk number / MBR signature) to pinpoint the exact partition, then assign a
  # temporary drive letter with Set-Partition -NewDriveLetter (not Add-PartitionAccessPath).
  $reagentXml = "$env:SystemRoot\System32\Recovery\ReAgent.xml"
  if (Test-Path $reagentXml -ErrorAction SilentlyContinue) {
    Write-BuildLog "Parsing ReAgent.xml for WinRE partition offset..." -Level Info
    try {
      [xml]$xDoc  = Get-Content $reagentXml -Raw -ErrorAction Stop
      $loc        = $xDoc.WindowsRE.WinreLocation
      $wimFolder  = $loc.path      # folder on recovery partition, e.g. \Recovery\WindowsRE
      $partOffset = [long]$loc.offset
      $diskId     = [long]$loc.id  # 0..n = disk number; >1000 = MBR disk signature

      # ── Tier 2: partition already has a drive letter ──────────────────────
      if ($wimFolder) {
        $wimRel = $wimFolder.TrimStart('\') + '\Winre.wim'
        foreach ($drv in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Root) {
          $c = Join-Path $drv $wimRel
          if (Test-Path $c -ErrorAction SilentlyContinue) {
            Write-BuildLog "Found winre.wim (tier 2, lettered drive): $c" -Level Success
            return $c
          }
        }
      }

      # ── Tier 3: find partition by offset, assign temporary drive letter ───
      if ($partOffset -gt 0) {
        Write-BuildLog "Locating recovery partition by offset $partOffset..." -Level Info

        # OSD logic: id > 1000 means MBR signature, else use disk number
        $winrePart = $null
        if ($diskId -gt 1000) {
          $winrePart = Get-Disk |
            Where-Object { $_.Signature -eq $diskId } |
            Get-Partition |
            Where-Object { $_.Offset -eq $partOffset } |
            Select-Object -First 1
        } else {
          $winrePart = Get-Disk -Number $diskId -ErrorAction SilentlyContinue |
            Get-Partition -ErrorAction SilentlyContinue |
            Where-Object { $_.Offset -eq $partOffset } |
            Select-Object -First 1
        }

        if ($winrePart) {
          $hadDriveLetter = $winrePart.DriveLetter -and [char]$winrePart.DriveLetter -ne [char]0

          if ($hadDriveLetter) {
            $mountLetter = [string]$winrePart.DriveLetter
          } else {
            # Pick first free letter D..Z (OSD scans D→Z)
            $mountLetter = [char[]](68..90) |
              Where-Object { (Get-PSDrive -ErrorAction SilentlyContinue).Name -notcontains ([string]$_) } |
              Select-Object -First 1 |
              ForEach-Object { [string]$_ }
          }

          if ($mountLetter) {
            $needsCleanup = $false
            try {
              if (-not $hadDriveLetter) {
                Write-BuildLog "Assigning drive letter ${mountLetter}: to recovery partition (Disk $($winrePart.DiskNumber) Partition $($winrePart.PartitionNumber))..." -Level Info
                Set-Partition -DiskNumber $winrePart.DiskNumber `
                              -PartitionNumber $winrePart.PartitionNumber `
                              -NewDriveLetter $mountLetter -ErrorAction Stop
                Start-Sleep -Milliseconds 800
                $needsCleanup = $true
              }

              # Build search paths — use folder from XML first, then common fallbacks
              $searchPaths = @()
              if ($wimFolder) { $searchPaths += $wimFolder.TrimStart('\') + '\Winre.wim' }
              $searchPaths += @('Recovery\WindowsRE\Winre.wim','Recovery\Winre.wim')

              $foundOnPart = $null
              foreach ($sub in $searchPaths) {
                $probe = "${mountLetter}:\$sub"
                if (Test-Path $probe -ErrorAction SilentlyContinue) { $foundOnPart = $probe; break }
              }

              if ($foundOnPart) {
                $destWim = Join-Path $stageDir 'winre_extracted.wim'
                Write-BuildLog "Copying winre.wim from recovery partition via robocopy..." -Level Info
                $srcDir  = Split-Path $foundOnPart
                robocopy "$srcDir" "$stageDir" 'winre.wim' /NFL /NDL /NJH /NJS /R:0 /W:0 | Out-Null
                # Rename to expected filename if robocopy kept original name
                $roboCopy = Join-Path $stageDir 'winre.wim'
                if ((Test-Path $roboCopy) -and $roboCopy -ne $destWim) {
                  Move-Item -LiteralPath $roboCopy -Destination $destWim -Force
                }
                if (Test-Path $destWim -ErrorAction SilentlyContinue) {
                  (Get-Item $destWim -Force).Attributes = 'Archive'
                  Write-BuildLog "Found winre.wim (tier 3, offset-based partition mount): $destWim" -Level Success
                  return $destWim
                }
              }
            } finally {
              if ($needsCleanup) {
                Remove-PartitionAccessPath -DiskNumber $winrePart.DiskNumber `
                  -PartitionNumber $winrePart.PartitionNumber `
                  -AccessPath "${mountLetter}:\" -ErrorAction SilentlyContinue
              }
            }
          }
        }
      }
    } catch {
      Write-BuildLog "ReAgent.xml / partition-mount approach failed: $_" -Level Warning
    }
  }

  # ── Tier 4: broad drive scan ──────────────────────────────────────────────
  Write-BuildLog "Scanning all accessible drives for winre.wim..." -Level Info
  foreach ($drv in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Root) {
    foreach ($sub in @('Recovery\WindowsRE\Winre.wim','Recovery\Winre.wim','Windows\System32\Recovery\Winre.wim')) {
      $fp = Join-Path $drv $sub
      if (Test-Path $fp -ErrorAction SilentlyContinue) {
        Write-BuildLog "Found winre.wim (tier 4, drive scan): $fp" -Level Success
        return $fp
      }
    }
  }

  throw (
    "Could not locate winre.wim on this machine.`n" +
    "Common fixes:`n" +
    "  1. Run (as Administrator): reagentc /enable   then reboot and retry`n" +
    "  2. Pass -SourceISO <path-to-windows.iso> instead of -UseWinRE`n" +
    "  3. Manually place winre.wim at: $env:SystemDrive\Recovery\WindowsRE\Winre.wim"
  )
}

# Prepare the WIM source and ISO media structure.
# Modes:
#   -UseWinRE : copies ADK Media + plants winre.wim as sources\boot.wim
#   default   : mounts SourceISO, robocopy contents, returns path to boot.wim
function Mount-SourceISO {

  if ($UseWinRE) {
    Write-BuildLog "WinRE mode: building ISO source from ADK media + local winre.wim..."

    $media = $Script:Config.Tools.WinPEMedia
    if (-not $media -or -not (Test-Path $media)) {
      throw "ADK WinPE media folder not found: $media. Ensure Windows ADK is installed."
    }

    $dst = $Script:Config.Paths.ISO
    Write-BuildLog "Copying ADK media structure from: $media" -Level Info
    robocopy "$media" "$dst" /E /NFL /NDL /R:0 /W:0 /MT:8 | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "Robocopy of ADK media failed (exit $LASTEXITCODE)" }

    # Export or copy winre.wim into sources\ as boot.wim
    $winRESrc = Get-WinRESource
    $bootWimDest = [System.IO.Path]::Combine($dst,"sources","boot.wim")
    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::Combine($dst,"sources")) | Out-Null

    Write-BuildLog "Exporting winre.wim → sources\boot.wim (this may take a minute)..." -Level Info
    # Export index 1 so the result is a standard single-image WIM.
    # DISM handles both normal drive paths and \\?\GLOBALROOT device paths (recovery partition).
    & $Script:Config.Tools.DISM /Export-Image /SourceImageFile:"$winRESrc" /SourceIndex:1 /DestinationImageFile:"$bootWimDest" /DestinationName:"WinRE" /Compress:max | Out-Null
    if ($LASTEXITCODE -ne 0) {
      # Copy-Item cannot access \\?\GLOBALROOT device paths — only attempt it for regular drive paths
      $isDevicePath = $winRESrc -match '^\\\\[?\\]GLOBALROOT'
      if (-not $isDevicePath -and (Test-Path $winRESrc -ErrorAction SilentlyContinue)) {
        Write-BuildLog "DISM export failed (exit $LASTEXITCODE), falling back to Copy-Item..." -Level Warning
        Copy-Item -LiteralPath $winRESrc -Destination $bootWimDest -Force
      } else {
        throw "DISM Export-Image failed (exit $LASTEXITCODE) for: $winRESrc`nThe WinRE WIM could not be exported from the recovery partition.`nTry: reagentc /enable as Administrator and reboot, then retry."
      }
    }

    Write-BuildLog "WinRE WIM staged as sources\boot.wim" -Level Success
    return $bootWimDest

  } else {
    Write-BuildLog "ISO mode: mounting source ISO..."

    if ([string]::IsNullOrWhiteSpace($SourceISO)) { throw "-SourceISO is required when -UseWinRE is not specified." }
    Mount-DiskImage -ImagePath "$SourceISO" -ErrorAction Stop | Out-Null
    $vol = Get-DiskImage -ImagePath "$SourceISO" | Get-Volume
    $letter = $vol.DriveLetter

    if (-not (Test-Path "$letter`:\sources\boot.wim")) {
      throw "Invalid ISO: sources\boot.wim not found"
    }

    Write-BuildLog "Extracting ISO contents..."
    $src = "$letter`:\"
    $dst = $Script:Config.Paths.ISO
    robocopy $src $dst /E /NFL /NDL /R:0 /W:0 /MT:8 | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "Robocopy failed with exit code: $LASTEXITCODE" }

    Dismount-DiskImage -ImagePath "$SourceISO" | Out-Null
    return [System.IO.Path]::Combine($Script:Config.Paths.ISO,"sources","boot.wim")
  }
}

# Inject WiFi support into the mounted WIM:
#   - 3 MDM DLLs from local System32 (required by OSD Start-WinREWiFi)
#   - WirelessConnect.exe (GUI SSID selector, runs from X:\Windows\WirelessConnect.exe)
function Add-WiFiSupport {
  Write-BuildLog "Injecting WiFi support..."
  $mount  = $Script:Config.Paths.Mount
  $sys32  = Join-Path $mount "Windows\System32"
  $winDir = Join-Path $mount "Windows"

  # ---------------------------------------------------------------
  # DLL injection
  # OSD Start-WinREWiFi checks 7 DLLs before enabling WiFi:
  #   Required by all bases (MDM DLLs, not in bare WinPE or WinRE):
  #     dmcmnutils.dll, mdmpostprocessevaluator.dll, mdmregistration.dll
  #   Already present in WinRE but NOT in a bare ADK WinPE:
  #     raschap.dll, raschapext.dll, rastls.dll, rastlsext.dll
  # In WinRE mode the second group is already in the WIM.
  # In plain WinPE mode (-IncludeWiFi without -UseWinRE) we need all 7.
  # ---------------------------------------------------------------
  $mdmDlls = @(
    "dmcmnutils.dll",
    "mdmpostprocessevaluator.dll",
    "mdmregistration.dll"
  )
  $authDlls = @(
    "raschap.dll",
    "raschapext.dll",
    "rastls.dll",
    "rastlsext.dll"
  )
  # For bare WinPE we must inject all 7; for WinRE base the auth DLLs are already present
  $dllsToInject = if ($UseWinRE) { $mdmDlls } else { $mdmDlls + $authDlls }

  $dllsOk = 0
  foreach ($dll in $dllsToInject) {
    $src = Join-Path $env:SystemRoot "System32\$dll"
    if (Test-Path $src) {
      Copy-Item $src (Join-Path $sys32 $dll) -Force
      $dllsOk++
    } else {
      Write-BuildLog "Missing on build machine: $dll  (WiFi may not function without it)" -Level Warning
    }
  }
  Write-BuildLog "Copied $dllsOk / $($dllsToInject.Count) WiFi DLLs" -Level $(if ($dllsOk -eq $dllsToInject.Count) {'Success'} else {'Warning'})

  # ---------------------------------------------------------------
  # Intel Wireless WinPE Driver Pack
  # OSD's '-CloudDriver WiFi' (or '*') downloads the latest Intel
  # Wireless driver pack and injects the INF/SYS files.
  # Without this, WlanSvc starts but no adapter is enumerated on
  # Intel WiFi hardware (the most common chipset in enterprise HW).
  # ---------------------------------------------------------------
  if ($Script:OSDAvailable) {
    Write-BuildLog "Downloading Intel Wireless WinPE driver pack via OSD catalog..." -Level Info
    try {
      $wifiDriverDir = Join-Path $Script:Config.Paths.Temp "WiFi-Drivers"
      $wifiDriverPath = Save-WinPECloudDriver -CloudDriver WiFi -Path $wifiDriverDir
      $wifiFullPath = if ($wifiDriverPath -is [string]) { $wifiDriverPath } else { $wifiDriverPath.FullName }
      if ($wifiFullPath -and (Test-Path $wifiFullPath)) {
        & $Script:Config.Tools.DISM /Add-Driver /Image:"$mount" /Driver:"$wifiFullPath" /Recurse /ForceUnsigned | Out-Null
        if ($LASTEXITCODE -eq 0) {
          $infCount = (Get-ChildItem -Path $wifiFullPath -Filter *.inf -Recurse | Measure-Object).Count
          Write-BuildLog "Injected Intel WiFi WinPE drivers ($infCount INF files)" -Level Success
        } else {
          Write-BuildLog "DISM /Add-Driver for Intel WiFi returned non-zero (exit $LASTEXITCODE)" -Level Warning
        }
      }
    } catch {
      Write-BuildLog "Intel WiFi driver pack failed: $_ (WiFi adapter may not enumerate)" -Level Warning
    }
  } else {
    Write-BuildLog "OSD module not available — Intel WiFi drivers NOT injected. Install OSD (Install-Module OSD) to enable this." -Level Warning
    Write-BuildLog "WiFi may still work if WinRE already contains the correct adapter driver." -Level Warning
  }

  # ---------------------------------------------------------------
  # WirelessConnect.exe
  # GUI SSID selector invoked by Start-WinREWiFi -WirelessConnect.
  # Must live at X:\Windows\WirelessConnect.exe (exact path).
  # ---------------------------------------------------------------
  $wcCache = Join-Path $Script:Config.Paths.Cache "WirelessConnect.exe"
  if (-not (Test-Path $wcCache)) {
    Write-BuildLog "Downloading WirelessConnect.exe..." -Level Info
    Invoke-WebRequest -Uri $Script:AppSources.WirelessConnect -OutFile $wcCache -UseBasicParsing
  }
  Copy-Item $wcCache (Join-Path $winDir "WirelessConnect.exe") -Force
  Write-BuildLog "WirelessConnect.exe → X:\Windows\WirelessConnect.exe" -Level Success
}

# Save the OSD PowerShell module into the mounted WIM so that
# Start-WinREWiFi and Initialize-OSDCloudStartnet are available at boot.
function Add-OSDModuleToWIM {
  Write-BuildLog "Saving OSD module into WinPE image..."
  $mount = $Script:Config.Paths.Mount
  $moduleDest = Join-Path $mount "Program Files\WindowsPowerShell\Modules"
  New-Item -ItemType Directory -Force -Path $moduleDest | Out-Null

  if ($Script:OSDAvailable) {
    try {
      Save-Module -Name OSD -Path $moduleDest -Force -ErrorAction Stop
      Write-BuildLog "OSD module saved to WinPE (enables Start-WinREWiFi at boot)" -Level Success
    } catch {
      Write-BuildLog "Failed to save OSD module: $_ (WiFi connect prompt may not work)" -Level Warning
    }
  } else {
    Write-BuildLog "OSD module not available on build machine — skipping injection" -Level Warning
  }
}

function Mount-TargetWIM {
  param(
    [Parameter(Mandatory)] [string]$WimPath,
    [ValidateSet(1,2)] [int]$Index = 1
  )

  Write-BuildLog "Mounting boot.wim (Index $Index)..."
  Write-BuildLog "WIM file path: $WimPath" -Level Info
  Write-BuildLog "DISM tool: $($Script:Config.Tools.DISM)" -Level Info
  Write-BuildLog "Mount target: $($Script:Config.Paths.Mount)" -Level Info

  # Check if WIM file exists and is accessible
  if (-not (Test-Path "$WimPath")) {
    throw "WIM file not found: $WimPath"
  }

  # Reset WIM file attributes to remove read-only (common issue with ISO-extracted files)
  Write-BuildLog "Resetting WIM file attributes..." -Level Info
  try {
    $wimItem = Get-Item "$WimPath" -Force
    if ($wimItem.Attributes -match 'ReadOnly') {
      $wimItem.Attributes = $wimItem.Attributes -bxor 'ReadOnly'
      Write-BuildLog "Read-only attribute removed from WIM file" -Level Info
    }
  } catch {
    Write-BuildLog "Warning: Could not reset WIM attributes: $_" -Level Warning
  }

  # Clean up any previous mounts at this location
  $existingMount = Get-Item "$($Script:Config.Paths.Mount)" -ErrorAction SilentlyContinue
  if ($existingMount -and (Get-ChildItem "$($Script:Config.Paths.Mount)" -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
    Write-BuildLog "Mount directory not empty, attempting to dismount..." -Level Warning
    & $Script:Config.Tools.DISM /Unmount-Image /MountDir:$($Script:Config.Paths.Mount) /Discard 2>&1 | Out-Null
  }

  $output = & $Script:Config.Tools.DISM /Mount-Image /ImageFile:"$WimPath" /Index:$Index /MountDir:$($Script:Config.Paths.Mount) 2>&1
  $exitCode = $LASTEXITCODE

  Write-BuildLog "DISM mount output (exit code $exitCode):" -Level Info
  $output | ForEach-Object { Write-BuildLog "  $_" -Level Info }

  if ($exitCode -ne 0) {
    $msg = "Failed to mount WIM (exit code $exitCode).`n`nTroubleshooting steps:`n"
    $msg += "1. Ensure PowerShell is running as Administrator (right-click Run as Administrator)`n"
    $msg += "2. Close all file explorers accessing C:\WorkRoot`n"
    $msg += "3. Ensure no previous mounts in C:\WorkRoot\Mount_WIM (DISM /unmount-image /mountdir:C:\WorkRoot\Mount_WIM /discard)`n"
    $msg += "4. Try again`n`nSee DISM log: C:\WINDOWS\Logs\DISM\dism.log"
    throw $msg
  }
  $Script:State.Mounted = $true

  foreach ($hive in "SYSTEM","SOFTWARE") {
    $p = [System.IO.Path]::Combine($Script:Config.Paths.Mount,"Windows","System32","config",$hive)
    if (-not (Test-Path $p)) { throw "$hive hive missing in mounted WIM" }
  }

  Write-BuildLog "WIM mounted successfully" -Level "Success"
}

function Add-WinPE-Packages {
  Write-BuildLog "Installing WinPE optional components..."
  $mount = $Script:Config.Paths.Mount
  $count = 0
  $ocRoot = $Script:Config.Tools.WinPEOCs
  $lang = $Script:Config.Locale
  if (-not (Test-Path ([System.IO.Path]::Combine($ocRoot,$lang)))) { $lang = "en-us" }

  $packages = $Script:WinPEPackages.Clone()
  if ($EnableFBWF) { $packages += "WinPE-FBWF" }

  foreach ($pkg in $packages) {
    $cab = [System.IO.Path]::Combine($ocRoot,"$pkg.cab")
    if (Test-Path $cab) {
      & $Script:Config.Tools.DISM /Add-Package /Image:"$mount" /PackagePath:"$cab" /IgnoreCheck | Out-Null
      if ($LASTEXITCODE -eq 0) { $count++ } else { Write-BuildLog "Failed adding package: $pkg" -Level Warning }
      $langCab = [System.IO.Path]::Combine($ocRoot,$lang,"${pkg}_${lang}.cab")
      if (Test-Path $langCab) {
        & $Script:Config.Tools.DISM /Add-Package /Image:"$mount" /PackagePath:"$langCab" /IgnoreCheck | Out-Null
      }
    } else {
      Write-BuildLog "Package not found in OCs: $pkg (skipped)" -Level Warning
    }
  }

  $Script:Config.Stats.Packages = $count
  Write-BuildLog "Added $count WinPE packages" -Level "Success"
}

function Add-DellDrivers {
  if (-not $IncludeDellDrivers) { return }

  Write-BuildLog "Acquiring Dell WinPE11 drivers..."
  $mount      = $Script:Config.Paths.Mount
  $extractDir = [System.IO.Path]::Combine($Script:Config.Paths.Temp,"DellDrivers")
  New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

  # Prefer OSD catalog (Get-DellWinPEDriverPack returns the current version URL dynamically)
  if ($Script:OSDAvailable) {
    Write-BuildLog "Using OSD Save-WinPECloudDriver -CloudDriver Dell (auto-latest URL)..." -Level Info
    try {
      $driverPath = Save-WinPECloudDriver -CloudDriver Dell -Path $extractDir
      $driverFullPath = if ($driverPath -is [string]) { $driverPath } else { $driverPath.FullName }
      if ($driverFullPath -and (Test-Path $driverFullPath)) {
        & $Script:Config.Tools.DISM /Add-Driver /Image:"$mount" /Driver:"$driverFullPath" /Recurse /ForceUnsigned | Out-Null
        if ($LASTEXITCODE -eq 0) {
          $Script:Config.Stats.DriversAdded += (Get-ChildItem -Path $driverFullPath -Filter *.inf -Recurse | Measure-Object).Count
          Write-BuildLog "Injected $($Script:Config.Stats.DriversAdded) Dell INF drivers (OSD catalog)" -Level Success
        } else {
          Write-BuildLog "DISM /Add-Driver for Dell returned non-zero. Will try hardcoded CAB fallback." -Level Warning
        }
        return
      }
    } catch {
      Write-BuildLog "OSD Save-WinPECloudDriver failed: $_ — falling back to hardcoded URL" -Level Warning
    }
  }

  # Fallback: hardcoded CAB URL (pinned to last known-good version)
  Write-BuildLog "Downloading Dell drivers from hardcoded URL..." -Level Info
  $dellCab = [System.IO.Path]::Combine($Script:Config.Paths.Cache,"Dell-WinPE11-Drivers.cab")
  if (-not (Test-Path $dellCab)) {
    try {
      Invoke-WebRequest -Uri $Script:AppSources.DellWinPEDrivers -OutFile $dellCab -UseBasicParsing
    } catch {
      Write-BuildLog "Failed to download Dell drivers: $_" -Level Warning
      return
    }
  }

  Write-BuildLog "Extracting and injecting Dell drivers..."
  & "$env:SystemRoot\System32\expand.exe" -F:* "$dellCab" "$extractDir" | Out-Null

  if (Test-Path $extractDir) {
    & $Script:Config.Tools.DISM /Add-Driver /Image:"$mount" /Driver:"$extractDir" /Recurse /ForceUnsigned | Out-Null
    if ($LASTEXITCODE -eq 0) {
      $Script:Config.Stats.DriversAdded = (Get-ChildItem -Path $extractDir -Filter *.inf -Recurse | Measure-Object).Count
      Write-BuildLog "Injected $($Script:Config.Stats.DriversAdded) Dell INF drivers (hardcoded CAB)" -Level Success
    } else {
      Write-BuildLog "DISM /Add-Driver failed for Dell drivers" -Level Warning
    }
  }
}

# ============================================
# APPLICATIONS
# ============================================
function Ensure-7z {
  if (Get-Command 7z -ErrorAction SilentlyContinue) { return "7z" }
  $tools = Join-Path $Script:Config.Paths.Cache "tools"
  New-Item -ItemType Directory -Force -Path $tools | Out-Null
  $sevenZr = Join-Path $tools "7zr.exe"
  if (-not (Test-Path $sevenZr)) {
    Invoke-WebRequest -Uri $Script:AppSources.SevenZipMini -OutFile $sevenZr -UseBasicParsing
  }
  return $sevenZr
}

function Expand-7z {
  param(
    [Parameter(Mandatory)] [string]$ArchivePath,
    [Parameter(Mandatory)] [string]$Destination
  )
  $seven = Ensure-7z
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  & $seven x "$ArchivePath" -o"$Destination" -y | Out-Null
}

function Find-ExeUnder { param([string]$Root,[string]$ExeName) if (-not (Test-Path $Root)) { return $null } Get-ChildItem -Path $Root -Recurse -File -Filter $ExeName -ErrorAction SilentlyContinue | Select-Object -First 1 }

function Assert-ChromePlusLayout {
  param([string]$ChromeRoot)
  $chrome = Find-ExeUnder -Root $ChromeRoot -ExeName 'chrome.exe'
  if (-not $chrome) {
    throw "Chrome program files not found under: $ChromeRoot. Per upstream, extract Chrome's offline installer to obtain the program files and place them here."
  }
  $versionDll = Join-Path $chrome.Directory.FullName 'version.dll'
  if (-not (Test-Path $versionDll)) {
    throw "Chrome++ patch not in effect: version.dll missing next to chrome.exe at: $($chrome.Directory.FullName). Ensure Chrome++ 'version.dll' sits beside chrome.exe."
  }
  return $chrome.FullName
}

# Extract Chrome program files from a 7z SFX archive (Bush2021 uncompressed.exe or PortableApps paf.exe).
# IMPORTANT: These files must NEVER be executed as a process — doing so triggers a real Chrome
# installation on the host machine. We extract with 7z only (treat as a plain archive).
function Expand-ChromeArchive {
  param([string]$Archive, [string]$Dest)
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null
  Expand-7z -ArchivePath $Archive -Destination $Dest
}

function Get-Applications {
  Write-BuildLog "Downloading portable applications..."

  $cache = $Script:Config.Paths.Cache
  $apps = $Script:Config.Paths.Apps

  # --- WinXShell (portable shell for WinPE) ---
  $wxZip = Join-Path $cache "WinXShell.7z"
  if (-not (Test-Path $wxZip)) {
    Invoke-WebRequest -Uri $Script:AppSources.WinXShell -OutFile $wxZip -UseBasicParsing
  }
  $wxDest = Join-Path $apps "WinXShell"
  Expand-7z -ArchivePath $wxZip -Destination $wxDest
  $Script:Config.Apps.WinXShell = $wxDest

  # --- 7-Zip (full portable for the image) ---
  Write-BuildLog "Downloading 7-Zip portable..."
  $szDest = Join-Path $apps "7-Zip"
  New-Item -ItemType Directory -Force -Path $szDest | Out-Null
  $szExe = Join-Path $cache "7z-full.exe"
  if (-not (Test-Path $szExe)) {
    try {
      Invoke-WebRequest -Uri $Script:AppSources.SevenZipFull -OutFile $szExe -UseBasicParsing
    } catch {
      Write-BuildLog "Failed to download 7-Zip full installer, trying extra archive..." -Level Warning
      $szExtra = Join-Path $cache "7z-extra.7z"
      Invoke-WebRequest -Uri $Script:AppSources.SevenZipExtra -OutFile $szExtra -UseBasicParsing
      Expand-7z -ArchivePath $szExtra -Destination $szDest
      $szExe = $null
    }
  }
  if ($szExe -and (Test-Path $szExe)) {
    # 7-Zip installer supports /D= for target directory and /S for silent
    try {
      Start-Process -FilePath $szExe -ArgumentList "/S /D=$szDest" -Wait -WindowStyle Hidden -ErrorAction Stop
    } catch {
      Expand-7z -ArchivePath $szExe -Destination $szDest
    }
  }
  $Script:Config.Apps.'7-Zip' = $szDest
  Write-BuildLog "7-Zip prepared for injection" -Level "Success"

  # --- IBM Semeru Java (prefer latest; fallback to prior) ---
  $jvZip = Join-Path $cache "Semeru.zip"
  if (-not (Test-Path $jvZip)) {
    try { Invoke-WebRequest -Uri $Script:AppSources.SemeruPrimary -OutFile $jvZip -UseBasicParsing }
    catch { Invoke-WebRequest -Uri $Script:AppSources.SemeruFallback -OutFile $jvZip -UseBasicParsing }
  }
  $javaRoot = Join-Path $apps "Java"
  Expand-Archive $jvZip $javaRoot -Force
  # Flatten nested folder: Semeru ZIPs extract to e.g. Java\jdk8u482-b08\...
  $nested = Get-ChildItem -Path $javaRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'bin') }
  if ($nested -and $nested.Count -eq 1) {
    $nestedPath = $nested[0].FullName
    Write-BuildLog "Flattening nested Java directory: $($nested[0].Name)"
    Get-ChildItem -Path $nestedPath -Force | Move-Item -Destination $javaRoot -Force
    Remove-Item $nestedPath -Force -ErrorAction SilentlyContinue
  }
  $Script:Config.Apps.Java = $javaRoot

  # --- Explorer++ portable ---
  if ($IncludeExplorerPlus) {
    $epZip = Join-Path $cache "ExplorerPP.zip"
    if (-not (Test-Path $epZip)) {
      Invoke-WebRequest -Uri $Script:AppSources.ExplorerPlusPlus -OutFile $epZip -UseBasicParsing
    }
    Expand-Archive $epZip (Join-Path $apps "ExplorerPP") -Force
    $Script:Config.Apps.ExplorerPP = Join-Path $apps "ExplorerPP"
  }

  # --- Chrome (Chrome++ or user-provided portable) ---
  if ($UseChromePlus) {
    Write-BuildLog "Downloading Chrome Plus (Chrome++)..."
    $cp7z = Join-Path $cache "ChromePlus.7z"
    if (-not (Test-Path $cp7z)) {
      Invoke-WebRequest -Uri $Script:AppSources.ChromePlus -OutFile $cp7z -UseBasicParsing
    }
    $chPath = Join-Path $apps "Chrome"
    Expand-7z -ArchivePath $cp7z -Destination $chPath

    # If chrome.exe not found in Chrome++ .7z, acquire Chrome program files separately.
    # Chrome++ only ships version.dll (the patch); chrome.exe comes from a separate source.
    # ALL sources below are extracted with 7z only — never executed as a process.
    if (-not (Find-ExeUnder -Root $chPath -ExeName 'chrome.exe')) {
      Write-BuildLog "Chrome++ .7z does not contain chrome.exe — fetching Chrome program files..." -Level Info

      # Stash the version.dll from Chrome++ before we start filling the directory
      $versionDllSource = Find-ExeUnder -Root $chPath -ExeName 'version.dll'

      $chromeFetched = $false

      # ── Source A: user-supplied archive (highest priority) ──────────────
      if ($ChromeOfflineInstallerPath) {
        Write-BuildLog "Extracting Chrome from user-supplied archive (7z)..." -Level Info
        Expand-ChromeArchive -Archive $ChromeOfflineInstallerPath -Dest $chPath
        $chromeFetched = $true
      }

      # ── Source B: Bush2021/chrome_installer GitHub (7z SFX) ─────────────
      # x64_<ver>_chrome_installer_uncompressed.exe = 7z SFX of pre-extracted Chrome.
      # Structure after extraction: Chrome-bin\<version>\chrome.exe
      if (-not $chromeFetched) {
        $sfxCache = Join-Path $cache "chrome_sfx.exe"
        try {
          if (-not (Test-Path $sfxCache)) {
            Write-BuildLog "Downloading Chrome SFX (Bush2021/chrome_installer, GitHub)..." -Level Info
            Invoke-WebRequest -Uri $Script:AppSources.ChromeUnpackedSFX -OutFile $sfxCache -UseBasicParsing
          }
          Write-BuildLog "Extracting Chrome SFX with 7z (no execution)..." -Level Info
          Expand-ChromeArchive -Archive $sfxCache -Dest $chPath
          $chromeFetched = $true
        } catch {
          Write-BuildLog "Bush2021 GitHub download failed: $_" -Level Warning
          Remove-Item $sfxCache -Force -ErrorAction SilentlyContinue
        }
      }

      # ── Source C: Bush2021 CDN mirror (same 7z SFX, different host) ──────
      if (-not $chromeFetched) {
        $sfxCdn = Join-Path $cache "chrome_sfx_cdn.exe"
        try {
          if (-not (Test-Path $sfxCdn)) {
            Write-BuildLog "Downloading Chrome SFX (CDN mirror)..." -Level Info
            Invoke-WebRequest -Uri $Script:AppSources.ChromeUnpackedSFX_CDN -OutFile $sfxCdn -UseBasicParsing
          }
          Expand-ChromeArchive -Archive $sfxCdn -Dest $chPath
          $chromeFetched = $true
        } catch {
          Write-BuildLog "CDN mirror download failed: $_" -Level Warning
          Remove-Item $sfxCdn -Force -ErrorAction SilentlyContinue
        }
      }

      # ── Source D: PortableApps GoogleChromePortable paf.exe (NSIS/7z) ───
      # 7z extracts it to: App\Chrome-bin\<version>\chrome.exe
      # NEVER executed — 7z archive extraction only.
      if (-not $chromeFetched) {
        $pafCache = Join-Path $cache "GoogleChromePortable.paf.exe"
        try {
          if (-not (Test-Path $pafCache)) {
            Write-BuildLog "Downloading Chrome from PortableApps (paf.exe, 7z extract only)..." -Level Info
            Invoke-WebRequest -Uri $Script:AppSources.ChromePortableApps -OutFile $pafCache -UseBasicParsing
          }
          Expand-ChromeArchive -Archive $pafCache -Dest $chPath
          $chromeFetched = $true
        } catch {
          Write-BuildLog "PortableApps download failed: $_" -Level Warning
          Remove-Item $pafCache -Force -ErrorAction SilentlyContinue
        }
      }

      if (-not $chromeFetched -or -not (Find-ExeUnder -Root $chPath -ExeName 'chrome.exe')) {
        Write-BuildLog "All Chrome sources exhausted — skipping Chrome++ integration" -Level Warning
        Write-BuildLog "Tip: pass -ChromeOfflineInstallerPath to supply chrome.exe manually" -Level Warning
        return
      }

      # ── Apply Chrome++ patch: place version.dll next to chrome.exe ───────
      $chromeExeFound = Find-ExeUnder -Root $chPath -ExeName 'chrome.exe'
      if ($versionDllSource -and $chromeExeFound) {
        $versionDllDest = Join-Path $chromeExeFound.Directory.FullName 'version.dll'
        if (-not (Test-Path $versionDllDest)) {
          Copy-Item $versionDllSource.FullName $versionDllDest -Force
          Write-BuildLog "Chrome++ version.dll placed next to chrome.exe" -Level Info
        }
      }
    }

    # Validate Chrome++ co-location (version.dll next to chrome.exe)
    $Script:Config.Apps.ChromeExe = Assert-ChromePlusLayout -ChromeRoot $chPath
    $Script:Config.Apps.Chrome = $chPath
  }
  elseif ($ChromePortablePath) {
    $chDest = Join-Path $apps "Chrome"
    $ext = [System.IO.Path]::GetExtension("$ChromePortablePath").ToLower()
    if ($ext -eq ".zip") {
      Expand-Archive "$ChromePortablePath" "$chDest" -Force
    } else {
      # .7z, .exe (SFX), .paf.exe — all treated as 7z archives; never executed as a process
      Expand-7z -ArchivePath "$ChromePortablePath" -Destination "$chDest"
    }
    $chrome = Find-ExeUnder -Root $chDest -ExeName 'chrome.exe'
    if ($chrome) { $Script:Config.Apps.ChromeExe = $chrome.FullName }
    $Script:Config.Apps.Chrome = $chDest
  }
}

function Inject-AllApps {
  Write-BuildLog "Injecting applications into WIM image..."

  $progFiles = Join-Path $Script:Config.Paths.Mount "Program Files\PortableApps"
  New-Item -Path $progFiles -ItemType Directory -Force | Out-Null

  foreach ($app in $Script:Config.Apps.GetEnumerator()) {
    if ($app.Key -eq 'ChromeExe') { continue } # not a folder
    Write-BuildLog "Injecting: $($app.Key)"
    $dest = Join-Path $progFiles "$($app.Key)"
    New-Item -Path $dest -ItemType Directory -Force | Out-Null
    Copy-Item "$($app.Value)\*" "$dest" -Recurse -Force -ErrorAction SilentlyContinue
    $Script:Config.Stats.Apps++
  }

  if ($WallpaperPath) {
    Write-BuildLog "Injecting custom wallpaper..."
    $wallDir = Join-Path $Script:Config.Paths.Mount "Windows\Web\Wallpaper\RAMOS"
    New-Item -Path $wallDir -ItemType Directory -Force | Out-Null
    Copy-Item "$WallpaperPath" (Join-Path $wallDir "custom.jpg") -Force
    $Script:Config.WallpaperDest = "C:\Windows\Web\Wallpaper\RAMOS\custom.jpg"
  }
}

# ============================================
# REGISTRY (minimal; no FBWF on by default)
# ============================================
function Configure-SystemRegistry {
  Write-BuildLog "Configuring Registry (minimal)…"
  $mount = $Script:Config.Paths.Mount

  $sysPath = Join-Path "$mount" "Windows\System32\config\SYSTEM"
  $softPath = Join-Path "$mount" "Windows\System32\config\SOFTWARE"

  reg load "HKLM\RAM_SYS" "$sysPath" | Out-Null
  reg load "HKLM\RAM_SW" "$softPath" | Out-Null

  try {
    # Shell is driven entirely by winpeshl.ini (WinXShell + Explorer++); clear the registry value
    reg add "HKLM\RAM_SW\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /t REG_SZ /d "" /f | Out-Null

    if ($Script:Config.Apps.ContainsKey("Java")) {
      $javaInstall = "C:\Program Files\PortableApps\Java"
      reg add "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v JAVA_HOME /t REG_SZ /d "$javaInstall" /f | Out-Null
      # Append Java\bin to PATH so java.exe is callable without full path
      $existingPath = (reg query "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v Path 2>$null |
        Select-String 'REG_EXPAND_SZ|REG_SZ' |
        ForEach-Object { $_.Line -replace '^\s*\S+\s+REG_\S+\s+', '' }) -join ''
      if ($existingPath) {
        reg add "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v Path /t REG_EXPAND_SZ /d "$existingPath;$javaInstall\bin" /f | Out-Null
      } else {
        reg add "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v Path /t REG_EXPAND_SZ /d "%SystemRoot%\System32;%SystemRoot%;$javaInstall\bin" /f | Out-Null
      }
      Write-BuildLog "JAVA_HOME and PATH configured for Java" -Level "Success"
    }

    # Add 7-Zip to PATH
    if ($Script:Config.Apps.ContainsKey("7-Zip")) {
      $szInstall = "C:\Program Files\PortableApps\7-Zip"
      $existingPath = (reg query "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v Path 2>$null |
        Select-String 'REG_EXPAND_SZ|REG_SZ' |
        ForEach-Object { $_.Line -replace '^\s*\S+\s+REG_\S+\s+', '' }) -join ''
      if ($existingPath) {
        reg add "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v Path /t REG_EXPAND_SZ /d "$existingPath;$szInstall" /f | Out-Null
      } else {
        reg add "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v Path /t REG_EXPAND_SZ /d "%SystemRoot%\System32;%SystemRoot%;$szInstall" /f | Out-Null
      }
      Write-BuildLog "7-Zip added to PATH" -Level "Success"
    }

    if ($IncludeExplorerPlus) {
      reg add "HKLM\RAM_SW\Classes\Directory\shell\ExplorerPP" /ve /d "Open with Explorer++" /f | Out-Null
      reg add "HKLM\RAM_SW\Classes\Directory\shell\ExplorerPP\command" /ve /d "C:\Program Files\PortableApps\ExplorerPP\Explorer++.exe `"%1`"" /f | Out-Null
    }

    if ($EnableFBWF) {
      # Set desired overlay size (enablement typically requires reboot; we don't force it here)
      reg add "HKLM\RAM_SYS\ControlSet001\Control\FBWF" /v OverlaySize /t REG_DWORD /d $RamdiskSizeMB /f | Out-Null
    }
  }
  finally {
    reg unload "HKLM\RAM_SYS" | Out-Null
    reg unload "HKLM\RAM_SW" | Out-Null
  }

  Write-BuildLog "Registry configured" -Level "Success"
}

# ============================================
# SHELL & STARTUP
# ============================================
function Create-StartupScript {
  Write-BuildLog "Creating StartNet.cmd..."
  $mount = $Script:Config.Paths.Mount

  $wifiEnabled = ($UseWinRE -or $IncludeWiFi)

  # Base block: wpeinit + wired network init
  $content = @'
@echo off
echo ==========================================
echo   RAM OS - Initializing WinPE
echo ==========================================
wpeinit

REM Initialize wired network (DHCP) and disable firewall
wpeutil InitializeNetwork
wpeutil WaitForNetwork
wpeutil DisableFirewall
'@

  if ($wifiEnabled) {
    # OSD Initialize-OSDCloudStartnet -WirelessConnect handles the full WiFi flow:
    #   1. Checks if already online (Test-WebConnection google.com) — skips if wired is up
    #   2. Verifies dmcmnutils.dll is present (guard for injected DLLs)
    #   3. Starts WlanSvc if not running
    #   4. Detects WiFi adapter via Get-SmbClientNetworkInterface
    #   5. Checks HP UEFI for pre-provisioned WiFi profile (bonus for HP fleet)
    #   6. Launches WirelessConnect.exe (X:\Windows\WirelessConnect.exe) for GUI SSID selection
    #      OR uses a saved wifiProfile.xml for unattended connection
    # This mirrors exactly what the user's working Edit-OSDCloudWinPE code produced.
    $content += @'

REM === WiFi Initialization ===
REM OSD Initialize-OSDCloudStartnet: checks connectivity, starts WlanSvc,
REM detects adapter, then launches WirelessConnect.exe for SSID selection.
REM Falls back to inline WlanSvc start if OSD module is not in image.
PowerShell -NoLogo -NonInteractive -Command "& { if (Get-Command Initialize-OSDCloudStartnet -ErrorAction Ignore) { Initialize-OSDCloudStartnet -WirelessConnect } else { net start WlanSvc; Start-Sleep -Seconds 3; if (Test-Path X:\Windows\WirelessConnect.exe) { Start-Process X:\Windows\WirelessConnect.exe -Wait } } }"
'@
  }

  $content += @'

exit /b 0
'@

  Set-Content -Path (Join-Path "$mount" "Windows\System32\StartNet.cmd") -Value $content -Force -Encoding ASCII
  Write-BuildLog "StartNet.cmd created$(if ($wifiEnabled) { ' (WiFi: Initialize-OSDCloudStartnet -WirelessConnect)' })" -Level "Success"
}

function Create-PostShellScript {
  Write-BuildLog "Creating PostShell.cmd..."
  $mount = $Script:Config.Paths.Mount
  $postDir = Join-Path $mount "Windows\System32\RAMOS"
  New-Item -ItemType Directory -Force -Path $postDir | Out-Null

  $wall = $Script:Config.WallpaperDest

  $post = @'
@echo off
REM Apply visual tweaks for current user after Explorer has started
if exist "%SystemRoot%\System32\reg.exe" (
  if not "{WALL}"=="" if exist "{WALL}" (
    reg add "HKCU\Control Panel\Desktop" /v Wallpaper /t REG_SZ /d "{WALL}" /f
    rundll32.exe user32.dll,UpdatePerUserSystemParameters
  )
  REM Accent color (DWM colorization)
  reg add "HKCU\Software\Microsoft\Windows\DWM" /v ColorPrevalence /t REG_DWORD /d 1 /f >nul 2>&1
  reg add "HKCU\Software\Microsoft\Windows\DWM" /v AccentColor /t REG_DWORD /d 0x{ACCENT} /f >nul 2>&1
  reg add "HKCU\Software\Microsoft\Windows\DWM" /v ColorizationColor /t REG_DWORD /d 0x{ACCENT} /f >nul 2>&1
)
exit /b 0
'@.Replace("{WALL}",$(if ($wall) { $wall } else { "" })).Replace("{ACCENT}",$AccentColor)

  Set-Content -Path (Join-Path $postDir "PostShell.cmd") -Value $post -Encoding ASCII -Force
  Write-BuildLog "PostShell.cmd created" -Level "Success"
}

function Create-ChromeLauncher {
  if (-not $Script:Config.Apps.ChromeExe) { return }
  Write-BuildLog "Creating Chrome launcher (X:\ profile)..."
  $mount = $Script:Config.Paths.Mount
  $tools = Join-Path $mount "Windows\System32\RAMOS"
  New-Item -ItemType Directory -Force -Path $tools | Out-Null

  # Convert build-time chrome.exe path to runtime path inside the WIM
  # Build path:   D:\Build\Apps\Chrome\Application\chrome.exe
  # Runtime path: C:\Program Files\PortableApps\Chrome\Application\chrome.exe
  $buildAppsRoot = $Script:Config.Paths.Apps
  $runtimeAppsRoot = "C:\Program Files\PortableApps"
  $chromeExeRuntime = $Script:Config.Apps.ChromeExe -replace [regex]::Escape($buildAppsRoot),$runtimeAppsRoot

  $launcher = @'
@echo off
set "PROFILE=X:\ChromeProfile"
set "CACHE=X:\ChromeCache"
if not exist "%PROFILE%" mkdir "%PROFILE%"
if not exist "%CACHE%" mkdir "%CACHE%"
start "" "{CHROME}" --user-data-dir="%PROFILE%" --disk-cache-dir="%CACHE%" --no-first-run --no-default-browser-check
exit /b 0
'@.Replace('{CHROME}',$chromeExeRuntime)

  Set-Content -Path (Join-Path $tools "StartChrome.cmd") -Value $launcher -Encoding ASCII -Force
}

function Write-Winpeshl {
  Write-BuildLog "Writing winpeshl.ini..."
  $mount = $Script:Config.Paths.Mount
  $iniPath = Join-Path $mount "Windows\System32\winpeshl.ini"

  $launch = @("[LaunchApps]")

  # Shell: WinXShell (primary) + Explorer++ (optional file manager); no Microsoft explorer.exe
  $mountedBase = Join-Path $mount "Program Files\PortableApps"
  $foundWX = Find-ExeUnder -Root (Join-Path $mountedBase "WinXShell") -ExeName "WinXShell.exe"
  $winxShellPath = if ($foundWX) { $foundWX.FullName } else { $null }
  $foundEP = Find-ExeUnder -Root (Join-Path $mountedBase "ExplorerPP") -ExeName "Explorer++.exe"
  $explorerPPPath = if ($foundEP) { $foundEP.FullName } else { $null }

  # Primary shell: WinXShell
  if ($winxShellPath) {
    $winxShellPath = $winxShellPath -replace [regex]::Escape($mount),'C:'
    $launch += '"' + $winxShellPath + '"'
    Write-BuildLog "WinXShell set as primary shell" -Level "Success"
  } else {
    Write-BuildLog "WinXShell not found in WIM — falling back to cmd.exe shell" -Level "Warning"
    $launch += 'cmd.exe'
  }

  # File manager: Explorer++ (optional)
  if ($IncludeExplorerPlus -and $explorerPPPath) {
    $explorerPPPath = $explorerPPPath -replace [regex]::Escape($mount),'C:'
    $launch += '"' + $explorerPPPath + '"'
    Write-BuildLog "Explorer++ added as file manager" -Level "Success"
  }

  # If Chrome launcher exists, run it after Explorer so profile lives on X:\
  $chromeLauncher = "%SystemRoot%\System32\RAMOS\StartChrome.cmd"
  if (Test-Path (Join-Path $mount "Windows\System32\RAMOS\StartChrome.cmd")) {
    $launch += '"' + $chromeLauncher + '"'
  }

  $launch += '"%SystemRoot%\System32\RAMOS\PostShell.cmd"'

  Set-Content -Path $iniPath -Value ($launch -join "`r`n") -Encoding ASCII -Force
  Write-BuildLog "winpeshl.ini written" -Level "Success"
}

# ============================================
# ISO BUILD
# ============================================
function Build-FinalISO {
  Write-BuildLog "Building final ISO image..."

  $mount = $Script:Config.Paths.Mount
  $isoSource = $Script:Config.Paths.ISO

  & $Script:Config.Tools.DISM /Unmount-Image /MountDir:"$mount" /Commit | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to commit WIM changes" }
  $Script:State.Mounted = $false

  $outputPath = Join-Path $Script:Config.Paths.Output "$OutputISOName"

  # Resolve boot sector files:
  #   ADK mode (OSD)   → stored in $Script:Config.Tools by Get-WindowsAdkPaths
  #   ISO mode fallback → extracted into the ISO source folder
  if ($Script:Config.Tools.EtfsBootCom -and (Test-Path $Script:Config.Tools.EtfsBootCom)) {
    $bootFile = $Script:Config.Tools.EtfsBootCom
  } else {
    $bootFile = Join-Path "$isoSource" "boot\etfsboot.com"
  }

  if ($Script:Config.Tools.EfiSysNoprompt -and (Test-Path $Script:Config.Tools.EfiSysNoprompt)) {
    $efiFile = $Script:Config.Tools.EfiSysNoprompt
  } else {
    $efiFile = Join-Path "$isoSource" "efi\Microsoft\boot\efisys_noprompt.bin"
    if (-not (Test-Path $efiFile)) { $efiFile = Join-Path "$isoSource" "efi\Microsoft\boot\efisys.bin" }
  }

  if (-not (Test-Path "$bootFile")) { throw "Boot sector file not found: $bootFile (checked ADK paths and ISO source folder)" }

  $label = [System.IO.Path]::GetFileNameWithoutExtension($OutputISOName)
  $argList = @("-m","-o","-u2","-udfver102","-l$label")

  if (Test-Path "$efiFile") {
    $bootData = ('-bootdata:2#p0,e,b"{0}"#pEF,e,b"{1}"' -f "$bootFile","$efiFile")
    $argList += $bootData
  } else {
    $argList += "-b$bootFile"
  }
  $argList += @("$isoSource","$outputPath")

  Write-BuildLog "Running OSCDIMG with arguments: $($argList -join ' ')" -Level Info
  $oscdimgOutput = & $Script:Config.Tools.OSCDIMG $argList 2>&1
  $oscdimgExit = $LASTEXITCODE

  # Log OSCDIMG output for debugging
  if ($oscdimgOutput) {
    Write-BuildLog "OSCDIMG output:" -Level Info
    $oscdimgOutput | ForEach-Object { Write-BuildLog "  $_" -Level Info }
  }

  if ($oscdimgExit -ne 0) {
    $errorMsg = "OSCDIMG failed to create ISO (exit $oscdimgExit)"
    if ($oscdimgOutput) {
      $errorMsg += "`n`nOSCDIMG Output:`n" + ($oscdimgOutput -join "`n")
    }
    throw $errorMsg
  }

  return $outputPath
}

# ============================================
# MAIN
# ============================================
try {
  Initialize-BuildEnvironment

  $bootWim = Mount-SourceISO
  try { Copy-Item $bootWim "$($bootWim).bak" -Force } catch {}

  # WinRE WIM always has exactly one image index; user-supplied WimIndex applies to ISO mode only
  $effectiveIndex = if ($UseWinRE) { 1 } else { $WimIndex }
  Mount-TargetWIM -WimPath "$bootWim" -Index $effectiveIndex

  Add-WinPE-Packages
  Add-DellDrivers

  # WiFi support: inject MDM DLLs, Intel WiFi drivers, WirelessConnect.exe
  # Automatically applied in WinRE mode; also triggered by explicit -IncludeWiFi
  if ($UseWinRE -or $IncludeWiFi) {
    Add-WiFiSupport
    # Inject OSD module into WinPE so Initialize-OSDCloudStartnet / Start-WinREWiFi
    # are available at boot time (required for the WiFi init in StartNet.cmd to work)
    Add-OSDModuleToWIM
  }

  Get-Applications
  Inject-AllApps

  Configure-SystemRegistry
  Create-PostShellScript
  Create-ChromeLauncher
  Write-Winpeshl
  Create-StartupScript

  $finalIso = Build-FinalISO

  # Summary
  Write-BuildLog "BUILD COMPLETED SUCCESSFULLY" -Level "Success"
  Write-BuildLog "Output: $finalIso" -Level "Success"
  Write-BuildLog ("Size: {0} MB" -f ([math]::Round((Get-Item $finalIso).Length / 1MB,2))) -Level "Success"

  Write-Host "`n=========================================" -ForegroundColor Green
  Write-Host "RAM OS Build Summary" -ForegroundColor Green
  Write-Host "=========================================" -ForegroundColor Green
  Write-Host "Output File: $finalIso" -ForegroundColor White
  Write-Host "Base WIM: $(if ($UseWinRE) { 'WinRE (local winre.wim)' } else { 'WinPE (from ISO)' })" -ForegroundColor White
  Write-Host "Packages Added: $($Script:Config.Stats.Packages)" -ForegroundColor Gray
  Write-Host "Applications: $($Script:Config.Stats.Apps)" -ForegroundColor Gray
  Write-Host "Drivers (INF count): $($Script:Config.Stats.DriversAdded)" -ForegroundColor Gray
  if ($EnableFBWF) { Write-Host "FBWF: OC added (enablement usually requires reboot; not needed for RAM operation)" -ForegroundColor Gray }
  Write-Host "`nFeatures:" -ForegroundColor Cyan
  Write-Host "  [+] 7-Zip (injected + on PATH)" -ForegroundColor Gray
  Write-Host "  [+] IBM Semeru Java 8 (JAVA_HOME + on PATH)" -ForegroundColor Gray
  Write-Host "  [+] WinXShell (lightweight WinPE shell)" -ForegroundColor Gray
  if ($UseWinRE -or $IncludeWiFi) { Write-Host "  [+] WiFi support (MDM DLLs, Intel WiFi drivers, WirelessConnect.exe, OSD module, WlanSvc at boot)" -ForegroundColor Gray }
  if ($UseChromePlus) { Write-Host "  [+] Chrome++ (Chrome Plus) with portable validation" -ForegroundColor Gray }
  if ($IncludeExplorerPlus) { Write-Host "  [+] Explorer++ File Manager" -ForegroundColor Gray }
  if ($IncludeDellDrivers) { Write-Host "  [+] Dell WinPE11 Drivers (INF injected)" -ForegroundColor Gray }
  if ($WallpaperPath) { Write-Host "  [+] Custom Wallpaper" -ForegroundColor Gray }
  Write-Host "=========================================" -ForegroundColor Green
  Write-Host "`nBoot Instructions:" -ForegroundColor Yellow
  Write-Host "1. Write ISO to USB (Rufus/Ventoy) or mount in VM" -ForegroundColor White
  Write-Host "2. Boot from USB - WinPE runs from X:\ (RAM)" -ForegroundColor White
  Write-Host "3. Desktop appears - you can eject USB now" -ForegroundColor White
  Write-Host "4. Changes live in RAM and are lost on reboot" -ForegroundColor White

} catch {
  Write-BuildLog "BUILD FAILED: $_" -Level "Error"
  Write-BuildLog "Stack: $($_.ScriptStackTrace)" -Level "Error"
  exit 1
} finally {
  Invoke-Cleanup -Preserve:$KeepMountedWIM
}
