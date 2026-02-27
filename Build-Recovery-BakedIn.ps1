# =================================================================
# OSDCloud Recovery Builder — BAKED-IN Tools Edition
# =================================================================
# Tools (Chrome, Java Semeru 8 LTS, 7-Zip) are downloaded on the
# BUILD machine and injected into the WIM via OSD Config\ Robocopy.
# At WinPE boot: HTA menu -> LIBR (ZTI deploy) OR Recovery Desktop.
# =================================================================

param(
    [string]   $Workspace     = "C:\OSDCloud\WinRE",

    # --- LIBR / ZTI deployment target ---
    [string]   $OSName        = "Windows 11 24H2 x64",
    [string]   $OSLanguage    = "en-us",
    [string]   $OSEdition     = "Enterprise",
    [string]   $OSActivation  = "Volume",

    # --- WinPE hardware support ---
    [string[]] $CloudDriver   = @('*'),
    [switch]   $WirelessConnect,

    # --- Optional extras ---
    [string]   $DriversPath   = "$PSScriptRoot\Drivers",
    [string]   $WallpaperPath = "",          # must be .jpg
    [switch]   $ForceTemplate,
    [string]   $StagingPath   = "C:\BuildPayload",

    # --- Download URLs (update when versions go stale) ---
    # Chrome: uncompressed installer - extract Chrome-bin with 7-Zip
    # To find a new URL: download latest ChromeSetup.exe from
    #   https://dl.google.com/tag/s/appguid={...}/update2/installers/ChromeSetup.exe
    # and inspect the download URL from dl.google.com/release2/chrome/
    [string]   $ChromeUrl     = "https://dl.google.com/release2/chrome/AOs_2025Q1/131.0.6778.204/131.0.6778.204_chrome_installer_uncompressed.exe",

    # 7-Zip installer SFX - 7zr.exe can extract it
    [string]   $SevenZipUrl   = "https://www.7-zip.org/a/7z2409-x64.exe",
    [string]   $SevenZrUrl    = "https://www.7-zip.org/a/7zr.exe",

    # IBM Semeru JRE 8 LTS (OpenJ9) - check latest at:
    # https://github.com/ibm-semeru-runtimes/open-jdk8u-releases/releases
    [string]   $JavaUrl       = "https://github.com/ibm-semeru-runtimes/open-jdk8u-releases/releases/download/jdk8u422-b05/ibm-semeru-open-jre_x64_windows_8.0.422.5_openj9-0.46.0.zip"
)

#Requires -RunAsAdministrator
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# =================================================================
# HELPERS
# =================================================================
function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error')][string]$Type = 'Info'
    )
    $colors = @{ Info='Cyan'; Success='Green'; Warning='Yellow'; Error='Red' }
    $prefix = @{ Info='[INFO]'; Success='[OK]  '; Warning='[WARN]'; Error='[ERR] ' }
    Write-Host "$($prefix[$Type]) $Message" -ForegroundColor $colors[$Type]
}

function Invoke-Download {
    param([string]$Url, [string]$OutFile, [string]$Label, [int]$Tries = 3)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    for ($i = 1; $i -le $Tries; $i++) {
        try {
            Write-Status "Downloading $Label (attempt $i/$Tries)..." -Type Info
            if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
            if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 0) {
                $mb = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
                Write-Status "$Label downloaded ($mb MB)" -Type Success
                return $true
            }
        } catch {
            Write-Status "Attempt $i failed: $_" -Type Warning
            if ($i -lt $Tries) { Start-Sleep -Seconds 5 }
        }
    }
    Write-Status "FAILED to download $Label" -Type Error
    return $false
}

# =================================================================
# STEP 1 - OSD MODULE
# =================================================================
function Invoke-OSDModuleSetup {
    Write-Status "Ensuring OSD module is installed..." -Type Info
    if (-not (Get-Module OSD -ListAvailable)) {
        Install-Module OSD -Force -Scope CurrentUser
    }
    Import-Module OSD -Force
    Write-Status "OSD v$((Get-Module OSD).Version) loaded" -Type Success
}

