[CmdletBinding()]
param([switch]$DryRun)
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'ApiOps.ps1')
Invoke-ApimSync -Values (Get-ProjectEnvironment) -DryRun:$DryRun
