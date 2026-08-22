# AGENTS.md — OSD-DEV Repository Guide

Instructions for AI coding agents working in this repository. Read this before making changes.

## Project Purpose

Builds a **bootable WinPE-based "RAM OS" ISO**: a customized Windows PE desktop that runs entirely from RAM (`X:\`), with a lightweight shell, portable apps, optional WiFi, and vendor driver injection. The machine's own `winre.wim` can be used as the base image — no Windows ISO required.

## Repository Layout

```
OSD-DEV/
├── Build-Image.ps1           # MAIN builder (~2100 lines). Two modes: -SourceISO or -UseWinRE
├── Build-Image-OldWay.ps1    # Legacy: pure OSD-module OSDCloud flow (New-OSDCloudTemplate etc.)
├── Quick-Launch.ps1          # Interactive menu launcher wrapping the other scripts
├── Verify-Environment.ps1    # Pre-flight environment checks (8 sections)
├── .github/workflows/lint.yml # CI: PSScriptAnalyzer + PowerShell-Beautifier on *.ps1
├── Apps/                     # Pre-staged app archives (git-ignored except README.md)
│   └── README.md             # Explains WinXShell*.7z manual staging
├── dev/
│   ├── Build-Image-OldWay-Rework.ps1  # Standalone WinRE builder, no OSD dependency (reference impl)
│   └── OSD/                  # FULL CLONE of the OSD PowerShell module source (git-ignored via \dev)
│       └── Public/...        # Authoritative reference for OSD cmdlet behavior
└── .gitignore                # Ignores \dev and Apps/* (keeps Apps/README.md)
```

**Important:** `dev/OSD/` is a vendored copy of the [OSD module](https://www.powershellgallery.com/packages/OSD). Treat it as reference documentation for OSD cmdlets, not as code to modify. The installed module on the build machine is authoritative at runtime.

## Build Pipeline (Build-Image.ps1)

Main flow in the `try` block at the bottom:

1. `Initialize-BuildEnvironment` — admin check, WorkRoot dirs, transcript log, ADK detection
2. `Mount-SourceISO` — WinRE mode: copy ADK Media + export winre.wim → `sources\boot.wim`; ISO mode: mount + robocopy
3. `Get-WinRESource` — 4-tier winre.wim search (OSD Copy-WinREWIM → known paths → ReAgent.xml offset partition mount → drive scan)
4. `Mount-TargetWIM` — DISM mount of boot.wim index (WinRE always index 1)
5. `Add-WinPE-Packages` — OC cabs from `$Script:WinPEPackages` list (missing cabs skipped silently)
6. `Add-DellDrivers` — OSD `Save-WinPECloudDriver -CloudDriver Dell` first, hardcoded CAB fallback
7. `Add-WiFiSupport` + `Add-OSDModuleToWIM` — when `-UseWinRE` or `-IncludeWiFi`
8. `Get-Applications` — downloads/extracts WinXShell, 7-Zip, Semeru Java, Explorer++, Chrome++, Sysinternals (local `Apps\SysinternalsSuite*.zip` only — no download URL)
9. `Invoke-ADKEnhancement` — optional; mounts a full Windows `install.wim` read-only and copies real-OS components into WinPE (see below). Source ISO: auto-detected from `-SourceISO` in ISO mode; `-EnhanceFromISO` required in WinRE mode.
10. `Create-WinXShellConfig` — patches shipped `winxshell.jcfg` (never replaces it)
11. `Inject-AllApps` → registry/FBWF → PostShell.cmd → Chrome launcher → shortcuts → remove winpeshl.ini → `Create-StartupScript` (StartNet.cmd)
12. `Build-FinalISO` — DISM commit → re-export WIM `/Compress:maximum` → stage boot sectors → oscdimg

## Critical Domain Knowledge (do not break these)

### Compression
- After DISM `/Commit`, the WIM MUST be re-exported with `/Compress:maximum` (LZX). Uncompressed commits reach ~950 MB and cause bootmgr "Not enough memory resources" boot failures.
- **NEVER use `/Compress:recovery`** (LZMS) on boot.wim — winload.efi cannot read it → BSOD `0xc000000bb`.

### Shell / Boot chain
- No Microsoft `explorer.exe`. Shell = WinXShell (+ Explorer++ as file manager inside the WinXShell folder).
- `winpeshl.ini` must be absent so WinPE falls back to `cmd.exe /k StartNet.cmd`; StartNet.cmd ends with `start /wait "" "%WXSHELL%"`.
- Chrome shortcut targets the **full runtime path** `X:\Windows\System32\cmd.exe /c StartChrome.cmd` — a bare `cmd.exe` target makes WshShell bake the build machine's `C:\Windows\...` path into the .lnk.

### Chrome sources — NEVER execute installers
Chrome program files come from 7z-SFX archives (`Bush2021/chrome_installer`, PortableApps paf.exe). These are **extracted with 7z only, never executed** — executing installs real Chrome on the host. Chrome++ itself only ships `version.dll`; validation requires `version.dll` next to `chrome.exe`.

### WiFi DLL sets
- Bare WinPE needs all 7: `dmcmnutils.dll`, `mdmpostprocessevaluator.dll`, `mdmregistration.dll` + `raschap.dll`, `raschapext.dll`, `rastls.dll`, `rastlsext.dll`
- WinRE base already has the 4 auth DLLs → inject only the 3 MDM DLLs.

### WinXShell config
The archive ships its own `winxshell.jcfg` using proprietary keys (`::文件管理器`, `JVAR_MODULEPATH`, `::壁纸`). **Patch it with regex, never replace wholesale** — replacement breaks the shell.

### oscdimg quoting
Use `Start-Process -ArgumentList @(...)` (not `&`) so embedded quotes in `-bootdata:` survive. Prefer `efisys_noprompt.bin` (no "press any key").

### ADK Enhancement (`Invoke-ADKEnhancement`)
Optional pipeline that copies components from a full Windows `install.wim` into the mounted boot.wim to improve app compatibility:
- **Step A Core** (always when enhancement runs): D3D11/DXGI, MSVC runtimes, CoreUI/UIAutomation DLLs
- **Step B WoW64** (`-IncludeWoW64`): 32-bit subsystem from `SysWOW64` (~150–300 MB) — needed for 32-bit apps
- **Step C Audio** (`-IncludeAudio`): WASAPI/audiodg stack
- **Step D Shell** (`-IncludeShell`): Explorer/DWM/XAML components
- **Step G Scratch**: `-ScratchSpaceMB` (default 512; valid: 32/64/128/256/512)
- install.wim is mounted **read-only** from `Cache\`; never modify it. Stale enhancement mounts block subsequent builds like any other mount.
- NOTE: there was once an `ADK-Enchancer` gitlink (submodule without `.gitmodules`, pointing at an unreachable commit) — removed 2026-08-23. The feature is fully self-contained in `Build-Image.ps1`; do not re-add the gitlink.

## Verified OSD Module API (v26.2.27.1)

Confirmed against installed module source (`Public\Functions\WindowsAdk.ps1`):

`Get-WindowsAdkPaths` returns a PSCustomObject with:
`AdkRoot, PathBCDBoot, PathDeploymentTools, PathDISM, PathOscdimg, PathUsmt, PathWinPE, PathWinPEMedia, PathWinSetup, WinPEOCs, WinPERoot, WimSourcePath, bcdbootexe, bcdeditexe, bootsectexe, dismexe, efisysbin, efisysnopromptbin, etfsbootcom, imagexexe, oa3toolexe, oscdimgexe, pkgmgrexe`

- Registry source: `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots` → `KitsRoot10` (NOT KitsRoot11).
- There is **no `WinPEPath` property** — use `PathWinPE` or `WinPERoot`.
- `Initialize-OSDCloudStartnet [-WirelessConnect] [-WifiProfile]` exists; `Initialize-OSDCloudStartnetUpdate` also exists but is a *module update* routine, not network init.
- `Start-WinREWiFi` lives in `Public\OSDCloudTS\OSD.WinRE.WiFi.ps1`.

## Coding Conventions & Constraints

- **PowerShell 5.1 compatible.** Do NOT use inline `(if (...) {..} else {..})` expressions as array elements — PS 5.1 parses them as command invocations. Assign to a variable first, or use subexpressions `$(if ...)`.
- **Encoding: all `.ps1` files MUST be UTF-8 with BOM.** PS 5.1 reads BOM-less files as ANSI; em-dashes (U+2014) then corrupt tokenization and produce phantom parse errors that don't appear in pwsh 7.
- **CI lint** (`.github/workflows/lint.yml`): PSScriptAnalyzer (settings file at repo root) + PowerShell-Beautifier must both pass with zero findings on all `*.ps1` — **excluding `dev\`** (vendored OSD clone would add 4,600+ findings). Locally: `Invoke-ScriptAnalyzer -Path . -Recurse -Settings PSScriptAnalyzerSettings.psd1` on repo-owned files only. No empty catch blocks — log or comment the intent in every catch. Beautifier formatting is enforced by CI (`Edit-DTWBeautifyScript -SourcePath <file>`); run it locally before committing.
- Scripts run as Administrator (`#Requires -RunAsAdministrator`); builds require 20 GB+ free disk.
- External tools: DISM, oscdimg from ADK; robocopy exit codes ≤ 7 are success.
- Downloads go to `Cache\` and survive rebuilds; user-placed archives in repo-root `Apps\` take priority over downloads (currently WinXShell only).
- Logging via `Write-BuildLog` (levels Info/Success/Warning/Error) + `Start-Transcript` to `Output\Build-<timestamp>.log`.
- Cleanup: `Invoke-Cleanup` dismounts WIM (discard on failure), dismounts ISO, removes Apps/Temp dirs unless `-SkipCleanup`. `-KeepMountedWIM` preserves the mount for debugging.
- App name keys in `$Script:Config.Apps` ending in `Exe` are file paths, not directories — `Inject-AllApps` skips them.

## Known Pitfalls (learned the hard way)

- `reg load` on an already-loaded hive fails — force `reg unload HKLM\RAM_SYS` first.
- WIM files extracted from ISOs carry the ReadOnly attribute — clear before DISM mount.
- Robocopy of ADK media uses `/MT:8`; treat exit codes > 7 as fatal.
- `Copy-Item` cannot read `\\?\GLOBALROOT` device paths (recovery partition) — only DISM can export from there.
- WinXShell download URL embeds an expiring forum session token; local `Apps\WinXShell*.7z` staging is the reliable path.
- Truncated partial downloads in `Cache\` poison all future builds — `Save-Download` deletes the output file on any failure. Always route downloads through it.
- 7z exit codes: 0 = OK, 1 = warning (tolerable), ≥ 2 = fatal. `Expand-7z` enforces this.
- BOM-less UTF-8 + em-dashes = phantom PS 5.1 parse errors ("missing terminator", "missing }") that pwsh 7 does not show. Check encoding first when 5.1 fails but 7 passes.

## Validation Checklist for Changes

1. `powershell -NoProfile -Command "$null = [System.Management.Automation.Language.Parser]::ParseFile('<file>', [ref]$null, [ref]$err); $err"` — must report zero parse errors (test in **both** pwsh 7 and Windows PowerShell 5.1). Helper: `dev/_validate-syntax.ps1`.
2. `Invoke-ScriptAnalyzer` with `PSScriptAnalyzerSettings.psd1` on repo-owned files — must be zero findings (CI bar).
3. Run Beautifier (`Edit-DTWBeautifyScript -SourcePath <file>`) — CI fails on any formatting diff.
4. Re-check UTF-8 BOM after any edit or `git checkout` — checkout restores committed BOM-less versions.
5. Run `.\Verify-Environment.ps1` after touching pre-flight logic.
6. Never test-mount real WIMs casually — stale mounts break subsequent builds (see Verify-Environment section 4).
