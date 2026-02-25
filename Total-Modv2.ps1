$Workspace = "C:\OSDCloud\LiveWinRE"
$Mount     = "C:\Mount"
$Payload   = "C:\Payload"
$IsoName   = "OSDCloud-LiveWinRE"

# ========================
# PREREQUISITES - SCOOP
# ========================
Set-ExecutionPolicy Bypass -Scope Process -Force

# Check if Scoop is already installed
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Scoop with admin privileges..."
    iex "& {$(irm get.scoop.sh)} -RunAsAdmin"
}
else {
    Write-Host "Scoop is already installed"
}

# Install Git first (required for Scoop buckets)
Write-Host "Installing Git (required for Scoop)..."
scoop install git

# Configure buckets
Write-Host "Adding buckets..."
scoop bucket add extras
scoop bucket add java
scoop bucket add versions
scoop bucket add nonportable

Write-Host "Updating Scoop..."
scoop update

# Install apps with correct names
Write-Host "Installing required applications..."
$appsToInstall = @(
    @{ name = "powershell-core"; alt = "pwsh" },
    @{ name = "7zip"; alt = "7z" },
    @{ name = "temurin8-jre"; alt = "java" },
    @{ name = "microsoft-edge"; alt = "edge" },
    @{ name = "dotnet-runtime"; alt = $null },
    @{ name = "cairo"; alt = $null }
)

foreach ($appConfig in $appsToInstall) {
    $appName = $appConfig.name
    Write-Host "Attempting to install $appName..."
    scoop install $appName 2>$null
    
    if ($LASTEXITCODE -ne 0) {
        if ($appConfig.alt) {
            Write-Host "Trying alternative name: $($appConfig.alt)..."
            scoop install $appConfig.alt 2>$null
            if ($LASTEXITCODE -eq 0) {
                $appName = $appConfig.alt
                Write-Host "Successfully installed $appName"
            } else {
                Write-Warning "Failed to install $appName or alternative, continuing..."
            }
        } else {
            Write-Warning "Failed to install $appName, continuing..."
        }
    } else {
        Write-Host "Successfully installed $appName"
    }
}

# Prepare Payload folder
Remove-Item $Payload -Recurse -Force -ErrorAction SilentlyContinue
New-Item $Payload -ItemType Directory | Out-Null

# Map of original names to actual installed app names
# Install apps with correct names
Write-Host "Installing required applications..."
$appsToInstall = @(
    @{ name = "powershell-core"; alt = "pwsh" },
    @{ name = "7zip"; alt = "7z" },
    @{ name = "temurin8-jre"; alt = "java" },
    @{ name = "googlechrome"; alt = "edge" },
    @{ name = "dotnet10-sdk"; alt = $null },
    @{ name = "cairo-desktop"; alt = $null }
)

foreach ($originalName in $appMapping.Keys) {
    $possibleNames = $appMapping[$originalName]
    $found = $false
    
    foreach ($possibleName in $possibleNames) {
        $appPath = "$env:USERPROFILE\scoop\apps\$possibleName\current"
        if (Test-Path $appPath) {
            Write-Host "Copying $possibleName to Payload..."
            Copy-Item $appPath "$Payload\$possibleName" -Recurse -Force -ErrorAction SilentlyContinue
            $found = $true
            break
        }
    }
    
    if (-not $found) {
        Write-Warning "Could not find $originalName (tried: $($possibleNames -join ', ')) - skipping"
    }
}

if (Test-Path "C:\Windows\Fonts\segoeui.ttf") {
    Write-Host "Copying segoeui.ttf to Payload..."
    Copy-Item "C:\Windows\Fonts\segoeui.ttf" "$Payload\" -Force
}

# ========================
# OSD CLOUD SETUP
# ========================
Install-Module OSD -Force -Scope CurrentUser
Import-Module OSD

New-OSDCloudTemplate -Name LiveWinRE -WinRE
Set-OSDCloudWorkspace $Workspace

Edit-OSDCloudWinPE `
 -CloudDriver * `
 -WirelessConnect `
 -StartOSDCloudGUI

# ------------------------
# MOUNT WINRE
# ------------------------
$BootWim = "$Workspace\Media\sources\boot.wim"
New-Item $Mount -ItemType Directory -Force | Out-Null

Mount-WindowsImage `
 -ImagePath $BootWim `
 -Index 1 `
 -Path $Mount

New-Item "$Mount\Portable" -ItemType Directory -Force
Copy-Item "$Payload\*" "$Mount\Portable" -Recurse -Force
Copy-Item "$Payload\segoeui.ttf" "$Mount\Windows\Fonts\" -Force

