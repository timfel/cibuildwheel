param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactUrl,

    [string]$ArtifactRepo = 'timfel/graalpython',

    [string]$DestinationRoot = (Join-Path $PWD 'graalpython-artifact')
)

$ErrorActionPreference = 'Stop'

if ($ArtifactUrl -notmatch '/artifacts/(\d+)') {
    throw "Could not extract artifact id from URL: $ArtifactUrl"
}

$artifactId = $Matches[1]
$ghCommand = Get-Command gh -ErrorAction SilentlyContinue
if ($ghCommand) {
    $gh = $ghCommand.Source
}
else {
    $gh = 'C:\Program Files\GitHub CLI\gh.exe'
    if (-not (Test-Path $gh)) {
        throw 'gh is not installed or not on PATH'
    }
}
$destination = [System.IO.Path]::GetFullPath($DestinationRoot)
$zipPath = Join-Path $destination 'artifact.zip'
$extractRoot = Join-Path $destination 'extract'
$downloadUrl = "https://api.github.com/repos/$ArtifactRepo/actions/artifacts/$artifactId/zip"

New-Item -ItemType Directory -Force -Path $destination | Out-Null
New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null

$token = & $gh auth token
if ($LASTEXITCODE -ne 0 -or -not $token) {
    throw 'Could not retrieve GitHub auth token via gh auth token'
}
$token = $token.Trim()

Invoke-WebRequest -Headers @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json' } -Uri $downloadUrl -OutFile $zipPath

Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force

$artifactTar = Get-ChildItem -Path $extractRoot -Recurse -File -Filter *.tar | Select-Object -First 1
if (-not $artifactTar) {
    throw 'Expected a .tar file inside the downloaded GraalPy artifact.'
}

tar -xf $artifactTar.FullName -C $extractRoot
if ($LASTEXITCODE -ne 0) {
    throw "tar failed extracting $($artifactTar.FullName)"
}

$graalpyHome = Get-ChildItem -Path $extractRoot -Recurse -Directory |
    Where-Object { $_.Name -eq 'GRAALPY_NATIVE_STANDALONE' } |
    Select-Object -First 1
if (-not $graalpyHome) {
    throw 'Could not locate GRAALPY_NATIVE_STANDALONE in the downloaded artifact.'
}

$graalpyExe = Join-Path $graalpyHome.FullName 'bin\graalpy.exe'
if (-not (Test-Path $graalpyExe)) {
    throw "Could not locate graalpy.exe at $graalpyExe"
}

Write-Output $graalpyExe
