# ====================================
# OSDCloud Clean WinRE - Verification
# Pre-flight checks for build readiness
# ====================================

#Requires -RunAsAdministrator

Clear-Host

Write-Host "=======================================================" -ForegroundColor Magenta
Write-Host "  OSDCloud Clean WinRE - Environment Verification  v2.0" -ForegroundColor Magenta
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
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
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

$scripts = @{
    'Build-OSDCloud-Clean.ps1' = 'Main build orchestrator'
    'Optimize-WinRE.ps1'       = 'WIM optimization'
    'Quick-Launch.ps1'         = 'Interactive launcher'
}

foreach ($scriptName in $scripts.Keys) {
    $scriptPath = Join-Path $scriptDir $scriptName
    if (Test-Path $scriptPath) {
        $size = (Get-Item $scriptPath).Length / 1KB
        Write-Host "  OK  $scriptName ($([math]::Round($size, 1)) KB)" -ForegroundColor Green
    }
    else {
        Write-Host "  ERR $scriptName (NOT FOUND)" -ForegroundColor Red
        $allGood = $false
        $errors += "Missing script: $scriptName"
    }
}

Write-Host ""

# ====================================
# DOCUMENTATION
# ====================================
Write-Host "[3/8] Documentation" -ForegroundColor Cyan

$docs = @('README.md', 'QUICKSTART.md', 'PROJECT-SUMMARY.md', 'START-HERE.md')
$missingDocs = @()
foreach ($docName in $docs) {
    $docPath = Join-Path $scriptDir $docName
    if (Test-Path $docPath) {
        Write-Host "  OK  $docName" -ForegroundColor Green
    }
    else {
        Write-Host "  WARN $docName (not found)" -ForegroundColor Yellow
        $missingDocs += $docName
    }
}
if ($missingDocs.Count -gt 0) {
    $warnings += "Missing docs: $($missingDocs -join ', ')"
}

Write-Host ""

# ====================================
# POWERSHELL MODULES & DISM TOOLS
# ====================================
Write-Host "[4/8] PowerShell Modules & DISM" -ForegroundColor Cyan

# OSD Module
$osdModule = Get-Module OSD -ListAvailable -ErrorAction SilentlyContinue
if ($osdModule) {
    $version = $osdModule.Version | Sort-Object -Descending | Select-Object -First 1
    Write-Host "  OK  OSD Module: v$version" -ForegroundColor Green
}
else {
    Write-Host "  WARN OSD Module: Not installed (will be downloaded during build)" -ForegroundColor Yellow
    $warnings += "OSD module will be downloaded during build"
}

# DISM
$dismPath = Get-Command dism.exe -ErrorAction SilentlyContinue
if ($dismPath) {
    Write-Host "  OK  DISM Tools: Available" -ForegroundColor Green
}
else {
    Write-Host "  ERR DISM Tools: Not found (Windows ADK may be needed)" -ForegroundColor Red
    $errors += "DISM not available"
    $allGood = $false
}

# Mount-WindowsImage cmdlet
$mountCmd = Get-Command Mount-WindowsImage -ErrorAction SilentlyContinue
if ($mountCmd) {
    Write-Host "  OK  Mount-WindowsImage: Available" -ForegroundColor Green
}
else {
    Write-Host "  ERR Mount-WindowsImage: Not found" -ForegroundColor Red
    $errors += "Mount-WindowsImage cmdlet missing"
    $allGood = $false
}

Write-Host ""

# ====================================
# STALE MOUNT CHECK
# ====================================
Write-Host "[5/8] Stale Mount Check" -ForegroundColor Cyan

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
Write-Host "[6/8] Network & Download URLs" -ForegroundColor Cyan

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

# Test critical download URLs
$urls = @{
    'GitHub (Java/PS7)' = "https://github.com"
    'Google (Chrome)'   = "https://dl.google.com"
    '7-Zip.org'         = "https://www.7-zip.org"
    'GitHub Raw (WinXShell)' = "https://raw.githubusercontent.com"
}

foreach ($entry in $urls.GetEnumerator()) {
    try {
        $response = Invoke-WebRequest -Uri $entry.Value -Method Head -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        Write-Host "  OK  $($entry.Key): Reachable" -ForegroundColor Green
    }
    catch {
        Write-Host "  WARN $($entry.Key): NOT reachable" -ForegroundColor Yellow
        $warnings += "$($entry.Key) not reachable"
    }
}

Write-Host ""

# ====================================
# WINPE COMPATIBILITY VALIDATION
# ====================================
Write-Host "[7/8] WinPE Compatibility Check" -ForegroundColor Cyan