# ------------------------
# JAVA ENV + PATH
# ------------------------
reg load HKLM\WinRE "$Mount\Windows\System32\Config\SYSTEM"

reg add HKLM\WinRE\ControlSet001\Control\Session Manager\Environment `
 /v JAVA_HOME /t REG_SZ `
 /d X:\Portable\semeru8-jre /f

reg add HKLM\WinRE\ControlSet001\Control\Session Manager\Environment `
 /v Path /t REG_EXPAND_SZ `
 /d "X:\Portable\semeru8-jre\bin;X:\Portable\pwsh" /f

reg unload HKLM\WinRE

# ------------------------
# JAR SUPPORT
# ------------------------
reg load HKLM\WinRESW "$Mount\Windows\System32\Config\SOFTWARE"

reg add HKLM\WinRESW\Classes\.jar `
 /ve /t REG_SZ /d jarfile /f

reg add HKLM\WinRESW\Classes\jarfile\shell\open\command `
 /ve /t REG_SZ `
 /d "\"X:\Portable\semeru8-jre\bin\javaw.exe\" -jar \"%1\"" /f

reg unload HKLM\WinRESW

# ------------------------
# MODE SELECTOR
# ------------------------
@'
Add-Type -AssemblyName PresentationFramework
$result = [System.Windows.MessageBox]::Show(
"Select Mode:`nYes = Deploy`nNo = Maintenance",
"LiveOS",
"YesNo"
)

if ($result -eq "Yes") {
 Start-Process X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe `
 "-ExecutionPolicy Bypass -Command Start-OSDCloudGUI"
}
else {
 Start-Process X:\Portable\cairo\CairoDesktop.exe
}
'@ | Out-File "$Mount\Portable\ModeSelect.ps1" -Encoding ASCII

# ------------------------
# REMOTE TOOL
# ------------------------
@'
if (Test-NetConnection 1.1.1.1 -Quiet) {
 Invoke-Expression (
  Invoke-RestMethod https://yourserver/script.ps1
 )
}
else {
 Add-Type -AssemblyName PresentationFramework
 [System.Windows.MessageBox]::Show("Connect Wi-Fi first")
}
'@ | Out-File "$Mount\Portable\RemoteLauncher.ps1" -Encoding ASCII

# ------------------------
# DESKTOP SHORTCUT
# ------------------------
New-Item "$Mount\Users\Default\Desktop" -ItemType Directory -Force

$Wsh = New-Object -ComObject WScript.Shell
$Shortcut = $Wsh.CreateShortcut(
"$Mount\Users\Default\Desktop\Company Tool.lnk"
)
$Shortcut.TargetPath = "X:\Portable\pwsh\pwsh.exe"
$Shortcut.Arguments = "-ExecutionPolicy Bypass -File X:\Portable\RemoteLauncher.ps1"
$Shortcut.Save()

# ------------------------
# START MENU
# ------------------------
New-Item `
"$Mount\ProgramData\Microsoft\Windows\Start Menu\Programs" `
 -ItemType Directory -Force

$Deploy = $Wsh.CreateShortcut(
"$Mount\ProgramData\Microsoft\Windows\Start Menu\Programs\OSD Deploy.lnk"
)
$Deploy.TargetPath="X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$Deploy.Arguments="-ExecutionPolicy Bypass -Command Start-OSDCloudGUI"
$Deploy.Save()

# ------------------------
# TASKBAR PIN
# ------------------------
reg load HKLM\Task "$Mount\Windows\System32\Config\SOFTWARE"

reg add HKLM\Task\Microsoft\Windows\CurrentVersion\Explorer\Taskband `
 /v FavoritesResolve `
 /t REG_BINARY `
 /d 30000000 /f

reg unload HKLM\Task

# ------------------------
# SHELL = MODE SELECTOR
# ------------------------
Remove-Item "$Mount\Windows\System32\winpeshl.ini" -Force

@"
[LaunchApp]
AppPath = X:\Portable\pwsh\pwsh.exe
CmdLine = -ExecutionPolicy Bypass -File X:\Portable\ModeSelect.ps1
"@ | Out-File `
"$Mount\Windows\System32\winpeshl.ini" `
-Encoding ASCII

# ------------------------
# COMMIT
# ------------------------
Dismount-WindowsImage `
 -Path $Mount `
 -Save

New-OSDCloudISO `
 -WorkspacePath $Workspace `
 -IsoName $IsoName
