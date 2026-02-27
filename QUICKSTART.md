# OSDCloud Clean WinRE - Quick Start (5 Minutes)

## For the Impatient: Build Now!

### Prerequisites
- ✅ Windows 11/Server 2022
- ✅ 50GB free disk space
- ✅ Internet connection
- ✅ Administrator PowerShell

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
