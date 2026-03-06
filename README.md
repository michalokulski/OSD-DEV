# OSD WinPE/RAM OS Builder

**Version:** 1.4  
**Date:** March 2026  
**Status:** Experimental

## Overview

This repository provides scripts to build a custom Windows PE-based RAM OS with optional drivers, portable applications, and visual theming.  
The build pipeline uses manual DISM/PowerShell scripting, enhanced with the [OSD PowerShell module](https://www.powershellgallery.com/packages/OSD) for ADK detection, driver catalog lookup, and WiFi support.

- **Build-Image.ps1**: Modern, robust RAM OS builder. Two base WIM modes: traditional Windows ISO or local WinRE WIM. WinXShell + optional Explorer++ shell — no Microsoft `explorer.exe`.
- **Build-Image-OldWay.ps1**: Legacy OSDCloud-based build using OSD module cmdlets directly.

## Scripts

### 1. Build-Image.ps1

Advanced RAM OS builder with two operating modes:

#### Mode A — Traditional ISO (`-SourceISO`)
- Mounts a Windows 10/11 ISO, extracts `boot.wim`, builds WinPE from ADK OC packages.
- Wired networking only by default (`wpeinit`).
- Optionally add WiFi with `-IncludeWiFi` (injects all 7 required DLLs + Intel WiFi drivers + OSD module).

#### Mode B — WinRE base WIM (`-UseWinRE`, no ISO needed)
- Uses the build machine's own `winre.wim` as the base. Located via a 4-tier search: OSD `Copy-WinREWIM` → well-known paths → `ReAgent.xml` + offset-based partition mount → broad drive scan.
- Copies ADK `amd64\Media` for the ISO structure; exports WinRE into `sources\boot.wim`.
- Automatically enables full WiFi support — WinRE already contains `raschap`/`rastls` auth DLLs; only the 3 MDM DLLs + Intel WiFi drivers + `WirelessConnect.exe` are additionally injected.
- `StartNet.cmd` calls `Initialize-OSDCloudStartnet -WirelessConnect` → launches `WirelessConnect.exe` GUI SSID selector if not already online.

#### Common features (both modes)
- **No Microsoft `explorer.exe`** — shell is WinXShell (primary) + optional Explorer++ file manager, launched from `StartNet.cmd`. `winpeshl.ini` is removed so WinPE defaults to `cmd.exe /k StartNet.cmd` (OSD pattern).
- **WinXShell desktop config** (`winxshell.jcfg`) is generated automatically, pointing the desktop at `X:\Users\Public\Desktop` and wiring in the wallpaper path when provided.
- **WIM re-export with maximum (LZX) compression** after `DISM /Commit` — re-compresses all injected content via `/Compress:maximum` before packing into the ISO. Typically cuts WIM size from ~950 MB to ~450 MB, preventing the "Not enough memory resources" bootmgr error. **Never use `/Compress:recovery`** — it produces LZMS format which `winload.efi` cannot read (causes BSOD 0xc000000bb).
- ADK detection via OSD `Get-WindowsAdkPaths` (registry-based) with path-guessing fallback.
- Dell WinPE driver injection via OSD `Save-WinPECloudDriver -CloudDriver Dell` (auto-latest URL) with hardcoded-URL CAB fallback.
- Intel WiFi WinPE driver injection via OSD `Save-WinPECloudDriver -CloudDriver WiFi`.
- OSD module saved into WinPE image (`Save-Module OSD`) so `Start-WinREWiFi` / `Initialize-OSDCloudStartnet` are available at boot.
- Portable app integration: WinXShell, Explorer++ (optional), Chrome++ (with validation), IBM Semeru Java 8 (OpenJ9), 7-Zip, Sysinternals Suite.
- Java: `JAVA_HOME` set and `bin` appended to system `PATH` via `StartNet.cmd`.
- 7-Zip: portable full installer injected and added to `PATH`.
- Sysinternals Suite: injected into `Program Files\PortableApps\SysinternalsSuite` and added to `PATH` — place `SysinternalsSuite*.zip` in `Apps\`.
- Chrome++: validates `version.dll` co-location next to `chrome.exe`; multiple automatic fallback sources (Bush2021 GitHub SFX → CDN mirror → PortableApps paf.exe); graceful skip if all sources fail.
- Chrome shortcut targets `cmd.exe /c StartChrome.cmd` (shell-agnostic, works from WinXShell desktop).
- Chrome launcher writes profile/cache to `X:\` (volatile RAM, cleared on reboot).
- Custom wallpaper set via `winxshell.jcfg` (primary) and HKCU registry (secondary hint).
- Accent color stored as correct ARGB DWORD (`0xFFrrggbb`) in registry.
- UEFI (`efisys_noprompt.bin`) and legacy boot (`etfsboot.com`) — no "press any key" prompt.
- WIM index selection (`-WimIndex`: 1 = plain WinPE, 2 = WinPE+Setup; forced to 1 in WinRE mode).
- Optional FBWF overlay OC (`-EnableFBWF`).
- **ADK Enhancement** (`-EnhanceFromISO`) — optional inject pipeline sourcing from a full `install.wim`: Core runtime DLLs (D3D11, MSVC 2015–2022 runtimes, etc.), WiFi kernel drivers, iSCSI MOFs, Segoe fonts. Registry merge from install.wim hives (COM/CLSID, Svchost, LSA, TCP/IP, KnownDLLs). Drive-letter fix (C:\ → X:\), scratch-space configuration, MUI/telemetry/WMI slim. Optional extras: WoW64 32-bit subsystem (`-IncludeWoW64`), audio stack (`-IncludeAudio`), shell components (`-IncludeShell`). In ISO mode, `install.wim` is auto-detected from `-SourceISO`; in WinRE mode supply `-EnhanceFromISO <iso>`.

**Parameters:**

| Parameter | Required | Description |
|---|---|---|
| `-SourceISO` | ✅ (or `-UseWinRE`) | Path to Windows 10/11 ISO |
| `-UseWinRE` | ✅ (or `-SourceISO`) | Use local `winre.wim` as base — no ISO needed. Auto-enables WiFi. |
| `-IncludeWiFi` | | Inject WiFi support into a standard ISO-based build (7 DLLs + Intel drivers + WirelessConnect.exe + OSD module) |
| `-WorkRoot` | ✅ | Build working directory (20 GB free required) |
| `-UseChromePlus` | | Download & integrate Chrome++ |
| `-ChromeOfflineInstallerPath` | | Path to Chrome offline installer (`.exe`/`.zip`/`.7z`) — used as the first Chrome source if provided |
| `-ChromePortablePath` | | Alternate: local Chrome portable archive (`.zip`/`.7z`/`.exe`) |
| `-IncludeExplorerPlus` | | Include Explorer++ file manager |
| `-IncludeDellDrivers` | | Inject Dell WinPE 11 driver pack (OSD catalog, CAB fallback) |
| `-WallpaperPath` | | Custom wallpaper image (`.jpg`/`.jpeg`/`.png`/`.bmp`) |
| `-AccentColor` | | Hex RGB accent color (default: `0078D7`) |
| `-OutputISOName` | | Output ISO filename (default: `RAMOS_Desktop.iso`) |
| `-RamdiskSizeMB` | | Overlay size for FBWF (default: `4096`, range 1024–8192) |
| `-ADKPath` | | Path to WinPE add-on (auto-detected via OSD or path-guessing if omitted) |
| `-KeepMountedWIM` | | Preserve mounted WIM on failure (debug) |
| `-SkipCleanup` | | Skip cleanup after build |
| `-WimIndex` | | WIM index: `1` = WinPE, `2` = WinPE+Setup (default: `1`; forced `1` in WinRE mode) |
| `-EnableFBWF` | | Add WinPE-FBWF optional component |
| `-EnhanceFromISO` | | Windows ISO containing `install.wim` to inject from. In ISO mode, auto-detected from `-SourceISO`. In WinRE mode, required to enable enhancement. |
| `-InstallWimIndex` | | Index inside `install.wim` to use (default: `1`) |
| `-IncludeWoW64` | | Inject WoW64 (32-bit subsystem) — ~150+ DLLs. Required for 32-bit apps. Adds ~150–300 MB. |
| `-IncludeAudio` | | Inject audio subsystem (audiodg, WASAPI, etc.) from `install.wim` |
| `-IncludeShell` | | Inject shell components (Explorer, DWM, XAML) from `install.wim` |
| `-ScratchSpaceMB` | | WinPE scratch-space size in MB (`32`/`64`/`128`/`256`/`512`, default: `512`) |

**Usage Examples:**

```powershell
# Minimal WinRE mode — no ISO needed, WiFi auto-enabled
.\Build-Image.ps1 -UseWinRE -WorkRoot "D:\Build"

# WinRE mode with common extras
.\Build-Image.ps1 -UseWinRE -WorkRoot "D:\Build" `
  -IncludeDellDrivers -UseChromePlus -IncludeExplorerPlus

# Full WinRE build — every useful flag enabled (recommended)
.\Build-Image.ps1 `
  -UseWinRE `
  -WorkRoot "D:\Build" `
  -EnhanceFromISO "C:\Win11.iso" `
  -InstallWimIndex 1 `
  -IncludeWiFi `
  -IncludeDellDrivers `
  -UseChromePlus `
  -IncludeExplorerPlus `
  -IncludeWoW64 `
  -IncludeAudio `
  -IncludeShell `
  -WallpaperPath "C:\Images\wallpaper.jpg" `
  -AccentColor "0078D7" `
  -OutputISOName "RAMOS_Full.iso" `
  -ScratchSpaceMB 512

# Traditional ISO mode — wired only, minimal
.\Build-Image.ps1 -SourceISO "C:\Win11.iso" -WorkRoot "D:\Build"

# Traditional ISO mode with WiFi, drivers, and wallpaper
.\Build-Image.ps1 -SourceISO "C:\Win11.iso" -WorkRoot "D:\Build" `
  -IncludeWiFi -IncludeDellDrivers -IncludeExplorerPlus `
  -WallpaperPath "C:\Images\wallpaper.jpg"

# Full ISO mode — ADK Enhancement + all optional components
.\Build-Image.ps1 -SourceISO "C:\Win11.iso" -WorkRoot "D:\Build" `
  -UseChromePlus -IncludeExplorerPlus -IncludeDellDrivers `
  -IncludeWoW64 -IncludeAudio -IncludeShell `
  -WallpaperPath "C:\Images\wallpaper.jpg" `
  -OutputISOName "RAMOS_Full.iso"
```

> **Note on Chrome++:** `-ChromeOfflineInstallerPath` is optional. The script automatically tries 4 sources for the Chrome program files: user-supplied archive → Bush2021 GitHub SFX → CDN mirror → PortableApps paf.exe. All sources are extracted with 7-Zip only — never executed as a process.

> **Note on WiFi:** WiFi requires the OSD module (`Install-Module OSD`) on the build machine for Intel driver injection and `Save-Module OSD` into WinPE. Without it, DLLs and `WirelessConnect.exe` are still injected but adapter enumeration may fail on Intel hardware.

> **Note on WinXShell:** The official download URL embeds a forum session token that expires. Place a `WinXShell*.7z` or `WinXShell*.zip` archive directly in the `Apps\` folder (next to the script) to use it without downloading. See [Apps/README.md](Apps/README.md).

> **Note on Sysinternals Suite:** No automatic download URL is configured. Place `SysinternalsSuite.zip` (or any `SysinternalsSuite*.zip`) in the `Apps\` folder before building — the script will abort with a clear error if it is missing.

### 2. Build-Image-OldWay.ps1

Legacy OSDCloud-based build using the OSD PowerShell module.
- Creates an OSDCloud template (`WinRE`) and workspace.
- Customizes WinPE via `Edit-OSDCloudWinPE`.
- No manual WIM mounting — relies entirely on OSD cmdlets.

**Usage Example:**
```powershell
.\Build-Image-OldWay.ps1
```

### 3. Quick-Launch.ps1

Menu-driven launcher for common tasks:
- Build RAM OS (ISO mode or WinRE mode) — calls `Build-Image.ps1` interactively
- Build RAM OS (legacy) — calls `Build-Image-OldWay.ps1`
- Run environment verification
- Open output folder
- Clean build artifacts (guidance)

**Usage:**
```powershell
.\Quick-Launch.ps1
```

### 4. Verify-Environment.ps1

Performs pre-flight checks before building:
- OS version, admin rights, PowerShell version
- Disk space (20 GB minimum)
- Required scripts present
- OSD module installation and version
- DISM and OSCDIMG availability
- Windows ADK + WinPE add-on detection
- WinPE optional components folder
- WinRE availability (`reagentc /info`) for `-UseWinRE` mode
- Network connectivity and download URL reachability
- Build parameter reminders

**Usage:**
```powershell
.\Verify-Environment.ps1
```

## Directory Structure

```
OSD-DEV/
├── Build-Image.ps1           (Main RAM OS builder — ISO mode or WinRE mode)
├── Build-Image-OldWay.ps1    (Legacy OSDCloud-based build)
├── Quick-Launch.ps1          (Interactive menu launcher)
├── Verify-Environment.ps1    (Pre-flight environment check)
├── Apps/                     (Pre-staged app archives — git-ignored except README)
│   ├── WinXShell*.7z/.zip    (optional — avoids forum download)
│   ├── SysinternalsSuite*.zip (required — no download URL configured)
│   └── README.md
└── README.md
```

> Place pre-downloaded archives in `Apps\` and the build script picks them up automatically. `WinXShell*.7z/.zip` skips the forum download; `SysinternalsSuite*.zip` is **required** (no download URL is configured — the build will abort without it). Only `README.md` is tracked by Git — everything else in that folder is ignored.

**Generated build output** (under `-WorkRoot`, e.g. `D:\Build`):

```
D:\Build\
├── ISO_Source\               (ADK media or extracted source ISO contents)
├── Mount_WIM\                (WIM mount point)
├── Apps\                     (Downloaded portable apps — staging area)
├── Cache\                    (Download cache — survives rebuilds)
├── Temp\                     (Temporary extraction workspace)
└── Output\
    ├── RAMOS_Desktop.iso     (Final bootable ISO)
    └── Build-<timestamp>.log (Full build transcript)
```

## Prerequisites

- Windows 10/11 or Windows Server 2019/2022
- [Windows ADK](https://aka.ms/adk) with **WinPE add-on** and **Deployment Tools** installed
- PowerShell 5.1+ (run as **Administrator**)
- [OSD module](https://www.powershellgallery.com/packages/OSD): `Install-Module OSD` — **strongly recommended**  
  *(Required for: registry-based ADK detection, Intel WiFi driver injection, OSD module in WinPE, dynamic Dell driver URL)*
- 20 GB+ free disk space on the build drive
- Internet connection (first build downloads ~500 MB+; Chrome SFX alone is ~450 MB)
- For `-UseWinRE`: WinRE must be enabled on the build machine (`reagentc /enable`)

## Included Components (downloaded at build time)

| Component | Version | Purpose |
|---|---|---|
| WinXShell | latest (from `Apps\` or forum URL) | Lightweight WinPE desktop shell |
| IBM Semeru JDK 8 (OpenJ9) | 8u482-b08 (primary), 8u472-b08 (fallback) | Java runtime (~175 MB, needs ≥ 2 GB RAM target) |
| 7-Zip | 24.08 (extra portable) | Archiver (build-time extractor + injected into image) |
| Sysinternals Suite | from `Apps\SysinternalsSuite*.zip` | Microsoft Sysinternals tools — ProcExp, Autoruns, etc. (added to `PATH`) |
| Explorer++ | 1.4.0 | Portable file manager (optional) |
| Chrome++ (Chrome Plus) | 1.15.1 patch + Chrome 145 program files | Patched Chromium browser (optional) |
| Dell WinPE 11 Drivers | OSD catalog (auto-latest), A08 fallback | Hardware drivers for Dell systems (optional) |
| Intel Wireless WinPE Drivers | OSD catalog (auto-latest) | WiFi adapter drivers (with `-UseWinRE` / `-IncludeWiFi`) |
| WirelessConnect.exe | latest | GUI SSID selector at boot (with `-UseWinRE` / `-IncludeWiFi`) |
| OSD Module | installed version | PowerShell module saved into WinPE for boot-time WiFi init |

## Quick Start

### Option A — WinRE mode (recommended, no ISO needed)

```powershell
# 1. Install OSD module (once)
Install-Module OSD -Force

# 2. Verify environment
.\Verify-Environment.ps1

# 3. Build
.\Build-Image.ps1 -UseWinRE -WorkRoot "D:\Build" -IncludeDellDrivers
```

### Option B — Traditional ISO mode

```powershell
# 1. Install OSD module (once)
Install-Module OSD -Force

# 2. Verify environment
.\Verify-Environment.ps1

# 3. Build
.\Build-Image.ps1 -SourceISO "C:\Win11.iso" -WorkRoot "D:\Build"
```

4. **Burn ISO to USB** (Ventoy / Rufus) or mount in VM and boot.

5. **At boot:** WinPE loads into RAM (`X:\`). In WinRE mode, if not already connected to a wired network, `WirelessConnect.exe` presents an SSID selection GUI. Once the desktop appears, boot media can be ejected. All changes are volatile and lost on reboot.

## WiFi — How It Works

`StartNet.cmd` calls `Initialize-OSDCloudStartnet -WirelessConnect` (from the OSD module saved into WinPE):

1. Skips WiFi if already online (wired DHCP succeeded)
2. Checks MDM DLLs are present (`dmcmnutils.dll` etc.)
3. Starts `WlanSvc` if not running
4. Detects WiFi adapter via `Get-SmbClientNetworkInterface`
5. Optionally reads HP UEFI pre-provisioned WiFi credentials
6. Launches `X:\Windows\WirelessConnect.exe` for GUI SSID selection, or falls back to text menu

**WiFi DLL injection:**
- **WinRE mode**: 3 MDM DLLs only (`dmcmnutils.dll`, `mdmpostprocessevaluator.dll`, `mdmregistration.dll`) — auth DLLs (`raschap`, `rastls`, etc.) are already present in `winre.wim`.
- **Plain WinPE + `-IncludeWiFi`**: All 7 DLLs injected (3 MDM + 4 auth).

If the OSD module was not saved into WinPE, `StartNet.cmd` falls back to `net start WlanSvc` + direct launch of `WirelessConnect.exe`.

## Boot Ramdisk Size

The WIM is re-exported with `DISM /Export-Image /Compress:maximum` (LZX compression) after committing all changes. This is critical: without recompression, the uncommitted delta blocks leave the WIM at ~950 MB+, which causes bootmgr to fail with **"Not enough memory resources are available to process this command"** at early boot, even on machines with ample RAM (the issue is contiguous physical address availability before the memory manager starts, not total RAM). `/Compress:recovery` (LZMS) is intentionally avoided — `winload.efi` cannot decompress LZMS and will BSOD 0xc000000bb.

After recompression, the WIM is typically ~450–550 MB — well within what any machine with ≥ 2 GB RAM can handle.

IBM Semeru JDK 8 adds ~175 MB to the compressed WIM on its own. If booting on machines with exactly 2 GB RAM is a concern, omit Java (remove it from the app sources) or replace it with a JRE-only build.

## Maintenance

- Update `$Script:AppSources` URLs in `Build-Image.ps1` when component versions change.
- Update OSD module: `Update-Module OSD`
- Re-run `Verify-Environment.ps1` after Windows updates or ADK reinstallation.
- The `Cache\` folder under `-WorkRoot` preserves downloads between builds — delete it to force re-download.
- For WinRE mode: if `winre.wim` is missing, run `reagentc /enable` and reboot.
- To use a specific WinXShell build, place the archive in `Apps\` (see `Apps\README.md`).

## License

- Scripts: MIT License  
- Windows PE: Microsoft License  
- Third-party apps: See respective upstream licenses

---

_Last updated: March 6, 2026_