# =================================================================
# STEP 2 - TEMPLATE
# =================================================================
function Invoke-TemplateSetup {
    $name = 'WinRE'
    if (-not $ForceTemplate -and (Get-OSDCloudTemplateNames) -contains $name) {
        Write-Status "Template '$name' exists -- skipping (-ForceTemplate to rebuild)" -Type Warning
    } else {
        Write-Status "Building OSDCloud Template '$name' -- takes ~5 min..." -Type Info
        New-OSDCloudTemplate -Name $name -WinRE -Add7Zip -Verbose
        Write-Status "Template '$name' built" -Type Success
    }
    Set-OSDCloudTemplate -Name $name
}

# =================================================================
# STEP 3 - WORKSPACE
# =================================================================
function Invoke-WorkspaceSetup {
    Write-Status "Workspace: $Workspace" -Type Info
    Set-OSDCloudWorkspace -WorkspacePath $Workspace
    Write-Status "Workspace ready at $(Get-OSDCloudWorkspace)" -Type Success
}

# =================================================================
# STEP 4 - DOWNLOAD PORTABLE TOOLS -> $Workspace\Config\Tools\
#
# OSD's Edit-OSDCloudWinPE Robocopy-mirrors $Workspace\Config\ into
# X:\OSDCloud\Config\ inside the WIM -- no manual WIM mounting needed.
# Tools land at X:\OSDCloud\Config\Tools\ in WinPE at runtime.
# =================================================================
function Invoke-RecoveryToolsDownload {
    Write-Status "=== Downloading Recovery Tools (baking into WIM) ===" -Type Info

    $dl   = "$StagingPath\downloads"
    $base = "$Workspace\Config\Tools"
    foreach ($p in @($dl, $base)) { New-Item $p -ItemType Directory -Force | Out-Null }

    # ---- Bootstrap: 7zr.exe (standalone, no extraction needed) ----------
    $sevenZr = $null
    $sys7z   = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    if ($sys7z) {
        $sevenZr = $sys7z.Source
        Write-Status "Using system 7-Zip: $sevenZr" -Type Success
    } else {
        $sevenZrPath = "$dl\7zr.exe"
        if (Invoke-Download $SevenZrUrl $sevenZrPath "7zr.exe (bootstrap)") {
            $sevenZr = $sevenZrPath
        }
    }
    if (-not $sevenZr) {
        Write-Status "Cannot proceed without 7-Zip bootstrap -- aborting tool download" -Type Error
        return
    }

    # ---- 7-Zip full (installer is a 7z SFX -- extract to get 7zFM.exe) --
    Write-Status "--- 7-Zip ---" -Type Info
    $sevenZipDir       = "$base\7zip"
    $sevenZipInstaller = "$dl\7zip-installer.exe"
    New-Item $sevenZipDir -ItemType Directory -Force | Out-Null
    if (Invoke-Download $SevenZipUrl $sevenZipInstaller "7-Zip installer") {
        $tmp = "$dl\7zip_ext"
        New-Item $tmp -ItemType Directory -Force | Out-Null
        & $sevenZr x $sevenZipInstaller -o"$tmp" -y 2>&1 | Out-Null
        foreach ($f in @('7z.exe','7z.dll','7zFM.exe','7zG.exe','7-zip.dll')) {
            $src = Join-Path $tmp $f
            if (Test-Path $src) { Copy-Item $src $sevenZipDir -Force }
        }
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Write-Status "7-Zip ready at $sevenZipDir" -Type Success
    }

    # ---- Chrome portable (extract Chrome-bin from uncompressed installer) --
    Write-Status "--- Google Chrome ---" -Type Info
    $chromeDir = "$base\chrome"
    $chromeExe = "$dl\chrome_installer.exe"
    $chromeTmp = "$dl\chrome_ext"
    New-Item $chromeDir -ItemType Directory -Force | Out-Null
    if (Invoke-Download $ChromeUrl $chromeExe "Chrome installer") {
        New-Item $chromeTmp -ItemType Directory -Force | Out-Null
        # First-pass extraction
        & $sevenZr x $chromeExe -o"$chromeTmp" -y 2>&1 | Out-Null
        # Chrome installer may contain a nested chrome.7z
        $chrome7z = Get-ChildItem $chromeTmp -Recurse -Filter 'chrome.7z' -ErrorAction SilentlyContinue |
                        Select-Object -First 1
        if ($chrome7z) {
            & $sevenZr x $chrome7z.FullName -o"$chromeTmp\inner" -y 2>&1 | Out-Null
        }
        # Locate Chrome-bin directory
        $chromeBin = Get-ChildItem $chromeTmp -Recurse -Directory -Filter 'Chrome-bin' `
                         -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($chromeBin) {
            Copy-Item "$($chromeBin.FullName)\*" $chromeDir -Recurse -Force
            Write-Status "Chrome extracted from Chrome-bin" -Type Success
        } else {
            $chromeBinExe = Get-ChildItem $chromeTmp -Recurse -Filter 'chrome.exe' `
                                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($chromeBinExe) {
                Copy-Item (Split-Path $chromeBinExe.FullName -Parent) -Destination $chromeDir -Recurse -Force
                Write-Status "Chrome extracted (fallback layout)" -Type Warning
            } else {
                Write-Status "Chrome extraction failed -- chrome.exe not found inside installer" -Type Error
            }
        }
        Remove-Item $chromeTmp -Recurse -Force -ErrorAction SilentlyContinue

        # Suppress Chrome first-run wizard
        $masterPrefs = '{"distribution":{"suppress_first_run_bubble":true,"do_not_launch_chrome":true,"make_chrome_default":false,"suppress_first_run_default_browser_prompt":true},"first_run_tabs":["about:blank"]}'
        Set-Content "$chromeDir\master_preferences" -Value $masterPrefs -Encoding UTF8
    }

    # ---- IBM Semeru JRE 8 LTS (OpenJ9) ------------------------------------
    Write-Status "--- IBM Semeru JRE 8 LTS ---" -Type Info
    $javaDir = "$base\java"
    $javaZip = "$dl\semeru-jre8.zip"
    New-Item $javaDir -ItemType Directory -Force | Out-Null
    if (Invoke-Download $JavaUrl $javaZip "IBM Semeru JRE 8 (OpenJ9)") {
        Expand-Archive -Path $javaZip -DestinationPath $javaDir -Force
        # Flatten top-level folder (zip contains e.g. jdk-1.8.0_422-jre\)
        $inner = Get-ChildItem $javaDir -Directory | Select-Object -First 1
        if ($inner) {
            Get-ChildItem $inner.FullName | Move-Item -Destination $javaDir -Force
            Remove-Item $inner.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Status "IBM Semeru JRE 8 ready at $javaDir" -Type Success
    }

    Remove-Item $dl -Recurse -Force -ErrorAction SilentlyContinue
    Write-Status "Recovery tools staged at $base" -Type Success
}

