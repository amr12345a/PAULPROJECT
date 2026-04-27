@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "APP_NAME=IBKRTradeExecutor"
set "INSTALL_DIR=%ProgramData%\%APP_NAME%"
set "PORT=8080"
set "PYTHON_VERSION=3.13"
set "PYTHON_PACKAGES=fastapi uvicorn[standard] ib_insync python-dotenv pydantic"
set "IB_GATEWAY_INSTALLER_URL=%IB_GATEWAY_INSTALLER_URL%"
set "IB_GATEWAY_INSTALLER_PATH=%IB_GATEWAY_INSTALLER_PATH%"
set "CREATE_TASK=1"
set "OPEN_FIREWALL=1"

call :require_admin || exit /b 1
call :check_tools || exit /b 1
call :install_python || exit /b 1
call :install_ibkr || exit /b 1
call :deploy_app || exit /b 1

echo.
echo Installation complete.
echo App folder: %INSTALL_DIR%
echo Start the service with:
echo   powershell.exe -ExecutionPolicy Bypass -File "%INSTALL_DIR%\start_windows.ps1"
echo.
exit /b 0

:require_admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo This installer must be run from an elevated Administrator Command Prompt.
    exit /b 1
)
exit /b 0

:check_tools
where powershell.exe >nul 2>&1
if %errorlevel% neq 0 (
    echo PowerShell is required but was not found.
    exit /b 1
)
exit /b 0

:install_python
call :check_python_version
if %errorlevel% equ 0 (
    echo Compatible Python detected.
    goto :install_python_packages
)

where winget >nul 2>&1
if %errorlevel% neq 0 (
    echo winget was not found and Python 3.12 or 3.13 is not installed.
    echo Install Python 3.13 manually, then rerun this installer.
    exit /b 1
)

echo Installing Python %PYTHON_VERSION% with winget...
winget install --id Python.Python.3.13 -e --source winget --accept-package-agreements --accept-source-agreements --silent
if %errorlevel% neq 0 (
    echo Python installation failed.
    exit /b 1
)

call :check_python_version
if %errorlevel% neq 0 (
    echo Python 3.12 or 3.13 is still not available after installation.
    exit /b 1
)

:install_python_packages
exit /b 0

:check_python_version
where py >nul 2>&1
if %errorlevel% neq 0 (
    exit /b 1
)

set "PY_VERSION="
for /f %%V in ('py -3.13 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2^>nul') do set "PY_VERSION=%%V"

if not defined PY_VERSION (
    for /f %%V in ('py -3.12 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2^>nul') do set "PY_VERSION=%%V"
)

if not defined PY_VERSION (
    exit /b 1
)

if "%PY_VERSION%"=="3.12" exit /b 0
if "%PY_VERSION%"=="3.13" exit /b 0

exit /b 1

:install_ibkr
if not defined IB_GATEWAY_INSTALLER_PATH if not defined IB_GATEWAY_INSTALLER_URL (
    echo IB Gateway installer was not provided.
    echo Set IB_GATEWAY_INSTALLER_PATH or IB_GATEWAY_INSTALLER_URL, or install IB Gateway manually and rerun this installer.
    goto :deploy_app
)

set "IB_INSTALLER=%IB_GATEWAY_INSTALLER_PATH%"
if not defined IB_INSTALLER (
    set "IB_INSTALLER=%TEMP%\ibkr-installer.exe"
    echo Downloading IB Gateway installer from %IB_GATEWAY_INSTALLER_URL%...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%IB_GATEWAY_INSTALLER_URL%' -OutFile '%IB_INSTALLER%'"
    if errorlevel 1 (
        echo Failed to download IB Gateway installer.
        exit /b 1
    )
)

if not exist "%IB_INSTALLER%" (
    echo IB Gateway installer not found: %IB_INSTALLER%
    exit /b 1
)

echo Running IB Gateway installer from %IB_INSTALLER%...
start /wait "" "%IB_INSTALLER%"
if errorlevel 1 (
    echo IB Gateway installer returned an error.
    exit /b 1
)

exit /b 0

:deploy_app
if not exist "%SCRIPT_DIR%deploy_windows.ps1" (
    echo deploy_windows.ps1 not found next to this installer.
    exit /b 1
)

echo Deploying the FastAPI app...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%deploy_windows.ps1" -InstallDir "%INSTALL_DIR%" -CreateScheduledTask -OpenFirewall -Port %PORT%
if errorlevel 1 (
    echo App deployment failed.
    exit /b 1
)

exit /b 0
