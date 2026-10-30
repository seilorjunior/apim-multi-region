. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Bootstrap.ps1')
Invoke-PrivateBootstrap -Values (Get-ProjectEnvironment)
