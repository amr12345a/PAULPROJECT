param(
    [string]$InstallDir = "$env:ProgramData\NinjaTraderTradeExecutor",
    [string]$TaskName = 'NinjaTraderTradeExecutor',
    [switch]$CreateScheduledTask,
    [switch]$OpenFirewall,
    [int]$Port = 80
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$filesToCopy = @(
    'main.py',
    'requirements.txt',
    '.env.example',
    'README.md',
    'start_windows.ps1'
)

function Get-SupportedPythonLauncher {
    $candidates = @(
        @{ Exe = 'py'; Args = @('-3.13') },
        @{ Exe = 'py'; Args = @('-3.12') },
        @{ Exe = 'python'; Args = @() },
        @{ Exe = 'python3'; Args = @() }
    )

    foreach ($candidate in $candidates) {
        if (-not (Get-Command $candidate.Exe -ErrorAction SilentlyContinue)) {
            continue
        }

        $probe = & $candidate.Exe @($candidate.Args + @('-c', 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')) 2>$null
        if ($LASTEXITCODE -ne 0) {
            continue
        }

        if ($probe -match '^3\.(12|13)$') {
            return $candidate
        }
    }

    throw 'Python 3.12 or 3.13 is required. Python 3.14 forces a source build of pydantic-core, which needs Rust/Cargo.'
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

foreach ($file in $filesToCopy) {
    $sourcePath = Join-Path $scriptRoot $file
    $targetPath = Join-Path $InstallDir $file
    if (-not (Test-Path $sourcePath)) {
        throw "Required file not found: $sourcePath"
    }
    Copy-Item -Force $sourcePath $targetPath
}

Set-Location $InstallDir

if (-not (Test-Path (Join-Path $InstallDir '.env'))) {
    Copy-Item -Force (Join-Path $InstallDir '.env.example') (Join-Path $InstallDir '.env')
    Write-Host "Created .env from template at $InstallDir\.env"
}

$pythonCmd = $null
$pythonCmd = Get-SupportedPythonLauncher

if (-not (Test-Path (Join-Path $InstallDir '.venv'))) {
    & $pythonCmd.Exe @($pythonCmd.Args + @('-m', 'venv', '.venv'))
}

$venvPython = Join-Path $InstallDir '.venv\Scripts\python.exe'
if (-not (Test-Path $venvPython)) {
    throw "Virtual environment creation failed: $venvPython does not exist"
}

& $venvPython -m pip install --upgrade pip
& $venvPython -m pip install -r requirements.txt

if ($OpenFirewall) {
    $ruleName = "NinjaTraderTradeExecutor-$Port"
    if (-not (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)) {
        Write-Warning 'New-NetFirewallRule is not available on this system.'
    } else {
        try {
            if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port | Out-Null
                Write-Host "Created Windows Firewall rule: $ruleName"
            }
        } catch {
            Write-Warning "Failed to create firewall rule: $($_.Exception.Message)"
        }
    }
}

if ($CreateScheduledTask) {
    $startScript = Join-Path $InstallDir 'start_windows.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$startScript`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Registered scheduled task: $TaskName"
}

Write-Host ''
Write-Host 'Deployment complete.'
Write-Host "Install directory: $InstallDir"
Write-Host "Start manually: powershell.exe -ExecutionPolicy Bypass -File `"$InstallDir\start_windows.ps1`""
Write-Host "Health check: curl http://127.0.0.1:$Port/health"
