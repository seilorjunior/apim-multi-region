[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateSet('br', 'us', 'region1', 'region2')][string]$Region,
    [switch]$AllowDisruption,
    [string]$OutputPath = (Join-Path $PSScriptRoot "..\..\TestResults\failover-$([guid]::NewGuid().ToString('N')).json"),
    [ValidateRange(1, 1800)][int]$TimeoutSeconds = 300,
    [ValidateRange(1, 30)][int]$IntervalSeconds = 3,
    [ValidateRange(1, 100)][int]$ConsecutiveSuccesses = 5
)
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Failover.ps1')
if (-not $AllowDisruption) { throw 'This exercise interrupts a backend. Explicit -AllowDisruption is required.' }
if ($PSCmdlet.ShouldProcess($Region, 'Scale backend to zero, measure failover, then restore original replicas')) {
    Invoke-MeasuredFailover -Values (Get-ProjectEnvironment) -Region $Region -OutputPath $OutputPath `
        -TimeoutSeconds $TimeoutSeconds -IntervalSeconds $IntervalSeconds -ConsecutiveSuccesses $ConsecutiveSuccesses
}
