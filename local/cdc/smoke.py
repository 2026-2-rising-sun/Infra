#!/usr/bin/env python3
"""Destructive only within a dedicated, explicitly named cdc-smoke project.

Leaves its isolated stack/data intact for inspection. Does not run Backend/PG.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

from register import request

ROOT = Path(__file__).resolve().parent
TOPIC = "commerce.catalog.snapshots.v1"


def run(command, *, data=None, timeout=180):
    result = subprocess.run(command, input=data, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {command}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def until(fn, timeout=180):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = fn()
            if last:
                return last
        except (OSError, RuntimeError) as error:
            last = str(error)
        time.sleep(2)
    raise AssertionError(f"Condition did not become true: {last}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--connect-url", default="http://127.0.0.1:18083")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if not args.project.startswith("kafka-cdc-smoke-"):
        parser.error("Use a fresh dedicated project named kafka-cdc-smoke-<unique suffix>")
    compose = ["docker", "compose", "-p", args.project, "-f", str(ROOT / "docker-compose.yml")]
    checks = []
    def checked(name, detail=None):
        checks.append({"name": name, "detail": detail})
        print("PASS", name, flush=True)
    def dc(*command, **kwargs):
        return run(compose + list(command), **kwargs)
    def sql(statement):
        return dc("exec", "-T", "postgres", "psql", "-X", "-v", "ON_ERROR_STOP=1",
                  "-U", "cdc_smoke", "-d", "commercecore", "-At", data=statement)
    def kafka(script, *arguments):
        return dc("exec", "-T", "kafka", "/opt/kafka/bin/" + script,
                  "--bootstrap-server", "kafka:9092", *arguments)
    def offsets(topic):
        rows = kafka("kafka-get-offsets.sh", "--topic", topic).splitlines()
        return sum(int(line.rsplit(":", 1)[1]) for line in rows if line.startswith(topic + ":"))
    def status_running():
        state = request(args.connect_url, "/connectors/core-catalog-outbox/status")
        if state["connector"]["state"] == "FAILED" or any(t["state"] == "FAILED" for t in state["tasks"]):
            raise RuntimeError(json.dumps(state))
        return state["connector"]["state"] == "RUNNING" and bool(state["tasks"]) and all(t["state"] == "RUNNING" for t in state["tasks"])
    def literal(text):
        return "'" + text.replace("'", "''") + "'"
    expected = []
    def insert(topic=TOPIC, *, malformed=False):
        event_id = str(uuid.uuid4())
        key = "sku:" + str(uuid.uuid4())
        # Keep byte-for-byte envelope whitespace to detect accidental reserialization.
        payload = json.dumps({"eventId": event_id, "eventType": "InfraSmokeSnapshot",
                              "payload": {"label": '한글 "probe"', "null": None, "quantity": 3}},
                             ensure_ascii=False, separators=(", ", ": "))
        if malformed:
            payload = "not-json: must never be routed"
        sql("INSERT INTO public.event_outbox(event_id,event_type,topic,message_key,payload) VALUES (" +
            ",".join(map(literal, [event_id, "InfraSmokeSnapshot", topic, key, payload])) + ");")
        if topic == TOPIC:
            expected.append((event_id, key, payload))
        return event_id

    dc("config", "--quiet")
    # Must be a fresh stack; never reinterpret app data as the infrastructure fixture.
    assert not dc("ps", "-q", "postgres").strip(), "Project already running; choose a new project"
    dc("up", "-d", "--build", timeout=600)
    checked("independent Compose stack started")
    sql((ROOT / "smoke-schema.sql").read_text())
    dc("exec", "-T", "-e", "CDC_DATABASE_PASSWORD=cdc_replication_local", "postgres", "psql", "-X",
       "-v", "ON_ERROR_STOP=1", "-U", "cdc_smoke", "-d", "commercecore", data=(ROOT / "prepare.sql").read_text())
    checked("logical replication, dedicated read-only role and insert-only single-table publication prepared",
            sql("SHOW wal_level; SELECT puballtables,pubinsert,pubupdate,pubdelete FROM pg_publication WHERE pubname='core_catalog_outbox';"))
    before_topics = kafka("kafka-topics.sh", "--list")
    dc("run", "--rm", "--no-deps", "kafka-init")
    dc("run", "--rm", "--no-deps", "kafka-init")
    # The Connect worker can independently create Kafka's group-offset topic
    # while this check runs. Bootstrap must preserve the application inventory.
    after_topics = kafka("kafka-topics.sh", "--list")
    assert set(before_topics.splitlines()) - {"__consumer_offsets"} == set(after_topics.splitlines()) - {"__consumer_offsets"}
    for line in (ROOT.parent / "init/kafka/topics.tsv").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        topic, partitions, replicas, cleanup, retention = line.split()
        info = kafka("kafka-topics.sh", "--describe", "--topic", topic)
        assert f"PartitionCount: {partitions}" in info and f"ReplicationFactor: {replicas}" in info, info
        assert "cleanup.policy=" + cleanup in info, info
        assert retention == "-" or "retention.ms=" + retention in info, info
    checked("topic bootstrap twice is idempotent; 14 topics have explicit partitions/replication/cleanup/retention")
    insert()  # Existing row must be emitted by initial snapshot.
    insert("commerce.refund.requests.v1", malformed=True)
    config = json.loads((ROOT / "connector.json").read_text())
    config["database.password"] = "cdc_replication_local"
    until(lambda: request(args.connect_url, "/connector-plugins"))
    validation = request(args.connect_url, "/connector-plugins/" + config["connector.class"] + "/config/validate", "PUT", config)
    assert validation["error_count"] == 0, {c["definition"]["name"]: c["value"]["errors"] for c in validation["configs"] if c["value"]["errors"]}
    request(args.connect_url, "/connectors/core-catalog-outbox/config", "PUT", config)
    until(status_running)
    until(lambda: offsets(TOPIC) == 1)
    checked("Connect register and initial snapshot deliver exactly one target row")
    insert()
    until(lambda: offsets(TOPIC) == 2)
    checked("streaming INSERT reaches target topic")
    for other in ["commerce.refund.requests.v1", "commerce.payment-group.v1", "commerce.coupon-info.v1", "commerce.sales-info.v1", "live.broadcast.v1", "payment.refund.results.v1", "payment.execution.results.v1"]:
        insert(other, malformed=True)
    sql("INSERT INTO payment_delivery_request(payload) VALUES ('HTTP_ONLY'); UPDATE event_outbox SET attempts=attempts+1; DELETE FROM event_outbox WHERE topic <> 'commerce.catalog.snapshots.v1';")
    # A following target event is a WAL barrier, so this isn't a timing-only absence assertion.
    insert()
    until(lambda: offsets(TOPIC) == 3)
    for other in ["commerce.refund.requests.v1", "commerce.payment-group.v1", "commerce.coupon-info.v1", "commerce.sales-info.v1", "live.broadcast.v1", "payment.refund.results.v1", "payment.execution.results.v1"]:
        assert offsets(other) == 0, other
    assert "core_catalog_cdc.public.event_outbox" not in kafka("kafka-topics.sh", "--list")
    assert "core_catalog_cdc.public.payment_delivery_request" not in kafka("kafka-topics.sh", "--list")
    checked("7 non-target topics, malformed non-target payloads, HTTP delivery table and UPDATE/DELETE never emitted")
    time.sleep(3)  # offset flush interval is 1s
    dc("stop", "connect")
    insert()
    dc("start", "connect")
    until(status_running)
    until(lambda: offsets(TOPIC) >= 4)
    checked("Connect stop/offline insert/start resumes from retained slot+offset")
    # Preserve broker volume and PostgreSQL slot over a broker process restart too.
    dc("restart", "kafka")
    until(lambda: kafka("kafka-topics.sh", "--list"))
    insert()
    until(status_running)
    until(lambda: offsets(TOPIC) >= 5)
    checked("broker restart retains topics/offsets and connector recovers")
    record_count = offsets(TOPIC)
    messages = kafka("kafka-console-consumer.sh", "--topic", TOPIC, "--from-beginning",
                     "--group", args.project + "-verify-" + uuid.uuid4().hex,
                     "--max-messages", str(record_count), "--timeout-ms", "30000",
                     "--property", "print.headers=true", "--property", "print.key=true")
    records = [line.split("\t", 2) for line in messages.splitlines() if "InfraSmokeSnapshot" in line]
    assert len(records) == record_count, messages
    by_id = {json.loads(value)["eventId"]: (headers, key, value) for headers, key, value in records}
    assert set(by_id) == {event_id for event_id, _, _ in expected}, messages
    for event_id, key, payload in expected:
        headers, actual_key, actual_payload = by_id[event_id]
        assert actual_key == key and actual_payload == payload, (actual_key, actual_payload)
        assert "eventId:" + event_id in headers and "eventType:InfraSmokeSnapshot" in headers, headers
        assert isinstance(json.loads(actual_payload), dict)
    checked("5 event identities preserve exact UTF-8 TEXT envelope bytes, message_key and eventId/eventType headers",
            {"records": record_count, "distinct_events": len(by_id), "at_least_once_duplicates": record_count - len(by_id)})
    dc("cp", str(ROOT / "FilterOrderSmoke.java"), "connect:/tmp/FilterOrderSmoke.java")
    java_result = dc("exec", "-T", "connect", "java", "-Xmx128m", "-cp",
                     "/kafka/libs/*:/kafka/connect/debezium-connector-postgres/*", "/tmp/FilterOrderSmoke.java")
    assert "PASS 5 transform checks" in java_result, java_result
    checked("actual-image Filter/EventRouter order: 5 schema/operation checks", java_result)
    monitoring = sql((ROOT / "monitor.sql").read_text())
    assert "core_catalog_outbox" in monitoring and "event_outbox" in monitoring
    assert sql("SELECT count(*) FROM event_outbox WHERE topic='commerce.catalog.snapshots.v1' AND published_at IS NULL;").strip() == "5"
    checked("slot/WAL/publication/outbox diagnostics execute; CDC leaves published_at unchanged", monitoring)
    summary = {"project": args.project, "checks_passed": len(checks), "failed": 0, "skipped": 0,
               "checks": checks, "scope": "Infrastructure fixtures only; no Backend app or real PG/production validation"}
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
