# ====================================
# OSDCloud Clean WinRE LiveBoot Builder
# GUI + Java + Chrome
# No Scoop Dependencies
# ====================================

param(
    [ValidateSet('BuildWinRE', 'BuildISO', 'Full')]
    [string]$Mode = 'Full',
    
    [string]$Workspace = "C:\OSDCloud\LiveWinRE",
    [string]$Mount = "C:\Mount",
    [string]$BuildPayload = "C:\BuildPayload",
    [string]$IsoName = "OSDCloud-LiveWinRE-Clean"
)

#Requires -RunAsAdministrator

# ====================================
# CONFIGURATION
# ====================================
$config = @{
    JavaUrl         = "https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.21%2B9/OpenJDK11U-jre_x64_windows_hotspot_11.0.21_9.zip"
    ChromeUrl       = "https://dl.google.com/chrome/install/googlechromestandaloneenterprise64.msi"
    # WinXShell vendored directly from wimbuilder2 repo - no .NET required, purpose-built for WinPE
    WinXShellBase   = "https://raw.githubusercontent.com/slorelee/wimbuilder2/master/vendor/WinXShell/X_PF/WinXShell"
    PowerShellUrl   = "https://github.com/PowerShell/PowerShell/releases/download/v7.4.1/PowerShell-7.4.1-win-x64.zip"
    SevenZipUrl     = "https://www.7-zip.org/a/7z2301-x64.msi"
    Version         = "1.0.0"
    BuildDate       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
}

# ====================================
# FUNCTIONS
# ====================================
function Write-Status {
    param([string]$Message, [ValidateSet('Info', 'Success', 'Warning', 'Error')]$Type = 'Info')
    $colors = @{ Info = 'Cyan'; Success = 'Green'; Warning = 'Yellow'; Error = 'Red' }
    Write-Host "[$Type] $Message" -ForegroundColor $colors[$Type]
}

function Invoke-Download {
    param([string]$Url, [string]$OutFile, [string]$DisplayName)
    try {
        Write-Status "Downloading $DisplayName..." -Type Info
        if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
        
        # Use TLS 1.2
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
        
        if (Test-Path $OutFile) {
            $size = (Get-Item $OutFile).Length / 1MB
            Write-Status "Downloaded: $(Split-Path $OutFile -Leaf) ($([math]::Round($size, 2)) MB)" -Type Success
            return $true
        }
        else {
            Write-Status "Download failed: $DisplayName" -Type Error
            return $false
        }
    }
    catch {
        Write-Status "Error downloading $DisplayName : $_" -Type Error
        return $false
    }
}

function New-LauncherScript {
    param([string]$Path, [string]$Name, [string]$Target, [string]$Arguments = "")
    
    $content = @"
# Launcher for $Name
`$env:Path = "X:\Tools\bin;X:\Tools\jre\bin;X:\Tools\pwsh;" + `$env:Path

& "$Target" $Arguments
"@
    
    Set-Content -Path $Path -Value $content -Encoding UTF8
    Write-Status "Created launcher: $Name"
}

# ====================================
# CLEANUP & PREP
# ====================================
function Initialize-BuildEnvironment {
    Write-Status "=== Initializing Build Environment ===" -Type Info
    
    # Clean previous builds
    if (Test-Path $Mount) {
        Write-Status "Dismounting previous WIM..." -Type Warning
        Dismount-WindowsImage -Path $Mount -Discard -ErrorAction SilentlyContinue
        Remove-Item $Mount -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    @($Workspace, $Mount, $BuildPayload) | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item $_ -ItemType Directory -Force | Out-Null }
    }
    
    Write-Status "Build environment ready" -Type Success
}

