# OSD WinPE/RAM OS Builder

**Version:** 1.1  
**Date:** March 2026  
**Status:** Experimental

## Overview

This repository provides scripts to build a custom Windows PE-based RAM OS with optional drivers, portable applications, and visual theming.  
The current build pipeline is based on manual DISM and PowerShell scripting, with two main approaches:

- **Build-Image.ps1**: Modern, robust, and feature-rich RAM OS builder.  
- **Build-Image-OldWay.ps1**: Legacy OSDCloud-based build using OSD module cmdlets.

## Scripts

### 1. Build-Image.ps1

Advanced RAM OS builder.  
- Converts a Windows ISO into a bootable WinPE-based RAM OS.
- Supports driver injection (Dell WinPE 11 pack).
- Portable app integration: Open-Shell, Explorer++, Chrome++ (with validation), IBM Semeru Java.
- Java: `JAVA_HOME` set and `bin` appended to system `PATH` (callable without full path).
- Semeru ZIP nested folder auto-flattened after extraction.
- Chrome++: Gracefully skips if no `chrome.exe` available and no offline installer provided (warns instead of crashing).
- Network initialization (`wpeutil InitializeNetwork`, `WaitForNetwork`, `DisableFirewall`) in StartNet.cmd for connectivity at boot.
- Custom wallpaper and accent color support.
- Robust ADK/WinPE add-on detection and logging.
- UEFI and legacy boot support.

**Usage Example:**
```powershell
.\Build-Image.ps1 -SourceISO "C:\Win11.iso" -WorkRoot "D:\Build" -UseChromePlus -IncludeDellDrivers -IncludeExplorerPlus -ChromeOfflineInstallerPath "C:\Downloads\ChromeStandaloneSetup64.exe"
```

> **Note:** When using `-UseChromePlus`, you should also pass `-ChromeOfflineInstallerPath` pointing to  
> Chrome's standalone offline installer (`.exe`), because the Chrome++ `.7z` only contains the patch DLL  
> (`version.dll`), not the Chrome program files themselves.

See script comments for full parameter documentation.

### 2. Build-Image-OldWay.ps1

Legacy OSDCloud-based build using the OSD PowerShell module.  
- Creates an OSDCloud template and workspace.
- Customizes WinPE via OSDCloud cmdlets.

**Usage Example:**
```powershell
.\Build-Image-OldWay.ps1
```

### 3. Quick-Launch.ps1

Menu-driven launcher for common tasks:
- Build RAM OS (calls Build-Image.ps1)
- Run environment verification
- Clean build artifacts

### 4. Verify-Environment.ps1

Performs pre-flight checks:
- OS version, admin rights, PowerShell version
- Disk space
- Required scripts
- DISM, OSCDIMG, and Windows ADK WinPE add-on availability
- WinPE optional components folder
- Network connectivity and download URL reachability
- Build parameter reminders (Chrome++ offline installer, Java PATH, network init)

## Directory Structure

```
OSD-DEV/
├── Build-Image.ps1
├── Build-Image-OldWay.ps1
├── Quick-Launch.ps1
├── Verify-Environment.ps1
├── README.md
└── .trunk/
```

## Prerequisites

- Windows 10/11 or Server 2019/2022
- [Windows ADK](https://aka.ms/adk) + WinPE add-on installed
- PowerShell 5.1+ (run as Administrator)
- 20GB+ free disk space
- Internet connection (for first build)
- Chrome offline installer (`.exe`) if using `-UseChromePlus`

## Quick Start

1. **Verify Environment**
    ```powershell
    .\Verify-Environment.ps1
    ```
2. **Build RAM OS**
    ```powershell
    .\Build-Image.ps1 -SourceISO "C:\Win11.iso" -WorkRoot "D:\Build"
    ```
3. **Burn ISO to USB** (Ventoy/Rufus) and boot.

## Maintenance

- Update URLs in `Build-Image.ps1` as needed for new app/driver versions.
- Re-run `Verify-Environment.ps1` after Windows/ADK updates.

## License

- Scripts: MIT License
- Windows PE: Microsoft License
- Third-party apps: See respective licenses

---

_Last updated: March 2026_