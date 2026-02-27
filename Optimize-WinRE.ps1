# ====================================
# OSDCloud WinRE Optimization Utilities
# Reduce WIM size & improve performance
# ====================================

param(
    [ValidateSet('CleanupTemp', 'CompressWIM', 'RemoveBlob', 'OptimizeAll', 'Analyze')]
    [string]$Operation = 'OptimizeAll',
    
    [string]$Workspace = "C:\OSDCloud\LiveWinRE",
    [string]$Mount = "C:\Mount"
)

#Requires -RunAsAdministrator

# ====================================
# FUNCTIONS
# ====================================

function Write-Status {
    param([string]$Message, [ValidateSet('Info', 'Success', 'Warning', 'Error')]$Type = 'Info')
    $colors = @{ Info = 'Cyan'; Success = 'Green'; Warning = 'Yellow'; Error = 'Red' }
    Write-Host "[$Type] $Message" -ForegroundColor $colors[$Type]
}

function Get-DirectorySize {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) { return 0 }
    
    $size = 0
    try {
        $size = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue | 
                 Measure-Object -Property Length -Sum).Sum
    }
    catch {
        $size = 0
    }
    
    return $size
}

function Format-FileSize {
    param([int64]$Size)
    
    $units = 'B', 'KB', 'MB', 'GB', 'TB'
    $unitIndex = 0
    $displaySize = [float]$Size
    
    while ($displaySize -ge 1024 -and $unitIndex -lt $units.Count - 1) {
        $displaySize /= 1024
        $unitIndex++
    }
    
    return "$([math]::Round($displaySize, 2)) $($units[$unitIndex])"
}

# ====================================
# CLEANUP TEMPORARY FILES
# ====================================
function Invoke-CleanupTemp {
    Write-Status "=== Cleaning Temporary Files ===" -Type Info
    
    $bootWim = "$Workspace\Media\sources\boot.wim"
    
    if (-not (Test-Path $bootWim)) {
        Write-Status "boot.wim not found" -Type Error
        return
    }
    
    Write-Status "Mounting WIM for cleanup..." -Type Info
    New-Item $Mount -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    
    Mount-WindowsImage -ImagePath $bootWim -Index 1 -Path $Mount
    
    # Define cleanup paths
    $cleanupPaths = @(
        "$Mount\Windows\Temp",
        "$Mount\Windows\Logs",
        "$Mount\Windows\inf",  # Old driver database
        "$Mount\Windows\System32\spool\drivers",  # Print drivers not needed
        "$Mount\Windows\System32\DriverStore\FileRepository"  # Extra drivers
    )
    
    $totalFreed = 0
    
    foreach ($path in $cleanupPaths) {
        if (Test-Path $path) {
            $beforeSize = Get-DirectorySize $path
            
            # Delete all files but keep directory structure
            Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | 
                Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            
            $afterSize = Get-DirectorySize $path
            $freed = $beforeSize - $afterSize
            $totalFreed += $freed
            
            Write-Status "Cleaned: $(Split-Path $path -Leaf) - Freed: $(Format-FileSize $freed)"
        }
    }
    
    Write-Status "Dismounting WIM..." -Type Info
    Dismount-WindowsImage -Path $Mount -Save
    
    Write-Status "Cleanup complete! Freed: $(Format-FileSize $totalFreed)" -Type Success
}

