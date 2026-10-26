# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0

$ErrorActionPreference = 'Stop'

function Invoke-CiCommand {
    param([string]$Program, [string[]]$ArgumentList)
    Write-Host "> $Program $($ArgumentList -join ' ')"
    & $Program @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "CI command failed (exit ${LASTEXITCODE}): $Program $($ArgumentList -join ' ')"
    }
}

Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    Invoke-CiCommand -Program moon -ArgumentList @('version', '--all')
    Invoke-CiCommand -Program python -ArgumentList @('--version')
    Invoke-CiCommand -Program moon -ArgumentList @('fmt', '--check')
    Invoke-CiCommand -Program moon -ArgumentList @('check', '--target', 'native', '--warn-list', '+unnecessary_annotation', '--deny-warn')
    Invoke-CiCommand -Program moon -ArgumentList @('test', '--target', 'native')
    Invoke-CiCommand -Program moon -ArgumentList @('build', '--target', 'native')
    Invoke-CiCommand -Program moon -ArgumentList @('info')
    Invoke-CiCommand -Program git -ArgumentList @('diff', '--exit-code', 'HEAD', '--', '*.mbti')
    $ciUntrackedInterfaces = git ls-files --others --exclude-standard -- '*.mbti'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect generated interfaces' }
    if ($ciUntrackedInterfaces) {
        throw "Untracked generated interfaces: $($ciUntrackedInterfaces -join ', ')"
    }
    foreach ($ciGenerator in Get-ChildItem scripts/generate_*_fixtures.py | Sort-Object Name) {
        Invoke-CiCommand -Program python -ArgumentList @($ciGenerator.FullName, '--check')
    }
    foreach ($ciScript in @(
        'scripts/verify_mysql_fixtures.py',
        'scripts/verify_json_fixtures.py',
        'scripts/generate_schema_example.py'
    )) {
        Invoke-CiCommand -Program python -ArgumentList @($ciScript, '--check')
    }
    foreach ($ciScript in @(
        'scripts/test_cli.py',
        'scripts/test_rows_cli.py',
        'scripts/test_transactions_cli.py',
        'scripts/test_filters_cli.py',
        'scripts/test_json_cli.py'
    )) {
        Invoke-CiCommand -Program python -ArgumentList @($ciScript)
    }
    Invoke-CiCommand -Program git -ArgumentList @('diff', '--check')
} finally {
    Pop-Location
}
