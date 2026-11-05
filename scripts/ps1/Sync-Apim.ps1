[CmdletBinding()]
param(
    [switch]$DryRun,
    [ValidateSet('Sync', 'Export', 'Drift')][string]$Action = 'Sync',
    [string]$ConfigPath,
    [string]$Revision,
    [string]$PlanPath,
    [string]$ReportPath,
    [string]$OutputPath,
    [string]$DeletionManifest,
    [switch]$AllowDelete
)
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'ApiOps.ps1')
$values = if ($ConfigPath) {
    Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
} else {
    Get-ProjectEnvironment
}
Invoke-ApimSync -Values $values -Action $Action -DryRun:$DryRun -Revision $Revision `
    -PlanPath $PlanPath -ReportPath $ReportPath -OutputPath $OutputPath `
    -DeletionManifest $DeletionManifest -AllowDelete:$AllowDelete
