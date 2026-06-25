@echo off
rem Launch CAS Cap launcher GUI
rem Runs launcher.ps1 (in this folder) in STA mode
powershell -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1"
