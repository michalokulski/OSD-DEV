# OSDCloud Clean WinRE - Quick Start (5 Minutes)

## What You're Building

A bootable Windows PE/WinRE ISO (~400-500MB) with:

- ☕ **Java 8** (IBM Semeru/OpenJ9 — lightweight JVM)
- 🌐 **Chrome** (portable)
- 💻 **PowerShell 7**
- 🖥️ **WinXShell** (lightweight 10MB desktop GUI)
- 🛠️ **OSD Deploy tools**

---

## Prerequisites (30 seconds)

```powershell
# Run as Administrator — check environment first
.\Verify-Environment.ps1
```

Requirements:
- ✅ Windows 10/11 or Server 2019/2022
- ✅ PowerShell (run as Administrator)
- ✅ ~50GB free disk space
- ✅ Internet connection

---

## Build It (3 Steps)

### Step 1: Start the build

```powershell
# Option A: Interactive menu (easiest)
.\Quick-Launch.ps1
# Then select: 1

# Option B: Direct
.\Build-OSDCloud-Clean.ps1 -Mode Full
```

### Step 2: Wait

- **First build**: 45-60 minutes (downloads ~1-2GB)
- **Subsequent builds**: 20-30 minutes

### Step 3: Get your ISO

```powershell
Get-Item "C:\OSDCloud\LiveWinRE\*.iso"
```

Burn to USB with **Ventoy** or **Rufus**, then boot!

---

## What Happens During Build

```
Step 0 → Clean environment, setup directories
Step 1 → Install OSD module, create WinRE template
Step 2 → Download Java, Chrome, PowerShell, WinXShell, 7-Zip
Step 3 → Mount boot.wim, copy tools, configure registry
Step 4 → Create desktop shortcuts and ModeSelector launcher
Step 5 → Configure WinXShell as shell via Winlogon registry
       → Inject drivers from Drivers\ folder (if any)
Step 6 → Unmount and save boot.wim
Step 7 → Generate bootable ISO
```

---

## Boot Experience

When you boot the ISO:

1. **WinPE initializes** (`wpeinit`)
2. **WiFi GUI appears** (OSD wireless connect)
3. **Mode Selector** — choose:
   - **Deploy** → OSD deployment wizard
   - **Desktop** → WinXShell GUI with shortcuts
4. **WinXShell desktop** loads with shortcuts for Chrome, PowerShell, File Explorer, OSD Deploy

---

## Common Commands Reference

```powershell
# Full build with all defaults
.\Build-OSDCloud-Clean.ps1 -Mode Full

# Full build with custom workspace
.\Build-OSDCloud-Clean.ps1 -Mode Full -Workspace "D:\OSD"

# Only rebuild WinRE customization (skip ISO)
.\Build-OSDCloud-Clean.ps1 -Mode BuildWinRE

# Only rebuild ISO from existing WinRE
.\Build-OSDCloud-Clean.ps1 -Mode BuildISO

# Optimize size after build (20-30% reduction)
.\Optimize-WinRE.ps1 -Operation OptimizeAll

# Analyze where space is being used
.\Optimize-WinRE.ps1 -Operation Analyze

# Interactive menu for all options
.\Quick-Launch.ps1

# Custom driver injection path
.\Build-OSDCloud-Clean.ps1 -Mode Full -DriversPath "D:\MyDrivers"

# Custom wallpaper
.\Build-OSDCloud-Clean.ps1 -Mode Full -WallpaperPath "C:\Images\corp.jpg"
```

---

## File Sizes (Approximate)

| Component | Size |
|-----------|------|
| ISO (unoptimized) | 600-700 MB |
| ISO (optimized) | 400-500 MB |
| boot.wim (unoptimized) | 350-450 MB |
| boot.wim (optimized) | 250-350 MB |
| Java 8 JRE (IBM Semeru) | ~150 MB |
| Chrome (portable) | ~100 MB |
| PowerShell 7 | ~40 MB |
| WinXShell | ~10 MB |
| 7-Zip | ~5 MB |

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "OSD Module Not Found" | `Install-Module OSD -Force` |
| Build hangs / WIM stuck | `Dismount-WindowsImage -Path C:\Mount -Discard` then retry |
| ISO won't boot | Use Ventoy or Rufus (not copy-paste to drive) |
| Out of disk space | `.\Optimize-WinRE.ps1 -Operation CleanupTemp` |
| Driver injection fails | Check `.inf` has matching `.sys`/`.cat` files |
| WinXShell blank desktop | Ensure wxsUI ZIP files downloaded successfully |

---

## Next Steps

