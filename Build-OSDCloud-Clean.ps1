# ====================================
# OSDCloud Clean WinRE LiveBoot Builder
# GUI + Java 8 (IBM Semeru) + Chrome + PowerShell 7
# Portable-Only — No MSI / No Scoop
# ====================================
# Inspired by PhoenixPE (https://github.com/PhoenixPE/PhoenixPE)
# Shell: WinXShell from wimbuilder2 (https://github.com/slorelee/wimbuilder2)

param(
    [ValidateSet('BuildWinRE', 'BuildISO', 'Full')]
    [string]$Mode = 'Full',

    [string]$Workspace = "C:\OSDCloud\LiveWinRE",
    [string]$Mount = "C:\Mount",
    [string]$BuildPayload = "C:\BuildPayload",
    [string]$IsoName = "OSDCloud-LiveWinRE-Clean",

    # Optional: path to a folder of .inf drivers to inject into the WinPE image.
    # Place any .inf-based driver (with its .sys/.cat files) under this folder.
    # Sub-folders are supported — all drivers are injected recursively.
    # Leave empty to skip driver injection.
    [string]$DriversPath = "$PSScriptRoot\Drivers",

    # Optional: path to a custom wallpaper image (JPG/PNG/BMP) to use as the desktop
    # background inside the WinPE/WinRE environment (WinXShell desktop).
    # If not specified the default WinXShell wallpaper.jpg is used.
    # Example: -WallpaperPath "C:\Images\corp-wallpaper.jpg"
    [string]$WallpaperPath = ""
)

#Requires -RunAsAdministrator

# ====================================
# CONFIGURATION
# ====================================
$config = @{
    # --- Portable downloads only (NO .msi — WinPE has no msiexec) ---

    # IBM Semeru Runtime Open Edition — Java 8 JRE portable zip (OpenJ9 JVM — lighter footprint than HotSpot)
    # Releases: https://github.com/ibm-semeru-runtimes/open-jdk8u-releases/releases
    # TODO: bump JavaUrl + JavaSemeruVersion when a newer IBM Semeru 8 release ships
    JavaSemeruVersion = "8.0.422.5"
    JavaUrl         = "https://github.com/ibm-semeru-runtimes/open-jdk8u-releases/releases/download/jdk8u422-b05/ibm-semeru-open-jre_x64_windows_8.0.422.5_openj9-0.46.0.zip"

    # Chrome: download the uncompressed installer exe (self-extracting archive)
    # PhoenixPE approach: extract Chrome-bin from the installer exe using 7-Zip
    ChromeUrl       = "https://dl.google.com/release2/chrome/mnpsb6lkzuvjrtl77fwf3ttai4_143.0.7499.110/143.0.7499.110_chrome_installer_uncompressed.exe"

    # 7-Zip: portable extra (standalone 7za.exe, NO msi)
    SevenZipUrl     = "https://www.7-zip.org/a/7z2301-extra.7z"
    # 7-Zip full portable ZIP (used to bootstrap extraction — standard zip, no 7z needed)
    SevenZipBootUrl = "https://www.7-zip.org/a/7zr.exe"

    # PowerShell 7 portable zip
    PowerShellUrl   = "https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.zip"

    # WinXShell: purpose-built WinPE shell (Lua-scripted, no .NET required)
    # Source: wimbuilder2 vendor directory — PINNED to commit fc0c932 (2026-01-02)
    # To upgrade: check https://github.com/slorelee/wimbuilder2/commits/master/vendor/WinXShell
    # then update both the SHA below and the comment above.
    WinXShellBase   = "https://raw.githubusercontent.com/slorelee/wimbuilder2/fc0c93297429800086736c145936a66b657dfdf2/vendor/WinXShell/X_PF/WinXShell"

    Version         = "2.0.0"
    BuildDate       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Retry settings for downloads
    MaxRetries      = 3
    RetryDelaySec   = 5
}

# ====================================
# HELPER FUNCTIONS
# ====================================
function Write-Status {
    param([string]$Message, [ValidateSet('Info', 'Success', 'Warning', 'Error')]$Type = 'Info')
    $colors = @{ Info = 'Cyan'; Success = 'Green'; Warning = 'Yellow'; Error = 'Red' }
    $prefix = @{ Info = '[INFO]'; Success = '[OK]'; Warning = '[WARN]'; Error = '[ERR]' }
    Write-Host "$($prefix[$Type]) $Message" -ForegroundColor $colors[$Type]
}

function Invoke-Download {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$DisplayName,
        [int]$MaxRetries = $config.MaxRetries,
        [int]$RetryDelaySec = $config.RetryDelaySec
    )

    # Ensure TLS 1.2+
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            Write-Status "Downloading $DisplayName (attempt $attempt/$MaxRetries)..." -Type Info
            if (Test-Path $OutFile) { Remove-Item $OutFile -Force }

            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 300

            if (Test-Path $OutFile) {
                $bytes = (Get-Item $OutFile).Length
                if ($bytes -eq 0) {
                    Write-Status "Downloaded file is empty (0 bytes): $DisplayName" -Type Warning
                    continue
                }
                $size = $bytes / 1MB
                Write-Status "Downloaded: $(Split-Path $OutFile -Leaf) ($([math]::Round($size, 2)) MB)" -Type Success
                return $true
            }
        }
        catch {
            Write-Status "Attempt $attempt failed for $DisplayName : $_" -Type Warning
            if ($attempt -lt $MaxRetries) {
                Write-Status "Retrying in $RetryDelaySec seconds..." -Type Info
                Start-Sleep -Seconds $RetryDelaySec
            }
        }
    }

    Write-Status "FAILED to download $DisplayName after $MaxRetries attempts" -Type Error
    return $false
}

