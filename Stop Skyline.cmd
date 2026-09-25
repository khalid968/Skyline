@echo off
rem Closes what "Start Skyline" opened. Add -StopDocker to stop the data stack too.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\dev-down.ps1" %*
