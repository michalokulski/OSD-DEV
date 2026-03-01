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
    [switch]   $WirelessConnect ,

    # --- Optional extras ---
    [string]   $DriversPath   = "$PSScriptRoot\Drivers",
    [string]   $WallpaperPath = "",          # must be .jpg
    [switch]   $ForceTemplate,
    [string]   $StagingPath   = "C:\BuildPayload",

    # --- Optional GUI dependency pack (recreated from install.wim) ---
    [switch]   $BuildGuiShellPack,
    [string]   $InstallWimPath = "",
    [string]   $InstallMediaPath = "",
    [switch]   $AutoAcquireInstallWim = $true,
    [int]      $InstallWimIndex = 1,

    # --- Arsenal Image Mounter (AIM) RAM disk integration ---
    [switch]   $EnableAIMRamdisk = $true,
    [string]   $AIMRuntimePath = "$PSScriptRoot\ArsenalImageMounter\Runtime",
    [string]   $AIMDriverPath  = "$PSScriptRoot\ArsenalImageMounter\Driver",
    [string]   $AIMRamdiskSize = "2GB",
    [string]   $AIMRamdiskDrive = "R",
    [string]   $AIMRamdiskLabel = "Ramdisk",
    [string]   $AIMRamdiskFormat = "NTFS",
    [switch]   $AIMUseRamdiskForTemp = $true,

    # --- Download URLs (update when versions go stale) ---
    # Chrome: uncompressed installer - extract Chrome-bin with 7-Zip
    # To find a new URL: download latest ChromeSetup.exe from
    #   https://dl.google.com/tag/s/appguid={...}/update2/installers/ChromeSetup.exe
    # and inspect the download URL from dl.google.com/release2/chrome/
    [string]   $ChromeUrl     = "https://github.com/Bush2021/chrome_installer/releases/download/145.0.7632.117/x64_145.0.7632.117_chrome_installer_uncompressed.exe",

    # 7-Zip installer SFX - 7zr.exe can extract it
    [string]   $SevenZipUrl   = "https://www.7-zip.org/a/7z2409-x64.exe",
    [string]   $SevenZrUrl    = "https://www.7-zip.org/a/7zr.exe",

    # IBM Semeru JRE 8 LTS (OpenJ9) - check latest at:
    # https://github.com/ibmruntimes/semeru8-binaries/releases
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