function Get-DirectorySize {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        return (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
    }
    catch { return 0 }
}

function Format-FileSize {
    param([int64]$Size)
    $units = 'B', 'KB', 'MB', 'GB', 'TB'
    $i = 0; $s = [float]$Size
    while ($s -ge 1024 -and $i -lt $units.Count - 1) { $s /= 1024; $i++ }
    return "$([math]::Round($s, 2)) $($units[$i])"
}

# ====================================
# CLEANUP & PREP
# ====================================
function Initialize-BuildEnvironment {
    Write-Status "=== Initializing Build Environment ===" -Type Info

    # Dismount any stale WIM (prevents "access denied" during builds after crash)
    if (Test-Path $Mount) {
        $mounted = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $Mount }
        if ($mounted) {
            Write-Status "Dismounting stale WIM at $Mount..." -Type Warning
            Dismount-WindowsImage -Path $Mount -Discard -ErrorAction SilentlyContinue
        }
        Remove-Item $Mount -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Create working directories
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
    # NOTE: -StartOSDCloudGUI is intentionally NOT passed here.
    #   OSD would append 'Start-OSDCloudGUI' to startnet.cmd which we then strip.
    #   We manage our own mode selector in Invoke-WinPEShellConfig.
    # NOTE: -WirelessConnect is critical — OSD injects 'Initialize-OSDCloudStartnet -WirelessConnect'
    #   into startnet.cmd. That function calls Start-WinREWiFi which pops the WiFi GUI.
    #   Invoke-WinPEShellConfig PRESERVES this block and only appends after it.
    Write-Status "Enhancing WinPE with cloud drivers + WiFi support..." -Type Info
    Edit-OSDCloudWinPE `
        -CloudDriver * `
        -WirelessConnect

    Write-Status "OSD Cloud setup complete" -Type Success
}

