@ECHO OFF
wpeinit
cd\
title OSD 26.2.3.2
PowerShell -Nol -C Initialize-OSDCloudStartnet -WirelessConnect
PowerShell -Nol -C Initialize-OSDCloudStartnetUpdate
@ECHO OFF
ECHO Start-OSDCloud
start /wait PowerShell -NoL -C Start-OSDCloud -OSName 'Windows 11 24H2 x64' -OSLanguage en-us -OSEdition Enterprise -OSActivation Volume -Restart -ZTI
@ECHO ON
