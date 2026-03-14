param(
    [string]$ArtifactUrl = 'https://github.com/timfel/graalpython/actions/runs/23074531328/artifacts/5920266079',
    [string]$ArtifactRepo = 'timfel/graalpython',
    [string]$GraalPyExe,
    [ValidateSet('pure', 'c')]
    [string]$ProjectType = 'c',
    [ValidateSet('uv', 'build-uv', 'compare')]
    [string]$Frontend = 'compare',
    [string]$WorkRoot = (Join-Path $env:TEMP 'uv-graalpy-minimal-repro'),
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Section([string]$Message) {
    Write-Host "`n=== $Message ==="
}

function New-LegacyProject([string]$ProjectRoot, [string]$Kind) {
    New-Item -ItemType Directory -Force -Path $ProjectRoot | Out-Null

    if ($Kind -eq 'pure') {
        Set-Content -Path (Join-Path $ProjectRoot 'setup.py') -Encoding utf8 -Value @"
from setuptools import setup

setup(
    name='spam',
    version='0.1.0',
    py_modules=['spam'],
)
"@
        Set-Content -Path (Join-Path $ProjectRoot 'spam.py') -Encoding utf8 -Value @"
def ping():
    return 'pong'
"@
        return
    }

    Set-Content -Path (Join-Path $ProjectRoot 'setup.py') -Encoding utf8 -Value @"
import os
import sys

from setuptools import Extension, setup

libraries = []
if sys.platform.startswith('linux') and 'emscripten' not in os.environ.get('_PYTHON_HOST_PLATFORM', ''):
    libraries.extend(['m', 'c'])

setup(
    name='spam',
    version='0.1.0',
    ext_modules=[
        Extension(
            'spam',
            sources=['spam.c'],
            libraries=libraries,
        )
    ],
)
"@
    Set-Content -Path (Join-Path $ProjectRoot 'spam.c') -Encoding utf8 -Value @"
#include <Python.h>

static PyObject *
spam_filter(PyObject *self, PyObject *args)
{
    const char *content;
    int sts;

    if (!PyArg_ParseTuple(args, "s", &content))
        return NULL;

    sts = strcmp(content, "spam") != 0;
    return PyLong_FromLong(sts);
}

static PyMethodDef module_methods[] = {
    {"filter", (PyCFunction)spam_filter, METH_VARARGS, "Execute a shell command."},
    {NULL}
};

PyMODINIT_FUNC PyInit_spam(void)
{
    static struct PyModuleDef moduledef = {
        PyModuleDef_HEAD_INIT, "spam", "Example module", -1, module_methods,
    };
    return PyModule_Create(&moduledef);
}
"@
}

function Get-GraalPyExePath {
    if ($GraalPyExe) {
        return [System.IO.Path]::GetFullPath($GraalPyExe)
    }

    $helper = Join-Path $PSScriptRoot 'fetch_graalpy_artifact.ps1'
    $helperResult = & $helper -ArtifactUrl $ArtifactUrl -ArtifactRepo $ArtifactRepo -DestinationRoot (Join-Path $WorkRoot 'graalpython-artifact')
    return ($helperResult | Select-Object -Last 1).ToString().Trim()
}
function Invoke-LoggedCommand {
    param(
        [string]$Label,
        [string[]]$Command,
        [string]$WorkingDirectory,
        [string]$LogPath,
        [hashtable]$Environment
    )

    $joined = $Command | ForEach-Object {
        if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
    }
    $header = "`n>>> $Label`nPWD: $WorkingDirectory`nCMD: $($joined -join ' ')`n"
    $header | Tee-Object -FilePath $LogPath -Append | Out-Host

    Push-Location $WorkingDirectory
    try {
        $oldEnv = @{}
        foreach ($entry in $Environment.GetEnumerator()) {
            $name = [string]$entry.Key
            $oldEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, [string]$entry.Value, 'Process')
        }

        try {
            $stdoutPath = Join-Path $WorkingDirectory ([guid]::NewGuid().ToString() + '.stdout.log')
            $stderrPath = Join-Path $WorkingDirectory ([guid]::NewGuid().ToString() + '.stderr.log')
            $arguments = @()
            if ($Command.Length -gt 1) {
                $arguments = $Command[1..($Command.Length - 1)]
            }
            $process = Start-Process -FilePath $Command[0] -ArgumentList $arguments -WorkingDirectory $WorkingDirectory -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
            if (Test-Path $stdoutPath) {
                Get-Content $stdoutPath | Tee-Object -FilePath $LogPath -Append | Out-Host
                Remove-Item $stdoutPath -Force
            }
            if (Test-Path $stderrPath) {
                Get-Content $stderrPath | Tee-Object -FilePath $LogPath -Append | Out-Host
                Remove-Item $stderrPath -Force
            }
            return $process.ExitCode
        }
        finally {
            foreach ($entry in $oldEnv.GetEnumerator()) {
                [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, 'Process')
            }
        }
    }
    finally {
        Pop-Location
    }
}

