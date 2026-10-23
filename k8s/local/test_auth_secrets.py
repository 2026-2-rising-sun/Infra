"""인증 초기화가 지정 컨텍스트와 기존 키를 보존하는지 검증한다."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("auth-secrets.sh")

class AuthSecretsTest(unittest.TestCase):
    def invoke(self, mode, context="kind-isolated-test"):
        with tempfile.TemporaryDirectory() as directory:
            mock = Path(directory) / "kubectl"
            log = Path(directory) / "calls"
            mock.write_text(r"""#!/usr/bin/env python3
import os,sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['CALL_LOG'],'a') as f: f.write(' '.join(args)+'\n')
assert args[:2] == ['--context','kind-isolated-test']
mode=os.environ['MOCK_MODE']
if 'get' in args:
    if mode == 'error': sys.exit(1)
    if 'namespace' in args or mode == 'complete' or (mode == 'partial' and 'member-jwt-private' in args): print('resource/existing')
if 'apply' in args: sys.stdin.read()
""")
            mock.chmod(0o700)
            result = subprocess.run(["sh", str(SCRIPT)], capture_output=True, text=True,
                env={**os.environ, "KUBECTL": str(mock), "KUBE_CONTEXT": context,
                     "CALL_LOG": str(log), "MOCK_MODE": mode})
            return result, log.read_text() if log.exists() else ""

    def test_rejects_non_kind_before_access(self):
        result, calls = self.invoke("fresh", "production")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, "")

    def test_partial_keys_fail_without_mutation(self):
        result, calls = self.invoke("partial")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("create", calls)

    def test_existing_keys_and_tokens_are_preserved(self):
        result, calls = self.invoke("complete")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("create", calls)

    def test_fresh_creates_auth_inputs_in_explicit_context(self):
        result, calls = self.invoke("fresh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count("create secret generic"), 9)
        self.assertEqual(calls.count("create configmap"), 2)

    def test_api_failure_does_not_create_resources(self):
        result, calls = self.invoke("error")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("create", calls)

if __name__ == "__main__":
    unittest.main()
