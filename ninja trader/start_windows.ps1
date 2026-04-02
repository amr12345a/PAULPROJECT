$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$venvPython = Join-Path $scriptRoot '.venv\Scripts\python.exe'

if (-not (Test-Path $venvPython)) {
    throw "Python virtual environment not found at $venvPython. Run deploy_windows.ps1 first."
}

Set-Location $scriptRoot
& $venvPython -m uvicorn main:app --host 0.0.0.0 --port 8080
