Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:ProjectSubscriptionId = $null

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $result = & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new("$Command failed with exit code $LASTEXITCODE.")
    }
    return $result
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $allArguments = @($Arguments) + @('--only-show-errors', '--output', 'json')
    if ($script:ProjectSubscriptionId -and $Arguments[0] -ne 'ad') {
        $allArguments += @('--subscription', $script:ProjectSubscriptionId)
    }
    $json = Invoke-CheckedCommand -Command az -Arguments $allArguments
    if ($json) {
        return ($json -join "`n" | ConvertFrom-Json -AsHashtable)
    }
}

function Get-ProjectEnvironment {
    $json = Invoke-CheckedCommand -Command azd -Arguments @('env', 'get-values', '--output', 'json')
    $values = $json -join "`n" | ConvertFrom-Json -AsHashtable
    if ($values -isnot [System.Collections.IDictionary]) {
        throw 'azd did not return an environment object. Initialize an environment first.'
    }
    return $values
}

function Get-RequiredValue {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $Values.Contains($Name) -or [string]::IsNullOrWhiteSpace([string]$Values[$Name])) {
        throw "Missing $Name. Configure it using: azd env set $Name <value>"
    }
    return [string]$Values[$Name]
}

function Set-ProjectValue {
    param([string]$Name, [string]$Value)
    Invoke-CheckedCommand -Command azd -Arguments @('env', 'set', $Name, $Value) | Out-Null
}

function Assert-Guid {
    param([string]$Value, [string]$Name)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact($Value, 'D', [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$Name must be a non-empty GUID, not an email address."
    }
}

function Assert-FrontDoorPrivateOrigin {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Origin,
        [Parameter(Mandatory)][string]$ApimId,
        [Parameter(Mandatory)][string]$Marker
    )
    $shared = $Origin.properties.sharedPrivateLinkResource
    if ($shared.privateLink.id -ine $ApimId -or
        $shared.groupId -cne 'Gateway' -or
        $shared.requestMessage -cne $Marker) {
        throw 'Front Door origin does not match the expected private APIM connection.'
    }
}

function Assert-ApimPublicAccessBlocked {
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$ApimName
    )
    if ($StatusCode -in @(403, 404) -and (Test-Json -Json $Content -ErrorAction SilentlyContinue)) {
        $body = $Content | ConvertFrom-Json -AsHashtable
        if ($body -is [System.Collections.IDictionary] -and
            $body.Contains('statusCode') -and $body.statusCode -eq 403 -and
            $body.Contains('message') -and
            $body.message -like '*public network access*disabled*' -and
            $body.message.Contains($ApimName)) {
            return
        }
    }
    throw "Public APIM access was not confirmed blocked for $ApimName (HTTP $StatusCode)."
}

function Get-RegionalSettings {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    foreach ($entry in @(
        @{ Key = 'br'; Alias = 'region1'; Prefix = 'BRAZIL' },
        @{ Key = 'us'; Alias = 'region2'; Prefix = 'US' }
    )) {
        $prefix = $entry.Prefix
        [pscustomobject]@{
            Key = $entry.Key
            Alias = $entry.Alias
            ResourceGroup = Get-RequiredValue $Values "${prefix}_RESOURCE_GROUP"
            ApimName = Get-RequiredValue $Values "${prefix}_APIM_NAME"
            ApimId = Get-RequiredValue $Values "${prefix}_APIM_ID"
            AksName = Get-RequiredValue $Values "${prefix}_AKS_NAME"
            BackendIp = Get-RequiredValue $Values "${prefix}_BACKEND_IP"
            ApimSubnet = Get-RequiredValue $Values "${prefix}_APIM_SUBNET"
            Location = Get-RequiredValue $Values "$($prefix)_LOCATION"
        }
    }
}

