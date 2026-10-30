[CmdletBinding()]
param([switch]$RequirePinnedTools)
. (Join-Path $PSScriptRoot 'Common.ps1')
Push-Location $script:ProjectRoot
try {
    if ($RequirePinnedTools) {
        $versions = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\toolchain.json') -Raw | ConvertFrom-Json
        $pythonVersion = (Invoke-CheckedCommand python @('--version')) -replace '^Python ', ''
        $bicepVersion = Invoke-CheckedCommand bicep @('--version')
        if ($PSVersionTable.PSVersion.ToString() -ne $versions.powershell -or
            $pythonVersion -ne $versions.python -or $bicepVersion -notlike "Bicep CLI version $($versions.bicep) *") {
            throw 'Tool versions do not match scripts\toolchain.json.'
        }
        Invoke-CheckedCommand actionlint @('-shellcheck=', '-pyflakes=',
            '.\.github\workflows\validate.yml', '.\.github\workflows\release-image.yml', '.\.github\workflows\deploy.yml')
    }
    Invoke-CheckedCommand python @('-B', '-m', 'unittest', 'discover', '-s', '.\tests', '-p', 'test_*.py', '-v')
    foreach ($test in @('Test-Scripts.ps1', 'Test-Bootstrap.ps1', 'Test-ApiSample.ps1', 'Test-Failover.ps1', 'Test-Infrastructure.ps1')) {
        Invoke-CheckedCommand pwsh @('-NoProfile', '-File', (Join-Path $script:ProjectRoot "tests\$test"))
    }
    Write-Host 'All local validation suites passed. No Azure resource was changed.'
} finally {
    Pop-Location
}
