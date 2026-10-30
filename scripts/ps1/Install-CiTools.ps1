[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not $env:RUNNER_TEMP) { throw 'This installer is only for disposable Windows CI runners.' }
$versions = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\toolchain.json') -Raw | ConvertFrom-Json
$tools = Join-Path $env:RUNNER_TEMP 'poc-tools'
$null = New-Item -ItemType Directory -Path $tools -Force
Invoke-WebRequest -Uri "https://github.com/Azure/bicep/releases/download/v$($versions.bicep)/bicep-win-x64.exe" `
    -OutFile (Join-Path $tools 'bicep.exe')
$archive = Join-Path $tools 'pwsh.zip'
Invoke-WebRequest -Uri "https://github.com/PowerShell/PowerShell/releases/download/v$($versions.powershell)/PowerShell-$($versions.powershell)-win-x64.zip" -OutFile $archive
Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $tools 'pwsh') -Force
Remove-Item -LiteralPath $archive
$linterArchive = Join-Path $tools 'actionlint.zip'
Invoke-WebRequest -Uri "https://github.com/rhysd/actionlint/releases/download/v$($versions.actionlint)/actionlint_$($versions.actionlint)_windows_amd64.zip" -OutFile $linterArchive
Expand-Archive -LiteralPath $linterArchive -DestinationPath (Join-Path $tools 'actionlint') -Force
Remove-Item -LiteralPath $linterArchive
if (-not $env:GITHUB_PATH) { throw 'GITHUB_PATH is required.' }
$tools, (Join-Path $tools 'pwsh'), (Join-Path $tools 'actionlint') | Out-File -LiteralPath $env:GITHUB_PATH -Append -Encoding utf8
