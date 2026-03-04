<#
.SYNOPSIS
Advanced RAM OS Builder with Alternative Shell Support (No Microsoft Explorer)
Creates a Windows PE-based RAM OS using WinPE with alternative file managers.

.DESCRIPTION
Transforms a Windows ISO into a bootable RAM OS using WinPE with Explorer++ as primary shell.
- True RAM operation (WinPE runs from X:\; eject boot media after boot)
- Dell WinPE11 drivers injected
- Explorer++ as primary file manager (no Microsoft Explorer shell)
- Chrome++ (Chrome Plus) with portable validation
- Optional Open-Shell menu
- FBWF optional

.PARAMETER SourceISO
Path to Windows 10/11 ISO (any edition)

.PARAMETER WorkRoot
Build working directory (20GB free required)

.PARAMETER UseChromePlus
Download & integrate Chrome++

.PARAMETER ChromeOfflineInstallerPath
Path to Chrome offline installer (optional)

.PARAMETER ChromePortablePath
Local Chrome portable archive (.zip/.7z/.exe)

.PARAMETER IncludeExplorerPlus
Include Explorer++ file manager (recommended, acts as shell)

.PARAMETER IncludeOpenShell
Include Open-Shell Start Menu (optional)

.PARAMETER IncludeDellDrivers
Inject Dell WinPE 11 driver pack

.PARAMETER WallpaperPath
Custom wallpaper (.jpg/.png/.bmp)

.PARAMETER AccentColor
Hex RGB accent color

.PARAMETER OutputISOName
Output ISO filename

.PARAMETER RamdiskSizeMB
Overlay size for FBWF (if enabled)

.PARAMETER ADKPath
Path to WinPE add-on

.PARAMETER KeepMountedWIM
Preserve mounted WIM on failure

.PARAMETER SkipCleanup
Skip cleanup after build

.PARAMETER WimIndex
1=WinPE, 2=WinPE+Setup (default: 1)

.PARAMETER EnableFBWF
Add WinPE-FBWF OC
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
        $testPath = $_
        if (-not (Test-Path $testPath)) {
            $parent = Split-Path $testPath -Parent
            while ($parent -and -not (Test-Path $parent)) {
                $parent = Split-Path $parent -Parent
            }
            if (-not $parent) { throw "No valid ancestor directory for: $testPath" }
        }
        $resolved = if (Test-Path $testPath) { (Resolve-Path $testPath).Path } else { [IO.Path]::GetFullPath($testPath) }
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
    [Parameter(Mandatory = $false)][switch]$IncludeOpenShell,
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
    [string]$OutputISOName = "RAMOS_AltShell.iso",
    
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
    Stats = @{ Packages = 0; Apps = 0; DriversAdded = 0 }
}

$Script:AppSources = @{
    OpenShellExe = "https://github.com/Open-Shell/Open-Shell-Menu/releases/download/v4.4.196/OpenShellSetup_4_4_196.exe"
    OpenShellExeMirror = "https://sourceforge.net/projects/open-shell.mirror/files/v4.4.196/OpenShellSetup_4_4_196.exe/download"
    SemeruPrimary = "https://github.com/ibmruntimes/semeru8-binaries/releases/download/jdk8u482-b08_openj9-0.57.0/ibm-semeru-open-jdk_x64_windows_8u482b08_openj9-0.57.0.zip"
    SemeruFallback = "https://github.com/ibmruntimes/semeru8-binaries/releases/download/jdk8u472-b08_openj9-0.56.0/ibm-semeru-open-jdk_x64_windows_8u472b08_openj9-0.56.0-portable.zip"
    ExplorerPlusPlus = "https://github.com/derceg/explorerplusplus/releases/download/version-1.4.0/explorerpp_x64.zip"
    ChromePlus = "https://github.com/Bush2021/chrome_plus/releases/download/1.15.1/Chrome++_v1.15.1_x86_x64_arm64.7z"
    DellWinPEDrivers = "https://downloads.dell.com/FOLDER14002062M/1/WinPE11.0-Drivers-A08-2V5TD.cab"
    SevenZipMini = "https://www.7-zip.org/a/7zr.exe"
    SevenZipExtra = "https://www.7-zip.org/a/7z2408-extra.7z"
    SevenZipFull = "https://www.7-zip.org/a/7z2408-x64.exe"
}

