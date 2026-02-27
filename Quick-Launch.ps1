# ====================================
# OSDCloud Clean WinRE - Quick Launcher
# Menu-driven interface for all tasks
# ====================================

param(
    [string]$Workspace    = "C:\OSDCloud\LiveWinRE",
    [string]$Mount        = "C:\Mount",
    [string]$BuildPayload = "C:\BuildPayload"
)

#Requires -RunAsAdministrator

Clear-Host

function Write-Status {
    param([string]$Message, [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Header')]$Type = 'Info')
    $colors = @{ Info = 'Cyan'; Success = 'Green'; Warning = 'Yellow'; Error = 'Red'; Header = 'Magenta' }
    Write-Host $Message -ForegroundColor $colors[$Type]
}

function Show-Menu {
    Write-Status "===============================================" -Type Header
    Write-Status "   OSDCloud Clean WinRE LiveBoot v2.0 - Launcher" -Type Header
    Write-Status "===============================================" -Type Header
    Write-Host ""
    Write-Host " 1) Full Build (download, customize, create ISO)"
    Write-Host " 2) Build WinRE Only (prepare WIM customization)"
    Write-Host " 3) Build ISO Only (from existing WinRE)"
    Write-Host ""
    Write-Host " 4) Optimize WIM Size"
    Write-Host " 5) Analyze WIM Content"
    Write-Host ""
    Write-Host " 6) Open Workspace Folder"
    Write-Host " 7) View README Documentation"
    Write-Host " 8) Check Build Status"
    Write-Host " 9) Verify Environment (pre-flight checks)"
    Write-Host ""
    Write-Host " C) Clean Build Artifacts (prepare for fresh run)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " 0) Exit"
    Write-Host ""
}

function Invoke-CleanEnvironment {
    Clear-Host
    Write-Status "=== Clean Build Artifacts ==========================" -Type Header
    Write-Host ""
    Write-Host " Paths that will be cleaned:"
    Write-Host "   Mount      : $Mount"
    Write-Host "   BuildPayload: $BuildPayload"
    Write-Host "   Workspace  : $Workspace (Media + ISOs)"
    Write-Host ""
    Write-Host " Choose scope:"
    Write-Host ""
    Write-Host "  1) Temp only  — dismount WIM, remove Mount + BuildPayload"
    Write-Host "  2) Full clean — temp files AND Workspace (Media, ISO, logs)"
    Write-Host "  B) Back"
    Write-Host ""
    Write-Host -NoNewline " Select [1/2/B]: "
    $sub = (Read-Host).Trim().ToUpper()

    switch ($sub) {
        '1' {
            Write-Status "Cleaning temporary build files..." -Type Warning
            # Dismount any stale WIM
            $stale = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -ieq $Mount }
            if ($stale) {
                Write-Status "Dismounting stale WIM at $Mount ..." -Type Warning
                Dismount-WindowsImage -Path $Mount -Discard -ErrorAction SilentlyContinue
            }
            # Also unload any orphaned registry hives from a failed build
            reg unload "HKLM\WinRE_SW"  2>$null
            reg unload "HKLM\WinRE_SYS" 2>$null
            if (Test-Path $Mount)        { Remove-Item $Mount        -Recurse -Force -ErrorAction SilentlyContinue; Write-Status "Removed: $Mount" -Type Success }
            if (Test-Path $BuildPayload) { Remove-Item $BuildPayload -Recurse -Force -ErrorAction SilentlyContinue; Write-Status "Removed: $BuildPayload" -Type Success }
            Write-Status "Temp clean complete. Workspace ($Workspace) untouched." -Type Success
        }
        '2' {
            Write-Status "WARNING: This removes ALL build artifacts including any generated ISOs!" -Type Error
            Write-Host -NoNewline " Type YES to confirm: "
            $confirm = (Read-Host).Trim()
            if ($confirm -ceq 'YES') {
                # Dismount / unload first
                $stale = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
                    Where-Object { $_.Path -ieq $Mount }
                if ($stale) {
                    Write-Status "Dismounting stale WIM at $Mount ..." -Type Warning
                    Dismount-WindowsImage -Path $Mount -Discard -ErrorAction SilentlyContinue
                }
                reg unload "HKLM\WinRE_SW"  2>$null
                reg unload "HKLM\WinRE_SYS" 2>$null
                foreach ($p in @($Mount, $BuildPayload, $Workspace)) {
                    if (Test-Path $p) {
                        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Status "Removed: $p" -Type Success
                    }
                }
                Write-Status "Full clean complete. Environment is ready for a fresh build." -Type Success
            } else {
                Write-Status "Cancelled — nothing was removed." -Type Warning
            }
        }
        'B' { Clear-Host; return }
        default { Write-Status "Invalid selection." -Type Warning }
    }
    Write-Host ""
    Read-Host "Press Enter to continue"
    Clear-Host
}