# ====================================
# STEP 1: PREP OSDCLOUD
# ====================================
function Invoke-OSDCloudSetup {
    Write-Status "=== Setting up OSD Cloud Template ===" -Type Info
    
    # Install OSD Module
    if (-not (Get-Module OSD -ListAvailable)) {
        Write-Status "Installing OSD PowerShell Module..." -Type Info
        Install-Module OSD -Force -Scope CurrentUser
    }
    
    Import-Module OSD -Force
    
    # Create WinRE Template
    if (-not (Test-Path "$Workspace\Media")) {
        Write-Status "Creating OSD WinRE template..." -Type Info
        New-OSDCloudTemplate -Name LiveWinRE -WinRE
        Set-OSDCloudWorkspace $Workspace
    }
    else {
        Write-Status "OSD template exists, using existing..." -Type Warning
    }
    
    # Enhance WinPE
    Write-Status "Enhancing WinPE with drivers and network..." -Type Info
    Edit-OSDCloudWinPE `
        -CloudDriver * `
        -WirelessConnect `
        -StartOSDCloudGUI
    
    Write-Status "OSD Cloud setup complete" -Type Success
}

# ====================================
# STEP 2: DOWNLOAD & PREPARE APPLICATIONS
# ====================================
function Invoke-ApplicationPrep {
    Write-Status "=== Preparing Applications ===" -Type Info
    
    # Create temp folder for downloads
    $downloads = "$BuildPayload\downloads"
    if (Test-Path $downloads) { Remove-Item $downloads -Recurse -Force }
    New-Item $downloads -ItemType Directory -Force | Out-Null
    
    # Define apps to download
    $apps = @{
        'java'   = @{ url = $config.JavaUrl; file = 'openjdk-jre.zip'; unzip = $true }
        'chrome' = @{ url = $config.ChromeUrl; file = 'chrome-install.msi'; unzip = $false }
        'pwsh'   = @{ url = $config.PowerShellUrl; file = 'pwsh.zip'; unzip = $true }
        '7zip'   = @{ url = $config.SevenZipUrl; file = '7zip-install.msi'; unzip = $false }
    }
    
    $tools = "$BuildPayload\tools"
    New-Item $tools -ItemType Directory -Force | Out-Null
    
    # Download each app
    foreach ($app in $apps.GetEnumerator()) {
        $appName = $app.Key
        $appConfig = $app.Value
        $downloadPath = Join-Path $downloads $appConfig.file
        
        if (Invoke-Download -Url $appConfig.url -OutFile $downloadPath -DisplayName $appName) {
            if ($appConfig.unzip) {
                Write-Status "Extracting $appName..." -Type Info
                $appDir = Join-Path $tools $appName
                New-Item $appDir -ItemType Directory -Force | Out-Null
                
                Expand-Archive -Path $downloadPath -DestinationPath $appDir -Force
                Write-Status "Extracted $appName to $appDir" -Type Success
            }
            else {
                Copy-Item $downloadPath "$tools\$(Split-Path $downloadPath -Leaf)" -Force
                Write-Status "Copied $appName installer" -Type Success
            }
        }
    }
    
    # Download WinXShell individual binaries from wimbuilder2 vendor
    # (no .NET required - purpose-built for WinPE, Lua-scripted shell)
    Write-Status "Downloading WinXShell (WinPE-native shell)..." -Type Info
    $wxsDir = "$tools\winxshell"
    New-Item $wxsDir -ItemType Directory -Force | Out-Null
    $wxsBase = $config.WinXShellBase
    $wxsFiles = @(
        "WinXShell_x64.exe",
        "WinXShellC_x64.exe",
        "WinXShell.lua",
        "WinXShell.zh-CN.cfg",
        "wxsStub.dll",
        "wxsStub32.dll",
        "wallpaper.jpg"
    )
    $wxsOk = $true
    foreach ($wxsFile in $wxsFiles) {
        $wxsDest = Join-Path $wxsDir $wxsFile
        if (-not (Invoke-Download -Url "$wxsBase/$wxsFile" -OutFile $wxsDest -DisplayName "WinXShell/$wxsFile")) {
            $wxsOk = $false
        }
    }
    # Download wxsUI subfolder (taskbar/tray UI components)
    $wxsUIDir = "$wxsDir\wxsUI"
    New-Item $wxsUIDir -ItemType Directory -Force | Out-Null
    $wxsUIFiles = @("UI_WIFI", "UI_Volume", "UI_Taskbar", "UI_StartMenu")
    foreach ($uiComp in $wxsUIFiles) {
        $uiDest = "$wxsUIDir\$uiComp"
        New-Item $uiDest -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if ($wxsOk) {
        Write-Status "WinXShell downloaded successfully" -Type Success
    } else {
        Write-Status "Some WinXShell files failed - shell may be incomplete" -Type Warning
    }
    
    # Create bin directory for executables
    New-Item "$tools\bin" -ItemType Directory -Force | Out-Null
    
    Write-Status "Application preparation complete" -Type Success
}

# ====================================
# STEP 3: MOUNT & CUSTOMIZE WINRE
# ====================================
function Invoke-WinRECustomization {
    Write-Status "=== Mounting and Customizing WinRE ===" -Type Info
    
    $bootWim = "$Workspace\Media\sources\boot.wim"
    
    if (-not (Test-Path $bootWim)) {
        Write-Status "boot.wim not found at $bootWim" -Type Error
        return $false
    }
    
    # Mount WIM
    Write-Status "Mounting boot.wim..." -Type Info
    New-Item $Mount -ItemType Directory -Force | Out-Null
    
    Mount-WindowsImage -ImagePath $bootWim -Index 1 -Path $Mount
    
    # Copy tools
    Write-Status "Copying tools to WinRE..." -Type Info
    $toolsMount = "$Mount\Tools"
    Copy-Item "$BuildPayload\tools" -Destination $toolsMount -Recurse -Force
    
    # Create Tools directory structure
    New-Item "$Mount\Tools\bin" -ItemType Directory -Force | Out-Null
    New-Item "$Mount\Tools\scripts" -ItemType Directory -Force | Out-Null
    
    # Configure Registry for Java
    Write-Status "Configuring Java environment..." -Type Info
    
    $systemReg = "$Mount\Windows\System32\Config\SYSTEM"
    $softwareReg = "$Mount\Windows\System32\Config\SOFTWARE"
    
    # Load SYSTEM hive
    reg load HKLM\WinRE $systemReg 2>$null
    
    # Set JAVA_HOME
    reg add "HKLM\WinRE\ControlSet001\Control\Session Manager\Environment" `
        /v JAVA_HOME /t REG_SZ /d "X:\Tools\java" /f 2>$null
    
    # Set PATH - include all tools including WinXShell
    reg add "HKLM\WinRE\ControlSet001\Control\Session Manager\Environment" `
        /v PATH /t REG_EXPAND_SZ `
        /d "X:\Tools\bin;X:\Tools\java\bin;X:\Tools\pwsh;X:\Tools\winxshell;%PATH%" /f 2>$null
    
    reg unload HKLM\WinRE 2>$null
    
    # Load SOFTWARE hive
    reg load HKLM\WinRESW $softwareReg 2>$null
    
    # Register .JAR files
    reg add "HKLM\WinRESW\Classes\.jar" /ve /t REG_SZ /d "jarfile" /f 2>$null
    reg add "HKLM\WinRESW\Classes\jarfile\shell\open\command" `
        /ve /t REG_SZ /d "\"X:\Tools\java\bin\javaw.exe\" -jar \"%%1\"" /f 2>$null
    
    # Set WinXShell as the Windows shell (Winlogon method - same as wimbuilder2/EdgelessPE)
    # More reliable than winpeshl.ini; survives OSD module modifications to startnet.cmd
    reg add "HKLM\WinRESW\Microsoft\Windows NT\CurrentVersion\Winlogon" `
        /v Shell /t REG_SZ /d "X:\Tools\winxshell\WinXShell_x64.exe" /f 2>$null
    
    reg unload HKLM\WinRESW 2>$null
    
    Write-Status "Registry configuration complete" -Type Success
}

