# ====================================
# OSDCloud Clean WinRE - Verification
# Check that everything is ready
# ====================================

#Requires -RunAsAdministrator

Clear-Host

Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║   OSDCloud Clean WinRE - Environment Verification         ║" -ForegroundColor Magenta
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

$allGood = $true
$warnings = @()
$errors = @()

# ====================================
# SYSTEM CHECKS
# ====================================
Write-Host "📋 System Requirements" -ForegroundColor Cyan

# Windows Version
$osVersion = [System.Environment]::OSVersion.Version
if ($osVersion.Major -ge 10) {
    Write-Host "  ✓ Windows Version: $osVersion (OK)" -ForegroundColor Green
}
else {
    Write-Host "  ✗ Windows Version: $osVersion (Requires Windows 10+)" -ForegroundColor Red
    $allGood = $false
    $errors += "Windows version too old"
}

# Administrator Check
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if ($isAdmin) {
    Write-Host "  ✓ Administrator: Yes (OK)" -ForegroundColor Green
}
else {
    Write-Host "  ✗ Administrator: No (REQUIRED)" -ForegroundColor Red
    Write-Host "    Please run PowerShell as Administrator" -ForegroundColor Yellow
    $allGood = $false
    $errors += "Not running as administrator"
}

# PowerShell Version
$psVersion = $PSVersionTable.PSVersion.Major
Write-Host "  ✓ PowerShell: v$psVersion (OK)" -ForegroundColor Green

# Disk Space
$driveLetter = $PSScriptRoot.Substring(0, 1)
$drive = Get-PSDrive $driveLetter -ErrorAction SilentlyContinue
if ($drive) {
    $freeGB = $drive.Free / 1GB
    if ($freeGB -gt 50) {
        Write-Host "  ✓ Free Space: $([math]::Round($freeGB, 1)) GB (OK)" -ForegroundColor Green
    }
    else {
        Write-Host "  ⚠ Free Space: $([math]::Round($freeGB, 1)) GB (Recommended 50GB+)" -ForegroundColor Yellow
        $warnings += "Low disk space"
    }
}

Write-Host ""

# ====================================
# REQUIRED SCRIPTS
# ====================================
Write-Host "📄 Required Scripts" -ForegroundColor Cyan

$scripts = @{
    'Build-OSDCloud-Clean.ps1'    = 'Main build orchestrator'
    'Optimize-WinRE.ps1'          = 'WIM optimization'
    'Quick-Launch.ps1'            = 'Interactive launcher'
}

$missingScripts = @()
foreach ($scriptName in $scripts.Keys) {
    $scriptPath = Join-Path $PSScriptRoot $scriptName
    if (Test-Path $scriptPath) {
        $size = (Get-Item $scriptPath).Length / 1KB
        Write-Host "  ✓ $scriptName ($([math]::Round($size, 1)) KB)" -ForegroundColor Green
    }
    else {
        Write-Host "  ✗ $scriptName (NOT FOUND)" -ForegroundColor Red
        $missingScripts += $scriptName
        $allGood = $false
    }
}

Write-Host ""

# ====================================
# DOCUMENTATION
# ====================================
Write-Host "📚 Documentation" -ForegroundColor Cyan

$docs = @{
    'README.md'        = 'Complete reference'
    'QUICKSTART.md'    = 'Quick start guide'
    'PROJECT-SUMMARY.md' = 'Project overview'
}

$missingDocs = @()
foreach ($docName in $docs.Keys) {
    $docPath = Join-Path $PSScriptRoot $docName
    if (Test-Path $docPath) {
        $size = (Get-Item $docPath).Length / 1KB
        Write-Host "  ✓ $docName ($([math]::Round($size, 1)) KB)" -ForegroundColor Green
    }
    else {
        Write-Host "  ⚠ $docName (NOT FOUND)" -ForegroundColor Yellow
        $missingDocs += $docName
    }
}

Write-Host ""

# ====================================
# POWERSHELL MODULES
# ====================================
Write-Host "🔧 PowerShell Modules" -ForegroundColor Cyan

# Check for OSD Module
$osdModule = Get-Module OSD -ListAvailable -ErrorAction SilentlyContinue
if ($osdModule) {
    $version = $osdModule.Version | Sort-Object -Descending | Select-Object -First 1
    Write-Host "  ✓ OSD Module: v$version (Installed)" -ForegroundColor Green
}
else {
    Write-Host "  ⚠ OSD Module: Not installed" -ForegroundColor Yellow
    Write-Host "    Will be installed automatically during build" -ForegroundColor Gray
    $warnings += "OSD module will be downloaded during build"
}

