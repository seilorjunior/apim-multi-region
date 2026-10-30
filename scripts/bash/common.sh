#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if (( BASH_VERSINFO[0] < 4 )); then
    printf 'ERROR: Bash 4 or newer is required (macOS users must install a newer Bash).\n' >&2
    exit 1
fi
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SUBSCRIPTION_ID=''
export MSYS_NO_PATHCONV=1
trap 'printf "ERROR: command failed at %s:%s (exit %s).\n" "${BASH_SOURCE[0]:-stdin}" "$LINENO" "$?" >&2' ERR

die() { LAST_ERROR="$*"; printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }
require_tools() {
    local name
    for name in "$@"; do command -v "$name" >/dev/null || die "Required command not found: $name"; done
}
load_environment() {
    ENV_JSON="$(cd -- "$PROJECT_ROOT" && azd env get-values --output json)" || die 'Cannot read the selected azd environment.'
    jq -e 'type == "object"' <<<"$ENV_JSON" >/dev/null || die 'azd did not return an environment object.'
}
required() {
    jq -er --arg name "$1" '.[$name] | select(type == "string" and test("\\S"))' <<<"$ENV_JSON" ||
        die "Missing $1. Configure it using: azd env set $1 <value>"
}
set_value() { (cd -- "$PROJECT_ROOT" && azd env set "$1" "$2") || die "Cannot set azd value $1."; }
az_json() {
    local -a scope=()
    if [[ -n "$SUBSCRIPTION_ID" && "$1" != ad ]]; then scope=(--subscription "$SUBSCRIPTION_ID"); fi
    az "$@" "${scope[@]}" --only-show-errors --output json || die 'Azure CLI command failed.'
}
assert_guid() {
    [[ "$1" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ &&
        "$1" != 00000000-0000-0000-0000-000000000000 ]] || die "$2 must be a non-empty GUID."
}
assert_environment_name() {
    [[ "$1" =~ ^[a-z][a-z0-9-]{2,23}$ ]] || die 'Environment name must be 3-24 lowercase letters, digits or hyphens, starting with a letter.'
}
assert_email() {
    [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || die 'Publisher email is invalid.'
}
assert_image() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9./:_-]*@sha256:[a-f0-9]{64}$ ]] || die 'DEMO_IMAGE must be pinned by sha256 digest.'
}
bounded_integer() {
    [[ "$1" =~ ^(0|[1-9][0-9]*)$ && ${#1} -le 6 ]] || die "$4 must be a canonical non-negative integer."
    (( 10#$1 >= $2 && 10#$1 <= $3 )) || die "$4 must be between $2 and $3."
}
resolve_region() {
    case "$1" in br|region1) printf 'br\n' ;; us|region2) printf 'us\n' ;; *) die 'Region must be br, us, region1 or region2.' ;; esac
}
region_settings() {
    local key prefix field
    key="$(resolve_region "$1")"
    if [[ "$key" == br ]]; then prefix=BRAZIL; else prefix=US; fi
    for field in RESOURCE_GROUP APIM_NAME APIM_ID AKS_NAME BACKEND_IP APIM_SUBNET LOCATION; do
        required "${prefix}_$field" >/dev/null
    done
    jq -c --arg p "$prefix" --arg key "$key" '{
        Key:$key, ResourceGroup:.[$p+"_RESOURCE_GROUP"], ApimName:.[$p+"_APIM_NAME"],
        ApimId:.[$p+"_APIM_ID"], AksName:.[$p+"_AKS_NAME"], BackendIp:.[$p+"_BACKEND_IP"],
        ApimSubnet:.[$p+"_APIM_SUBNET"], Location:.[$p+"_LOCATION"]
    }' <<<"$ENV_JSON"
}
assert_operations() {
    local profile monitoring alerts id name zones image
    profile="$(required DEPLOYMENT_PROFILE)"
    monitoring="$(required MONITORING_MODE)"
    alerts="$(required ALERTS_MODE)"
    [[ "$profile" == poc || "$profile" == production ]] || die 'Invalid deployment profile.'
    [[ "$monitoring" == Enabled || "$monitoring" == Disabled ]] || die 'Invalid monitoring mode.'
    [[ "$alerts" == Enabled || "$alerts" == Disabled ]] || die 'Invalid alerts mode.'
    if [[ "$alerts" == Enabled ]]; then
        id="$(required ALERT_ACTION_GROUP_ID)"
        [[ "$monitoring" == Enabled && "$id" =~ ^/subscriptions/[[:xdigit:]-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Insights/actionGroups/[^/]+$ ]] ||
            die 'Alerts require monitoring and an existing action group resource ID.'
    fi
    if [[ "$profile" == production ]]; then
        for name in REGION1_ZONES REGION2_ZONES; do
            zones="$(required "$name")"
            jq -en --arg zones "$zones" '$zones | split(",") |
                length >= 2 and length <= 3 and length == (unique | length) and all(.[]; test("^[1-3]$"))' >/dev/null ||
                die 'Production requires at least two distinct supported zones per cluster.'
        done
        image="$(required DEMO_IMAGE)"
        assert_image "$image"
        [[ "$monitoring" == Enabled && "$alerts" == Enabled ]] || die 'Production requires monitoring and routed alerts.'
    fi
}
render_manifest() {
    python3 - "$PROJECT_ROOT" "$1" "$2" "$3" "${4:-}" <<'PY'
import ipaddress
from pathlib import Path
import re
import sys

root, region, backend, subnet, image = sys.argv[1:]
if not re.fullmatch(r"[a-z0-9]+", region):
    raise ValueError("Invalid region name.")
ipaddress.IPv4Address(backend)
network = ipaddress.IPv4Network(subnet, strict=True)
if not 20 <= network.prefixlen <= 32:
    raise ValueError("Invalid APIM subnet CIDR: prefix must be 20-32.")
if image and not re.fullmatch(r"[a-z0-9][a-z0-9./:_-]*@sha256:[a-f0-9]{64}", image):
    raise ValueError("DEMO_IMAGE must be pinned by sha256 digest.")
root = Path(root)
source = "\n".join("    " + line for line in (root / "src/demo/server.py").read_text().splitlines())
config = ("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: regional-demo\n"
          "  namespace: private-poc\ndata:\n  server.py: |\n" + source + "\n---")
replacements = {
    "__SOURCE_CONFIG_MAP__": "" if image else config,
    "__CONTAINER_COMMAND__": "" if image else '          command: ["python", "/app/server.py"]',
    "__SOURCE_MOUNT__": "" if image else (
        "          volumeMounts:\n            - name: source\n"
        "              mountPath: /app\n              readOnly: true"),
    "__SOURCE_VOLUME__": "" if image else (
        "      volumes:\n        - name: source\n          configMap:\n            name: regional-demo"),
    "__DEMO_IMAGE__": image or "docker.io/library/python:3.13-alpine",
    "__REGION__": region, "__BACKEND_IP__": backend, "__APIM_SUBNET__": subnet,
}
manifest = (root / "k8s/demo.yaml").read_text()
for token, value in replacements.items():
    manifest = manifest.replace(token, value)
print(manifest, end="")
PY
}
aks_checked() {
    local region="$1" command="$2" file="${3:-}" result
    local -a args=(aks command invoke --resource-group "$(jq -r .ResourceGroup <<<"$region")"
        --name "$(jq -r .AksName <<<"$region")" --command "$command")
    if [[ -n "$file" ]]; then args+=(--file "$file"); fi
    result="$(az_json "${args[@]}")" || die 'AKS command invocation failed.'
    if ! jq -e '.exitCode == 0' <<<"$result" >/dev/null; then
        jq -r '.logs // "No command result returned."' <<<"$result" >&2
        die 'AKS Run Command failed.'
    fi
    jq -r '.logs // empty' <<<"$result" >&2
}
get_deployment() {
    local result
    result="$(az_json aks command invoke --resource-group "$(jq -r .ResourceGroup <<<"$1")" \
        --name "$(jq -r .AksName <<<"$1")" --command 'kubectl -n private-poc get deployment regional-demo -o json')"
    jq -e '.exitCode == 0' <<<"$result" >/dev/null || die 'Cannot inspect deployment.'
    jq -er '.logs | fromjson' <<<"$result" || die 'AKS did not return deployment JSON.'
}
set_replicas() {
    local region="$1" replicas="$2" command
    bounded_integer "$replicas" 0 100 Replicas
    command="kubectl -n private-poc scale deployment/regional-demo --replicas=$replicas"
    if (( replicas > 0 )); then
        command+=' && kubectl -n private-poc rollout status deployment/regional-demo --timeout=180s'
    else
        command+=' && kubectl -n private-poc wait --for=delete pod -l app=regional-demo --timeout=180s'
    fi
    aks_checked "$region" "$command"
}
http_get() {
    local url="$1" header="${2:-}" dir stats code duration network=''
    local -a args=(--silent --show-error --max-time 10 --proto '=https')
    dir="$(mktemp -d)"
    if [[ -n "$header" ]]; then args+=(--header "$header"); fi
    if stats="$(curl "${args[@]}" --dump-header "$dir/headers" --output "$dir/body" \
        --write-out '%{http_code} %{time_total}' --url "$url")"; then
        read -r code duration <<<"$stats"
    else
        network="curl failed with exit code $?"
        code=0
        duration=0
    fi
    python3 - "$dir" "$code" "$duration" "$network" <<'PY'
import json
from pathlib import Path
import sys
directory, status, duration, error = sys.argv[1:]
directory = Path(directory)
raw = (directory / "body").read_text(errors="replace") if (directory / "body").exists() else ""
try:
    body = json.loads(raw)
except json.JSONDecodeError:
    body = None
headers = {}
if (directory / "headers").exists():
    for line in (directory / "headers").read_text(errors="replace").splitlines():
        if ":" in line:
            name, value = line.split(":", 1)
            headers[name.lower()] = value.strip()
print(json.dumps({"Status": int(status), "Body": body, "Headers": headers,
                  "LatencyMs": round(float(duration) * 1000, 3), "NetworkError": error or None}))
PY
    rm -f -- "$dir/headers" "$dir/body"
    rmdir -- "$dir"
}
api_sample() {
    local response separator='?' request_id
    [[ "$1" != *'?'* ]] || separator='&'
    request_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    response="$(http_get "$1${separator}request=$request_id")"
    jq -c --argjson allowed "$2" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        . as $r |
        (if .NetworkError != null then .NetworkError
         elif .Status != 200 then "HTTP \(.Status)"
         elif (.Body | type) != "object" then "Invalid JSON response object."
         elif .Body.service != "regional-demo" or ($allowed | index($r.Body.region)) == null or
              .Headers["x-served-region"] != .Body.region then "Invalid response contract or regional header."
         else null end) as $error |
        {TimestampUtc:$timestamp, Status:.Status, Region:(.Body.region? // null),
         CorrelationId:(.Headers["x-correlation-id"] // null), LatencyMs:.LatencyMs,
         Success:($error == null), Error:$error}' <<<"$response"
}
assert_apim_blocked() {
    jq -e --arg name "$2" '
        (.Status == 403 or .Status == 404) and
        (if (.Body | type) == "object" then
            .Body.statusCode == 403 and (.Body.message | type) == "string" and
            (.Body.message | test("public network access.*disabled"; "i")) and
            (.Body.message | contains($name))
         else false end)' <<<"$1" >/dev/null ||
        die "Public APIM access was not confirmed blocked for $2."
}