# ====================================
# STEP 2: DOWNLOAD & PREPARE APPLICATIONS
# ====================================
function Invoke-ApplicationPrep {
    Write-Status "=== Preparing Portable Applications ===" -Type Info

    $downloads = "$BuildPayload\downloads"
    if (Test-Path $downloads) { Remove-Item $downloads -Recurse -Force }
    New-Item $downloads -ItemType Directory -Force | Out-Null

    $tools = "$BuildPayload\tools"
    New-Item $tools -ItemType Directory -Force | Out-Null

    # ── 1. IBM Semeru JRE 8 (portable zip — extract directly) ──
    Write-Status "--- IBM Semeru JRE 8 (OpenJ9) ---" -Type Info
    $javaZip = "$downloads\semeru-jre8.zip"
    if (Invoke-Download -Url $config.JavaUrl -OutFile $javaZip -DisplayName "IBM Semeru JRE 8 ($($config.JavaSemeruVersion))") {
        $javaDir = "$tools\java"
        New-Item $javaDir -ItemType Directory -Force | Out-Null
        Expand-Archive -Path $javaZip -DestinationPath $javaDir -Force
        # Flatten: the zip contains a top-level folder e.g. jdk-1.8.0_422-jre
        $inner = Get-ChildItem $javaDir -Directory | Select-Object -First 1
        if ($inner) {
            Get-ChildItem $inner.FullName | Move-Item -Destination $javaDir -Force
            Remove-Item $inner.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Status "IBM Semeru JRE 8 extracted ($(Format-FileSize (Get-DirectorySize $javaDir)))" -Type Success
    }

    # ── 2. PowerShell 7 (already a zip — extract directly) ──
    Write-Status "--- PowerShell 7 ---" -Type Info
    $pwshZip = "$downloads\pwsh.zip"
    if (Invoke-Download -Url $config.PowerShellUrl -OutFile $pwshZip -DisplayName "PowerShell 7") {
        $pwshDir = "$tools\pwsh"
        New-Item $pwshDir -ItemType Directory -Force | Out-Null
        Expand-Archive -Path $pwshZip -DestinationPath $pwshDir -Force
        Write-Status "PowerShell 7 extracted ($(Format-FileSize (Get-DirectorySize $pwshDir)))" -Type Success
    }

    # ── 3. Bootstrap 7-Zip (needed to extract Chrome installer) ──
    Write-Status "--- 7-Zip Bootstrap ---" -Type Info
    $sevenZipExe = $null

    # Check if 7z is already available on build system
    $sys7z = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($sys7z) {
        $sevenZipExe = $sys7z.Source
        Write-Status "Using system 7-Zip: $sevenZipExe" -Type Success
    }
    else {
        # Download 7zr.exe (standalone reduced 7-Zip console, official, tiny ~600KB)
        $sevenZr = "$downloads\7zr.exe"
        if (Invoke-Download -Url $config.SevenZipBootUrl -OutFile $sevenZr -DisplayName "7zr.exe (bootstrap)") {
            $sevenZipExe = $sevenZr
            Write-Status "7-Zip bootstrap ready" -Type Success
        }
    }

    # ── 4. Chrome — extract portable files from installer exe ──
    # PhoenixPE approach: the Chrome uncompressed installer is a self-extracting archive.
    # We use 7-Zip to extract Chrome-bin\ from it.  No MSI needed.
    Write-Status "--- Google Chrome (portable extraction) ---" -Type Info
    $chromeExe = "$downloads\chrome_installer.exe"
    if (Invoke-Download -Url $config.ChromeUrl -OutFile $chromeExe -DisplayName "Chrome Installer") {
        $chromeDir = "$tools\chrome"
        $chromeTmp = "$downloads\chrome_extract"
        New-Item $chromeDir -ItemType Directory -Force | Out-Null
        New-Item $chromeTmp -ItemType Directory -Force | Out-Null

        if ($sevenZipExe) {
            Write-Status "Extracting Chrome with 7-Zip..." -Type Info
            & $sevenZipExe x "$chromeExe" -o"$chromeTmp" -y 2>&1 | Out-Null

            # Look for chrome.7z inside (common structure)
            $chrome7z = Get-ChildItem $chromeTmp -Recurse -Filter "chrome.7z" | Select-Object -First 1
            if ($chrome7z) {
                Write-Status "Found chrome.7z, extracting inner archive..." -Type Info
                & $sevenZipExe x "$($chrome7z.FullName)" -o"$chromeTmp\inner" -y 2>&1 | Out-Null
            }

            # Find Chrome-bin directory (PhoenixPE layout)
            $chromeBin = Get-ChildItem $chromeTmp -Recurse -Directory -Filter "Chrome-bin" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($chromeBin) {
                Copy-Item "$($chromeBin.FullName)\*" -Destination $chromeDir -Recurse -Force
                Write-Status "Chrome extracted from Chrome-bin ($(Format-FileSize (Get-DirectorySize $chromeDir)))" -Type Success
            }
            else {
                # Fallback: some installer layouts just have the files directly
                $chromeExeInner = Get-ChildItem $chromeTmp -Recurse -Filter "chrome.exe" | Select-Object -First 1
                if ($chromeExeInner) {
                    Copy-Item (Split-Path $chromeExeInner.FullName -Parent) -Destination $chromeDir -Recurse -Force
                    Write-Status "Chrome extracted (fallback layout)" -Type Warning
                }
                else {
                    Copy-Item "$chromeTmp\*" -Destination $chromeDir -Recurse -Force
                    Write-Status "Chrome extracted (raw copy)" -Type Warning
                }
            }
        }
        else {
            Write-Status "Could not obtain 7-Zip — Chrome extraction SKIPPED" -Type Error
        }

        Remove-Item $chromeTmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ── 5. 7-Zip portable console (for inclusion in the WinPE image) ──
    Write-Status "--- 7-Zip Portable (for PE image) ---" -Type Info
    $sevenZipDir = "$tools\7zip"
    New-Item $sevenZipDir -ItemType Directory -Force | Out-Null
    # Copy the bootstrap 7zr.exe into the image tools
    if ($sevenZipExe -and (Test-Path $sevenZipExe)) {
        Copy-Item $sevenZipExe "$sevenZipDir\7zr.exe" -Force
        Write-Status "7-Zip portable console included in image" -Type Success
    }

    # ── 6. WinXShell — download COMPLETE file set from wimbuilder2 ──
    Write-Status "--- WinXShell Desktop Shell ---" -Type Info
    $wxsDir = "$tools\winxshell"
    New-Item $wxsDir -ItemType Directory -Force | Out-Null

    $wxsBase = $config.WinXShellBase
    $wxsOk = $true

    # Root executables and config files
    $wxsRootFiles = @(
        "WinXShell_x64.exe",
        "WinXShellC_x64.exe",
        "WinXShell.lua",
        "WinXShell.zh-CN.cfg",
        "wxsStub.dll",
        "wxsStub32.dll",
        "wallpaper.jpg"
    )
    foreach ($f in $wxsRootFiles) {
        if (-not (Invoke-Download -Url "$wxsBase/$f" -OutFile "$wxsDir\$f" -DisplayName "WinXShell/$f")) {
            $wxsOk = $false
        }
    }

    # FileExpRefresh subdirectory (needed for file explorer integration)
    $ferDir = "$wxsDir\FileExpRefresh"
    New-Item $ferDir -ItemType Directory -Force | Out-Null
    foreach ($f in @("wxsStub.dll", "wxsStub32.dll")) {
        Invoke-Download -Url "$wxsBase/FileExpRefresh/$f" -OutFile "$ferDir\$f" -DisplayName "FileExpRefresh/$f" | Out-Null
    }

    # wxsUI subdirectory — provides taskbar, system tray, WiFi, volume, etc.
    $wxsUIDir = "$wxsDir\wxsUI"
    New-Item $wxsUIDir -ItemType Directory -Force | Out-Null

    # Lua scripts and font files
    $wxsUIRootFiles = @(
        "KeyboardLayout.lua",
        "SegoeIcons.ttf",
        "segmdl2.ttf",
        "UI_Settings.lua",
        "UI_Shutdown.lua"
    )
    foreach ($f in $wxsUIRootFiles) {
        Invoke-Download -Url "$wxsBase/wxsUI/$f" -OutFile "$wxsUIDir\$f" -DisplayName "wxsUI/$f" | Out-Null
    }

    # wxsUI ZIPs — these are the actual UI panel modules (taskbar, tray, WiFi, etc.)
    # Without these, WinXShell shows a blank desktop with no controls!
    $wxsUIZips = @(
        "UI_Calendar.zip",
        "UI_DisplaySwitch.zip",
        "UI_LED.zip",
        "UI_Launcher.zip",
        "UI_Logon.zip",
        "UI_Resolution.zip",
        "UI_Sample.zip",
        "UI_Settings.zip",
        "UI_Shutdown.zip",
        "UI_SystemInfo.zip",
        "UI_TrayPanel.zip",
        "UI_Volume.zip",
        "UI_WIFI.zip"
    )
    foreach ($z in $wxsUIZips) {
        Invoke-Download -Url "$wxsBase/wxsUI/$z" -OutFile "$wxsUIDir\$z" -DisplayName "wxsUI/$z" | Out-Null
    }

    # UI_NotifyInfo subdirectory
    New-Item "$wxsUIDir\UI_NotifyInfo" -ItemType Directory -Force | Out-Null

    if ($wxsOk) {
        Write-Status "WinXShell downloaded with all UI components" -Type Success
    }
    else {
        Write-Status "Some WinXShell core files failed — shell may not start" -Type Error
    }

    # Create PATH directories
    New-Item "$tools\bin" -ItemType Directory -Force | Out-Null
    New-Item "$tools\scripts" -ItemType Directory -Force | Out-Null

    # Report totals
    $totalSize = Get-DirectorySize $tools
    Write-Status "Total tools size: $(Format-FileSize $totalSize)" -Type Info
    Write-Status "Application preparation complete" -Type Success
}

# ====================================
# STEP 3: MOUNT & CUSTOMIZE WINRE
# ====================================
function Invoke-WinRECustomization {
    Write-Status "=== Mounting and Customizing WinRE ===" -Type Info

    $bootWim = "$Workspace\Media\sources\boot.wim"

    if (-not (Test-Path $bootWim)) {
        throw "boot.wim not found at $bootWim — run Invoke-OSDCloudSetup first (Mode BuildWinRE or Full)"
    }

    # Mount WIM
    Write-Status "Mounting boot.wim..." -Type Info
    New-Item $Mount -ItemType Directory -Force | Out-Null
    Mount-WindowsImage -ImagePath $bootWim -Index 1 -Path $Mount

    # Copy tools into the image
    Write-Status "Copying tools to WinRE (X:\Tools)..." -Type Info
    $toolsMount = "$Mount\Tools"
    Copy-Item "$BuildPayload\tools" -Destination $toolsMount -Recurse -Force

    # Ensure directory structure
    New-Item "$Mount\Tools\bin" -ItemType Directory -Force | Out-Null
    New-Item "$Mount\Tools\scripts" -ItemType Directory -Force | Out-Null

    # ── Patch WinXShell.lua — pin wallpaper path (PhoenixPE approach) ──
    # The upstream WinXShell.lua uses a relative/undefined wallpaper path.
    # Set it explicitly so it resolves correctly regardless of CWD at WinXShell launch.
    $wxsLua = "$Mount\Tools\winxshell\WinXShell.lua"
    if (Test-Path $wxsLua) {
        $wxsContent = Get-Content $wxsLua -Raw -Encoding UTF8
        if ($wxsContent -match 'wallpaper\s*=\s*"[^"]*"') {
            $wxsContent = $wxsContent -replace 'wallpaper\s*=\s*"[^"]*"', 'wallpaper = "X:\\Tools\\winxshell\\wallpaper.jpg"'
            Set-Content $wxsLua $wxsContent -Encoding UTF8 -NoNewline
            Write-Status "WinXShell.lua: wallpaper path pinned to X:\Tools\winxshell\wallpaper.jpg" -Type Success
        }
        else {
            Write-Status "WinXShell.lua: wallpaper key not found — skipping patch (verify manually)" -Type Warning
        }
    }
    else {
        Write-Status "WinXShell.lua not found at $wxsLua — wallpaper patch skipped" -Type Warning
    }

    # ── Configure Registry ──
    Write-Status "Configuring offline registry..." -Type Info

    $systemReg = "$Mount\Windows\System32\Config\SYSTEM"
    $softwareReg = "$Mount\Windows\System32\Config\SOFTWARE"

    # Load SYSTEM hive → set JAVA_HOME and PATH
    reg load HKLM\WinRE_SYS $systemReg 2>$null

    reg add "HKLM\WinRE_SYS\ControlSet001\Control\Session Manager\Environment" `
        /v JAVA_HOME /t REG_SZ /d "X:\Tools\java" /f 2>$null

    reg add "HKLM\WinRE_SYS\ControlSet001\Control\Session Manager\Environment" `
        /v PATH /t REG_EXPAND_SZ `
        /d "X:\Tools\bin;X:\Tools\java\bin;X:\Tools\pwsh;X:\Tools\chrome;X:\Tools\winxshell;X:\Tools\7zip;%PATH%" /f 2>$null

    reg unload HKLM\WinRE_SYS 2>$null

    # Load SOFTWARE hive → set shell, file associations
    reg load HKLM\WinRE_SW $softwareReg 2>$null

    # Register .jar file association
    reg add "HKLM\WinRE_SW\Classes\.jar" /ve /t REG_SZ /d "IBM.jarfile" /f 2>$null
    reg add "HKLM\WinRE_SW\Classes\.jar" /v "Content Type" /t REG_SZ /d "application/jar" /f 2>$null
    reg add "HKLM\WinRE_SW\Classes\IBM.jarfile" /ve /t REG_SZ /d "IBM Semeru JAR file" /f 2>$null
    reg add "HKLM\WinRE_SW\Classes\IBM.jarfile\shell\open" /ve /t REG_SZ /d "Open" /f 2>$null
    reg add "HKLM\WinRE_SW\Classes\IBM.jarfile\shell\open\command" `
        /ve /t REG_SZ /d '"X:\Tools\java\bin\javaw.exe" -jar "%1"' /f *>$null

    # JavaSoft / Oracle compatibility keys — required by many Java apps that query
    # HKLM\SOFTWARE\JavaSoft at runtime to locate the JRE (PhoenixPE approach)
    $jver = $config.JavaSemeruVersion          # e.g. "8.0.422.5"
    $jShortVer = "1.8"                         # JRE short version for legacy lookups
    reg add "HKLM\WinRE_SW\JavaSoft\Java Runtime Environment" `
        /v CurrentVersion /t REG_SZ /d $jShortVer /f 2>$null
    reg add "HKLM\WinRE_SW\JavaSoft\Java Runtime Environment\$jShortVer" `
        /v JavaHome /t REG_SZ /d "X:\Tools\java" /f 2>$null
    reg add "HKLM\WinRE_SW\JavaSoft\Java Runtime Environment\$jShortVer" `
        /v MicroVersion /t REG_SZ /d "0" /f 2>$null
    reg add "HKLM\WinRE_SW\JavaSoft\Java Runtime Environment\$jShortVer" `
        /v RuntimeLib /t REG_SZ /d "X:\Tools\java\bin\server\jvm.dll" /f 2>$null
    # Also register the Azul/IBM-specific key for apps that look for vendor info
    reg add "HKLM\WinRE_SW\IBM\Semeru Runtime Open Edition\jre-8" `
        /v CurrentVersion /t REG_SZ /d $jver /f 2>$null
    reg add "HKLM\WinRE_SW\IBM\Semeru Runtime Open Edition\jre-8" `
        /v InstallationPath /t REG_SZ /d "X:\Tools\java\" /f 2>$null

    # Set WinXShell as the Winlogon shell
    # Same approach as wimbuilder2 / EdgelessPE / PhoenixPE — more reliable than winpeshl.ini
    # because OSD module can overwrite winpeshl.ini during Edit-OSDCloudWinPE
    reg add "HKLM\WinRE_SW\Microsoft\Windows NT\CurrentVersion\Winlogon" `
        /v Shell /t REG_SZ /d "X:\Tools\winxshell\WinXShell_x64.exe" /f 2>$null

    # Register Chrome for http/https/html (like PhoenixPE)
    reg add "HKLM\WinRE_SW\Classes\http\shell\open\command" `
        /ve /t REG_SZ /d '"X:\Tools\chrome\chrome.exe" "%1"' /f *>$null
    reg add "HKLM\WinRE_SW\Classes\https\shell\open\command" `
        /ve /t REG_SZ /d '"X:\Tools\chrome\chrome.exe" "%1"' /f *>$null
    reg add "HKLM\WinRE_SW\Classes\.html" /ve /t REG_SZ /d "ChromeHTML" /f 2>$null
    reg add "HKLM\WinRE_SW\Classes\.htm" /ve /t REG_SZ /d "ChromeHTML" /f 2>$null
    reg add "HKLM\WinRE_SW\Classes\ChromeHTML\shell\open\command" `
        /ve /t REG_SZ /d '"X:\Tools\chrome\chrome.exe" "%1"' /f *>$null

    # Chrome master_preferences to disable first-run wizard (PhoenixPE approach)
    $chromeMasterPrefs = @'
{
    "distribution": {
        "suppress_first_run_bubble": true,
        "do_not_create_desktop_shortcut": true,
        "do_not_create_quick_launch_shortcut": true,
        "do_not_launch_chrome": true,
        "do_not_register_for_update_launch": true,
        "make_chrome_default": true,
        "make_chrome_default_for_user": true,
        "suppress_first_run_default_browser_prompt": true,
        "system_level": true
    },
    "first_run_tabs": ["about:blank"]
}
'@
    $chromeToolPath = "$Mount\Tools\chrome"
    if (Test-Path $chromeToolPath) {
        Set-Content -Path "$chromeToolPath\master_preferences" -Value $chromeMasterPrefs -Encoding UTF8
    }

    # ── Custom Wallpaper ──
    $wxsWallpaper = "$Mount\Tools\winxshell\wallpaper.jpg"
    if (-not [string]::IsNullOrWhiteSpace($WallpaperPath) -and (Test-Path $WallpaperPath)) {
        Write-Status "Applying custom wallpaper: $WallpaperPath" -Type Info
        # Copy to WinXShell directory (its primary wallpaper source)
        Copy-Item $WallpaperPath $wxsWallpaper -Force
        # Also place in the standard Windows Web wallpaper location
        $webWallpaperDir = "$Mount\Windows\Web\Wallpaper"
        New-Item $webWallpaperDir -ItemType Directory -Force | Out-Null
        Copy-Item $WallpaperPath "$webWallpaperDir\wallpaper$([System.IO.Path]::GetExtension($WallpaperPath))" -Force
        # Set system wallpaper registry key
        reg add "HKLM\WinRE_SW\Microsoft\Windows NT\CurrentVersion\Winlogon" `
            /v Wallpaper /t REG_SZ `
            /d "X:\Windows\Web\Wallpaper\wallpaper$([System.IO.Path]::GetExtension($WallpaperPath))" /f 2>$null
        Write-Status "Custom wallpaper applied" -Type Success
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($WallpaperPath)) {
            Write-Status "WallpaperPath '$WallpaperPath' not found — using default WinXShell wallpaper" -Type Warning
        }
    }

    reg unload HKLM\WinRE_SW 2>$null

    Write-Status "Registry configuration complete" -Type Success
}

# ====================================
# STEP 4: CREATE LAUNCHER SCRIPTS
# ====================================
function Invoke-LauncherSetup {
    Write-Status "=== Creating Launcher Scripts ===" -Type Info

    $scriptsDir = "$Mount\Tools\scripts"

    # Mode Selector — plain batch menu (NO WPF — WinPE doesn't have PresentationFramework!)
    $modeSelector = @'
@echo off
title LiveWinRE - Mode Selector
echo.
echo  ============================================
echo   LiveWinRE LiveBoot - Mode Selector
echo  ============================================
echo.
echo   1 = OSD Cloud Deploy (automated deployment)
echo   2 = Desktop Mode    (WinXShell GUI)
echo.
set /p choice="  Select [1-2]: "
if "%choice%"=="1" (
    echo.
    echo  Starting OSD Cloud Deployment...
    X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoExit -Command "Import-Module OSD -Force -ErrorAction SilentlyContinue; Start-OSDCloudGUI"
)
echo  Starting WinXShell desktop...
rem WinXShell starts automatically via Winlogon\Shell registry
'@
    Set-Content -Path "$scriptsDir\ModeSelector.cmd" -Value $modeSelector -Encoding ASCII

    # OSD Deploy launcher
    $osdLauncher = @'
@echo off
title OSD Cloud Deploy
X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoExit -Command "Import-Module OSD -Force -ErrorAction SilentlyContinue; Start-OSDCloudGUI"
'@
    Set-Content -Path "$scriptsDir\OSD-Deploy.cmd" -Value $osdLauncher -Encoding ASCII

    # Chrome launcher (with WinPE-safe flags)
    $chromeLauncher = @'
@echo off
start "" "X:\Tools\chrome\chrome.exe" --no-first-run --no-default-browser-check --disable-background-networking --disable-sync %*
'@
    Set-Content -Path "$scriptsDir\Chrome.cmd" -Value $chromeLauncher -Encoding ASCII

    # PowerShell 7 launcher
    $pwshLauncher = @'
@echo off
"X:\Tools\pwsh\pwsh.exe" -NoLogo -NoExit %*
'@
    Set-Content -Path "$scriptsDir\PowerShell7.cmd" -Value $pwshLauncher -Encoding ASCII

    # Command Prompt with environment
    $cmdLauncher = @'
@echo off
title LiveWinRE Command Prompt
set PATH=X:\Tools\bin;X:\Tools\java\bin;X:\Tools\pwsh;X:\Tools\chrome;X:\Tools\winxshell;X:\Tools\7zip;%PATH%
set JAVA_HOME=X:\Tools\java
echo.
echo  LiveWinRE Command Prompt
echo  Java: X:\Tools\java    Chrome: X:\Tools\chrome
echo  PS7:  X:\Tools\pwsh    7-Zip:  X:\Tools\7zip
echo.
cmd /k
'@
    Set-Content -Path "$scriptsDir\CommandPrompt.cmd" -Value $cmdLauncher -Encoding ASCII

    # Create desktop shortcut bootstrap script (run at WinPE first-boot via startnet.cmd)
    # Rationale: shortcuts point to X:\ paths that don't exist on the build host.
    # Creating them at WinPE boot-time (when X:\ is live) is the PhoenixPE approach
    # and avoids unreliable build-time COM calls against non-existent paths.
    $createShortcutsScript = @'
param()
# Creates desktop shortcuts at WinPE boot — X:\ is live at this point
$desktopDir = "X:\Users\Public\Desktop"
New-Item $desktopDir -ItemType Directory -Force | Out-Null

$shortcuts = @(
    @{ Name = "OSD Deploy";     Target = "X:\Tools\scripts\OSD-Deploy.cmd";     WorkDir = "X:\Tools" }
    @{ Name = "Chrome Browser"; Target = "X:\Tools\scripts\Chrome.cmd";         WorkDir = "X:\Tools\chrome" }
    @{ Name = "PowerShell 7";   Target = "X:\Tools\pwsh\pwsh.exe";              WorkDir = "X:\Tools\pwsh" }
    @{ Name = "Command Prompt"; Target = "X:\Tools\scripts\CommandPrompt.cmd";  WorkDir = "X:\Tools" }
)

foreach ($sc in $shortcuts) {
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut("$desktopDir\$($sc.Name).lnk")
        $lnk.TargetPath       = $sc.Target
        $lnk.WorkingDirectory = $sc.WorkDir
        $lnk.Save()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
    }
    catch {
        # Fallback: plain cmd stub on the desktop
        "@echo off`nstart `"`" `"$($sc.Target)`"" | Set-Content "$desktopDir\$($sc.Name).cmd" -Encoding ASCII
    }
}
'@
    Set-Content -Path "$scriptsDir\CreateShortcuts.ps1" -Value $createShortcutsScript -Encoding UTF8
    Write-Status "Desktop shortcut bootstrap script created (runs at WinPE boot)" -Type Info

    # Copy launchers to bin (so they're on PATH)
    Copy-Item "$scriptsDir\*.cmd" "$Mount\Tools\bin\" -Force

    Write-Status "Launcher setup complete" -Type Success
}

