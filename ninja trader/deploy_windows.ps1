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
if (Get-Command py -ErrorAction SilentlyContinue) {
    $pythonCmd = 'py'
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $pythonCmd = 'python'
} else {
    throw 'Python was not found. Install Python 3.11+ and rerun this script.'
}

if (-not (Test-Path (Join-Path $InstallDir '.venv'))) {
    if ($pythonCmd -eq 'py') {
        & py -3 -m venv .venv
    } else {
        & python -m venv .venv
    }
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
