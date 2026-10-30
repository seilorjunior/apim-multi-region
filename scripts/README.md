# Script reference

Operational entry points are available in [PowerShell](./ps1/) and
[native Bash](./bash/). Bash scripts use Azure CLI/azd directly; they do not call
PowerShell. Both implementations retain the existing resource names, environment
keys, privacy checks, and explicit failover consent.

Run examples from the **repository root**, using the selected azd environment.
Start with `azd env select <environment-name>` and verify selection before any
live operation. Authentication/configuration inside WSL may differ from Windows.
Do not run both shell versions of a mutating operation concurrently.

## Layout and complete inventory

```text
scripts/
  README.md
  toolchain.json
  ps1/                    PowerShell entry points and libraries
  bash/                   Native Bash entry points and libraries
```

| PowerShell | Bash | Purpose and effects |
|---|---|---|
| [Initialize-Environment.ps1](./ps1/Initialize-Environment.ps1) | [initialize-environment.sh](./bash/initialize-environment.sh) | Query subscription tenant; create/select and populate a **local** azd environment. No provisioning. |
| [Pre-Provision.ps1](./ps1/Pre-Provision.ps1) | [pre-provision.sh](./bash/pre-provision.sh) | Preflight: read Azure configuration, set local defaults, preserve disabled APIM access. No resource creation. |
| [Post-Provision.ps1](./ps1/Post-Provision.ps1) | [post-provision.sh](./bash/post-provision.sh) | **Mutates Azure:** private bootstrap, workloads, and API publication. |
| [Test-EndToEnd.ps1](./ps1/Test-EndToEnd.ps1) | [test-end-to-end.sh](./bash/test-end-to-end.sh) | Read live Azure configuration and send direct/Front Door HTTP requests. No resource mutation. |
| [Set-DemoAvailability.ps1](./ps1/Set-DemoAvailability.ps1) | [set-demo-availability.sh](./bash/set-demo-availability.sh) | **Mutates live replicas** to 0 or 2. No automatic restoration. |
| [Test-Failover.ps1](./ps1/Test-Failover.ps1) | [test-failover.sh](./bash/test-failover.sh) | **Disrupts one backend**, measures responses, attempts restoration, writes JSON evidence. |
| [Invoke-Validation.ps1](./ps1/Invoke-Validation.ps1) | [invoke-validation.sh](./bash/invoke-validation.sh) | Local tests/compilation; no Azure access. |
| [Install-CiTools.ps1](./ps1/Install-CiTools.ps1) | [install-ci-tools.sh](./bash/install-ci-tools.sh) | Download tools on disposable CI runners; no Azure access. Not a workstation installer. |
| [Common.ps1](./ps1/Common.ps1) | [common.sh](./bash/common.sh) | Shared environment, validation, rendering, Azure/AKS, and HTTP helpers. **Library, not an entry point.** |
| [Bootstrap.ps1](./ps1/Bootstrap.ps1) | [bootstrap.sh](./bash/bootstrap.sh) | Private Link correlation/approval and privacy-gated publication. **Library, called by postprovision.** |
| [Failover.ps1](./ps1/Failover.ps1) | [failover.sh](./bash/failover.sh) | Measurement, report, and recovery logic. **Library, called by the guarded failover entry point.** |

Old root-level PowerShell paths have moved. Update external automation from
`scripts\<Name>.ps1` to `scripts\ps1\<Name>.ps1`; no legacy wrappers are retained.
[azure.yaml](../azure.yaml), repository tests, and workflows use the new paths.
Do not move [toolchain.json](./toolchain.json) into either shell directory.

## Dependencies and conventions

- **PowerShell:** PowerShell 7 (`pwsh`); Azure CLI (`az`), azd, and Bicep CLI
  for initialization/provisioning. Python and PyYAML for local tests.
- **Bash:** Bash 4+, `jq`, Python 3.10+ available as `python3`, `curl`, az, azd,
  and Bicep for the full operational workflow. Validation needs Bash/jq/Python/Bicep,
  not az/azd/pwsh. Scripts report missing required commands.
