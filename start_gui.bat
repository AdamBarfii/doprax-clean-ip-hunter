@echo off
chcp 65001 > nul
title AetherProbe - Doprax Clean IP Hunter GUI
echo Starting AetherProbe Modern Desktop Dashboard...
python gui.py
if %errorlevel% neq 0 (
    echo.
    echo Trying direct python executable...
    "%LOCALAPPDATA%\Python\bin\python.exe" gui.py
)
pause