1. **Full Documentation**: Read [README.md](README.md)
2. **Optimization**: `.\Optimize-WinRE.ps1 -Operation Analyze` for size breakdown
3. **Custom Drivers**: Add `.inf` drivers to `Drivers\` folder
4. **Custom Wallpaper**: `.\Build-OSDCloud-Clean.ps1 -WallpaperPath "C:\img.jpg"`
5. **Customization**: Edit build script for your specific needs

---

## Support

- 📖 Full guide: [README.md](README.md)
- 🔧 Technical details: [PROJECT-SUMMARY.md](PROJECT-SUMMARY.md)
- 🐛 Issues: Check README.md Troubleshooting section

---

✨ **That's it! Your clean OSD WinRE distro is ready to build.** ✨

**Pro Tip:** Keep original scripts safe — create backups before customizing!

### Option 1: Interactive Menu (Easiest)
```powershell
# Run as Administrator
.\Quick-Launch.ps1
# Select option 1 for Full Build
```

### Option 2: One-Line Build
```powershell
# Run as Administrator
.\Build-OSDCloud-Clean.ps1 -Mode Full
```

### Option 3: Step-by-Step
```powershell
# 1. Build WinRE customization
.\Build-OSDCloud-Clean.ps1 -Mode BuildWinRE

# 2. Create ISO
.\Build-OSDCloud-Clean.ps1 -Mode BuildISO

# 3. (Optional) Optimize size
.\Optimize-WinRE.ps1 -Operation OptimizeAll
```

## What Happens?

**Build Process (45-60 minutes):**
1. ⬇️ Downloads: Java, Chrome, PowerShell, WinXShell (~1-2GB)
2. 🛠️ Creates OSD WinRE template
3. 📦 Injects tools and scripts
4. 🔧 Configures registry and environment
5. 💾 Generates ISO (~400-500MB)

**Output Location:**
```
C:\OSDCloud\LiveWinRE\OSDCloud-LiveWinRE-Clean.iso
```

## Boot & Use

### From USB
```powershell
# Use Ventoy or Rufus to write ISO to USB
# Boot from USB
# Select mode: Deploy (OSD) or Desktop (WinXShell + Tools)
```



## What's Inside?

- ✅ **PowerShell** - Full scripting capabilities
- ✅ **Java 11 JRE** - Run any Java app
- ✅ **Chrome** - Web browser
- ✅ **WinXShell** - Lightweight GUI shell
- ✅ **7-Zip** - Archive tool
- ✅ **OSD Deploy** - System deployment wizard
- ✅ **File Manager** - Explore drives

## Customize It?

### Add Your Own App
Edit `Build-OSDCloud-Clean.ps1`, find `Invoke-ApplicationPrep`:

```powershell
$apps = @{
    'myapp' = @{ url = 'https://download.site/myapp.zip'; file = 'myapp.zip'; unzip = $true }
}
```

### Add Script to Boot Menu
Edit `Build-OSDCloud-Clean.ps1`, function `Invoke-LauncherSetup`:

```powershell
$myScript = @'
Write-Host "My Custom Script"
# Your code here
'@
Set-Content -Path "$scriptsDir\MyScript.ps1" -Value $myScript
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "OSD Module Not Found" | `Install-Module OSD -Force` |
| Build hangs | Press Ctrl+C, run `.\Optimize-WinRE.ps1 -Operation CleanupTemp`, restart |
| ISO won't boot | Use Ventoy or Rufus (not just copy-paste to drive) |
| Out of disk space | Run optimization: `.\Optimize-WinRE.ps1 -Operation OptimizeAll` |

## Next Steps

1. **Full Documentation**: Read [README.md](README.md)
2. **Optimization**: Run `.\Optimize-WinRE.ps1 -Operation Analyze` for size breakdown
3. **Customization**: Edit build scripts for your specific needs

## Common Commands Reference

```powershell
# Full build with all options
.\Build-OSDCloud-Clean.ps1 -Mode Full -Workspace "C:\OSDCloud\LiveWinRE"

# Quick optimize & rebuild ISO
.\Optimize-WinRE.ps1 -Operation OptimizeAll
.\Build-OSDCloud-Clean.ps1 -Mode BuildISO

# Analyze where space is being used
.\Optimize-WinRE.ps1 -Operation Analyze

# Interactive menu for all options
.\Quick-Launch.ps1
```

## File Sizes (Approximate)

| Component | Size |
|-----------|------|
| ISO (unoptimized) | 600-700 MB |
| ISO (optimized) | 400-500 MB |
| boot.wim (unoptimized) | 350-450 MB |
| boot.wim (optimized) | 250-350 MB |
| Java JRE | 150 MB |
| Chrome | 100 MB |
| PowerShell 7 | 40 MB |
| WinXShell | 10 MB |

## Support

- 📖 Full guide: [README.md](README.md)
- 🐛 Issues: Check README.md Troubleshooting section

---

✨ **That's it! Your clean OSD WinRE distro is ready to build.** ✨

**Pro Tip:** Keep the original scripts safe and create backups before customizing!
