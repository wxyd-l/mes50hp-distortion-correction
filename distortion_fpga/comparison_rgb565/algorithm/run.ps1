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
$taskRuntime = Join-Path (Split-Path -Parent $PSScriptRoot) '.runtime'
$taskPreviousPythonPath = $env:PYTHONPATH
Push-Location -LiteralPath $PSScriptRoot
try {
    if (Test-Path -LiteralPath $taskRuntime) {
        $env:PYTHONPATH = $taskRuntime + [IO.Path]::PathSeparator + $taskPreviousPythonPath
    }
    if (-not $TaskArguments -or $TaskArguments[0] -eq 'demo') {
        & $taskPython pipeline.py demo --camera examples/camera_demo.json --out out/complete_demo
    } elseif ($TaskArguments[0] -eq 'test') {
        & $taskPython -m unittest discover -s tests -v
    } else {
        # Pass e.g. pipeline.py / calibrate.py / quality.py and its arguments.
        & $taskPython @TaskArguments
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Algorithm command failed with exit code $LASTEXITCODE"
    }
} finally {
    $env:PYTHONPATH = $taskPreviousPythonPath
    Pop-Location
}
