@echo off
rem Debug launcher: keeps the console open; syntax/startup errors are shown in a dialog and in startup-error.log
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -NoExit -File "%~dp0Launch.ps1"