# =================================================================
# STEP 5 - WRITE WinPE SCRIPTS -> $Workspace\Config\Scripts\
# OSD Robocopy's these into X:\OSDCloud\Config\Scripts\ in the WIM.
# =================================================================
function Invoke-WriteWinPEScripts {
    $scriptsDir = "$Workspace\Config\Scripts"
    New-Item $scriptsDir -ItemType Directory -Force | Out-Null

    # ---- Build the Start-OSDCloud argument string (substituted now) ------
    $osdArgs = "-OSName '$OSName' -OSLanguage $OSLanguage -OSEdition $OSEdition -OSActivation $OSActivation -ZTI -Restart"

    # ---- Select-Mode.hta -------------------------------------------------
    # Double-quoted here-string: $osdArgs is expanded at BUILD TIME.
    $hta = @"
<html>
<head>
<title>OSDCloud Boot Menu</title>
<HTA:APPLICATION BORDER="thin" BORDERSTYLE="normal" CAPTION="yes"
    MAXIMIZEBUTTON="no" MINIMIZEBUTTON="no" SYSMENU="no"
    SCROLL="no" SINGLEINSTANCE="yes"/>
<style>
* { margin:0; padding:0; box-sizing:border-box; }
body {
    font-family: 'Segoe UI', Tahoma, sans-serif;
    background: #0f1117;
    color: #e0e0e0;
    height: 100vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
}
h1   { font-size:22px; color:#90caf9; margin-bottom:6px; letter-spacing:1px; }
.sub { font-size:12px; color:#555; margin-bottom:44px; }
.row { display:flex; gap:28px; }
.btn {
    width:260px; height:140px; border:none; border-radius:10px;
    cursor:pointer; display:flex; flex-direction:column;
    align-items:center; justify-content:center; gap:8px;
}
.btn:active { opacity:0.85; }
.btn-title { font-size:18px; font-weight:700; }
.btn-desc  { font-size:11px; opacity:0.72; text-align:center; padding:0 10px; line-height:1.5; }
.libr     { background:#1565c0; color:#fff; }
.libr:hover { background:#1976d2; }
.recovery { background:#2e7d32; color:#fff; }
.recovery:hover { background:#388e3c; }
</style>
</head>
<body>
<h1>BOOT SELECTION</h1>
<p class="sub">Network initialized. Select operating mode.</p>
<div class="row">
  <button class="btn libr" onclick="LaunchLIBR()">
    <span class="btn-title">LIBR</span>
    <span class="btn-desc">Automated OS Deployment<br>Windows 11 24H2 Enterprise</span>
  </button>
  <button class="btn recovery" onclick="LaunchRecovery()">
    <span class="btn-title">Windows Recovery OS</span>
    <span class="btn-desc">Desktop + Chrome, 7-Zip,<br>Java Semeru 8 LTS</span>
  </button>
</div>
<script language="JScript">
window.onload = function() {
    var w = 620, h = 400;
    self.resizeTo(w, h);
    self.moveTo(Math.round((screen.width  - w) / 2),
                Math.round((screen.height - h) / 2));
};
function LaunchLIBR() {
    var sh = new ActiveXObject("WScript.Shell");
    sh.Run("PowerShell -NoLogo -NonInteractive -Command \"Start-OSDCloud $osdArgs\"", 1, false);
    window.close();
}
function LaunchRecovery() {
    var sh = new ActiveXObject("WScript.Shell");
    sh.Run("PowerShell -NoLogo -File \"X:\\OSDCloud\\Config\\Scripts\\Start-RecoveryMode.ps1\"", 1, false);
    window.close();
}
</script>
</body>
</html>
"@
    Set-Content "$scriptsDir\Select-Mode.hta" -Value $hta -Encoding UTF8
    Write-Status "Select-Mode.hta written" -Type Success

    # ---- Start-RecoveryMode.ps1 ------------------------------------------
    # This script runs INSIDE WinPE at boot time.
    # Tools are pre-baked at X:\OSDCloud\Config\Tools\.
    $recoveryPs1 = @'
# =============================================================
# Start-RecoveryMode.ps1  --  runs inside WinPE at boot
# Tools are pre-baked at X:\OSDCloud\Config\Tools\
# =============================================================
$toolsBase = "X:\OSDCloud\Config\Tools"
$desktop   = "$env:SystemDrive\Users\Public\Desktop"
New-Item $desktop -ItemType Directory -Force | Out-Null

# Helper: create .lnk shortcut -- fallback to .cmd stub if COM fails
function New-PEShortcut {
    param(
        [string]$Name,
        [string]$Target,
        [string]$Arguments  = "",
        [string]$WorkingDir = ""
    )
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut("$desktop\$Name.lnk")
        $lnk.TargetPath = $Target
        if ($Arguments)  { $lnk.Arguments        = $Arguments  }
        if ($WorkingDir) { $lnk.WorkingDirectory  = $WorkingDir }
        $lnk.Save()
        [Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
        Write-Host "[OK]   Shortcut: $Name"
    } catch {
        "@echo off`r`nstart `"`" `"$Target`" $Arguments" |
            Set-Content "$desktop\$Name.cmd" -Encoding ASCII
        Write-Host "[WARN] Shortcut fallback (.cmd): $Name"
    }
}

# Chrome Browser (portable flags required for WinPE -- no roaming profile)
New-PEShortcut `
    -Name       "Chrome Browser" `
    -Target     "$toolsBase\chrome\chrome.exe" `
    -Arguments  "--no-first-run --no-default-browser-check --disable-sync --disable-gpu --user-data-dir=`"$toolsBase\chrome\profile`"" `
    -WorkingDir "$toolsBase\chrome"

# 7-Zip File Manager
New-PEShortcut `
    -Name       "7-Zip" `
    -Target     "$toolsBase\7zip\7zFM.exe" `
    -WorkingDir "$toolsBase\7zip"

# Java-aware Command Prompt (IBM Semeru 8 on PATH)
New-PEShortcut `
    -Name       "Java Prompt (Semeru 8)" `
    -Target     "X:\Windows\System32\cmd.exe" `
    -Arguments  "/k `"set JAVA_HOME=$toolsBase\java&& set PATH=%JAVA_HOME%\bin;%PATH%&& java -version`"" `
    -WorkingDir "$toolsBase\java\bin"

# Quick-return to OSD deployment wizard
New-PEShortcut `
    -Name       "LIBR - OSD Deploy" `
    -Target     "X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Arguments  "-NoLogo -NoExit -Command `"Import-Module OSD -Force; Start-OSDCloudGUI`"" `
    -WorkingDir "X:\Windows\System32"

# Expose Java + tools on PATH for any child processes spawned from desktop
[Environment]::SetEnvironmentVariable("JAVA_HOME", "$toolsBase\java", "Machine")
[Environment]::SetEnvironmentVariable(
    "PATH",
    "$toolsBase\java\bin;$toolsBase\chrome;$toolsBase\7zip;$env:PATH",
    "Machine"
)

Write-Host "[OK]   Desktop ready -- launching Explorer..."
Start-Process "explorer.exe"
'@
    Set-Content "$scriptsDir\Start-RecoveryMode.ps1" -Value $recoveryPs1 -Encoding UTF8
    Write-Status "Start-RecoveryMode.ps1 written" -Type Success
}

# =================================================================
# STEP 6 - EDIT WinPE (inject config + startnet -> HTA + ISO)
# =================================================================
function Invoke-WinPEBuild {
    Write-Status "=== Customizing WinPE ===" -Type Info

    $editParams = @{ Add7Zip = $true }

    if ($CloudDriver)     { $editParams.CloudDriver     = $CloudDriver }
    if ($WirelessConnect) { $editParams.WirelessConnect = $true }

    if ($DriversPath -and (Test-Path $DriversPath)) {
        $inf = @(Get-ChildItem $DriversPath -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue)
        if ($inf.Count -gt 0) {
            $editParams.DriverPath = @($DriversPath)
            Write-Status "$($inf.Count) extra .inf driver(s) found -- injecting" -Type Info
        }
    }

    if ($WallpaperPath -and (Test-Path $WallpaperPath) -and ($WallpaperPath -match '\.jpg$')) {
        $editParams.Wallpaper = Get-Item $WallpaperPath
    }

    # startnet.cmd tail: show HTA menu after WiFi init
    # Do NOT pass -StartOSDCloud -- the HTA owns boot routing
    $editParams.Startnet = 'start /wait mshta.exe "X:\OSDCloud\Config\Scripts\Select-Mode.hta"'

    Edit-OSDCloudWinPE @editParams
    Write-Status "WinPE build and ISO complete" -Type Success
}

# =================================================================
# MAIN
# =================================================================
$sw = [Diagnostics.Stopwatch]::StartNew()
Write-Host ""
Write-Status "=== OSDCloud Recovery Builder -- BAKED-IN  |  Workspace: $Workspace ===" -Type Info
Write-Host ""

Invoke-OSDModuleSetup
Invoke-TemplateSetup
Invoke-WorkspaceSetup
Invoke-RecoveryToolsDownload   # ~15-20 min first run (Chrome ~170MB, Java ~150MB, 7-Zip ~3MB)
Invoke-WriteWinPEScripts
Invoke-WinPEBuild

$sw.Stop()
Write-Host ""
Write-Status "=== Done in $($sw.Elapsed.ToString('hh\:mm\:ss')) ===" -Type Success
Get-ChildItem "$Workspace\*.iso" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Status "ISO: $($_.FullName)  ($([math]::Round($_.Length/1MB,0)) MB)" -Type Info
}
Write-Host ""