# ====================================
# STEP 5: CONFIGURE WINPE SHELL
# ====================================
function Invoke-WinPEShellConfig {
    Write-Status "=== Configuring WinPE Shell ===" -Type Info

    # Strategy:
    # 1. Winlogon\Shell = WinXShell_x64.exe  (set via registry in Step 3)
    # 2. startnet.cmd: PRESERVE the OSD-written WiFi init block, APPEND our mode selector
    # 3. Remove winpeshl.ini so WinPE uses standard Winlogon shell loading
    #
    # CRITICAL — WiFi preservation:
    #   Edit-OSDCloudWinPE (Step 1) already wrote startnet.cmd with:
    #     wpeinit
    #     PowerShell -Nol -C Initialize-OSDCloudStartnet -WirelessConnect
    #     PowerShell -Nol -C Initialize-OSDCloudStartnetUpdate
    #   Initialize-OSDCloudStartnet checks for dmcmnutils.dll, calls Start-WinREWiFi
    #   which presents the WiFi connection GUI and waits for a valid IP before
    #   continuing. If we overwrite startnet.cmd we lose ALL of this.
    #
    #   We therefore READ the OSD content, strip only the OSD launch tail
    #   ('start PowerShell -NoL' and any blank lines after it), then
    #   APPEND our environment setup and mode selector.

    $startnetPath = "$Mount\Windows\System32\startnet.cmd"

    # --- Read OSD-written startnet.cmd (produced by Edit-OSDCloudWinPE) ---
    $osdStartnet = ''
    if (Test-Path $startnetPath) {
        $osdStartnet = Get-Content $startnetPath -Raw -Encoding ASCII
        Write-Status "Existing OSD startnet.cmd found — preserving WiFi init block" -Type Info

        # Verify the WiFi init call is present
        if ($osdStartnet -match 'Initialize-OSDCloudStartnet') {
            Write-Status "WiFi init (Initialize-OSDCloudStartnet) confirmed in startnet.cmd" -Type Success
        }
        else {
            Write-Status "WARNING: Initialize-OSDCloudStartnet not found in OSD startnet.cmd — WiFi may not work" -Type Warning
        }

        # Strip the OSD-appended tail: '@ECHO OFF\r?\nstart PowerShell -NoL' and everything after.
        # OSD adds this when no -StartOSDCloud* flag is passed.
        $osdStartnet = $osdStartnet -replace '(?i)@ECHO OFF\r?\nstart PowerShell.*?(\r?\n|$)', ''
        # Also strip any trailing blank lines so our append is clean
        $osdStartnet = $osdStartnet.TrimEnd()
    }
    else {
        Write-Status "OSD startnet.cmd not found — building from scratch (WiFi init may be missing!)" -Type Warning
        $osdStartnet = "@ECHO OFF`r`nwpeinit`r`ncd\\"
    }

    # --- Append our custom LiveWinRE launcher block ---
    $customBlock = @"

rem ==============================================================
rem  LiveWinRE Custom Launcher (appended by Build-OSDCloud-Clean)
rem  OSD WiFi init block above is intentionally preserved.
rem ==============================================================

rem Environment: make all portable tools available from any shell
set PATH=X:\Tools\bin;X:\Tools\java\bin;X:\Tools\pwsh;X:\Tools\chrome;X:\Tools\winxshell;X:\Tools\7zip;%PATH%
set JAVA_HOME=X:\Tools\java

rem Create desktop shortcuts now that X:\ is live (build-time host cannot resolve X:\ paths)
X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NonInteractive -File X:\Tools\scripts\CreateShortcuts.ps1

rem Show mode selector (OSD Deploy vs WinXShell Desktop)
call X:\Tools\scripts\ModeSelector.cmd

rem WinXShell starts automatically as the desktop shell via Winlogon\Shell registry key.
"@

    # Idempotency guard: do not re-append our custom block on repeated runs
    if ($osdStartnet -match [regex]::Escape('ModeSelector.cmd')) {
        Write-Status "Custom launcher block already present in startnet.cmd — skipping append" -Type Warning
        $finalStartnet = $osdStartnet
    }
    else {
        $finalStartnet = $osdStartnet + $customBlock
    }
    Set-Content -Path $startnetPath -Value $finalStartnet -Encoding ASCII

    Write-Status "startnet.cmd updated (OSD WiFi block preserved, LiveWinRE launcher appended)" -Type Success

    # Remove winpeshl.ini — let Winlogon handle shell startup instead
    $winpeshlPath = "$Mount\Windows\System32\winpeshl.ini"
    if (Test-Path $winpeshlPath) {
        Remove-Item $winpeshlPath -Force -ErrorAction SilentlyContinue
        Write-Status "Removed winpeshl.ini (using Winlogon shell instead)" -Type Info
    }

    Write-Status "WinPE shell configured (WinXShell via Winlogon + startnet.cmd with WiFi)" -Type Success
}