# ====================================
# STEP 4: CREATE LAUNCHER SCRIPTS
# ====================================
function Invoke-LauncherSetup {
    Write-Status "=== Creating Launcher Scripts ===" -Type Info
    
    $scriptsDir = "$Mount\Tools\scripts"
    
    # Mode Selector Script - runs at boot BEFORE WinXShell takes over as shell
    # WinXShell is set as Winlogon\Shell, so this script is launched via startnet.cmd
    # to give the user a choice: OSD Deploy (exits to WinXShell after) or pure Desktop
    $modeSelector = @'
# LiveWinRE Mode Selector
# Launched from startnet.cmd before WinXShell shell starts
Add-Type -AssemblyName PresentationFramework

$result = [System.Windows.MessageBox]::Show(
    "Select Operating Mode:`n`nYes = OSD Deploy (automated deployment)`nNo = Desktop Mode (WinXShell GUI)",
    "LiveWinRE LiveBoot",
    "YesNo",
    "Question"
)

if ($result -eq "Yes") {
    # Launch OSD deployment GUI - WinXShell will still start as shell after
    Import-Module OSD -Force -ErrorAction SilentlyContinue
    Start-OSDCloudGUI
}
# Either way, WinXShell_x64.exe starts as shell via Winlogon\Shell registry key
'@
    Set-Content -Path "$scriptsDir\ModeSelector.ps1" -Value $modeSelector -Encoding UTF8
    
    # Desktop shortcut for OSD Deploy
    Write-Status "Creating shortcuts..." -Type Info
    
    New-Item "$Mount\Users\Default\Desktop" -ItemType Directory -Force | Out-Null
    
    $wsh = New-Object -ComObject WScript.Shell
    
    # OSD Deploy Shortcut
    $osdShortcut = $wsh.CreateShortcut("$Mount\Users\Default\Desktop\OSD Deploy.lnk")
    $osdShortcut.TargetPath = "X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    $osdShortcut.Arguments = "-ExecutionPolicy Bypass -NoExit -Command Start-OSDCloudGUI"
    $osdShortcut.WorkingDirectory = "X:\Windows\System32"
    $osdShortcut.Save()
    
    # Chrome Shortcut
    $chromeShortcut = $wsh.CreateShortcut("$Mount\Users\Default\Desktop\Chrome Browser.lnk")
    $chromeShortcut.TargetPath = "X:\Tools\chrome\chrome.exe"
    $chromeShortcut.Save()
    
    # PowerShell Shortcut
    $pwshShortcut = $wsh.CreateShortcut("$Mount\Users\Default\Desktop\PowerShell.lnk")
    $pwshShortcut.TargetPath = "X:\Tools\pwsh\pwsh.exe"
    $pwshShortcut.Save()
    
    # File Manager Shortcut
    $fileShortcut = $wsh.CreateShortcut("$Mount\Users\Default\Desktop\File Explorer.lnk")
    $fileShortcut.TargetPath = "X:\Windows\explorer.exe"
    $fileShortcut.Save()
    
    Write-Status "Launcher setup complete" -Type Success
}

