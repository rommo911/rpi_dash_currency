@echo off
REM Run the dashboard locally on Windows for testing, via a Python venv.
REM Double-click this file, or run it from a terminal:
REM   scripts\run-local-windows.bat
REM Stop the server with Ctrl+C.

setlocal

set "SCRIPT_DIR=%~dp0"
set "PROJECT_DIR=%SCRIPT_DIR%.."
cd /d "%PROJECT_DIR%"

where python >nul 2>nul
if errorlevel 1 (
    echo Python was not found on PATH. Install it from https://www.python.org/downloads/ and re-run this script.
    pause
    exit /b 1
)

if not exist ".venv\Scripts\python.exe" (
    echo Creating virtual environment in .venv ...
    python -m venv .venv
    if errorlevel 1 (
        echo Failed to create the virtual environment.
        pause
        exit /b 1
    )
)

echo Installing/updating dependencies ...
".venv\Scripts\python.exe" -m pip install --upgrade pip >nul
".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 (
    echo Failed to install dependencies.
    pause
    exit /b 1
)

if not exist "config.py" (
    echo config.py not found next to app.py - create it with an ADMIN_PASSWORD before continuing.
    pause
    exit /b 1
)

echo.
echo Starting the dashboard ...
echo   Dashboard: http://127.0.0.1:5000/
echo   Admin:     http://127.0.0.1:5000/admin
echo Press Ctrl+C to stop.
echo.

".venv\Scripts\python.exe" app.py

endlocal