function Resolve-InstallWimPath {
    param(
        [string]$RequestedInstallWimPath,
        [string]$InstallMediaPath,
        [string]$WorkspacePath,
        [string]$StagingRoot,
        [int]$ImageIndex,
        [switch]$AutoAcquire
    )

    function Convert-EsdToWim {
        param(
            [string]$EsdPath,
            [string]$ExportRoot,
            [int]$Index
        )

        New-Item $ExportRoot -ItemType Directory -Force | Out-Null
        $wimOut = Join-Path $ExportRoot ("install.auto.index{0}.wim" -f $Index)
        if (Test-Path $wimOut) {
            Remove-Item $wimOut -Force -ErrorAction SilentlyContinue
        }

        Write-Status "Converting install.esd to install.wim (index $Index) from $EsdPath" -Type Info
        $args = @(
            '/English',
            '/Export-Image',
            "/SourceImageFile:$EsdPath",
            "/SourceIndex:$Index",
            "/DestinationImageFile:$wimOut",
            '/Compress:max',
            '/CheckIntegrity'
        )
        $proc = Start-Process -FilePath dism.exe -ArgumentList $args -PassThru -Wait -NoNewWindow
        if ($proc.ExitCode -ne 0 -or -not (Test-Path $wimOut)) {
            throw "DISM export failed for install.esd (exit code $($proc.ExitCode))"
        }

        Write-Status "Generated install.wim at $wimOut" -Type Success
        return $wimOut
    }

    function Resolve-Candidate {
        param(
            [string]$Candidate,
            [string]$ExportRoot,
            [int]$Index
        )

        if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }

        $expanded = [Environment]::ExpandEnvironmentVariables($Candidate.Trim().Trim('"'))
        if (-not (Test-Path $expanded)) { return $null }

        $item = Get-Item -LiteralPath $expanded -ErrorAction SilentlyContinue
        if (-not $item) { return $null }

        if ($item.PSIsContainer) {
            $folderCandidates = @(
                (Join-Path $item.FullName 'sources\install.wim'),
                (Join-Path $item.FullName 'sources\install.esd'),
                (Join-Path $item.FullName 'install.wim'),
                (Join-Path $item.FullName 'install.esd')
            )

            foreach ($path in $folderCandidates) {
                if (-not (Test-Path $path)) { continue }
                if ($path -match '(?i)\.wim$') { return $path }
                if ($path -match '(?i)\.esd$') { return (Convert-EsdToWim -EsdPath $path -ExportRoot $ExportRoot -Index $Index) }
            }

            return $null
        }

        if ($item.Extension -match '(?i)^\.wim$') {
            return $item.FullName
        }

        if ($item.Extension -match '(?i)^\.esd$') {
            return (Convert-EsdToWim -EsdPath $item.FullName -ExportRoot $ExportRoot -Index $Index)
        }

        if ($item.Extension -match '(?i)^\.iso$') {
            $mounted = $null
            try {
                Write-Status "Mounting ISO to locate install.wim/install.esd: $($item.FullName)" -Type Info
                $mounted = Mount-DiskImage -ImagePath $item.FullName -PassThru -ErrorAction Stop
                $vol = $mounted | Get-Volume -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $vol -or -not $vol.DriveLetter) {
                    throw "Mounted ISO has no accessible drive letter"
                }

                $root = "$($vol.DriveLetter):\"
                $wimPath = Join-Path $root 'sources\install.wim'
                if (Test-Path $wimPath) { return $wimPath }

                $esdPath = Join-Path $root 'sources\install.esd'
                if (Test-Path $esdPath) {
                    return (Convert-EsdToWim -EsdPath $esdPath -ExportRoot $ExportRoot -Index $Index)
                }
            }
            finally {
                if ($mounted) {
                    Dismount-DiskImage -ImagePath $item.FullName -ErrorAction SilentlyContinue | Out-Null
                }
            }

            return $null
        }

        return $null
    }

    if ($RequestedInstallWimPath -and (Test-Path $RequestedInstallWimPath)) {
        return (Get-Item -LiteralPath $RequestedInstallWimPath).FullName
    }

    if ($RequestedInstallWimPath -and -not (Test-Path $RequestedInstallWimPath)) {
        Write-Status "InstallWimPath not found, will attempt auto-acquire: $RequestedInstallWimPath" -Type Warning
    }

    if (-not $AutoAcquire) {
        return $null
    }

    $exportRoot = Join-Path $StagingRoot 'install-media'
    New-Item $exportRoot -ItemType Directory -Force | Out-Null

    $candidateList = New-Object System.Collections.Generic.List[string]
    if ($RequestedInstallWimPath) { [void]$candidateList.Add($RequestedInstallWimPath) }
    if ($InstallMediaPath)       { [void]$candidateList.Add($InstallMediaPath) }
    [void]$candidateList.Add((Join-Path $WorkspacePath 'Media\sources\install.wim'))
    [void]$candidateList.Add((Join-Path $WorkspacePath 'Media\sources\install.esd'))
    [void]$candidateList.Add((Join-Path $WorkspacePath 'Media'))

    foreach ($candidate in ($candidateList | Select-Object -Unique)) {
        Write-Status "Trying install media candidate: $candidate" -Type Info
        try {
            $resolved = Resolve-Candidate -Candidate $candidate -ExportRoot $exportRoot -Index $ImageIndex
            if ($resolved -and (Test-Path $resolved)) {
                Write-Status "Resolved install.wim source: $resolved" -Type Success
                return $resolved
            }
        }
        catch {
            Write-Status "Candidate failed: $candidate -- $_" -Type Warning
        }
    }

    return $null
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
# STEP 4.5 - BUILD GUI SHELL + COMPATIBILITY PACK FROM install.wim
#
# This recreates the useful Explorer/WinXShell runtime dependency
# layer and adds VC/.NET compatibility payloads using pure
# PowerShell + DISM + smart copy, without using PhoenixPE binaries/components.
# Output lands in:
#   $Workspace\Config\ShellPack\Windows\...
#   $Workspace\Config\ShellPack\ProgramData\...
#   $Workspace\Config\ShellPack\RegistryPack\...
# =================================================================
function Invoke-BuildGuiShellPack {
    if (-not $BuildGuiShellPack) {
        Write-Status "GUI shell pack not requested (-BuildGuiShellPack not set)" -Type Info
        return
    }

    $resolvedInstallWimPath = Resolve-InstallWimPath `
        -RequestedInstallWimPath $InstallWimPath `
        -InstallMediaPath $InstallMediaPath `
        -WorkspacePath $Workspace `
        -StagingRoot $StagingPath `
        -ImageIndex $InstallWimIndex `
        -AutoAcquire:$AutoAcquireInstallWim

    if (-not $resolvedInstallWimPath -or -not (Test-Path $resolvedInstallWimPath)) {
        Write-Status "Unable to resolve install.wim source. Provide -InstallWimPath, or enable auto-acquire with -InstallMediaPath (.wim/.esd/.iso/folder)." -Type Error
        return
    }

    $shellPackRoot = "$Workspace\Config\ShellPack"
    if (Test-Path $shellPackRoot) { Remove-Item $shellPackRoot -Recurse -Force }
    New-Item $shellPackRoot -ItemType Directory -Force | Out-Null

    $mountDir = Join-Path $env:TEMP "OSDGuiShellPackMount"
    if (Test-Path $mountDir) {
        try { Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null } catch {}
        Remove-Item $mountDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item $mountDir -ItemType Directory -Force | Out-Null

    $requiredPaths = @(
        '\Program Files\Microsoft.NET',
        '\Program Files\Reference Assemblies',
        '\Program Files (x86)\Microsoft.NET',
        '\Program Files (x86)\Reference Assemblies',
        '\Windows\Microsoft.NET',

        '\Windows\SystemResources\Windows.UI.ShellCommon',

        '\Windows\explorer.exe',
        '\Windows\System32\Shell32.dll',
        '\Windows\System32\ExplorerFrame.dll',
        '\Windows\System32\CoreMessaging.dll',
        '\Windows\System32\CoreUIComponents.dll',
        '\Windows\System32\TextInputFramework.dll',
        '\Windows\System32\TextShaping.dll',
        '\Windows\System32\twinapi.dll',
        '\Windows\System32\twinapi.appcore.dll',
        '\Windows\System32\twinui.appcore.dll',
        '\Windows\System32\twinui.pcshell.dll',
        '\Windows\System32\windows.storage.dll',
        '\Windows\System32\Windows.Storage.Search.dll',
        '\Windows\System32\Windows.UI.dll',
        '\Windows\System32\Windows.UI.FileExplorer.dll',
        '\Windows\System32\Windows.UI.Core.TextInput.dll',
        '\Windows\System32\Windows.Internal.Shell.Broker.dll',
        '\Windows\System32\windowsudk.shellcommon.dll',
        '\Windows\System32\Windows.Networking.Connectivity.dll',
        '\Windows\System32\SHCore.dll',
        '\Windows\System32\comctl32.dll',
        '\Windows\System32\rmclient.dll',
        '\Windows\System32\UIAnimation.dll',
        '\Windows\System32\UIRibbon.dll',
        '\Windows\System32\dcomp.dll',
        '\Windows\System32\d3d11.dll',
        '\Windows\System32\dxgi.dll',
        '\Windows\System32\DataExchange.dll',
        '\Windows\System32\chartv.dll',
        '\Windows\System32\OneCoreUAPCommonProxyStub.dll',

        '\Windows\System32\mscorees.dll',
        '\Windows\System32\mscoree.dll',
        '\Windows\System32\mscorier.dll',
        '\Windows\System32\mscories.dll',
        '\Windows\System32\aspnet_counters.dll',
        '\Windows\System32\dfshim.dll',
        '\Windows\System32\netfxperf.dll',
        '\Windows\System32\PresentationCFFRasterizerNative_v0300.dll',
        '\Windows\System32\PresentationHost.exe',
        '\Windows\System32\PresentationHostProxy.dll',
        '\Windows\System32\PresentationNative_v0300.dll',
        '\Windows\System32\sxstrace.exe',
        '\Windows\System32\UIAutomationCore.dll',
        '\Windows\System32\WindowsCodecs.dll',
        '\Windows\System32\WindowsCodecsExt.dll',
        '\Windows\System32\FntCache.dll',

        '\Windows\System32\msvcp110.dll',
        '\Windows\System32\msvcp120.dll',
        '\Windows\System32\msvcp140.dll',
        '\Windows\System32\msvcp140_1.dll',
        '\Windows\System32\msvcp_win.dll',
        '\Windows\System32\msvcrt.dll',
        '\Windows\System32\msvcr100.dll',
        '\Windows\System32\msvcr110.dll',
        '\Windows\System32\msvcr120.dll',
        '\Windows\System32\vcruntime140.dll',
        '\Windows\System32\vcruntime140_1.dll',
        '\Windows\System32\vcruntime140_threads.dll',
        '\Windows\System32\ucrtbase.dll',
        '\Windows\System32\downlevel\ucrtbase.dll',
        '\Windows\System32\ucrtbase_enclave.dll',
        '\Windows\System32\msvcp120_clr0400.dll',
        '\Windows\System32\msvcp140_clr0400.dll',
        '\Windows\System32\msvcr100_clr0400.dll',
        '\Windows\System32\msvcr120_clr0400.dll',
        '\Windows\System32\vcruntime140_clr0400.dll',
        '\Windows\System32\vcruntime140_1_clr0400.dll',
        '\Windows\System32\ucrtbase_clr0400.dll',

        '\Windows\SysWOW64\mscorees.dll',
        '\Windows\SysWOW64\mscoree.dll',
        '\Windows\SysWOW64\mscorier.dll',
        '\Windows\SysWOW64\mscories.dll',
        '\Windows\SysWOW64\aspnet_counters.dll',
        '\Windows\SysWOW64\dfshim.dll',
        '\Windows\SysWOW64\netfxperf.dll',
        '\Windows\SysWOW64\PresentationCFFRasterizerNative_v0300.dll',
        '\Windows\SysWOW64\PresentationHost.exe',
        '\Windows\SysWOW64\PresentationHostProxy.dll',
        '\Windows\SysWOW64\PresentationNative_v0300.dll',
        '\Windows\SysWOW64\sxstrace.exe',
        '\Windows\SysWOW64\UIAutomationCore.dll',
        '\Windows\SysWOW64\WindowsCodecs.dll',
        '\Windows\SysWOW64\WindowsCodecsExt.dll',

        '\Windows\SysWOW64\msvcp110.dll',
        '\Windows\SysWOW64\msvcp120.dll',
        '\Windows\SysWOW64\msvcp140.dll',
        '\Windows\SysWOW64\msvcp140_1.dll',
        '\Windows\SysWOW64\msvcp_win.dll',
        '\Windows\SysWOW64\msvcrt.dll',
        '\Windows\SysWOW64\msvcr100.dll',
        '\Windows\SysWOW64\msvcr110.dll',
        '\Windows\SysWOW64\msvcr120.dll',
        '\Windows\SysWOW64\vcruntime140.dll',
        '\Windows\SysWOW64\vcruntime140_1.dll',
        '\Windows\SysWOW64\vcruntime140_threads.dll',
        '\Windows\SysWOW64\ucrtbase.dll',
        '\Windows\SysWOW64\downlevel\ucrtbase.dll',
        '\Windows\SysWOW64\ucrtbase_enclave.dll',
        '\Windows\SysWOW64\msvcp120_clr0400.dll',
        '\Windows\SysWOW64\msvcp140_clr0400.dll',
        '\Windows\SysWOW64\msvcr100_clr0400.dll',
        '\Windows\SysWOW64\msvcr120_clr0400.dll',
        '\Windows\SysWOW64\vcruntime140_clr0400.dll',
        '\Windows\SysWOW64\vcruntime140_1_clr0400.dll',
        '\Windows\SysWOW64\ucrtbase_clr0400.dll',

        '\ProgramData\Microsoft\Windows\AppRepository',
        '\Windows\System32\StateRepository.core.dll',
        '\Windows\System32\Windows.StateRepository.dll',
        '\Windows\System32\Windows.StateRepositoryBroker.dll',
        '\Windows\System32\Windows.StateRepositoryClient.dll',
        '\Windows\System32\Windows.StateRepositoryCore.dll',
        '\Windows\System32\Windows.StateRepositoryPS.dll',
        '\Windows\System32\Windows.StateRepositoryUpgrade.dll',
        '\Windows\System32\Windows.CloudStore.dll',

        '\Windows\Fonts\segoe*.ttf',
        '\Windows\Fonts\arial*.ttf',
        '\Windows\Fonts\calibri*.ttf',
        '\Windows\Fonts\cambria*.ttf',
        '\Windows\Fonts\times*.ttf',
        '\Windows\Fonts\verdana*.ttf'
    )

    $registryPackRoot = Join-Path $shellPackRoot 'RegistryPack'
    New-Item $registryPackRoot -ItemType Directory -Force | Out-Null

    $copied = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    $regExported = New-Object System.Collections.Generic.List[string]
    $regMissing = New-Object System.Collections.Generic.List[string]

    try {
        Write-Status "Mounting install.wim index $InstallWimIndex to build GUI shell pack..." -Type Info
        Mount-WindowsImage -ImagePath $resolvedInstallWimPath -Index $InstallWimIndex -Path $mountDir -ReadOnly | Out-Null

        foreach ($sourceSpec in $requiredPaths) {
            $trimmed = $sourceSpec.TrimStart('\\')
            $sourcePattern = Join-Path $mountDir $trimmed
            $matches = @()

            if ($sourceSpec.Contains('*')) {
                $matches = @(Get-ChildItem -Path $sourcePattern -File -Force -ErrorAction SilentlyContinue)
            } else {
                $item = Get-Item -LiteralPath $sourcePattern -Force -ErrorAction SilentlyContinue
                if ($item) { $matches = @($item) }
            }

            if ($matches.Count -eq 0) {
                $missing.Add($sourceSpec)
                continue
            }

            foreach ($match in $matches) {
                $relative = $match.FullName.Substring($mountDir.Length).TrimStart('\\')
                $destination = Join-Path $shellPackRoot $relative

                if ($match.PSIsContainer) {
                    New-Item $destination -ItemType Directory -Force | Out-Null
                    Copy-Item (Join-Path $match.FullName '*') -Destination $destination -Recurse -Force -ErrorAction SilentlyContinue
                } else {
                    $destParent = Split-Path $destination -Parent
                    New-Item $destParent -ItemType Directory -Force | Out-Null
                    Copy-Item -LiteralPath $match.FullName -Destination $destination -Force -ErrorAction SilentlyContinue
                }
                $copied.Add($relative)
            }
        }

        Write-Status "Building GUI registry/service pack from install.wim hives..." -Type Info

        $srcSoftwareHive = Join-Path $mountDir 'Windows\System32\Config\SOFTWARE'
        $srcSystemHive   = Join-Path $mountDir 'Windows\System32\Config\SYSTEM'
        $srcDefaultHive  = Join-Path $mountDir 'Windows\System32\Config\DEFAULT'

        $srcSoftwareRoot = 'HKLM\OSD_SRC_SOFTWARE'
        $srcSystemRoot   = 'HKLM\OSD_SRC_SYSTEM'
        $srcDefaultRoot  = 'HKLM\OSD_SRC_DEFAULT'

        reg.exe load $srcSoftwareRoot $srcSoftwareHive | Out-Null
        reg.exe load $srcSystemRoot   $srcSystemHive   | Out-Null
        reg.exe load $srcDefaultRoot  $srcDefaultHive  | Out-Null

        $regExports = @(
            @{ Key = "$srcSoftwareRoot\Microsoft\Windows NT\CurrentVersion\Winlogon"; File = 'SOFTWARE-Winlogon.reg' },
            @{ Key = "$srcSoftwareRoot\Microsoft\Windows\CurrentVersion\Explorer"; File = 'SOFTWARE-Explorer.reg' },
            @{ Key = "$srcSoftwareRoot\Microsoft\Windows\CurrentVersion\CloudStore"; File = 'SOFTWARE-CloudStore.reg' },
            @{ Key = "$srcSoftwareRoot\Microsoft\Windows\CurrentVersion\AppModel"; File = 'SOFTWARE-AppModel.reg' },
            @{ Key = "$srcSoftwareRoot\Classes"; File = 'SOFTWARE-Classes.reg' },
            @{ Key = "$srcSoftwareRoot\Microsoft\.NETFramework"; File = 'SOFTWARE-DotNetFramework.reg' },
            @{ Key = "$srcSoftwareRoot\Microsoft\Fusion"; File = 'SOFTWARE-Fusion.reg' },
            @{ Key = "$srcSoftwareRoot\Microsoft\MSBuild"; File = 'SOFTWARE-MSBuild.reg' },
            @{ Key = "$srcSoftwareRoot\Microsoft\NET Framework Setup"; File = 'SOFTWARE-NETFrameworkSetup.reg' },
            @{ Key = "$srcSoftwareRoot\Microsoft\Windows\CurrentVersion\SideBySide"; File = 'SOFTWARE-SideBySide.reg' },
            @{ Key = "$srcSoftwareRoot\WOW6432Node\Microsoft\.NETFramework"; File = 'SOFTWARE-WOW64-DotNetFramework.reg' },
            @{ Key = "$srcSoftwareRoot\WOW6432Node\Microsoft\Fusion"; File = 'SOFTWARE-WOW64-Fusion.reg' },
            @{ Key = "$srcSoftwareRoot\WOW6432Node\Microsoft\MSBuild"; File = 'SOFTWARE-WOW64-MSBuild.reg' },
            @{ Key = "$srcSoftwareRoot\WOW6432Node\Microsoft\NET Framework Setup"; File = 'SOFTWARE-WOW64-NETFrameworkSetup.reg' },

            @{ Key = "$srcSystemRoot\ControlSet001\Services\StateRepository"; File = 'SYSTEM-Svc-StateRepository.reg' },
            @{ Key = "$srcSystemRoot\ControlSet001\Services\AppXSvc"; File = 'SYSTEM-Svc-AppXSvc.reg' },
            @{ Key = "$srcSystemRoot\ControlSet001\Services\ClipSVC"; File = 'SYSTEM-Svc-ClipSVC.reg' },
            @{ Key = "$srcSystemRoot\ControlSet001\Services\TokenBroker"; File = 'SYSTEM-Svc-TokenBroker.reg' },
            @{ Key = "$srcSystemRoot\ControlSet001\Services\FontCache"; File = 'SYSTEM-Svc-FontCache.reg' },
            @{ Key = "$srcSystemRoot\ControlSet001\Services\FontCache3.0.0.0"; File = 'SYSTEM-Svc-FontCache3.reg' },

            @{ Key = "$srcDefaultRoot\Software\Microsoft\Windows\CurrentVersion\Explorer"; File = 'DEFAULT-Explorer.reg' }
        )

        foreach ($entry in $regExports) {
            $outReg = Join-Path $registryPackRoot $entry.File
            if (reg.exe query $entry.Key > $null 2>&1) {
                reg.exe export $entry.Key $outReg /y | Out-Null
                if (Test-Path $outReg) {
                    $regExported.Add($entry.File)
                }
                else {
                    $regMissing.Add($entry.Key)
                }
            }
            else {
                $regMissing.Add($entry.Key)
            }
        }

        reg.exe unload $srcDefaultRoot  | Out-Null
        reg.exe unload $srcSystemRoot   | Out-Null
        reg.exe unload $srcSoftwareRoot | Out-Null
    }
    finally {
        try { Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null } catch {}
        Remove-Item $mountDir -Recurse -Force -ErrorAction SilentlyContinue

        reg.exe unload HKLM\OSD_SRC_DEFAULT  > $null 2>&1
        reg.exe unload HKLM\OSD_SRC_SYSTEM   > $null 2>&1
        reg.exe unload HKLM\OSD_SRC_SOFTWARE > $null 2>&1
    }

    $report = [ordered]@{
        BuiltAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
        InstallWimPathRequested = $InstallWimPath
        InstallMediaPath = $InstallMediaPath
        InstallWimPathResolved = $resolvedInstallWimPath
        InstallWimIndex= $InstallWimIndex
        CopiedCount    = $copied.Count
        MissingCount   = $missing.Count
        RegistryExportedCount = $regExported.Count
        RegistryMissingCount  = $regMissing.Count
        Copied         = $copied
        Missing        = $missing
        RegistryExported = $regExported
        RegistryMissing  = $regMissing
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content "$shellPackRoot\Pack-Report.json" -Encoding UTF8

    Write-Status "GUI shell + compatibility pack created: copied $($copied.Count) file item(s), exported $($regExported.Count) registry item(s)" -Type Success
    Write-Status "Pack report: $shellPackRoot\Pack-Report.json" -Type Info
}

# =================================================================
# STEP 4.6 - STAGE ARSENAL IMAGE MOUNTER (AIM) FOR WINPE BOOT
#
# Expects locally available AIM runtime + driver payload.
# Stages files into:
#   $Workspace\Config\ArsenalImageMounter\Runtime
#   $Workspace\Config\ArsenalImageMounter\Driver
#   $Workspace\Config\ArsenalImageMounter\AIM-Settings.json
# =================================================================
function Invoke-StageAIMRamdisk {
    if (-not $EnableAIMRamdisk) {
        Write-Status "AIM RAM disk integration disabled" -Type Info
        return
    }

    $aimConfigRoot = "$Workspace\Config\ArsenalImageMounter"
    if (Test-Path $aimConfigRoot) { Remove-Item $aimConfigRoot -Recurse -Force }
    New-Item $aimConfigRoot -ItemType Directory -Force | Out-Null

    $runtimeDest = Join-Path $aimConfigRoot 'Runtime'
    $driverDest  = Join-Path $aimConfigRoot 'Driver'

    $runtimeReady = $false
    $driverReady  = $false

    if (Test-Path $AIMRuntimePath) {
        New-Item $runtimeDest -ItemType Directory -Force | Out-Null
        Copy-Item (Join-Path $AIMRuntimePath '*') -Destination $runtimeDest -Recurse -Force
        $runtimeReady = $true
    } else {
        Write-Status "AIM runtime path not found: $AIMRuntimePath" -Type Warning
    }

    if (Test-Path $AIMDriverPath) {
        New-Item $driverDest -ItemType Directory -Force | Out-Null
        Copy-Item (Join-Path $AIMDriverPath '*') -Destination $driverDest -Recurse -Force
        $driverReady = $true
    } else {
        Write-Status "AIM driver path not found: $AIMDriverPath" -Type Warning
    }

    $aimExe = $null
    if ($runtimeReady) {
        $aimExe = Get-ChildItem $runtimeDest -Recurse -File -Filter 'AimRamdrive.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    $infCount = 0
    if ($driverReady) {
        $infCount = @(Get-ChildItem $driverDest -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue).Count
    }

    $driveLetter = (($AIMRamdiskDrive -replace ':','').Trim().ToUpperInvariant())
    if ([string]::IsNullOrWhiteSpace($driveLetter)) { $driveLetter = 'R' }

    $enabled = $runtimeReady -and $driverReady -and ($null -ne $aimExe) -and ($infCount -gt 0)

    $settings = [ordered]@{
        Enabled = $enabled
        Runtime = [ordered]@{
            RuntimePathPresent = $runtimeReady
            DriverPathPresent  = $driverReady
            AimRamdriveExeFound = ($null -ne $aimExe)
            DriverInfCount = $infCount
        }
        Ramdisk = [ordered]@{
            Size = $AIMRamdiskSize
            DriveLetter = $driveLetter
            Label = $AIMRamdiskLabel
            Format = $AIMRamdiskFormat
            UseForTemp = [bool]$AIMUseRamdiskForTemp
        }
    }

    $settingsPath = Join-Path $aimConfigRoot 'AIM-Settings.json'
    $settings | ConvertTo-Json -Depth 6 | Set-Content $settingsPath -Encoding UTF8

    if ($enabled) {
        Write-Status "AIM staged for WinPE boot (drive $driveLetter:, size $AIMRamdiskSize, format $AIMRamdiskFormat)" -Type Success
    }
    else {
        Write-Status "AIM staging incomplete; RAM disk auto-init will be skipped (see $settingsPath)" -Type Warning
    }
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
    # Sets environment variables, then launches the Recovery Dashboard HTA.
    $recoveryPs1 = @'
# =============================================================
# Start-RecoveryMode.ps1  --  runs inside WinPE at boot
# Tools are pre-baked at X:\OSDCloud\Config\Tools\
# =============================================================
$toolsBase = "X:\OSDCloud\Config\Tools"

    $logRoot = "X:\OSDCloud\Logs"
    New-Item $logRoot -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    $depLog = Join-Path $logRoot "DependencyCheck.log"

    function Write-DepLog {
        param([string]$Message,[string]$Level="INFO")
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
        Write-Host $line
        Add-Content -Path $depLog -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }

Write-Host ""
Write-Host "=== Recovery Mode ===" -ForegroundColor Cyan
Write-Host "[INFO] Tools base: $toolsBase"

# Expose Java + tools on PATH for any child processes
[Environment]::SetEnvironmentVariable("JAVA_HOME", "$toolsBase\java", "Machine")
[Environment]::SetEnvironmentVariable(
    "PATH",
    "$toolsBase\java\bin;$toolsBase\chrome;$toolsBase\7zip;$env:PATH",
    "Machine"
)
Write-Host "[OK]   JAVA_HOME and PATH configured"

# Log-only dependency check (always continues)
Write-DepLog "Running dependency check (log-only mode; startup will continue regardless of results)"

$checks = @(
    @{ Label = "Chrome binary";                Path = "$toolsBase\chrome\chrome.exe" },
    @{ Label = "Chrome helper DLL";            Path = "$toolsBase\chrome\chrome_elf.dll" },
    @{ Label = "7-Zip file manager";           Path = "$toolsBase\7zip\7zFM.exe" },
    @{ Label = "Java runtime";                 Path = "$toolsBase\java\bin\java.exe" },
    @{ Label = "VC runtime vcruntime140";      Path = "X:\Windows\System32\vcruntime140.dll" },
    @{ Label = "VC runtime vcruntime140_1";    Path = "X:\Windows\System32\vcruntime140_1.dll" },
    @{ Label = "VC runtime msvcp140";          Path = "X:\Windows\System32\msvcp140.dll" },
    @{ Label = "UCRT ucrtbase";                Path = "X:\Windows\System32\ucrtbase.dll" },
    @{ Label = ".NET host mscoree";            Path = "X:\Windows\System32\mscoree.dll" },
    @{ Label = ".NET host mscorees";           Path = "X:\Windows\System32\mscorees.dll" }
)

$missing = New-Object System.Collections.Generic.List[string]
foreach ($check in $checks) {
    if (Test-Path $check.Path) {
        Write-DepLog "OK   $($check.Label): $($check.Path)"
    }
    else {
        $missing.Add($check.Label)
        Write-DepLog "MISS $($check.Label): $($check.Path)" "WARN"
    }
}

$chromeExe = "$toolsBase\chrome\chrome.exe"
if (Test-Path $chromeExe) {
    try {
        $verOut = & $chromeExe --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-DepLog "Chrome smoke test OK: $($verOut -join ' ')"
        }
        else {
            Write-DepLog "Chrome smoke test failed (exit $LASTEXITCODE): $($verOut -join ' ')" "WARN"
        }
    }
    catch {
        Write-DepLog "Chrome smoke test exception: $_" "WARN"
    }
}
else {
    Write-DepLog "Chrome smoke test skipped: chrome.exe missing" "WARN"
}

if ($missing.Count -gt 0) {
    Write-DepLog "Dependency check summary: $($missing.Count) item(s) missing -> $($missing -join ', ')" "WARN"
}
else {
    Write-DepLog "Dependency check summary: all monitored items present" "OK"
}

# Launch the Recovery Dashboard
Write-Host "[OK]   Launching Recovery Dashboard..." -ForegroundColor Green
Start-Process "mshta.exe" -ArgumentList "`"X:\OSDCloud\Config\Scripts\Recovery-Dashboard.hta`""
'@
    Set-Content "$scriptsDir\Start-RecoveryMode.ps1" -Value $recoveryPs1 -Encoding UTF8
    Write-Status "Start-RecoveryMode.ps1 written" -Type Success

    # ---- Apply-GuiShellPack.ps1 ------------------------------------------
    $applyPackPs1 = @'
$packRoot = "X:\OSDCloud\Config\ShellPack"

$logRoot = "X:\OSDCloud\Logs"
New-Item $logRoot -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
$logFile = Join-Path $logRoot "GuiShellPack.log"

function Write-ApplyLog {
    param([string]$Message,[string]$Level="INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

if (-not (Test-Path $packRoot)) {
    Write-ApplyLog "GUI shell pack not present; shell payload copy/import will be skipped" "WARN"
}

Write-ApplyLog "Applying GUI shell pack..."

$packApplied = Test-Path $packRoot
if ($packApplied) {
    $windowsSrc = Join-Path $packRoot "Windows"
    if (Test-Path $windowsSrc) {
        robocopy $windowsSrc "X:\Windows" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    }

    $programDataSrc = Join-Path $packRoot "ProgramData"
    if (Test-Path $programDataSrc) {
        robocopy $programDataSrc "X:\ProgramData" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    }

    $registryPack = Join-Path $packRoot "RegistryPack"
    if (Test-Path $registryPack) {
        Write-ApplyLog "Applying GUI registry/service pack..."
        try {
            reg.exe load HKLM\OSD_SRC_SOFTWARE "X:\Windows\System32\Config\SOFTWARE" | Out-Null
            reg.exe load HKLM\OSD_SRC_SYSTEM   "X:\Windows\System32\Config\SYSTEM"   | Out-Null
            reg.exe load HKLM\OSD_SRC_DEFAULT  "X:\Windows\System32\Config\DEFAULT"  | Out-Null

            Get-ChildItem $registryPack -Filter '*.reg' -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    reg.exe import $_.FullName | Out-Null
                }
        }
        finally {
            reg.exe unload HKLM\OSD_SRC_DEFAULT  > $null 2>&1
            reg.exe unload HKLM\OSD_SRC_SYSTEM   > $null 2>&1
            reg.exe unload HKLM\OSD_SRC_SOFTWARE > $null 2>&1
        }
    }
}

$chromeRoot = "X:\OSDCloud\Config\Tools\chrome"
$chromeExe = Join-Path $chromeRoot "chrome.exe"
if (Test-Path $chromeExe) {
    Write-ApplyLog "Applying Chrome compatibility registry keys..."

    reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" /ve /t REG_EXPAND_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\chrome\chrome.exe" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" /v Path /t REG_EXPAND_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\chrome" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" /ve /t REG_EXPAND_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\chrome\chrome.exe" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" /v Path /t REG_EXPAND_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\chrome" /f | Out-Null

    reg.exe add "HKLM\SOFTWARE\Classes\.htm" /ve /t REG_SZ /d "ChromeHTML" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Classes\.html" /ve /t REG_SZ /d "ChromeHTML" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Classes\.shtml" /ve /t REG_SZ /d "ChromeHTML" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Classes\.xht" /ve /t REG_SZ /d "ChromeHTML" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Classes\.xhtml" /ve /t REG_SZ /d "ChromeHTML" /f | Out-Null

    reg.exe add "HKLM\SOFTWARE\Classes\ChromeHTML" /ve /t REG_SZ /d "Chrome HTML Document" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Classes\ChromeHTML" /v FriendlyTypeName /t REG_SZ /d "Chrome HTML Document" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Classes\ChromeHTML\DefaultIcon" /ve /t REG_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\chrome\chrome.exe,10" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Classes\ChromeHTML\shell\open\command" /ve /t REG_SZ /d "\"%SystemDrive%\OSDCloud\Config\Tools\chrome\chrome.exe\" \"%%1\"" /f | Out-Null

    reg.exe add "HKLM\SOFTWARE\Classes\ChromeURL" /ve /t REG_SZ /d "Chrome URL" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Classes\ChromeURL" /v FriendlyTypeName /t REG_SZ /d "Chrome URL" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Classes\ChromeURL" /v "URL Protocol" /t REG_SZ /d "" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Classes\ChromeURL\DefaultIcon" /ve /t REG_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\chrome\chrome.exe,0" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Classes\ChromeURL\shell\open\command" /ve /t REG_SZ /d "\"%SystemDrive%\OSDCloud\Config\Tools\chrome\chrome.exe\" \"%%1\"" /f | Out-Null

    reg.exe add "HKLM\SOFTWARE\Classes\http" /v "URL Protocol" /t REG_SZ /d "" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Classes\http\shell\open\command" /ve /t REG_SZ /d "\"%SystemDrive%\OSDCloud\Config\Tools\chrome\chrome.exe\" \"%%1\"" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Classes\https" /v "URL Protocol" /t REG_SZ /d "" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Classes\https\shell\open\command" /ve /t REG_SZ /d "\"%SystemDrive%\OSDCloud\Config\Tools\chrome\chrome.exe\" \"%%1\"" /f | Out-Null

    reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.htm\UserChoice" /v ProgId /t REG_SZ /d "ChromeHTML" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.html\UserChoice" /v ProgId /t REG_SZ /d "ChromeHTML" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.shtml\UserChoice" /v ProgId /t REG_SZ /d "ChromeHTML" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.xht\UserChoice" /v ProgId /t REG_SZ /d "ChromeHTML" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.xhtml\UserChoice" /v ProgId /t REG_SZ /d "ChromeHTML" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice" /v ProgId /t REG_SZ /d "ChromeURL" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice" /v ProgId /t REG_SZ /d "ChromeURL" /f | Out-Null

    reg.exe add "HKLM\SOFTWARE\Policies\Google\Chrome" /v DefaultBrowserSettingEnabled /t REG_DWORD /d 0 /f | Out-Null
    Write-ApplyLog "Chrome compatibility registry keys applied"
}
else {
    Write-ApplyLog "Chrome binary not found at $chromeExe; skipped Chrome registry compatibility" "WARN"
}

$javaRoot = "X:\OSDCloud\Config\Tools\java"
$javaExe = Join-Path $javaRoot "bin\java.exe"
$javawExe = Join-Path $javaRoot "bin\javaw.exe"
if (Test-Path $javaExe) {
    Write-ApplyLog "Applying Java (Semeru) compatibility registry keys..."

    reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\java.exe" /ve /t REG_EXPAND_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\java\bin\java.exe" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\java.exe" /v Path /t REG_EXPAND_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\java\bin" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\java.exe" /ve /t REG_EXPAND_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\java\bin\java.exe" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\java.exe" /v Path /t REG_EXPAND_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\java\bin" /f | Out-Null

    if (Test-Path $javawExe) {
        reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\javaw.exe" /ve /t REG_EXPAND_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\java\bin\javaw.exe" /f | Out-Null
        reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\javaw.exe" /v Path /t REG_EXPAND_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\java\bin" /f | Out-Null
        reg.exe add "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\javaw.exe" /ve /t REG_EXPAND_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\java\bin\javaw.exe" /f | Out-Null
        reg.exe add "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\javaw.exe" /v Path /t REG_EXPAND_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\java\bin" /f | Out-Null

        reg.exe add "HKLM\SOFTWARE\Classes\.jar" /ve /t REG_SZ /d "Semeru.jarfile" /f | Out-Null
        reg.exe add "HKLM\SOFTWARE\Classes\.jar" /v "Content Type" /t REG_SZ /d "application/jar" /f | Out-Null
        reg.exe add "HKLM\SOFTWARE\Classes\Semeru.jarfile" /ve /t REG_SZ /d "Semeru jar file" /f | Out-Null
        reg.exe add "HKLM\SOFTWARE\Classes\Semeru.jarfile\shell\open" /ve /t REG_SZ /d "Open" /f | Out-Null
        reg.exe add "HKLM\SOFTWARE\Classes\Semeru.jarfile\shell\open\command" /ve /t REG_SZ /d "\"%SystemDrive%\OSDCloud\Config\Tools\java\bin\javaw.exe\" -jar \"%%1\" %%*" /f | Out-Null
    }

    $runtimeLibCandidates = @(
        (Join-Path $javaRoot "bin\server\jvm.dll"),
        (Join-Path $javaRoot "jre\bin\server\jvm.dll"),
        (Join-Path $javaRoot "bin\client\jvm.dll"),
        (Join-Path $javaRoot "jre\bin\client\jvm.dll"),
        (Join-Path $javaRoot "bin\j9vm\jvm.dll"),
        (Join-Path $javaRoot "jre\bin\j9vm\jvm.dll")
    )
    $runtimeLib = ($runtimeLibCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
    if (-not $runtimeLib) { $runtimeLib = "$javaRoot\bin\server\jvm.dll" }
    $runtimeLibExpanded = $runtimeLib -replace [regex]::Escape($javaRoot), '%SystemDrive%\OSDCloud\Config\Tools\java'

    reg.exe add "HKLM\SOFTWARE\JavaSoft\Java Runtime Environment" /v CurrentVersion /t REG_SZ /d "1.8" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\JavaSoft\Java Runtime Environment\1.8" /v JavaHome /t REG_EXPAND_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\java" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\JavaSoft\Java Runtime Environment\1.8" /v MicroVersion /t REG_SZ /d "0" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\JavaSoft\Java Runtime Environment\1.8" /v RuntimeLib /t REG_EXPAND_SZ /d "$runtimeLibExpanded" /f | Out-Null

    reg.exe add "HKLM\SOFTWARE\WOW6432Node\JavaSoft\Java Runtime Environment" /v CurrentVersion /t REG_SZ /d "1.8" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\WOW6432Node\JavaSoft\Java Runtime Environment\1.8" /v JavaHome /t REG_EXPAND_SZ /d "%SystemDrive%\OSDCloud\Config\Tools\java" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\WOW6432Node\JavaSoft\Java Runtime Environment\1.8" /v MicroVersion /t REG_SZ /d "0" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\WOW6432Node\JavaSoft\Java Runtime Environment\1.8" /v RuntimeLib /t REG_EXPAND_SZ /d "$runtimeLibExpanded" /f | Out-Null

    Write-ApplyLog "Java (Semeru) compatibility registry keys applied"
}
else {
    Write-ApplyLog "Java binary not found at $javaExe; skipped Java registry compatibility" "WARN"
}

$aimRoot = "X:\OSDCloud\Config\ArsenalImageMounter"
$aimSettingsPath = Join-Path $aimRoot "AIM-Settings.json"
if (Test-Path $aimSettingsPath) {
    try {
        $aimSettings = Get-Content $aimSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($aimSettings.Enabled) {
            Write-ApplyLog "AIM settings enabled; staging driver/runtime..."

            $aimRuntimeSrc = Join-Path $aimRoot "Runtime"
            if (Test-Path $aimRuntimeSrc) {
                robocopy $aimRuntimeSrc "X:\Windows\System32" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            }

            $aimDriverSrc = Join-Path $aimRoot "Driver"
            if (Test-Path $aimDriverSrc) {
                $infFiles = Get-ChildItem $aimDriverSrc -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue
                foreach ($inf in $infFiles) {
                    pnputil.exe /add-driver "$($inf.FullName)" /install | Out-Null
                }
            }

            $aimExe = "X:\Windows\System32\AimRamdrive.exe"
            if (Test-Path $aimExe) {
                $size  = [string]$aimSettings.Ramdisk.Size
                $drive = [string]$aimSettings.Ramdisk.DriveLetter
                $label = [string]$aimSettings.Ramdisk.Label
                $fmt   = [string]$aimSettings.Ramdisk.Format

                if ([string]::IsNullOrWhiteSpace($drive)) { $drive = 'R' }
                $drive = ($drive -replace ':','').Trim().ToUpperInvariant()

                $argLine = "$size $drive $label $fmt"
                Write-ApplyLog "Initializing AIM ramdisk: $argLine"
                $proc = Start-Process -FilePath $aimExe -ArgumentList $argLine -PassThru -Wait -WindowStyle Hidden

                $driveRoot = "${drive}:\"
                if ($proc.ExitCode -eq 0 -and (Test-Path $driveRoot)) {
                    Write-ApplyLog "AIM ramdisk ready at $driveRoot"
                    if ([bool]$aimSettings.Ramdisk.UseForTemp) {
                        $tempPath = Join-Path $driveRoot "Temp"
                        New-Item $tempPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                        [Environment]::SetEnvironmentVariable("TEMP", $tempPath, "Machine")
                        [Environment]::SetEnvironmentVariable("TMP",  $tempPath, "Machine")
                        $env:TEMP = $tempPath
                        $env:TMP  = $tempPath
                        Write-ApplyLog "TEMP/TMP moved to $tempPath"
                    }
                }
                else {
                    Write-ApplyLog "AIM ramdisk init failed (exit code $($proc.ExitCode)); continuing without ramdisk" "WARN"
                }
            }
            else {
                Write-ApplyLog "AimRamdrive.exe not found in X:\Windows\System32; skipping ramdisk init" "WARN"
            }
        }
        else {
            Write-ApplyLog "AIM settings present but disabled; skipping ramdisk init"
        }
    }
    catch {
        Write-ApplyLog "AIM init error: $_" "WARN"
    }
}
else {
    Write-ApplyLog "AIM settings not found; skipping ramdisk init"
}

# Mirrors PhoenixPE behavior note: this binary can destabilize shell state in PE.
$cloudStoreDll = "X:\Windows\System32\Windows.CloudStore.dll"
if ($packApplied -and (Test-Path $cloudStoreDll)) {
    Remove-Item $cloudStoreDll -Force -ErrorAction SilentlyContinue
}

# Keep shell host aligned with an Explorer-like desktop when dependency pack is present.
if ($packApplied) {
    reg.exe add "HKLM\SYSTEM\Setup" /v CmdLine /t REG_SZ /d "cmd.exe" /f | Out-Null
    reg.exe add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /t REG_SZ /d "explorer.exe" /f | Out-Null
}

Write-ApplyLog "GUI shell pack apply complete" "OK"
'@
    Set-Content "$scriptsDir\Apply-GuiShellPack.ps1" -Value $applyPackPs1 -Encoding UTF8
    Write-Status "Apply-GuiShellPack.ps1 written" -Type Success

    # ---- Recovery-Dashboard.hta ---------------------------------------------
    # Persistent launcher HTA — serves as the "desktop" in WinPE.
    # Double-quoted here-string: $osdArgs is expanded at BUILD TIME.
    $toolsPath = "X:\OSDCloud\Config\Tools"
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

    # startnet.cmd tail: apply shell pack first, then show HTA menu after WiFi init
    # Do NOT pass -StartOSDCloud -- the HTA owns boot routing
    $editParams.Startnet = 'powershell.exe -ExecutionPolicy Bypass -NoLogo -File "X:\OSDCloud\Config\Scripts\Apply-GuiShellPack.ps1" & start /wait mshta.exe "X:\OSDCloud\Config\Scripts\Select-Mode.hta"'

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
Invoke-BuildGuiShellPack
Invoke-StageAIMRamdisk
Invoke-WriteWinPEScripts
Invoke-WinPEBuild

$sw.Stop()
Write-Host ""
Write-Status "=== Done in $($sw.Elapsed.ToString('hh\:mm\:ss')) ===" -Type Success
Get-ChildItem "$Workspace\*.iso" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Status "ISO: $($_.FullName)  ($([math]::Round($_.Length/1MB,0)) MB)" -Type Info
}
Write-Host ""

