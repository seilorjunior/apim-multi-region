from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PublicReleaseTests(unittest.TestCase):
    def test_license_and_security_policy(self):
        license_text = (ROOT / "LICENSE").read_text()
        self.assertIn("MIT License", license_text)
        self.assertIn("Permission is hereby granted, free of charge", license_text)
        self.assertIn("apim-multi-region contributors", license_text)
        policy = (ROOT / ".github" / "SECURITY.md").read_text()
        self.assertIn("private vulnerability reporting", policy)
        self.assertIn("Revoke/rotate", policy)

    def test_public_documentation_has_no_live_azure_endpoints(self):
        documents = [ROOT / "README.md", ROOT / "scripts" / "README.md",
                     ROOT / ".github" / "SECURITY.md"]
        documents.extend((ROOT / "docs").rglob("*.md"))
        documents.extend((ROOT / "docs").rglob("*.svg"))
        live_endpoint = re.compile(
            r"https?://[a-z0-9][a-z0-9.-]*\.(?:azurefd\.net|azure-api\.net)\b", re.IGNORECASE)
        for document in documents:
            with self.subTest(document=document.relative_to(ROOT)):
                self.assertIsNone(live_endpoint.search(document.read_text()),
                                  "Use a placeholder or environment-derived URL in public documentation.")

    @unittest.skipUnless(shutil.which("git"), "Git is required to verify publication ignore rules.")
    def test_private_artifacts_are_excluded_from_publication(self):
        ignored = [
            ".azure/deployment-plan.md", ".azure/config.json", ".azure/sample/.env",
            ".env", ".env.production", "src/.env.local", "TestResults/failover.json",
            "operator.pem", "operator.key", "operator.pfx", "operator.p12",
            "kubeconfig", "kubeconfig.backup", "operator.kubeconfig", ".kube/config",
            "terraform.tfstate", "terraform.tfstate.backup", "deployment.tfplan",
        ]
        public = ["README.md", "LICENSE", ".github/SECURITY.md",
                  "infra/main.bicep", "infra/main.parameters.json", "k8s/demo.yaml",
                  "scripts/toolchain.json", "scripts/ps1/Common.ps1",
                  "scripts/bash/common.sh", ".env.example"]
        with tempfile.TemporaryDirectory(prefix="apim-publication-") as directory:
            metadata = Path(directory) / "metadata"
            subprocess.run(["git", "init", "--quiet", str(metadata)],
                           check=True, capture_output=True, text=True)
            command = ["git", "--git-dir", str(metadata / ".git"), "--work-tree", str(ROOT)]
            result = subprocess.run(command + ["check-ignore", "--no-index", "--stdin", "-z"],
                                    input=("\0".join(ignored + public) + "\0").encode(), cwd=ROOT,
                                    check=True, capture_output=True)
            self.assertEqual(set(result.stdout.decode().split("\0")[:-1]), set(ignored))
            candidates = subprocess.run(command + ["ls-files", "--others", "--exclude-standard", "-z"],
                                        cwd=ROOT, check=True, capture_output=True)
            paths = candidates.stdout.decode().split("\0")[:-1]
            self.assertIn("LICENSE", paths)
            self.assertIn(".github/SECURITY.md", paths)
            self.assertFalse(any(path.startswith((".azure/", "TestResults/")) for path in paths))


if __name__ == "__main__":
    unittest.main()
