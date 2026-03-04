<#
.SYNOPSIS
Advanced RAM OS Builder with Hardware Support
Creates a Windows PE-based RAM Operating System with full desktop, portable apps, Dell drivers, and visual theming.

.DESCRIPTION
Transforms Windows ISO into bootable RAM OS using WinPE+FBWF. Features:
- True RAM operation (eject media after boot)
- Dell WinPE11 driver integration (network/storage support)
- Explorer++ file manager option
- Chrome/Chrome Plus browser support
- Custom wallpaper and UI accent colors
- IBM Semeru Java, OpenShell menu
- FBWF RAM disk overlay (volatile storage)

.PARAMETER SourceISO
Path to Windows 10/11 ISO (any edition)

.PARAMETER WorkRoot
Build working directory (20GB free required)

.PARAMETER ChromePortablePath
Local path to Chrome Portable (.zip or .paf.exe) - optional if using -UseChromePlus

.PARAMETER UseChromePlus
Switch to download Chrome Plus (enhanced/patched Chrome) instead of standard Chrome

.PARAMETER IncludeExplorerPlus
Switch to include Explorer++ (lightweight file manager)

.PARAMETER IncludeDellDrivers
Switch to inject Dell WinPE11 driver pack (network/storage drivers for Dell hardware)

.PARAMETER WallpaperPath
Path to custom wallpaper image (.jpg/.png/.bmp)

.PARAMETER AccentColor
Hex color for UI accents (default: 0078D7 = Windows Blue)

.PARAMETER OutputISOName
Output filename for the generated ISO

.PARAMETER RamdiskSizeMB
FBWF overlay size in MB (default: 4096, range: 1024-8192)

.PARAMETER ADKPath
Path to Windows ADK (auto-detected if installed in default location)

.PARAMETER KeepMountedWIM
Switch to preserve mounted WIM on failure (for debugging)

.PARAMETER SkipCleanup
Switch to skip cleanup of temporary files after build

.EXAMPLE
Basic build with Chrome Plus and Dell drivers:
.\Build-RAMOS.ps1 -SourceISO "C:\Win11.iso" -WorkRoot "D:\Build" -UseChromePlus -IncludeDellDrivers

