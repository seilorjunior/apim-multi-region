import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts" / "bash"
VALUES = {
    "AZURE_SUBSCRIPTION_ID": "00000000-0000-0000-0000-000000000001",
    "AZURE_ENV_NAME": "test", "FRONT_DOOR_PROFILE_NAME": "profile",
    "FRONT_DOOR_ID": "fdid", "AZURE_RESOURCE_GROUP": "global",
    "FRONT_DOOR_ORIGIN_GROUP_NAME": "origins",
    "API_URL": "https://test.example/demo/", "API_HEALTH_URL": "https://test.example/demo/health/ready",
}
for prefix, region in (("BRAZIL", "westus2"), ("US", "eastus")):
    for key, value in {
        "RESOURCE_GROUP": prefix, "APIM_NAME": "apim-" + prefix, "APIM_ID": "/apim/" + prefix,
        "AKS_NAME": "aks-" + prefix, "BACKEND_IP": "10.10.3.250", "APIM_SUBNET": "10.10.4.0/24",
        "LOCATION": region,
    }.items():
        VALUES[f"{prefix}_{key}"] = value


def json_documents(text):
    decoder = json.JSONDecoder()
    documents = []
    while text.strip():
        document, end = decoder.raw_decode(text.lstrip())
        documents.append(document)
        text = text.lstrip()[end:]
    return documents


class BashTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("bash"):
            cls.unavailable("Bash is not installed.")
        probe = subprocess.run(["bash", "-c", "command -v jq; command -v python3"],
                               cwd=ROOT, capture_output=True, text=True, timeout=30)
        if probe.returncode:
            cls.unavailable("Bash needs jq and python3 (Windows: use WSL with these tools).")

    @classmethod
    def unavailable(cls, message):
        if os.environ.get("REQUIRE_BASH_TESTS") == "1":
            raise RuntimeError(message)
        raise unittest.SkipTest(message + " The native-bash CI job requires these tests.")

    def run_bash(self, script, success=True):
        raw = subprocess.run(["bash", "-s"], input=(script + "\n").encode(), cwd=ROOT,
                             capture_output=True, timeout=40)
        result = subprocess.CompletedProcess(raw.args, raw.returncode,
                                             raw.stdout.decode(), raw.stderr.decode())
        if success:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stderr + result.stdout)
        return result

    def common(self, extra=""):
        return "source scripts/bash/common.sh\nENV_JSON=" + shlex.quote(json.dumps(VALUES)) + "\n" + extra

    def test_syntax_and_help(self):
        for path in SCRIPTS.glob("*.sh"):
            with self.subTest(script=path.name):
                self.assertNotIn(b"\r", path.read_bytes(), "Bash scripts require LF line endings.")
                self.run_bash(f"bash -n scripts/bash/{path.name}")
                if path.stem not in ("common", "bootstrap", "failover"):
                    result = self.run_bash(f"bash scripts/bash/{path.name} --help")
                    self.assertIn("Usage:", result.stdout)

    def test_shared_container_smoke_action(self):
        action = yaml.safe_load((ROOT / ".github" / "actions" / "container-smoke" / "action.yml").read_text())
        script = action["runs"]["steps"][0]["run"]
        mock = r'''
IMAGE_TAG=local:test
docker() {
    case "$1 $2" in
        'image inspect')
            if [[ "$SCENARIO" == WrongUser ]]; then printf root; else printf '10001:10001'; fi ;;
        'run -d')
            if [[ "$SCENARIO" == RunFailure ]]; then return 42; fi
            printf container-id ;;
        'exec container-id') printf 10001 ;;
        'port container-id') printf '127.0.0.1:49152' ;;
        'logs container-id') printf 'CONTAINER_LOGS\n' >&2 ;;
        'rm -f') printf 'CONTAINER_REMOVED\n' >&2 ;;
        *) printf 'Unexpected Docker command: %s\n' "$*" >&2; return 99 ;;
    esac
}
curl() {
    if [[ "$SCENARIO" == HttpFailure ]]; then return 22; fi
    if [[ "${*: -1}" == */health/ready ]]; then
        printf '{"status":"ok","region":"eastus"}'
    else
        printf '{"service":"regional-demo","region":"eastus"}'
    fi
}
'''
        for scenario in ("Success", "WrongUser", "RunFailure", "HttpFailure"):
            with self.subTest(scenario=scenario):
                result = self.run_bash("SCENARIO=" + scenario + "\n" + mock + script,
                                       success=scenario == "Success")
                if scenario in ("Success", "HttpFailure"):
                    self.assertIn("CONTAINER_LOGS", result.stderr)
                    self.assertIn("CONTAINER_REMOVED", result.stderr)
                else:
                    self.assertNotIn("CONTAINER_REMOVED", result.stderr)

    def test_guards_before_azure_access(self):
        guard = 'azd() { echo "UNEXPECTED_AZURE_ACCESS" >&2; return 99; }\nexport -f azd\n'
        result = self.run_bash(guard + "bash scripts/bash/test-failover.sh --region region1 --what-if", success=False)
        self.assertIn("--allow-disruption", result.stderr)
        self.assertNotIn("UNEXPECTED_AZURE_ACCESS", result.stderr)
        result = self.run_bash(guard + "bash scripts/bash/test-failover.sh --region region1 --allow-disruption --what-if")
        self.assertIn("What if:", result.stderr)
        self.assertNotIn("UNEXPECTED_AZURE_ACCESS", result.stderr)
        for arguments in ("--region region1 --allow-disruption", "--region bad --allow-disruption --yes",
                          "--region region1 --allow-disruption --yes --timeout-seconds 0", "--unknown"):
            result = self.run_bash(guard + "bash scripts/bash/test-failover.sh " + arguments, success=False)
            self.assertNotIn("UNEXPECTED_AZURE_ACCESS", result.stderr)

    def test_render_and_input_validation(self):
        image = "ghcr.io/example/demo@sha256:" + "a" * 64
        for image_arg in ("", image):
            result = self.run_bash(self.common(
                "render_manifest eastus 10.10.3.250 10.10.4.0/24 " + shlex.quote(image_arg)))
            docs = [doc for doc in yaml.safe_load_all(result.stdout) if doc]
            spec = next(doc for doc in docs if doc["kind"] == "Deployment")["spec"]["template"]["spec"]
            if image_arg:
                self.assertEqual(spec["containers"][0]["image"], image)
                self.assertNotIn("volumes", spec)
            else:
                config = next(doc for doc in docs if doc["kind"] == "ConfigMap")
                self.assertEqual(config["data"]["server.py"].rstrip(),
                                 (ROOT / "src" / "demo" / "server.py").read_text().rstrip())
        for cidr in ("999.999.999.999/24", "10.10.4.1/24", "10.10.4.0/33", "::1/24", "10.10.4.0/19"):
            self.run_bash(self.common("render_manifest eastus 10.10.3.250 " + shlex.quote(cidr)), success=False)
        self.run_bash(self.common("render_manifest eastus 10.10.3.250 10.10.4.0/24 image:latest"), success=False)
        self.run_bash(self.common("render_manifest 'eastus;bad' 10.10.3.250 10.10.4.0/24"), success=False)

    def test_public_denial_and_sampling(self):
        body = {"statusCode": 403, "message": "public network access on apim-test is disabled"}
        for status in (403, 404):
            response = json.dumps({"Status": status, "Body": body})
            self.run_bash(self.common("assert_apim_blocked " + shlex.quote(response) + " apim-test"))
        for response in ({"Status": 403, "Body": "Forbidden"}, {"Status": 200, "Body": body},
                         {"Status": 404, "Body": {"statusCode": 404}},
                         {"Status": 403, "Body": {"statusCode": 403, "message": "Invalid Front Door header"}}):
            self.run_bash(self.common("assert_apim_blocked " + shlex.quote(json.dumps(response)) + " apim-test"), success=False)
        good = {"Status": 200, "Body": {"service": "regional-demo", "region": "eastus"},
                "Headers": {"x-served-region": "eastus"}, "LatencyMs": 12.5, "NetworkError": None}
        cases = [good, {**good, "Status": 503}, {**good, "Body": []},
                 {**good, "Body": None}, {**good, "Headers": {}}, {**good, "NetworkError": "Connection failed"}]
        for index, response in enumerate(cases):
            mock = "http_get() { printf '%s\\n' " + shlex.quote(json.dumps(response)) + "; }\n"
            sample = json.loads(self.run_bash(self.common(mock + "api_sample https://example.test '[\"eastus\"]'")).stdout)
            self.assertEqual(sample["Success"], index == 0)
            if index:
                self.assertTrue(sample["Error"])

    def test_subscription_scope_and_native_errors(self):
        script = self.common(r'''
SUBSCRIPTION_ID=test-subscription
az() { printf '%s\n' "$*" >&2; printf '{}\n'; }
az_json ad group show --group test
az_json provider list
''')
        result = self.run_bash(script)
        calls = result.stderr.splitlines()
        self.assertNotIn("--subscription", calls[0])
        self.assertIn("--subscription test-subscription", calls[1])
        self.run_bash(self.common("az() { return 9; }\naz_json provider list"), success=False)

    def test_operations_settings(self):
        basic = {"DEPLOYMENT_PROFILE": "poc", "MONITORING_MODE": "Disabled", "ALERTS_MODE": "Disabled"}
        production = {
            "DEPLOYMENT_PROFILE": "production", "MONITORING_MODE": "Enabled", "ALERTS_MODE": "Enabled",
            "ALERT_ACTION_GROUP_ID": "/subscriptions/00000000-0000-0000-0000-000000000001/"
                                     "resourceGroups/test/providers/Microsoft.Insights/actionGroups/oncall",
            "REGION1_ZONES": "1,2,3", "REGION2_ZONES": "1,2",
            "DEMO_IMAGE": "ghcr.io/example/demo@sha256:" + "a" * 64,
        }
        cases = [(basic, True), (production, True)]
        for key, value in (
            ("DEPLOYMENT_PROFILE", "invalid"), ("MONITORING_MODE", "Disabled"),
            ("ALERTS_MODE", "Disabled"), ("REGION1_ZONES", "1"),
            ("REGION2_ZONES", "1,1"), ("REGION1_ZONES", "1,4"),
            ("DEMO_IMAGE", "image:latest"),
            ("ALERT_ACTION_GROUP_ID", production["ALERT_ACTION_GROUP_ID"].replace("Microsoft.", "MicrosoftX")),
        ):
            cases.append(({**production, key: value}, False))
        for values, expected in cases:
            with self.subTest(settings=values):
                self.run_bash(self.common("ENV_JSON=" + shlex.quote(json.dumps(values)) +
                                          "\nassert_operations"), success=expected)

    def test_http_envelope_serialization(self):
        mock = r'''
curl() {
    while (( $# )); do
        case "$1" in
            --dump-header) printf 'HTTP/2 200\r\nX-Served-Region: eastus\r\n' > "$2"; shift 2 ;;
            --output) printf '%s' "$MOCK_BODY" > "$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    if [[ "$MOCK_NETWORK" == failure ]]; then return 28; fi
    printf '200 0.0125'
}
http_get https://test.example/demo/
'''
        for body, network in (('{"region":"eastus"}', "ok"), ("not JSON", "ok"), ("", "failure")):
            script = self.common("MOCK_BODY=" + shlex.quote(body) + "\nMOCK_NETWORK=" +
                                 shlex.quote(network) + "\n" + mock)
            result = json.loads(self.run_bash(script).stdout)
            self.assertEqual(result["Headers"]["x-served-region"], "eastus")
            self.assertEqual(result["Status"], 0 if network == "failure" else 200)
            self.assertEqual(result["LatencyMs"], 0 if network == "failure" else 12.5)
            self.assertEqual(result["Body"], {"region": "eastus"} if body.startswith("{") else None)
            self.assertEqual(bool(result["NetworkError"]), network == "failure")

    def test_initialization_and_preflight_entry_points(self):
        values = {
            **VALUES, "AZURE_TENANT_ID": "00000000-0000-0000-0000-000000000002",
            "AKS_ADMIN_GROUP_OBJECT_ID": "00000000-0000-0000-0000-000000000003",
            "APIM_PUBLISHER_EMAIL": "publisher@example.test", "APIM_PUBLISHER_NAME": "Test",
            "AZURE_LOCATION": "westus2",
        }
        mock = r'''
MOCK_DIR="$(mktemp -d -t apim-bash-tests.XXXXXXXX)"
trap 'rm -f -- "$MOCK_DIR/state"; rmdir -- "$MOCK_DIR"' EXIT
export MOCK_STATE="$MOCK_DIR/state"
: > "$MOCK_STATE"
azd() {
    if [[ "$1 $2" == 'env get-values' ]]; then printf '%s\n' "$MOCK_VALUES"
    elif [[ "$1 $2" == 'env set' ]]; then printf '%s=%s\n' "$3" "$4" >> "$MOCK_STATE"
    elif [[ "$1 $2" == 'env new' ]]; then printf 'environment-created\n' >> "$MOCK_STATE"
    else return 91; fi
}
az() {
    case "$1 $2" in
        'account show') printf '{"tenantId":"00000000-0000-0000-0000-000000000002","state":"Enabled"}' ;;
        'ad group') printf '{"securityEnabled":true}' ;;
        'provider show')
            if [[ "$SCENARIO" == ProviderError ]]; then printf '"NotRegistered"'; else printf '"Registered"'; fi ;;
        'group exists') printf true ;;
        'apim list') printf '[{"publicNetworkAccess":"Disabled"}]' ;;
        *) return 92 ;;
    esac
}
bicep() { return 0; }
export -f az azd bicep
set +e
bash "scripts/bash/$ENTRY" "${ARGS[@]}"
code=$?
cat "$MOCK_STATE"
exit "$code"
'''
        for scenario in ("Initialize", "Preflight", "ProviderError"):
            script = self.common(
                "export MOCK_VALUES=" + shlex.quote(json.dumps(values)) + "\nexport SCENARIO=" + scenario + "\n")
            if scenario == "Initialize":
                script += (
                    "ENTRY=initialize-environment.sh\nARGS=(--subscription-id " + values["AZURE_SUBSCRIPTION_ID"] +
                    " --tenant-id " + values["AZURE_TENANT_ID"] +
                    " --publisher-email publisher@example.test --environment-name native-unit-test"
                    " --region1-location westus2 --region2-location eastus)\n")
            else:
                script += "ENTRY=pre-provision.sh\nARGS=()\n"
            result = self.run_bash(script + mock, success=scenario != "ProviderError")
            if scenario == "Initialize":
                self.assertIn("environment-created", result.stdout)
                self.assertIn("BRAZIL_LOCATION=westus2", result.stdout)
                self.assertIn("No Azure resource was provisioned", result.stderr)
            else:
                self.assertIn("MONITORING_MODE=Disabled", result.stdout)
                if scenario == "Preflight":
                    self.assertIn("APIM_PUBLIC_ACCESS_BR=Disabled", result.stdout)
                    self.assertIn("APIM_PUBLIC_ACCESS_US=Disabled", result.stdout)
                else:
                    self.assertNotIn("APIM_PUBLIC_ACCESS_", result.stdout)
                    self.assertIn("Register Microsoft.ApiManagement", result.stderr)

    def test_bootstrap_state_machine(self):
        mock = r'''
source scripts/bash/bootstrap.sh
cleanup_bootstrap() {
    local code=$?
    rm -f -- "$BOOTSTRAP_TEMP_DIR/demo.yaml" "$BOOTSTRAP_TEMP_DIR/gateway.json" "$BOOTSTRAP_TEMP_DIR/gateway.parameters.json"
    rmdir "$BOOTSTRAP_TEMP_DIR"
    (exit "$code")
}
check_private() {
    jq -e '.disabled.br and .disabled.us' "$MOCK_DIR/state" >/dev/null || die 'PUBLICATION_BEFORE_PRIVACY'
}
event() {
    jq --arg event "$1" '.events += [$event]' "$MOCK_DIR/state" > "$MOCK_DIR/next"
    mv "$MOCK_DIR/next" "$MOCK_DIR/state"
}
set_value() { :; }
bicep() { check_private; event compile; }
aks_checked() { check_private; event workload; }
az_json() {
    local key=br status=Approved marker connection id
    if [[ "$1 $2 $3" == "network private-endpoint-connection list" ]]; then
        id="${@: -1}"
        [[ "$id" != *US ]] || key=us
        jq --arg key "$key" '.polls[$key] += 1' "$MOCK_DIR/state" > "$MOCK_DIR/next"
        mv "$MOCK_DIR/next" "$MOCK_DIR/state"
        if [[ "$CASE" == Timeout ]]; then printf '[]\n'; return; fi
        if [[ "$CASE" == Pending && "$(jq -r --arg k "$key" '.polls[$k]' "$MOCK_DIR/state")" == 1 ]]; then status=Pending; fi
        if [[ "$key" == us && ( "$CASE" == Rejected || "$CASE" == Disconnected ) ]]; then status="$CASE"; fi
        marker="azd:test:$key:profile"
        [[ "$CASE" != Unexpected ]] || marker=someone-else
        connection="$(jq -cn --arg status "$status" --arg marker "$marker" '{id:"connection",properties:{privateEndpoint:{id:"endpoint"},privateLinkServiceConnectionState:{status:$status,description:$marker}}}')"
        jq -cn --argjson c "$connection" --arg case "$CASE" 'if $case == "Ambiguous" then [$c,$c] else [$c] end'
    elif [[ "$1 $2 $3" == "network private-endpoint-connection approve" ]]; then
        event approve; printf '{}\n'
    elif [[ "$1 $2" == "resource show" ]]; then
        [[ "$4" != */us ]] || key=us
        if [[ "$key" == br ]]; then id=/apim/BRAZIL; else id=/apim/US; fi
        [[ "$CASE" != WrongOrigin ]] || id=/wrong
        jq -cn --arg id "$id" --arg marker "azd:test:$key:profile" '{properties:{sharedPrivateLinkResource:{privateLink:{id:$id},groupId:"Gateway",requestMessage:$marker}}}'
    elif [[ "$1 $2" == "apim show" ]]; then
        [[ "$4" != apim-US ]] || key=us
        jq -c --arg key "$key" '{publicNetworkAccess:(if .disabled[$key] then "Disabled" else "Enabled" end)}' "$MOCK_DIR/state"
    elif [[ "$1 $2" == "resource update" ]]; then
        [[ "$4" != */US ]] || key=us
        [[ "$CASE" != UpdateFailure ]] || die 'Simulated ARM update failure.'
        if [[ "$CASE" != StillPublic ]]; then
            jq --arg key "$key" '.disabled[$key]=true' "$MOCK_DIR/state" > "$MOCK_DIR/next"
            mv "$MOCK_DIR/next" "$MOCK_DIR/state"
        fi
        event disable; printf '{}\n'
    elif [[ "$1 $2" == "deployment group" ]]; then
        check_private; event api
        [[ "$CASE" != PublishFailure ]] || die 'Simulated publication failure.'
        printf '{}\n'
    else
        die "Unexpected mock command: $*"
    fi
}
private_bootstrap 2 0
'''
        for case in ("Pending", "Resume", "Timeout", "Rejected", "Disconnected", "Unexpected",
                     "Ambiguous", "WrongOrigin", "UpdateFailure", "StillPublic", "PublishFailure"):
            with self.subTest(case=case):
                state = {"disabled": {"br": case == "Resume", "us": case == "Resume"},
                         "polls": {"br": 0, "us": 0}, "events": []}
                script = self.common("CASE=" + case + r'''
MOCK_DIR="$(mktemp -d)"
export MOCK_DIR
printf '%s\n' ''' + shlex.quote(json.dumps(state)) + r''' > "$MOCK_DIR/state"
set +e
(
set -e
''' + mock + r'''
)
code=$?
cat "$MOCK_DIR/state"
rm -f -- "$MOCK_DIR/state" "$MOCK_DIR/next"
rmdir "$MOCK_DIR"
exit "$code"
''')
                result = self.run_bash(script, success=case in ("Pending", "Resume"))
                final = json_documents(result.stdout)[-1]
                if case in ("Pending", "Resume"):
                    self.assertEqual(final["events"].count("workload"), 2)
                    self.assertEqual(final["events"].count("api"), 2)
                elif case != "PublishFailure":
                    self.assertNotIn("workload", final["events"])
                    self.assertNotIn("api", final["events"])
                if case == "Pending":
                    self.assertEqual(final["events"].count("approve"), 2)
                if case == "Resume":
                    self.assertNotIn("approve", final["events"])
                    self.assertNotIn("disable", final["events"])
                self.assertNotIn("PUBLICATION_BEFORE_PRIVACY", result.stderr)

    def test_measured_failover_restores_and_reports(self):
        mock = r'''
source scripts/bash/failover.sh
get_deployment() {
    local count=3
    if [[ "$CASE" == Unavailable && "$(jq -r .Key <<<"$1")" == us ]]; then count=0; fi
    jq -cn --argjson n "$count" '{spec:{replicas:$n},status:{readyReplicas:$n}}'
}
set_replicas() {
    jq --argjson count "$2" '.changes += [$count]' "$MOCK_DIR/state" > "$MOCK_DIR/next"
    mv "$MOCK_DIR/next" "$MOCK_DIR/state"
    [[ "$CASE" != FaultError || "$2" != 0 ]] || die 'Fault command failed.'
    [[ "$CASE" != RestoreError || "$2" == 0 ]] || die 'Restore command failed.'
}
api_sample() {
    local n success=true region=eastus
    jq '.requests += 1' "$MOCK_DIR/state" > "$MOCK_DIR/next"
    mv "$MOCK_DIR/next" "$MOCK_DIR/state"
    n="$(jq -r .requests "$MOCK_DIR/state")"
    [[ "$CASE" != SampleError || "$n" != 2 ]] || die 'Unexpected sample error.'
    if [[ "$CASE" == BaselineError || ( "$CASE" == Transient && "$n" == 2 ) ]]; then success=false; fi
    [[ "$CASE" != NoConvergence ]] || region=westus2
    jq -cn --argjson success "$success" --arg region "$region" '{TimestampUtc:"test",Status:(if $success then 200 else 503 end),Region:$region,Success:$success,LatencyMs:12.5,Error:(if $success then null else "HTTP 503" end)}'
}
measured_failover br "$MOCK_DIR/report.json" 2 1 1
'''
        for case in ("Success", "Transient", "FaultError", "SampleError", "RestoreError",
                     "NoConvergence", "Unavailable", "BaselineError"):
            with self.subTest(case=case):
                script = self.common("CASE=" + case + r'''
MOCK_DIR="$(mktemp -d)"
export MOCK_DIR
printf '{"changes":[],"requests":0}\n' > "$MOCK_DIR/state"
set +e
(
set -e
''' + mock + r'''
)
code=$?
cat "$MOCK_DIR/state"
rm -f -- "$MOCK_DIR/state" "$MOCK_DIR/next" "$MOCK_DIR/report.json"
rmdir "$MOCK_DIR"
exit "$code"
''')
                result = self.run_bash(script, success=case in ("Success", "Transient"))
                docs = json_documents(result.stdout)
                state = docs[-1]
                if case in ("Unavailable", "BaselineError"):
                    self.assertEqual(state["changes"], [])
                    self.assertEqual(len(docs), 1)
                else:
                    self.assertEqual(state["changes"], [0, 3])
                    report = docs[0]
                    self.assertEqual(report["OriginalReplicas"], 3)
                    self.assertEqual(report["Restored"], case != "RestoreError")
                    self.assertEqual(report["Passed"], case in ("Success", "Transient"))
                    if case == "Transient":
                        self.assertEqual(report["FailedRequests"], 1)
                        self.assertEqual(report["P95LatencyMs"], 12.5)


if __name__ == "__main__":
    unittest.main()
