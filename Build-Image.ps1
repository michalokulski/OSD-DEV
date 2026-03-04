<#
.SYNOPSIS
Advanced RAM OS Builder with Hardware Support (Fixed & Validated)
Creates a Windows PE-based RAM Operating System with Explorer shell, optional apps, Dell drivers, and visual theming.

.DESCRIPTION
Transforms a Windows ISO into a bootable RAM OS using WinPE. Highlights:
- True RAM operation (WinPE runs from X:\; you can eject boot media after desktop loads)
- Dell WinPE11 drivers injected correctly (CAB extracted, INF drivers added)
- Explorer shell with optional Open-Shell & Explorer++
- Chrome++ (Chrome Plus) with repo-faithful validation (version.dll next to chrome.exe)
- Chrome launcher puts profile/cache on X:\ (volatile)
- Optional FBWF OC (off by default; not needed for eject-media)
- Robust ADK + WinPE OC detection, safe cleanup, better logging
- UEFI "no prompt" boot image if present

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
.\Build-RAMOS.ps1 -SourceISO "C:\Win11.iso" -WorkRoot "D:\Build" -UseChromePlus -IncludeDellDrivers -IncludeExplorerPlus -ChromeOfflineInstallerPath "C:\Downloads\ChromeStandaloneSetup64.exe"