# Verify build script doesn't use MSI / WPF (sanity check)
$buildScript = Join-Path $scriptDir "Build-OSDCloud-Clean.ps1"
if (Test-Path $buildScript) {
    $allLines = Get-Content $buildScript

    # Strip comment-only lines before scanning — prevents false positives from
    # comments like "# NO .msi" or "# PresentationFramework not available in WinPE"
    $codeLines   = $allLines | Where-Object { $_ -notmatch '^\s*#' }
    $codeContent = $codeLines -join "`n"

    # .msi check on code lines only
    if ($codeContent -match '\.msi') {
        Write-Host "  ERR Build script still references .msi files!" -ForegroundColor Red
        Write-Host "       WinPE has no msiexec.exe — only portable/zip downloads work" -ForegroundColor Yellow
        $errors += "Build script uses .msi downloads (incompatible with WinPE)"
        $allGood = $false
    }
    else {
        Write-Host "  OK  No .msi references in build script (portable-only)" -ForegroundColor Green
    }

    # WinXShell wxsUI check on full content — these are string literals we want to confirm exist
    if (($allLines -match 'UI_TrayPanel\.zip') -and ($allLines -match 'UI_WIFI\.zip') -and ($allLines -match 'UI_Volume\.zip')) {
        Write-Host "  OK  WinXShell wxsUI components configured" -ForegroundColor Green
    }
    else {
        Write-Host "  WARN WinXShell may be missing wxsUI panel components" -ForegroundColor Yellow
        $warnings += "WinXShell wxsUI zips may not be downloaded"
    }

    # WPF check on code lines only
    if ($codeContent -match 'PresentationFramework') {
        Write-Host "  ERR Build script uses WPF (PresentationFramework) — not available in WinPE" -ForegroundColor Red
        $errors += "WPF dependency detected — will crash in WinPE"
        $allGood = $false
    }
    else {
        Write-Host "  OK  No WPF dependencies (WinPE-safe)" -ForegroundColor Green
    }
}
else {
    Write-Host "  ERR Build script not found for validation" -ForegroundColor Red
}

Write-Host ""

# ====================================
# CONFIGURATION PATHS
# ====================================
Write-Host "[8/8] Configuration Paths" -ForegroundColor Cyan

$workspacePath = "C:\OSDCloud\LiveWinRE"
if (Test-Path $workspacePath) {
    Write-Host "  INFO Workspace: $workspacePath (exists)" -ForegroundColor Cyan

    $wim = "$workspacePath\Media\sources\boot.wim"
    if (Test-Path $wim) {
        $wimSizeMB = (Get-Item $wim).Length / 1MB
        Write-Host "  OK  boot.wim: $([math]::Round($wimSizeMB, 1)) MB" -ForegroundColor Green
    }
    else {
        Write-Host "  INFO boot.wim: Not yet created (will be created during build)" -ForegroundColor Gray
    }

    $iso = Get-ChildItem "$workspacePath\*.iso" -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($iso) {
        $isoSizeGB = $iso.Length / 1GB
        Write-Host "  OK  ISO: $($iso.Name) ($([math]::Round($isoSizeGB, 2)) GB)" -ForegroundColor Green
    }
}
else {
    Write-Host "  INFO Workspace: $workspacePath (will be created during build)" -ForegroundColor Gray
}

$tempPath = "C:\Mount"
Write-Host "  INFO Mount Point: $tempPath" -ForegroundColor Gray

$buildPath = "C:\BuildPayload"
Write-Host "  INFO Build Payload: $buildPath" -ForegroundColor Gray

Write-Host ""

# ====================================
# EXECUTION PERMISSIONS
# ====================================
Write-Host "[Exec Policy]" -ForegroundColor Cyan
$policy = Get-ExecutionPolicy -Scope Process
if ($policy -eq 'Undefined') { $policy = Get-ExecutionPolicy }
if ($policy -in 'Bypass', 'Unrestricted', 'RemoteSigned') {
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

if ($errors.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host "" -ForegroundColor Green
    Write-Host "  READY TO BUILD  -  All checks passed" -ForegroundColor Green
    Write-Host "" -ForegroundColor Green
    Write-Host "  Run:" -ForegroundColor Green
    Write-Host "    .\Quick-Launch.ps1                         (Interactive menu)" -ForegroundColor Cyan
    Write-Host "    .\Build-OSDCloud-Clean.ps1 -Mode Full      (Direct build)" -ForegroundColor Cyan
    Write-Host ""
}
elseif ($errors.Count -eq 0) {
    Write-Host "" -ForegroundColor Yellow
    Write-Host "  WARNINGS DETECTED  -  Build should work but review these:" -ForegroundColor Yellow
    Write-Host ""
    $warnings | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "  You can proceed:" -ForegroundColor Yellow
    Write-Host "    .\Quick-Launch.ps1" -ForegroundColor Cyan
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
    Write-Host "    3. Verify all required scripts exist" -ForegroundColor Gray
    Write-Host "    4. Ensure no .msi references in build script" -ForegroundColor Gray
    Write-Host ""
}

Write-Host "=======================================================" -ForegroundColor Magenta
Write-Host ""
