@echo off
title Windows Tweaks Launcher
cd /d "%~dp0"

:: Prefer the real standalone app (installed > win-unpacked > portable).
:: Browser fallback (server.ps1 app-mode) only if no app binary is found.
set "INSTALLED=C:\Program Files\Windows Tweaks\Windows Tweaks.exe"
set "UNPACKED=%~dp0dist\win-unpacked\Windows Tweaks.exe"
set "PORTABLE=%~dp0dist\WindowsTweaks-Portable.exe"

if exist "%INSTALLED%" (
    echo [Tweaks] Launching standalone app...
    start "" "%INSTALLED%"
    exit /b
)
if exist "%UNPACKED%" (
    echo [Tweaks] Launching standalone app (win-unpacked)...
    start "" "%UNPACKED%"
    exit /b
)
if exist "%PORTABLE%" (
    echo [Tweaks] Launching standalone app (portable)...
    start "" "%PORTABLE%"
    exit /b
)

:: --- Fallback: browser mode (no app binary found) ---
:: Check for Administrative privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [Tweaks] Requesting Administrator Privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~dp0start.bat\"' -Verb RunAs"
    exit /b
)

echo ==============================================================================
echo                      WINDOWS TWEAKS LAUNCHER (BROWSER FALLBACK)
echo ==============================================================================
echo [Tweaks] No standalone app binary found, starting browser mode...
echo [Tweaks] Starting background listener on http://127.0.0.1:48921/
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
pause
