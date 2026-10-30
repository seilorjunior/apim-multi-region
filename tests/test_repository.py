import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


class RepositoryTests(unittest.TestCase):
    def render(self, image=None):
        if os.environ.get("SCRIPT_TEST_SHELL") == "bash":
            script = 'source scripts/bash/common.sh\nrender_manifest eastus 10.10.3.250 10.10.4.0/24'
            if image:
                script += " " + shlex.quote(image)
            result = subprocess.run(
                ["bash", "-s"], input=(script + "\n").encode(), cwd=ROOT,
                check=True, capture_output=True,
            )
            return [doc for doc in yaml.safe_load_all(result.stdout) if doc]
        common = ROOT / "scripts" / "ps1" / "Common.ps1"
        script = (
            f". '{str(common).replace(chr(39), chr(39) * 2)}'; "
            "New-DemoManifest -Region eastus -BackendIp 10.10.3.250 "
            "-ApimSubnet 10.10.4.0/24"
        )
        if image:
            script += f" -Image '{image}'"
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-Command", script],
            check=True, capture_output=True, text=True,
        )
        return [doc for doc in yaml.safe_load_all(result.stdout) if doc]

    def test_rendered_manifests(self):
        image = "ghcr.io/example/demo@sha256:" + "a" * 64
        for immutable in (False, True):
            with self.subTest(immutable=immutable):
                docs = self.render(image if immutable else None)
                deployment = next(doc for doc in docs if doc["kind"] == "Deployment")
                spec = deployment["spec"]["template"]["spec"]
                container = spec["containers"][0]
                self.assertEqual(deployment["spec"]["replicas"], 2)
                self.assertEqual(spec["securityContext"]["runAsUser"], 10001)
                self.assertFalse(spec["automountServiceAccountToken"])
                self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
                constraints = spec["topologySpreadConstraints"]
                self.assertEqual(constraints[0]["topologyKey"], "kubernetes.io/hostname")
                self.assertEqual(constraints[0]["whenUnsatisfiable"], "DoNotSchedule")
                self.assertEqual(constraints[0]["maxSkew"], 1)
                self.assertEqual(constraints[0]["minDomains"], 2)
                self.assertEqual(constraints[1]["topologyKey"], "topology.kubernetes.io/zone")
                self.assertEqual(constraints[1]["maxSkew"], 1)
                if immutable:
                    self.assertEqual(container["image"], image)
                    self.assertNotIn("command", container)
                    self.assertNotIn("volumes", spec)
                    self.assertNotIn("volumeMounts", container)
                    self.assertNotIn("ConfigMap", [doc["kind"] for doc in docs])
                else:
                    config = next(doc for doc in docs if doc["kind"] == "ConfigMap")
                    source = (ROOT / "src" / "demo" / "server.py").read_text()
                    self.assertEqual(config["data"]["server.py"].rstrip(), source.rstrip())
                service = next(doc for doc in docs if doc["kind"] == "Service")
                self.assertEqual(service["spec"]["loadBalancerSourceRanges"], ["10.10.4.0/24"])
                self.assertEqual(service["metadata"]["annotations"][
                    "service.beta.kubernetes.io/azure-load-balancer-internal"], "true")
                pdb = next(doc for doc in docs if doc["kind"] == "PodDisruptionBudget")
                self.assertEqual(pdb["spec"]["minAvailable"], 1)

    def test_workflow_gates(self):
        workflows = {}
        for path in (ROOT / ".github" / "workflows").glob("*.yml"):
            workflows[path.stem] = yaml.load(path.read_text(), Loader=yaml.BaseLoader)
        validate = workflows["validate"]
        self.assertIn("pull_request", validate["on"])
        self.assertIn("workflow_call", validate["on"])
        self.assertIn("native-bash", validate["jobs"])
        for name, environment in (("deploy", "azure-deployment"), ("release-image", "image-release")):
            workflow = workflows[name]
            self.assertEqual(list(workflow["on"]), ["workflow_dispatch"])
            jobs = workflow["jobs"]
            job = next(job for job in jobs.values() if job.get("environment") == environment)
            self.assertEqual(job["needs"], "validate")
            self.assertIn("required_reviewers", job["steps"][1]["run"])
        release_steps = workflows["release-image"]["jobs"]["image"]["steps"]
        scan_index = next(i for i, step in enumerate(release_steps) if step.get("id") == "image")
        push_index = next(i for i, step in enumerate(release_steps) if "docker push" in step.get("run", ""))
        self.assertLess(scan_index, push_index)
        self.assertIn("--severity HIGH,CRITICAL", release_steps[scan_index]["run"])

    def test_toolchain_and_container_contract(self):
        versions = json.loads((ROOT / "scripts" / "toolchain.json").read_text())
        dockerfile = (ROOT / "src" / "demo" / "Dockerfile").read_text()
        self.assertIn(f"python:{versions['python']}-alpine", dockerfile)
        self.assertIn("USER 10001:10001", dockerfile)
        self.assertIn('CMD ["python", "/app/server.py"]', dockerfile)
        self.assertEqual((ROOT / "src" / "demo" / ".dockerignore").read_text().splitlines()[0], "*")

    def test_platform_hooks_and_script_layout(self):
        project = yaml.safe_load((ROOT / "azure.yaml").read_text())
        for hook, stem in (("preprovision", "pre-provision"), ("postprovision", "post-provision")):
            config = project["hooks"][hook]
            self.assertIn("scripts/ps1/", config["windows"]["run"])
            self.assertEqual(config["posix"]["run"], f"bash ./scripts/bash/{stem}.sh")
        self.assertEqual(list((ROOT / "scripts").glob("*.ps1")), [])
        self.assertTrue((ROOT / "scripts" / "toolchain.json").exists())

    def test_script_documentation_inventory_and_links(self):
        guide = ROOT / "scripts" / "README.md"
        text = guide.read_text()
        for folder, extension in (("ps1", "*.ps1"), ("bash", "*.sh")):
            for script in (ROOT / "scripts" / folder).glob(extension):
                with self.subTest(script=script.name):
                    self.assertIn(f"(./{folder}/{script.name})", text)
        for document in (ROOT / "README.md", guide, ROOT / ".github" / "SECURITY.md"):
            for target in re.findall(r"\[[^\]]+\]\(([^)]+)\)", document.read_text()):
                if target.startswith(("https://", "http://", "#")):
                    continue
                with self.subTest(document=document.name, target=target):
                    self.assertTrue((document.parent / target.split("#", 1)[0]).exists(),
                                    f"Broken documentation link: {target}")


if __name__ == "__main__":
    unittest.main()
