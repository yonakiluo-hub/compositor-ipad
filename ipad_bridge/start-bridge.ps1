param(
    [ValidateSet('mock', 'comfyui')][string]$Backend = 'mock',
    [string]$ComfyUrl = 'http://127.0.0.1:8188',
    [string]$ComfyModelsDirectory = '',
    [string]$ComfyInstallDirectory = '',
    [switch]$EnableExperimental,
    [int]$MaxPendingJobs = 8,
    [string]$ListenAddress = '127.0.0.1',
    [int]$Port = 8190,
    [string]$BaseUrl = '',
    [string]$DataDirectory = '',
    [string]$Certificate = '',
    [string]$PrivateKey = ''
)
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    $python = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $python)) { throw 'Run setup.ps1 first.' }
    if (-not $DataDirectory) { $DataDirectory = Join-Path $PSScriptRoot ('data-' + $Backend) }
    if ([bool]$Certificate -ne [bool]$PrivateKey) { throw 'Provide both Certificate and PrivateKey for TLS.' }
    if (-not $BaseUrl) {
        if ($ListenAddress -eq '0.0.0.0' -or $ListenAddress -eq '::') {
            throw 'For LAN access, pass BaseUrl with the computer LAN address.'
        }
        $scheme = if ($Certificate) { 'https' } else { 'http' }
        $BaseUrl = '{0}://{1}:{2}' -f $scheme, $ListenAddress, $Port
    }
    $common = @('--data-dir', $DataDirectory, '--backend', $Backend, '--comfy-url', $ComfyUrl)
    if ($ComfyModelsDirectory) { $common += @('--comfy-models-dir', $ComfyModelsDirectory) }
    if ($ComfyInstallDirectory) { $common += @('--comfy-install-dir', $ComfyInstallDirectory) }
    if ($EnableExperimental) { $common += '--enable-experimental' }
    $common += @('--max-pending-jobs', [string]$MaxPendingJobs)
    & $python -m bridge pairing @common --base-url $BaseUrl
    if ($LASTEXITCODE -ne 0) { throw 'Pairing setup failed.' }
    $serveArgs = @('--host', $ListenAddress, '--port', [string]$Port)
    if ($Certificate) { $serveArgs += @('--ssl-certfile', $Certificate, '--ssl-keyfile', $PrivateKey) }
    & $python -m bridge serve @common @serveArgs
    if ($LASTEXITCODE -ne 0) { throw 'Bridge exited with an error. Inspect the preceding log.' }
} finally { Pop-Location }
