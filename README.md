# OSDCloud Clean WinRE LiveBoot - Complete Guide

**Version:** 1.0.0  
**Date:** February 2026  
**Status:** Production Ready

## Overview

A modern, clean Windows PE/WinRE distribution based on OSD (OSDeploy) framework, designed for:
- ✅ Graphical user interface (WinXShell)
- ✅ PowerShell scripting
- ✅ Java application support
- ✅ Chrome web browser
- ✅ Minimal footprint (< 500MB ISO)
- ✅ No bloat, no Scoop dependencies
- ✅ Clean system deployments

## Architecture

```
OSDCloud-Clean/
├── Build-OSDCloud-Clean.ps1          (Main build script)
├── Optimize-WinRE.ps1                (Size optimization)
├── README.md                          (This file)
└── Output/
    ├── OSDCloud-LiveWinRE-Clean.iso  (Bootable ISO)
    └── NetworkBoot/                  (PXE/iPXE files)
        ├── boot.wim
        ├── boot.ipxe
        ├── pxelinux.cfg/
        ├── DEPLOYMENT-GUIDE.md
        └── http_server.py
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
-Mode       : BuildWinRE | BuildISO | Full (default: Full)
-Workspace  : Path to workspace (default: C:\OSDCloud\LiveWinRE)
-IsoName    : ISO filename (default: OSDCloud-LiveWinRE-Clean)
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
Reduces WIM/ISO size while maintaining functionality:
- Clean temporary files
- Compress WIM with max compression
- Remove unnecessary components
- Analyze size breakdown

**Operations:**
```powershell
-Operation  : CleanupTemp | CompressWIM | RemoveBlob | OptimizeAll | Analyze
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
- Windows 11/Server 2022 (for WinRE support)
- Administrator privileges
- 50GB free disk space
- PowerShell 5.1+ (7+ recommended)
- Internet connection for downloads

### Step 1: Build WinRE Distribution
```powershell
# Run as Administrator
cd "g:\Workspace\OSD-DEV"
.\Build-OSDCloud-Clean.ps1 -Mode Full
```

**Expected Output:**
- ✓ Downloads: Java, Chrome, WinXShell, PowerShell (~1-2GB total)
- ✓ Creates OSD WinRE template
- ✓ Customizes with tools and scripts
- ✓ Generates ISO file (~400-500MB)
- ⏱ Total time: 45-60 minutes

### Step 2: Verify the Build
```powershell
# Check ISO was created
Get-ChildItem "C:\OSDCloud\LiveWinRE\*.iso" -Recurse

# Verify WIM payload
Get-Item "C:\OSDCloud\LiveWinRE\Media\sources\boot.wim"
```

### Step 3: (Optional) Optimize Size
```powershell
.\Optimize-WinRE.ps1 -Operation OptimizeAll
```

Typical size reduction: **20-30%**

### Step 4: Boot & Test
**From ISO:**
- Burn to USB with Ventoy or Rufus
- Boot computer
- Select operating mode (Deploy or Desktop)

## What Gets Installed

### Tools & Applications
| Component | Size | Purpose |
|-----------|------|---------|
| OpenJDK 11 JRE | ~150MB | Java application support |
| Google Chrome | ~100MB | Web browser |
| PowerShell 7.4 | ~40MB | Modern scripting |
| WinXShell | ~10MB | Lightweight GUI shell |
| 7-Zip | ~5MB | Archive handling |

### Pre-configured Features
- ✅ Network (Ethernet + WiFi drivers)
- ✅ Storage drivers (SATA, NVMe, RAID)
- ✅ GPU support (basic)
- ✅ Multi-language support (en-US default)
- ✅ OSD Deploy tools pre-installed
- ✅ PowerShell ISE included
- ✅ WMI and WinRM enabled

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
- **Desktop Mode** - Returns to Cairo desktop with tools

## Advanced Customization

### Adding Custom Applications
1. Add to `$apps` hashtable in Build-OSDCloud-Clean.ps1
2. Use zip format for extraction, MSI for installers:
```powershell
$apps = @{
    'myapp' = @{ url = 'https://...'; file = 'myapp.zip'; unzip = $true }
}
```

### Custom Launcher Scripts
Edit launcher section in Build-OSDCloud-Clean.ps1:
```powershell
function Invoke-LauncherSetup {
    # Add your launcher here
    $customScript = @'
    # Your script code
    '@
    Set-Content -Path "$scriptsDir\YourScript.ps1" -Value $customScript
}
```

