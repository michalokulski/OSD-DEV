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
    Write-Host " 1) Build RAM OS (modern)         [Build-Image.ps1]"
    Write-Host " 2) Build RAM OS (legacy/OSDCloud)[Build-Image-OldWay.ps1]"
    Write-Host " 3) Verify Environment            [Verify-Environment.ps1]"
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

function Invoke-Menu {
    do {
        Show-Menu
        Write-Host -NoNewline " Select [0-4, C]: "
        $choice = (Read-Host).Trim()
        
        switch ($choice) {
            '1' {
                Clear-Host
                Write-Status "=== Build RAM OS (Modern) ===" -Type Header
                Write-Host ""
                Write-Host "Enter path to Windows ISO:" -ForegroundColor Cyan
                $iso = Read-Host
                
                if (-not (Test-Path $iso)) {
                    Write-Status "ISO not found: $iso" -Type Error
                    Read-Host "Press Enter to continue"
                    Clear-Host
                    continue
                }
                
                Write-Host "Enter WorkRoot path (e.g., D:\Build, C:\Build):" -ForegroundColor Cyan
                $work = Read-Host
                
                Write-Host ""
                Write-Host "Optional features:" -ForegroundColor Yellow
                Write-Host "Include Dell WinPE11 drivers? (Y/N):" -ForegroundColor Cyan
                $dellDrivers = (Read-Host).Trim().ToUpper() -eq 'Y'
                Write-Host "Include Chrome++? (Y/N):" -ForegroundColor Cyan
                $chromePlus = (Read-Host).Trim().ToUpper() -eq 'Y'
                Write-Host "Include Explorer++? (Y/N):" -ForegroundColor Cyan
                $explorerPP = (Read-Host).Trim().ToUpper() -eq 'Y'
                
                $params = @{
                    SourceISO = $iso
                    WorkRoot = $work
                }
                if ($dellDrivers) { $params.IncludeDellDrivers = $true }
                if ($chromePlus) { $params.UseChromePlus = $true }
                if ($explorerPP) { $params.IncludeExplorerPlus = $true }
                
                Write-Host ""
                Write-Status "Starting build..." -Type Info
                & "$PSScriptRoot\Build-Image.ps1" @params
                Write-Status "Build-Image.ps1 completed." -Type Success
                Read-Host "Press Enter to continue"
                Clear-Host
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
                $outputDir = "C:\Build\Output"
                if (Test-Path $outputDir) {
                    Write-Status "Opening output folder: $outputDir" -Type Info
                    explorer.exe $outputDir
                } else {
                    Write-Status "Output folder not found: $outputDir" -Type Warning
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
    # Verify scripts exist
    $scripts = @(
        "$PSScriptRoot\Build-Image.ps1",
        "$PSScriptRoot\Build-Image-OldWay.ps1",
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