# ====================================
# COMPRESS WIM FILE
# ====================================
function Invoke-CompressWIM {
    Write-Status "=== Compressing WIM File ===" -Type Info
    
    $bootWim = "$Workspace\Media\sources\boot.wim"
    $instWim = "$Workspace\Media\sources\install.wim"
    
    @($bootWim, $instWim) | ForEach-Object {
        if (Test-Path $_) {
            $fileName = Split-Path $_ -Leaf
            Write-Status "Compressing $fileName..." -Type Info
            
            $beforeSize = (Get-Item $_).Length
            
            # Use DISM to recompress WIM with maximum compression
            dism.exe /Export-Image /SourceImagePath:"$_" /SourceIndex:1 /DestinationImagePath:"$_.tmp" /Compress:maximum
            
            if ($LASTEXITCODE -eq 0) {
                Remove-Item $_ -Force
                Rename-Item "$_.tmp" $_ -Force
                
                $afterSize = (Get-Item $_).Length
                $saved = $beforeSize - $afterSize
                $compression = [math]::Round(($saved / $beforeSize) * 100, 1)
                
                Write-Status "$fileName compressed: $(Format-FileSize $beforeSize) -> $(Format-FileSize $afterSize) ($compression% reduction)" -Type Success
            }
            else {
                Write-Status "Failed to compress $fileName" -Type Error
                if (Test-Path "$_.tmp") { Remove-Item "$_.tmp" -Force }
            }
        }
    }
}

# ====================================
# REMOVE UNNECESSARY COMPONENTS
# ====================================
function Invoke-RemoveBlob {
    Write-Status "=== Removing Unnecessary Components ===" -Type Info
    
    $bootWim = "$Workspace\Media\sources\boot.wim"
    
    if (-not (Test-Path $bootWim)) {
        Write-Status "boot.wim not found" -Type Error
        return
    }
    
    Write-Status "Mounting WIM..." -Type Info
    New-Item $Mount -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    
    Mount-WindowsImage -ImagePath $bootWim -Index 1 -Path $Mount
    
    # Remove components
    $removeComponents = @(
        "$Mount\Windows\System32\spool",           # Print queue
        "$Mount\Windows\System32\catroot2",        # Component store
        "$Mount\PerfLogs",                          # Performance logs
        "$Mount\Windows\Prefetch",                 # Prefetch cache
        "$Mount\Users\Default\AppData\Local\Temp", # User temp
        "$Mount\Windows\System32\dllcache"         # DLL cache
    )
    
    foreach ($component in $removeComponents) {
        if (Test-Path $component) {
            $beforeSize = Get-DirectorySize $component
            
            Remove-Item $component -Force -Recurse -ErrorAction SilentlyContinue
            
            Write-Status "Removed: $(Split-Path $component -Leaf) - Freed: $(Format-FileSize $beforeSize)"
        }
    }
    
    Write-Status "Dismounting WIM..." -Type Info
    Dismount-WindowsImage -Path $Mount -Save
    
    Write-Status "Component removal complete" -Type Success
}

# ====================================
# ANALYZE WIM SIZE BREAKDOWN
# ====================================
function Invoke-AnalyzeWIM {
    Write-Status "=== Analyzing WIM Size Breakdown ===" -Type Info
    
    $bootWim = "$Workspace\Media\sources\boot.wim"
    
    if (-not (Test-Path $bootWim)) {
        Write-Status "boot.wim not found" -Type Error
        return
    }
    
    Write-Status "Mounting WIM for analysis..." -Type Info
    New-Item $Mount -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    
    Mount-WindowsImage -ImagePath $bootWim -Index 1 -Path $Mount
    
    # Define analysis sections
    $sections = @{
        'System32'            = "$Mount\Windows\System32"
        'Drivers'             = "$Mount\Windows\System32\drivers"
        'Tools'               = "$Mount\Tools"
        'Temporary Files'     = "$Mount\Windows\Temp,C:\Mount\Payload"
        'WinSXS'             = "$Mount\Windows\WinSXS"
        'Boot Media'          = "$Workspace\Media\*"
    }
    
    $totalSize = 0
    $results = @()
    
    foreach ($section in $sections.GetEnumerator()) {
        $size = 0
        $paths = $section.Value -split ','
        
        foreach ($path in $paths) {
            if (Test-Path $path) {
                $size += Get-DirectorySize $path
            }
        }
        
        $totalSize += $size
        
        $results += [PSCustomObject]@{
            Section = $section.Key
            Size    = $size
            SizeFormatted = Format-FileSize $size
            Percent = 0
        }
    }
    
    # Calculate percentages
    if ($totalSize -gt 0) {
        $results | ForEach-Object { $_.Percent = [math]::Round(($_.Size / $totalSize) * 100, 1) }
    }
    
    Write-Status "WIM Analysis Results:" -Type Info
    Write-Host "`n"
    
    $results | Sort-Object Size -Descending | ForEach-Object {
        $bar = '█' * ([math]::Round($_.Percent / 5))
        Write-Host "$($_.Section.PadRight(25)) $($_.SizeFormatted.PadRight(12)) $($_.Percent.ToString().PadLeft(5))% $bar"
    }
    
    Write-Host "`n"
    Write-Status "Total Size: $(Format-FileSize $totalSize)" -Type Success
    
    Write-Status "Dismounting WIM..." -Type Info
    Dismount-WindowsImage -Path $Mount -Discard
}

