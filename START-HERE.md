# OSDCloud Clean WinRE - START HERE 🚀

## What You Have

A complete, production-ready solution to build a **clean Windows PE/WinRE distribution** with:
- ✅ Java 8 (IBM Semeru/OpenJ9), Chrome, PowerShell 7, WinXShell GUI included
- ✅ ~400-500MB final ISO (optimized)
- ✅ No Scoop dependencies — portable/zip downloads only
- ✅ Driver injection support (`Drivers\` folder + `-DriversPath` parameter)
- ✅ Custom wallpaper support (`-WallpaperPath` parameter)
- ✅ Professional documentation
- ✅ Ready to deploy immediately

## Files Overview

### 🚀 Quick Start (Pick One)

#### Option A: Interactive Menu (Easiest)
```powershell
.\Quick-Launch.ps1
```
Then select option "1" for Full Build

#### Option B: One-Line Build (Fastest)
```powershell
.\Build-OSDCloud-Clean.ps1 -Mode Full
```

#### Option C: Read First (Safe)
- Read **QUICKSTART.md** (5 min read)
- Then run one of above options

---

## File Guide

| File | Purpose | Read Time |
|------|---------|-----------|
| **QUICKSTART.md** | 5-minute quick start | 5 min ⚡ |
| **README.md** | Complete documentation | 30 min 📖 |
| **PROJECT-SUMMARY.md** | Technical overview | 15 min 🔧 |
| **Build-OSDCloud-Clean.ps1** | Main build script | Run it! 🏗️ |
| **Optimize-WinRE.ps1** | Size optimization | Optional 📦 |
| **Quick-Launch.ps1** | Interactive launcher | Easy starter 🎯 |
| **Verify-Environment.ps1** | Pre-flight check | Run first ✓ |
| **Drivers\** | Extra drivers to inject | Drop `.inf` files here 💾 |

---

## 3-Step Quick Start

### Step 1: Verify Environment (30 seconds)
```powershell
# Run as Administrator
.\Verify-Environment.ps1
```

### Step 2: Build (45-60 minutes)
```powershell
# Run as Administrator
.\Quick-Launch.ps1
# Select: 1
```

### Step 3: Use (Boot & Test)
```powershell
# Find ISO
Get-Item "C:\OSDCloud\LiveWinRE\*.iso"

# Burn to USB with Ventoy or Rufus
# Boot and test!
```

---

## What Gets Built

```
C:\OSDCloud\LiveWinRE\
├── OSDCloud-LiveWinRE-Clean.iso          ← Your bootable image (~400-500MB)
├── Media\
│   └── sources\boot.wim                  ← Windows PE kernel
└── [Build artifacts...]
```

---

## Included Components

| Component | Size | Provides |
|-----------|------|----------|
| Windows PE | Base | Boot environment, drivers |
| IBM Semeru JRE 8 (OpenJ9) | ~150MB | Java application support |
| Chrome (portable) | ~100MB | Web browser |
| PowerShell 7 | ~40MB | Scripting & automation |
| WinXShell | ~10MB | Lightweight GUI desktop |
| OSD Tools | Pre-loaded | System deployment wizard |
| 7-Zip | ~5MB | Archive handling |

---

## What Improvements You're Getting

| Aspect | Old (Scoop-based) | New (Clean) |
|--------|-----------------|-------------|
| **Package Manager** | Scoop + 4 buckets | Direct downloads |
| **Reliability** | App discovery issues | Official URLs |
| **Shell** | Cairo (20MB) | WinXShell (10MB) |
| **Java** | OpenJDK 11 HotSpot | IBM Semeru JRE 8 OpenJ9 |
| **Drivers** | Manual | Auto-inject from `Drivers\` |
| **Wallpaper** | Fixed | Customizable via parameter |
| **Size** | 600-800MB | 400-500MB |
| **Optimization** | Manual | Automated |
| **Documentation** | Minimal | Comprehensive |

---

## Common Tasks

### First Time Setup
```powershell
.\Quick-Launch.ps1  # Menu-driven, easiest
```

### Just Build (No Menu)
```powershell
.\Build-OSDCloud-Clean.ps1 -Mode Full
```

### Optimize Size (20-30% reduction)
```powershell
.\Optimize-WinRE.ps1 -Operation OptimizeAll
```

### Check System Before Building
```powershell
.\Verify-Environment.ps1
```

### Inject Custom Drivers

Drop `.inf` drivers (with `.sys`/`.cat`) into `Drivers\` sub-folders, then build.

### Use Custom Wallpaper

```powershell
.\Build-OSDCloud-Clean.ps1 -Mode Full -WallpaperPath "C:\Images\corp-wallpaper.jpg"
```

---

## Next Steps

### Right Now
1. Run: `.\Verify-Environment.ps1`
2. Fix any red errors (warnings are OK)
3. Read: **QUICKSTART.md** (5 minutes)

### Then
1. Run: `.\Quick-Launch.ps1` → Option 1
2. Wait 45-60 minutes
3. ISO will be ready in `C:\OSDCloud\LiveWinRE\`

### Finally
1. Burn ISO to USB with Ventoy or Rufus
2. Boot computer
3. Select: Deploy (OSD) or Desktop (Tools)
4. Test everything works!

---

## Pro Tips

- 💾 Run on an SSD — WIM operations are much faster
- 🔌 Ensure stable internet for first build (~1-2GB downloads)
- ♻️ Subsequent builds reuse workspace (20-30 min, no re-download)
- 📦 Run `.\Optimize-WinRE.ps1 -Operation OptimizeAll` after build for smaller ISO
- 🧑‍💻 All scripts are heavily commented — safe to read and customize

---

## Troubleshooting

### "Build fails with OSD error"
```powershell
Install-Module OSD -Force
```

### "Disk space error"
```powershell
# Run optimization first
.\Optimize-WinRE.ps1 -Operation OptimizeAll
# Or use different drive
.\Build-OSDCloud-Clean.ps1 -Workspace "D:\OSD -Mode Full"
```

### "ISO won't boot"
- Use **Ventoy** or **Rufus** to write USB (not copy-paste)
- Verify BIOS boot order
- Try both Legacy and UEFI modes

See **README.md** for complete troubleshooting section.

---

## Documentation Structure

```
Entry Points:
├── START HERE (this file)           ← You are here
├── QUICKSTART.md                    ← 5-minute quick start
└── README.md                        ← Complete reference

Reference:
├── PROJECT-SUMMARY.md               ← Architecture & technical details
├── CHANGES.md                       ← What was refactored
└── REFACTORING-SUMMARY.md           ← Detailed change list

Scripts:
├── Quick-Launch.ps1                 ← Interactive menu
├── Build-OSDCloud-Clean.ps1         ← Main builder
├── Optimize-WinRE.ps1               ← Size optimization
└── Verify-Environment.ps1           ← Pre-flight check

Driver Injection:
└── Drivers\                         ← Drop .inf drivers here
    └── README.md                    ← Driver folder instructions
```

---

## Key Differences from Old Solution

| Aspect | Old (Scoop-based) | New (Clean) |
|--------|----------------------|------------|
| **Package Manager** | Scoop + 4 buckets | Direct downloads |
| **Reliability** | App discovery issues | Official URLs |
| **Shell** | Cairo (20MB) | WinXShell (10MB) |
| **Java** | OpenJDK 11 HotSpot | IBM Semeru JRE 8 OpenJ9 |
| **Drivers** | Manual | Auto-inject from `Drivers\` |
| **Size** | 600-800MB | 400-500MB |
| **Optimization** | Manual | Automated |
| **Documentation** | Minimal | Comprehensive |

---

## Success Indicators

✅ You'll know it's working when:

1. **Build completes** → ISO file appears in `C:\OSDCloud\LiveWinRE\`
2. **ISO boots** → Windows PE loads with splash screen
3. **Desktop appears** → WinXShell desktop shell loads
4. **Apps work** → Chrome, PowerShell, Java all functional
5. **Deploy option** → OSD deployment wizard launches properly
6. **Network ready** → (Optional) DHCP boot works

---

## Getting Help

### For Build Issues
1. Check **Verify-Environment.ps1** output
2. Read section in **README.md** (Troubleshooting)
3. Review error messages in PowerShell

### For Customization
1. Edit scripts (heavily commented)
2. See **README.md** (Advanced Customization)
3. Add apps/scripts as documented

---

## Time Estimates

| Task | Time | Notes |
|------|------|-------|
| Verify environment | 30 sec | Quick check |
| Full build (1st time) | 45-60 min | Downloads ~1-2GB |
| Full build (subsequent) | 20-30 min | Skips downloads |
| Optimization | 10-15 min | Optional, 20-30% size reduction |
| **Total initial setup** | **60-75 min** | ☕ Get coffee! |
| **Future rebuilds** | **30 min** | Much faster |

---

## You're All Set! 🎉

### Ready to Build?

**Fastest way to start:**
```powershell
.\Quick-Launch.ps1
```

**For detailed reading first:**
Read **QUICKSTART.md** (takes 5 minutes)

**For complete reference:**
Read **README.md** (after first build)

---

**Version**: 2.0.0  
**Status**: ✅ Production Ready  
**Last Updated**: February 2026

Happy deploying! 🚀
