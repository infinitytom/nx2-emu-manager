@echo off
rem Debug launcher: keeps the console open so startup errors are visible
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -NoExit -File "%~dp0EmuManager.ps1"