### Modifying WinPE Appearance
Mount the boot.wim and customize:
- Wallpaper: `$Mount\Windows\System32\drivers\etc`
- Cursor/Theme: Registry modifications
- Shell behavior: winpeshl.ini changes

### Registry Customization
Add to Build-OSDCloud-Clean.ps1 before `Dismount-WindowsImage`:
```powershell
# Your registry modifications here
reg add "HKLM\WinRE\..." /v key /t REG_SZ /d value /f
```

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

### Network Boot Not Working
1. Confirm DHCP Options 66/67 configured
2. Test from client: `ipconfig /all` shows expected boot server
3. Verify network connectivity with `ping`
4. Check TFTP/HTTP server running with `netstat -an`

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

### Registry Changes Don't Persist
After editing registry in mount, verify:
1. Hive is correctly loaded (`reg load`)
2. Changes saved before unmount
3. WIM dismounted with `-Save` flag

## Performance Tuning

### Reduce Boot Time
- Install minimal drivers only (use `-CloudDriver *` judiciously)
- Remove language packs
- Optimize WIM compression
- Use fast storage (SSD for build)

### Reduce Memory Usage
- Disable unnecessary services in registry
- Remove debug symbols
- Minimize image cache

### Network Boot Optimization
- Use local HTTP server instead of internet downloads
- Pre-cache WIM on local network
- Use IPv4 only (IPv6 adds latency)

## Security Considerations

### For Production Deployments
1. **Network Isolation**
   - Restrict DHCP to authorized subnets
   - Use firewall rules
   - Monitor boot attempts

2. **Access Control**
   - Implement OSD authentication
   - Use WDS instead of plain TFTP
   - Enable logging for audits

3. **Content Security**
   - Validate downloaded tools checksums
   - Use signed PowerShell scripts
   - Implement code signing

4. **Network Security**
   - Use VPN for sensitive networks
   - Implement IPsec for boot traffic
   - Use HTTPS for file downloads
   - Restrict to trusted VLANs

## Maintenance & Updates

### Regular Updates
```powershell
# Update URLs in Build-OSDCloud-Clean.ps1 periodically:
# - Check for Java JRE updates
# - Chrome updates (auto via MSI)
# - PowerShell updates
# - OSD module updates
```

### Rebuild Frequency
- **Monthly**: Check component updates
- **Quarterly**: Full rebuild with latest versions
- **As-needed**: Security fixes

### Version Management
```powershell
# Track versions in config
$config = @{
    JavaVersion = "11.0.21"
    ChromeVersion = "Latest"
    PowerShellVersion = "7.4.1"
    OSDVersion = "Latest"
}
```

## Known Limitations

1. **Size**: Must fit on network/USB media (target < 500MB)
2. **Graphics**: Generic VESA drivers only (may not support GPU accelerationfully)
3. **Language**: English (en-US) default
4. **Architecture**: x64 only (x86 not supported)
5. **Stability**: WinPE is not a full OS, designed for short-term deployments
6. **Applications**: Limited to what fits in ~500MB WIM

## Support & Resources

### Official Documentation
- [OSD Module](https://github.com/OSDeploy/OSD)
- [Windows PE](https://docs.microsoft.com/windows/deployment/windows-pe/windows-pe-intro)
- [iPXE](https://ipxe.org/)

### Troubleshooting Resources
- OSD GitHub Issues
- Windows PE documentation
- iPXE wiki
- Community forums

### Getting Help
1. Check DEPLOYMENT-GUIDE.md
2. Review logs in build directory
3. Test components individually
4. Search OSD documentation

## Contributing

To improve this project:
1. Test builds thoroughly
2. Document any custom modifications
3. Share optimization tips
4. Report issues with details

## License & Attribution

- **OSD Module**: MIT License
- **Windows PE**: Microsoft License
- **WinXShell**: MIT License
- **Other components**: Respect original licenses

## Changelog

### v1.0.0 (February 2026)
- ✨ Initial release
- ✨ Multi-mode operation (BuildWinRE, BuildISO)
- ✨ Java + Chrome + PowerShell support
- ✨ WinXShell lightweight GUI shell
- ✨ Optimization utilities
- ✨ Clean architecture (no Scoop)

---

**Last Updated:** February 26, 2026  
**Tested On:** Windows 11, Server 2022  
**Status:** ✅ Production Ready