# ====================================
# OPTIMIZE ALL
# ====================================
function Invoke-OptimizeAll {
    Write-Status "=== Running Full Optimization ===" -Type Info
    Write-Status "This may take several minutes..." -Type Warning
    Write-Host "`n"
    
    Invoke-CleanupTemp
    Write-Host "`n"
    
    Invoke-RemoveBlob
    Write-Host "`n"
    
    Invoke-CompressWIM
    Write-Host "`n"
    
    Write-Status "Full optimization complete!" -Type Success
}

# ====================================
# GENERATE OPTIMIZATION REPORT
# ====================================
function New-OptimizationReport {
    Write-Status "=== Generating Optimization Report ===" -Type Info
    
    $report = @"
# OSDCloud WinRE Optimization Report
Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

## WIM Statistics

ISO File: $(if (Test-Path "$Workspace\*.iso") { Get-ChildItem "$Workspace\*.iso" | Select -First 1 | % { "$(Split-Path $_ -Leaf) - $(Format-FileSize (Get-Item $_).Length)" } } else { "Not found" })

boot.wim: $(if (Test-Path "$Workspace\Media\sources\boot.wim") { Format-FileSize (Get-Item "$Workspace\Media\sources\boot.wim").Length } else { "Not found" })

## Optimization Areas

### Priority 1 - High Impact
- CleanupTemp: Remove Windows Temp, Logs, Driver cache
- CompressWIM: Recompress with maximum compression
- RemoveBlob: Remove unused system components

### Priority 2 - Medium Impact
- Remove language packs (keep only en-US)
- Remove Store apps not needed
- Clean WinSXS component store

### Priority 3 - Low Impact
- Optimize boot files
- Remove debug symbols
- Clean thumbnail cache

## Recommendations

1. Start with OptimizeAll to perform basic cleanup
2. For production, consider:
   - Removing non-essential drivers
   - Stripping debug information
   - Removing language resources
3. After optimization, re-test to ensure functionality

## Size Reduction Tips

- Language Packs: ~50-100MB each
- Debug Symbols: ~100-200MB
- Component Store (WinSXS): ~200-500MB
- Unused Drivers: ~50-200MB

Target WIM size: < 500MB for efficient network boot
"@
    
    $reportPath = "$Workspace\OPTIMIZATION-REPORT.md"
    Set-Content -Path $reportPath -Value $report -Encoding ASCII
    Write-Status "Report saved: $reportPath" -Type Success
}

# ====================================
# MAIN EXECUTION
# ====================================
function Invoke-Main {
    Write-Host "`n"
    Write-Status "=== OSDCloud WinRE Optimization Utility ===" -Type Info
    Write-Status "Operation: $Operation | Workspace: $Workspace" -Type Info
    Write-Host "`n"
    
    switch ($Operation) {
        'CleanupTemp'  { Invoke-CleanupTemp }
        'CompressWIM'  { Invoke-CompressWIM }
        'RemoveBlob'   { Invoke-RemoveBlob }
        'OptimizeAll'  { Invoke-OptimizeAll }
        'Analyze'      { Invoke-AnalyzeWIM }
    }
    
    New-OptimizationReport
    
    Write-Host "`n"
    Write-Status "=== Operation Complete ===" -Type Success
    Write-Host "`n"
}

# Execute
Invoke-Main
