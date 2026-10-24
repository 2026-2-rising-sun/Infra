import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("origin_policy", Path(__file__).with_name("origin-policy.py"))
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class OriginPolicyTest(unittest.TestCase):
    def test_정확한_헤더만_허용하고_나머지는_거부한다(self):
        secret = "synthetic-test-secret-not-real-0001"
        result = policy.render({"origin_verify_secret": {"value": secret}}, "shoppinglive-dev")
        self.assertEqual(result["metadata"]["namespace"], "shoppinglive-dev")
        self.assertEqual(result["spec"]["targetRefs"][0]["name"], "shoppinglive")
        authorization = result["spec"]["authorization"]
        self.assertEqual(authorization["defaultAction"], "Deny")
        self.assertEqual(authorization["rules"][0]["principal"]["headers"], [{"name": "X-Origin-Verify", "values": [secret]}])

    def test_빈값이나_약한값을_거부한다(self):
        for secret in ["", "short", "*" * 32, "a\nb" * 32]:
            with self.subTest(secret=secret), self.assertRaises(ValueError):
                policy.render({"origin_verify_secret": {"value": secret}}, "shoppinglive-dev")
