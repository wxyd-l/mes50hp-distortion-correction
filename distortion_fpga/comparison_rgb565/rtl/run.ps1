param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $TaskArguments
)
$ErrorActionPreference = 'Stop'
$taskBundledPython = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
if (Test-Path -LiteralPath $taskBundledPython) {
    $taskPython = $taskBundledPython
} else {
    $taskPython = (Get-Command python -ErrorAction Stop).Source
}
Push-Location -LiteralPath $PSScriptRoot
try {
    if ($TaskArguments -and $TaskArguments[0] -eq 'full') {
        & $taskPython -m unittest discover -s tests -v
        if ($LASTEXITCODE -ne 0) { throw 'Integer oracle/package tests failed' }
        & $taskPython tools/run_sim.py
        if ($LASTEXITCODE -ne 0) { throw 'RTL regressions failed' }
        & $taskPython tools/run_cache_sim.py
        if ($LASTEXITCODE -ne 0) { throw 'Cache regressions failed' }
        & (Join-Path (Split-Path -Parent $PSScriptRoot) 'algorithm/run.ps1') demo
        & $taskPython tools/prepare_package.py --lut ../algorithm/out/complete_demo/rotate_keep --input ../algorithm/out/complete_demo/input_synthetic.png --out out/demo720p
        if ($LASTEXITCODE -ne 0) { throw '720P package generation failed' }
        & $taskPython tools/run_package_sim.py --package out/demo720p
        if ($LASTEXITCODE -ne 0) { throw 'Serial mapper full frame failed' }
        & $taskPython tools/run_package_sim.py --package out/demo720p --fast-map
    } elseif (-not $TaskArguments -or $TaskArguments[0] -eq 'test') {
        & $taskPython -m unittest discover -s tests -v
        if ($LASTEXITCODE -ne 0) { throw 'Integer oracle/package tests failed' }
        & $taskPython tools/run_sim.py
        if ($LASTEXITCODE -ne 0) { throw 'RTL regressions failed' }
        & $taskPython tools/run_cache_sim.py
    } elseif ($TaskArguments[0] -eq 'sim') {
        & $taskPython tools/run_sim.py
    } else {
        & $taskPython @TaskArguments
    }
    if ($LASTEXITCODE -ne 0) { throw "RTL command failed with exit code $LASTEXITCODE" }
    if (-not $TaskArguments -or $TaskArguments[0] -in @('test', 'full')) {
        & $taskPython tools/formula_regression.py
        if ($LASTEXITCODE -ne 0) { throw 'Formula comparison regressions failed' }
    }
} finally {
    Pop-Location
}