- Bash 3.2 shipped with macOS is unsupported. Linux/WSL is the native CI path;
  Git Bash requires usable native tools and compatible authentication.
- Bash files must retain **LF**, not CRLF. [editor settings](../.editorconfig) and
  [Git attributes](../.gitattributes) enforce this. Run with `bash`, not `sh`;
  executable-bit metadata is not required for the documented commands.
- Bash entry points support `--help` without Azure access. PowerShell parameter
  help is available through `Get-Help .\scripts\ps1\<Name>.ps1 -Full`.
- Azure operations are subscription-scoped without changing the global default.
  Tenant-scoped Graph group lookups do not take a subscription argument.
- azd values are read as JSON, never sourced/evaluated as executable shell code.
  The entire local `.azure` directory, including deployment plans and history,
  environment files, and [TestResults output](../.gitignore) must not be committed.
  Ignore rules do not protect files already tracked or remove Git history.
- Nonzero exit means failure. Preserve stderr together with any JSON evidence.
  A successful local test is not permission to deploy or disrupt resources.

## Initialize-Environment

Use once to create/select local configuration, or rerun to update its values.
The subscription tenant is checked through Azure CLI; resources are not provisioned
and the global CLI subscription is not changed.

| PowerShell parameter | Bash option | Required/default |
|---|---|---|
| `-SubscriptionId` | `--subscription-id` | Required nonzero GUID. |
| `-TenantId` | `--tenant-id` | Required nonzero GUID matching subscription. |
| `-PublisherEmail` | `--publisher-email` | Required publisher email. |
| `-EnvironmentName` | `--environment-name` | `poc-apim-private`; 3-24 lowercase letters/digits/hyphens, starting with a letter. |
| `-PublisherName` | `--publisher-name` | Legacy default `PoC multi-regiao`. |
| `-AksAdminGroupObjectId` | `--aks-admin-group-object-id` | Optional here; **required before provisioning**. Real Entra security group ID. |
| `-BrazilLocation` / `-Region1Location` | `--region1-location` | `brazilsouth`. |
| `-UsLocation` / `-Region2Location` | `--region2-location` | `eastus`. |

```powershell
.\scripts\ps1\Initialize-Environment.ps1 `
  -SubscriptionId "<subscription-guid>" -TenantId "<tenant-guid>" `
  -PublisherEmail "<email>" -AksAdminGroupObjectId "<group-guid>" `
  -Region1Location westus2 -Region2Location eastus
```

```bash
bash scripts/bash/initialize-environment.sh \
  --subscription-id "<subscription-guid>" --tenant-id "<tenant-guid>" \
  --publisher-email "<email>" --aks-admin-group-object-id "<group-guid>" \
  --region1-location westus2 --region2-location eastus
```

Writes `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `AZURE_LOCATION`,
`BRAZIL_LOCATION`, `US_LOCATION`, `APIM_PUBLISHER_NAME`, `APIM_PUBLISHER_EMAIL`,
and the admin group when supplied. Missing group input produces a warning; the
preprovision hook will refuse to continue without a valid security group.
Choosing a different location for existing resources is not a safe migration.

## Pre-Provision

Called automatically by `azd provision`/`azd up`. Takes no custom arguments.
Reads the selected environment, verifies subscription tenant/state, publisher
settings, distinct regions, a real Entra security group, and registered providers.
It does **not** register providers automatically.

It initializes missing profile/monitoring/alert/zone settings using cost-neutral
defaults. For each existing regional APIM, it preserves `Disabled` public access
in `APIM_PUBLIC_ACCESS_BR`/`APIM_PUBLIC_ACCESS_US`. Unknown/ambiguous state fails.
Production candidate settings require approved digest, monitoring, alerts/action
group, and distinct zones. Existing incompatible AKS tier/zones block automatic
conversion.

To run preflight alone, with Azure reads and local azd writes:

```powershell
.\scripts\ps1\Pre-Provision.ps1
```

