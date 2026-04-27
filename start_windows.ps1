param(
    [string]$InstallDir = "$PSScriptRoot"
)

$ErrorActionPreference = 'Stop'

Set-Location $InstallDir

$venvPython = Join-Path $InstallDir '.venv\Scripts\python.exe'
if (-not (Test-Path $venvPython)) {
    throw "Python virtual environment not found at $venvPython. Run deploy_windows.ps1 first."
}

$hostAddress = '0.0.0.0'
$port = 8080
$envPath = Join-Path $InstallDir '.env'

if (Test-Path $envPath) {
    foreach ($rawLine in Get-Content $envPath) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#') -or -not $line.Contains('=')) {
            continue
        }

        $key, $value = $line.Split('=', 2)
        $key = $key.Trim()
        $value = $value.Trim().Trim('"')

        if ($key -eq 'HOST' -and $value) {
            $hostAddress = $value
            continue
        }

        if ($key -eq 'PORT') {
            $parsedPort = 0
            if ([int]::TryParse($value, [ref]$parsedPort)) {
                $port = $parsedPort
            }
        }
    }
}

& $venvPython -m uvicorn main:app --host $hostAddress --port $port
