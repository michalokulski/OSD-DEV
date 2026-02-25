# ============================
# OSDCloud Live WinRE Builder
# ============================

$Workspace = "C:\OSDCloud\LiveWinRE"
$Mount     = "C:\Mount"
$Payload   = "C:\Payload"
$IsoName   = "OSDCloud-LiveWinRE"

# --- Pre-Reqs ---
Write-Host "Installing OSD Module..."
Install-Module OSD -Force -Scope CurrentUser
Import-Module OSD

# --- Create WinRE Template ---
Write-Host "Creating WinRE Template..."
New-OSDCloudTemplate -Name LiveWinRE -WinRE
Set-OSDCloudWorkspace $Workspace

# Inject WiFi GUI + Drivers
Edit-OSDCloudWinPE `
 -CloudDriver * `
 -WirelessConnect `
 -StartOSDCloudGUI

# ------------------------
# SCOOP SETUP (Latest Apps)
# ------------------------
Write-Host "Installing Scoop..."
Set-ExecutionPolicy Bypass -Scope Process -Force
iwr -useb get.scoop.sh | iex

scoop bucket add extras
scoop update

Write-Host "Installing Payload..."
scoop install cairo 7zip openjdk17 microsoft-edge dotnet-runtime pwsh

# Prepare Payload Folder
Remove-Item $Payload -Recurse -Force -ErrorAction SilentlyContinue
New-Item $Payload -ItemType Directory | Out-Null

$apps = @("cairo","7zip","openjdk17","microsoft-edge","dotnet-runtime","pwsh")

foreach ($app in $apps) {
    Copy-Item `
    "$env:USERPROFILE\scoop\apps\$app\current" `
    "$Payload\$app" `
    -Recurse -Force
}

# Fonts for WPF + Cairo
Copy-Item "C:\Windows\Fonts\segoeui.ttf" "$Payload\" -Force

# ------------------------
# MOUNT WINRE
# ------------------------
$BootWim = "$Workspace\Media\sources\boot.wim"

New-Item $Mount -ItemType Directory -Force | Out-Null

Mount-WindowsImage `
 -ImagePath $BootWim `
 -Index 1 `
 -Path $Mount

# Inject Portable Payload
New-Item "$Mount\Portable" -ItemType Directory -Force
Copy-Item "$Payload\*" "$Mount\Portable" -Recurse -Force

Copy-Item "$Payload\segoeui.ttf" "$Mount\Windows\Fonts\" -Force

# ------------------------
# REMOTE LAUNCHER SCRIPT
# ------------------------
@'
if (Test-NetConnection 1.1.1.1 -Quiet) {
    try {
        Invoke-Expression (
          Invoke-RestMethod https://yourserver/script.ps1
        )
    }
}
else {
 Add-Type -AssemblyName PresentationFramework
 [System.Windows.MessageBox]::Show(
 "No Network Detected. Please connect Wi-Fi first."
 )
}
'@ | Out-File `
"$Mount\Portable\RemoteLauncher.ps1" `
-Encoding ASCII

# ------------------------
# DESKTOP SHORTCUT
# ------------------------
New-Item `
"$Mount\Users\Default\Desktop" `
 -ItemType Directory -Force

$Wsh = New-Object -ComObject WScript.Shell

$Shortcut = $Wsh.CreateShortcut(
"$Mount\Users\Default\Desktop\Company Tool.lnk"
)

$Shortcut.TargetPath = "X:\Portable\pwsh\pwsh.exe"
$Shortcut.Arguments = "-ExecutionPolicy Bypass -File X:\Portable\RemoteLauncher.ps1"
$Shortcut.Save()

# ------------------------
# SET SHELL TO CAIRO
# ------------------------
Remove-Item `
"$Mount\Windows\System32\winpeshl.ini" `
-Force -ErrorAction SilentlyContinue

@"
[LaunchApp]
AppPath = X:\Portable\cairo\CairoDesktop.exe
"@ | Out-File `
"$Mount\Windows\System32\winpeshl.ini" `
-Encoding ASCII

# ------------------------
# COMMIT IMAGE
# ------------------------
Dismount-WindowsImage `
 -Path $Mount `
 -Save

# ------------------------
# BUILD ISO
# ------------------------
New-OSDCloudISO `
 -WorkspacePath $Workspace `
 -IsoName $IsoName

Write-Host "ISO Build Complete!"