# ====================================
# STEP 5: CONFIGURE WINPE SHELL
# ====================================
function Invoke-WinPEShellConfig {
    Write-Status "=== Configuring WinPE Shell ===" -Type Info
    
    # Strategy (same as wimbuilder2/EdgelessPE):
    # 1. Winlogon\Shell = WinXShell_x64.exe  (set in registry during Invoke-WinRECustomization)
    # 2. startnet.cmd runs ModeSelector.ps1 FIRST (before shell loads)
    # 3. WinXShell then starts as the desktop shell automatically
    # This avoids winpeshl.ini conflicts with OSD module
    
    $startnetPath = "$Mount\Windows\System32\startnet.cmd"
    $startnet = @"
@echo off
wpeinit
rem === LiveWinRE Boot Sequence ===
rem Run mode selector (OSD Deploy vs Desktop) before shell starts
X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NonInteractive -File X:\Tools\scripts\ModeSelector.ps1
rem WinXShell starts automatically as shell via Winlogon registry
"@
    Set-Content -Path $startnetPath -Value $startnet -Encoding ASCII
    
    # Remove winpeshl.ini so WinPE uses standard Winlogon shell loading
    Remove-Item "$Mount\Windows\System32\winpeshl.ini" -Force -ErrorAction SilentlyContinue
    
    Write-Status "WinPE shell configured (WinXShell via Winlogon + startnet.cmd)" -Type Success
}

# ====================================
# STEP 6: COMMIT CHANGES
# ====================================
function Invoke-WinRECommit {
    Write-Status "=== Committing WinRE Changes ===" -Type Info
    
    Dismount-WindowsImage -Path $Mount -Save
    Write-Status "WinRE image committed" -Type Success
    
    # Clean mount directory
    Remove-Item $Mount -Recurse -Force -ErrorAction SilentlyContinue
}

# ====================================
# STEP 7: BUILD ISO
# ====================================
function Invoke-ISOBuild {
    Write-Status "=== Building ISO Image ===" -Type Info
    
    Import-Module OSD -Force
    
    New-OSDCloudISO -WorkspacePath $Workspace
    
    $isoPath = Get-ChildItem "$Workspace\*.iso" -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($isoPath) {
        $sizeGB = $isoPath.Length / 1GB
        Write-Status "ISO created: $($isoPath.FullName) ($([math]::Round($sizeGB, 2)) GB)" -Type Success
    }
}



# ====================================
# MAIN EXECUTION
# ====================================
function Invoke-Main {
    Write-Host "`n"
    Write-Status "=== OSDCloud Clean WinRE Builder ===" -Type Info
    Write-Status "Mode: $Mode | Version: $($config.Version) | Build: $($config.BuildDate)" -Type Info
    Write-Host "`n"
    
    # Step 0: Initialize
    if ($Mode -in 'BuildWinRE', 'Full') {
        Initialize-BuildEnvironment
    }
    
    # Step 1: OSD Setup
    if ($Mode -in 'BuildWinRE', 'Full') {
        Invoke-OSDCloudSetup
    }
    
    # Step 2: Download Apps
    if ($Mode -in 'BuildWinRE', 'Full') {
        Invoke-ApplicationPrep
    }
    
    # Step 3: Mount & Customize
    if ($Mode -in 'BuildWinRE', 'Full') {
        Invoke-WinRECustomization
        Invoke-LauncherSetup
        Invoke-WinPEShellConfig
        Invoke-WinRECommit
    }
    
    # Step 4: Build ISO
    if ($Mode -in 'BuildISO', 'Full') {
        Invoke-ISOBuild
    }
    

    
    Write-Host "`n"
    Write-Status "=== Build Complete ===" -Type Success
    Write-Status "Workspace: $Workspace" -Type Info
    
    if (Test-Path "$Workspace\*.iso") {
        $iso = Get-ChildItem "$Workspace\*.iso" | Select-Object -Last 1
        Write-Status "ISO Location: $($iso.FullName)" -Type Info
    }
    
    Write-Host "`n"
}

# Execute
Invoke-Main
