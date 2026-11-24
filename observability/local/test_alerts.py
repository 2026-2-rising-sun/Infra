"""alerts.yml 문법과 alerts.test.yml 발화/미발화 검사. deploy.py 와 같은 Prometheus 이미지의 promtool 을 쓴다."""
from pathlib import Path
import subprocess
import unittest

HERE = Path(__file__).resolve().parent
PROMTOOL = ["docker", "run", "--rm", "-v", f"{HERE}:/rules:ro", "-w", "/rules",
            "--entrypoint", "promtool", "prom/prometheus:v3.5.0"]


class AlertRulesTest(unittest.TestCase):
    def test_rules_are_valid(self):
        subprocess.run([*PROMTOOL, "check", "rules", "alerts.yml"], check=True)

    def test_rules_fire_as_expected(self):
        subprocess.run([*PROMTOOL, "test", "rules", "alerts.test.yml"], check=True)


if __name__ == "__main__":
    unittest.main()
