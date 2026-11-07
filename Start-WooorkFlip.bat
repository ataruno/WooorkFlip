@echo off
cd /d "%~dp0"
pwsh.exe -NoProfile -STA -File "%~dp0WooorkFlip-GUI.ps1"
