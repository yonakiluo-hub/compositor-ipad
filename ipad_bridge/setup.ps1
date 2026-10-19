param([string]$Python = 'python', [switch]$WithTests)
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    if (-not (Test-Path -LiteralPath '.venv\Scripts\python.exe')) {
        & $Python -m venv .venv
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the Python environment.' }
    }
    $requirements = if ($WithTests) { 'requirements-dev.txt' } else { 'requirements.txt' }
    & '.\.venv\Scripts\python.exe' -m pip install -r $requirements
    if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
} finally { Pop-Location }