$Script:WinPEPackages = @(
    "WinPE-WMI", "WinPE-Scripting", "WinPE-PowerShell", "WinPE-HTA", 
    "WinPE-NetFx", "WinPE-WOW64", "WinPE-Fonts-Legacy", "WinPE-StorageWMI", 
    "WinPE-DismCmdlets", "WinPE-FMAPI", "WinPE-WiFi"
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
        "Error" { "Red" }
        "Warning" { "Yellow" }
        default { "Cyan" }
    }
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
}

# ============================================
# SETUP & CLEANUP
# ============================================
function Initialize-BuildEnvironment {
    Write-BuildLog "Initializing RAM OS Builder (Alternative Shell Edition)..."
    
    if (-not (Test-Path $WorkRoot)) {
        New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    }
    
    $Script:Config.Paths = @{
        Root = (Resolve-Path "$WorkRoot").Path
        ISO = Join-Path "$WorkRoot" "ISO_Source"
        Mount = Join-Path "$WorkRoot" "Mount_WIM"
        Apps = Join-Path "$WorkRoot" "Apps"
        Cache = Join-Path "$WorkRoot" "Cache"
        Output = Join-Path "$WorkRoot" "Output"
        Temp = Join-Path "$WorkRoot" "Temp"
    }
    
    foreach ($p in $Script:Config.Paths.Values) {
        if (-not (Test-Path $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
    }
    
    $Script:Config.LogFile = Join-Path $Script:Config.Paths.Output "Build-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Start-Transcript -Path $Script:Config.LogFile | Out-Null
    
    # Probe ADK + WinPE add-on
    $candidates = @(
        $ADKPath,
        "${env:ProgramFiles(x86)}\Windows Kits\11\Assessment and Deployment Kit\Windows Preinstallation Environment",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    
    if (-not $candidates) {
        throw "Windows ADK WinPE add-on not found. Install ADK + WinPE add-on: https://aka.ms/adk"
    }
    
    $winpeAddOn = $candidates
    $adkRoot = Split-Path $winpeAddOn
    
    $Script:Config.Tools = @{
        DISM = Join-Path $adkRoot "Deployment Tools\AMD64\DISM\dism.exe"
        OSCDIMG = Join-Path $adkRoot "Deployment Tools\AMD64\Oscdimg\oscdimg.exe"
        WinPEOCs = Join-Path $winpeAddOn "amd64\WinPE_OCs"
    }
    
    if (-not (Test-Path $Script:Config.Tools.DISM)) {
        $Script:Config.Tools.DISM = (Get-Command dism.exe -ErrorAction Stop).Source
    }
    if (-not (Test-Path $Script:Config.Tools.OSCDIMG)) {
        throw "OSCDIMG.exe not found in ADK installation"
    }
    if (-not (Test-Path $Script:Config.Tools.WinPEOCs)) {
        throw "WinPE optional components folder not found"
    }
    
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {}
    
    $Script:State = @{
        BootWimMounted = $false
        IsoMounted = $false
    }
    
    Write-BuildLog "Build environment initialized" -Level "Success"
}

function Invoke-Cleanup {
    param([switch]$Preserve)
    Write-BuildLog "Performing cleanup..."
    
    if ($Script:State.BootWimMounted -and -not $Preserve) {
        & $Script:Config.Tools.DISM /Unmount-Image /MountDir:$Script:Config.Paths.Mount /Discard 2>&1 | Out-Null
        $Script:State.BootWimMounted = $false
    }
    
    if ($Script:State.IsoMounted) {
        Get-DiskImage -ImagePath "$SourceISO" -ErrorAction SilentlyContinue | 
            Dismount-DiskImage -ErrorAction SilentlyContinue | Out-Null
        $Script:State.IsoMounted = $false
    }
    
    if (-not $SkipCleanup) {
        Remove-Item $Script:Config.Paths.Apps -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $Script:Config.Paths.Temp -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    Stop-Transcript -ErrorAction SilentlyContinue
}

# ============================================
# ISO & WIM OPERATIONS
# ============================================
function Mount-SourceISO {
    Write-BuildLog "Mounting source ISO..."
    
    $diskImage = Mount-DiskImage -ImagePath "$SourceISO" -PassThru -ErrorAction Stop
    $Script:State.IsoMounted = $true
    
    $vol = $diskImage | Get-Volume
    $letter = $vol.DriveLetter
    
    if (-not (Test-Path "$letter`:\sources\boot.wim")) {
        throw "Invalid ISO: sources\boot.wim not found"
    }
    
    # Check for install.wim or install.esd
    $installFile = if (Test-Path "$letter`:\sources\install.wim") { 
        "install.wim" 
    } elseif (Test-Path "$letter`:\sources\install.esd") { 
        "install.esd" 
    } else { 
        $null 
    }
    
    if (-not $installFile) {
        Write-BuildLog "Warning: Neither install.wim nor install.esd found. Some features may be limited." -Level "Warning"
    }
    
    Write-BuildLog "Extracting ISO contents..."
    $src = "$letter`:\"
    $dst = $Script:Config.Paths.ISO
    
    robocopy $src $dst /E /NFL /NDL /R:0 /W:0 /MT:8 | Out-Null
    if ($LASTEXITCODE -gt 7) {
        throw "Robocopy failed with exit code: $LASTEXITCODE"
    }
    
    Dismount-DiskImage -ImagePath "$SourceISO" | Out-Null
    $Script:State.IsoMounted = $false
    
    return @{
        BootWim = Join-Path $Script:Config.Paths.ISO "sources\boot.wim"
        InstallFile = if ($installFile) { Join-Path $Script:Config.Paths.ISO "sources\$installFile" } else { $null }
        InstallType = $installFile
    }
}

function Mount-TargetWIM {
    param(
        [Parameter(Mandatory)][string]$WimPath,
        [ValidateSet(1,2)][int]$Index = 1
    )
    
    Write-BuildLog "Mounting boot.wim (Index $Index)..."
    & $Script:Config.Tools.DISM /Mount-Image /ImageFile:"$WimPath" /Index:$Index /MountDir:$Script:Config.Paths.Mount | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to mount WIM. Ensure no mount conflicts and sufficient disk space."
    }
    
    $Script:State.BootWimMounted = $true
    
    foreach ($hive in "SYSTEM","SOFTWARE") {
        $p = Join-Path $Script:Config.Paths.Mount "Windows\System32\config\$hive"
        if (-not (Test-Path $p)) {
            throw "$hive hive missing in mounted WIM"
        }
    }
    
    Write-BuildLog "WIM mounted successfully" -Level "Success"
}

function Add-WinPE-Packages {
    Write-BuildLog "Installing WinPE optional components..."
    
    $mount = $Script:Config.Paths.Mount
    $count = 0
    $ocRoot = $Script:Config.Tools.WinPEOCs
    $lang = $Script:Config.Locale
    
    if (-not (Test-Path (Join-Path $ocRoot "$lang"))) {
        $lang = "en-us"
    }
    
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
            Write-BuildLog "Package not found: $pkg (skipped)" -Level Warning
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
        $infCount = (Get-ChildItem -Path $extractDir -Filter *.inf -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($infCount -gt 0) {
            & $Script:Config.Tools.DISM /Add-Driver /Image:$Script:Config.Paths.Mount /Driver:"$extractDir" /Recurse /ForceUnsigned | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $Script:Config.Stats.DriversAdded = $infCount
                Write-BuildLog "Injected $infCount Dell INF drivers" -Level "Success"
            } else {
                Write-BuildLog "DISM /Add-Driver failed for Dell drivers" -Level Warning
            }
        }
    }
}

# ============================================
# APPLICATIONS
# ============================================
function Ensure-7z {
    if (Get-Command 7z -ErrorAction SilentlyContinue) {
        return "7z"
    }
    
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
    
    # Proper quoting for spaces in paths
    $arguments = @("x", "`"$ArchivePath`"", "-o`"$Destination`"", "-y")
    & $seven @arguments | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip extraction failed with code $LASTEXITCODE"
    }
}

function Find-ExeUnder {
    param([string]$Root, [string]$ExeName)
    if (-not (Test-Path $Root)) { return $null }
    Get-ChildItem -Path $Root -Recurse -File -Filter $ExeName -ErrorAction SilentlyContinue | 
        Select-Object -First 1
}

function Assert-ChromePlusLayout {
    param([string]$ChromeRoot)
    
    $chrome = Find-ExeUnder -Root $ChromeRoot -ExeName 'chrome.exe'
    if (-not $chrome) {
        throw "Chrome not found under: $ChromeRoot"
    }
    
    $versionDll = Join-Path $chrome.Directory.FullName 'version.dll'
    if (-not (Test-Path $versionDll)) {
        throw "Chrome++ patch missing: version.dll not found next to chrome.exe"
    }
    
    return $chrome.FullName
}

function Get-Applications {
    Write-BuildLog "Downloading portable applications..."
    $cache = $Script:Config.Paths.Cache
    $apps = $Script:Config.Paths.Apps
    
    # --- Open-Shell (if requested) ---
    if ($IncludeOpenShell) {
        $osExe = Join-Path $cache "OpenShellSetup.exe"
        if (-not (Test-Path $osExe)) {
            try {
                Invoke-WebRequest -Uri $Script:AppSources.OpenShellExe -OutFile $osExe -UseBasicParsing
            } catch {
                Invoke-WebRequest -Uri $Script:AppSources.OpenShellExeMirror -OutFile $osExe -UseBasicParsing
            }
        }
        
        $osDest = Join-Path $apps "OpenShell"
        New-Item -ItemType Directory -Force -Path $osDest | Out-Null
        
        # Try to extract using 7z first (inno setup extraction), fallback to silent install
        try {
            Expand-7z -ArchivePath $osExe -Destination $osDest
        } catch {
            Write-BuildLog "7z extraction failed for Open-Shell, trying silent extraction..." -Level Warning
            $tempExtract = Join-Path $Script:Config.Paths.Temp "OSExtract"
            Start-Process -FilePath $osExe -ArgumentList "/SILENT /ExtractTo=`"$tempExtract`"" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
            if (Test-Path $tempExtract) {
                Copy-Item "$tempExtract\*" $osDest -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        
        if (Test-Path (Join-Path $osDest "StartMenu.exe")) {
            $Script:Config.Apps.OpenShell = $osDest
            Write-BuildLog "Open-Shell prepared" -Level "Success"
        }
    }
    
    # --- 7-Zip portable ---
    Write-BuildLog "Downloading 7-Zip portable..."
    $szDest = Join-Path $apps "7-Zip"
    New-Item -ItemType Directory -Force -Path $szDest | Out-Null
    $szExe = Join-Path $cache "7z-full.exe"
    
    if (-not (Test-Path $szExe)) {
        try {
            Invoke-WebRequest -Uri $Script:AppSources.SevenZipFull -OutFile $szExe -UseBasicParsing
        } catch {
            Write-BuildLog "Downloading 7-Zip extra archive..." -Level Warning
            $szExtra = Join-Path $cache "7z-extra.7z"
            Invoke-WebRequest -Uri $Script:AppSources.SevenZipExtra -OutFile $szExtra -UseBasicParsing
            Expand-7z -ArchivePath $szExtra -Destination $szDest
            $szExe = $null
        }
    }
    
    if ($szExe -and (Test-Path $szExe)) {
        try {
            Start-Process -FilePath $szExe -ArgumentList "/S","/D=$szDest" -Wait -WindowStyle Hidden -ErrorAction Stop
        } catch {
            Expand-7z -ArchivePath $szExe -Destination $szDest
        }
    }
    
    if (Test-Path (Join-Path $szDest "7z.exe")) {
        $Script:Config.Apps.'7-Zip' = $szDest
        Write-BuildLog "7-Zip prepared" -Level "Success"
    }
    
    # --- IBM Semeru Java ---
    $jvZip = Join-Path $cache "Semeru.zip"
    if (-not (Test-Path $jvZip)) {
        try {
            Invoke-WebRequest -Uri $Script:AppSources.SemeruPrimary -OutFile $jvZip -UseBasicParsing
        } catch {
            Invoke-WebRequest -Uri $Script:AppSources.SemeruFallback -OutFile $jvZip -UseBasicParsing
        }
    }
    
    $javaRoot = Join-Path $apps "Java"
    Expand-Archive $jvZip $javaRoot -Force
    
    # Flatten nested folder
    $nested = Get-ChildItem -Path $javaRoot -Directory | Where-Object { 
        Test-Path (Join-Path $_.FullName 'bin') 
    } | Select-Object -First 1
    
    if ($nested) {
        Get-ChildItem -Path $nested.FullName -Force | Move-Item -Destination $javaRoot -Force
        Remove-Item $nested.FullName -Force -ErrorAction SilentlyContinue
    }
    
    if (Test-Path (Join-Path $javaRoot "bin\java.exe")) {
        $Script:Config.Apps.Java = $javaRoot
    }
    
    # --- Explorer++ portable (Primary File Manager) ---
    $epZip = Join-Path $cache "ExplorerPP.zip"
    if (-not (Test-Path $epZip)) {
        Invoke-WebRequest -Uri $Script:AppSources.ExplorerPlusPlus -OutFile $epZip -UseBasicParsing
    }
    
    $epDest = Join-Path $apps "ExplorerPP"
    Expand-Archive $epZip $epDest -Force
    
    $epExe = Find-ExeUnder -Root $epDest -ExeName "Explorer++.exe"
    if ($epExe) {
        $Script:Config.Apps.ExplorerPP = $epDest
        Write-BuildLog "Explorer++ prepared (will be used as shell)" -Level "Success"
    } else {
        throw "Explorer++ extraction failed - executable not found"
    }
    
    # --- Chrome (Chrome++ or portable) ---
    if ($UseChromePlus) {
        Write-BuildLog "Downloading Chrome Plus..."
        $cp7z = Join-Path $cache "ChromePlus.7z"
        if (-not (Test-Path $cp7z)) {
            Invoke-WebRequest -Uri $Script:AppSources.ChromePlus -OutFile $cp7z -UseBasicParsing
        }
        
        $chPath = Join-Path $apps "Chrome"
        Expand-7z -ArchivePath $cp7z -Destination $chPath
        
        if (-not (Find-ExeUnder -Root $chPath -ExeName 'chrome.exe')) {
            if ($ChromeOfflineInstallerPath) {
                Write-BuildLog "Extracting Chrome from offline installer..."
                $tempChrome = Join-Path $Script:Config.Paths.Temp "ChromeExtract"
                try {
                    Expand-7z -ArchivePath $ChromeOfflineInstallerPath -Destination $tempChrome
                } catch {
                    Start-Process -FilePath $ChromeOfflineInstallerPath -ArgumentList "--silent-install","--install-dir=`"$tempChrome`"" -Wait -WindowStyle Hidden
                }
                
                if (Test-Path $tempChrome) {
                    Copy-Item "$tempChrome\*" (Join-Path $chPath "App") -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-Item $tempChrome -Recurse -Force -ErrorAction SilentlyContinue
                }
            } else {
                Write-BuildLog "Chrome++ missing chrome.exe and no offline installer provided" -Level "Warning"
            }
        }
        
        if (Find-ExeUnder -Root $chPath -ExeName 'chrome.exe') {
            $Script:Config.Apps.ChromeExe = Assert-ChromePlusLayout -ChromeRoot $chPath
            $Script:Config.Apps.Chrome = $chPath
        }
    } elseif ($ChromePortablePath) {
        $chDest = Join-Path $apps "Chrome"
        $ext = [System.IO.Path]::GetExtension("$ChromePortablePath").ToLower()
        
        if ($ext -eq ".zip") {
            Expand-Archive "$ChromePortablePath" "$chDest" -Force
        } elseif ($ext -eq ".7z") {
            Expand-7z -ArchivePath "$ChromePortablePath" -Destination "$chDest"
        } elseif ($ext -eq ".exe") {
            try {
                Start-Process -FilePath "$ChromePortablePath" -ArgumentList "/S","/D=$chDest" -Wait -WindowStyle Hidden
            } catch {
                Expand-7z -ArchivePath "$ChromePortablePath" -Destination "$chDest"
            }
        }
        
        $chrome = Find-ExeUnder -Root $chDest -ExeName 'chrome.exe'
        if ($chrome) {
            $Script:Config.Apps.ChromeExe = $chrome.FullName
            $Script:Config.Apps.Chrome = $chDest
        }
    }
}

