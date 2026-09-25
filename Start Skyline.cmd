@echo off
rem Starts the Skyline development environment. See scripts\dev-up.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\dev-up.ps1" %*
