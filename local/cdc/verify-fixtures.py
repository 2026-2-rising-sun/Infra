#!/usr/bin/env python3
"""Send the contract owner's three exact JSON examples through a smoke connector.

Run after smoke.py. This tests transport only, not application producers/consumers.
"""
import argparse
import hashlib
import json
from pathlib import Path
import uuid

from smoke import ROOT, TOPIC, run, until


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--examples", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, help="Optional actual-producer handoff manifest")
    parser.add_argument("--source-root", type=Path, help="Read-only producer repository for source hash checks")
    args = parser.parse_args()
    if not args.project.startswith("kafka-cdc-smoke-"):
        parser.error("Only dedicated kafka-cdc-smoke-* projects are allowed")
    compose = ["docker", "compose", "-p", args.project, "-f", str(ROOT / "docker-compose.yml")]
    def dc(*command, **kwargs):
        return run(compose + list(command), **kwargs)
    def sql(statement):
        return dc("exec", "-T", "postgres", "psql", "-X", "-v", "ON_ERROR_STOP=1",
                  "-U", "cdc_smoke", "-d", "commercecore", "-At", data=statement)
    def literal(value):
        return "'" + value.replace("'", "''") + "'"
    def kafka(script, *arguments):
        return dc("exec", "-T", "kafka", "/opt/kafka/bin/" + script,
                  "--bootstrap-server", "kafka:9092", *arguments)
    def count():
        return sum(int(line.rsplit(":", 1)[1]) for line in
                   kafka("kafka-get-offsets.sh", "--topic", TOPIC).splitlines() if line.startswith(TOPIC + ":"))
    manifest = None
    manifest_sha = None
    verified_sources = []
    if args.manifest:
        if not args.source_root:
            parser.error("--manifest requires --source-root")
        raw_manifest = args.manifest.read_bytes()
        manifest_sha = hashlib.sha256(raw_manifest).hexdigest()
        manifest = json.loads(raw_manifest)
        for source in manifest.get("sources", []):
            producer_source = args.source_root / source["path"]
            assert hashlib.sha256(producer_source.read_bytes()).hexdigest() == source["sha256"], "Producer changed: request a fresh manifest"
            verified_sources.append(source)
    expected = []
    for event_type in ["ProductSnapshotChanged", "SkuSnapshotChanged", "InventorySnapshotChanged"]:
        example = args.examples / (event_type + ".json")
        raw = example.read_bytes()
        envelope = json.loads(raw)
        assert envelope["eventType"] == event_type
        assert envelope["aggregateId"].startswith(("product:", "sku:"))
        event_id = envelope["eventId"]
        producer = None
        if manifest:
            producer = next(item for item in manifest["files"] if item["eventType"] == event_type)
            assert hashlib.sha256(raw).hexdigest() == producer["sha256"], "Fixture changed: request a fresh manifest"
            assert envelope["aggregateId"] == producer["key"]
            if "source" in producer:
                producer_source = args.source_root / producer["source"]
                assert hashlib.sha256(producer_source.read_bytes()).hexdigest() == producer["source_sha256"], "Producer changed: request a fresh manifest"
        assert sql("SELECT count(*) FROM event_outbox WHERE event_id=" + literal(event_id) + ";").strip() == "0", "Already inserted; use a fresh project"
        expected.append({"path": str(example), "sha256": hashlib.sha256(raw).hexdigest(),
                         "event_id": event_id, "event_type": event_type,
                         "key": envelope["aggregateId"], "body": raw.decode("utf-8"),
                         "producer_source": None if not producer else producer.get("source"),
                         "producer_source_sha256": None if not producer else producer.get("source_sha256")})
    before = count()
    for item in expected:
        sql("INSERT INTO event_outbox(event_id,event_type,topic,message_key,payload) VALUES (" +
            ",".join(map(literal, [item["event_id"], item["event_type"], TOPIC, item["key"], item["body"]])) + ");")
    until(lambda: count() >= before + 3)
    total = count()
    messages = kafka("kafka-console-consumer.sh", "--topic", TOPIC, "--from-beginning",
                     "--group", args.project + "-contracts-" + uuid.uuid4().hex,
                     "--max-messages", str(total), "--timeout-ms", "30000",
                     "--property", "print.headers=true", "--property", "print.key=true",
                     "--property", "line.separator=\x1e")
    records = [item.split("\t", 2) for item in messages.split("\x1e") if item]
    assert len(records) == total, (len(records), total)
    by_id = {json.loads(body)["eventId"]: (headers, key, body) for headers, key, body in records}
    for item in expected:
        headers, key, body = by_id[item["event_id"]]
        assert key == item["key"] and body.encode() == item["body"].encode(), item["event_type"]
        assert "eventId:" + item["event_id"] in headers, headers
        assert "eventType:" + item["event_type"] in headers, headers
        assert isinstance(json.loads(body), dict)
        del item["body"]
    report = {"passed": 3, "failed": 0, "skipped": 0, "project": args.project,
              "scope": "Exact contract examples inserted as infrastructure fixtures; no Backend app execution",
              "manifest_sha256": manifest_sha,
              "revision": None if not manifest else manifest.get("revision"),
              "verified_sources": verified_sources,
              "fixture_origin_evidence": None if not manifest else manifest["evidence"],
              "fixture_origin_command": None if not manifest else manifest["command"],
              "fixtures": expected}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
