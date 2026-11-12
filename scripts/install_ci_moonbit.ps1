# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0

# Install into a new directory; never replace the developer's existing .moon.
param(
    [Parameter(Mandatory)][string]$InstallDir,
    [string]$DownloadDir
)

$ErrorActionPreference = 'Stop'
$ciVersion = '0.10.20+65efd5b93'
if ([string]::IsNullOrWhiteSpace($DownloadDir)) {
    $DownloadDir = Join-Path ([IO.Path]::GetTempPath()) "moonbinlog-ci-downloads-$ciVersion"
}
$ciEncodedVersion = [Uri]::EscapeDataString($ciVersion)
if (Test-Path -LiteralPath $InstallDir) {
    throw "Install directory must not exist: $InstallDir"
}
New-Item -ItemType Directory -Path $InstallDir, $DownloadDir -Force | Out-Null

$ciArchives = @(
    @{
        File = 'moonbit.zip'
        Url = "https://cli.moonbitlang.com/binaries/$ciEncodedVersion/moonbit-windows-x86_64.zip"
        Hash = 'bdff9a3b2d7c61a3adae2fe09221d3de63effc6cab28bfa0cbeb94fb0d529d79'
        Destination = $InstallDir
    },
    @{
        File = 'core.zip'
        Url = "https://cli.moonbitlang.com/cores/core-$ciEncodedVersion.zip"
        Hash = 'd7982eed233e0c4f933f566274cc9777466447e0d5b633006e8bf18975c7c833'
        Destination = (Join-Path $InstallDir 'lib')
    }
)
foreach ($ciArchive in $ciArchives) {
    $ciArchivePath = Join-Path $DownloadDir $ciArchive.File
    if (!(Test-Path -LiteralPath $ciArchivePath)) {
        Invoke-WebRequest -Uri $ciArchive.Url -OutFile $ciArchivePath
    }
    if ((Get-FileHash -LiteralPath $ciArchivePath -Algorithm SHA256).Hash -ne $ciArchive.Hash) {
        throw "SHA-256 mismatch: $ciArchivePath"
    }
    Expand-Archive -LiteralPath $ciArchivePath -DestinationPath $ciArchive.Destination
}

$ciBinDir = Join-Path $InstallDir 'bin'
$env:PATH = "$ciBinDir;$env:PATH"
$env:MOON_HOME = [IO.Path]::GetFullPath($InstallDir)
if ($env:GITHUB_ENV) {
    "MOON_HOME=$env:MOON_HOME" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}
if ($env:GITHUB_PATH) {
    $ciBinDir | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
}
moon version --all
if ($LASTEXITCODE -ne 0) { throw 'MoonBit version check failed' }
moon -C (Join-Path $InstallDir 'lib/core') bundle --warn-list -a --all
if ($LASTEXITCODE -ne 0) { throw 'MoonBit core bundle failed' }
moon -C (Join-Path $InstallDir 'lib/core') bundle --warn-list -a --target wasm-gc --quiet
if ($LASTEXITCODE -ne 0) { throw 'MoonBit core wasm-gc bundle failed' }
