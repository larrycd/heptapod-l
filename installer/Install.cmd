@echo off
title Heptapod L Studio installer
echo Placing the Heptapod L infographics on your Desktop...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=[Environment]::GetFolderPath('Desktop'); Copy-Item -LiteralPath '%~dp0Heptapod L - Positional Map.png','%~dp0Heptapod L - Positional Map (Paper).png','%~dp0Heptapod L - How It Works.png' -Destination $d -Force; Write-Host ('Copied to ' + $d)"
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
echo.
pause