# ====================================
# STEP 5b: INJECT EXTRA DRIVERS
# ====================================
function Invoke-DriverInjection {
    if ([string]::IsNullOrWhiteSpace($DriversPath) -or -not (Test-Path $DriversPath)) {
        Write-Status "Drivers folder not found at '$DriversPath' — skipping driver injection" -Type Info
        return
    }

    $infFiles = Get-ChildItem -Path $DriversPath -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue
    if ($infFiles.Count -eq 0) {
        Write-Status "Drivers folder is empty (no .inf files found) — skipping driver injection" -Type Warning
        return
    }

    Write-Status "=== Injecting Extra Drivers ($($infFiles.Count) .inf files found) ===" -Type Info
    Write-Status "Source: $DriversPath" -Type Info

    try {
        $result = Add-WindowsDriver -Path $Mount -Driver $DriversPath -Recurse -ErrorAction Stop
        $injected = @($result).Count
        Write-Status "Driver injection complete — $injected driver package(s) added to image" -Type Success
    }
    catch {
        Write-Status "Driver injection failed: $_" -Type Error
        Write-Status "Build will continue — drivers were NOT injected" -Type Warning
    }
}

# ====================================
# STEP 6: COMMIT CHANGES
# ====================================
function Invoke-WinRECommit {
    Write-Status "=== Committing WinRE Changes ===" -Type Info

    # Report image size before commit
    $toolsSize = Get-DirectorySize "$Mount\Tools"
    Write-Status "Tools payload size: $(Format-FileSize $toolsSize)" -Type Info

    # Force GC to release any lingering COM / file handles before dismounting.
    # Without this, WScript.Shell COM objects or open file handles can leave the
    # registry hives locked and cause 'the process cannot access the file' errors.
    [gc]::Collect()
    [gc]::WaitForPendingFinalizers()

    # Safety: ensure registry hives are unloaded before dismount.
    # These are no-ops if Invoke-WinRECustomization already unloaded them correctly.
    # Note: reg.exe writes its "ERROR:" messages to STDOUT (not stderr), so *>$null
    # is required to suppress both streams; 2>$null alone would leave errors visible.
    reg unload "HKLM\WinRE_SW"  *>$null
    reg unload "HKLM\WinRE_SYS" *>$null

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
    else {
        Write-Status "ISO file not found after build — check OSD module output" -Type Error
    }
}

