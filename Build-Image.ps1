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
      $resolved = try { Resolve-Path "$_" -ErrorAction Stop } catch { $null }
      if (-not $resolved) { throw "Cannot resolve path: $_" }
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
  [string]$ADKPath = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment",

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

  # Minimal 7-zip standalone extractor
  SevenZipMini        = "https://www.7-zip.org/a/7zr.exe"
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
function Initialize-BuildEnvironment {
  Write-BuildLog "Initializing RAM OS Builder..."

  $Script:Config.Paths = @{
    Root   = (Resolve-Path "$WorkRoot").Path
    ISO    = Join-Path "$WorkRoot" "ISO_Source"
    Mount  = Join-Path "$WorkRoot" "Mount_WIM"
    Apps   = Join-Path "$WorkRoot" "Apps"
    Cache  = Join-Path "$WorkRoot" "Cache"
    Output = Join-Path "$WorkRoot" "Output"
    Temp   = Join-Path "$WorkRoot" "Temp"
  }
  foreach ($p in $Script:Config.Paths.Values) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
  }

  $Script:Config.LogFile = Join-Path $Script:Config.Paths.Output "Build-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
  Start-Transcript -Path $Script:Config.LogFile | Out-Null

  # Probe ADK + WinPE add-on
  $candidates = @(
    $ADKPath,
    "${env:ProgramFiles(x86)}\Windows Kits\11\Assessment and Deployment Kit\Windows Preinstallation Environment",
    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment"
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

  if (-not $candidates) {
    throw "Windows ADK WinPE add-on not found. Install ADK + WinPE add-on: https://aka.ms/adk"
  }

  $winpeAddOn = $candidates[0]
  $adkRoot    = Split-Path $winpeAddOn

  $Script:Config.Tools = @{
    DISM     = Join-Path $adkRoot "Deployment Tools\AMD64\DISM\dism.exe"
    OSCDIMG  = Join-Path $adkRoot "Deployment Tools\AMD64\Oscdimg\oscdimg.exe"
    WinPEOCs = Join-Path $winpeAddOn "amd64\WinPE_OCs"
  }

  if (-not (Test-Path $Script:Config.Tools.DISM)) {
    $Script:Config.Tools.DISM = (Get-Command dism.exe).Source
  }
  if (-not (Test-Path $Script:Config.Tools.OSCDIMG)) {
    throw "OSCDIMG.exe not found in ADK installation"
  }
  if (-not (Test-Path $Script:Config.Tools.WinPEOCs)) {
    throw "WinPE optional components folder not found: $($Script:Config.Tools.WinPEOCs)"
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
  return (Join-Path $Script:Config.Paths.ISO "sources\boot.wim")
}

function Mount-TargetWIM {
  param(
    [Parameter(Mandatory)][string]$WimPath,
    [ValidateSet(1,2)][int]$Index = 1
  )

  Write-BuildLog "Mounting boot.wim (Index $Index)..."
  & $Script:Config.Tools.DISM /Mount-Image /ImageFile:"$WimPath" /Index:$Index /MountDir:$Script:Config.Paths.Mount | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to mount WIM. Ensure no mount conflicts and sufficient disk space." }
  $Script:State.Mounted = $true

  foreach ($hive in "SYSTEM","SOFTWARE") {
    $p = Join-Path $Script:Config.Paths.Mount "Windows\System32\config\$hive"
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
  if (-not (Test-Path (Join-Path $ocRoot "$lang"))) { $lang = "en-us" }

  $packages = $Script:WinPEPackages.Clone()
  if ($EnableFBWF) { $packages += "WinPE-FBWF" }

  foreach ($pkg in $packages) {
    $cab = Join-Path $ocRoot "$pkg.cab"
    if (Test-Path $cab) {
      & $Script:Config.Tools.DISM /Add-Package /Image:"$mount" /PackagePath:"$cab" /IgnoreCheck | Out-Null
      if ($LASTEXITCODE -eq 0) { $count++ } else { Write-BuildLog "Failed adding package: $pkg" -Level Warning }
      $langCab = Join-Path $ocRoot "$lang\${pkg}_${lang}.cab"
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
  $dellCab = Join-Path $Script:Config.Paths.Cache "Dell-WinPE11-Drivers.cab"
  if (-not (Test-Path $dellCab)) {
    try {
      Invoke-WebRequest -Uri $Script:AppSources.DellWinPEDrivers -OutFile $dellCab -UseBasicParsing
    } catch {
      Write-BuildLog "Failed to download Dell drivers: $_" -Level "Warning"
      return
    }
  }

  Write-BuildLog "Extracting and injecting Dell drivers..."
  $extractDir = Join-Path $Script:Config.Paths.Temp "DellDrivers"
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
  try {
    Start-Process -FilePath $Installer -ArgumentList "/extract=`"$Dest`"" -Wait -WindowStyle Hidden -ErrorAction Stop
  } catch {
    Expand-7z -ArchivePath $Installer -Destination $Dest
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
  try {
    Start-Process -FilePath $osExe -ArgumentList "/extract=`"$osDest`"" -Wait -WindowStyle Hidden -ErrorAction Stop
  } catch {
    Expand-7z -ArchivePath $osExe -Destination $osDest
  }
  $Script:Config.Apps.OpenShell = $osDest

  # --- IBM Semeru Java (prefer latest; fallback to prior) ---
  $jvZip = Join-Path $cache "Semeru.zip"
  if (-not (Test-Path $jvZip)) {
    try { Invoke-WebRequest -Uri $Script:AppSources.SemeruPrimary -OutFile $jvZip -UseBasicParsing }
    catch { Invoke-WebRequest -Uri $Script:AppSources.SemeruFallback -OutFile $jvZip -UseBasicParsing }
  }
  Expand-Archive $jvZip (Join-Path $apps "Java") -Force
  $Script:Config.Apps.Java = Join-Path $apps "Java"

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
    if (-not (Find-ExeUnder -Root $chPath -ExeName 'chrome.exe') -and $ChromeOfflineInstallerPath) {
      Write-BuildLog "Extracting Chrome program files from offline installer..." -Level Info
      Install-ChromeFromOfflineInstaller -Installer $ChromeOfflineInstallerPath -Dest (Join-Path $chPath "App")
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
      reg add "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v JAVA_HOME /t REG_SZ /d "C:\Program Files\PortableApps\Java" /f | Out-Null
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
  REM Accent color visibility (best-effort)
  reg add "HKCU\Software\Microsoft\Windows\DWM" /v ColorPrevalence /t REG_DWORD /d 1 /f >nul 2>&1
)
exit /b 0
'@.Replace("{WALL}", ($wall ? $wall : ""))

  Set-Content -Path (Join-Path $postDir "PostShell.cmd") -Value $post -Encoding ASCII -Force
  Write-BuildLog "PostShell.cmd created" -Level "Success"
}

function Create-ChromeLauncher {
  if (-not $Script:Config.Apps.ChromeExe) { return }
  Write-BuildLog "Creating Chrome launcher (X:\ profile)..."
  $mount = $Script:Config.Paths.Mount
  $tools = Join-Path $mount "Windows\System32\RAMOS"
  New-Item -ItemType Directory -Force -Path $tools | Out-Null

  $chromeExe = $Script:Config.Apps.ChromeExe
  $launcher = @'
@echo off
set "PROFILE=X:\ChromeProfile"
set "CACHE=X:\ChromeCache"
if not exist "%PROFILE%" mkdir "%PROFILE%"
if not exist "%CACHE%" mkdir "%CACHE%"
start "" "{CHROME}" --user-data-dir="%PROFILE%" --disk-cache-dir="%CACHE%" --no-first-run --no-default-browser-check
exit /b 0
'@.Replace('{CHROME}',$chromeExe)

  Set-Content -Path (Join-Path $tools "StartChrome.cmd") -Value $launcher -Encoding ASCII -Force
}

function Write-Winpeshl {
  Write-BuildLog "Writing winpeshl.ini..."
  $mount = $Script:Config.Paths.Mount
  $iniPath = Join-Path $mount "Windows\System32\winpeshl.ini"

  $launch = @("[LaunchApps]")
  $launch += 'explorer.exe'

  # Check in the mounted WIM, not the running system
  $mountedBase = Join-Path $mount "Program Files\PortableApps"
  $openShellPath = (Find-ExeUnder -Root (Join-Path $mountedBase "OpenShell") -ExeName "StartMenu.exe")?.FullName
  $explorerPPPath = (Find-ExeUnder -Root (Join-Path $mountedBase "ExplorerPP") -ExeName "Explorer++.exe")?.FullName

  # Convert to runtime paths (C:\ instead of mount path)
  if ($openShellPath) { 
    $openShellPath = $openShellPath.Replace($mount, "C:")
    $launch += '"' + $openShellPath + '"' 
  }
  if ($IncludeExplorerPlus -and $explorerPPPath) { 
    $explorerPPPath = $explorerPPPath.Replace($mount, "C:")
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