param([string]$ConfigPath = '')
$ErrorActionPreference = 'Stop'

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot 'launcher-private.json'
}

try {
    $ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $pythonPath = ''
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        try {
            $settings = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($settings.bridge_python -and (Test-Path -LiteralPath $settings.bridge_python -PathType Leaf)) {
                $pythonPath = [string]$settings.bridge_python
            }
        } catch {
            Write-Warning '本机设置需要修正，请在接下来打开的窗口中更新设置。'
        }
    }
    if (-not $pythonPath) {
        $pythonPath = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
    }
    if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
        Write-Host '尚未找到桥接运行环境。' -ForegroundColor Yellow
        Write-Host '请先在本文件夹运行 setup.ps1。已有环境时，可在 launcher-private.json 的 bridge_python 中填写原 Python 路径。'
        exit 1
    }
    Push-Location $PSScriptRoot
    try {
        & $pythonPath -c 'import tkinter' 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host '这个 Python 环境缺少桌面界面组件。请安装含 Tcl/Tk 的 Python，再运行 setup.ps1。' -ForegroundColor Yellow
            exit 1
        }
        & $pythonPath -m launcher --config $ConfigPath --gui
        $launcherResult = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    exit $launcherResult
} catch {
    Write-Host 'Windows 绘画助手未能启动，请检查 Python 路径和文件夹访问权限。' -ForegroundColor Red
    exit 1
}
