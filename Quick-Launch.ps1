# ====================================
# OSDCloud Clean WinRE - Quick Launcher
# Menu-driven interface for all tasks
# ====================================

param(
    [string]$Workspace    = "C:\OSDCloud\WinRE",
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
    Write-Status "================================================" -Type Header
    Write-Status "   OSDCloud WinRE Builder v3.0 - Launcher" -Type Header
    Write-Status "   Workspace: $Workspace" -Type Header
    Write-Status "================================================" -Type Header
    Write-Host ""
    Write-Host " -- Deploy ISO (LIBR ZTI only) --" -ForegroundColor DarkGray
    Write-Host " 1) Full Build  (clean deploy ISO)"
    Write-Host " 2) Build WinRE Only"
    Write-Host " 3) Build ISO Only  (from existing WinRE)"
    Write-Host ""
    Write-Host " -- Recovery ISO (HTA boot menu: LIBR + Desktop tools) --" -ForegroundColor DarkGray
    Write-Host " 4) Recovery ISO -- Baked-In  (tools in WIM, ~350 MB larger)"
    Write-Host " 5) Recovery ISO -- On-Demand  (lighter WIM, tools download at boot)"
    Write-Host ""
    Write-Host " -- Maintenance --" -ForegroundColor DarkGray
    Write-Host " 6) Optimize WIM Size"
    Write-Host " 7) Analyze WIM Content"
    Write-Host " 8) Open Workspace Folder"
    Write-Host " 9) Verify Environment  (pre-flight checks)"
    Write-Host ""
    Write-Host " C) Clean Build Artifacts  (prepare for fresh run)" -ForegroundColor Yellow
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
                Write-Status "Building Recovery ISO (Baked-In tools)..." -Type Success
                Write-Status "Downloads Chrome, 7-Zip and IBM Semeru JRE 8 into the WIM -- allow 20+ min" -Type Warning
                & "$PSScriptRoot\Build-Recovery-BakedIn.ps1" -Workspace $Workspace
                Write-Status "Recovery (Baked-In) ISO complete!" -Type Success
                Read-Host "Press Enter to continue"
                Clear-Host
            }
            '5' {
                Write-Status "Building Recovery ISO (On-Demand tools)..." -Type Success
                Write-Status "Tools download at WinPE boot -- requires network + 4 GB RAM on target machine" -Type Warning
                & "$PSScriptRoot\Build-Recovery-OnDemand.ps1" -Workspace $Workspace
                Write-Status "Recovery (On-Demand) ISO complete!" -Type Success
                Read-Host "Press Enter to continue"
                Clear-Host
            }
            '6' {
                Write-Status "Starting WIM optimization (may take several minutes)..." -Type Warning
                & "$PSScriptRoot\Optimize-WinRE.ps1" -Operation OptimizeAll -Workspace $Workspace
                Write-Status "Optimization complete!" -Type Success
                Read-Host "Press Enter to continue"
                Clear-Host
            }
            '7' {
                Write-Status "Analyzing WIM content..." -Type Success
                & "$PSScriptRoot\Optimize-WinRE.ps1" -Operation Analyze -Workspace $Workspace
                Read-Host "Press Enter to continue"
                Clear-Host
            }
            '8' {
                Write-Status "Opening workspace: $Workspace" -Type Info
                if (Test-Path $Workspace) {
                    # Show ISO/WIM status before opening
                    $iso = Get-ChildItem "$Workspace\*.iso" -ErrorAction SilentlyContinue | Select-Object -Last 1
                    if ($iso) { Write-Status "ISO: $($iso.Name)  ($([math]::Round($iso.Length/1GB,2)) GB)" -Type Success }
                    $wim = "$Workspace\Media\sources\boot.wim"
                    if (Test-Path $wim) { Write-Status "WIM: $([math]::Round((Get-Item $wim).Length/1MB,1)) MB" -Type Success }
                    explorer.exe $Workspace
                }
                else {
                    Write-Status "Workspace not found -- it will be created on first build." -Type Warning
                }
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
        "$PSScriptRoot\Build-Recovery-BakedIn.ps1",
        "$PSScriptRoot\Build-Recovery-OnDemand.ps1",
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
