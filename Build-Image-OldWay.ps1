$PATH_Wallpaper = ""
$PATH_URL = ""

Set-ExecutionPolicy RemoteSigned -Force
Install-Module OSD
Import-Module OSD

#Creates an OSDCloud Template in $env:ProgramData\OSDCloud
New-OSDCloudTemplate -Name WinRE -WinRE -Add7Zip -Verbose
#Changes the path to the OSDCloud Workspace from an OSDCloud Template
Set-OSDCloudWorkspace C:/OSDCloudWinRE -Verbose
#Sets the current OSDCloud Template to a valid OSDCloud Template returned by Get-OSDCloudTemplateNames
Set-OSDCloudTemplate -Name 'WinRE' -Verbose
#Edits WinPE in an OSDCloud Workspace for customization
Edit-OSDCloudWinPE -StartOSDCloud "-OSName 'Windows 11 24H2 x64' -OSLanguage en-us -OSEdition Enterprise -OSActivation Volume -Restart -ZTI" `
#-Wallpaper $PATH_Wallpaper `
#-CloudDriver * `
#-StartURL $PATH_URL 
