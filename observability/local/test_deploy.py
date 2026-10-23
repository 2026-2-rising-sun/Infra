"""Strimzi 전환 후에도 환경별 Kafka exporter 주소를 보존한다."""
import json
from pathlib import Path
import subprocess
import sys
import unittest

class KafkaExporterTest(unittest.TestCase):
    def broker(self, *args):
        manifest = json.loads(subprocess.check_output([sys.executable, str(Path(__file__).with_name("deploy.py")), *args]))
        deployment = next(x for x in manifest["items"] if x["kind"] == "Deployment" and x["metadata"]["name"] == "kafka-exporter")
        return deployment["spec"]["template"]["spec"]["containers"][0]["args"][0]

    def test_dev_uses_strimzi_bootstrap(self):
        self.assertEqual(self.broker("--app-namespace", "shoppinglive-dev"), "--kafka.server=kafka-kafka-bootstrap.shoppinglive-dev.svc.cluster.local:9092")

    def test_existing_environment_keeps_broker(self):
        self.assertEqual(self.broker(), "--kafka.server=kafka.shoppinglive-fe-dev-integration.svc.cluster.local:9092")

    def test_explicit_service_override(self):
        self.assertEqual(self.broker("--kafka-service", "custom"), "--kafka.server=custom.shoppinglive-fe-dev-integration.svc.cluster.local:9092")