function New-CaseEnvironment {
    param(
        [string]$GraalPyExePath,
        [string]$CaseRoot
    )

    $uv = (Get-Command uv -ErrorAction Stop).Source
    $venvDir = Join-Path $CaseRoot 'venv'
    $envMap = @{}

    New-Item -ItemType Directory -Force -Path $CaseRoot | Out-Null
    $exitCode = Invoke-LoggedCommand -Label 'Create GraalPy venv' -Command @($uv, 'venv', $venvDir, '--python', $GraalPyExePath) -WorkingDirectory $CaseRoot -LogPath (Join-Path $CaseRoot 'commands.log') -Environment $envMap
    if ($exitCode -ne 0 -or -not (Test-Path (Join-Path $venvDir 'Scripts\python.exe'))) {
        throw "Failed to create venv in $CaseRoot"
    }

    $venvScripts = Join-Path $venvDir 'Scripts'
    return @{
        Uv = $uv
        Python = Join-Path $venvScripts 'python.exe'
        VenvDir = $venvDir
        Env = @{
            PATH = "$venvScripts;$env:PATH"
            VIRTUAL_ENV = $venvDir
        }
    }
}
function Invoke-ReproCase {
    param(
        [string]$Label,
        [string]$ProjectRoot,
        [string]$GraalPyExePath,
        [ValidateSet('uv', 'build-uv')]
        [string]$CaseFrontend,
        [string]$CaseRoot,
        [string]$UvCacheDir
    )

    $setup = New-CaseEnvironment -GraalPyExePath $GraalPyExePath -CaseRoot $CaseRoot
    $logPath = Join-Path $CaseRoot 'commands.log'
    $envMap = @{
        PATH = $setup.Env.PATH
        VIRTUAL_ENV = $setup.Env.VIRTUAL_ENV
    }
    if ($UvCacheDir) {
        New-Item -ItemType Directory -Force -Path $UvCacheDir | Out-Null
        $envMap['UV_CACHE_DIR'] = $UvCacheDir
    }

    Invoke-LoggedCommand -Label 'uv --version' -Command @($setup.Uv, '--version') -WorkingDirectory $CaseRoot -LogPath $logPath -Environment $envMap | Out-Null
    Invoke-LoggedCommand -Label 'python --version' -Command @($setup.Python, '--version') -WorkingDirectory $CaseRoot -LogPath $logPath -Environment $envMap | Out-Null
    Invoke-LoggedCommand -Label 'python identity' -Command @($setup.Python, '-c', 'import sys; print(sys.executable); print(sys.prefix)') -WorkingDirectory $CaseRoot -LogPath $logPath -Environment $envMap | Out-Null

    if ($CaseFrontend -eq 'build-uv') {
        $installExit = Invoke-LoggedCommand -Label 'Install build[virtualenv]' -Command @($setup.Uv, 'pip', 'install', '--upgrade', 'build[virtualenv]') -WorkingDirectory $CaseRoot -LogPath $logPath -Environment $envMap
        if ($installExit -ne 0) {
            return [pscustomobject]@{ Label = $Label; Frontend = $CaseFrontend; ExitCode = $installExit; CaseRoot = $CaseRoot; LogPath = $logPath }
        }
        $buildCmd = @($setup.Python, '-m', 'build', $ProjectRoot, '--wheel', '--outdir', (Join-Path $CaseRoot 'dist'), '--installer=uv')
    }
    else {
        $buildCmd = @($setup.Uv, 'build', '--python=python', $ProjectRoot, '--wheel', '--out-dir', (Join-Path $CaseRoot 'dist'))
    }

    $buildExit = Invoke-LoggedCommand -Label "Build via $CaseFrontend" -Command $buildCmd -WorkingDirectory $CaseRoot -LogPath $logPath -Environment $envMap

    if ($buildExit -ne 0 -and $UvCacheDir -and (Test-Path $UvCacheDir)) {
        "`n>>> UV cache tree ($UvCacheDir)`n" | Tee-Object -FilePath $logPath -Append | Out-Host
        Get-ChildItem -Path $UvCacheDir -Recurse -Force | Select-Object FullName, Length | Format-Table -AutoSize | Out-String | Tee-Object -FilePath $LogPath -Append | Out-Host
    }

    return [pscustomobject]@{
        Label = $Label
        Frontend = $CaseFrontend
        ExitCode = $buildExit
        CaseRoot = $CaseRoot
        LogPath = $logPath
    }
}

$root = [System.IO.Path]::GetFullPath($WorkRoot)
New-Item -ItemType Directory -Force -Path $root | Out-Null

$graalpy = Get-GraalPyExePath
Write-Section 'Using GraalPy artifact'
Write-Host $graalpy

$projectRoot = Join-Path $root ("project-" + $ProjectType)
New-LegacyProject -ProjectRoot $projectRoot -Kind $ProjectType

$frontends = switch ($Frontend) {
    'compare' { @('build-uv', 'uv') }
    'build-uv' { @('build-uv') }
    'uv' { @('uv') }
}

$results = @()
foreach ($caseFrontend in $frontends) {
    $caseRoot = Join-Path $root ("case-" + $caseFrontend)
    $uvCacheDir = Join-Path $caseRoot 'uv-cache'
    Write-Section "Running $caseFrontend on $ProjectType project"
    $results += Invoke-ReproCase -Label "$ProjectType/$caseFrontend" -ProjectRoot $projectRoot -GraalPyExePath $graalpy -CaseFrontend $caseFrontend -CaseRoot $caseRoot -UvCacheDir $uvCacheDir
}

Write-Section 'Summary'
$results | Format-Table Label, Frontend, ExitCode, CaseRoot, LogPath -AutoSize

$uvFailed = $results | Where-Object { $_.Frontend -eq 'uv' -and $_.ExitCode -ne 0 }
$buildUvPassed = $results | Where-Object { $_.Frontend -eq 'build-uv' -and $_.ExitCode -eq 0 }

if ($uvFailed -and $buildUvPassed) {
    Write-Host 'Observed the expected split: uv failed while build[uv] equivalent passed.'
    exit 0
}

if ($uvFailed) {
    Write-Host 'uv failed.'
    exit 1
}

Write-Host 'uv did not fail.'
Write-Host "Work directory retained at $root for inspection."
exit 0





