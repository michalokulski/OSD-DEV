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
# SCOOP APPS
# ------------------------
Set-ExecutionPolicy Bypass -Scope Process -Force
$env:SCOOP_USE_ARIA2 = 'false'
$env:SCOOP_ALLOW_ADMIN = 'true'
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
 "$Payload\$app" -Recurse -Force
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
