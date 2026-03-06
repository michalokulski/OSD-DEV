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
  [switch]$EnableFBWF,

  # ── ADK Enhancement (install.wim component injection) ──────────────────────
  # Path to a Windows 10/11 ISO containing install.wim.
  # In ISO mode (-SourceISO), if omitted, install.wim is auto-discovered from the
  # already-extracted SourceISO (no re-download needed).
  # In WinRE mode (-UseWinRE), provide this to unlock the full enhancement pass.
  [Parameter(Mandatory = $false)]
  [ValidateScript({
      if ($_) {
        if (-not (Test-Path "$_")) { throw "EnhanceFromISO not found: $_" }
        if ([IO.Path]::GetExtension("$_").ToLower() -ne '.iso') { throw "EnhanceFromISO must be an .iso file" }
      }
      $true
    })]
  [string]$EnhanceFromISO = "",

  # Index inside install.wim to use as component source.
  # Default 1 is correct for most retail Windows ISOs.
  [Parameter(Mandatory = $false)]
  [ValidateRange(1,16)]
  [int]$InstallWimIndex = 1,

  # Include WoW64 (32-bit compatibility layer) — 150+ DLLs from PhoenixPE minimal list.
  # Enables 32-bit recovery / forensics tools in a 64-bit WinPE. Adds ~150-300 MB.
  [Parameter(Mandatory = $false)]
  [switch]$IncludeWoW64,

  # Inject audio subsystem (audiodg, WASAPI, etc.) from install.wim.
  [Parameter(Mandatory = $false)]
  [switch]$IncludeAudio,

  # Inject shell components (Explorer, DWM, shell32, XAML) from install.wim.
  # Enable for builds that need the full Windows desktop shell.
  [Parameter(Mandatory = $false)]
  [switch]$IncludeShell,

  # WinPE scratch space in MB (RAM disk used by DISM/Setup — separate from FBWF).
  # Valid values: 32, 64, 128, 256, 512.
  [Parameter(Mandatory = $false)]
  [ValidateSet(32,64,128,256,512)]
  [int]$ScratchSpaceMB = 512
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
  # Forum Source: http://bbs.wuyou.net/forum.php?mod=viewthread&tid=371541
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
# Packages match OSD's WindowsAdk.ps1 New-WinPE function (Add-WindowsPackage -Path order matters — dependencies first)
# WiFi/SRT packages appended after the OSD base set
$Script:WinPEPackages = @(
  # ── OSD base set (same order as OSD's WindowsAdk.ps1) ──
  "WinPE-WMI",
  "WinPE-HTA",
  "WinPE-NetFx",
  "WinPE-Scripting",
  "WinPE-PowerShell",
  "WinPE-SecureStartup",
  "WinPE-DismCmdlets",
  "WinPE-Dot3Svc",
  "WinPE-EnhancedStorage",
  "WinPE-FMAPI",
  "WinPE-GamingPeripherals",
  "WinPE-PPPoE",
  "WinPE-PlatformId",
  "WinPE-PmemCmdlets",
  "WinPE-RNDIS",
  "WinPE-SecureBootCmdlets",
  "WinPE-StorageWMI",
  "WinPE-WDS-Tools",
  # ── Extra packages not in OSD base but useful for this build ──
  "WinPE-Fonts-Legacy",
  "WinPE-WiFi-Package",  # ADK for Windows 10 name
  "WinPE-WiFi",           # ADK for Windows 11 alternate name; skipped if .cab absent
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
  $mount  = $Script:Config.Paths.Mount
  $ocRoot = $Script:Config.Tools.WinPEOCs
  $lang   = $Script:Config.Locale
  if (-not (Test-Path ([System.IO.Path]::Combine($ocRoot,$lang)))) { $lang = 'en-us' }
  $count  = 0
  $skipped = 0

  $packages = $Script:WinPEPackages.Clone()
  if ($EnableFBWF) { $packages += 'WinPE-FBWF' }

  # Match OSD's WindowsAdk.ps1 pattern:
  #   Add-WindowsPackage -Path (offline, NOT -Online) with $ErrorActionPreference = 'Ignore'
  #   No /IgnoreCheck — let DISM report real failures; missing .cab is silently skipped
  foreach ($pkg in $packages) {
    $cab = [System.IO.Path]::Combine($ocRoot, "$pkg.cab")
    if (-not (Test-Path $cab)) {
      Write-BuildLog "  Package not found, skipping: $pkg" -Level Warning
      $skipped++
      continue
    }
    try {
      Add-WindowsPackage -Path $mount -PackagePath $cab -ErrorAction Stop | Out-Null
      $count++
    } catch {
      Write-BuildLog "  Failed adding $pkg`: $_" -Level Warning
    }
    # Lang pack — silently skip if absent (OSD pattern)
    $langCab = [System.IO.Path]::Combine($ocRoot, $lang, "${pkg}_${lang}.cab")
    if (Test-Path $langCab) {
      try {
        Add-WindowsPackage -Path $mount -PackagePath $langCab -ErrorAction Stop | Out-Null
      } catch {
        Write-BuildLog "  Failed adding lang pack ${pkg}_${lang}: $_" -Level Warning
      }
    }
  }

  $Script:Config.Stats.Packages = $count
  Write-BuildLog "Added $count WinPE packages ($skipped skipped — .cab not present)" -Level 'Success'
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
  # Archive structure: WinXShell_RC4.x.x\WinXShell\WinXShell_x64.exe
  # Flatten to: Apps\WinXShell\WinXShell_x64.exe (find the dir containing the exe)
  $wxZip = Join-Path $cache "WinXShell.7z"
  if (-not (Test-Path $wxZip)) {
    # Search order:
    #   1. OSD-DEV\Apps\ folder (next to the script) — place WinXShell archives here
    #   2. Build cache dir (leftover from prior runs or manually placed)
    #   3. Live download (URL contains a session token and may be expired)
    $scriptAppsDir = Join-Path (Split-Path -Parent $PSCommandPath) "Apps"
    $manualWx = $null
    foreach ($searchDir in @($scriptAppsDir, $cache)) {
      if (-not (Test-Path $searchDir)) { continue }
      $manualWx = Get-ChildItem -Path $searchDir -Filter 'WinXShell*.7z' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if (-not $manualWx) {
        $manualWx = Get-ChildItem -Path $searchDir -Filter 'WinXShell*.zip' -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1
      }
      if ($manualWx) { break }
    }
    if ($manualWx) {
      Write-BuildLog "  Using local WinXShell archive: $($manualWx.FullName)" -Level Info
      Copy-Item $manualWx.FullName $wxZip -Force
    } else {
      Write-BuildLog "  Downloading WinXShell (URL contains session token — may be expired)..." -Level Warning
      try {
        Invoke-WebRequest -Uri $Script:AppSources.WinXShell -OutFile $wxZip -UseBasicParsing -ErrorAction Stop
      } catch {
        Remove-Item $wxZip -Force -ErrorAction SilentlyContinue
        throw ("WinXShell download failed: $_`n`n" +
          "The download URL requires an active forum session token and may have expired.`n" +
          "Manual fix: place a WinXShell*.7z archive in: $scriptAppsDir`n" +
          "  (see $scriptAppsDir\README.md for details)")
      }
    }
  }
  $wxDest = Join-Path $apps "WinXShell"
  New-Item -ItemType Directory -Force -Path $wxDest | Out-Null
  Expand-7z -ArchivePath $wxZip -Destination $wxDest
  # Flatten: find the actual directory containing WinXShell_x64.exe and move contents up
  $wxExeItem = Get-ChildItem -Path $wxDest -Recurse -Filter 'WinXShell_x64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($wxExeItem -and $wxExeItem.Directory.FullName -ne $wxDest) {
    Write-BuildLog "  Flattening WinXShell directory: $($wxExeItem.Directory.Name)" -Level Info
    Get-ChildItem -Path $wxExeItem.Directory.FullName -Force | Move-Item -Destination $wxDest -Force
    # Remove now-empty parent chain
    $parent = $wxExeItem.Directory
    while ($parent.FullName -ne $wxDest) {
      Remove-Item $parent.FullName -Recurse -Force -ErrorAction SilentlyContinue
      $parent = $parent.Parent
    }
  }
  
  # VERIFICATION: Ensure WinXShell executable exists after extraction (Fix #2)
  $wxExe = Get-ChildItem -Path $wxDest -Recurse -Filter 'WinXShell_x64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $wxExe) {
    Write-BuildLog "ERROR: WinXShell executable not found after extraction" -Level Error
    throw "WinXShell extraction failed or archive was corrupted. Build cannot continue."
  }
  Write-BuildLog "WinXShell verified and ready for injection" -Level Success
  
  $Script:Config.Apps.WinXShell = $wxDest

  # --- 7-Zip (full portable for the image) ===
  # Extraction-only approach (no installer execution): more reliable and consistent
  Write-BuildLog "Downloading 7-Zip portable..."
  $szDest = Join-Path $apps "7-Zip"
  New-Item -ItemType Directory -Force -Path $szDest | Out-Null
  
  # Try to download and extract the 7z-extra.7z archive (contains portable binaries)
  $szExtra = Join-Path $cache "7z-extra.7z"
  if (-not (Test-Path $szExtra)) {
    try {
      Write-BuildLog "  Downloading 7z-extra.7z from 7-zip.org..." -Level Info
      Invoke-WebRequest -Uri $Script:AppSources.SevenZipExtra -OutFile $szExtra -UseBasicParsing -ErrorAction Stop
    } catch {
      Write-BuildLog "  Failed to download from SevenZipExtra source: $_" -Level Warning
      # Fallback: try alternative mirror or older version
      try {
        Write-BuildLog "  Retrying with SevenZipFull (SFX archive)..." -Level Info
        $szExe = Join-Path $cache "7z-full.exe"
        Invoke-WebRequest -Uri $Script:AppSources.SevenZipFull -OutFile $szExe -UseBasicParsing -ErrorAction Stop
        $szExtra = $szExe  # Treat SFX executable as extractable archive
      } catch {
        Write-BuildLog "  Failed to download 7-Zip from any source: $_" -Level Error
        throw "Could not download 7-Zip. Check internet connection and sources."
      }
    }
  }
  
  # Extract using 7zr.exe (ensured by Ensure-7z function)
  try {
    Write-BuildLog "  Extracting 7-Zip archive..." -Level Info
    Expand-7z -ArchivePath $szExtra -Destination $szDest
    Write-BuildLog "  7-Zip extracted successfully" -Level Info
  } catch {
    Write-BuildLog "  Failed to extract 7-Zip: $_" -Level Error
    throw "7-Zip extraction failed. Archive may be corrupted."
  }
  
  # Verify 7-Zip binaries are present.
  # 7z-extra.7z contains 7za.exe (standalone console); 7z-full.exe SFX contains 7z.exe.
  $sz7zExe  = Join-Path $szDest "7z.exe"
  $sz7zaExe = Join-Path $szDest "7za.exe"
  $sz7zX64  = Join-Path $szDest "x64\7z.exe"
  if (-not (Test-Path $sz7zExe) -and -not (Test-Path $sz7zaExe) -and -not (Test-Path $sz7zX64)) {
    Write-BuildLog "  Warning: neither 7z.exe nor 7za.exe found after extraction — PATH entry may not resolve correctly" -Level Warning
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
  Write-BuildLog "Note: IBM Semeru JDK adds ~175 MB to the WIM ramdisk. Ensure the boot target has at least 2 GB RAM." -Level Warning

  # --- Explorer++ portable ---
  # Per WinXShell author: Explorer++ must live in the SAME folder as WinXShell_x64.exe.
  # WinXShell.jcfg then references it via {JVAR_MODULEPATH}\explorer++.exe.
  # We do NOT register it as a separate PortableApps entry — it's a WinXShell plugin.
  if ($IncludeExplorerPlus) {
    $epZip = Join-Path $cache "ExplorerPP.zip"
    if (-not (Test-Path $epZip)) {
      Invoke-WebRequest -Uri $Script:AppSources.ExplorerPlusPlus -OutFile $epZip -UseBasicParsing
    }
    # Extract to a temp location, find explorer++.exe, copy it into the WinXShell dir
    $epTemp = Join-Path $Script:Config.Paths.Temp "ExplorerPP_extract"
    Expand-Archive $epZip $epTemp -Force
    $epExeItem = Get-ChildItem -Path $epTemp -Recurse -Filter 'explorerpp_x64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $epExeItem) { $epExeItem = Get-ChildItem -Path $epTemp -Recurse -Filter 'explorer++.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($epExeItem) {
      # Normalise to explorer++.exe — the name WinXShell.jcfg expects
      $epDest = Join-Path $Script:Config.Apps.WinXShell 'explorer++.exe'
      Copy-Item $epExeItem.FullName $epDest -Force
      $Script:Config.Apps.ExplorerPPExe = $epDest
      Write-BuildLog "Explorer++ copied into WinXShell folder: $epDest" -Level Success
    } else {
      Write-BuildLog "Explorer++ executable not found in ZIP — skipping" -Level Warning
    }
    Remove-Item $epTemp -Recurse -Force -ErrorAction SilentlyContinue
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

function Create-WinXShellConfig {
  # WinXShell ships its own winxshell.jcfg inside the archive — we must PATCH it,
  # not replace it. Replacing with a custom schema silently breaks WinXShell because
  # it uses proprietary keys (e.g. "::文件管理器", JVAR_MODULEPATH, etc.).
  #
  # What we patch:
  #  1. Wallpaper path — set if -WallpaperPath supplied (key: "::壁纸": { "file":"..." })
  #  2. Explorer++ integration — uncomment "::第3方文件管理器" line if explorer++.exe was
  #     placed in the WinXShell folder (per author instructions).
  #     Key to uncomment: "#::第3方文件管理器":"##{JVAR_MODULEPATH}\\explorer++.exe"
  #     After patch:        "::第3方文件管理器":"{JVAR_MODULEPATH}\\explorer++.exe"
  #
  # If no jcfg is found in the extracted archive, we log a warning and skip — the
  # bundled defaults will be used (WinXShell still works, just without our tweaks).
  Write-BuildLog "Patching WinXShell configuration (winxshell.jcfg)..."

  $wxDest = $Script:Config.Apps.WinXShell
  if (-not $wxDest -or -not (Test-Path $wxDest)) {
    Write-BuildLog "WinXShell directory not found — skipping config patch" -Level Warning
    return
  }

  $configPath = Join-Path $wxDest "winxshell.jcfg"
  if (-not (Test-Path $configPath)) {
    Write-BuildLog "winxshell.jcfg not found in WinXShell archive — skipping patch (bundled defaults apply)" -Level Warning
    return
  }

  $jcfgContent = Get-Content $configPath -Raw -Encoding UTF8

  # ── Patch 1: Explorer++ — uncomment the third-party file manager line ─────
  # Author's comment syntax: leading '#' on both the key and value makes it a comment.
  # Uncommented form the author shows:  "::第3方文件管理器":"{JVAR_MODULEPATH}\\explorer++.exe"
  if ($IncludeExplorerPlus -and $Script:Config.Apps.ExplorerPPExe) {
    # Pattern covers both quote styles and possible whitespace
    $jcfgContent = $jcfgContent -replace
      '"#::第3方文件管理器"\s*:\s*"##\{JVAR_MODULEPATH\}\\\\explorer\+\+\.exe"',
      '"::第3方文件管理器":"{JVAR_MODULEPATH}\\\\explorer++.exe"'
    Write-BuildLog "  Explorer++ integration activated in winxshell.jcfg" -Level Info
  }

  # ── Patch 2: Wallpaper ────────────────────────────────────────────────────
  # WinXShell uses "file" inside a "::壁纸" block.  The bundled jcfg typically
  # has it blank or commented.  We do a best-effort replacement; if the key is
  # absent we append a minimal block at the top-level JSON object.
  if ($WallpaperPath) {
    $wallpaperRuntime = 'X:\\Windows\\Web\\Wallpaper\\RAMOS\\custom.jpg'
    # Try replacing an existing blank/commented file entry inside ::壁纸
    $newWall = $jcfgContent -replace
      '("::壁纸"\s*:\s*\{[^}]*"file"\s*:\s*)"[^"]*"',
      "`$1`"$wallpaperRuntime`""
    if ($newWall -ne $jcfgContent) {
      $jcfgContent = $newWall
      Write-BuildLog "  Wallpaper path set in winxshell.jcfg (::壁纸)" -Level Info
    } else {
      Write-BuildLog "  ::壁纸 block not found in jcfg — wallpaper will be applied via PostShell.cmd only" -Level Warning
    }
  }

  Set-Content -Path $configPath -Value $jcfgContent -Encoding UTF8 -Force
  Write-BuildLog "winxshell.jcfg patched successfully" -Level Success
}

function Inject-AllApps {
  Write-BuildLog "Injecting applications into WIM image..."

  $progFiles = Join-Path $Script:Config.Paths.Mount "Program Files\PortableApps"
  New-Item -Path $progFiles -ItemType Directory -Force | Out-Null

  foreach ($app in $Script:Config.Apps.GetEnumerator()) {
    # Skip entries that are file paths rather than app directories:
    #   ChromeExe     — path to chrome.exe inside the Chrome folder (already covered by 'Chrome')
    #   ExplorerPPExe — explorer++.exe was copied into the WinXShell folder; no separate dir to inject
    if ($app.Key -in @('ChromeExe', 'ExplorerPPExe')) { continue }
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
    $Script:Config.WallpaperDest = "X:\Windows\Web\Wallpaper\RAMOS\custom.jpg"
  }
}

# ============================================
# ADK ENHANCEMENT  (PhoenixPE / wimbuilder2 approach)
# Mounts install.wim (read-only) and injects:
#   Step A — Core runtime components (DLLs, WiFi drivers, iSCSI MOFs, fonts)
#   Step B — WoW64 (32-bit subsystem) — optional via -IncludeWoW64
#   Step C — Audio subsystem         — optional via -IncludeAudio
#   Step D — Shell components         — optional via -IncludeShell
#   Step E — Registry merge from install.wim hives (CLSID, COM, Svchost, LSA…)
#   Step F — Drive-letter fix (C:\ → X:\) in PE SOFTWARE hive
#   Step G — WinPE scratch space via DISM /Set-ScratchSpace
#   Step H — Slim: MUI cleanup, telemetry, WMI auto-recover, migration engine
# ============================================
function Invoke-ADKEnhancement {
  param(
    [Parameter(Mandatory)][string]$InstallWimPath,
    [int]$InstallIndex = 1
  )

  Write-BuildLog "==> ADK Enhancement: injecting components from install.wim..." -Level Info
  Write-BuildLog "    Source : $InstallWimPath (index $InstallIndex)" -Level Info

  $mount        = $Script:Config.Paths.Mount
  $mountInstall = Join-Path $Script:Config.Paths.Temp 'mount_install'
  $lang         = $Script:Config.Locale
  if (-not $lang) { $lang = 'en-us' }

  # -- Helper: copy a file only if the source exists -----------------------
  function Copy-IfPresent {
    param([string]$Src, [string]$Dst)
    if (Test-Path $Src) {
      $dir = Split-Path $Dst -Parent
      if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
      Copy-Item -Path $Src -Destination $Dst -Force
      return $true
    }
    return $false
  }

  # -- Helper: remove a path safely ----------------------------------------
  function Remove-Safe {
    param([string]$Path)
    if (Test-Path $Path) { Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue }
  }

  New-Item -ItemType Directory -Force -Path $mountInstall | Out-Null

  # Mount install.wim read-only
  Write-BuildLog "    Mounting install.wim (read-only)..." -Level Info
  & $Script:Config.Tools.DISM /Mount-Wim /WimFile:"$InstallWimPath" /Index:$InstallIndex `
    /MountDir:"$mountInstall" /ReadOnly 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-BuildLog "    install.wim mount failed (exit $LASTEXITCODE) — enhancement skipped" -Level Warning
    return
  }

  $iSys32  = Join-Path $mountInstall 'Windows\System32'
  $iSysWOW = Join-Path $mountInstall 'Windows\SysWOW64'
  $iWin    = Join-Path $mountInstall 'Windows'
  $peSys32 = Join-Path $mount        'Windows\System32'
  $peSysWO = Join-Path $mount        'Windows\SysWOW64'
  $peWin   = Join-Path $mount        'Windows'

  try {

    # ════════════════════════════════════════════════════════════════════
    # Step A — Core runtime components
    # Based on PhoenixPE 210-Core.script and wimbuilder2 System/main.bat
    # ════════════════════════════════════════════════════════════════════
    Write-BuildLog "  [A] Core runtime components from install.wim..." -Level Info

    $essentialDlls = @(
      'powercfg.cpl','powercpl.dll','umpoext.dll',
      'Windows.CloudStore.dll',
      'ncsi.dll',
      'credssp.dll',
      'ISM.exe',
      'dxgi.dll','dxva2.dll','DXCore.dll',
      'd3d11.dll','d3d12.dll',
      'msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll',
      'fmapi.dll'
    )
    $copiedA = 0
    foreach ($f in $essentialDlls) {
      if (Copy-IfPresent (Join-Path $iSys32 $f) (Join-Path $peSys32 $f)) { $copiedA++ }
    }
    # Language-specific ncsi.dll.mui
    Copy-IfPresent (Join-Path $iSys32 "$lang\ncsi.dll.mui") `
                   (Join-Path $peSys32 "$lang\ncsi.dll.mui") | Out-Null

    # WiFi drivers (PhoenixPE 210-Core.script)
    $peDrivers = Join-Path $mount 'Windows\System32\Drivers'
    foreach ($drv in @('vwifibus.sys','vwifimp.sys','WifiCx.sys')) {
      if (Copy-IfPresent (Join-Path $iWin "System32\Drivers\$drv") (Join-Path $peDrivers $drv)) {
        Write-BuildLog "    WiFi driver: $drv" -Level Info
      }
    }

    # iSCSI WMI MOF files (PhoenixPE 210-Core.script)
    $peWbem      = Join-Path $mount 'Windows\System32\wbem'
    $installWbem = Join-Path $mountInstall 'Windows\System32\wbem'
    if (-not (Test-Path $peWbem)) { New-Item -ItemType Directory -Path $peWbem -Force | Out-Null }
    foreach ($mof in @('iscsidsc.mof','iscsihba.mof','iscsiprf.mof','iscsirem.mof',
                        'iscsiwmiv2.mof','iscsiwmiv2_uninstall.mof','msiscsi.mof',
                        'storagewmi.mof','storagewmi_passthru.mof')) {
      Copy-IfPresent (Join-Path $installWbem $mof) (Join-Path $peWbem $mof) | Out-Null
    }

    # Fonts (Segoe UI family, Consolas, Segoe Fluent Icons)
    $fontsDir = Join-Path $peWin 'Fonts'
    if (-not (Test-Path $fontsDir)) { New-Item -ItemType Directory -Path $fontsDir -Force | Out-Null }
    $fontList = @('segoeui.ttf','segoeuib.ttf','segoeuii.ttf','segoeuiz.ttf',
                  'seguisb.ttf','seguisym.ttf','consola.ttf','consolab.ttf',
                  'consolai.ttf','consolaz.ttf','SegoeIcons.ttf')
    foreach ($font in $fontList) {
      Copy-IfPresent (Join-Path $iWin "Fonts\$font") (Join-Path $fontsDir $font) | Out-Null
    }
    Write-BuildLog "    Core inject: $copiedA DLLs + WiFi drivers + iSCSI MOFs + fonts" -Level Info

    # ════════════════════════════════════════════════════════════════════
    # Step B — WoW64 (PhoenixPE 251-WoW64.script minimal list)
    # ════════════════════════════════════════════════════════════════════
    if ($IncludeWoW64) {
      Write-BuildLog "  [B] WoW64 (32-bit subsystem)..." -Level Info
      if (-not (Test-Path $peSysWO)) { New-Item -ItemType Directory -Path $peSysWO -Force | Out-Null }

      # WoW64 bridge DLLs in System32
      foreach ($dll in @('wow64.dll','wow64base.dll','wow64con.dll','wow64cpu.dll','wow64win.dll','wowreg32.exe')) {
        Copy-IfPresent (Join-Path $iSys32 $dll) (Join-Path $peSys32 $dll) | Out-Null
      }

      # SysWOW64 minimal list (~150+ files — PhoenixPE 251-WoW64.script)
      $sysWow64Files = @(
        # Core runtime
        'ntdll.dll','kernel32.dll','kernelbase.dll','kernel.appcore.dll',
        'advapi32.dll','user32.dll','win32u.dll','gdi32.dll','gdi32full.dll',
        'msvcrt.dll','msvcrt40.dll','ucrtbase.dll','msvcp_win.dll','msvcp110_win.dll',
        'msvcp60.dll','msvbvm60.dll','crtdll.dll','rpcrt4.dll','sechost.dll',
        'combase.dll','ole32.dll','oleaut32.dll','olecli32.dll','oledlg.dll',
        'olepro32.dll','asycfilt.dll','stdole2.tlb','stdole32.tlb',
        # Shell and UI
        'shlwapi.dll','shell32.dll','SHCore.dll','shfolder.dll','shdocvw.dll',
        'shellstyle.dll','comdlg32.dll','comctl32.dll','ExplorerFrame.dll',
        'ieframe.dll','iertutil.dll','mshtml.dll','imgutil.dll',
        'thumbcache.dll','linkinfo.dll','ntshrui.dll',
        # DirectX / Graphics
        'dxgi.dll','d3d9.dll','d3d10warp.dll','d3d11.dll','d3d12.dll',
        'd2d1.dll','Dwrite.dll','dcomp.dll','ddraw.dll',
        'dwmapi.dll','UIAnimation.dll','uxtheme.dll',
        'GdiPlus.dll','WindowsCodecs.dll','mscms.dll',
        # Security / Crypto
        'crypt32.dll','cryptbase.dll','cryptdll.dll','cryptnet.dll','cryptsp.dll',
        'ncrypt.dll','ncryptprov.dll','ncryptsslp.dll','bcrypt.dll','bcryptprimitives.dll',
        'wintrust.dll','rsaenh.dll','schannel.dll','sspicli.dll','secur32.dll',
        'kerberos.dll','msv1_0.dll','dpapi.dll','samlib.dll','samcli.dll',
        'mskeyprotect.dll','slc.dll',
        # Network
        'ws2_32.dll','wsock32.dll','mswsock.dll','winhttp.dll','wininet.dll',
        'urlmon.dll','webio.dll','dnsapi.dll','dhcpcsvc.dll','dhcpcsvc6.dll',
        'iphlpapi.dll','winnsi.dll','rasapi32.dll','rasadhlp.dll',
        'fwpuclnt.dll','FirewallAPI.dll','fwbase.dll','fwpolicyiomgr.dll',
        'ntlanman.dll','netapi32.dll','netutils.dll','srvcli.dll','wkscli.dll',
        'logoncli.dll','dfscli.dll',
        # COM / Automation
        'actxprxy.dll','atl.dll','atlthunk.dll','clb.dll','clbcatq.dll',
        'sxs.dll','sxsstore.dll','sxstrace.exe',
        'OneCoreCommonProxyStub.dll','OneCoreUAPCommonProxyStub.dll',
        'OnDemandConnRouteHelper.dll',
        'Windows.Globalization.dll','Windows.Graphics.dll',
        'Windows.FileExplorer.Common.dll','windows.storage.dll',
        'twinapi.dll','twinapi.appcore.dll','WinTypes.dll',
        'policymanager.dll','edputil.dll','wldp.dll',
        # System utilities (32-bit)
        'reg.exe','regsvr32.exe','regedt32.exe','rundll32.exe','svchost.exe',
        'cmd.exe','cmdext.dll','attrib.exe','clip.exe','findstr.exe',
        'run64.exe','dllhost.exe',
        'net.exe','net1.exe','netmsg.dll',
        # Settings / Policy
        'setupapi.dll','cfgmgr32.dll','devobj.dll','devrtl.dll',
        'authz.dll','ntmarta.dll','ntasn1.dll','msasn1.dll',
        'gpapi.dll','userenv.dll','profapi.dll',
        'regapi.dll','resutils.dll',
        # IME / Locale
        'imm32.dll','msctf.dll','InputHost.dll','usp10.dll','lpk.dll',
        'mlang.dll','normaliz.dll','tzres.dll','winnlsres.dll','winbrand.dll',
        'Bcp47Langs.dll','bcp47mrm.dll',
        # Misc runtime
        'hid.dll','avifil32.dll','avrt.dll','msvfw32.dll','winmm.dll',
        'winmmbase.dll','msacm32.dll','msacm32.drv','mpr.dll',
        'version.dll','psapi.dll','msimg32.dll','lz32.dll',
        'pdh.dll','fltlib.dll','ulib.dll',
        'vbscript.dll','mfc40.dll','mfc42.dll',
        'dbghelp.dll','dbgcore.dll','msxml3.dll','msxml3r.dll',
        'msxml6.dll','msxml6r.dll',
        'xmllite.dll','dui70.dll','duser.dll',
        'UIAutomationCore.dll','SensApi.dll','StructuredQuery.dll',
        'riched20.dll','riched32.dll','msdelta.dll',
        'ColorAdapterClient.dll','DataExchange.dll','CoreUIComponents.dll',
        'aclui.dll','mscories.dll',
        'odbc32.dll','odbcint.dll',
        'wimgapi.dll','davhlpr.dll',
        'cscapi.dll','directmanipulation.dll',
        'rmclient.dll',
        'framedynos.dll','ncobjapi.dll','wmiclnt.dll',
        'adsldp.dll','adsldpc.dll','activeds.dll','ntdsapi.dll',
        'wldap32.dll','dsrole.dll',
        'spfileq.dll','SPInf.dll','dsound.dll','wow32.dll','winsta.dll',
        'wtsapi32.dll','wbemcomn.dll'
      )
      # NLS/KBD glob copies
      Get-ChildItem -Path $iSysWOW -Filter 'C_*.NLS'  -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-IfPresent $_.FullName (Join-Path $peSysWO $_.Name) | Out-Null }
      Get-ChildItem -Path $iSysWOW -Filter 'KBD*.dll' -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-IfPresent $_.FullName (Join-Path $peSysWO $_.Name) | Out-Null }

      $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
      $wowCopied = 0; $wowSkipped = 0
      foreach ($file in $sysWow64Files) {
        if (-not $seen.Add($file)) { continue }
        if (Copy-IfPresent (Join-Path $iSysWOW $file) (Join-Path $peSysWO $file)) { $wowCopied++ }
        else { $wowSkipped++ }
      }
      # SysWOW64\wbem (WMI 32-bit support)
      $wbemWow = Join-Path $iSysWOW 'wbem'
      $peWbemWow = Join-Path $peSysWO 'wbem'
      if (Test-Path $wbemWow) {
        if (-not (Test-Path $peWbemWow)) { New-Item -ItemType Directory -Path $peWbemWow -Force | Out-Null }
        Get-ChildItem -Path $wbemWow -File -ErrorAction SilentlyContinue |
          ForEach-Object { Copy-IfPresent $_.FullName (Join-Path $peWbemWow $_.Name) | Out-Null }
      }
      # SysWOW64 audio for 32-bit app compat (PhoenixPE 251-WoW64.script)
      foreach ($f in @('AudioSes.dll','MMDevAPI.dll','devenum.dll','quartz.dll','msdmo.dll','dsound.dll')) {
        Copy-IfPresent (Join-Path $iSysWOW $f) (Join-Path $peSysWO $f) | Out-Null
      }
      Write-BuildLog "    WoW64: $wowCopied copied, $wowSkipped not in source" -Level Info
    }

    # ════════════════════════════════════════════════════════════════════
    # Step C — Audio subsystem (wimbuilder2 / PhoenixPE Components/Audio)
    # ════════════════════════════════════════════════════════════════════
    if ($IncludeAudio) {
      Write-BuildLog "  [C] Audio subsystem..." -Level Info
      foreach ($dll in @('audiodg.exe','audiosrv.dll','audioeng.dll','audioendpointbuilder.dll',
                          'mmdevapi.dll','wasapi.dll','mf.dll','mfplat.dll','mfreadwrite.dll',
                          'ksuser.dll','ksproxy.ax','dsound.dll','XAudio2_9.dll',
                          'wmasf.dll','wmaudio3.dll')) {
        Copy-IfPresent (Join-Path $iSys32 $dll) (Join-Path $peSys32 $dll) | Out-Null
      }
      Write-BuildLog "    Audio subsystem injected" -Level Info
    }

    # ════════════════════════════════════════════════════════════════════
    # Step D — Shell components (wimbuilder2 / PhoenixPE Components/Shell)
    # ════════════════════════════════════════════════════════════════════
    if ($IncludeShell) {
      Write-BuildLog "  [D] Shell components (Explorer, DWM, XAML)..." -Level Info
      foreach ($dll in @('explorer.exe','shell32.dll','shlwapi.dll','shsvcs.dll',
                          'SHCore.dll','Windows.Shell.ServiceProvider.dll',
                          'dwm.exe','dwmapi.dll','dwminit.dll','udwm.dll',
                          'taskbar.dll','twinui.dll','twinui.appcore.dll','twinui.pcshell.dll',
                          'windows.ui.dll','windows.ui.xaml.dll',
                          'uiautomationcore.dll','uiautomation6.dll',
                          'ExplorerFrame.dll','cscui.dll')) {
        Copy-IfPresent (Join-Path $iSys32 $dll) (Join-Path $peSys32 $dll) | Out-Null
      }
      Write-BuildLog "    Shell components injected" -Level Info
    }

    # ════════════════════════════════════════════════════════════════════
    # Step E — Registry merge from install.wim hives
    # Matches PhoenixPE 211-Registry.script Config-BaseWim-SoftwareHive +
    # Config-BaseWim-SystemHive (subtree copies via reg.exe copy /s)
    # ════════════════════════════════════════════════════════════════════
    Write-BuildLog "  [E] Registry merge from install.wim hives..." -Level Info

    $peHiveSW  = Join-Path $mount 'Windows\System32\config\SOFTWARE'
    $peHiveSYS = Join-Path $mount 'Windows\System32\config\SYSTEM'
    $iHiveSW   = Join-Path $mountInstall 'Windows\System32\config\SOFTWARE'
    $iHiveSYS  = Join-Path $mountInstall 'Windows\System32\config\SYSTEM'

    # copy hives to a neutral location so reg.exe can load them alongside the PE hives
    $hiveTmp   = Join-Path $Script:Config.Paths.Temp 'hive_tmp'
    New-Item -ItemType Directory -Force -Path $hiveTmp | Out-Null
    $iSwCopy  = Join-Path $hiveTmp 'inst_SW'
    $iSysCopy = Join-Path $hiveTmp 'inst_SYS'
    Copy-Item $iHiveSW  $iSwCopy  -Force -ErrorAction SilentlyContinue
    Copy-Item $iHiveSYS $iSysCopy -Force -ErrorAction SilentlyContinue

    $tmpPeSW   = 'HKLM\ADK_PE_SW'
    $tmpPeSYS  = 'HKLM\ADK_PE_SYS'
    $tmpInSW   = 'HKLM\ADK_IN_SW'
    $tmpInSYS  = 'HKLM\ADK_IN_SYS'

    foreach ($key in @($tmpPeSW,$tmpPeSYS,$tmpInSW,$tmpInSYS)) {
      reg unload $key 2>&1 | Out-Null
    }

    reg load $tmpPeSW  $peHiveSW   2>&1 | Out-Null
    reg load $tmpPeSYS $peHiveSYS  2>&1 | Out-Null
    reg load $tmpInSW  $iSwCopy    2>&1 | Out-Null; $inSwLoaded  = ($LASTEXITCODE -eq 0)
    reg load $tmpInSYS $iSysCopy   2>&1 | Out-Null; $inSysLoaded = ($LASTEXITCODE -eq 0)

    try {
      if ($inSwLoaded) {
        # COM / Shell classes
        foreach ($k in @('Classes\AppID','Classes\CLSID','Classes\Interface','Classes\Typelib',
                          'Classes\folder','Classes\themefile','Classes\SystemFileAssociations',
                          'Classes\DirectShow','Classes\Media Type','Classes\MediaFoundation')) {
          reg copy "HKLM\ADK_IN_SW\$k" "HKLM\ADK_PE_SW\$k" /s /f 2>&1 | Out-Null
        }
        # Svchost, SecurityManager, Ole, PolicyManager
        foreach ($k in @('Microsoft\Windows NT\CurrentVersion\Svchost',
                          'Microsoft\SecurityManager','Microsoft\Ole',
                          'Microsoft\PolicyManager')) {
          reg copy "HKLM\ADK_IN_SW\$k" "HKLM\ADK_PE_SW\$k" /s /f 2>&1 | Out-Null
        }
        # WinRT / AppModel / AppX
        foreach ($k in @('Microsoft\WindowsRuntime',
          'Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel',
          'Microsoft\Windows\CurrentVersion\AppModel',
          'Microsoft\Windows\CurrentVersion\AppX')) {
          reg copy "HKLM\ADK_IN_SW\$k" "HKLM\ADK_PE_SW\$k" /s /f 2>&1 | Out-Null
        }
        Write-BuildLog "    SOFTWARE hive: COM, shell classes, Svchost, AppModel merged" -Level Info
      }
      if ($inSysLoaded) {
        # Appinfo, LSA, Power, TCP/IP services, KnownDLLs
        foreach ($k in @('ControlSet001\Services\Appinfo',
                          'ControlSet001\Control\Lsa',
                          'ControlSet001\Control\Power',
                          'ControlSet001\Services\Tcpip',
                          'ControlSet001\Services\Winsock',
                          'ControlSet001\Services\Winsock2',
                          'ControlSet001\Control\Session Manager\KnownDLLs')) {
          reg copy "HKLM\ADK_IN_SYS\$k" "HKLM\ADK_PE_SYS\$k" /s /f 2>&1 | Out-Null
        }
        # TermService — copy and disable (Start=4)
        reg copy "HKLM\ADK_IN_SYS\ControlSet001\Services\TermService" `
                 "HKLM\ADK_PE_SYS\ControlSet001\Services\TermService" /s /f 2>&1 | Out-Null
        reg add  "HKLM\ADK_PE_SYS\ControlSet001\Services\TermService" `
          /v Start /t REG_DWORD /d 4 /f 2>&1 | Out-Null
        Write-BuildLog "    SYSTEM hive: Appinfo, LSA, Power, TCP/IP, KnownDLLs, TermService merged" -Level Info
      }

      # ════════════════════════════════════════════════════════════════
      # Step F — Drive-letter fix: ensure PE SOFTWARE uses X:\ not C:\
      # PhoenixPE SetSystemDriveLetter
      # ════════════════════════════════════════════════════════════════
      Write-BuildLog "  [F] Verifying PE drive letter in SOFTWARE hive..." -Level Info
      $clsidCheck = reg query 'HKLM\ADK_PE_SW\Classes\CLSID\{0000002F-0000-0000-C000-000000000046}\InprocServer32' 2>&1 | Out-String
      if ($clsidCheck -match 'C:\\') {
        Write-BuildLog "    Detected C:\\ in PE hive — replacing with X:\\ ..." -Level Warning
        $exportPath = Join-Path $Script:Config.Paths.Temp 'pe_sw_drivfix.reg'
        reg export 'HKLM\ADK_PE_SW' $exportPath /y 2>&1 | Out-Null
        if (Test-Path $exportPath) {
          $content = [System.IO.File]::ReadAllText($exportPath)
          $content = $content -replace '(?i)(")C:\\\\', '$1X:\\'
          [System.IO.File]::WriteAllText($exportPath, $content)
          reg import $exportPath 2>&1 | Out-Null
          Remove-Item $exportPath -Force -ErrorAction SilentlyContinue
          Write-BuildLog "    Drive letter corrected to X:\\" -Level Info
        }
      } else {
        Write-BuildLog "    Drive letter: X:\\ confirmed" -Level Info
      }
    } finally {
      foreach ($key in @($tmpPeSW,$tmpPeSYS,$tmpInSW,$tmpInSYS)) {
        reg unload $key 2>&1 | Out-Null
      }
      # Clean up registry transaction logs left by reg.exe
      $cfgDir = Join-Path $mount 'Windows\System32\config'
      Get-ChildItem -Path $cfgDir -Include '*.LOG1','*.LOG2','*.blf','*.regtrans-ms' `
        -Recurse -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # ════════════════════════════════════════════════════════════════════
    # Step G — WinPE scratch space (DISM /Set-ScratchSpace)
    # PhoenixPE references this as a pre-flight step; wimbuilder2 uses FBWF sizing.
    # ════════════════════════════════════════════════════════════════════
    Write-BuildLog "  [G] Setting WinPE scratch space: $ScratchSpaceMB MB..." -Level Info
    $scratchArg = "/Set-ScratchSpace:$ScratchSpaceMB"
    & $Script:Config.Tools.DISM "/Image:$mount" $scratchArg 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-BuildLog "    DISM /Set-ScratchSpace returned $LASTEXITCODE (non-fatal)" -Level Warning
    } else {
      Write-BuildLog "    Scratch space set to $ScratchSpaceMB MB" -Level Info
    }

    # ════════════════════════════════════════════════════════════════════
    # Step H — Slim: remove unneeded files
    # Based on PhoenixPE SlimFast and wimbuilder2 SlimWim
    # ════════════════════════════════════════════════════════════════════
    Write-BuildLog "  [H] Slimming PE image (MUI, telemetry, WMI autoRecover, migration)..." -Level Info

    # H1: MUI language resources — keep $lang and en-us (boot fallback)
    foreach ($muiRoot in @(
      (Join-Path $mount 'Windows\System32'),
      (Join-Path $mount 'Windows\Boot\EFI'),
      (Join-Path $mount 'Windows\Boot\PCAT'),
      (Join-Path $mount 'Windows\Boot\PXE')
    )) {
      if (-not (Test-Path $muiRoot)) { continue }
      Get-ChildItem -Path $muiRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[a-z]{2}-[A-Z]{2}' -and $_.Name -ne $lang -and $_.Name -ne 'en-US' } |
        ForEach-Object { Remove-Safe $_.FullName }
    }

    # H2: Telemetry
    foreach ($item in @(
      (Join-Path $mount 'Windows\DiagTrack'),
      (Join-Path $mount 'Windows\System32\DiagSvcs'),
      (Join-Path $mount 'Windows\System32\diagER.dll'),
      (Join-Path $mount 'Windows\System32\diagtrack.dll')
    )) { Remove-Safe $item }

    # H3: WMI auto-recover + logs (WMI rebuilds from MOF files on first boot)
    foreach ($item in @(
      (Join-Path $mount 'Windows\System32\wbem\AutoRecover'),
      (Join-Path $mount 'Windows\System32\wbem\Logs'),
      (Join-Path $mount 'Windows\System32\wbem\Repository'),
      (Join-Path $mount 'Windows\System32\wbem\tmf')
    )) { Remove-Safe $item }

    # H4: Migration engine (not needed in a rescue/RAM OS PE)
    foreach ($f in @('migapp.xml','migcore.dll','migisol.dll','migres.dll',
                      'migstore.dll','migsys.dll','SFCN.dat')) {
      Remove-Safe (Join-Path $mount "Windows\System32\$f")
    }
    Remove-Safe (Join-Path $mount 'Windows\System32\migration')

    # H5: WinRE sources folder (present in WinRE base; not needed in output WIM)
    Remove-Safe (Join-Path $mount 'sources')

    # H6: Desktop.ini stubs
    Remove-Safe (Join-Path $mount 'Users\Default\Desktop\Desktop.ini')
    Remove-Safe (Join-Path $mount 'Users\Public\Desktop\Desktop.ini')

    # H7: WallpaperHost / immersive shell provider (cause issues in WinPE)
    foreach ($f in @('WallpaperHost.exe','windows.immersiveshell.serviceprovider.dll')) {
      Remove-Safe (Join-Path $mount "Windows\System32\$f")
    }

    Write-BuildLog "    Slimming complete" -Level Info

  } finally {
    # Unmount install.wim (discard — we only read from it)
    Write-BuildLog "  Unmounting install.wim..." -Level Info
    & $Script:Config.Tools.DISM /Unmount-Wim /MountDir:"$mountInstall" /Discard 2>&1 | Out-Null
    & $Script:Config.Tools.DISM /Cleanup-Mountpoints 2>&1 | Out-Null
    Remove-Safe $mountInstall
  }

  Write-BuildLog "ADK Enhancement complete" -Level Success
}


# install.wim hive merging is handled separately in Invoke-ADKEnhancement.
# ============================================
function Configure-SystemRegistry {
  Write-BuildLog "Configuring PE registry (PhoenixPE-aligned tweaks)..."
  $mount      = $Script:Config.Paths.Mount
  $swPath     = Join-Path $mount "Windows\System32\config\SOFTWARE"
  $sysPath    = Join-Path $mount "Windows\System32\config\SYSTEM"

  # Force-unload any stale hives from a prior crashed build, then load fresh.
  reg unload "HKLM\PE_SW"  2>&1 | Out-Null
  reg unload "HKLM\PE_SYS" 2>&1 | Out-Null

  $out = reg load "HKLM\PE_SW"  $swPath  2>&1; if ($LASTEXITCODE -ne 0) { throw "reg load PE_SW failed: $out"  }
  $out = reg load "HKLM\PE_SYS" $sysPath 2>&1; if ($LASTEXITCODE -ne 0) { throw "reg load PE_SYS failed: $out" }

  try {
    # ── WinPE identification + wallpaper path ─────────────────────────────
    reg add "HKLM\PE_SW\Microsoft\Windows NT\CurrentVersion\WinPE" `
      /v InstRoot /d 'X:\' /f 2>&1 | Out-Null
    reg add "HKLM\PE_SW\Microsoft\Windows NT\CurrentVersion\WinPE" `
      /v CustomBackground /t REG_EXPAND_SZ `
      /d 'X:\Windows\Web\Wallpaper\Windows\img0.jpg' /f 2>&1 | Out-Null

    # WinPE OC registration hooks (PhoenixPE Config-SoftwareHive)
    $ocBase = "HKLM\PE_SW\Microsoft\Windows NT\CurrentVersion\WinPE\OC"
    reg add "$ocBase\Microsoft-WinPE-WMI" `
      /v "1. Register CIMWIN32" /d '%systemroot%\system32\wbem\cimwin32.dll' /f 2>&1 | Out-Null
    reg add "$ocBase\Microsoft-WinPE-WSH" `
      /v "1. Register WSHOM" /d '%systemroot%\system32\wshom.ocx' /f 2>&1 | Out-Null
    reg add "HKLM\PE_SW\Microsoft\Windows NT\CurrentVersion\WinPE\UGC" `
      /v "Microsoft-Windows-TCPIP" /t REG_MULTI_SZ /d "netiougc.exe -online" /f 2>&1 | Out-Null

    # Enable SIHost integration (PhoenixPE)
    reg add "HKLM\PE_SW\Microsoft\Windows NT\CurrentVersion\Winlogon" `
      /v EnableSIHostIntegration /t REG_DWORD /d 1 /f 2>&1 | Out-Null

    # Add DriverStore to Installation Sources (X:\ is the WinPE system drive at runtime)
    reg add "HKLM\PE_SW\Microsoft\Windows\CurrentVersion\Setup" `
      /v "Installation Sources" /t REG_MULTI_SZ `
      /d "X:\Windows\System32\DriverStore\FileRepository" /f 2>&1 | Out-Null

    # Telemetry / DiagTrack (PhoenixPE Config-SystemHive)
    reg add "HKLM\PE_SW\Microsoft\Windows\CurrentVersion\Policies\DataCollection" `
      /v AllowTelemetry /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    reg add "HKLM\PE_SYS\ControlSet001\Control\WMI\Autologger\AutoLogger-Diagtrack-Listener" `
      /v Start /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    reg add "HKLM\PE_SYS\ControlSet001\Services\diagnosticshub.standardcollector.service" `
      /v Start /t REG_DWORD /d 4 /f 2>&1 | Out-Null
    reg add "HKLM\PE_SYS\ControlSet001\Services\DiagTrack" `
      /v Start /t REG_DWORD /d 4 /f 2>&1 | Out-Null

    # Disable Hibernate + Fast Startup (PhoenixPE)
    reg add "HKLM\PE_SYS\ControlSet001\Control\Power" `
      /v HibernateEnabled /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    reg add "HKLM\PE_SYS\ControlSet001\Control\Power" `
      /v CustomizeDuringSetup /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    reg add "HKLM\PE_SYS\ControlSet001\Control\Session Manager\Power" `
      /v HiberbootEnabled /t REG_DWORD /d 0 /f 2>&1 | Out-Null

    # Filesystem performance
    reg add "HKLM\PE_SYS\ControlSet001\Control\FileSystem" `
      /v NtfsDisableLastAccessUpdate /t REG_DWORD /d 1 /f 2>&1 | Out-Null
    reg add "HKLM\PE_SYS\ControlSet001\Control\FileSystem" `
      /v RefsDisableLastAccessUpdate /t REG_DWORD /d 1 /f 2>&1 | Out-Null
    reg add "HKLM\PE_SYS\ControlSet001\Control\MiniNT" `
      /v AllowRefsFormatOverNonmirrorVolume /t REG_DWORD /d 1 /f 2>&1 | Out-Null

    # LSA / Security (PhoenixPE — NTLMv2 only, level 3)
    reg add "HKLM\PE_SYS\ControlSet001\Control\Lsa" `
      /v "Security Packages" /t REG_MULTI_SZ /d "tspkg" /f 2>&1 | Out-Null
    reg add "HKLM\PE_SYS\ControlSet001\Control\SecurityProviders" `
      /v SecurityProviders /d "credssp.dll" /f 2>&1 | Out-Null
    reg add "HKLM\PE_SYS\ControlSet001\Control\Lsa" `
      /v LmCompatibilityLevel /t REG_DWORD /d 3 /f 2>&1 | Out-Null
    reg add "HKLM\PE_SYS\ControlSet001\Control\Lsa" `
      /v LimitBlankPasswordUse /t REG_DWORD /d 0 /f 2>&1 | Out-Null

    # AppData environment variable
    reg add "HKLM\PE_SYS\ControlSet001\Control\Session Manager\Environment" `
      /v AppData /t REG_EXPAND_SZ `
      /d '%SystemDrive%\Users\Default\AppData\Roaming' /f 2>&1 | Out-Null

    # AllowStart service keys (ProfSvc, LanmanWorkstation, DNSCache, NlaSvc)
    foreach ($svc in @('ProfSvc','LanmanWorkstation','DNSCache','NlaSvc')) {
      reg add "HKLM\PE_SYS\Setup\AllowStart\$svc" /f 2>&1 | Out-Null
    }

    # USB hub safe-remove
    reg add "HKLM\PE_SYS\ControlSet001\Services\usbhub\HubG" `
      /v DisableOnSoftRemove /t REG_DWORD /d 1 /f 2>&1 | Out-Null

    # PS/2 mouse wheel detection
    reg add "HKLM\PE_SYS\ControlSet001\Services\i8042prt\Parameters" `
      /v EnableWheelDetection /t REG_DWORD /d 2 /f 2>&1 | Out-Null

    # BFE (Base Filtering Engine) — PhoenixPE Config-SystemHive
    reg add "HKLM\PE_SYS\ControlSet001\Services\BFE" `
      /v ImagePath /t REG_EXPAND_SZ `
      /d "%systemroot%\system32\svchost.exe -k LocalServiceNoNetworkFirewall -p" /f 2>&1 | Out-Null
    reg add "HKLM\PE_SYS\ControlSet001\Services\BFE" `
      /v SvcHostSplitDisable /t REG_DWORD /d 1 /f 2>&1 | Out-Null

    # Default user profile path
    reg add "HKLM\PE_SW\Microsoft\Windows NT\CurrentVersion\ProfileList\S-1-5-18" `
      /v ProfileImagePath /d 'X:\Users\Default' /f 2>&1 | Out-Null

    # Desktop personalization
    reg add "HKLM\PE_SW\Microsoft\Windows\CurrentVersion\Personalization" `
      /v AllowChangeDesktopBackground /t REG_DWORD /d 1 /f 2>&1 | Out-Null
    reg add "HKLM\PE_SW\Microsoft\Windows\CurrentVersion\Personalization" `
      /v AllowPersonalization /t REG_DWORD /d 1 /f 2>&1 | Out-Null

    # Font registration
    $fontsKey = "HKLM\PE_SW\Microsoft\Windows NT\CurrentVersion\Fonts"
    reg add $fontsKey /v "Segoe UI (TrueType)" /d segoeui.ttf /f 2>&1 | Out-Null
    reg add $fontsKey /v "Consolas (TrueType)" /d consola.ttf  /f 2>&1 | Out-Null
    $pefontsDir = Join-Path $mount "Windows\Fonts"
    if (Test-Path (Join-Path $pefontsDir 'SegoeIcons.ttf')) {
      reg add $fontsKey /v "Segoe Fluent Icons (TrueType)" /d SegoeIcons.ttf /f 2>&1 | Out-Null
    }

    # ── FBWF overlay size (only when -EnableFBWF is specified) ────────────
    if ($EnableFBWF) {
      $fbwfKey = "HKLM\PE_SYS\ControlSet001\Services\FBWF"
      reg add $fbwfKey /v WinPECacheThreshold /t REG_DWORD /d $RamdiskSizeMB /f 2>&1 | Out-Null
      if ($RamdiskSizeMB -ge 4094) {
        reg add "HKLM\PE_SYS\ControlSet001\Services\exfat" /v Start /t REG_DWORD /d 0 /f 2>&1 | Out-Null
        Write-BuildLog "  exFAT driver enabled (required for FBWF >= 4094 MB)" -Level Info
      }
      Write-BuildLog "  FBWF WinPECacheThreshold = $RamdiskSizeMB MB" -Level Info
    }

    Write-BuildLog "PE registry tweaks applied (PhoenixPE-aligned)" -Level Success

  } finally {
    reg unload "HKLM\PE_SW"  2>&1 | Out-Null
    reg unload "HKLM\PE_SYS" 2>&1 | Out-Null
    # Clean up registry transaction logs
    $cfgDir = Join-Path $mount 'Windows\System32\config'
    Get-ChildItem -Path $cfgDir -Include '*.LOG1','*.LOG2','*.blf','*.regtrans-ms' `
      -Recurse -ErrorAction SilentlyContinue |
      Remove-Item -Force -ErrorAction SilentlyContinue
  }
}

# ============================================
# SHELL & STARTUP
# ============================================
function Create-StartupScript {
  Write-BuildLog "Creating StartNet.cmd..."
  $mount = $Script:Config.Paths.Mount

  $wifiEnabled = ($UseWinRE -or $IncludeWiFi)

  # Find WinXShell runtime path (C:\ based) from what was injected into the WIM
  $mountedBase  = Join-Path $mount 'Program Files\PortableApps'
  $wxItem       = Find-ExeUnder -Root (Join-Path $mountedBase 'WinXShell') -ExeName 'WinXShell_x64.exe'
  if (-not $wxItem) { $wxItem = Find-ExeUnder -Root (Join-Path $mountedBase 'WinXShell') -ExeName 'WinXShell.exe' }
  $wxRuntime    = if ($wxItem) { $wxItem.FullName -replace [regex]::Escape($mount), 'X:' } else { $null }
  
  # VALIDATION: Ensure path conversion from mount to X: drive succeeded (Fix #3)
  if ($wxRuntime -and -not $wxRuntime.StartsWith('X:\')) {
    Write-BuildLog "ERROR: WinXShell path conversion failed. Expected X:\ prefix, got: $wxRuntime" -Level Error
    throw "Critical path conversion error. Build cannot continue."
  }

  #TODO:REWORK
  # ── Startup sequence (optimized) ───────────────────────────────────────────
  # 1. wpeinit: initializes all devices, network adapters, and storage
  #    (no need for separate wpeutil InitializeNetwork — wpeinit already does this)
  # 2. Disable firewall for easier network access
  # 3. WiFi setup (if enabled)
  # 4. Environment variables for Java, 7-Zip, etc.
  # 5. Launch WinXShell (last step, blocking)
  #
  # Reference: Build-Image-OldWay-Rework.ps1
  $content = @'
@ECHO OFF
wpeinit

REM Disable firewall for easier network access
wpeutil DisableFirewall
'@

  if ($wifiEnabled) {
    $content += @'

REM === WiFi Initialization (OSD) ===
PowerShell -NoLogo -NonInteractive -Command "& { if (Get-Command Initialize-OSDCloudStartnet -ErrorAction Ignore) { Initialize-OSDCloudStartnet } else { net start WlanSvc 2>$null; Start-Sleep -Seconds 3; if (Test-Path X:\Windows\WirelessConnect.exe) { Start-Process X:\Windows\WirelessConnect.exe -Wait } } }"
'@
  }

  # Set environment variables (simpler and more reliable than offline hive editing)
  if ($Script:Config.Apps.ContainsKey('Java')) {
    $javaRuntime = 'X:\Program Files\PortableApps\Java'
    $content += "`r`nSET JAVA_HOME=$javaRuntime`r`nSET PATH=%PATH%;$javaRuntime\bin`r`n"
  }
  if ($Script:Config.Apps.ContainsKey('7-Zip')) {
    $szRuntime = 'X:\Program Files\PortableApps\7-Zip'
    $content += "SET PATH=%PATH%;$szRuntime`r`n"
  }

  # Launch WinXShell (blocking — when WinXShell exits, WinPE shuts down)
  if ($wxRuntime) {
    # FIX #1: Use empty title with variable to avoid START command ambiguity with quoted paths
    # Pattern: set VAR=path && start /wait "" "%VAR%"
    $content += @"

REM === Apply Post-Shell Tweaks ===
if exist "X:\Windows\System32\RAMOS\PostShell.cmd" (
  start "" "X:\Windows\System32\RAMOS\PostShell.cmd"
)

REM === Start Shell ===
set WXSHELL=$wxRuntime
start /wait "" "%WXSHELL%"
"@
    Write-BuildLog "  StartNet.cmd will launch: $wxRuntime" -Level Info
  } else {
    # FIX #4: Make shell fallback a hard error (cannot boot without shell)
    $msg = "CRITICAL: WinXShell was not found in the mounted WIM.`n"
    $msg += "The bootable image cannot function without a shell.`n"
    $msg += "Verify WinXShell download/extraction succeeded and try again."
    Write-BuildLog $msg -Level Error
    throw "WinXShell not available - build cannot complete."
  }

  $content += @'

exit /b 0
'@

  Set-Content -Path (Join-Path $mount 'Windows\System32\StartNet.cmd') -Value $content -Force -Encoding ASCII
  Write-BuildLog "StartNet.cmd created$(if ($wifiEnabled) { ' (WiFi: Initialize-OSDCloudStartnet -WirelessConnect)' })" -Level 'Success'
}

function Create-PostShellScript {
  Write-BuildLog "Creating PostShell.cmd..."
  $mount = $Script:Config.Paths.Mount
  $postDir = Join-Path $mount "Windows\System32\RAMOS"
  New-Item -ItemType Directory -Force -Path $postDir | Out-Null

  $wall = $Script:Config.WallpaperDest

  $post = @'
@echo off
REM Post-startup tweaks.
REM NOTE: DWM does not run in WinPE — accent-color and colorization writes are
REM       stored in-registry and will take effect if the image is ever booted into
REM       a full Windows session; they are harmless no-ops in WinPE.
REM       Wallpaper is set via WinXShell config (winxshell.jcfg) — the HKCU key
REM       below is a secondary hint in case the shell reads the registry as well.
if exist "%SystemRoot%\System32\reg.exe" (
  if not "{WALL}"=="" if exist "{WALL}" (
    reg add "HKCU\Control Panel\Desktop" /v Wallpaper /t REG_SZ /d "{WALL}" /f >nul 2>&1
    reg add "HKCU\Control Panel\Desktop" /v WallpaperStyle /t REG_SZ /d 10 /f >nul 2>&1
  )
  REM Accent color — ARGB DWORD (0xFF + 6-digit hex)
  reg add "HKCU\Software\Microsoft\Windows\DWM" /v ColorPrevalence /t REG_DWORD /d 1 /f >nul 2>&1
  reg add "HKCU\Software\Microsoft\Windows\DWM" /v AccentColor /t REG_DWORD /d 0x{ACCENT} /f >nul 2>&1
  reg add "HKCU\Software\Microsoft\Windows\DWM" /v ColorizationColor /t REG_DWORD /d 0x{ACCENT} /f >nul 2>&1
)
exit /b 0
'@.Replace("{WALL}",$(if ($wall) { $wall } else { "" })).Replace("{ACCENT}","FF$AccentColor")

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
  $runtimeAppsRoot = "X:\Program Files\PortableApps"
  $chromeExeRuntime = $Script:Config.Apps.ChromeExe -replace [regex]::Escape($buildAppsRoot),$runtimeAppsRoot

  $launcher = @'
@echo off
set "PROFILE=X:\ChromeProfile"
set "CACHE=X:\ChromeCache"
if not exist "%PROFILE%" mkdir "%PROFILE%"
if not exist "%CACHE%" mkdir "%CACHE%"
start "" "{CHROME}" --user-data-dir="%PROFILE%" --disk-cache-dir="%CACHE%" --no-first-run --no-default-browser-check --no-sandbox --disable-gpu
exit /b 0
'@.Replace('{CHROME}',$chromeExeRuntime)

  Set-Content -Path (Join-Path $tools "StartChrome.cmd") -Value $launcher -Encoding ASCII -Force
}

function Create-DesktopShortcuts {
  Write-BuildLog "Creating Desktop Custom Shortcuts..."
  $mount = $Script:Config.Paths.Mount
  
  # Standard WinPE Desktop folders
  $desktopDirs = @(
    (Join-Path $mount "Users\Public\Desktop"),
    (Join-Path $mount "Users\Default\Desktop"),
    (Join-Path $mount "Windows\System32\config\systemprofile\Desktop")
  )

  foreach ($d in $desktopDirs) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  }

  $WshShell = New-Object -ComObject WScript.Shell

  # Helper inner block to create lnk across all profiles.
  # $Arguments is optional; when supplied, TargetPath is the launcher (e.g. cmd.exe)
  # and Arguments contains the real command — necessary for .cmd/.bat targets because
  # non-Explorer shells (WinXShell) may not invoke .cmd files directly from .lnk.
  $createMultiLnk = {
    param($Name, $Target, $Icon, $Arguments = "")
    foreach ($d in $desktopDirs) {
      $lnkPath = Join-Path $d "$Name.lnk"
      $Shortcut = $WshShell.CreateShortcut($lnkPath)
      $Shortcut.TargetPath = $Target
      if ($Arguments) { $Shortcut.Arguments = $Arguments }
      $Shortcut.IconLocation = "$Icon,0"
      $workDir = Split-Path -Parent $Target
      if ($workDir) { $Shortcut.WorkingDirectory = $workDir }
      $Shortcut.Save()
    }
  }

  # Chrome Shortcut — target cmd.exe so WinXShell can reliably launch the .cmd launcher
  if ($Script:Config.Apps.ChromeExe) {
    $buildAppsRoot = $Script:Config.Paths.Apps
    $runtimeAppsRoot = "X:\Program Files\PortableApps"
    $chromeRuntime = $Script:Config.Apps.ChromeExe -replace [regex]::Escape($buildAppsRoot), $runtimeAppsRoot
    # Use the full X:\ path to cmd.exe so the .lnk stores the correct WinPE path
    # (WshShell would otherwise resolve bare "cmd.exe" to C:\Windows\System32\cmd.exe on the build machine).
    &$createMultiLnk "Google Chrome" "X:\Windows\System32\cmd.exe" $chromeRuntime "/c `"X:\Windows\System32\RAMOS\StartChrome.cmd`""
  }

}
# Note: Explorer++ desktop shortcut is not needed — WinXShell activates it via the
# ::第3方文件管理器 entry in winxshell.jcfg (see Create-WinXShellConfig).

function Write-Winpeshl {
  # OSD pattern: startnet.cmd launches WinXShell at the end — no winpeshl.ini needed.
  # Removing winpeshl.ini (or leaving it absent) causes WinPE to default to
  # cmd.exe /k startnet.cmd, which is exactly what we want.
  $mount   = $Script:Config.Paths.Mount
  $iniPath = Join-Path $mount 'Windows\System32\winpeshl.ini'
  if (Test-Path $iniPath) {
    Remove-Item $iniPath -Force
    Write-BuildLog "winpeshl.ini removed — WinPE will use cmd.exe → StartNet.cmd (OSD pattern)" -Level Info
  }
  Write-BuildLog "winpeshl.ini: no-op (shell launched from StartNet.cmd)" -Level 'Success'
}

# ============================================
# ISO BUILD
# ============================================
function Build-FinalISO {
  Write-BuildLog "Building final ISO image..."

  $mount       = $Script:Config.Paths.Mount
  $isoSource   = $Script:Config.Paths.ISO
  $outputDir   = $Script:Config.Paths.Output
  $isoLabel    = [System.IO.Path]::GetFileNameWithoutExtension($OutputISOName)
  $isoFullName = Join-Path $outputDir $OutputISOName

  # ── 1. Commit the WIM ─────────────────────────────────────────────────
  Write-BuildLog "  Committing WIM..." -Level Info
  & $Script:Config.Tools.DISM /Unmount-Image /MountDir:"$mount" /Commit | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to commit WIM changes (DISM exit $LASTEXITCODE)" }
  $Script:State.Mounted = $false

  # ── 1b. Re-export with maximum compression ────────────────────────────
  # After DISM /Commit, newly-added files (apps, drivers, packages) are stored
  # as uncompressed delta blocks inside the WIM. The combined WIM can easily
  # reach 900 MB+, which causes bootmgr to fail with "Not enough memory
  # resources" when it tries to allocate that as a single contiguous ramdisk
  # at early-boot time — even if the machine has plenty of physical RAM.
  # Re-exporting with /Compress:maximum (LZX) recompresses everything and typically
  # cuts the WIM to 40-60% of its committed size, keeping it bootable.
  # IMPORTANT: Do NOT use /Compress:recovery — that uses LZMS compression which
  # the WinPE boot loader (winload.efi) does not support; it will BSOD 0xc000000bb.
  $bootWimPath   = Join-Path $isoSource 'sources\boot.wim'
  $bootWimReexp  = Join-Path $Script:Config.Paths.Temp 'boot_reexport.wim'
  Write-BuildLog "  Re-exporting WIM with maximum (LZX) compression (reduces boot ramdisk size)..." -Level Info
  $beforeMB = [math]::Round((Get-Item $bootWimPath).Length / 1MB, 1)
  & $Script:Config.Tools.DISM /Export-Image /SourceImageFile:"$bootWimPath" /SourceIndex:1 /DestinationImageFile:"$bootWimReexp" /Compress:maximum | Out-Null
  if ($LASTEXITCODE -eq 0 -and (Test-Path $bootWimReexp)) {
    Move-Item -LiteralPath $bootWimReexp -Destination $bootWimPath -Force
    $afterMB = [math]::Round((Get-Item $bootWimPath).Length / 1MB, 1)
    Write-BuildLog "  WIM size: ${beforeMB} MB → ${afterMB} MB (saved $([math]::Round($beforeMB - $afterMB, 1)) MB)" -Level Success
  } else {
    Write-BuildLog "  WIM re-export failed (exit $LASTEXITCODE) — ISO will use uncompressed WIM (may not boot on low-RAM machines)" -Level Warning
    Remove-Item $bootWimReexp -Force -ErrorAction SilentlyContinue
  }

  # ── 2. Verify ISO source layout ────────────────────────────────────────
  $bootDir = Join-Path $isoSource 'boot'
  $efiBoot = Join-Path $isoSource 'efi\microsoft\boot'
  foreach ($dir in @($bootDir, $efiBoot)) {
    if (-not (Test-Path $dir)) { throw "ISO source folder is missing required directory: $dir" }
  }
  $bootWim = Join-Path $isoSource 'sources\boot.wim'
  if (-not (Test-Path $bootWim)) { throw "boot.wim not found at $bootWim" }

  # ── 3. Stage boot sector files into ISO source (OSD pattern) ──────────
  #   oscdimg's -bootdata: paths must survive quoting — easier to stage them
  #   inside the media tree so there are never spaces or special chars in the path.
  $oscdimgDir         = Split-Path $Script:Config.Tools.OSCDIMG
  $etfsbootcom_adk    = $Script:Config.Tools.EtfsBootCom
  $efisys_adk         = Join-Path $oscdimgDir 'efisys.bin'
  $efisysnoprompt_adk = $Script:Config.Tools.EfiSysNoprompt

  $destEtfsboot  = Join-Path $bootDir 'etfsboot.com'
  $destEfisys    = Join-Path $efiBoot 'efisys.bin'
  $destEfisysNP  = Join-Path $efiBoot 'efisys_noprompt.bin'

  if (-not (Test-Path $destEtfsboot)) {
    if (-not (Test-Path $etfsbootcom_adk)) { throw "etfsboot.com not found at ADK path: $etfsbootcom_adk" }
    Copy-Item $etfsbootcom_adk $bootDir -Force
    Write-BuildLog "  Staged etfsboot.com from ADK" -Level Info
  } else {
    Write-BuildLog "  etfsboot.com already present in ISO source" -Level Info
  }

  if (-not (Test-Path $destEfisys)) {
    if (Test-Path $efisys_adk) {
      Copy-Item $efisys_adk $efiBoot -Force
      Write-BuildLog "  Staged efisys.bin from ADK" -Level Info
    }
  } else {
    Write-BuildLog "  efisys.bin already present in ISO source" -Level Info
  }

  if (-not (Test-Path $destEfisysNP)) {
    if (Test-Path $efisysnoprompt_adk) {
      Copy-Item $efisysnoprompt_adk $efiBoot -Force
      Write-BuildLog "  Staged efisys_noprompt.bin from ADK" -Level Info
    }
  } else {
    Write-BuildLog "  efisys_noprompt.bin already present in ISO source" -Level Info
  }

  # ── 4. Scrub non-boot files from sources\ before packing ──────────────────
  #   Keep only boot.wim (and .sdi/.efi/.cat/.inf/.dll helpers).
  #   Explicitly remove install.wim / install.esd — these are Windows setup images
  #   (4-8 GB each) and must NOT be packed into the boot ISO.
  foreach ($installImg in @('install.wim','install.esd')) {
    $imgPath = Join-Path $isoSource "sources\$installImg"
    if (Test-Path $imgPath) {
      Write-BuildLog "  Removing $installImg from sources\ (not needed in boot ISO — saves GB of space)" -Level Info
      Remove-Item $imgPath -Force
    }
  }
  Get-ChildItem (Join-Path $isoSource 'sources') -File | Where-Object { $_.Extension -notin @('.wim','.sdi','.efi','.cat','.inf','.dll') } | ForEach-Object {
    Write-BuildLog "  Removing stray file from sources\: $($_.Name)" -Level Info
    Remove-Item $_.FullName -Force
  }

  # ── 5. Build the ISO (OSD pattern: Start-Process to preserve inner quotes) ─
  if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
  }
  if (Test-Path $isoFullName) {
    Write-BuildLog "  Removing existing ISO: $isoFullName" -Level Info
    Remove-Item $isoFullName -Force
  }

  $oscdimgexe     = $Script:Config.Tools.OSCDIMG
  $isoLabelString = '-l"{0}"' -f $isoLabel

  Write-BuildLog "  oscdimg: $oscdimgexe" -Level Info
  Write-BuildLog "  source:  $isoSource"  -Level Info
  Write-BuildLog "  output:  $isoFullName" -Level Info
  Write-BuildLog "  label:   $isoLabel"   -Level Info

  # Prefer efisys_noprompt.bin (no "press any key" prompt) — correct for unattended RAM OS
  if (Test-Path $destEfisysNP) {
    $bootDataString = '2#p0,e,b"{0}"#pEF,e,b"{1}"' -f $destEtfsboot, $destEfisysNP
    Write-BuildLog "  EFI boot: efisys_noprompt.bin (no prompt)" -Level Info
  } elseif (Test-Path $destEfisys) {
    $bootDataString = '2#p0,e,b"{0}"#pEF,e,b"{1}"' -f $destEtfsboot, $destEfisys
    Write-BuildLog "  EFI boot: efisys.bin (standard)" -Level Info
  } else {
    throw "No EFI boot sector file found in $efiBoot (tried efisys_noprompt.bin and efisys.bin)"
  }

  Write-BuildLog "  Running oscdimg..." -Level Info
  # Use Start-Process (matches OSD's New-WindowsAdkISO) — preserves embedded quotes
  # in -bootdata: argument that & operator would otherwise strip.
  $process = Start-Process $oscdimgexe `
    -ArgumentList @('-m', '-o', '-u2', "-bootdata:$bootDataString", '-udfver102', $isoLabelString, "`"$isoSource`"", "`"$isoFullName`"") `
    -PassThru -Wait -WindowStyle Hidden

  if ($process.ExitCode -ne 0) {
    throw "OSCDIMG failed with exit code $($process.ExitCode)"
  }

  if (-not (Test-Path $isoFullName)) {
    throw "OSCDIMG reported success but ISO not found at: $isoFullName"
  }

  $isoItem = Get-Item $isoFullName
  Write-BuildLog ("ISO created: {0} ({1:N1} MB)" -f $isoFullName, ($isoItem.Length / 1MB)) -Level Success
  return $isoFullName
}

# ============================================
# MAIN
# ============================================
try {
  Initialize-BuildEnvironment

  $bootWim = Mount-SourceISO
  # Backup the original WIM to Temp\ — NOT inside the ISO source tree (it would be packed into the ISO)
  try { Copy-Item $bootWim (Join-Path $Script:Config.Paths.Temp 'boot.wim.bak') -Force } catch {}

  # WinRE WIM always has exactly one image index; user-supplied WimIndex applies to ISO mode only
  $effectiveIndex = if ($UseWinRE) { 1 } else { $WimIndex }
  Mount-TargetWIM -WimPath "$bootWim" -Index $effectiveIndex

  Add-WinPE-Packages

  # ── ADK Enhancement: inject components from install.wim ─────────────────
  # Determine where to find install.wim:
  #   1. -EnhanceFromISO: mount the provided ISO, extract install.wim to Cache, unmount
  #   2. ISO mode (not -UseWinRE): install.wim is already in ISO_Source\sources\
  #   3. WinRE mode without -EnhanceFromISO: log guidance, skip
  $installWimForEnhancement = $null

  if (-not [string]::IsNullOrWhiteSpace($EnhanceFromISO)) {
    Write-BuildLog "Enhancement ISO provided: $EnhanceFromISO" -Level Info
    Write-BuildLog "Mounting enhancement ISO to locate install.wim..." -Level Info
    try {
      Mount-DiskImage -ImagePath "$EnhanceFromISO" -ErrorAction Stop | Out-Null
      $enhVol    = Get-DiskImage -ImagePath "$EnhanceFromISO" | Get-Volume
      $enhLetter = $enhVol.DriveLetter
      $enhInstallWim = "${enhLetter}:\sources\install.wim"
      if (-not (Test-Path $enhInstallWim)) {
        $enhInstallWim = "${enhLetter}:\sources\install.esd"
      }
      if (Test-Path $enhInstallWim) {
        $cachedWim = Join-Path $Script:Config.Paths.Cache 'install_enhance.wim'
        Write-BuildLog "  Copying install.wim from ISO to cache (this may take a minute)..." -Level Info
        Copy-Item -LiteralPath $enhInstallWim -Destination $cachedWim -Force
        $installWimForEnhancement = $cachedWim
        Write-BuildLog "  install.wim cached: $cachedWim" -Level Info
      } else {
        Write-BuildLog "  install.wim not found in $EnhanceFromISO — enhancement skipped" -Level Warning
      }
    } catch {
      Write-BuildLog "  Failed to mount enhancement ISO: $_ — enhancement skipped" -Level Warning
    } finally {
      Dismount-DiskImage -ImagePath "$EnhanceFromISO" -ErrorAction SilentlyContinue | Out-Null
    }
  } elseif (-not $UseWinRE) {
    # ISO mode: install.wim was extracted together with the rest of the ISO
    $isoInstallWim = Join-Path $Script:Config.Paths.ISO 'sources\install.wim'
    $isoInstallEsd = Join-Path $Script:Config.Paths.ISO 'sources\install.esd'
    if (Test-Path $isoInstallWim) {
      Write-BuildLog "Auto-detected install.wim from ISO source: $isoInstallWim" -Level Info
      $installWimForEnhancement = $isoInstallWim
    } elseif (Test-Path $isoInstallEsd) {
      Write-BuildLog "Auto-detected install.esd from ISO source (ESD may be encrypted): $isoInstallEsd" -Level Warning
      $installWimForEnhancement = $isoInstallEsd
    } else {
      Write-BuildLog "install.wim not found in ISO source — enhancement skipped" -Level Warning
      Write-BuildLog "  Tip: use -EnhanceFromISO <path> to supply a Windows ISO explicitly" -Level Warning
    }
  } else {
    # WinRE mode: no ISO source available
    Write-BuildLog "WinRE mode: no install.wim source. To run ADK enhancement, add:" -Level Warning
    Write-BuildLog "  -EnhanceFromISO <path-to-windows.iso>" -Level Warning
  }

  if ($installWimForEnhancement) {
    Invoke-ADKEnhancement -InstallWimPath $installWimForEnhancement -InstallIndex $InstallWimIndex
  }
  # ── End ADK Enhancement ──────────────────────────────────────────────────

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
  Create-WinXShellConfig
  Inject-AllApps

  Configure-SystemRegistry
  Create-PostShellScript
  Create-ChromeLauncher
  Create-DesktopShortcuts
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
  if ($installWimForEnhancement) {
    Write-Host "  [+] ADK Enhancement (install.wim component injection):" -ForegroundColor Gray
    Write-Host "       Core DLLs, WiFi drivers, iSCSI MOFs, fonts" -ForegroundColor DarkGray
    Write-Host "       PE registry: COM/CLSID, Svchost, LSA, TCP/IP, KnownDLLs merged" -ForegroundColor DarkGray
    Write-Host "       PhoenixPE-aligned PE tweaks applied; scratch space $ScratchSpaceMB MB" -ForegroundColor DarkGray
    if ($IncludeWoW64)  { Write-Host "       WoW64 (32-bit subsystem, ~150+ DLLs)" -ForegroundColor DarkGray }
    if ($IncludeAudio)  { Write-Host "       Audio subsystem (WASAPI, audiodg, etc.)" -ForegroundColor DarkGray }
    if ($IncludeShell)  { Write-Host "       Shell components (Explorer, DWM, XAML)" -ForegroundColor DarkGray }
  } else {
    Write-Host "  [ ] ADK Enhancement NOT run (no install.wim; add -EnhanceFromISO to enable)" -ForegroundColor DarkGray
  }
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
