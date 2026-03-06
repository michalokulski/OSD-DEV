# ====================================
# RAM OS Builder - Quick Launcher
# Menu-driven interface for all tasks
# ====================================

#Requires -RunAsAdministrator

Clear-Host

function Write-Status {
    param([string]$Message, [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Header')]$Type = 'Info')
    $colors = @{ Info = 'Cyan'; Success = 'Green'; Warning = 'Yellow'; Error = 'Red'; Header = 'Magenta' }
    Write-Host $Message -ForegroundColor $colors[$Type]
}

function Show-Menu {
    Write-Status "================================================" -Type Header
    Write-Status "   RAM OS Builder - Launcher" -Type Header
    Write-Status "================================================" -Type Header
    Write-Host ""
    Write-Host " 1) Build RAM OS (modern)           [Build-Image.ps1]"
    Write-Host "    ISO mode or WinRE mode (no ISO needed)"
    Write-Host " 2) Build RAM OS (legacy/OSDCloud)  [Build-Image-OldWay.ps1]"
    Write-Host " 3) Verify Environment              [Verify-Environment.ps1]"
    Write-Host " 4) Open Output Folder"
    Write-Host ""
    Write-Host " C) Clean Build Artifacts (manual)"
    Write-Host " 0) Exit"
    Write-Host ""
}

function Invoke-CleanEnvironment {
    Clear-Host
    Write-Status "=== Clean Build Artifacts ==========================" -Type Header
    Write-Host ""
    Write-Host " Manual clean-up recommended:"
    Write-Host " - Remove build folders (e.g., D:\Build, C:\Build, or your WorkRoot)"
    Write-Host " - Dismount any stale WIMs: Dismount-WindowsImage -Path <mountdir> -Discard"
    Write-Host " - Remove temp/cache/output folders as needed"
    Write-Host ""
    Write-Host " Press Enter to return to menu."
    Read-Host | Out-Null
    Clear-Host
}

function Invoke-BuildModernMenu {
    Clear-Host
    Write-Status "=== Build RAM OS (Modern) ===" -Type Header
    Write-Host ""
    Write-Host "Build mode:" -ForegroundColor Cyan
    Write-Host "  1) WinRE mode  - no ISO needed, WiFi auto-enabled (recommended)"
    Write-Host "  2) ISO mode    - traditional; provide a Windows 10/11 ISO"
    Write-Host ""
    Write-Host -NoNewline "Select [1/2]: "
    $modeChoice = (Read-Host).Trim()

    $params = @{}
    $useWinRE = $false

    switch ($modeChoice) {
        '1' {
            $useWinRE = $true
            $params['UseWinRE'] = $true
            Write-Host ""
            Write-Host "NOTE: WiFi is automatically included in WinRE mode." -ForegroundColor Gray
        }
        '2' {
            Write-Host ""
            Write-Host "Enter path to Windows ISO:" -ForegroundColor Cyan
            $iso = (Read-Host).Trim()
            if (-not $iso) {
                Write-Status "No ISO path provided. Returning to menu." -Type Warning
                Read-Host "Press Enter to continue"
                Clear-Host
                return
            }
            if (-not (Test-Path $iso)) {
                Write-Status "ISO not found: $iso" -Type Error
                Read-Host "Press Enter to continue"
                Clear-Host
                return
            }
            $params['SourceISO'] = $iso
        }
        default {
            Write-Status "Invalid selection. Returning to menu." -Type Warning
            Read-Host "Press Enter to continue"
            Clear-Host
            return
        }
    }

    Write-Host ""
    Write-Host "Enter WorkRoot path (e.g., D:\Build):" -ForegroundColor Cyan
    $work = (Read-Host).Trim()
    if (-not $work) {
        Write-Status "No WorkRoot path provided. Returning to menu." -Type Warning
        Read-Host "Press Enter to continue"
        Clear-Host
        return
    }
    $params['WorkRoot'] = $work

    Write-Host ""
    Write-Host "Optional features:" -ForegroundColor Yellow

    Write-Host "Include Dell WinPE11 drivers? (Y/N):" -ForegroundColor Cyan
    if ((Read-Host).Trim().ToUpper() -eq 'Y') { $params['IncludeDellDrivers'] = $true }

    Write-Host "Include Chrome++? (Y/N):" -ForegroundColor Cyan
    if ((Read-Host).Trim().ToUpper() -eq 'Y') {
        $params['UseChromePlus'] = $true
        Write-Host "Path to Chrome offline installer .exe (or Enter to skip):" -ForegroundColor Cyan
        $chromeInstaller = (Read-Host).Trim()
        if ($chromeInstaller -and (Test-Path $chromeInstaller)) {
            $params['ChromeOfflineInstallerPath'] = $chromeInstaller
        }
        elseif ($chromeInstaller) {
            Write-Status "  Chrome installer not found at '$chromeInstaller' — will attempt auto-download" -Type Warning
        }
    }

    Write-Host "Include Explorer++? (Y/N):" -ForegroundColor Cyan
    if ((Read-Host).Trim().ToUpper() -eq 'Y') { $params['IncludeExplorerPlus'] = $true }

    if (-not $useWinRE) {
        Write-Host "Include WiFi support? (Y/N):" -ForegroundColor Cyan
        if ((Read-Host).Trim().ToUpper() -eq 'Y') { $params['IncludeWiFi'] = $true }
    }

    Write-Host ""
    Write-Host "ADK Enhancement (injects DLLs, registry, subsystems from install.wim):" -ForegroundColor Yellow
    if ($useWinRE) {
        Write-Host "  WinRE mode: supply a Windows ISO to enable enhancement." -ForegroundColor Gray
        Write-Host "Path to Windows ISO for ADK Enhancement (or Enter to skip):" -ForegroundColor Cyan
        $enhIso = (Read-Host).Trim()
        if ($enhIso -and (Test-Path $enhIso)) {
            $params['EnhanceFromISO'] = $enhIso
        } elseif ($enhIso) {
            Write-Status "  ISO not found at '$enhIso' — ADK Enhancement will be skipped" -Type Warning
        }
    } else {
        Write-Host "  ISO mode: install.wim will be auto-detected from source ISO." -ForegroundColor Gray
        Write-Host "  Use -EnhanceFromISO only if you want a different Windows ISO as the component source." -ForegroundColor Gray
        Write-Host "Override install.wim source ISO? (Enter path or press Enter to use source ISO):" -ForegroundColor Cyan
        $enhIso = (Read-Host).Trim()
        if ($enhIso -and (Test-Path $enhIso)) {
            $params['EnhanceFromISO'] = $enhIso
        } elseif ($enhIso) {
            Write-Status "  ISO not found at '$enhIso' — will auto-detect from source ISO" -Type Warning
        }
    }
    Write-Host "Include WoW64 (32-bit subsystem, ~150-300 MB, needed for 32-bit apps)? (Y/N):" -ForegroundColor Cyan
    if ((Read-Host).Trim().ToUpper() -eq 'Y') { $params['IncludeWoW64'] = $true }
    Write-Host "Include Audio subsystem? (Y/N):" -ForegroundColor Cyan
    if ((Read-Host).Trim().ToUpper() -eq 'Y') { $params['IncludeAudio'] = $true }

    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Yellow
    if ($useWinRE) {
        Write-Host "  Mode:    WinRE (no ISO)" -ForegroundColor Gray
        Write-Host "  WiFi:    Auto-enabled" -ForegroundColor Gray
    }
    else {
        Write-Host "  Mode:    ISO   ($($params['SourceISO']))" -ForegroundColor Gray
        Write-Host "  WiFi:    $( if ($params.ContainsKey('IncludeWiFi')) { 'Yes' } else { 'No' } )" -ForegroundColor Gray
    }
    Write-Host "  WorkRoot:     $work" -ForegroundColor Gray
    Write-Host "  Dell Drivers: $( if ($params.ContainsKey('IncludeDellDrivers')) { 'Yes' } else { 'No' } )" -ForegroundColor Gray
    Write-Host "  Chrome++:     $( if ($params.ContainsKey('UseChromePlus')) { 'Yes' } else { 'No' } )" -ForegroundColor Gray
    Write-Host "  Explorer++:   $( if ($params.ContainsKey('IncludeExplorerPlus')) { 'Yes' } else { 'No' } )" -ForegroundColor Gray
    Write-Host "  ADK Enh.:     $( if ($params.ContainsKey('EnhanceFromISO')) { "Yes (ISO: $($params['EnhanceFromISO']))" } elseif (-not $useWinRE) { 'Auto (from source ISO)' } else { 'No' } )" -ForegroundColor Gray
    Write-Host "  WoW64:        $( if ($params.ContainsKey('IncludeWoW64')) { 'Yes' } else { 'No' } )" -ForegroundColor Gray
    Write-Host "  Audio:        $( if ($params.ContainsKey('IncludeAudio')) { 'Yes' } else { 'No' } )" -ForegroundColor Gray
    Write-Host ""
    Write-Host -NoNewline "Proceed? (Y/N): "
    if ((Read-Host).Trim().ToUpper() -ne 'Y') {
        Write-Status "Cancelled." -Type Warning
        Read-Host "Press Enter to continue"
        Clear-Host
        return
    }

    Write-Host ""
    Write-Status "Starting build..." -Type Info
    & "$PSScriptRoot\Build-Image.ps1" @params
    Write-Status "Build-Image.ps1 completed." -Type Success
    Read-Host "Press Enter to continue"
    Clear-Host
}

function Invoke-Menu {
    do {
        Show-Menu
        Write-Host -NoNewline " Select [0-4, C]: "
        $choice = (Read-Host).Trim()

        switch ($choice) {
            '1' {
                Invoke-BuildModernMenu
            }
            '2' {
                Write-Status "Launching Build-Image-OldWay.ps1 (legacy OSDCloud)..." -Type Success
                & "$PSScriptRoot\Build-Image-OldWay.ps1"
                Write-Status "Build-Image-OldWay.ps1 completed." -Type Success
                Read-Host "Press Enter to continue"
                Clear-Host
            }
            '3' {
                Write-Status "Running environment verification..." -Type Info
                & "$PSScriptRoot\Verify-Environment.ps1"
                Read-Host "Press Enter to continue"
                Clear-Host
            }
            '4' {
                Write-Host "Enter WorkRoot path to open Output folder (e.g., D:\Build):" -ForegroundColor Cyan
                $workRoot = (Read-Host).Trim()
                if (-not $workRoot) { $workRoot = "C:\Build" }
                $outputDir = Join-Path $workRoot "Output"
                if (Test-Path $outputDir) {
                    Write-Status "Opening output folder: $outputDir" -Type Info
                    explorer.exe $outputDir
                }
                else {
                    Write-Status "Output folder not found: $outputDir" -Type Warning
                    Write-Host "  (Has a build been run yet?)" -ForegroundColor Gray
                }
                Read-Host "Press Enter to continue"
                Clear-Host
            }
            { $_ -in 'C','c' } {
                Invoke-CleanEnvironment
            }
            '0' {
                Write-Status "Exiting..." -Type Info
                exit 0
            }
            default {
                Write-Status "Invalid option. Please select 0-4 or C." -Type Warning
                Read-Host "Press Enter to continue"
                Clear-Host
            }
        }
    } while ($true)
}

# ====================================
# MAIN
# ====================================
try {
    # Verify required scripts exist
    $required = @(
        "$PSScriptRoot\Build-Image.ps1",
        "$PSScriptRoot\Verify-Environment.ps1"
    )

    $missingScripts = $required | Where-Object { -not (Test-Path $_) }
    if ($missingScripts) {
        Write-Status "ERROR: Missing required scripts:" -Type Warning
        $missingScripts | ForEach-Object { Write-Host "  - $_" }
        exit 1
    }

    # Optional scripts (warn but don't block)
    $optional = @(
        "$PSScriptRoot\Build-Image-OldWay.ps1"
    )
    $optional | Where-Object { -not (Test-Path $_) } | ForEach-Object {
        Write-Status "WARN: Optional script not found: $_" -Type Warning
    }

    # Show menu
    Invoke-Menu
}
catch {
    Write-Status "Error: $_" -Type Error
    Read-Host "Press Enter to exit"
    exit 1
}