#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateScript({
      if (-not (Test-Path "$_")) { throw "Source ISO not found: $_" }
      $true
  })]
  [string]$SourceISO,

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

  [Parameter(Mandatory = $false)][switch]$UseChromePlus,

  [Parameter(Mandatory = $false)]
  [ValidateScript({
      if ($_){
        if (-not (Test-Path "$_")) { throw "Chrome offline installer not found: $_" }
        $ext = [IO.Path]::GetExtension("$_").ToLower()
        if ($ext -notin @('.exe','.zip','.7z')) { throw "Offline installer must be .exe, .zip or .7z" }
      }
      $true
  })]
  [string]$ChromeOfflineInstallerPath = "",

  [Parameter(Mandatory = $false)]
  [ValidateScript({
      if ($_){
        if (-not (Test-Path "$_")) { throw "Chrome portable path not found: $_" }
        $ext = [System.IO.Path]::GetExtension("$_").ToLower()
        if ($ext -notin @('.zip','.exe','.7z')) { throw "Chrome must be .zip, .7z or .exe" }
      }
      $true
  })]
  [string]$ChromePortablePath = "",

  [Parameter(Mandatory = $false)][switch]$IncludeExplorerPlus,
  [Parameter(Mandatory = $false)][switch]$IncludeDellDrivers,

  [Parameter(Mandatory = $false)]
  [ValidateScript({
      if ($_){
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
  [string]$ADKPath = "",  # Will be auto-detected if not provided

  [Parameter(Mandatory = $false)][switch]$KeepMountedWIM,
  [Parameter(Mandatory = $false)][switch]$SkipCleanup,

  [Parameter(Mandatory = $false)]
  [ValidateSet(1,2)]
  [int]$WimIndex = 1,

  [Parameter(Mandatory = $false)]
  [switch]$EnableFBWF
)

#Requires -RunAsAdministrator

# ============================================
# INITIALIZATION
# ============================================
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
  # Open-Shell official (4.4.196). We extract from the installer to achieve a portable layout.
  OpenShellExe        = "https://github.com/Open-Shell/Open-Shell-Menu/releases/download/v4.4.196/OpenShellSetup_4_4_196.exe"
  # Fallback mirror (in case GitHub throttles)
  OpenShellExeMirror  = "https://sourceforge.net/projects/open-shell.mirror/files/v4.4.196/OpenShellSetup_4_4_196.exe/download"

  # IBM Semeru (prefer latest 8u482; fallback to previously-used 8u472)
  SemeruPrimary       = "https://github.com/ibmruntimes/semeru8-binaries/releases/download/jdk8u482-b08_openj9-0.57.0/ibm-semeru-open-jdk_x64_windows_8u482b08_openj9-0.57.0.zip"
  SemeruFallback      = "https://github.com/ibmruntimes/semeru8-binaries/releases/download/jdk8u472-b08_openj9-0.56.0/ibm-semeru-open-jdk_x64_windows_8u472b08_openj9-0.56.0-portable.zip"

  # Explorer++ official portable ZIP
  ExplorerPlusPlus    = "https://github.com/derceg/explorerplusplus/releases/download/version-1.4.0/explorerpp_x64.zip"

  # Chrome++ (Chrome Plus) packaged as .7z; requires version.dll next to chrome.exe
  ChromePlus          = "https://github.com/Bush2021/chrome_plus/releases/download/1.15.1/Chrome++_v1.15.1_x86_x64_arm64.7z"

  # Dell WinPE 11 driver pack A08 (Dec 23, 2025)
  DellWinPEDrivers    = "https://downloads.dell.com/FOLDER14002062M/1/WinPE11.0-Drivers-A08-2V5TD.cab"

  # Minimal 7-zip standalone extractor (build-time only)
  SevenZipMini        = "https://www.7-zip.org/a/7zr.exe"

  # Full 7-Zip portable (console + GUI) for injection into the image
  SevenZipExtra       = "https://www.7-zip.org/a/7z2408-extra.7z"
  SevenZipFull        = "https://www.7-zip.org/a/7z2408-x64.exe"
}

# Valid WinPE OCs per MS docs; language packs added when present
$Script:WinPEPackages = @(
  "WinPE-WMI",
  "WinPE-Scripting",
  "WinPE-PowerShell",
  "WinPE-HTA",
  "WinPE-NetFx",
  "WinPE-WOW64",
  "WinPE-Fonts-Legacy",
  "WinPE-StorageWMI",
  "WinPE-DismCmdlets",
  "WinPE-FMAPI",
  "WinPE-WiFi"
)

# ============================================
# LOGGING
# ============================================
function Write-BuildLog {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [ValidateSet("Info","Success","Warning","Error")][string]$Level = "Info"
  )
  $ts = Get-Date -Format "HH:mm:ss"
  $color = switch ($Level) {
    "Success" { "Green" }
    "Error"   { "Red" }
    "Warning" { "Yellow" }
    default   { "Cyan" }
  }
  Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
}

# ============================================
# SETUP
# ============================================
function Test-Administrator {
  $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
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
  $WorkRoot = "$WorkRoot".Replace('/', '\').Trim()
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
    Root   = $WorkRoot
    ISO    = [System.IO.Path]::Combine($WorkRoot, "ISO_Source")
    Mount  = [System.IO.Path]::Combine($WorkRoot, "Mount_WIM")
    Apps   = [System.IO.Path]::Combine($WorkRoot, "Apps")
    Cache  = [System.IO.Path]::Combine($WorkRoot, "Cache")
    Output = [System.IO.Path]::Combine($WorkRoot, "Output")
    Temp   = [System.IO.Path]::Combine($WorkRoot, "Temp")
    Mount_Install = [System.IO.Path]::Combine($WorkRoot, "Mount_Install")
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
  $Script:Config.LogFile = [System.IO.Path]::Combine($Script:Config.Paths.Output, "Build-$timestamp.log")
  if ([string]::IsNullOrWhiteSpace($Script:Config.LogFile)) {
    throw "LogFile path resolved to empty value"
  }
  
  Start-Transcript -Path $Script:Config.LogFile -ErrorAction Stop | Out-Null

  # Probe ADK + WinPE add-on
  $progFiles86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
  $progFiles = [Environment]::GetEnvironmentVariable("ProgramFiles")
  
  Write-BuildLog "Detected ProgramFiles(x86): $progFiles86" -Level Info
  Write-BuildLog "Detected ProgramFiles: $progFiles" -Level Info
  
  # Build candidate paths explicitly to avoid pipeline issues
  $candidate1 = $ADKPath
  $candidate2 = if ($progFiles86) { [System.IO.Path]::Combine($progFiles86, "Windows Kits\11\Assessment and Deployment Kit\Windows Preinstallation Environment") } else { $null }
  $candidate3 = if ($progFiles86) { [System.IO.Path]::Combine($progFiles86, "Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment") } else { $null }
  $candidate4 = if ($progFiles) { [System.IO.Path]::Combine($progFiles, "Windows Kits\11\Assessment and Deployment Kit\Windows Preinstallation Environment") } else { $null }
  $candidate5 = if ($progFiles) { [System.IO.Path]::Combine($progFiles, "Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment") } else { $null }
  
  Write-BuildLog "Candidate paths constructed: c1=$candidate1 | c2=$candidate2 | c3=$candidate3 | c4=$candidate4 | c5=$candidate5" -Level Info
  
  # Filter candidates without using pipeline to avoid PowerShell unpacking strings with parentheses
  $candidates = @()
  foreach ($c in @($candidate1, $candidate2, $candidate3, $candidate4, $candidate5)) {
    if ($c -and $c.Length -gt 3 -and (Test-Path $c)) {
      # Check if already in array before adding (Select-Object -Unique)
      if ($candidates -notcontains $c) {
        $candidates += $c
      }
    }
  }
  
  Write-BuildLog "After filtering - Candidates count: $($candidates.Count)" -Level Info
  if ($candidates.Count -gt 0) {
    Write-BuildLog "First candidate after filter: [$($candidates[0])] | Type: $($candidates[0].GetType().Name)" -Level Info
  }

  if (-not $candidates -or $candidates.Count -eq 0) {
    $msg = @"
Windows ADK WinPE add-on not found in any standard location.

REQUIRED: Install Windows Assessment and Deployment Kit (ADK) with WinPE:
1. Download: https://aka.ms/adk
2. Run the installer
3. Select "Windows Preinstallation Environment (Windows PE)"
4. Ensure "Deployment Tools" is also selected

Locations checked:
  - $progFiles86\Windows Kits\11\Assessment and Deployment Kit\Windows Preinstallation Environment
  - $progFiles86\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment
  - $progFiles\Windows Kits\11\Assessment and Deployment Kit\Windows Preinstallation Environment
  - $progFiles\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment

Or provide a custom path: -ADKPath "C:\Path\To\Windows Preinstallation Environment"
"@
    throw $msg
  }

  $winpeAddOn = $candidates[0]
  Write-BuildLog "Variable winpeAddOn assigned: [$winpeAddOn]" -Level Info
  
  $adkRoot = Split-Path -Path "$winpeAddOn" -Parent
  Write-BuildLog "After Split-Path - adkRoot: [$adkRoot]" -Level Info
  
  if ([string]::IsNullOrWhiteSpace($adkRoot)) {
    throw "ADK Root path is empty after Split-Path. WinPE path was: '$winpeAddOn'"
  }

  Write-BuildLog "ADK Root detected: $adkRoot" -Level Info
  Write-BuildLog "WinPE Add-On detected: $winpeAddOn" -Level Info

  $Script:Config.Tools = @{
    DISM     = [System.IO.Path]::Combine($adkRoot, "Deployment Tools\amd64\DISM\dism.exe")
    OSCDIMG  = [System.IO.Path]::Combine($adkRoot, "Deployment Tools\amd64\Oscdimg\oscdimg.exe")
    WinPEOCs = [System.IO.Path]::Combine($winpeAddOn, "amd64\WinPE_OCs")
  }

  Write-BuildLog "DISM path: $($Script:Config.Tools.DISM)" -Level Info
  Write-BuildLog "OSCDIMG path: $($Script:Config.Tools.OSCDIMG)" -Level Info
  Write-BuildLog "WinPE OCs path: $($Script:Config.Tools.WinPEOCs)" -Level Info

  if (-not (Test-Path $Script:Config.Tools.DISM)) {
    Write-BuildLog "DISM not found at: $($Script:Config.Tools.DISM) - trying PATH" -Level Warning
    try {
      $Script:Config.Tools.DISM = (Get-Command dism.exe -ErrorAction Stop).Source
    } catch {
      throw "DISM.exe not found. Ensure Windows ADK is installed or DISM is available in PATH"
    }
  }
  
  if (-not (Test-Path $Script:Config.Tools.OSCDIMG)) {
    Write-BuildLog "OSCDIMG not found at: $($Script:Config.Tools.OSCDIMG) - checking if file exists with Test-Path verbose" -Level Warning
    try {
      $Script:Config.Tools.OSCDIMG = (Get-Command oscdimg.exe -ErrorAction Stop).Source
    } catch {
      $msg = @"
OSCDIMG.exe not found in ADK installation or PATH.

This tool is required to build the ISO image. The Windows ADK with WinPE must be installed.

To install ADK:
1. Download from: https://aka.ms/adk
2. Run the installer and select "Windows Preinstallation Environment (Windows PE)" option
3. Ensure "Deployment Tools" is also selected for OSCDIMG.exe

Alternatively, you can specify the ADK path using:
  -ADKPath "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit"

Current ADK candidates checked:
  - $ADKPath
  - `${env:ProgramFiles(x86)}\Windows Kits\11\Assessment and Deployment Kit\Windows Preinstallation Environment`
  - `${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment`
"@
      throw $msg
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

  # Dismount ISO if still mounted
  Get-DiskImage -ImagePath "$SourceISO" -ErrorAction SilentlyContinue | Dismount-DiskImage -ErrorAction SilentlyContinue | Out-Null

  if (-not $SkipCleanup) {
    Remove-Item $Script:Config.Paths.Apps -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $Script:Config.Paths.Temp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $Script:Config.Paths.Mount_Install -Recurse -Force -ErrorAction SilentlyContinue
  }

  Stop-Transcript -ErrorAction SilentlyContinue
}

# ============================================
# ISO & WIM
# ============================================
function Mount-SourceISO {
  Write-BuildLog "Mounting source ISO..."

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
  return [System.IO.Path]::Combine($Script:Config.Paths.ISO, "sources", "boot.wim")
}

function Mount-TargetWIM {
  param(
    [Parameter(Mandatory)][string]$WimPath,
    [ValidateSet(1,2)][int]$Index = 1
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
    $p = [System.IO.Path]::Combine($Script:Config.Paths.Mount, "Windows", "System32", "config", $hive)
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
  if (-not (Test-Path ([System.IO.Path]::Combine($ocRoot, $lang)))) { $lang = "en-us" }

  $packages = $Script:WinPEPackages.Clone()
  if ($EnableFBWF) { $packages += "WinPE-FBWF" }

  foreach ($pkg in $packages) {
    $cab = [System.IO.Path]::Combine($ocRoot, "$pkg.cab")
    if (Test-Path $cab) {
      & $Script:Config.Tools.DISM /Add-Package /Image:"$mount" /PackagePath:"$cab" /IgnoreCheck | Out-Null
      if ($LASTEXITCODE -eq 0) { $count++ } else { Write-BuildLog "Failed adding package: $pkg" -Level Warning }
      $langCab = [System.IO.Path]::Combine($ocRoot, $lang, "${pkg}_${lang}.cab")
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
  $dellCab = [System.IO.Path]::Combine($Script:Config.Paths.Cache, "Dell-WinPE11-Drivers.cab")
  if (-not (Test-Path $dellCab)) {
    try {
      Invoke-WebRequest -Uri $Script:AppSources.DellWinPEDrivers -OutFile $dellCab -UseBasicParsing
    } catch {
      Write-BuildLog "Failed to download Dell drivers: $_" -Level "Warning"
      return
    }
  }

  Write-BuildLog "Extracting and injecting Dell drivers..."
  $extractDir = [System.IO.Path]::Combine($Script:Config.Paths.Temp, "DellDrivers")
  New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
  & "$env:SystemRoot\System32\expand.exe" -F:* "$dellCab" "$extractDir" | Out-Null

  if (Test-Path $extractDir) {
    & $Script:Config.Tools.DISM /Add-Driver /Image:$Script:Config.Paths.Mount /Driver:"$extractDir" /Recurse /ForceUnsigned | Out-Null
    if ($LASTEXITCODE -eq 0) {
      $Script:Config.Stats.DriversAdded = (Get-ChildItem -Path $extractDir -Filter *.inf -Recurse | Measure-Object).Count
      Write-BuildLog "Injected $($Script:Config.Stats.DriversAdded) Dell INF drivers" -Level "Success"
    } else {
      Write-BuildLog "DISM /Add-Driver failed for Dell drivers" -Level Warning
    }
  }
}

# ============================================
# EXPLORER SHELL
# ============================================
function Add-ExplorerShell {
  Write-BuildLog "Checking Explorer shell availability..."
  $mount = $Script:Config.Paths.Mount
  $explorerTarget = Join-Path $mount "Windows\explorer.exe"

  if (Test-Path $explorerTarget) {
    Write-BuildLog "Explorer.exe found in boot.wim" -Level "Success"
    return
  }

  Write-BuildLog "Explorer.exe NOT found in boot.wim — extracting from install.wim..." -Level "Warning"
  $installWim = Join-Path $Script:Config.Paths.ISO "sources\install.wim"
  if (-not (Test-Path $installWim)) {
    Write-BuildLog "install.wim not found in ISO source. Explorer shell will not be available." -Level "Error"
    return
  }

  $mountInstall = $Script:Config.Paths.Mount_Install
  if (-not (Test-Path $mountInstall)) { New-Item -ItemType Directory -Path $mountInstall -Force | Out-Null }

  Write-BuildLog "Mounting install.wim (Index 1) for Explorer extraction..."
  & $Script:Config.Tools.DISM /Mount-Image /ImageFile:"$installWim" /Index:1 /MountDir:"$mountInstall" /ReadOnly | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-BuildLog "Failed to mount install.wim for Explorer extraction" -Level "Error"
    return
  }

  try {
    # Core Explorer shell files needed for a functional desktop in WinPE
    $shellFiles = @(
      "Windows\explorer.exe",
      "Windows\System32\ExplorerFrame.dll",
      "Windows\System32\twinui.dll",
      "Windows\System32\twinui.pcshell.dll",
      "Windows\System32\Windows.UI.Immersive.dll",
      "Windows\System32\authui.dll",
      "Windows\System32\StartTileData.dll",
      "Windows\System32\InputHost.dll",
      "Windows\System32\TextInputFramework.dll"
    )

    $copied = 0
    foreach ($file in $shellFiles) {
      $src = Join-Path $mountInstall $file
      $dst = Join-Path $mount $file
      if ((Test-Path $src) -and -not (Test-Path $dst)) {
        $dstDir = Split-Path $dst -Parent
        if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        Copy-Item $src $dst -Force
        $copied++
      }
    }
    Write-BuildLog "Copied $copied Explorer shell files from install.wim" -Level "Success"
  }
  finally {
    & $Script:Config.Tools.DISM /Unmount-Image /MountDir:"$mountInstall" /Discard | Out-Null
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
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$Destination
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

function Install-ChromeFromOfflineInstaller {
  param([string]$Installer,[string]$Dest)
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null
  # Use 7z extraction first (reliable for Chrome NSIS/stub installer); fall back to /extract
  try {
    Expand-7z -ArchivePath $Installer -Destination $Dest
  } catch {
    try {
      Start-Process -FilePath $Installer -ArgumentList "/extract=`"$Dest`"" -Wait -WindowStyle Hidden -ErrorAction Stop
    } catch {
      Write-BuildLog "Could not extract Chrome offline installer: $_" -Level "Warning"
    }
  }
}

function Get-Applications {
  Write-BuildLog "Downloading portable applications..."

  $cache = $Script:Config.Paths.Cache
  $apps  = $Script:Config.Paths.Apps

  # --- Open-Shell (official EXE; extract to portable layout) ---
  $osExe = Join-Path $cache "OpenShellSetup.exe"
  if (-not (Test-Path $osExe)) {
    try { Invoke-WebRequest -Uri $Script:AppSources.OpenShellExe -OutFile $osExe -UseBasicParsing }
    catch { Invoke-WebRequest -Uri $Script:AppSources.OpenShellExeMirror -OutFile $osExe -UseBasicParsing }
  }
  $osDest = Join-Path $apps "OpenShell"
  New-Item -ItemType Directory -Force -Path $osDest | Out-Null
  # Use 7z extraction first (reliable for NSIS/Inno Setup EXEs); fall back to installer /extract
  try {
    Expand-7z -ArchivePath $osExe -Destination $osDest
  } catch {
    try {
      Start-Process -FilePath $osExe -ArgumentList "/extract=`"$osDest`"" -Wait -WindowStyle Hidden -ErrorAction Stop
    } catch {
      Write-BuildLog "Could not extract Open-Shell installer: $_" -Level "Warning"
    }
  }
  $Script:Config.Apps.OpenShell = $osDest

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

    # If chrome.exe not found, try user-provided offline installer
    if (-not (Find-ExeUnder -Root $chPath -ExeName 'chrome.exe')) {
      if ($ChromeOfflineInstallerPath) {
        Write-BuildLog "Extracting Chrome program files from offline installer..." -Level Info
        Install-ChromeFromOfflineInstaller -Installer $ChromeOfflineInstallerPath -Dest (Join-Path $chPath "App")
      } else {
        Write-BuildLog "Chrome++ .7z does not contain chrome.exe. Provide -ChromeOfflineInstallerPath to supply Chrome's standalone installer." -Level "Warning"
        Write-BuildLog "Skipping Chrome++ integration (no chrome.exe available)" -Level "Warning"
        return
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
    } elseif ($ext -eq ".7z") {
      Expand-7z -ArchivePath "$ChromePortablePath" -Destination "$chDest"
    } elseif ($ext -eq ".exe") {
      try { Start-Process -FilePath "$ChromePortablePath" -ArgumentList "/extract=`"$chDest`"" -Wait -WindowStyle Hidden -ErrorAction Stop }
      catch { Expand-7z -ArchivePath "$ChromePortablePath" -Destination "$chDest" }
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
  reg load "HKLM\RAM_SW"  "$softPath" | Out-Null

  try {
    reg add "HKLM\RAM_SW\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /t REG_SZ /d "explorer.exe" /f | Out-Null

    if ($Script:Config.Apps.ContainsKey("Java")) {
      $javaInstall = "C:\Program Files\PortableApps\Java"
      reg add "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v JAVA_HOME /t REG_SZ /d "$javaInstall" /f | Out-Null
      # Append Java\bin to PATH so java.exe is callable without full path
      $existingPath = (reg query "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v Path 2>$null | Where-Object { $_ -match 'REG_' } | ForEach-Object { ($_ -replace '^\s+\S+\s+REG_\S+\s+', '').Trim() })
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
      $existingPath = (reg query "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v Path 2>$null | Where-Object { $_ -match 'REG_' } | ForEach-Object { ($_ -replace '^\s+\S+\s+REG_\S+\s+', '').Trim() })
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
    reg unload "HKLM\RAM_SW"  | Out-Null
  }

  Write-BuildLog "Registry configured" -Level "Success"
}

# ============================================
# SHELL & STARTUP
# ============================================
function Create-StartupScript {
  Write-BuildLog "Creating StartNet.cmd..."
  $mount = $Script:Config.Paths.Mount
  $content = @'
@echo off
echo ==========================================
echo   RAM OS - Initializing WinPE
echo ==========================================
wpeinit

REM Initialize network (wired adapters via DHCP)
wpeutil InitializeNetwork
wpeutil WaitForNetwork

REM Disable Windows Firewall to avoid blocking in WinPE
wpeutil DisableFirewall

exit /b 0
'@
  Set-Content -Path (Join-Path "$mount" "Windows\System32\StartNet.cmd") -Value $content -Force -Encoding ASCII
  Write-BuildLog "StartNet.cmd created" -Level "Success"
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
'@.Replace("{WALL}", $(if ($wall) { $wall } else { "" })).Replace("{ACCENT}", $AccentColor)

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
  $chromeExeRuntime = $Script:Config.Apps.ChromeExe -replace [regex]::Escape($buildAppsRoot), $runtimeAppsRoot

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

  # Verify explorer.exe exists in the image; fall back to cmd.exe
  $explorerInWim = Join-Path $mount "Windows\explorer.exe"
  if (Test-Path $explorerInWim) {
    $launch += 'explorer.exe'
  } else {
    Write-BuildLog "explorer.exe not found in WIM — falling back to cmd.exe shell" -Level "Warning"
    $launch += 'cmd.exe'
  }

  # Check in the mounted WIM, not the running system (PS 5.1 compatible — no ?. operator)
  $mountedBase = Join-Path $mount "Program Files\PortableApps"
  $foundOS = Find-ExeUnder -Root (Join-Path $mountedBase "OpenShell") -ExeName "StartMenu.exe"
  $openShellPath = if ($foundOS) { $foundOS.FullName } else { $null }
  $foundEP = Find-ExeUnder -Root (Join-Path $mountedBase "ExplorerPP") -ExeName "Explorer++.exe"
  $explorerPPPath = if ($foundEP) { $foundEP.FullName } else { $null }

  # Convert to runtime paths (C:\ instead of mount path) — case-insensitive replace
  if ($openShellPath) { 
    $openShellPath = $openShellPath -replace [regex]::Escape($mount), 'C:'
    $launch += '"' + $openShellPath + '"' 
  }
  if ($IncludeExplorerPlus -and $explorerPPPath) { 
    $explorerPPPath = $explorerPPPath -replace [regex]::Escape($mount), 'C:'
    $launch += '"' + $explorerPPPath + '"' 
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
  $bootFile = Join-Path "$isoSource" "boot\etfsboot.com"
  $efiFile = Join-Path "$isoSource" "efi\Microsoft\boot\efisys_noprompt.bin"
  if (-not (Test-Path $efiFile)) { $efiFile = Join-Path "$isoSource" "efi\Microsoft\boot\efisys.bin" }

  if (-not (Test-Path "$bootFile")) { throw "Boot sector file not found: $bootFile" }

  $label = [System.IO.Path]::GetFileNameWithoutExtension($OutputISOName)
  $argList = @("-m","-o","-u2","-udfver102","-l$label")

  if (Test-Path "$efiFile") {
    $bootData = ('-bootdata:2#p0,e,b"{0}"#pEF,e,b"{1}"' -f "$bootFile","$efiFile")
    $argList += $bootData
  } else {
    $argList += "-b$bootFile"
  }
  $argList += @("$isoSource","$outputPath")

  & $Script:Config.Tools.OSCDIMG $argList
  if ($LASTEXITCODE -ne 0) { throw "OSCDIMG failed to create ISO (exit $LASTEXITCODE)" }

  return $outputPath
}

# ============================================
# MAIN
# ============================================
try {
  Initialize-BuildEnvironment

  $bootWim = Mount-SourceISO
  try { Copy-Item $bootWim "$($bootWim).bak" -Force } catch {}

  Mount-TargetWIM -WimPath "$bootWim" -Index $WimIndex

  Add-WinPE-Packages
  Add-DellDrivers
  Add-ExplorerShell

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
  Write-BuildLog ("Size: {0} MB" -f ([math]::Round((Get-Item $finalIso).Length / 1MB, 2))) -Level "Success"

  Write-Host "`n=========================================" -ForegroundColor Green
  Write-Host "RAM OS Build Summary" -ForegroundColor Green
  Write-Host "=========================================" -ForegroundColor Green
  Write-Host "Output File: $finalIso" -ForegroundColor White
  Write-Host "Packages Added: $($Script:Config.Stats.Packages)" -ForegroundColor Gray
  Write-Host "Applications: $($Script:Config.Stats.Apps)" -ForegroundColor Gray
  Write-Host "Drivers (INF count): $($Script:Config.Stats.DriversAdded)" -ForegroundColor Gray
  if ($EnableFBWF) { Write-Host "FBWF: OC added (enablement usually requires reboot; not needed for RAM operation)" -ForegroundColor Gray }
  Write-Host "`nFeatures:" -ForegroundColor Cyan
  Write-Host "  [+] 7-Zip (injected + on PATH)" -ForegroundColor Gray
  Write-Host "  [+] IBM Semeru Java 8 (JAVA_HOME + on PATH)" -ForegroundColor Gray
  Write-Host "  [+] Open-Shell Start Menu" -ForegroundColor Gray
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
  Invoke-Cleanup -Preserve:$KeepMountedWIM
  exit 1
} finally {
  if (-not $KeepMountedWIM) {
    Invoke-Cleanup
  }
}