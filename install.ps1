<#
.SYNOPSIS
    Windows setup for the trans search data science project.

.DESCRIPTION
    Installs Python (winget first, python.org installer as a fallback), makes sure
    pip is present, builds a .venv with the project requirements, and drops a
    shortcut on the desktop that runs the analysis.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    # Full version used only by the python.org fallback installer.
    [string]$PythonVersion = '3.12.10',
    [string]$ShortcutName = 'trans search data science'
)

$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0

$ProjectRoot  = $PSScriptRoot
$VenvDir      = Join-Path $ProjectRoot '.venv'
$VenvPython   = Join-Path $VenvDir 'Scripts\python.exe'
$Requirements = Join-Path $ProjectRoot 'requirements.txt'
$Launcher     = Join-Path $ProjectRoot 'run_stats.cmd'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# winget and the python.org installer both edit the persisted PATH, which the
# already-running process will not see otherwise.
function Update-SessionPath {
    $parts = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
    ) | Where-Object { $_ }
    $env:Path = $parts -join ';'
}

function Resolve-PythonExe {
    $candidates = New-Object System.Collections.Generic.List[string]

    $launcher = Get-Command 'py' -CommandType Application -ErrorAction SilentlyContinue
    if ($launcher) {
        $resolved = & $launcher.Source -3 -c 'import sys; print(sys.executable)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $resolved) { $candidates.Add(($resolved | Select-Object -First 1).Trim()) }
    }

    foreach ($name in @('python', 'python3')) {
        foreach ($cmd in @(Get-Command $name -CommandType Application -ErrorAction SilentlyContinue)) {
            $candidates.Add($cmd.Source)
        }
    }

    foreach ($exe in $candidates) {
        if ([string]::IsNullOrWhiteSpace($exe)) { continue }
        # A zero-byte stub that just opens the Microsoft Store.
        if ($exe -like '*\WindowsApps\*') { continue }
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }

        $version = & $exe -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $version) { continue }

        $parts = ($version | Select-Object -First 1).Trim().Split('.')
        if ($parts.Count -ge 2 -and [int]$parts[0] -eq 3 -and [int]$parts[1] -ge 9) {
            return $exe
        }
    }

    return $null
}

function Install-PythonWithWinget {
    $winget = Get-Command 'winget' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $winget) { return $false }

    $series = ($PythonVersion.Split('.')[0..1]) -join '.'
    Write-Step "Installing Python $series via winget"
    & $winget.Source install --id "Python.Python.$series" --source winget --scope user `
        --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "winget exited with $LASTEXITCODE; falling back to the python.org installer."
        return $false
    }
    return $true
}

function Install-PythonFromPythonOrg {
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'win32' }
    $url = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-$arch.exe"
    $installer = Join-Path ([System.IO.Path]::GetTempPath()) "python-$PythonVersion-$arch.exe"

    Write-Step "Downloading $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $previous = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
    } finally {
        $ProgressPreference = $previous
    }

    Write-Step 'Running the Python installer (per-user, silent)'
    $arguments = @(
        '/quiet'
        'InstallAllUsers=0'
        'PrependPath=1'
        'Include_pip=1'
        'Include_launcher=1'
        'Include_test=0'
    )
    $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue

    # 3010 means the install succeeded but wants a reboot.
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "The Python installer failed with exit code $($process.ExitCode)."
    }
}

function New-Launcher {
    $content = @'
@echo off
cd /d "%~dp0"
".venv\Scripts\python.exe" "stats.py"
echo.
pause
'@
    Set-Content -LiteralPath $Launcher -Value $content -Encoding ASCII
}

function New-DesktopShortcut {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) { throw 'Could not locate the desktop folder.' }

    $shortcutPath = Join-Path $desktop "$ShortcutName.lnk"
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $Launcher
        $shortcut.WorkingDirectory = $ProjectRoot
        $shortcut.Description = 'Run the trans search data science analysis'
        $shortcut.IconLocation = "$VenvPython,0"
        $shortcut.Save()
    } finally {
        [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
    }
    return $shortcutPath
}

if (-not (Test-Path -LiteralPath $Requirements -PathType Leaf)) {
    throw "requirements.txt not found next to this script (looked in $ProjectRoot)."
}

Write-Step 'Looking for an existing Python 3.9+'
$python = Resolve-PythonExe

if (-not $python) {
    Write-Host 'No suitable Python found.'
    if (-not (Install-PythonWithWinget)) {
        Install-PythonFromPythonOrg
    }
    Update-SessionPath
    $python = Resolve-PythonExe
    if (-not $python) {
        throw 'Python was installed but is still not on PATH. Open a new terminal and re-run this script.'
    }
} else {
    Write-Host "Found $python"
}

# The python.org and winget builds both bundle pip, but a repaired or trimmed
# install can be missing it.
& $python -m pip --version *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Step 'Bootstrapping pip with ensurepip'
    & $python -m ensurepip --default-pip
    if ($LASTEXITCODE -ne 0) { throw 'Could not bootstrap pip.' }
}

if (-not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
    Write-Step "Creating the virtual environment in $VenvDir"
    & $python -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create the virtual environment.' }
} else {
    Write-Step 'Reusing the existing virtual environment'
}

Write-Step 'Upgrading pip'
& $VenvPython -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw 'Failed to upgrade pip.' }

Write-Step 'Installing requirements'
& $VenvPython -m pip install -r $Requirements
if ($LASTEXITCODE -ne 0) { throw 'Failed to install the requirements.' }

Write-Step 'Creating the launcher and desktop shortcut'
New-Launcher
$shortcut = New-DesktopShortcut

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host "  Shortcut: $shortcut"
Write-Host "  Manual run: `"$VenvPython`" `"$(Join-Path $ProjectRoot 'stats.py')`""
