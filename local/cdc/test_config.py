"""Cross-surface configuration drift and isolation checks; no cluster writes."""
import json
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


def compose_json(filename, *options):
    return json.loads(subprocess.check_output(
        ["docker", "compose", "-f", str(ROOT / filename), *options,
         "config", "--format", "json"], text=True))


class ConfigurationTest(unittest.TestCase):
    def test_topic_inventory_matches_strimzi_and_preserves_notification_live(self):
        expected = {}
        for line in (ROOT / "local/init/kafka/topics.tsv").read_text().splitlines():
            if line and not line.startswith("#"):
                name, partitions, replicas, cleanup = line.split()
                expected[name] = (int(partitions), int(replicas), cleanup)
        topics = {}
        for document in (ROOT / "k8s/overlays/dev/datatier/kafka.yaml").read_text().split("---"):
            if "kind: KafkaTopic" not in document:
                continue
            name = re.search(r"^  topicName: (.+)$", document, re.M)
            if not name:
                name = re.search(r"^  name: (.+)$", document, re.M)
            partitions = int(re.search(r"^  partitions: (\d+)$", document, re.M)[1])
            replicas = int(re.search(r"^  replicas: (\d+)$", document, re.M)[1])
            cleanup = re.search(r"^    cleanup.policy: (.+)$", document, re.M)
            topics[name[1]] = (partitions, replicas, cleanup[1] if cleanup else "delete")
        self.assertEqual(expected, topics)
        self.assertEqual(11, len(topics))
        for name in ["live.broadcast.v1", "commerce.payment-group.v1", "commerce.coupon-info.v1", "commerce.sales-info.v1"]:
            self.assertIn(name, topics)
        self.assertNotIn("commerce.coupon.events.v1", topics)

    def test_smoke_project_does_not_inherit_shared_names_ports_volumes(self):
        config = compose_json("local/cdc/docker-compose.yml")
        self.assertEqual({"postgres", "kafka", "kafka-init", "connect"}, set(config["services"]))
        for name, service in config["services"].items():
            self.assertNotIn("container_name", service, name)
        ports = {int(p["published"]) for s in config["services"].values() for p in s.get("ports", [])}
        self.assertEqual({15432, 39092, 18083}, ports)
        self.assertEqual({"cdc-postgres", "cdc-kafka"}, set(config["volumes"]))
        self.assertEqual("commercecore", config["services"]["postgres"]["environment"]["POSTGRES_MULTIPLE_DATABASES"])

    def test_connect_worker_internal_topics_fit_one_broker(self):
        config = compose_json("local/docker-compose.yml", "--profile", "cdc")
        env = config["services"]["connect"]["environment"]
        self.assertEqual("/kafka/connect", env["CONNECT_PLUGIN_PATH"])
        # Container SIGKILL must not pre-empt the worker's task cleanup window.
        grace = config["services"]["connect"]["stop_grace_period"]
        seconds = sum(int(value) * {"h": 3600, "m": 60, "s": 1}[unit]
                      for value, unit in re.findall(r"(\d+)([hms])", grace))
        self.assertGreater(seconds, int(env["SHUTDOWN_TIMEOUT"]) / 1000)
        for key in ["CONFIG_STORAGE_REPLICATION_FACTOR", "OFFSET_STORAGE_REPLICATION_FACTOR",
                    "STATUS_STORAGE_REPLICATION_FACTOR", "OFFSET_STORAGE_PARTITIONS", "STATUS_STORAGE_PARTITIONS"]:
            self.assertEqual("1", env["CONNECT_" + key], key)
        self.assertEqual("true", config["services"]["kafka"]["environment"]["KAFKA_AUTO_CREATE_TOPICS_ENABLE"])
        self.assertIn("logical", " ".join(config["services"]["postgres"]["command"]))

    def test_capture_and_converter_boundary(self):
        config = json.loads((ROOT / "local/cdc/connector.json").read_text())
        self.assertEqual("public.event_outbox", config["table.include.list"])
        self.assertEqual("disabled", config["publication.autocreate.mode"])
        self.assertEqual("catalogOnly,outbox", config["transforms"])
        self.assertIn("value.after.topic == 'commerce.catalog.snapshots.v1'", config["transforms.catalogOnly.condition"])
        self.assertEqual("false", config["transforms.outbox.table.expand.json.payload"])
        self.assertEqual("org.apache.kafka.connect.storage.StringConverter", config["value.converter"])
        self.assertEqual("none", config["errors.tolerance"])
        self.assertNotIn("database.password", config)
        self.assertIn("event_id:header:eventId", config["transforms.outbox.table.fields.additional.placement"])

    def test_b_database_uses_reserved_independent_port_and_volume(self):
        config = compose_json("local/cdc/b-postgres.compose.yml")
        self.assertEqual({"postgres"}, set(config["services"]))
        service = config["services"]["postgres"]
        self.assertEqual([("127.0.0.1", "25433", 5432)],
                         [(p["host_ip"], p["published"], p["target"]) for p in service["ports"]])
        self.assertEqual("catalog_cdc_b", service["environment"]["POSTGRES_DB"])
        self.assertEqual({"b-postgres"}, set(config["volumes"]))
        self.assertNotIn("container_name", service)

    def test_c_database_uses_separate_reserved_port_and_volume(self):
        config = compose_json("local/cdc/c-postgres.compose.yml")
        self.assertEqual({"postgres"}, set(config["services"]))
        service = config["services"]["postgres"]
        self.assertEqual([("127.0.0.1", "25434", 5432)],
                         [(p["host_ip"], p["published"], p["target"]) for p in service["ports"]])
        self.assertEqual("core_refunds_c", service["environment"]["POSTGRES_DB"])
        self.assertEqual({"c-postgres"}, set(config["volumes"]))
        self.assertNotIn("container_name", service)

    def test_all_existing_overlays_render_without_cluster(self):
        for overlay in ["dev", "dev/tools", "perf", "demo"]:
            with self.subTest(overlay=overlay):
                subprocess.run(["kubectl", "kustomize", str(ROOT / "k8s/overlays" / overlay)],
                               check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()