function New-DemoManifest {
    param(
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][string]$BackendIp,
        [Parameter(Mandatory)][string]$ApimSubnet,
        [string]$Image
    )
    $parsedIp = $null
    if ($Region -notmatch '^[a-z0-9]+$') {
        throw 'Invalid region name.'
    }
    if (-not [System.Net.IPAddress]::TryParse($BackendIp, [ref]$parsedIp) -or
        $parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $parsedIp.ToString() -cne $BackendIp) {
        throw 'The demo backend must use an IPv4 address.'
    }
    $cidr = $ApimSubnet.Split('/')
    $subnetIp = $null
    $prefix = 0
    if ($cidr.Count -ne 2 -or $cidr[0] -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        -not [System.Net.IPAddress]::TryParse($cidr[0], [ref]$subnetIp) -or
        $subnetIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $subnetIp.ToString() -cne $cidr[0] -or
        -not [int]::TryParse($cidr[1], [ref]$prefix) -or $prefix -lt 20 -or $prefix -gt 32) {
        throw 'Invalid APIM subnet CIDR: expected an IPv4 network with prefix 20-32.'
    }
    $bits = ($subnetIp.GetAddressBytes() | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
    if ($bits.Substring($prefix).Contains('1')) {
        throw 'Invalid APIM subnet CIDR: host bits must be zero.'
    }
    if ($Image -and $Image -cnotmatch '^[a-z0-9][a-z0-9./:_-]*@sha256:[a-f0-9]{64}$') {
        throw 'DEMO_IMAGE must be a registry image pinned by sha256 digest.'
    }
    $source = Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'src\demo\server.py')
    $indented = ($source | ForEach-Object { "    $_" }) -join "`n"
    $template = Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'k8s\demo.yaml') -Raw
    $config = "apiVersion: v1`nkind: ConfigMap`nmetadata:`n  name: regional-demo`n  namespace: private-poc`ndata:`n  server.py: |`n$indented`n---"
    $command = '          command: ["python", "/app/server.py"]'
    $mount = "          volumeMounts:`n            - name: source`n              mountPath: /app`n              readOnly: true"
    $volume = "      volumes:`n        - name: source`n          configMap:`n            name: regional-demo"
    if ($Image) {
        $config = ''
        $command = ''
        $mount = ''
        $volume = ''
    } else {
        $Image = 'docker.io/library/python:3.13-alpine'
    }
    return $template.Replace('__SOURCE_CONFIG_MAP__', $config).
        Replace('__CONTAINER_COMMAND__', $command).
        Replace('__SOURCE_MOUNT__', $mount).
        Replace('__SOURCE_VOLUME__', $volume).
        Replace('__DEMO_IMAGE__', $Image).
        Replace('__REGION__', $Region).
        Replace('__BACKEND_IP__', $BackendIp).
        Replace('__APIM_SUBNET__', $ApimSubnet)
}

function Resolve-RegionKey {
    param([Parameter(Mandatory)][ValidateSet('br', 'us', 'region1', 'region2')][string]$Region)
    if ($Region -eq 'region1') { return 'br' }
    if ($Region -eq 'region2') { return 'us' }
    return $Region
}

function Assert-OperationsSettings {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    if ($Values.DEPLOYMENT_PROFILE -notin @('poc', 'production') -or
        $Values.MONITORING_MODE -notin @('Enabled', 'Disabled') -or
        $Values.ALERTS_MODE -notin @('Enabled', 'Disabled')) {
        throw 'Invalid deployment profile or monitoring/alerts mode.'
    }
    if ($Values.ALERTS_MODE -eq 'Enabled' -and
        ($Values.MONITORING_MODE -ne 'Enabled' -or
        $Values.ALERT_ACTION_GROUP_ID -notmatch '^/subscriptions/[a-fA-F0-9-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Insights/actionGroups/[^/]+$')) {
        throw 'Alerts require monitoring and an existing Azure Monitor action group resource ID.'
    }
    if ($Values.DEPLOYMENT_PROFILE -eq 'production') {
        foreach ($name in @('REGION1_ZONES', 'REGION2_ZONES')) {
            $zones = ([string]$Values[$name]).Split(',')
            if ($zones.Count -lt 2 -or $zones.Count -gt 3 -or
                @($zones | Select-Object -Unique).Count -ne $zones.Count -or
                @($zones | Where-Object { $_ -notmatch '^[1-3]$' }).Count -gt 0) {
                throw 'Production requires at least two distinct, regionally supported availability zones per cluster.'
            }
        }
        if (-not $Values.Contains('DEMO_IMAGE') -or [string]$Values.DEMO_IMAGE -cnotmatch '^[a-z0-9][a-z0-9./:_-]*@sha256:[a-f0-9]{64}$') {
            throw 'Production requires DEMO_IMAGE pinned by sha256 digest.'
        }
        if ($Values.MONITORING_MODE -ne 'Enabled' -or $Values.ALERTS_MODE -ne 'Enabled') {
            throw 'Production requires monitoring and routed alerts.'
        }
    }
}

function Invoke-AksChecked {
    param(
        [string]$ResourceGroup,
        [string]$ClusterName,
        [string]$Command,
        [string]$File
    )
    $arguments = @('aks', 'command', 'invoke', '--resource-group', $ResourceGroup, '--name', $ClusterName, '--command', $Command)
    if ($File) {
        $arguments += @('--file', $File)
    }
    $result = Invoke-AzJson -Arguments $arguments
    if (-not $result -or -not $result.ContainsKey('exitCode') -or $result.exitCode -ne 0) {
        $details = if ($result -and $result.ContainsKey('logs')) { $result.logs } else { 'No command result returned.' }
        throw "AKS Run Command failed on ${ClusterName}: $details"
    }
    if ($result.ContainsKey('logs')) {
        Write-Host $result.logs
    }
}
