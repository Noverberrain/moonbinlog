# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0

# Install into a new directory; never replace the developer's existing .moon.
param(
    [Parameter(Mandatory)][string]$InstallDir,
    [string]$DownloadDir = (Join-Path ([IO.Path]::GetTempPath()) 'moonbinlog-ci-downloads')
)

$ErrorActionPreference = 'Stop'
$ciVersion = '0.10.15+943464bfa'
$ciEncodedVersion = [Uri]::EscapeDataString($ciVersion)
if (Test-Path -LiteralPath $InstallDir) {
    throw "Install directory must not exist: $InstallDir"
}
New-Item -ItemType Directory -Path $InstallDir, $DownloadDir -Force | Out-Null

$ciArchives = @(
    @{
        File = 'moonbit.zip'
        Url = "https://cli.moonbitlang.com/binaries/$ciEncodedVersion/moonbit-windows-x86_64.zip"
        Hash = '6e3ef6cb96aa5086d122183972687f79fc912f80652000907d96ee6ad967e3bf'
        Destination = $InstallDir
    },
    @{
        File = 'core.zip'
        Url = "https://cli.moonbitlang.com/cores/core-$ciEncodedVersion.zip"
        Hash = '05556b27b156348950ea88ae6838032c8b478ae532b18b3929387d1da4c18d55'
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
if ($env:GITHUB_PATH) {
    $ciBinDir | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
}
moon version --all
if ($LASTEXITCODE -ne 0) { throw 'MoonBit version check failed' }
moon -C (Join-Path $InstallDir 'lib/core') bundle --warn-list -a --all
if ($LASTEXITCODE -ne 0) { throw 'MoonBit core bundle failed' }
moon -C (Join-Path $InstallDir 'lib/core') bundle --warn-list -a --target wasm-gc --quiet
if ($LASTEXITCODE -ne 0) { throw 'MoonBit core wasm-gc bundle failed' }