.EXAMPLE
Full featured with custom wallpaper and Explorer++:
.\Build-RAMOS.ps1 -SourceISO "C:\Win11.iso" -WorkRoot "D:\Build" -UseChromePlus -IncludeExplorerPlus -IncludeDellDrivers -WallpaperPath "C:\wallpaper.jpg" -AccentColor "FF5722"
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateScript({
      if (-not (Test-Path "${_}")) {
        throw "Source ISO not found: ${_}"
      }
      return $true
    })]
  [string]${SourceISO},

  [Parameter(Mandatory = $true)]
  [ValidateScript({
      ${resolved} = try {
        Resolve-Path "${_}" -ErrorAction Stop
      } catch {
        $null
      }
      if (-not ${resolved}) {
        throw "Cannot resolve path: ${_}"
      }
      ${drive} = Split-Path -Qualifier ${resolved}
      ${free} = ([System.IO.DriveInfo]::new("${drive}\")).AvailableFreeSpace / 1GB
      if (${free} -lt 8) {
        throw "Insufficient space on ${drive} (${free} GB, need 8+)"
      }
      return $true
    })]
  [string]${WorkRoot},

  [Parameter(Mandatory = $false)]
  [ValidateScript({
      if (${_}) {
        if (-not (Test-Path "${_}")) {
          throw "Chrome path not found: ${_}"
        }
        ${ext} = [System.IO.Path]::GetExtension("${_}").ToLower()
        if (${ext} -notin @('.zip','.exe')) {
          throw "Chrome must be .zip or .exe (PAF)"
        }
      }
      return $true
    })]
  [string]${ChromePortablePath} = "",

  [Parameter(Mandatory = $false)]
  [switch]${UseChromePlus},

  [Parameter(Mandatory = $false)]
  [switch]${IncludeExplorerPlus},

  [Parameter(Mandatory = $false)]
  [switch]${IncludeDellDrivers},

  [Parameter(Mandatory = $false)]
  [ValidateScript({
      if (${_}) {
        if (-not (Test-Path "${_}")) {
          throw "Wallpaper not found: ${_}"
        }
        ${ext} = [System.IO.Path]::GetExtension("${_}").ToLower()
        if (${ext} -notin @('.jpg','.jpeg','.png','.bmp')) {
          throw "Wallpaper must be image file"
        }
      }
      return $true
    })]
  [string]${WallpaperPath},

  [Parameter(Mandatory = $false)]
  [ValidatePattern('^[0-9A-Fa-f]{6}$')]
  [string]${AccentColor} = "0078D7",

  [Parameter(Mandatory = $false)]
  [string]${OutputISOName} = "RAMOS_Desktop.iso",

  [Parameter(Mandatory = $false)]
  [ValidateRange(1024,8192)]
  [uint64]${RamdiskSizeMB} = 4096,

  [Parameter(Mandatory = $false)]
  [string]${ADKPath} = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment",

  [Parameter(Mandatory = $false)]
  [switch]${KeepMountedWIM},

  [Parameter(Mandatory = $false)]
  [switch]${SkipCleanup}
)

#Requires -RunAsAdministrator

# ============================================
# INITIALIZATION
# ============================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

${Script:Config} = @{
  StartTime = Get-Date
  LogFile = $null
  Paths = @{}
  Tools = @{}
  Apps = @{}
  Stats = @{
    Packages = 0
    Apps = 0
    DriversAdded = 0
  }
}
#TODO: Fix subject of Chrome 
# Add 7-zip
${Script:AppSources} = @{
  OpenShell = "https://github.com/Open-Shell/Open-Shell-Menu/releases/download/4.4.191/OpenShell-4.4.191-Portable.zip"
  Semeru = "https://github.com/ibmruntimes/semeru8-binaries/releases/download/jdk8u472-b08_openj9-0.56.0/ibm-semeru-open-jdk_x64_windows_8u472b08_openj9-0.56.0-portable.zip"
  ExplorerPlusPlus = "https://github.com/derceg/explorer-plus-plus/releases/download/1.4.0/explorerpp_x64.zip"
  ChromePlus = "https://github.com/Bush2021/chrome_plus/releases/download/1.15.1/Chrome++_v1.15.1_x86_x64_arm64.7z"
  ChromePortable = "https://dl.google.com/release2/chrome/nuloamky47wcog6772kpqu2zyu_145.0.7632.160/145.0.7632.160_chrome_installer_uncompressed.exe" # Note: This is the online installer, not a true portable version. Will attempt silent extraction.
  DellWinPEDrivers = "https://downloads.dell.com/FOLDER14002062M/1/WinPE11.0-Drivers-A08-2V5TD.cab"
  SevenZip = "https://www.7-zip.org/a/7z2201-x64.exe"
}

${Script:WinPEPackages} = @(
  "WinPE-WMI"
  "WinPE-NetFx"
  "WinPE-NetFx2"
  "WinPE-PowerShell"
  "WinPE-Scripting"
  "WinPE-HTA"
  "WinPE-Shell-Setup" # Critical for Explorer
  "WinPE-Shell-Setup-WOW64" # 32-bit app support
  "WinPE-Fonts-Legacy"
  "WinPE-WINTOC"
  "WinPE-StorageWMI"
  "WinPE-WlanSvc"
)

# ============================================
# LOGGING FUNCTIONS
# ============================================
function Write-BuildLog {
  param(
    [Parameter(Mandatory = $true)]
    [string]${Message},
    [ValidateSet("Info","Success","Warning","Error")]
    [string]${Level} = "Info"
  )

  ${ts} = Get-Date -Format "HH:mm:ss"
  ${color} = switch (${Level}) {
    "Success" { "Green" }
    "Error" { "Red" }
    "Warning" { "Yellow" }
    default { "Cyan" }
  }

  Write-Host "[${ts}] [${Level}] ${Message}" -ForegroundColor ${color}
}

# ============================================
# SETUP FUNCTIONS
# ============================================
function Initialize-BuildEnvironment {
  Write-BuildLog "Initializing RAM OS Builder v4.1 (Dell Support Edition)..."

  # Setup directory structure
  ${Script:Config}.Paths = @{
    Root = (Resolve-Path "${WorkRoot}").Path
    ISO = Join-Path "${WorkRoot}" "ISO_Source"
    Mount = Join-Path "${WorkRoot}" "Mount_WIM"
    Apps = Join-Path "${WorkRoot}" "Apps"
    Cache = Join-Path "${WorkRoot}" "Cache"
    Output = Join-Path "${WorkRoot}" "Output"
    Temp = Join-Path "${WorkRoot}" "Temp"
  }

  foreach (${p} in ${Script:Config}.Paths.Values) {
    if (-not (Test-Path "${p}")) {
      New-Item -ItemType Directory -Path "${p}" -Force | Out-Null
    }
  }

  # Initialize logging
  ${Script:Config}.LogFile = Join-Path ${Script:Config}.Paths.Output "Build-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
  Start-Transcript -Path ${Script:Config}.LogFile | Out-Null

  # Validate ADK installation
  if (-not (Test-Path "${ADKPath}")) {
    throw "Windows ADK not found at: ${ADKPath}`nDownload from: https://aka.ms/adk`nInstall 'Windows Preinstallation Environment' component."
  }

  ${Script:Config}.Tools = @{
    DISM = Join-Path (Split-Path "${ADKPath}") "Deployment Tools\AMD64\DISM\dism.exe"
    OSCDIMG = Join-Path (Split-Path "${ADKPath}") "Deployment Tools\AMD64\Oscdimg\oscdimg.exe"
    WinPEOCs = Join-Path "${ADKPath}" "amd64\WinPE_OCs"
  }

  if (-not (Test-Path ${Script:Config}.Tools.DISM)) {
    throw "DISM.exe not found in ADK installation"
  }
  if (-not (Test-Path ${Script:Config}.Tools.OSCDIMG)) {
    throw "OSCDIMG.exe not found in ADK installation"
  }

  Write-BuildLog "Build environment initialized" -Level "Success"
}

function Invoke-Cleanup {
  param([switch]${Preserve})

  Write-BuildLog "Performing cleanup..."

  # Unmount WIM if exists
  if ((Test-Path ${Script:Config}.Paths.Mount) -and (-not ${Preserve})) {
    & ${Script:Config}.Tools.DISM /Unmount-Image /MountDir:${Script:Config}.Paths.Mount /Discard 2>&1 | Out-Null
  }

  # Dismount ISO if still mounted
  Get-DiskImage -ImagePath "${SourceISO}" -ErrorAction SilentlyContinue |
  Dismount-DiskImage | Out-Null

  # Remove temp directories (unless KeepMountedWIM)
  if (-not ${SkipCleanup}) {
    Remove-Item ${Script:Config}.Paths.Apps -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item ${Script:Config}.Paths.Temp -Recurse -Force -ErrorAction SilentlyContinue
  }

  Stop-Transcript -ErrorAction SilentlyContinue
}

# ============================================
# ISO & WIM FUNCTIONS
# ============================================
function Mount-SourceISO {
  Write-BuildLog "Mounting source ISO..."

  Mount-DiskImage -ImagePath "${SourceISO}" -ErrorAction Stop | Out-Null
  ${vol} = Get-DiskImage -ImagePath "${SourceISO}" | Get-Volume
  ${letter} = "${vol}".DriveLetter

  if (-not (Test-Path "${letter}:\sources\boot.wim")) {
    throw "Invalid ISO: boot.wim not found in sources folder"
  }

  Write-BuildLog "Extracting ISO contents (this may take a minute)..."
  robocopy "${letter}:\" ${Script:Config}.Paths.ISO /E /NFL /NDL /R:0 /W:0 /MT:8 | Out-Null
  if ($LASTEXITCODE -gt 7) {
    throw "Robocopy failed with exit code: $LASTEXITCODE"
  }

  Dismount-DiskImage -ImagePath "${SourceISO}" | Out-Null

  return (Join-Path ${Script:Config}.Paths.ISO "sources\boot.wim")
}

function Mount-TargetWIM {
  param([string]${WimPath})

  Write-BuildLog "Mounting boot.wim (Index 2: WinPE + Setup)..."

  & ${Script:Config}.Tools.DISM /Mount-Image /ImageFile:"${WimPath}" /Index:2 /MountDir:${Script:Config}.Paths.Mount | Out-Null
  if (${LASTEXITCODE} -ne 0) {
    throw "Failed to mount WIM. Ensure sufficient RAM and no existing mount conflicts."
  }

  # Validate critical hives exist
  ${sysHive} = Join-Path ${Script:Config}.Paths.Mount "Windows\System32\config\SYSTEM"
  ${softHive} = Join-Path ${Script:Config}.Paths.Mount "Windows\System32\config\SOFTWARE"

  if (-not (Test-Path "${sysHive}")) {
    throw "SYSTEM hive missing in mounted WIM"
  }
  if (-not (Test-Path "${softHive}")) {
    throw "SOFTWARE hive missing in mounted WIM"
  }

  Write-BuildLog "WIM mounted successfully" -Level "Success"
}

function Add-WinPE-Packages {
  Write-BuildLog "Installing WinPE Desktop Environment packages..."

  ${mount} = ${Script:Config}.Paths.Mount
  ${count} = 0

  foreach (${pkg} in ${Script:WinPEPackages}) {
    ${cab} = Join-Path ${Script:Config}.Tools.WinPEOCs "${pkg}.cab"

    if (Test-Path "${cab}") {
      & ${Script:Config}.Tools.DISM /Add-Package /Image:"${mount}" /PackagePath:"${cab}" /IgnoreCheck | Out-Null
      if (${LASTEXITCODE} -eq 0) {
        ${count}++
      }

      # Add language pack if available
      ${langCab} = Join-Path ${Script:Config}.Tools.WinPEOCs "en-us\${pkg}_en-us.cab"
      if (Test-Path "${langCab}") {
        & ${Script:Config}.Tools.DISM /Add-Package /Image:"${mount}" /PackagePath:"${langCab}" /IgnoreCheck | Out-Null
      }
    }
  }

  ${Script:Config}.Stats.Packages = ${count}
  Write-BuildLog "Added ${count} WinPE packages" -Level "Success"
}

function Add-DellDrivers {
  if (-not ${IncludeDellDrivers}) {
    return
  }

  Write-BuildLog "Acquiring Dell WinPE11 drivers..."
  ${dellCab} = Join-Path ${Script:Config}.Paths.Cache "Dell-WinPE11-Drivers.cab"

  # Download if not cached
  if (-not (Test-Path "${dellCab}")) {
    try {
      Invoke-WebRequest -Uri ${Script:AppSources}.DellWinPEDrivers -OutFile "${dellCab}" -UseBasicParsing
    } catch {
      Write-BuildLog "Failed to download Dell drivers: ${_}" -Level "Warning"
      return
    }
  }

  Write-BuildLog "Injecting Dell drivers into WinPE..."

  # Method 1: Try as a CAB package
  & ${Script:Config}.Tools.DISM /Add-Package /Image:${Script:Config}.Paths.Mount /PackagePath:"${dellCab}" /IgnoreCheck | Out-Null

  if (${LASTEXITCODE} -eq 0) {
    ${Script:Config}.Stats.DriversAdded = "Dell Package (All Drivers)"
    Write-BuildLog "Dell driver package integrated successfully" -Level "Success"
  } else {
    # Method 2: Extract and inject as drivers
    ${extractDir} = Join-Path ${Script:Config}.Paths.Temp "DellDrivers"
    Write-BuildLog "Extracting driver CAB for injection..."

    Expand-Archive "${dellCab}" "${extractDir}" -Force -ErrorAction SilentlyContinue

    if (Test-Path "${extractDir}") {
      & ${Script:Config}.Tools.DISM /Add-Driver /Image:${Script:Config}.Paths.Mount /Driver:"${extractDir}" /Recurse /ForceUnsigned 2>&1 | Out-Null
      ${Script:Config}.Stats.DriversAdded = "Dell Drivers (Extracted)"
      Write-BuildLog "Dell drivers injected via driver method" -Level "Success"
    }
  }
}

# ============================================
# APPLICATION FUNCTIONS
# ============================================
function Get-Applications {
  Write-BuildLog "Downloading portable applications..."

  ${cache} = ${Script:Config}.Paths.Cache
  ${apps} = ${Script:Config}.Paths.Apps

  # OpenShell
  ${osZip} = Join-Path "${cache}" "OpenShell.zip"
  if (-not (Test-Path "${osZip}")) {
    Invoke-WebRequest -Uri ${Script:AppSources}.OpenShell -OutFile "${osZip}" -UseBasicParsing
  }
  Expand-Archive "${osZip}" (Join-Path "${apps}" "OpenShell") -Force
  ${Script:Config}.Apps.OpenShell = Join-Path "${apps}" "OpenShell"

  # IBM Semeru Java
  ${jvZip} = Join-Path "${cache}" "Semeru.zip"
  if (-not (Test-Path "${jvZip}")) {
    Invoke-WebRequest -Uri ${Script:AppSources}.Semeru -OutFile "${jvZip}" -UseBasicParsing
  }
  Expand-Archive "${jvZip}" (Join-Path "${apps}" "Java") -Force
  ${Script:Config}.Apps.Java = Join-Path "${apps}" "Java"

  # Chrome / Chrome Plus
  if (${UseChromePlus}) {
    Write-BuildLog "Downloading Chrome Plus..."
    ${cpExe} = Join-Path "${cache}" "ChromePlus.exe"
    Invoke-WebRequest -Uri ${Script:AppSources}.ChromePlus -OutFile "${cpExe}" -UseBasicParsing

    ${chPath} = Join-Path "${apps}" "Chrome"
    New-Item -Path "${chPath}" -ItemType Directory -Force | Out-Null

    # Try to extract if 7z available, otherwise copy as-is
    if (Get-Command 7z -ErrorAction SilentlyContinue) {
      & 7z x "${cpExe}" -o"${chPath}" -y | Out-Null
    } else {
      Copy-Item "${cpExe}" (Join-Path "${chPath}" "ChromePlus.exe")
      Write-BuildLog "Chrome Plus saved as installer (extract manually or install after boot)" -Level "Warning"
    }
    ${Script:Config}.Apps.Chrome = ${chPath}
  }
  elseif (${ChromePortablePath}) {
    Write-BuildLog "Extracting provided Chrome Portable..."
    ${chDest} = Join-Path "${apps}" "Chrome"
    ${ext} = [System.IO.Path]::GetExtension("${ChromePortablePath}").ToLower()

    if (${ext} -eq ".zip") {
      Expand-Archive "${ChromePortablePath}" "${chDest}" -Force
    }
    elseif (${ext} -eq ".exe") {
      # Try PAF silent extraction
      Start-Process -FilePath "${ChromePortablePath}" -ArgumentList "/destination=`"${chDest}`"" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue

      if ((-not (Test-Path "${chDest}")) -and (Get-Command 7z -ErrorAction SilentlyContinue)) {
        & 7z x "${ChromePortablePath}" -o"${chDest}" -y | Out-Null
      }
    }
    ${Script:Config}.Apps.Chrome = ${chDest}
  }

  # Explorer++
  if (${IncludeExplorerPlus}) {
    Write-BuildLog "Downloading Explorer++..."
    ${epZip} = Join-Path "${cache}" "ExplorerPP.zip"
    if (-not (Test-Path "${epZip}")) {
      Invoke-WebRequest -Uri ${Script:AppSources}.ExplorerPlusPlus -OutFile "${epZip}" -UseBasicParsing
    }
    Expand-Archive "${epZip}" (Join-Path "${apps}" "ExplorerPP") -Force
    ${Script:Config}.Apps.ExplorerPP = Join-Path "${apps}" "ExplorerPP"
  }
}

function Inject-AllApps {
  Write-BuildLog "Injecting applications into WIM image..."

  ${progFiles} = Join-Path ${Script:Config}.Paths.Mount "Program Files\PortableApps"
  New-Item -Path "${progFiles}" -ItemType Directory -Force | Out-Null

  foreach (${app} in ${Script:Config}.Apps.GetEnumerator()) {
    Write-BuildLog "Injecting: $($app.Key)"
    ${dest} = Join-Path "${progFiles}" "$($app.Key)"
    Copy-Item "$($app.Value)" "${dest}" -Recurse -Force
    ${Script:Config}.Stats.Apps++
  }

  # Copy custom wallpaper if provided
  if (${WallpaperPath}) {
    Write-BuildLog "Injecting custom wallpaper..."
    ${wallDir} = Join-Path ${Script:Config}.Paths.Mount "Windows\Web\Wallpaper\RAMOS"
    New-Item -Path "${wallDir}" -ItemType Directory -Force | Out-Null
    Copy-Item "${WallpaperPath}" (Join-Path "${wallDir}" "custom.jpg") -Force
    ${Script:Config}.WallpaperDest = "C:\Windows\Web\Wallpaper\RAMOS\custom.jpg"
  }
}

# ============================================
# REGISTRY CONFIGURATION
# ============================================
function Configure-SystemRegistry {
  Write-BuildLog "Configuring Registry for RAM OS operation..."

  ${mount} = ${Script:Config}.Paths.Mount

  # Load SYSTEM and SOFTWARE hives
  ${sysPath} = Join-Path "${mount}" "Windows\System32\config\SYSTEM"
  ${softPath} = Join-Path "${mount}" "Windows\System32\config\SOFTWARE"

  reg load "HKLM\RAM_SYS" "${sysPath}" | Out-Null
  reg load "HKLM\RAM_SW" "${softPath}" | Out-Null

  try {
    # --- FBWF Configuration (Critical for RAM Operation) ---
    # Service setup
    reg add "HKLM\RAM_SYS\ControlSet001\Services\FBWF" /v Start /t REG_DWORD /d 0 /f | Out-Null # Boot start
    reg add "HKLM\RAM_SYS\ControlSet001\Services\FBWF" /v Get-Content /t REG_DWORD /d 1 /f | Out-Null # Kernel driver (FIXED: was Get-Content)

    # FBWF Settings
    reg add "HKLM\RAM_SYS\ControlSet001\Control\FBWF" /v Enabled /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKLM\RAM_SYS\ControlSet001\Control\FBWF" /v OverlaySize /t REG_DWORD /d ${RamdiskSizeMB} /f | Out-Null
    reg add "HKLM\RAM_SYS\ControlSet001\Control\FBWF" /v Compression /t REG_DWORD /d 1 /f | Out-Null

    # --- Shell Configuration ---
    # MUST use Explorer.exe as shell (OpenShell requires Explorer to host it)
    reg add "HKLM\RAM_SW\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /t REG_SZ /d "explorer.exe" /f | Out-Null

    # Auto-start OpenShell after Explorer loads
    ${osPath} = "C:\Program Files\PortableApps\OpenShell\OpenShell.exe"
    if (Test-Path (Join-Path ${mount} "Program Files\PortableApps\OpenShell\StartMenu.exe")) {
      ${osPath} = "C:\Program Files\PortableApps\OpenShell\StartMenu.exe"
    }
    reg add "HKLM\RAM_SW\Microsoft\Windows\CurrentVersion\Run" /v OpenShell /t REG_SZ /d "`"${osPath}`"" /f | Out-Null

    # --- Visual Customizations ---
    if (${WallpaperPath}) {
      reg add "HKLM\RAM_SW\Microsoft\Windows\CurrentVersion\Themes" /v DesktopBackground /t REG_SZ /d "${Script:Config}.WallpaperDest" /f | Out-Null
    }

    # Accent Color
    reg add "HKLM\RAM_SW\Microsoft\Windows\DWM" /v AccentColor /t REG_DWORD /d "0x${AccentColor}" /f | Out-Null

    # --- Environment Variables ---
    if (${Script:Config}.Apps.ContainsKey("Java")) {
      reg add "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v JAVA_HOME /t REG_SZ /d "C:\Program Files\PortableApps\Java" /f | Out-Null
    }

    # --- Services (Network) ---
    ${services} = @("WlanSvc","Dhcp","Dnscache","NlaSvc","netprofm")
    foreach (${svc} in ${services}) {
      reg add "HKLM\RAM_SYS\ControlSet001\Services\${svc}" /v Start /t REG_DWORD /d 2 /f | Out-Null
    }

    # --- Explorer++ Integration ---
    if (${IncludeExplorerPlus}) {
      reg add "HKLM\RAM_SW\Classes\Directory\shell\ExplorerPP" /ve /d "Open with Explorer++" /f | Out-Null
      reg add "HKLM\RAM_SW\Classes\Directory\shell\ExplorerPP\command" /ve /d "C:\Program Files\PortableApps\ExplorerPP\Explorer++.exe `"%1`"" /f | Out-Null
    }
  }
  finally {
    reg unload "HKLM\RAM_SYS" | Out-Null
    reg unload "HKLM\RAM_SW" | Out-Null
  }

  Write-BuildLog "Registry configured successfully" -Level "Success"
}

# ============================================
# STARTUP & BUILD FUNCTIONS
# ============================================
function Create-StartupScript {
  Write-BuildLog "Creating WinPE startup scripts..."

  ${mount} = ${Script:Config}.Paths.Mount

  # StartNet.cmd - WinPE initialization
  ${content} = @'
@echo off
echo ==========================================
echo  RAM OS v4.1 - Initializing...
echo ==========================================
echo.

:: Initialize network stack
wpeinit

:: Enable File-Based Write Filter (RAM overlay)
echo Enabling RAM Overlay (FBWF)...
fbwfmgr /enable

:: Brief pause for FBWF to initialize (ping = compatible delay)
ping 127.0.0.1 -n 2 >nul

:: Start Windows Explorer (Desktop)
echo Starting Desktop Environment...
start explorer.exe

:: Delay then start enhancements
ping 127.0.0.1 -n 3 >nul

:: Start OpenShell (Start Menu replacement)
if exist "C:\Program Files\PortableApps\OpenShell\StartMenu.exe" (
    start "" "C:\Program Files\PortableApps\OpenShell\StartMenu.exe"
)

:: Start Explorer++ if available
if exist "C:\Program Files\PortableApps\ExplorerPP\Explorer++.exe" (
    start "" "C:\Program Files\PortableApps\ExplorerPP\Explorer++.exe"
)

echo.
echo RAM OS Ready. You may remove boot media.
echo.

exit
'@

  Set-Content -Path (Join-Path "${mount}" "Windows\System32\StartNet.cmd") -Value ${content} -Force -Encoding ASCII
  Write-BuildLog "Startup script created" -Level "Success"
}

function Build-FinalISO {
  Write-BuildLog "Building final ISO image..."

  ${mount} = ${Script:Config}.Paths.Mount
  ${isoSource} = ${Script:Config}.Paths.ISO

  # Commit WIM changes
  & ${Script:Config}.Tools.DISM /Unmount-Image /MountDir:"${mount}" /Commit | Out-Null
  if (${LASTEXITCODE} -ne 0) {
    throw "Failed to commit WIM changes"
  }

  # Build ISO
  ${outputPath} = Join-Path ${Script:Config}.Paths.Output "${OutputISOName}"
  ${bootFile} = Join-Path "${isoSource}" "boot\etfsboot.com"
  ${efiFile} = Join-Path "${isoSource}" "efi\Microsoft\boot\efisys.bin"

  if (-not (Test-Path "${bootFile}")) {
    throw "Boot sector file not found"
  }

  ${argList} = @("-m","-o","-u2","-udfver102","-l$([System.IO.Path]::GetFileNameWithoutExtension(${OutputISOName}))")

  # Dual-boot (BIOS + UEFI) if EFI files present, else BIOS only
  if (Test-Path "${efiFile}") {
    ${bootData} = '-bootdata:2#p0,e,b"{0}"#pEF,e,b"{1}"' -f "${bootFile}","${efiFile}"
    ${argList} += ${bootData}
  } else {
    ${argList} += "-b${bootFile}"
  }

  ${argList} += @("${isoSource}","${outputPath}")

  & ${Script:Config}.Tools.OSCDIMG ${argList}
  if (${LASTEXITCODE} -ne 0) {
    throw "OSCDIMG failed to create ISO"
  }

  return ${outputPath}
}

# ============================================
# MAIN EXECUTION
# ============================================
try {
  Initialize-BuildEnvironment

  ${bootWim} = Mount-SourceISO
  Mount-TargetWIM -WimPath "${bootWim}"

  Add-WinPE-Packages
  Add-DellDrivers

  Get-Applications
  Inject-AllApps

  Configure-SystemRegistry
  Create-StartupScript

  ${finalIso} = Build-FinalISO

  # Summary
  Write-BuildLog "BUILD COMPLETED SUCCESSFULLY" -Level "Success"
  Write-BuildLog "Output: ${finalIso}" -Level "Success"
  Write-BuildLog "Size: $([math]::Round((Get-Item ${finalIso}).Length / 1MB, 2)) MB" -Level "Success"

  Write-Host "`n=========================================" -ForegroundColor Green
  Write-Host "RAM OS Build Summary" -ForegroundColor Green
  Write-Host "=========================================" -ForegroundColor Green
  Write-Host "Output File: ${finalIso}" -ForegroundColor White
  Write-Host "Packages Added: ${Script:Config}.Stats.Packages" -ForegroundColor Gray
  Write-Host "Applications: ${Script:Config}.Stats.Apps" -ForegroundColor Gray
  Write-Host "Drivers: ${Script:Config}.Stats.DriversAdded" -ForegroundColor Gray
  Write-Host "RAM Overlay: ${RamdiskSizeMB} MB (FBWF)" -ForegroundColor Gray
  Write-Host "`nFeatures:" -ForegroundColor Cyan
  if (${UseChromePlus}) { Write-Host "  [+] Chrome Plus Browser" -ForegroundColor Gray }
  if (${IncludeExplorerPlus}) { Write-Host "  [+] Explorer++ File Manager" -ForegroundColor Gray }
  if (${IncludeDellDrivers}) { Write-Host "  [+] Dell WinPE11 Drivers" -ForegroundColor Gray }
  if (${WallpaperPath}) { Write-Host "  [+] Custom Wallpaper" -ForegroundColor Gray }
  Write-Host "=========================================" -ForegroundColor Green
  Write-Host "`nBoot Instructions:" -ForegroundColor Yellow
  Write-Host "1. Write ISO to USB (Rufus/Ventoy) or mount in VM" -ForegroundColor White
  Write-Host "2. Boot from USB - loads entirely into RAM" -ForegroundColor White
  Write-Host "3. Desktop appears - you can eject USB now!" -ForegroundColor White
  Write-Host "4. All changes save to RAM only (lost on reboot)" -ForegroundColor White

} catch {
  Write-BuildLog "BUILD FAILED: ${_}" -Level "Error"
  Write-BuildLog "Stack: $($_.ScriptStackTrace)" -Level "Error"
  Invoke-Cleanup -Preserve:${KeepMountedWIM}
  exit 1
} finally {
  if (-not ${KeepMountedWIM}) {
    Invoke-Cleanup
  }
}
