# ====================================
# RAM OS Builder - Environment Verification
# Pre-flight checks for build readiness
# ====================================

#Requires -RunAsAdministrator

Clear-Host

Write-Host "=======================================================" -ForegroundColor Magenta
Write-Host "  RAM OS Builder - Environment Verification" -ForegroundColor Magenta
Write-Host "=======================================================" -ForegroundColor Magenta
Write-Host ""

$allGood = $true
$warnings = @()
$errors = @()

# ====================================
# SYSTEM CHECKS
# ====================================
Write-Host "[1/8] System Requirements" -ForegroundColor Cyan

# Windows Version
$osVersion = [System.Environment]::OSVersion.Version
if ($osVersion.Major -ge 10) {
  Write-Host "  OK  Windows Version: $osVersion" -ForegroundColor Green
}
else {
  Write-Host "  ERR Windows Version: $osVersion (Requires Windows 10+)" -ForegroundColor Red
  $allGood = $false
  $errors += "Windows version too old"
}

# Administrator Check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
if ($isAdmin) {
  Write-Host "  OK  Administrator: Yes" -ForegroundColor Green
}
else {
  Write-Host "  ERR Administrator: No (REQUIRED)" -ForegroundColor Red
  Write-Host "       Please run PowerShell as Administrator" -ForegroundColor Yellow
  $allGood = $false
  $errors += "Not running as administrator"
}

# PowerShell Version
$psVersion = $PSVersionTable.PSVersion
Write-Host "  OK  PowerShell: v$psVersion" -ForegroundColor Green

