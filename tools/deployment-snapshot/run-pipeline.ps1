param([switch]$Apply)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
if (-not $PSScriptRoot.StartsWith('D:\Temp\CodeTemp\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Run the copied launcher from its CodeTemp runtime directory.'
}
$pipelineConfig = Get-Content (Join-Path $PSScriptRoot 'pipeline.json') -Raw | ConvertFrom-Json
$pipelinePython = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\python.exe'
$ruleArgs = @('-B', (Join-Path $pipelineConfig.acl_runtime 'sync.py'))
if ($Apply) { $ruleArgs += '--apply' }
& $pipelinePython @ruleArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$snapshotArgs = @('-B', (Join-Path $PSScriptRoot 'snapshot.py'))
if ($Apply) { $snapshotArgs += @('--apply', '--commit', '--push') }
& $pipelinePython @snapshotArgs
exit $LASTEXITCODE
