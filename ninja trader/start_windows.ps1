$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$venvPython = Join-Path $scriptRoot '.venv\Scripts\python.exe'

if (-not (Test-Path $venvPython)) {
    throw "Python virtual environment not found at $venvPython. Run deploy_windows.ps1 first."
}

Set-Location $scriptRoot

$port = 8080
$envPath = Join-Path $scriptRoot '.env'
if (Test-Path $envPath) {
    $portLine = Get-Content $envPath | Where-Object { $_ -match '^\s*PORT\s*=' } | Select-Object -First 1
    if ($portLine) {
        $rawPort = ($portLine -split '=', 2)[1].Trim().Trim('"', "'")
        $parsedPort = 0
        if ([int]::TryParse($rawPort, [ref]$parsedPort) -and $parsedPort -gt 0 -and $parsedPort -le 65535) {
            $port = $parsedPort
        } else {
            Write-Warning "Invalid PORT value '$rawPort' in .env. Falling back to 8080."
        }
    }
}

& $venvPython -m uvicorn main:app --host 0.0.0.0 --port $port
