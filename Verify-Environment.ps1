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
Write-Host "[1/6] System Requirements" -ForegroundColor Cyan

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
Write-Host "[2/6] Required Scripts" -ForegroundColor Cyan

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
        Write-Host "  ERR $scriptName (NOT FOUND)" -ForegroundColor Red
        $allGood = $false
        $errors += "Missing script: $scriptName"
    }
}

Write-Host ""

# ====================================
# POWERSHELL MODULES & DISM TOOLS
# ====================================
Write-Host "[3/6] PowerShell Modules & DISM" -ForegroundColor Cyan

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
    Write-Host "  WARN Mount-WindowsImage: Not found (not strictly required)" -ForegroundColor Yellow
    $warnings += "Mount-WindowsImage cmdlet missing"
}

Write-Host ""

# ====================================
# STALE MOUNT CHECK
# ====================================
Write-Host "[4/6] Stale Mount Check" -ForegroundColor Cyan

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
Write-Host "[5/6] Network & Download URLs" -ForegroundColor Cyan

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
$urls = @(
    "https://github.com",
    "https://dl.google.com",
    "https://www.7-zip.org"
)

foreach ($url in $urls) {
    try {
        $response = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        Write-Host "  OK  $url: Reachable" -ForegroundColor Green
    }
    catch {
        Write-Host "  WARN $url: NOT reachable" -ForegroundColor Yellow
        $warnings += "$url not reachable"
    }
}

Write-Host ""

# ====================================
# CONFIGURATION PATHS
# ====================================
Write-Host "[6/6] Configuration Paths" -ForegroundColor Cyan

$defaultWorkRoot = "C:\Build"
if (Test-Path $defaultWorkRoot) {
    Write-Host "  INFO WorkRoot: $defaultWorkRoot (exists)" -ForegroundColor Cyan
    $iso = Get-ChildItem "$defaultWorkRoot\Output\*.iso" -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($iso) {
        $isoSizeGB = $iso.Length / 1GB
        Write-Host "  OK  ISO: $($iso.Name) ($([math]::Round($isoSizeGB, 2)) GB)" -ForegroundColor Green
    }
}
else {
    Write-Host "  INFO WorkRoot: $defaultWorkRoot (will be created during build)" -ForegroundColor Gray
}

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
    Write-Host "    .\Build-Image.ps1 -SourceISO <ISO> -WorkRoot <Path>" -ForegroundColor Cyan
    Write-Host ""
}
elseif ($errors.Count -eq 0) {
    Write-Host "" -ForegroundColor Yellow
    Write-Host "  WARNINGS DETECTED  -  Build should work but review these:" -ForegroundColor Yellow
    Write-Host ""
    $warnings | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "  You can proceed:" -ForegroundColor Yellow
    Write-Host "    .\Quick-Launch.ps1  (menu)" -ForegroundColor Cyan
    Write-Host "    .\Build-Image.ps1 -SourceISO <ISO> -WorkRoot <Path>" -ForegroundColor Cyan
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
    Write-Host ""
}

Write-Host "=======================================================" -ForegroundColor Magenta
Write-Host ""