# Windows PE Tools
$dismPath = Get-Command dism.exe -ErrorAction SilentlyContinue
if ($dismPath) {
    Write-Host "  ✓ DISM Tools: Present (OK)" -ForegroundColor Green
}
else {
    Write-Host "  ⚠ DISM Tools: Not in PATH" -ForegroundColor Yellow
    $warnings += "DISM may need Windows ADK"
}

Write-Host ""

# ====================================
# NETWORK & INTERNET
# ====================================
Write-Host "🌐 Network Connectivity" -ForegroundColor Cyan

try {
    $internet = Test-NetConnection 8.8.8.8 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($internet -or (Test-NetConnection google.com -InformationLevel Quiet -WarningAction SilentlyContinue)) {
        Write-Host "  ✓ Internet: Connected (OK)" -ForegroundColor Green
    }
    else {
        Write-Host "  ⚠ Internet: May not be connected" -ForegroundColor Yellow
        $warnings += "Check internet connection"
    }
}
catch {
    Write-Host "  ⚠ Internet: Check manually" -ForegroundColor Yellow
}

Write-Host ""

# ====================================
# CONFIGURATION
# ====================================
Write-Host "⚙️  Configuration Paths" -ForegroundColor Cyan

$workspacePath = "C:\OSDCloud\LiveWinRE"
if (Test-Path $workspacePath) {
    Write-Host "  ℹ Workspace: $workspacePath (exists)" -ForegroundColor Cyan
}
else {
    Write-Host "  ℹ Workspace: $workspacePath (will be created)" -ForegroundColor Cyan
}

$tempPath = "C:\Mount"
Write-Host "  ℹ Mount Point: $tempPath (will be created)" -ForegroundColor Cyan

$buildPath = "C:\BuildPayload"
Write-Host "  ℹ Build Payload: $buildPath (will be created)" -ForegroundColor Cyan

Write-Host ""

# ====================================
# EXECUTION PERMISSIONS
# ====================================
Write-Host "🔐 Script Execution Policy" -ForegroundColor Cyan

$policy = Get-ExecutionPolicy
if ($policy -in 'Bypass', 'Unrestricted', 'RemoteSigned') {
    Write-Host "  ✓ Current: $policy (OK)" -ForegroundColor Green
}
else {
    Write-Host "  ⚠ Current: $policy (May need to set to RemoteSigned)" -ForegroundColor Yellow
    Write-Host "    Run: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser" -ForegroundColor Gray
}

Write-Host ""

# ====================================
# SUMMARY
# ====================================
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Magenta

if ($errors.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host "✅ READY TO BUILD" -ForegroundColor Green
    Write-Host ""
    Write-Host "All systems are go! You can now run:" -ForegroundColor Green
    Write-Host ""
    Write-Host "  .\Quick-Launch.ps1      (Interactive menu)" -ForegroundColor Cyan
    Write-Host "  .\Build-OSDCloud-Clean.ps1 -Mode Full  (Direct build)" -ForegroundColor Cyan
    Write-Host ""
}
elseif ($errors.Count -eq 0) {
    Write-Host "⚠️  WARNINGS DETECTED" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Issues to review:" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Host "  • $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "You can proceed, but review warnings first:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  .\Quick-Launch.ps1" -ForegroundColor Cyan
    Write-Host ""
}
else {
    Write-Host "❌ CANNOT BUILD" -ForegroundColor Red
    Write-Host ""
    Write-Host "Critical errors found:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  • $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Please fix these issues before building:" -ForegroundColor Red
    Write-Host "  1. Run PowerShell As Administrator" -ForegroundColor Gray
    Write-Host "  2. Ensure Windows 10 or later" -ForegroundColor Gray
    Write-Host "  3. Verify required scripts exist" -ForegroundColor Gray
    Write-Host ""
}

Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host ""

# ====================================
# QUICK REFERENCE
# ====================================
Write-Host "📖 Quick Reference" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Full Build:              .\Build-OSDCloud-Clean.ps1 -Mode Full" -ForegroundColor Cyan
Write-Host "  Interactive Menu:        .\Quick-Launch.ps1" -ForegroundColor Cyan
Write-Host "  Optimize Size:           .\Optimize-WinRE.ps1 -Operation OptimizeAll" -ForegroundColor Cyan
Write-Host "  Quick Start Guide:       .\QUICKSTART.md" -ForegroundColor Cyan
Write-Host "  Full Documentation:      .\README.md" -ForegroundColor Cyan
Write-Host ""

Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Magenta
