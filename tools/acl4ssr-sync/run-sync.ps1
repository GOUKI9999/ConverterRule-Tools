param([switch]$Apply)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
if (-not $PSScriptRoot.StartsWith('D:\Temp\CodeTemp\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Copy this launcher and sync.py to the CodeTemp runtime directory first.'
}
$syncPython = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\python.exe'
if (-not (Test-Path -LiteralPath $syncPython)) { throw "Python unavailable: $syncPython" }
$syncArguments = @('-B', (Join-Path $PSScriptRoot 'sync.py'))
if ($Apply) { $syncArguments += '--apply' }
& $syncPython @syncArguments
exit $LASTEXITCODE
