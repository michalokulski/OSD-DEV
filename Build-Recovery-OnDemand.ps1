# =================================================================
# OSDCloud Recovery Builder — ON-DEMAND Tools Edition
# =================================================================
# NO tools are downloaded at build time. The WIM is lighter.
# When the user selects "Windows Recovery OS" in the HTA menu,
# Start-RecoveryMode-OnDemand.ps1 runs inside WinPE and downloads
# Chrome, 7-Zip, and Java Semeru 8 live into the X:\ RAM disk.
#
# IMPORTANT: Requires ~350 MB free on X:\ (RAM disk).
#            Machine should have at least 4 GB RAM.
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

    # --- Download URLs embedded into the runtime WinPE script ---
    # Chrome: uncompressed installer
    [string]   $ChromeUrl     = "https://github.com/Bush2021/chrome_installer/releases/download/145.0.7632.117/x64_145.0.7632.117_chrome_installer_uncompressed.exe",
    # 7-Zip installer SFX
    [string]   $SevenZipUrl   = "https://www.7-zip.org/a/7z2409-x64.exe",
    # IBM Semeru JRE 8 LTS (OpenJ9)
    [string]   $JavaUrl       = "https://github.com/ibmruntimes/semeru8-binaries/releases/download/jdk8u482-b08.1_openj9-0.57.0/ibm-semeru-open-jre_x64_windows_8.0.482.1.zip"
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
# STEP 4 - WRITE WinPE SCRIPTS -> $Workspace\Config\Scripts\
# OSD Robocopy's these into X:\OSDCloud\Config\Scripts\ in the WIM.
# =================================================================
function Invoke-WriteWinPEScripts {
    $scriptsDir = "$Workspace\Config\Scripts"
    New-Item $scriptsDir -ItemType Directory -Force | Out-Null

    # ---- Build the Start-OSDCloud argument string (expanded at BUILD time) --
    $osdArgs = "-OSName '$OSName' -OSLanguage $OSLanguage -OSEdition $OSEdition -OSActivation $OSActivation -ZTI -Restart"

    # ---- Select-Mode.hta -- identical to BakedIn variant ------------------
    # Double-quoted here-string: $osdArgs expanded at BUILD time by PowerShell.
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
    <span class="btn-title">Recovery Dashboard</span>
    <span class="btn-desc">Chrome, 7-Zip, Java Semeru 8<br>PowerShell, CMD, Tools</span>
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
    sh.Run("PowerShell -NoLogo -File \"X:\\OSDCloud\\Config\\Scripts\\Start-RecoveryMode-OnDemand.ps1\"", 1, false);
    window.close();
}
</script>
</body>
</html>
"@
    Set-Content "$scriptsDir\Select-Mode.hta" -Value $hta -Encoding UTF8
    Write-Status "Select-Mode.hta written" -Type Success

    # ---- Start-RecoveryMode-OnDemand.ps1 ----------------------------------
    # Double-quoted here-string: URL variables ($ChromeUrl etc.) are expanded
    # at BUILD TIME so the URLs are hardcoded into the WinPE script.
    # Runtime variables (paths like X:\...) use backtick-escaped $ so they
    # are written literally and evaluated inside WinPE.
    $onDemandPs1 = @"
# =============================================================
# Start-RecoveryMode-OnDemand.ps1  --  runs inside WinPE at boot
# Downloads tools live from the internet into X:\RecoveryTools\
# Requires: network connection, ~350 MB free on X:\ RAM disk
# =============================================================

# ---- RAM check ---------------------------------------------------
`$ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
if (`$ram -lt 4) {
    Write-Warning "Only `${ram} GB RAM detected. Downloading ~350 MB into X:\ may exhaust the RAM disk."
    Write-Warning "Press Ctrl+C within 10 seconds to abort..."
    Start-Sleep -Seconds 10
}

`$toolsBase = "X:\RecoveryTools"
New-Item `$toolsBase -ItemType Directory -Force | Out-Null

