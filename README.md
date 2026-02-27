# OSDCloud Clean WinRE LiveBoot - Complete Guide

**Version:** 2.0.0  
**Date:** June 2025  
**Status:** Production Ready

## Overview

A complete, production-ready Windows PE/WinRE distribution based on OSD (OSDeploy) framework:
- ✅ Java 8 (IBM Semeru/OpenJ9), Chrome, PowerShell 7, WinXShell GUI
- ✅ ~400-500MB final ISO (optimized)
- ✅ No Scoop dependencies — direct portable downloads only
- ✅ Driver injection support (`Drivers\` folder + `-DriversPath` parameter)
- ✅ Custom wallpaper support (`-WallpaperPath` parameter)
- ✅ WinXShell lightweight desktop shell (10MB)
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

C:\OSDCloud\LiveWinRE\               (Generated output)
├── OSDCloud-LiveWinRE-Clean.iso      (Bootable ISO)
└── Media/sources/boot.wim            (Customized WinPE kernel)
```

## Components

### 1. **Build-OSDCloud-Clean.ps1**
Main build orchestrator that:
- Downloads and prepares applications
- Creates OSD WinRE template
- Customizes WinRE with tools
- Configures registry and environment variables
- Generates launchers and shortcuts
- Creates final ISO

**Parameters:**
```powershell
-Mode          : BuildWinRE | BuildISO | Full (default: Full)
-Workspace     : Path to workspace (default: C:\OSDCloud\LiveWinRE)
-Mount         : WIM mount point (default: C:\Mount)
-BuildPayload  : Download/staging area (default: C:\BuildPayload)
-IsoName       : ISO filename (default: OSDCloud-LiveWinRE-Clean)
-DriversPath   : Path to extra .inf drivers to inject (default: .\Drivers)
-WallpaperPath : Custom wallpaper for WinXShell desktop (optional)
```

**Usage Examples:**
```powershell
# Full build (download, customize, create ISO)
.\Build-OSDCloud-Clean.ps1 -Mode Full

# Only customize WinRE without ISO
.\Build-OSDCloud-Clean.ps1 -Mode BuildWinRE

# Only create ISO from existing WinRE
.\Build-OSDCloud-Clean.ps1 -Mode BuildISO
```

### 2. **Optimize-WinRE.ps1**

WIM size optimization utility:
- `CleanupTemp` — Remove temp files, logs, caches from mounted WIM
- `CompressWIM` — Recompress boot.wim with maximum DISM compression
- `RemoveBlob` — Remove unused system components
- `OptimizeAll` — Run all of the above in sequence
- `Analyze` — Mount WIM and show size breakdown by component

**Parameters:**
```powershell
-Operation : CleanupTemp | CompressWIM | RemoveBlob | OptimizeAll | Analyze (default: OptimizeAll)
-Workspace : Path to workspace (default: C:\OSDCloud\LiveWinRE)
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
- ✓ Downloads: Java, Chrome, WinXShell, PowerShell (~1-2GB total)
- ✓ Creates OSD WinRE template
- ✓ Customizes with tools and scripts
- ✓ Generates ISO file (~400-500MB)
- ⏱ Total time: 45-60 minutes

### Step 3: (Optional) Optimize Size
```powershell
.\Optimize-WinRE.ps1 -Operation OptimizeAll
```

Typical size reduction: **20-30%**

### Step 4: Boot & Test

```powershell
# Find ISO
Get-Item "C:\OSDCloud\LiveWinRE\*.iso"
```

Burn to USB with **Ventoy** or **Rufus**, then boot.

## What Gets Installed

Applications are downloaded as portable archives (no MSI/Scoop) and staged to `X:\Tools` inside the WinPE image:

| Component | Version | Size | Location in WinPE |
|-----------|---------|------|-------------------|
| IBM Semeru JRE 8 (OpenJ9) | 8u latest | ~150MB | `X:\Tools\java` |
| Google Chrome (portable) | Latest | ~100MB | `X:\Tools\chrome` |
| PowerShell 7 | 7.4.x | ~40MB | `X:\Tools\pwsh` |
| WinXShell | 0.2.x | ~10MB | `X:\Tools\winxshell` |
| 7-Zip | Latest | ~5MB | `X:\Tools\7zip` |

Environment variables set in WinPE registry:
- `JAVA_HOME = X:\Tools\java`
- `PATH` extended with `X:\Tools\bin;X:\Tools\java\bin;X:\Tools\pwsh;X:\Tools\chrome;X:\Tools\winxshell;X:\Tools\7zip`

## Included Launchers

When booted, users can access:

**Desktop Shortcuts:**
- 📋 **OSD Deploy** - Launch system deployment
- 🔵 **Chrome Browser** - Web access
- 💻 **PowerShell** - Management console
- 📁 **File Explorer** - Filesystem browsing

**Mode Selector:**
Boots into menu to choose:
- **Deploy Mode** - Runs OSD deployment wizard
- **Desktop Mode** - Returns to WinXShell desktop with tools

## Advanced Customization

### Add Applications
1. Add download logic in `Invoke-ApplicationPrep` in [Build-OSDCloud-Clean.ps1](Build-OSDCloud-Clean.ps1)
2. Use portable zip format (no `.msi` — WinPE has no `msiexec`)
3. Extract to `$tools\<appname>` in `$BuildPayload\tools`

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
# Update component URLs in Build-OSDCloud-Clean.ps1 when new versions release:
# - IBM Semeru JRE 8: https://github.com/ibm-semeru-runtimes/open-jdk8u-releases/releases
# - Chrome: URL auto-resolves to latest
# - PowerShell 7: https://github.com/PowerShell/PowerShell/releases
# - WinXShell: https://github.com/slorelee/wimbuilder2
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
- **WinXShell**: <https://github.com/slorelee/wimbuilder2>
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
- **WinXShell**: MIT License — [slorelee/wimbuilder2](https://github.com/slorelee/wimbuilder2)
- **IBM Semeru Runtimes**: IBM open-source license

## Changelog

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