# ====================================
# MAIN EXECUTION
# ====================================
function Invoke-Main {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host ""
    Write-Status "=== OSDCloud Clean WinRE Builder v$($config.Version) ===" -Type Info
    Write-Status "Mode: $Mode | Build: $($config.BuildDate)" -Type Info
    Write-Status "All downloads are PORTABLE — no MSI, no installers" -Type Info
    Write-Host ""

    # Step 0: Initialize
    if ($Mode -in 'BuildWinRE', 'Full') {
        Initialize-BuildEnvironment
    }

    # Step 1: OSD Setup
    if ($Mode -in 'BuildWinRE', 'Full') {
        Invoke-OSDCloudSetup
    }

    # Step 2: Download portable apps
    if ($Mode -in 'BuildWinRE', 'Full') {
        Invoke-ApplicationPrep
    }

    # Step 3-5: Mount, customize, configure shell
    if ($Mode -in 'BuildWinRE', 'Full') {
        try {
            Invoke-WinRECustomization
            Invoke-LauncherSetup
            Invoke-WinPEShellConfig
            Invoke-DriverInjection   # inject extra drivers while WIM is still mounted
            Invoke-WinRECommit
        }
        catch {
            Write-Status "Build pipeline failed: $_" -Type Error
            # Safety dismount — no-op if already dismounted
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            reg unload "HKLM\WinRE_SW"  2>$null
            reg unload "HKLM\WinRE_SYS" 2>$null
            Dismount-WindowsImage -Path $Mount -Discard -ErrorAction SilentlyContinue
            throw
        }
    }

    # Step 6: Build ISO
    if ($Mode -in 'BuildISO', 'Full') {
        Invoke-ISOBuild
    }

    $stopwatch.Stop()
    $elapsed = $stopwatch.Elapsed

    Write-Host ""
    Write-Status "=== Build Complete ===" -Type Success
    Write-Status "Elapsed: $($elapsed.ToString('hh\:mm\:ss'))" -Type Info
    Write-Status "Workspace: $Workspace" -Type Info

    if (Test-Path "$Workspace\*.iso") {
        $iso = Get-ChildItem "$Workspace\*.iso" | Select-Object -Last 1
        Write-Status "ISO Location: $($iso.FullName)" -Type Info
        Write-Status "ISO Size: $(Format-FileSize $iso.Length)" -Type Info
    }

    Write-Host ""
}

# Execute
Invoke-Main