# ---- Download helper ----------------------------------------------
function Invoke-PEDownload {
    param([string]`$Url, [string]`$OutFile, [string]`$Label)
    Write-Host "[DL]   `$Label ..."
    `$ProgressPreference = 'SilentlyContinue'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri `$Url -OutFile `$OutFile -UseBasicParsing -TimeoutSec 600
        `$mb = [math]::Round((Get-Item `$OutFile).Length / 1MB, 1)
        Write-Host "[OK]   `$Label (`$mb MB)"
    } catch {
        Write-Host "[ERR]  `$Label failed: `$_"
    }
}

# =================================================================
# 7-Zip
# NOTE: X:\Windows\System32\7za.exe is already in the WIM (from -Add7Zip)
# We extract 7zFM.exe so the user has a GUI file manager.
# =================================================================
Write-Host ""
Write-Host "=== Downloading 7-Zip ===" -ForegroundColor Cyan
`$sevenZipDir = "`$toolsBase\7zip"
New-Item `$sevenZipDir -ItemType Directory -Force | Out-Null
`$sevenZipInst = "`$toolsBase\7zip-installer.exe"
Invoke-PEDownload "$SevenZipUrl" `$sevenZipInst "7-Zip installer"
if (Test-Path `$sevenZipInst) {
    `$tmp7z = "`$toolsBase\7zip_ext"
    New-Item `$tmp7z -ItemType Directory -Force | Out-Null
    # 7za.exe is pre-installed at X:\Windows\System32\7za.exe by OSD -Add7Zip
    & "X:\Windows\System32\7za.exe" x `$sevenZipInst -o"`$tmp7z" -y 2>&1 | Out-Null
    foreach (`$f in @('7z.exe','7z.dll','7zFM.exe','7zG.exe','7-zip.dll')) {
        `$src = Join-Path `$tmp7z `$f
        if (Test-Path `$src) { Copy-Item `$src `$sevenZipDir -Force }
    }
    Remove-Item `$tmp7z       -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item `$sevenZipInst         -Force -ErrorAction SilentlyContinue
    Write-Host "[OK]   7-Zip ready"
}

# =================================================================
# Google Chrome
# =================================================================
Write-Host ""
Write-Host "=== Downloading Chrome ===" -ForegroundColor Cyan
`$chromeDir = "`$toolsBase\chrome"
New-Item `$chromeDir -ItemType Directory -Force | Out-Null
`$chromeInst = "`$toolsBase\chrome_installer.exe"
Invoke-PEDownload "$ChromeUrl" `$chromeInst "Chrome installer"
if (Test-Path `$chromeInst) {
    `$tmpChrome = "`$toolsBase\chrome_ext"
    New-Item `$tmpChrome -ItemType Directory -Force | Out-Null
    & "X:\Windows\System32\7za.exe" x `$chromeInst -o"`$tmpChrome" -y 2>&1 | Out-Null
    `$chrome7z = Get-ChildItem `$tmpChrome -Recurse -Filter 'chrome.7z' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (`$chrome7z) {
        & "X:\Windows\System32\7za.exe" x `$chrome7z.FullName -o"`$tmpChrome\inner" -y 2>&1 | Out-Null
    }
    `$chromeBin = Get-ChildItem `$tmpChrome -Recurse -Directory -Filter 'Chrome-bin' `
                     -ErrorAction SilentlyContinue | Select-Object -First 1
    if (`$chromeBin) {
        Copy-Item "`$(`$chromeBin.FullName)\*" `$chromeDir -Recurse -Force
        Write-Host "[OK]   Chrome ready (from Chrome-bin)"
    } else {
        `$chromeExeBin = Get-ChildItem `$tmpChrome -Recurse -Filter 'chrome.exe' `
                            -ErrorAction SilentlyContinue | Select-Object -First 1
        if (`$chromeExeBin) {
            Copy-Item (Split-Path `$chromeExeBin.FullName -Parent) -Destination `$chromeDir -Recurse -Force
            Write-Host "[WARN] Chrome ready (fallback layout)"
        } else {
            Write-Host "[ERR]  Chrome extraction failed"
        }
    }
    Remove-Item `$tmpChrome  -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item `$chromeInst          -Force -ErrorAction SilentlyContinue

    '{"distribution":{"suppress_first_run_bubble":true,"do_not_launch_chrome":true,"make_chrome_default":false,"suppress_first_run_default_browser_prompt":true},"first_run_tabs":["about:blank"]}' |
        Set-Content "`$chromeDir\master_preferences" -Encoding UTF8
}

# =================================================================
# IBM Semeru JRE 8 LTS (OpenJ9)
# =================================================================
Write-Host ""
Write-Host "=== Downloading IBM Semeru JRE 8 ===" -ForegroundColor Cyan
`$javaDir = "`$toolsBase\java"
New-Item `$javaDir -ItemType Directory -Force | Out-Null
`$javaZip = "`$toolsBase\semeru-jre8.zip"
Invoke-PEDownload "$JavaUrl" `$javaZip "IBM Semeru JRE 8 (OpenJ9)"
if (Test-Path `$javaZip) {
    Expand-Archive -Path `$javaZip -DestinationPath `$javaDir -Force
    Remove-Item `$javaZip -Force -ErrorAction SilentlyContinue
    `$inner = Get-ChildItem `$javaDir -Directory | Select-Object -First 1
    if (`$inner) {
        Get-ChildItem `$inner.FullName | Move-Item -Destination `$javaDir -Force
        Remove-Item `$inner.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "[OK]   IBM Semeru JRE 8 ready"
}

# =================================================================
# Set environment variables and launch Recovery Dashboard
# =================================================================
Write-Host ""
Write-Host "=== Configuring Environment ===" -ForegroundColor Cyan

# Expose Java + tools on PATH for any child processes
[Environment]::SetEnvironmentVariable("JAVA_HOME", "`$toolsBase\java", "Machine")
[Environment]::SetEnvironmentVariable(
    "PATH",
    "`$toolsBase\java\bin;`$toolsBase\chrome;`$toolsBase\7zip;`$env:PATH",
    "Machine"
)
Write-Host "[OK]   JAVA_HOME and PATH configured"

# Launch the Recovery Dashboard
Write-Host "[OK]   Launching Recovery Dashboard..." -ForegroundColor Green
Start-Process "mshta.exe" -ArgumentList "`"`"X:\OSDCloud\Config\Scripts\Recovery-Dashboard.hta`"`""
"@
    Set-Content "$scriptsDir\Start-RecoveryMode-OnDemand.ps1" -Value $onDemandPs1 -Encoding UTF8
    Write-Status "Start-RecoveryMode-OnDemand.ps1 written" -Type Success

    # ---- Recovery-Dashboard.hta ---------------------------------------------
    # Persistent launcher HTA — serves as the "desktop" in WinPE.
    # Double-quoted here-string: $osdArgs is expanded at BUILD TIME.
    $toolsPath = "X:\RecoveryTools"
    $dashboardHta = @"
<html>
<head>
<title>Recovery Dashboard</title>
<HTA:APPLICATION BORDER="thin" BORDERSTYLE="normal" CAPTION="yes"
    MAXIMIZEBUTTON="yes" MINIMIZEBUTTON="yes" SYSMENU="yes"
    SCROLL="no" SINGLEINSTANCE="yes" ICON=""/>
<style>
* { margin:0; padding:0; box-sizing:border-box; }
body {
    font-family: 'Segoe UI', Tahoma, sans-serif;
    background: #0f1117;
    color: #e0e0e0;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 30px 20px 16px;
}
h1 { font-size:22px; color:#90caf9; margin-bottom:4px; letter-spacing:1px; }
.sub { font-size:11px; color:#555; margin-bottom:28px; }
.grid {
    display: flex; flex-wrap: wrap; gap: 16px;
    justify-content: center; max-width: 880px;
}
.card {
    width: 200px; height: 120px; border: none; border-radius: 10px;
    cursor: pointer; display: flex; flex-direction: column;
    align-items: center; justify-content: center; gap: 6px;
    transition: opacity 0.15s;
}
.card:hover { opacity: 0.88; }
.card:active { opacity: 0.75; }
.card-icon { font-size: 28px; }
.card-title { font-size: 14px; font-weight: 700; }
.card-desc { font-size: 10px; opacity: 0.7; text-align: center; padding: 0 8px; }

.c-blue    { background: #1565c0; color: #fff; }
.c-green   { background: #2e7d32; color: #fff; }
.c-orange  { background: #e65100; color: #fff; }
.c-purple  { background: #6a1b9a; color: #fff; }
.c-teal    { background: #00695c; color: #fff; }
.c-grey    { background: #37474f; color: #fff; }
.c-red     { background: #b71c1c; color: #fff; }
.c-indigo  { background: #283593; color: #fff; }

.status {
    margin-top: auto; padding-top: 16px;
    font-size: 11px; color: #555; text-align: center;
}
</style>
</head>
<body>
<h1>RECOVERY DASHBOARD</h1>
<p class="sub">Launch tools from this panel. This window stays open.</p>
<div class="grid">
  <button class="card c-blue" onclick="LaunchChrome()">
    <span class="card-icon">&#127760;</span>
    <span class="card-title">Chrome</span>
    <span class="card-desc">Web Browser</span>
  </button>
  <button class="card c-green" onclick="Launch7Zip()">
    <span class="card-icon">&#128451;</span>
    <span class="card-title">7-Zip</span>
    <span class="card-desc">File Manager</span>
  </button>
  <button class="card c-orange" onclick="LaunchJava()">
    <span class="card-icon">&#9749;</span>
    <span class="card-title">Java Prompt</span>
    <span class="card-desc">Semeru 8 + JAVA_HOME</span>
  </button>
  <button class="card c-purple" onclick="LaunchPowerShell()">
    <span class="card-icon">&#9889;</span>
    <span class="card-title">PowerShell</span>
    <span class="card-desc">Windows PowerShell</span>
  </button>
  <button class="card c-teal" onclick="LaunchCmd()">
    <span class="card-icon">&#128421;</span>
    <span class="card-title">Command Prompt</span>
    <span class="card-desc">cmd.exe</span>
  </button>
  <button class="card c-grey" onclick="LaunchNotepad()">
    <span class="card-icon">&#128196;</span>
    <span class="card-title">Notepad</span>
    <span class="card-desc">Text Editor</span>
  </button>
  <button class="card c-red" onclick="LaunchDiskpart()">
    <span class="card-icon">&#128439;</span>
    <span class="card-title">Disk Management</span>
    <span class="card-desc">diskpart</span>
  </button>
  <button class="card c-indigo" onclick="LaunchLIBR()">
    <span class="card-icon">&#128187;</span>
    <span class="card-title">LIBR Deploy</span>
    <span class="card-desc">OSD Cloud GUI</span>
  </button>
</div>
<div class="status" id="statusBar">Loading system info...</div>
<script language="JScript">
var TOOLS = "$toolsPath";
var sh = new ActiveXObject("WScript.Shell");

window.onload = function() {
    var w = 900, h = 580;
    self.resizeTo(w, h);
    self.moveTo(Math.round((screen.width  - w) / 2),
                Math.round((screen.height - h) / 2));
    try {
        var wmi = GetObject("winmgmts:\\\\.\\root\\cimv2");
        var cs = wmi.ExecQuery("SELECT TotalPhysicalMemory FROM Win32_ComputerSystem");
        var ram = "";
        var e = new Enumerator(cs);
        if (!e.atEnd()) { ram = (e.item().TotalPhysicalMemory / 1073741824).toFixed(1); }
        var os = wmi.ExecQuery("SELECT Caption FROM Win32_OperatingSystem");
        var osName = "";
        var e2 = new Enumerator(os);
        if (!e2.atEnd()) { osName = e2.item().Caption; }
        var net = wmi.ExecQuery("SELECT * FROM Win32_NetworkAdapterConfiguration WHERE IPEnabled = True");
        var ip = "No network";
        var e3 = new Enumerator(net);
        if (!e3.atEnd()) {
            var addrs = e3.item().IPAddress;
            if (addrs) { ip = addrs(0); }
        }
        document.getElementById("statusBar").innerHTML =
            osName + " &nbsp;|&nbsp; RAM: " + ram + " GB &nbsp;|&nbsp; IP: " + ip;
    } catch(ex) {
        document.getElementById("statusBar").innerHTML = "System info unavailable";
    }
};

function LaunchChrome() {
    sh.Run('"' + TOOLS + '\\chrome\\chrome.exe" --no-first-run --no-default-browser-check --disable-sync --disable-gpu --user-data-dir="' + TOOLS + '\\chrome\\profile"', 1, false);
}
function Launch7Zip() {
    sh.Run('"' + TOOLS + '\\7zip\\7zFM.exe"', 1, false);
}
function LaunchJava() {
    sh.Run('cmd.exe /k "set JAVA_HOME=' + TOOLS + '\\java&& set PATH=%JAVA_HOME%\\bin;%PATH%&& java -version"', 1, false);
}
function LaunchPowerShell() {
    sh.Run("powershell.exe", 1, false);
}
function LaunchCmd() {
    sh.Run("cmd.exe", 1, false);
}
function LaunchNotepad() {
    sh.Run("notepad.exe", 1, false);
}
function LaunchDiskpart() {
    sh.Run('cmd.exe /k diskpart', 1, false);
}
function LaunchLIBR() {
    sh.Run('PowerShell -NoLogo -NoExit -Command "Import-Module OSD -Force; Start-OSDCloudGUI"', 1, false);
}
</script>
</body>
</html>
"@
    Set-Content "$scriptsDir\Recovery-Dashboard.hta" -Value $dashboardHta -Encoding UTF8
    Write-Status "Recovery-Dashboard.hta written" -Type Success
}

# =================================================================
# STEP 5 - EDIT WinPE (inject config + startnet -> HTA + ISO)
# =================================================================
function Invoke-WinPEBuild {
    Write-Status "=== Customizing WinPE ===" -Type Info

    $editParams = @{ Add7Zip = $true }  # 7za.exe pre-installed; on-demand script uses it for extraction

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
    $editParams.Startnet = 'start /wait mshta.exe "X:\OSDCloud\Config\Scripts\Select-Mode.hta"'

    Edit-OSDCloudWinPE @editParams
    Write-Status "WinPE build and ISO complete" -Type Success
}

# =================================================================
# MAIN
# =================================================================
$sw = [Diagnostics.Stopwatch]::StartNew()
Write-Host ""
Write-Status "=== OSDCloud Recovery Builder -- ON-DEMAND  |  Workspace: $Workspace ===" -Type Info
Write-Host ""

Invoke-OSDModuleSetup
Invoke-TemplateSetup
Invoke-WorkspaceSetup
# No tool download here -- tools are fetched at WinPE boot time
Invoke-WriteWinPEScripts
Invoke-WinPEBuild

$sw.Stop()
Write-Host ""
Write-Status "=== Done in $($sw.Elapsed.ToString('hh\:mm\:ss')) ===" -Type Success
Get-ChildItem "$Workspace\*.iso" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Status "ISO: $($_.FullName)  ($([math]::Round($_.Length/1MB,0)) MB)" -Type Info
}
Write-Host ""