function Inject-AllApps {
    Write-BuildLog "Injecting applications into WIM image..."
    $progFiles = Join-Path $Script:Config.Paths.Mount "Program Files\PortableApps"
    New-Item -Path $progFiles -ItemType Directory -Force | Out-Null
    
    foreach ($app in $Script:Config.Apps.GetEnumerator()) {
        if ($app.Key -eq 'ChromeExe') { continue }
        
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
# REGISTRY CONFIGURATION
# ============================================
function Configure-SystemRegistry {
    Write-BuildLog "Configuring Registry..."
    $mount = $Script:Config.Paths.Mount
    $sysPath = Join-Path "$mount" "Windows\System32\config\SYSTEM"
    $softPath = Join-Path "$mount" "Windows\System32\config\SOFTWARE"
    
    reg load "HKLM\RAM_SYS" "$sysPath" | Out-Null
    reg load "HKLM\RAM_SW" "$softPath" | Out-Null
    
    try {
        # Check if Microsoft Explorer exists in the image
        $explorerPath = Join-Path $mount "Windows\explorer.exe"
        $hasExplorer = Test-Path $explorerPath
        
        if ($hasExplorer) {
            # Only set explorer.exe if it actually exists (user might have added it manually)
            reg add "HKLM\RAM_SW\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /t REG_SZ /d "explorer.exe" /f | Out-Null
            Write-BuildLog "Shell set to explorer.exe (found in image)" -Level "Info"
        } else {
            # No explorer - WinPE will use winpeshl.ini exclusively
            Write-BuildLog "No explorer.exe found - relying on winpeshl.ini for shell" -Level "Info"
            # Clear shell value to prevent errors
            reg add "HKLM\RAM_SW\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /t REG_SZ /d "" /f | Out-Null
        }
        
        # Environment variables
        if ($Script:Config.Apps.ContainsKey("Java")) {
            $javaInstall = "C:\Program Files\PortableApps\Java"
            reg add "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v JAVA_HOME /t REG_SZ /d "$javaInstall" /f | Out-Null
            
            $currentPath = (reg query "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v Path 2>$null | 
                Select-String "REG_EXPAND_SZ|REG_SZ" | 
                ForEach-Object { $_.Line -replace '^\s*\S+\s+(REG_\S+)\s+', '' }) -join ''
            
            if ($currentPath) {
                reg add "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v Path /t REG_EXPAND_SZ /d "$currentPath;$javaInstall\bin" /f | Out-Null
            }
        }
        
        if ($Script:Config.Apps.ContainsKey("7-Zip")) {
            $szInstall = "C:\Program Files\PortableApps\7-Zip"
            $currentPath = (reg query "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v Path 2>$null | 
                Select-String "REG_EXPAND_SZ|REG_SZ" | 
                ForEach-Object { $_.Line -replace '^\s*\S+\s+(REG_\S+)\s+', '' }) -join ''
            
            if ($currentPath) {
                reg add "HKLM\RAM_SYS\ControlSet001\Control\Session Manager\Environment" /v Path /t REG_EXPAND_SZ /d "$currentPath;$szInstall" /f | Out-Null
            }
        }
        
        # Explorer++ context menu
        if ($IncludeExplorerPlus -and $Script:Config.Apps.ContainsKey("ExplorerPP")) {
            reg add "HKLM\RAM_SW\Classes\Directory\shell\ExplorerPP" /ve /d "Open with Explorer++" /f | Out-Null
            reg add "HKLM\RAM_SW\Classes\Directory\shell\ExplorerPP\command" /ve /d "C:\Program Files\PortableApps\ExplorerPP\Explorer++.exe `"%1`"" /f | Out-Null
        }
        
        if ($EnableFBWF) {
            reg add "HKLM\RAM_SYS\ControlSet001\Control\FBWF" /v OverlaySize /t REG_DWORD /d $RamdiskSizeMB /f | Out-Null
        }
    } finally {
        reg unload "HKLM\RAM_SYS" | Out-Null
        reg unload "HKLM\RAM_SW" | Out-Null
    }
    
    Write-BuildLog "Registry configured" -Level "Success"
}

# ============================================
# SHELL & STARTUP SCRIPTS
# ============================================
function Create-StartupScript {
    Write-BuildLog "Creating StartNet.cmd..."
    $mount = $Script:Config.Paths.Mount
    
    $content = @'
@echo off
echo ==========================================
echo RAM OS - Initializing WinPE
echo ==========================================
wpeinit
wpeutil InitializeNetwork
wpeutil WaitForNetwork
wpeutil DisableFirewall
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
    $wallValue = if ($wall) { $wall } else { "" }
    
    $content = @"
@echo off
REM Post-shell configuration
if exist "%SystemRoot%\System32\reg.exe" (
    if not "$wallValue"=="" if exist "$wallValue" (
        reg add "HKCU\Control Panel\Desktop" /v Wallpaper /t REG_SZ /d "$wallValue" /f
        rundll32.exe user32.dll,UpdatePerUserSystemParameters
    )
    reg add "HKCU\Software\Microsoft\Windows\DWM" /v ColorPrevalence /t REG_DWORD /d 1 /f >nul 2>&1
    reg add "HKCU\Software\Microsoft\Windows\DWM" /v AccentColor /t REG_DWORD /d 0x$AccentColor /f >nul 2>&1
)
exit /b 0
"@
    
    Set-Content -Path (Join-Path $postDir "PostShell.cmd") -Value $content -Encoding ASCII -Force
    Write-BuildLog "PostShell.cmd created" -Level "Success"
}

function Create-ChromeLauncher {
    if (-not $Script:Config.Apps.ChromeExe) { return }
    
    Write-BuildLog "Creating Chrome launcher..."
    $mount = $Script:Config.Paths.Mount
    $tools = Join-Path $mount "Windows\System32\RAMOS"
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    
    $buildAppsRoot = $Script:Config.Paths.Apps
    $runtimeAppsRoot = "C:\Program Files\PortableApps"
    $chromeExeRuntime = $Script:Config.Apps.ChromeExe -replace [regex]::Escape($buildAppsRoot), $runtimeAppsRoot
    
    $content = @"
@echo off
set "PROFILE=X:\ChromeProfile"
set "CACHE=X:\ChromeCache"
if not exist "%PROFILE%" mkdir "%PROFILE%"
if not exist "%CACHE%" mkdir "%CACHE%"
start "" "$chromeExeRuntime" --user-data-dir="%PROFILE%" --disk-cache-dir="%CACHE%" --no-first-run --no-default-browser-check
exit /b 0
"@
    
    Set-Content -Path (Join-Path $tools "StartChrome.cmd") -Value $content -Encoding ASCII -Force
}

function Write-Winpeshl {
    Write-BuildLog "Writing winpeshl.ini (Alternative Shell)..."
    $mount = $Script:Config.Paths.Mount
    $iniPath = Join-Path $mount "Windows\System32\winpeshl.ini"
    $launch = @("[LaunchApps]")
    
    $mountedBase = Join-Path $mount "Program Files\PortableApps"
    $runtimeBase = "C:\Program Files\PortableApps"
    
    # Primary Shell: Explorer++ (The alternative file manager)
    $epExe = Find-ExeUnder -Root (Join-Path $mountedBase "ExplorerPP") -ExeName "Explorer++.exe"
    if ($epExe) {
        $runtimePath = $epExe.FullName -replace [regex]::Escape($mount), "C:"
        $launch += "`"$runtimePath`""
        Write-BuildLog "Setting Explorer++ as primary shell" -Level "Success"
    } else {
        # Fallback to cmd.exe if Explorer++ not found (shouldn't happen)
        $launch += "cmd.exe"
        Write-BuildLog "Warning: Explorer++ not found, using cmd.exe" -Level "Warning"
    }
    
    # Open-Shell (Start Menu) - launched after shell
    if ($IncludeOpenShell -and $Script:Config.Apps.ContainsKey("OpenShell")) {
        $osExe = Find-ExeUnder -Root (Join-Path $mountedBase "OpenShell") -ExeName "StartMenu.exe"
        if ($osExe) {
            $runtimePath = $osExe.FullName -replace [regex]::Escape($mount), "C:"
            $launch += "`"$runtimePath`""
        }
    }
    
    # Chrome
    if (Test-Path (Join-Path $mount "Windows\System32\RAMOS\StartChrome.cmd")) {
        $launch += '"%SystemRoot%\System32\RAMOS\StartChrome.cmd"'
    }
    
    # Post-configuration
    $launch += '"%SystemRoot%\System32\RAMOS\PostShell.cmd"'
    
    Set-Content -Path $iniPath -Value ($launch -join "`r`n") -Encoding ASCII -Force
    Write-BuildLog "winpeshl.ini written with alternative shell" -Level "Success"
}

# ============================================
# ISO BUILD
# ============================================
function Build-FinalISO {
    Write-BuildLog "Building final ISO image..."
    
    $mount = $Script:Config.Paths.Mount
    $isoSource = $Script:Config.Paths.ISO
    
    & $Script:Config.Tools.DISM /Unmount-Image /MountDir:"$mount" /Commit | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to commit WIM changes"
    }
    
    $Script:State.BootWimMounted = $false
    
    $outputPath = Join-Path $Script:Config.Paths.Output "$OutputISOName"
    $bootFile = Join-Path "$isoSource" "boot\etfsboot.com"
    $efiFile = Join-Path "$isoSource" "efi\Microsoft\boot\efisys_noprompt.bin"
    
    if (-not (Test-Path $efiFile)) {
        $efiFile = Join-Path "$isoSource" "efi\Microsoft\boot\efisys.bin"
    }
    
    if (-not (Test-Path "$bootFile")) {
        throw "Boot sector file not found: $bootFile"
    }
    
    $label = [System.IO.Path]::GetFileNameWithoutExtension($OutputISOName)
    $argList = @("-m","-o","-u2","-udfver102","-l$label")
    
    if (Test-Path "$efiFile") {
        $bootData = ('-bootdata:2#p0,e,b"{0}"#pEF,e,b"{1}"' -f "$bootFile","$efiFile")
        $argList += $bootData
    } else {
        $argList += "-b$bootFile"
    }
    
    $argList += @("$isoSource","$outputPath")
    
    & $Script:Config.Tools.OSCDIMG @argList
    if ($LASTEXITCODE -ne 0) {
        throw "OSCDIMG failed to create ISO (exit $LASTEXITCODE)"
    }
    
    return $outputPath
}

# ============================================
# MAIN EXECUTION
# ============================================
try {
    Initialize-BuildEnvironment
    
    $isoInfo = Mount-SourceISO
    $bootWim = $isoInfo.BootWim
    
    try {
        Copy-Item $bootWim "$($bootWim).bak" -Force
    } catch {}
    
    Mount-TargetWIM -WimPath "$bootWim" -Index $WimIndex
    Add-WinPE-Packages
    Add-DellDrivers
    Get-Applications      # Downloads apps including Explorer++
    Inject-AllApps        # Injects apps into WIM
    Configure-SystemRegistry
    Create-PostShellScript
    Create-ChromeLauncher
    Write-Winpeshl        # Creates winpeshl.ini with Explorer++ as shell
    Create-StartupScript
    
    $finalIso = Build-FinalISO
    
    # Summary
    Write-BuildLog "BUILD COMPLETED SUCCESSFULLY" -Level "Success"
    Write-BuildLog "Output: $finalIso" -Level "Success"
    Write-BuildLog ("Size: {0} MB" -f ([math]::Round((Get-Item $finalIso).Length / 1MB, 2))) -Level "Success"
    
    Write-Host "`n=========================================" -ForegroundColor Green
    Write-Host "RAM OS Build Summary (Alternative Shell)" -ForegroundColor Green
    Write-Host "=========================================" -ForegroundColor Green
    Write-Host "Output File: $finalIso" -ForegroundColor White
    Write-Host "Packages: $($Script:Config.Stats.Packages)" -ForegroundColor Gray
    Write-Host "Apps Injected: $($Script:Config.Stats.Apps)" -ForegroundColor Gray
    Write-Host "Drivers: $($Script:Config.Stats.DriversAdded)" -ForegroundColor Gray
    Write-Host "`nShell: Explorer++ (Alternative File Manager)" -ForegroundColor Cyan
    if ($IncludeOpenShell) { Write-Host "Start Menu: Open-Shell" -ForegroundColor Cyan }
    if ($Script:Config.Apps.ContainsKey("Chrome")) { Write-Host "Browser: Chrome++" -ForegroundColor Cyan }
    Write-Host "`nBoot Instructions:" -ForegroundColor Yellow
    Write-Host "1. Boot ISO/USB - WinPE loads to X:\" -ForegroundColor White
    Write-Host "2. Explorer++ starts as file manager" -ForegroundColor White
    Write-Host "3. Media can be ejected after boot" -ForegroundColor White
    Write-Host "=========================================" -ForegroundColor Green
    
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