```bash
bash scripts/bash/pre-provision.sh
```

Output is diagnostics; failure stops azd before resource provisioning.
See the [main settings table](../README.md#8-opt-in-observability-and-availability-profile)
for opt-ins. Preflight does not prove quota, SKU/zone availability, Azure Policy,
effective permissions, or that action-group notifications will arrive.

## Post-Provision

Called automatically after infrastructure provisioning. Takes no custom arguments.
**Changes live resources**; use only after approval. Requires infrastructure
outputs in the azd environment, including both regional resource sets and Front
Door identifiers. Do not fabricate these outputs.

Through the Bootstrap library it:

1. Matches Private Link requests to `azd:<environment>:<regional-key>:<profile>`.
2. Rejects unexpected approvals, rejected/disconnected requests, wrong origins,
   and ambiguous matches; logs the endpoint ID before approving.
3. Polls approval/configuration (up to 120 attempts, with 15-second polling).
4. Disables and verifies public access on **both** APIM gateways before publishing.
5. Renders the shared Kubernetes template and installs it using AKS Run Command.
6. Compiles/deploys the regional API template and prints the end-to-end command.

Temporary rendered manifests and ARM parameter files are cleaned up. Partial
publication fails explicitly rather than claiming success. Fix the underlying
error, keep connection markers intact, then resume the selected environment:

```text
azd hooks run postprovision
```

For an explicitly approved manual invocation, choose **one**:

```powershell
.\scripts\ps1\Post-Provision.ps1
```

```bash
bash scripts/bash/post-provision.sh
```

There is no need to run the hook manually after a successful azd provision.
Do not use the hook to bypass a failed privacy gate or apply the unrendered
[Kubernetes template](../k8s/demo.yaml) directly.

### Automatic OS selection

[azure.yaml](../azure.yaml) selects Windows `pwsh` hooks or POSIX native Bash hooks.
The POSIX hook launches `bash` explicitly, even though its azd launcher shell is
`sh`. Bash operations have no PowerShell dependency.

When using azd installed inside WSL, run all related authentication, environment
selection, and commands there. Windows azd uses Windows hooks. A manual Bash hook
on Windows/WSL is an explicit alternative, not a reason to provision a second time.
Do not assume Windows and Linux azd sessions point to the same subscription/environment.

## Test-EndToEnd

Checks the **deployed** environment; no provisioning or replica mutation.
It reads Azure configuration and performs real HTTP requests.

| PowerShell | Bash | Default/range |
|---|---|---|
| `-Samples` | `--samples` | 10; 1-100. |
| `-ExpectedRegion` | `--expected-region` | Optional actual location, e.g. `eastus`, not alias `region2`. |
| `-IntervalSeconds` | `--interval-seconds` | 3; 1-60 seconds between API samples. |

```powershell
.\scripts\ps1\Test-EndToEnd.ps1 -Samples 10 -ExpectedRegion eastus
```

```bash
bash scripts/bash/test-end-to-end.sh --samples 10 --expected-region eastus
```

Validates disabled APIM public access, private AKS API servers, disabled local
accounts, Front Door responses, region/body/header agreement, correlation GUID,
and final readiness. Public direct APIM requests include the correct FDID and
must produce HTTP 403 or 404 **with JSON `statusCode:403`, an explicit public-network
disabled message, and the expected APIM name**. Generic denials do not pass.

PowerShell prints a sample table; Bash emits JSON samples on stdout and diagnostics
on stderr. Both fail on the first invalid check. Seeing only one region in
active-active sampling is not itself a failure. After a controlled fault, wait
for probe convergence before expecting all responses from the survivor.

## Set-DemoAvailability

**Live mutation with no automatic rollback.** This simple manual helper has no
disruption consent switch or dry-run; running it is the requested action.

| PowerShell | Bash | Values |
|---|---|---|
| `-Region` | `--region` | Required: `br`, `us`, `region1`, or `region2`. |
| `-State` | `--state` | Required: `Unavailable` -> 0 replicas; `Available` -> 2 replicas. Case-sensitive in Bash. |

```powershell
.\scripts\ps1\Set-DemoAvailability.ps1 -Region region1 -State Unavailable
# After the approved exercise:
.\scripts\ps1\Set-DemoAvailability.ps1 -Region region1 -State Available
```

```bash
bash scripts/bash/set-demo-availability.sh --region region1 --state Unavailable
# After the approved exercise:
bash scripts/bash/set-demo-availability.sh --region region1 --state Available
```

`Available` waits for rollout. Bash also waits for pod deletion on `Unavailable`.
The helper does not record an original replica count or create a measured report.
Do not use `Available` as exact recovery for a deployment that originally had a
different replica count. Never intentionally disable both regional applications.
The aliases identify resource sets, not fixed locations. With the setup examples,
`br`/`region1` means West US 2 and `us`/`region2` means East US; inspect your own
selected environment before changing availability.

## Test-Failover

Preferred controlled backend exercise: explicit consent, baseline, measurement,
and an attempt to restore the original state. **Not a regional DR/RPO test.**
Reserve survivor capacity, prevent concurrent operations, and keep manual recovery
access. It does not delete infrastructure or test a complete Azure region outage.

| PowerShell | Bash | Default/range |
|---|---|---|
| `-Region` | `--region` | Required: `br`, `us`, `region1`, or `region2`. |
| `-AllowDisruption` | `--allow-disruption` | Required explicit acknowledgement. |
| `-WhatIf` | `--what-if` | Preview only; no environment read, HTTP, or Azure access. Still requires acknowledgement. |
| `-OutputPath` | `--output-path` | Unique JSON path under repository `TestResults` by default. Relative custom paths use the working directory. |
| `-TimeoutSeconds` | `--timeout-seconds` | 300; 1-1800, measured from before the fault command. |
| `-IntervalSeconds` | `--interval-seconds` | 3; 1-30 seconds. |
| `-ConsecutiveSuccesses` | `--consecutive-successes` | 5; 1-100 healthy survivor samples in a row. |
| `-Confirm:$false` | `--yes` | Explicitly bypass interactive confirmation **only after external approval**. |

```powershell
.\scripts\ps1\Test-Failover.ps1 -Region region1 -AllowDisruption -WhatIf
# Live exercise; prompts before proceeding:
.\scripts\ps1\Test-Failover.ps1 -Region region1 -AllowDisruption `
  -OutputPath .\TestResults\approved-exercise.json
```

```bash
bash scripts/bash/test-failover.sh --region region1 --allow-disruption --what-if
# Live exercise; type YES to confirm:
bash scripts/bash/test-failover.sh --region region1 --allow-disruption \
  --output-path TestResults/approved-exercise.json
```

Bash refuses noninteractive execution without `--yes`, and refuses to overwrite
an existing evidence file. PowerShell can overwrite the supplied report path;
always choose a fresh path in either shell.

Both deployments must be fully ready with 1-100 desired replicas. Baseline API
validation must pass before any fault. The runner records the target's original
count, scales it to zero, waits for target pod deletion, samples the public API
until the required survivor streak or timeout, then attempts recovery.

PowerShell uses `finally`; Bash uses EXIT/INT/TERM traps. Recovery scales to the
**original count**, waits for rollout, checks ready replicas, and samples the API.
Public traffic need not select the restored region because Front Door considers
latency. If recovery fails, stderr identifies the cluster/count to restore and
the process exits nonzero. SIGKILL, process/host loss, control-plane unavailability,
or loss of credentials can prevent recovery/evidence persistence. Automatic
restoration is an attempt, not a guarantee.

### Evidence and interpretation

JSON report fields include:

- `SchemaVersion`, `Exercise` (`backend-failover-not-regional-DR`).
- `TargetRegion`, `SurvivingRegion`, `OriginalReplicas`, UTC start/end timestamps.
- `TimeoutSeconds`, `RequiredConsecutiveSuccesses`, `Baseline`.
- `FaultCommandDurationSeconds`, `ObservedConvergenceSeconds`.
- `Samples` with status, region, correlation ID, latency, success/error.
- `SampleCount`, `FailedRequests`, `P95LatencyMs`, `Errors`, `Passed`, `Restored`.

```powershell
$report = Get-Content .\TestResults\approved-exercise.json -Raw | ConvertFrom-Json
$report | Select-Object Passed, Restored, ObservedConvergenceSeconds, FailedRequests
```

```bash
jq '{Passed, Restored, ObservedConvergenceSeconds, FailedRequests}' \
  TestResults/approved-exercise.json
```

A precondition failure before injection may produce no report. A successful report
must have both `Passed:true` and `Restored:true`; preserve errors from failed runs.
Sampling begins **after** the fault command completes. Observed convergence includes
that unobserved command interval plus the success streak, not precise outage duration
or a validated DR RTO. No persistent data exists, so no RPO is measured.

For exact manual recovery after a failed exercise, use an authorized cluster
administrator to scale `private-poc/deployment/regional-demo` to `OriginalReplicas`
and verify rollout/readiness. The manual availability helper only restores **two**,
so it is not a substitute when the recorded count differs.

## Invoke-Validation

Local-only, suitable before a commit/PR. Does not read the deployed environment.
Install [test dependencies](../requirements-test.txt) first.

```powershell
python -m pip install -r .\requirements-test.txt
.\scripts\ps1\Invoke-Validation.ps1
```

```bash
python3 -m pip install -r requirements-test.txt
bash scripts/bash/invoke-validation.sh
```

PowerShell runs all Python suites and the five PowerShell test scripts below,
including compiled ARM contracts. Bash runs shell syntax, all Python suites with
the native manifest renderer, and compilation of the main/gateway Bicep templates.
It does not invoke PowerShell; the Windows CI job supplies additional ARM contracts.

`-RequirePinnedTools` / `--require-pinned-tools` requires the appropriate
Python/Bicep versions from [toolchain.json](./toolchain.json), PowerShell's version
in the PowerShell path, and actionlint on PATH. It lints all three workflows;
actionlint's optional shellcheck/pyflakes integrations are disabled.
Bash tests require jq/python3. Set `REQUIRE_BASH_TESTS=1` to fail instead of skipping
if native dependencies are unavailable; Linux CI does this automatically.

### Local test scripts

| Test | Coverage / focused command |
|---|---|
| [Test-Scripts.ps1](../tests/Test-Scripts.ps1) | PowerShell parsing/helpers/input guards: `pwsh -NoProfile -File .\tests\Test-Scripts.ps1`. |
| [Test-Bootstrap.ps1](../tests/Test-Bootstrap.ps1) | Mocked Private Link state transitions, privacy gate, failure/resume: `pwsh -NoProfile -File .\tests\Test-Bootstrap.ps1`. |
| [Test-ApiSample.ps1](../tests/Test-ApiSample.ps1) | Mocked status/network/JSON/header samples: `pwsh -NoProfile -File .\tests\Test-ApiSample.ps1`. |
| [Test-Failover.ps1](../tests/Test-Failover.ps1) | Mocked measured exercise/restoration/reporting: `pwsh -NoProfile -File .\tests\Test-Failover.ps1`. |
| [Test-Infrastructure.ps1](../tests/Test-Infrastructure.ps1) | Bicep builds and ARM security/RBAC/monitoring contracts: `pwsh -NoProfile -File .\tests\Test-Infrastructure.ps1`. |
| [test_demo.py](../tests/test_demo.py) | Local HTTP API, readiness, headers/logging: `python -B -m unittest discover -s tests -p test_demo.py -v`. |
| [test_repository.py](../tests/test_repository.py) | Rendered manifests, hooks, workflow gates, and repository contracts. |
| [test_bash.py](../tests/test_bash.py) | Native guards, initialization/preflight, rendering, HTTP, bootstrap, failover/recovery: `python3 -B -m unittest discover -s tests -p test_bash.py -v`. |
| [test_public_release.py](../tests/test_public_release.py) | MIT/security policy, placeholder-only public Azure URLs, and Git exclusion of local deployment data/keys/reports: `python3 -B -m unittest discover -s tests -p test_public_release.py -v`. |

All Python suites: `python3 -B -m unittest discover -s tests -p 'test_*.py' -v`.
For native repository rendering, set `SCRIPT_TEST_SHELL=bash`; otherwise those
renderer checks use PowerShell. Tests use synthetic inputs and mocked Azure commands.

## Install-CiTools

These scripts are for **disposable GitHub Actions runners**, not global workstation
setup. They download public tool releases into `RUNNER_TEMP/poc-tools` and append
paths to `GITHUB_PATH` for subsequent steps. Current-step PATH is not automatically
changed. Python comes from the workflow's setup-python step.

- PowerShell requires a Windows runner; installs pinned Bicep, PowerShell,
  and actionlint.
- Bash requires a Linux x64 runner with `RUNNER_TEMP` and `GITHUB_PATH`; installs
  pinned Bicep and actionlint, **not PowerShell**. Needs curl/jq/tar.
- Versions are shared in [toolchain.json](./toolchain.json); image release also
  pins Trivy separately through that file.
- Downloads require network access and fail explicitly. Do not set fake runner
  variables merely to bypass the platform guard on a shared workstation.

## Shared libraries

### Common

Loaded by entry points: repository-root discovery, explicit subscription scoping,
safe JSON environment reads, required values, GUID/profile/image/CIDR checks,
region aliases, manifest rendering, checked AKS commands, HTTP envelopes, and
strict APIM public-network denial evidence.

Bash additionally prevents MSYS resource-ID path conversion and uses restrictive
temporary-file permissions. The renderer uses Python's IPv4 validation; source
and template are shared with PowerShell. Digest mode removes the source ConfigMap
and mounts; legacy mode embeds the same server source in both regions.

### Bootstrap

Owns the postprovision state machine described above, bounded polling, correlation,
both-gateway privacy gate, and cleanup. It is extracted so tests can mock failures
without calling Azure. Do not invoke internal publication helpers independently:
doing so could bypass the privacy gate.

### Failover

Owns healthy baseline checks, monotonic timing, survivor streaks, p95, structured
reports, and restoration. Only invoke through the consent-guarded entry point.
It is a backend availability exercise library, not regional DR orchestration.

## Troubleshooting

| Symptom | Action |
|---|---|
| `bash` reports `$'\r'` / syntax errors | Restore LF line endings and use Bash 4+, not `sh`. |
| Tool not found | Install prerequisites in the host running the script; Windows PATH/auth is not automatically Linux PATH/auth. |
| azd values missing | Select the correct existing environment; initialize missing inputs or complete approved provisioning. Never fabricate outputs. |
| Wrong tenant, inaccessible group, unregistered provider | Fix the reported identity/configuration/provider with the environment owner; rerun preflight. |
| Azure CLI extension `Access is denied` | Repair that CLI installation with its owner; do not ignore the failure or change shared permissions automatically. Origin verification uses `az resource show`, not `az afd`. |
| Unexpected/ambiguous Private Link request | Inspect APIM requests and Front Door origin/marker correlation; do not approve arbitrary endpoints. |
| Post hook failed after partial progress | Correct the error, keep gateways private, then run `azd hooks run postprovision` with approval. |
| Direct APIM denial shape differs | Inspect real evidence and add a verified fixture before broadening acceptance; a generic 403/404 is insufficient. |
| Front Door still returns target region/errors | Allow probe convergence; check both origins and healthy survivor capacity before another approved exercise. |
| Restoration or report write failed | Preserve stderr/report, restore the recorded replica count with an authorized operator, verify rollout and public API before closing the exercise. |
| Container build unavailable | Start an approved Linux Docker daemon; local script tests do not substitute for image build/scan/runtime verification. |

See the [main README](../README.md) for costs, production blockers, CI approval
configuration, and destructive environment cleanup warnings.