# Disk Space
$scriptDir = if ([string]::IsNullOrEmpty($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
$driveLetter = if ($scriptDir.Length -ge 2 -and $scriptDir[1] -eq ':') { $scriptDir[0] } else { (Get-Location).Drive.Name }
$drive = Get-PSDrive $driveLetter -ErrorAction SilentlyContinue
if ($drive) {
  $freeGB = $drive.Free / 1GB
  if ($freeGB -gt 50) {
    Write-Host "  OK  Free Space: $([math]::Round($freeGB, 1)) GB" -ForegroundColor Green
  }
  elseif ($freeGB -gt 20) {
    Write-Host "  WARN Free Space: $([math]::Round($freeGB, 1)) GB (Recommended 50GB+)" -ForegroundColor Yellow
    $warnings += "Low disk space ($([math]::Round($freeGB, 1)) GB free)"
  }
  else {
    Write-Host "  ERR Free Space: $([math]::Round($freeGB, 1)) GB (Need at least 20GB)" -ForegroundColor Red
    $errors += "Insufficient disk space"
    $allGood = $false
  }
}

Write-Host ""

# ====================================
# REQUIRED SCRIPTS
# ====================================
Write-Host "[2/8] Required Scripts" -ForegroundColor Cyan

$scripts = @(
  'Build-Image.ps1',
  'Build-Image-OldWay.ps1',
  'Quick-Launch.ps1',
  'Verify-Environment.ps1'
)

foreach ($scriptName in $scripts) {
  $scriptPath = Join-Path $scriptDir $scriptName
  if (Test-Path $scriptPath) {
    $size = (Get-Item $scriptPath).Length / 1KB
    Write-Host "  OK  $scriptName ($([math]::Round($size, 1)) KB)" -ForegroundColor Green
  }
  else {
    Write-Host "  WARN $scriptName (NOT FOUND)" -ForegroundColor Yellow
    $warnings += "Missing script: $scriptName"
  }
}

Write-Host ""

# ====================================
# POWERSHELL MODULES & DISM TOOLS
# ====================================
Write-Host "[3/8] PowerShell Modules & DISM" -ForegroundColor Cyan

# OSD Module (strongly recommended)
$osdModule = Get-Module OSD -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if ($osdModule) {
  Write-Host "  OK  OSD Module: v$($osdModule.Version) installed" -ForegroundColor Green
  Write-Host "       Enables: ADK detection, WiFi drivers, Dell drivers, OSD-in-WIM" -ForegroundColor Gray
}
else {
  Write-Host "  WARN OSD Module: NOT INSTALLED" -ForegroundColor Yellow
  Write-Host "       Install: Install-Module OSD -Force" -ForegroundColor Gray
  Write-Host "       Required for: -UseWinRE, -IncludeWiFi, dynamic Dell drivers, ADK detection" -ForegroundColor Gray
  $warnings += "OSD module not installed (required for WiFi + WinRE mode)"
}

# DISM
$dismPath = Get-Command dism.exe -ErrorAction SilentlyContinue
if ($dismPath) {
  Write-Host "  OK  DISM Tools: Available ($($dismPath.Source))" -ForegroundColor Green
}
else {
  Write-Host "  ERR DISM Tools: Not found (Windows ADK required)" -ForegroundColor Red
  $errors += "DISM not available"
  $allGood = $false
}

# Mount-WindowsImage cmdlet
$mountCmd = Get-Command Mount-WindowsImage -ErrorAction SilentlyContinue
if ($mountCmd) {
  Write-Host "  OK  Mount-WindowsImage: Available" -ForegroundColor Green
}
else {
  Write-Host "  WARN Mount-WindowsImage: Not found (not strictly required)" -ForegroundColor Yellow
  $warnings += "Mount-WindowsImage cmdlet missing"
}

# Windows ADK WinPE add-on
$adkCandidates = @(
  "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment",
  "${env:ProgramFiles(x86)}\Windows Kits\11\Assessment and Deployment Kit\Windows Preinstallation Environment"
)
$adkFound = $adkCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($adkFound) {
  Write-Host "  OK  WinPE Add-on: $adkFound" -ForegroundColor Green
  $adkRoot = Split-Path $adkFound

  # OSCDIMG
  $oscdimgPath = Join-Path $adkRoot "Deployment Tools\AMD64\Oscdimg\oscdimg.exe"
  if (Test-Path $oscdimgPath) {
    Write-Host "  OK  OSCDIMG: Available" -ForegroundColor Green
  }
  else {
    Write-Host "  ERR OSCDIMG: Not found at $oscdimgPath" -ForegroundColor Red
    $errors += "OSCDIMG not found (required for ISO creation)"
    $allGood = $false
  }

  # WinPE OCs folder
  $ocPath = Join-Path $adkFound "amd64\WinPE_OCs"
  if (Test-Path $ocPath) {
    $ocCount = (Get-ChildItem -Path $ocPath -Filter "*.cab" | Measure-Object).Count
    Write-Host "  OK  WinPE OCs: $ocCount packages available" -ForegroundColor Green
  }
  else {
    Write-Host "  ERR WinPE OCs folder not found: $ocPath" -ForegroundColor Red
    $errors += "WinPE optional components missing"
    $allGood = $false
  }
}
elseif ($osdModule) {
  # Use OSD registry-based ADK detection as fallback
  try {
    $adkPaths = Get-WindowsAdkPaths -ErrorAction Stop
    if ($adkPaths -and $adkPaths.WinPEPath -and (Test-Path $adkPaths.WinPEPath)) {
      Write-Host "  OK  WinPE Add-on: $($adkPaths.WinPEPath) (detected via OSD)" -ForegroundColor Green
    }
    else {
      Write-Host "  ERR WinPE Add-on: NOT FOUND (checked registry via OSD)" -ForegroundColor Red
      Write-Host "       Install: https://aka.ms/adk and the WinPE add-on" -ForegroundColor Gray
      $errors += "Windows ADK WinPE add-on not installed"
      $allGood = $false
    }
  }
  catch {
    Write-Host "  ERR WinPE Add-on: NOT FOUND" -ForegroundColor Red
    Write-Host "       Install: https://aka.ms/adk and the WinPE add-on" -ForegroundColor Gray
    $errors += "Windows ADK WinPE add-on not installed"
    $allGood = $false
  }
}
else {
  Write-Host "  ERR WinPE Add-on: NOT FOUND" -ForegroundColor Red
  Write-Host "       Install: https://aka.ms/adk and the WinPE add-on" -ForegroundColor Gray
  $errors += "Windows ADK WinPE add-on not installed"
  $allGood = $false
}

Write-Host ""

# ====================================
# STALE MOUNT CHECK
# ====================================
Write-Host "[4/8] Stale Mount Check" -ForegroundColor Cyan

$staleMounts = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue
if ($staleMounts) {
  foreach ($sm in $staleMounts) {
    Write-Host "  WARN Stale mount: $($sm.Path) -> $($sm.ImagePath)" -ForegroundColor Yellow
    $warnings += "Stale WIM mount at $($sm.Path)"
  }
  Write-Host "       Fix: Dismount-WindowsImage -Path '<path>' -Discard" -ForegroundColor Gray
}
else {
  Write-Host "  OK  No stale mounts detected" -ForegroundColor Green
}

Write-Host ""

# ====================================
# NETWORK & DOWNLOAD URL REACHABILITY
# ====================================
Write-Host "[5/8] Network & Download URLs" -ForegroundColor Cyan

# Basic internet check
try {
  $internet = Test-NetConnection 8.8.8.8 -InformationLevel Quiet -WarningAction SilentlyContinue
  if ($internet) {
    Write-Host "  OK  Internet: Connected" -ForegroundColor Green
  }
  else {
    Write-Host "  WARN Internet: May not be connected" -ForegroundColor Yellow
    $warnings += "Internet connectivity issue"
  }
}
catch {
  Write-Host "  WARN Internet: Could not verify" -ForegroundColor Yellow
  $warnings += "Internet check failed"
}

# Test critical download URLs used by Build-Image.ps1
$urls = @(
  @{ Name = "GitHub (WinXShell, Explorer++, Semeru, Chrome++)"; Url = "https://github.com" },
  @{ Name = "PowerShell Gallery (OSD module)"; Url = "https://www.powershellgallery.com" },
  @{ Name = "okieselbach (WirelessConnect.exe)"; Url = "https://github.com/okieselbach" },
  @{ Name = "Dell Drivers"; Url = "https://downloads.dell.com" },
  @{ Name = "7-Zip"; Url = "https://www.7-zip.org" }
)

foreach ($entry in $urls) {
  try {
    Invoke-WebRequest -Uri $entry.Url -Method Head -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop | Out-Null
    Write-Host "  OK  $($entry.Name): Reachable" -ForegroundColor Green
  }
  catch {
    Write-Host "  WARN $($entry.Name) ($($entry.Url)): NOT reachable" -ForegroundColor Yellow
    $warnings += "$($entry.Name) not reachable"
  }
}

Write-Host ""

# ====================================
# WINRE AVAILABILITY (for -UseWinRE mode)
# ====================================
Write-Host "[6/8] WinRE Availability (-UseWinRE mode)" -ForegroundColor Cyan

$winreFound = $false

try {
  $reagentcOut = & reagentc /info 2>&1
  $reagentcStr = ($reagentcOut -join " ")
  if ($reagentcStr -match "Enabled") {
    Write-Host "  OK  WinRE: Enabled (reagentc /info)" -ForegroundColor Green
    $winreFound = $true

    $winreLocations = @(
      "$env:WINDIR\System32\Recovery\winre.wim",
      "C:\Recovery\WindowsRE\winre.wim"
    )
    $wimPath = $winreLocations | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($wimPath) {
      $wimSizeMB = [math]::Round((Get-Item $wimPath).Length / 1MB,1)
      Write-Host "  OK  winre.wim: $wimPath ($wimSizeMB MB)" -ForegroundColor Green
    }
    else {
      Write-Host "  INFO winre.wim: Not found at default paths" -ForegroundColor Gray
      Write-Host "       Build-Image.ps1 will search via reagentc /info at build time" -ForegroundColor Gray
    }
  }
  elseif ($reagentcStr -match "Disabled") {
    Write-Host "  WARN WinRE: Disabled on this system" -ForegroundColor Yellow
    Write-Host "       To enable: reagentc /enable (may require reboot)" -ForegroundColor Gray
    Write-Host "       NOTE: -UseWinRE mode cannot proceed without an enabled WinRE" -ForegroundColor Gray
    $warnings += "WinRE disabled — run 'reagentc /enable' to use -UseWinRE mode"
  }
  else {
    Write-Host "  INFO WinRE: Status unknown (non-standard reagentc output)" -ForegroundColor Gray
  }
}
catch {
  Write-Host "  WARN reagentc: Not available or failed — cannot verify WinRE state" -ForegroundColor Yellow
  $warnings += "Could not check WinRE availability (reagentc failed)"
}

if (-not $winreFound) {
  Write-Host "  INFO -UseWinRE mode may not be available; use -SourceISO mode as alternative" -ForegroundColor Gray
}

Write-Host ""

# ====================================
# CONFIGURATION PATHS
# ====================================
Write-Host "[7/8] Configuration Paths" -ForegroundColor Cyan

$defaultWorkRoot = "C:\Build"
if (Test-Path $defaultWorkRoot) {
  Write-Host "  INFO WorkRoot: $defaultWorkRoot (exists)" -ForegroundColor Cyan
  $iso = Get-ChildItem "$defaultWorkRoot\Output\*.iso" -ErrorAction SilentlyContinue | Select-Object -Last 1
  if ($iso) {
    $isoSizeGB = $iso.Length / 1GB
    Write-Host "  OK  Last ISO: $($iso.Name) ($([math]::Round($isoSizeGB, 2)) GB)" -ForegroundColor Green
  }
}
else {
  Write-Host "  INFO WorkRoot: $defaultWorkRoot (will be created during build)" -ForegroundColor Gray
}

Write-Host ""

# ====================================
# BUILD-IMAGE.PS1 PARAMETER HINTS
# ====================================
Write-Host "[8/8] Build Script Reminders" -ForegroundColor Cyan

Write-Host "  INFO Two build modes available:" -ForegroundColor Gray
Write-Host "       -UseWinRE  -WorkRoot <path>          (no ISO; WiFi auto-enabled)" -ForegroundColor Cyan
Write-Host "       -SourceISO <path>  -WorkRoot <path>  (traditional ISO-based build)" -ForegroundColor Cyan
Write-Host ""
Write-Host "  INFO OSD module (strongly recommended):" -ForegroundColor Gray
Write-Host "       Install-Module OSD -Force" -ForegroundColor Cyan
Write-Host "       Enables: ADK auto-detection, Intel WiFi drivers, Dell driver catalog," -ForegroundColor Gray
Write-Host "                OSD module in WinPE, Initialize-OSDCloudStartnet WiFi init" -ForegroundColor Gray
Write-Host ""
Write-Host "  INFO WiFi support (-UseWinRE or -IncludeWiFi):" -ForegroundColor Gray
Write-Host "       Injects: Auth DLLs + Intel WinPE driver + WirelessConnect.exe + OSD module" -ForegroundColor Gray
Write-Host "       At boot: SSID selector launches automatically if machine is offline" -ForegroundColor Gray
Write-Host ""
Write-Host "  INFO Chrome++: Use -UseChromePlus AND -ChromeOfflineInstallerPath <path>" -ForegroundColor Gray
Write-Host "       (Chrome++ .7z does NOT include chrome.exe; offline installer required)" -ForegroundColor Gray
Write-Host "  INFO Java: IBM Semeru 8 downloaded; JAVA_HOME and PATH auto-configured" -ForegroundColor Gray
Write-Host ""
Write-Host "  INFO ADK Enhancement (optional, highly recommended for Chrome/Java compatibility):" -ForegroundColor Gray
Write-Host "       ISO mode:   install.wim auto-detected from -SourceISO (no extra param needed)" -ForegroundColor Gray
Write-Host "       WinRE mode: -EnhanceFromISO <windows-iso>  (required to enable enhancement)" -ForegroundColor Gray
Write-Host "       -IncludeWoW64    32-bit subsystem (~150 DLLs; needed for 32-bit apps)" -ForegroundColor Gray
Write-Host "       -IncludeAudio    WASAPI/audiodg audio stack from install.wim" -ForegroundColor Gray
Write-Host "       -IncludeShell    Explorer, DWM, XAML shell components from install.wim" -ForegroundColor Gray
Write-Host "       -ScratchSpaceMB  WinPE scratch RAM (default 512; valid: 32/64/128/256/512)" -ForegroundColor Gray

Write-Host ""

# ====================================
# EXECUTION PERMISSIONS
# ====================================
Write-Host "[Exec Policy]" -ForegroundColor Cyan
$policy = Get-ExecutionPolicy -Scope Process
if ($policy -eq 'Undefined') { $policy = Get-ExecutionPolicy }
if ($policy -in 'Bypass','Unrestricted','RemoteSigned') {
  Write-Host "  OK  Execution Policy: $policy" -ForegroundColor Green
}
elseif ($policy -eq 'AllSigned') {
  Write-Host "  WARN Execution Policy: $policy (scripts must be signed)" -ForegroundColor Yellow
  $warnings += "Execution policy AllSigned — unsigned scripts will be blocked"
}
else {
  Write-Host "  ERR Execution Policy: $policy — will block script execution" -ForegroundColor Red
  Write-Host "       Fix: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser" -ForegroundColor Gray
  $errors += "Execution policy '$policy' will block scripts"
  $allGood = $false
}

Write-Host ""

# ====================================
# SUMMARY
# ====================================
Write-Host "=======================================================" -ForegroundColor Magenta

# Exit non-zero when critical errors were found (usable from CI or Quick-Launch)
if (-not $allGood -or $errors.Count -gt 0) { $script:ExitCode = 1 } else { $script:ExitCode = 0 }

if ($errors.Count -eq 0 -and $warnings.Count -eq 0) {
  Write-Host "" -ForegroundColor Green
  Write-Host "  READY TO BUILD  -  All checks passed" -ForegroundColor Green
  Write-Host "" -ForegroundColor Green
  Write-Host "  WinRE mode (recommended):" -ForegroundColor Green
  Write-Host "    .\Build-Image.ps1 -UseWinRE -WorkRoot D:\Build" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "  Traditional ISO mode:" -ForegroundColor Green
  Write-Host "    .\Build-Image.ps1 -SourceISO C:\Win11.iso -WorkRoot D:\Build" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "  Or use the interactive launcher:" -ForegroundColor Green
  Write-Host "    .\Quick-Launch.ps1" -ForegroundColor Cyan
  Write-Host ""
}
elseif ($errors.Count -eq 0) {
  Write-Host "" -ForegroundColor Yellow
  Write-Host "  WARNINGS DETECTED  -  Build should work but review these:" -ForegroundColor Yellow
  Write-Host ""
  $warnings | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
  Write-Host ""
  Write-Host "  You can proceed:" -ForegroundColor Yellow
  Write-Host "    .\Quick-Launch.ps1                                           (menu)" -ForegroundColor Cyan
  Write-Host "    .\Build-Image.ps1 -UseWinRE -WorkRoot D:\Build               (WinRE mode)" -ForegroundColor Cyan
  Write-Host "    .\Build-Image.ps1 -SourceISO C:\Win11.iso -WorkRoot D:\Build  (ISO mode)" -ForegroundColor Cyan
  Write-Host ""
}
else {
  Write-Host "" -ForegroundColor Red
  Write-Host "  CANNOT BUILD  -  Critical errors found:" -ForegroundColor Red
  Write-Host ""
  $errors | ForEach-Object { Write-Host "    [ERR] $_" -ForegroundColor Red }
  if ($warnings.Count -gt 0) {
    Write-Host ""
    $warnings | ForEach-Object { Write-Host "    [WARN] $_" -ForegroundColor Yellow }
  }
  Write-Host ""
  Write-Host "  Fix these issues first:" -ForegroundColor Red
  Write-Host "    1. Run PowerShell as Administrator" -ForegroundColor Gray
  Write-Host "    2. Ensure Windows 10 or later" -ForegroundColor Gray
  Write-Host "    3. Install Windows ADK + WinPE add-on: https://aka.ms/adk" -ForegroundColor Gray
  Write-Host "    4. Install OSD module: Install-Module OSD -Force" -ForegroundColor Gray
  Write-Host ""
}

Write-Host "=======================================================" -ForegroundColor Magenta
Write-Host ""
exit $script:ExitCode
