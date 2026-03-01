# OSDCloud Clean WinRE LiveBoot - Complete Guide

**Version:** 3.0.0  
**Date:** March 2026  
**Status:** Production Ready

## Overview

A complete, production-ready Windows PE/WinRE distribution based on OSD (OSDeploy) framework:
- ✅ OSD-native build pipeline — no manual DISM WIM mounting
- ✅ **Deploy ISO** (`Build-OSDCloud-Clean.ps1`) — ZTI/GUI LIBR deployment, minimal footprint
- ✅ **Recovery ISO** (`Build-Recovery-BakedIn.ps1`) — HTA boot menu: LIBR deploy OR full desktop (Chrome, 7-Zip, Java Semeru 8 baked in)
- ✅ **Recovery ISO** (`Build-Recovery-OnDemand.ps1`) — same HTA menu but lighter WIM; tools download at boot
- ✅ Optional GUI shell compatibility pack from Windows install media (`install.wim/.esd/.iso/folder`) with auto-acquire + ESD→WIM export
- ✅ Boot-time compatibility wiring for Chrome + Java (App Paths, associations, JavaSoft compatibility keys)
- ✅ Optional AIM RAM disk staging and boot initialization with non-blocking fallback
- ✅ Boot-time dependency logging (`X:\OSDCloud\Logs\DependencyCheck.log`) in non-blocking mode
- ✅ No Scoop dependencies — direct portable downloads only
- ✅ Driver injection support (`Drivers\` folder + `-DriversPath` parameter)
- ✅ Custom wallpaper support (`-WallpaperPath` parameter)
- ✅ Clean system deployments

## Architecture

```
OSD-DEV/
├── Build-OSDCloud-Clean.ps1          (Deploy ISO builder)
├── Build-Recovery-BakedIn.ps1        (Recovery ISO — tools in WIM)
├── Build-Recovery-OnDemand.ps1       (Recovery ISO — tools download at boot)
├── Build-Image-OldWay.ps1            (Legacy build approach)
├── Quick-Launch.ps1                  (Interactive menu)
├── Verify-Environment.ps1            (Pre-flight check)
└── README.md                         (This file)

C:\OSDCloud\WinRE\                   (Generated output)
├── OSDCloud.iso                       (Bootable ISO)
└── Media/sources/boot.wim            (Customized WinPE kernel)
```

## Components

### 1. **Build-OSDCloud-Clean.ps1**
Deploy-only ISO builder. Uses native OSD cmdlets exclusively — no manual WIM mounting. Produces a ZTI or GUI-mode deployment ISO for LIBR.

**Parameters:**
```powershell
-Mode          : Full | BuildWinRE | BuildISO (default: Full)
-Workspace     : Output path (default: C:\OSDCloud\WinRE)
-BootMode      : ZTI | GUI (default: ZTI)
-OSName        : e.g. 'Windows 11 24H2 x64'
-OSLanguage    : e.g. en-us
-OSEdition     : e.g. Enterprise
-OSActivation  : Volume | Retail
-CloudDriver   : Driver pack array (default: @('*'))
-WirelessConnect : Include WiFi init in startnet.cmd
-DriversPath   : Path to extra .inf drivers to inject
-WallpaperPath : Custom .jpg wallpaper for WinPE desktop
-ForceTemplate : Rebuild OSDCloud Template even if it exists
```

**Usage:**
```powershell
# Full build
.\Build-OSDCloud-Clean.ps1 -Mode Full

# ZTI with specific OS
.\Build-OSDCloud-Clean.ps1 -OSName 'Windows 11 24H2 x64' -OSEdition Enterprise

# ISO only from existing WinRE
.\Build-OSDCloud-Clean.ps1 -Mode BuildISO
```

### 2. **Build-Recovery-BakedIn.ps1**
Recovery ISO builder. Downloads Chrome, 7-Zip and IBM Semeru JRE 8 to `$Workspace\Config\Tools\`  
during build. OSD's `Edit-OSDCloudWinPE` Robocopy-mirrors `Config\` into the WIM automatically.  
At boot: HTA menu offers LIBR ZTI deploy or a full Recovery Desktop (explorer.exe + shortcuts).  
When `-BuildGuiShellPack` is used, the script can source install media from `-InstallWimPath` or auto-resolve from `-InstallMediaPath` (or workspace media), including automatic `.esd` export to `.wim`.

```powershell
.\Build-Recovery-BakedIn.ps1
.\Build-Recovery-BakedIn.ps1 -StagingPath D:\Downloads  # custom download cache

# Build GUI shell compatibility pack from a local install.wim
.\Build-Recovery-BakedIn.ps1 -BuildGuiShellPack -InstallWimPath "D:\sources\install.wim" -InstallWimIndex 6

# Auto-acquire from install.esd (exports selected index to WIM automatically)
.\Build-Recovery-BakedIn.ps1 -BuildGuiShellPack -InstallMediaPath "D:\sources\install.esd" -InstallWimIndex 6

# Auto-acquire from Windows ISO (mounts ISO, locates install.wim/esd, exports if needed)
.\Build-Recovery-BakedIn.ps1 -BuildGuiShellPack -InstallMediaPath "D:\ISO\Win11_24H2_English_x64.iso" -InstallWimIndex 6

# Enable pack build with no explicit path (auto-tries workspace media candidates)
.\Build-Recovery-BakedIn.ps1 -BuildGuiShellPack -InstallWimIndex 6
```

**GUI shell pack source parameters:**
```powershell
-BuildGuiShellPack      : Enables compatibility pack creation from Windows install media
-InstallWimPath         : Direct path to install.wim (preferred if already available)
-InstallMediaPath       : Optional path to .wim, .esd, .iso, or media folder
-AutoAcquireInstallWim  : Auto-resolve/export WIM from media candidates (default: enabled)
-InstallWimIndex        : Source image index used for mounting/export
```

**Quick-Launch integration:**
- Menu option `4` now prompts for optional GUI shell pack build.
- You can provide install media path interactively or leave blank for auto-acquire.

### 3. **Build-Recovery-OnDemand.ps1**
Same HTA boot menu as BakedIn, but the WIM carries no pre-staged tools.  
When the user selects "Windows Recovery OS", `Start-RecoveryMode-OnDemand.ps1` runs inside WinPE  
and downloads Chrome, 7-Zip and Java into `X:\RecoveryTools\` on the RAM disk.

> Requires ~350 MB free on `X:\`. Machine should have **at least 4 GB RAM**. Network must be connected.

```powershell
.\Build-Recovery-OnDemand.ps1
```

**Parameters:**
```powershell
-Workspace       : Output path (default: C:\OSDCloud\WinRE)
-OSName          : e.g. 'Windows 11 24H2 x64'
-OSLanguage      : e.g. en-us
-OSEdition       : e.g. Enterprise
-OSActivation    : Volume | Retail
-CloudDriver     : Driver pack array (default: @('*'))
-WirelessConnect : Include WiFi init in startnet.cmd
-DriversPath     : Path to extra .inf drivers (default: .\Drivers)
-WallpaperPath   : Custom .jpg wallpaper for WinPE desktop
-ForceTemplate   : Rebuild OSDCloud Template even if it exists
-ChromeUrl       : Override Chrome download URL
-SevenZipUrl     : Override 7-Zip download URL
-JavaUrl         : Override Java download URL
```
## Quick Start Guide

### Prerequisites
- Windows 10/11 or Windows Server 2019/2022
- PowerShell 5.1+ (run as **Administrator**)
- ~50GB free disk space
- Internet connection (first build ~1-2GB downloads)

### Step 1: Verify Environment
```powershell
# Run as Administrator
.\Verify-Environment.ps1
```

### Step 2: Build WinRE Distribution
```powershell
# Run as Administrator
.\Build-OSDCloud-Clean.ps1 -Mode Full
```

**Expected Output:**
- ✓ Creates OSD WinRE template
- ✓ Customizes WinPE with OSD built-ins (7za, WiFi, cloud drivers)
- ✓ Generates ISO file (~300-400 MB)
- ⏱ Total time: 5-15 minutes (no app downloads)

Typical size reduction: **20-30%**

### Step 3: Build Recovery ISO (optional)
```powershell
# Tools baked into WIM (~20+ min, larger ISO, no network needed at boot)
.\Build-Recovery-BakedIn.ps1

# OR: lightweight WIM, tools download at boot (~5 min build, needs network at boot)
.\Build-Recovery-OnDemand.ps1
```

**Expected Output:**
- ✓ Creates HTA dual-mode boot menu (LIBR deploy OR Recovery Desktop)
- ✓ BakedIn: Chrome, 7-Zip, Java Semeru 8 pre-staged in WIM (~600-700 MB ISO)
- ✓ OnDemand: lighter WIM (~300-400 MB ISO), downloads ~350 MB at boot

### Step 4: Boot & Test

```powershell
# Find ISO
Get-Item "C:\OSDCloud\WinRE\*.iso"
```

Burn to USB with **Ventoy** or **Rufus**, then boot.

### Boot Sequence (Recovery ISO)

```
wpeinit
  └ Initialize-OSDCloudStartnet   (WiFi drivers)
  └ Initialize-OSDCloudStartnetUpdate  (module refresh)
  └ PowerShell Apply-GuiShellPack.ps1
       └ (if present) apply ShellPack file+registry payload
       └ apply Chrome + Java compatibility registry wiring
       └ initialize AIM ramdisk if staged/enabled (non-blocking)
  └ mshta.exe Select-Mode.hta      (HTA boot menu)
        ├─ LIBR button     → PowerShell Start-OSDCloud -ZTI -Restart
        └─ Recovery button → PowerShell Start-RecoveryMode[OnDemand].ps1
                                └ (OnDemand: downloads Chrome, 7-Zip, Java)
                                └ sets JAVA_HOME / PATH
                                └ writes dependency log (baked-in mode)
                                └ launches Recovery-Dashboard.hta
                                      └ persistent launcher with 8 tool buttons
```

## What Gets Installed

Applications are portable (no MSI/Scoop) and staged into the WIM via OSD's automatic `Config\` Robocopy.

**Deploy ISO** (`Build-OSDCloud-Clean.ps1`) — no extra tools; WinPE uses OSD built-ins only.

**Recovery ISOs** — tools at `X:\OSDCloud\Config\Tools\` (BakedIn) or `X:\RecoveryTools\` (OnDemand):

| Component | Version | Size | In WinPE |
|-----------|---------|------|----------|
| IBM Semeru JRE 8 (OpenJ9) | 8u482+ | ~150 MB | `...\Tools\java` |
| Google Chrome (portable) | 145+ | ~170 MB | `...\Tools\chrome` |
| 7-Zip (FM + CLI) | 24.09 | ~5 MB | `...\Tools\7zip` |
| 7za.exe (CLI only) | built-in | ~1 MB | `X:\Windows\System32\7za.exe` (all ISOs) |

Environment variables set in WinPE at Recovery Desktop launch:
- `JAVA_HOME = ...\Tools\java`
- `PATH` extended with `java\bin`, `chrome`, `7zip`

## Included Launchers

**Deploy ISO** boots directly into startnet.cmd which calls `Start-OSDCloud` with ZTI/GUI parameters.

**Recovery ISO** boots into the HTA menu (`Select-Mode.hta`):

| Button | Action |
|--------|--------|
| **LIBR** | Runs `Start-OSDCloud -ZTI -Restart` (full automated deploy) |
| **Recovery Dashboard** | Runs `Start-RecoveryMode[OnDemand].ps1` → launches Recovery Dashboard HTA |

**Recovery Dashboard** (`Recovery-Dashboard.hta`) — persistent launcher panel with 8 buttons:

| Button | Action |
|--------|--------|
| **Chrome** | Portable Chrome browser (no first-run, custom profile) |
| **7-Zip** | 7zFM.exe GUI file manager |
| **Java Prompt** | cmd.exe with `JAVA_HOME` pre-set (Semeru 8) |
| **PowerShell** | Windows PowerShell session |
| **Command Prompt** | cmd.exe |
| **Notepad** | Text editor |
| **Disk Management** | diskpart |
| **LIBR Deploy** | `Start-OSDCloudGUI` in PowerShell |

## Advanced Customization

### Add Applications to Recovery Desktop
1. Add download logic in `Invoke-RecoveryToolsDownload` in [Build-Recovery-BakedIn.ps1](Build-Recovery-BakedIn.ps1)
2. Use portable zip/exe format (no `.msi` — WinPE has no `msiexec`)
3. Extract to `$Workspace\Config\Tools\<appname>` — OSD Robocopy injects it automatically
4. Add a desktop shortcut call in `Start-RecoveryMode.ps1` (written by `Invoke-WriteWinPEScripts`)

### Custom Drivers

Place `.inf`-based drivers under `Drivers\` in sub-folders:

```
Drivers\
  NIC\Intel-I225\e2f68.inf ...
  Storage\Samsung-NVMe\samsungnvme.inf ...
  WiFi\Intel-AX201\netwtw10.inf ...
```

Or pass a custom path: `.\Build-OSDCloud-Clean.ps1 -DriversPath "D:\MyDrivers"`

### Custom Wallpaper

```powershell
.\Build-OSDCloud-Clean.ps1 -Mode Full -WallpaperPath "C:\Images\corp-wallpaper.jpg"
```

### Registry Changes

**Deploy ISO** (`Build-OSDCloud-Clean.ps1`): Modify `Invoke-WinRECustomization` to add custom registry keys under the mounted WIM hives.

**Recovery ISOs** (`Build-Recovery-BakedIn.ps1` / `Build-Recovery-OnDemand.ps1`): These do not mount the WIM directly — they use OSD's `Edit-OSDCloudWinPE` and `Config\` injection. Runtime customization is done in the `Start-RecoveryMode*.ps1` scripts embedded inside the WIM.

## Troubleshooting

### Build Fails: "OSD Module Not Found"
```powershell
# Install OSD module
Install-Module OSD -Force -Scope CurrentUser
```

### Download Timeouts
Increase connection timeout in script:
```powershell
# Add to Invoke-Download function
$ProgressPreference = 'SilentlyContinue'
[System.Net.ServicePointManager]::DefaultConnectionLimit = 10
```

### ISO Won't Boot
1. Verify ISO creation completed
2. Use Ventoy or Rufus to write to USB
3. Check BIOS boot order
4. Try Legacy + UEFI boot modes

### WIM Mount Fails
```powershell
# Force unmount if stuck
Dismount-WindowsImage -Path "C:\Mount" -Discard

# Cleanup
[System.GC]::Collect()
Get-Process | Where-Object {$_.Name -like '*dism*'} | Stop-Process -Force
```

## Performance Tuning

- Run on SSD for significantly faster WIM operations
- Close other applications during build (DISM is CPU/IO intensive)
- First build is slowest due to downloads; subsequent builds reuse cached workspace

## Security Considerations

- Script requires **Administrator** — review before running in production
- All downloads are from official sources (IBM, Google, Microsoft, GitHub)
- No Scoop, no third-party package manager
- WinPE environment is isolated — no persistent changes to host OS

## Maintenance & Updates

### Regular Tasks

```powershell
# Update component URLs when new versions release:
# - IBM Semeru JRE 8: https://github.com/ibmruntimes/semeru8-binaries/releases
# - Chrome: https://github.com/Bush2021/chrome_installer/releases
# - 7-Zip: https://www.7-zip.org/download.html
# URLs are parameters on Build-Recovery-BakedIn.ps1 and Build-Recovery-OnDemand.ps1
# e.g.: .\Build-Recovery-BakedIn.ps1 -ChromeUrl "https://...new-url..."
```

### Rebuild Frequency
- **Monthly**: Check component updates
- **Quarterly**: Full rebuild with latest versions
- **As-needed**: Security fixes or driver updates

## Known Limitations

- WinPE has no `msiexec` — all applications must be portable/zip-based
- WinPE environment resets on reboot (no persistent storage by default)
- Chrome may require additional Visual C++ runtimes in some WinPE builds
- Driver injection requires `.inf` + `.sys` + `.cat` — standalone `.exe` drivers are not supported

## Support & Resources

- **OSD Module**: <https://osdcloud.osdeploy.com>
- **IBM Semeru Runtimes**: <https://developer.ibm.com/languages/java/semeru-runtimes>
- **OSDeploy Community**: <https://www.osdeploy.com>

## Contributing

To improve this project:
1. Test builds thoroughly
2. Document any custom modifications
3. Share optimization tips
4. Report issues with details

## License & Attribution

- **OSD Module**: MIT License — [OSDeploy](https://github.com/OSDeploy/OSD)
- **Windows PE**: Microsoft License
- **IBM Semeru Runtimes**: IBM open-source license

## Changelog

### v3.1.0 (March 2026)
- ✨ Added GUI shell pack install media auto-acquire (`.wim/.esd/.iso/folder`) with automatic ESD→WIM export
- ✨ Added boot-time Chrome compatibility registry wiring (App Paths, URL/file associations)
- ✨ Added boot-time Java Semeru compatibility wiring (`.jar` association, JavaSoft compatibility keys, App Paths)
- ✨ Added boot-time dependency logging mode (`DependencyCheck.log`) that never blocks dashboard launch
- ✨ Added optional AIM RAM disk staging/init with graceful fallback
- ✨ Updated Quick-Launch option 4 to prompt for optional GUI shell pack media source

### v3.0.0 (February 2026)
- ✨ Replaced manual DISM WIM-mount pipeline with native OSD cmdlet calls
- ✨ Removed WinXShell, PowerShell 7 — WinRE native `explorer.exe` + `Start-OSDCloudGUI` used instead
- ✨ Added `Build-Recovery-BakedIn.ps1` — HTA dual-mode boot menu, tools baked into WIM
- ✨ Added `Build-Recovery-OnDemand.ps1` — same HTA menu, tools downloaded at WinPE boot
- ✨ Tool paths moved from `X:\Tools\` to `X:\OSDCloud\Config\Tools\` (OSD Config injection)
- ✨ `Quick-Launch.ps1` updated with Recovery ISO menu entries (options 4 and 5)
- ✨ `Verify-Environment.ps1` updated to check all 5 build scripts
- ✨ Default workspace changed from `C:\OSDCloud\LiveWinRE` to `C:\OSDCloud\WinRE`

### v2.0.0 (February 2026)
- ✨ Replaced Cairo shell with WinXShell (10MB vs 20MB)
- ✨ Removed `BuildNetwork` mode — simplified to 3 build modes
- ✨ Switched Java from OpenJDK 11 (HotSpot) to IBM Semeru JRE 8 (OpenJ9)
- ✨ Added `-DriversPath` parameter for custom driver injection
- ✨ Added `-WallpaperPath` parameter for custom desktop background
- ✨ Added `Drivers\` folder with auto-injection support
- ✨ Added elapsed build time reporting
- ✨ New `Verify-Environment.ps1` with WinPE compatibility checks

### v1.0.0 (Initial)
- Initial release with Scoop-based approach (superseded)

---

**Last Updated:** February 27, 2026  
**Tested On:** Windows 11, Windows Server 2022  
**Status:** ✅ Production Ready
