@echo off
chcp 65001 > nul
title Doprax Clean IP Hunter
echo Starting Doprax Clean IP Hunter...
python doprax_hunter.py
if %errorlevel% neq 0 (
    echo.
    echo Trying direct python executable...
    "%LOCALAPPDATA%\Python\bin\python.exe" doprax_hunter.py
)
pause