function Invoke-Menu {
    do {
        Show-Menu
        Write-Host -NoNewline " Select [0-9, C]: "
        $choice = (Read-Host).Trim()
        
        switch ($choice) {
            '1' {
                Write-Status "Starting Full Build..." -Type Success
                & "$PSScriptRoot\Build-OSDCloud-Clean.ps1" -Mode Full -Workspace $Workspace
                Write-Status "Build complete! Check $Workspace for ISO." -Type Success
                Read-Host "Press Enter to continue"
                Clear-Host
            }
            '2' {
                Write-Status "Building WinRE customization..." -Type Success
                & "$PSScriptRoot\Build-OSDCloud-Clean.ps1" -Mode BuildWinRE -Workspace $Workspace
                Write-Status "WinRE ready for customization!" -Type Success
                Read-Host "Press Enter to continue"
                Clear-Host
            }
            '3' {
                Write-Status "Building ISO from existing WinRE..." -Type Success
                & "$PSScriptRoot\Build-OSDCloud-Clean.ps1" -Mode BuildISO -Workspace $Workspace
                Write-Status "ISO creation complete!" -Type Success
                Read-Host "Press Enter to continue"
                Clear-Host
            }
            '4' {
                Write-Status "Starting WIM optimization (may take several minutes)..." -Type Warning
                & "$PSScriptRoot\Optimize-WinRE.ps1" -Operation OptimizeAll -Workspace $Workspace
                Write-Status "Optimization complete!" -Type Success
                Read-Host "Press Enter to continue"
                Clear-Host
            }
            '5' {
                Write-Status "Analyzing WIM content..." -Type Success
                & "$PSScriptRoot\Optimize-WinRE.ps1" -Operation Analyze -Workspace $Workspace
                Read-Host "Press Enter to continue"
                Clear-Host
            }
            '6' {
                Write-Status "Opening workspace: $Workspace" -Type Info
                if (Test-Path $Workspace) {
                    explorer.exe $Workspace
                }
                else {
                    Write-Host "Workspace not found!" -ForegroundColor Red
                }
                Read-Host "Press Enter to continue"
                Clear-Host
            }
            '7' {
                Write-Status "Opening README..." -Type Info
                $readmeFile = "$PSScriptRoot\README.md"
                if (Test-Path $readmeFile) {
                    notepad.exe $readmeFile
                }
                else {
                    Write-Host "README.md not found!"
                    Read-Host "Press Enter to continue"
                }
                Clear-Host
            }
            '8' {
                Clear-Host
                Write-Status "Build Status Report" -Type Header
                Write-Host ""
                
                if (Test-Path $Workspace) {
                    Write-Status "Workspace: $Workspace" -Type Info
                    
                    $iso = Get-ChildItem "$Workspace\*.iso" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($iso) {
                        $sizeGB = $iso.Length / 1GB
                        Write-Status "ISO: $(Split-Path $iso -Leaf) - $([math]::Round($sizeGB, 2)) GB" -Type Success
                    }
                    else {
                        Write-Status "ISO: Not yet created" -Type Warning
                    }
                    
                    $wim = "$Workspace\Media\sources\boot.wim"
                    if (Test-Path $wim) {
                        $sizeMB = (Get-Item $wim).Length / 1MB
                        Write-Status "WIM: boot.wim - $([math]::Round($sizeMB, 1)) MB" -Type Success
                    }
                    else {
                        Write-Status "WIM: Not yet created" -Type Warning
                    }
                }
                else {
                    Write-Status "Workspace not found. Create with Build menu first." -Type Warning
                }
                
                Write-Host ""
                Read-Host "Press Enter to continue"
                Clear-Host
            }
            '9' {
                Clear-Host
                Write-Status "Running environment verification..." -Type Info
                & "$PSScriptRoot\Verify-Environment.ps1"
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
                Write-Status "Invalid option. Please select 0-9 or C." -Type Warning
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
    # Verify scripts exist
    $scripts = @(
        "$PSScriptRoot\Build-OSDCloud-Clean.ps1",
        "$PSScriptRoot\Optimize-WinRE.ps1",
        "$PSScriptRoot\Verify-Environment.ps1"
    )
    
    $missingScripts = $scripts | Where-Object { -not (Test-Path $_) }
    if ($missingScripts) {
        Write-Status "ERROR: Missing scripts:" -Type Warning
        $missingScripts | ForEach-Object { Write-Host " - $_" }
        exit 1
    }
    
    # Show menu
    Invoke-Menu
}
catch {
    Write-Status "Error: $_" -Type Error
    Read-Host "Press Enter to exit"
    exit 1
}
