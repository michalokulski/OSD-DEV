# ============================
# OSDCloud Live WinRE Builder
# Cairo + Semeru8 + JAR Support
# ============================

$Workspace = "C:\OSDCloud\LiveWinRE"
$Mount     = "C:\Mount"
$Payload   = "C:\Payload"
$IsoName   = "OSDCloud-LiveWinRE"

Install-Module OSD -Force -Scope CurrentUser
Import-Module OSD

New-OSDCloudTemplate -Name LiveWinRE -WinRE
Set-OSDCloudWorkspace $Workspace

Edit-OSDCloudWinPE `
 -CloudDriver * `
 -WirelessConnect `
 -StartOSDCloudGUI

# ------------------------
# SCOOP
# ------------------------
Set-ExecutionPolicy Bypass -Scope Process -Force
iwr -useb get.scoop.sh | iex

scoop bucket add extras
scoop update

scoop install cairo 7zip semeru8-jre microsoft-edge dotnet-runtime pwsh

Remove-Item $Payload -Recurse -Force -ErrorAction SilentlyContinue
New-Item $Payload -ItemType Directory | Out-Null

$apps = @(
"cairo",
"7zip",
"semeru8-jre",
"microsoft-edge",
"dotnet-runtime",
"pwsh"
)

foreach ($app in $apps) {
    Copy-Item `
    "$env:USERPROFILE\scoop\apps\$app\current" `
    "$Payload\$app" `
    -Recurse -Force
}

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

New-Item "$Mount\Portable" -ItemType Directory -Force
Copy-Item "$Payload\*" "$Mount\Portable" -Recurse -Force
Copy-Item "$Payload\segoeui.ttf" "$Mount\Windows\Fonts\" -Force

# ------------------------
# REGISTRY ENVIRONMENT
# ------------------------
reg load HKLM\WinRE "$Mount\Windows\System32\Config\SYSTEM"

reg add HKLM\WinRE\ControlSet001\Control\Session Manager\Environment `
 /v JAVA_HOME `
 /t REG_SZ `
 /d X:\Portable\semeru8-jre `
 /f

reg add HKLM\WinRE\ControlSet001\Control\Session Manager\Environment `
 /v Path `
 /t REG_EXPAND_SZ `
 /d "X:\Portable\semeru8-jre\bin;X:\Portable\pwsh" `
 /f

reg unload HKLM\WinRE

# ------------------------
# JAR FILE ASSOCIATION
# ------------------------
reg load HKLM\WinRESW "$Mount\Windows\System32\Config\SOFTWARE"

reg add HKLM\WinRESW\Classes\.jar `
 /ve /t REG_SZ /d jarfile /f

reg add HKLM\WinRESW\Classes\jarfile\shell\open\command `
 /ve /t REG_SZ `
 /d "\"X:\Portable\semeru8-jre\bin\javaw.exe\" -jar \"%1\"" `
 /f

reg unload HKLM\WinRESW

# ------------------------
# REMOTE SCRIPT
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
 "Please connect Wi-Fi first"
 )
}
'@ | Out-File `
"$Mount\Portable\RemoteLauncher.ps1" `
-Encoding ASCII

# ------------------------
# DESKTOP
# ------------------------
New-Item "$Mount\Users\Default\Desktop" -ItemType Directory -Force

$Wsh = New-Object -ComObject WScript.Shell

$Shortcut = $Wsh.CreateShortcut(
"$Mount\Users\Default\Desktop\Run Company Tool.lnk"
)

$Shortcut.TargetPath = "X:\Portable\pwsh\pwsh.exe"
$Shortcut.Arguments = "-ExecutionPolicy Bypass -File X:\Portable\RemoteLauncher.ps1"
$Shortcut.Save()

# ------------------------
# SET CAIRO SHELL
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
# COMMIT
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
