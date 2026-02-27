# OSDCloud Clean WinRE LiveBoot - Complete Guide

**Version:** 3.0.0  
**Date:** February 2026  
**Status:** Production Ready

## Overview

A complete, production-ready Windows PE/WinRE distribution based on OSD (OSDeploy) framework:
- ✅ OSD-native build pipeline — no manual DISM WIM mounting
- ✅ **Deploy ISO** (`Build-OSDCloud-Clean.ps1`) — ZTI/GUI LIBR deployment, minimal footprint
- ✅ **Recovery ISO** (`Build-Recovery-BakedIn.ps1`) — HTA boot menu: LIBR deploy OR full desktop (Chrome, 7-Zip, Java Semeru 8 baked in)
- ✅ **Recovery ISO** (`Build-Recovery-OnDemand.ps1`) — same HTA menu but lighter WIM; tools download at boot
- ✅ No Scoop dependencies — direct portable downloads only
- ✅ Driver injection support (`Drivers\` folder + `-DriversPath` parameter)
- ✅ Custom wallpaper support (`-WallpaperPath` parameter)
- ✅ Clean system deployments

## Architecture

```
OSD-DEV/
├── Build-OSDCloud-Clean.ps1          (Main build script)
├── Optimize-WinRE.ps1                (Size optimization)
├── Quick-Launch.ps1                  (Interactive menu)
├── Verify-Environment.ps1            (Pre-flight check)
├── Drivers/                          (Optional .inf driver injection)
│   └── README.md
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

```powershell
.\Build-Recovery-BakedIn.ps1
.\Build-Recovery-BakedIn.ps1 -StagingPath D:\Downloads  # custom download cache
```

### 3. **Build-Recovery-OnDemand.ps1**
Same HTA boot menu as BakedIn, but the WIM carries no pre-staged tools.  
When the user selects "Windows Recovery OS", `Start-RecoveryMode-OnDemand.ps1` runs inside WinPE  
and downloads Chrome, 7-Zip and Java into `X:\RecoveryTools\` on the RAM disk.

> Requires ~350 MB free on `X:\`. Machine should have **at least 4 GB RAM**. Network must be connected.

```powershell
.\Build-Recovery-OnDemand.ps1
```

### 4. **Optimize-WinRE.ps1**

WIM size optimization utility:
- `CleanupTemp` — Remove temp files, logs, caches from mounted WIM
- `CompressWIM` — Recompress boot.wim with maximum DISM compression
- `RemoveBlob` — Remove unused system components
- `OptimizeAll` — Run all of the above in sequence
- `Analyze` — Mount WIM and show size breakdown by component

**Parameters:**
```powershell
-Operation : CleanupTemp | CompressWIM | RemoveBlob | OptimizeAll | Analyze (default: OptimizeAll)
-Workspace : Path to workspace (default: C:\OSDCloud\WinRE)
-Mount     : WIM mount point (default: C:\Mount)
```

**Usage:**
```powershell
# Run full optimization
.\Optimize-WinRE.ps1 -Operation OptimizeAll

# Just analyze current size
.\Optimize-WinRE.ps1 -Operation Analyze

# Cleanup temporary files only
.\Optimize-WinRE.ps1 -Operation CleanupTemp
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

### Step 3: (Optional) Optimize Size
```powershell
.\Optimize-WinRE.ps1 -Operation OptimizeAll
```

Typical size reduction: **20-30%**

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
  └ mshta.exe Select-Mode.hta      (HTA boot menu)
        ├─ LIBR button     → PowerShell Start-OSDCloud -ZTI -Restart
        └─ Recovery button → PowerShell Start-RecoveryMode[OnDemand].ps1
                                └ creates desktop shortcuts
                                └ sets JAVA_HOME / PATH
                                └ Start-Process explorer.exe
```

## What Gets Installed

Applications are portable (no MSI/Scoop) and staged into the WIM via OSD's automatic `Config\` Robocopy.

**Deploy ISO** (`Build-OSDCloud-Clean.ps1`) — no extra tools; WinPE uses OSD built-ins only.

**Recovery ISOs** — tools at `X:\OSDCloud\Config\Tools\` (BakedIn) or `X:\RecoveryTools\` (OnDemand):

| Component | Version | Size | In WinPE |
|-----------|---------|------|----------|
| IBM Semeru JRE 8 (OpenJ9) | 8u422+ | ~150 MB | `...\Tools\java` |
| Google Chrome (portable) | 131+ | ~170 MB | `...\Tools\chrome` |
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
| **Windows Recovery OS** | Runs `Start-RecoveryMode[OnDemand].ps1` → desktop + shortcuts |

**Recovery Desktop Shortcuts** (created by Start-RecoveryMode):
- **Chrome Browser** — portable, no first-run, custom profile dir
- **7-Zip** — 7zFM.exe GUI file manager
- **Java Prompt (Semeru 8)** — cmd.exe with `JAVA_HOME` pre-set
- **LIBR — OSD Deploy** — launches `Start-OSDCloudGUI` in PowerShell

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

Modify `Invoke-WinRECustomization` in [Build-OSDCloud-Clean.ps1](Build-OSDCloud-Clean.ps1) to add custom registry keys under the mounted WIM hives.

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

### Out of Disk Space
1. Run Optimize-WinRE.ps1
2. Clean download cache: `Remove-Item C:\BuildPayload\downloads -Recurse`
3. Use different workspace: `.\Build-OSDCloud-Clean.ps1 -Workspace "D:\OSD"`

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
# - IBM Semeru JRE 8: https://github.com/ibm-semeru-runtimes/open-jdk8u-releases/releases
# - Chrome: https://dl.google.com/release2/chrome/ (inspect network traffic for uncompressed URL)
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
