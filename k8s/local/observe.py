#!/usr/bin/env python3
"""기존 kind를 변경하지 않고 조사·백업하고, 별도 관리 UI를 연결한다."""
import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess

SERVICES = ("member", "shopping", "commerce", "live", "notification")


def kubectl(args, *command, data=None, namespaced=True):
    return subprocess.run(
        ["kubectl", "--context", args.context,
         *(["-n", args.namespace] if namespaced else []),
         "--request-timeout=30s", *command], input=data, capture_output=True,
        check=True).stdout


def inventory(args):
    deployments = json.loads(kubectl(args, "get", "deployments", "-o", "json"))
    return {
        "capturedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "context": args.context, "namespace": args.namespace,
        "deployments": [{"name": d["metadata"]["name"],
                         "ready": d["status"].get("readyReplicas", 0),
                         "replicas": d["spec"].get("replicas", 1),
                         "containers": [{"name": c["name"], "image": c["image"],
                                         "resources": c.get("resources", {})}
                                        for c in d["spec"]["template"]["spec"]["containers"]],
                         "volumes": d["spec"]["template"]["spec"].get("volumes", [])}
                        for d in deployments["items"]],
        "services": json.loads(kubectl(args, "get", "services", "-o", "json")),
    }


def tools_manifest(namespace, tools_namespace):
    items = [{"apiVersion": "v1", "kind": "Namespace",
              "metadata": {"name": tools_namespace}}]
    for name, image, port, env in [
        ("kafka-ui", "kafbat/kafka-ui:v1.5.0", 8080,
         {"KAFKA_CLUSTERS_0_NAME": namespace,
          "KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS": f"kafka.{namespace}.svc.cluster.local:9092"}),
        ("redisinsight", "redis/redisinsight:3.8.0", 5540,
         {"RI_REDIS_HOST": f"redis.{namespace}.svc.cluster.local",
          "RI_REDIS_ALIAS": namespace}),
    ]:
        labels = {"app": name, "app.kubernetes.io/managed-by": "shoppinglive-observability"}
        items.extend([
            {"apiVersion": "apps/v1", "kind": "Deployment",
             "metadata": {"name": name, "namespace": tools_namespace},
             "spec": {"replicas": 1, "selector": {"matchLabels": labels},
                      "template": {"metadata": {"labels": labels}, "spec": {"containers": [
                          {"name": name, "image": image, "ports": [{"containerPort": port}],
                           "env": [{"name": k, "value": v} for k, v in env.items()],
                           "resources": {"requests": {"cpu": "25m", "memory": "128Mi"},
                                         "limits": {"memory": "512Mi"}}}]}}}},
            {"apiVersion": "v1", "kind": "Service",
             "metadata": {"name": name, "namespace": tools_namespace},
             "spec": {"selector": labels, "ports": [{"port": port, "targetPort": port}]}},
        ])
    return {"apiVersion": "v1", "kind": "List", "items": items}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["inspect", "backup", "tools"])
    parser.add_argument("--context", default="kind-shoppinglive-dev")
    parser.add_argument("--namespace", default="shoppinglive-fe-dev-integration")
    parser.add_argument("--tools-namespace", default="shoppinglive-observability")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--apply", action="store_true", help="관리 UI만 적용한다")
    args = parser.parse_args()
    if not args.context.startswith("kind-"):
        parser.error("기존 로컬 kind 컨텍스트만 허용합니다")
    if args.action == "tools":
        if args.tools_namespace == args.namespace:
            parser.error("기존 앱과 관리 UI의 네임스페이스를 분리하세요")
        manifest = json.dumps(tools_manifest(args.namespace, args.tools_namespace)).encode()
        print(kubectl(args, "apply", "-f", "-", data=manifest, namespaced=False).decode()
              if args.apply else manifest.decode())
        return
    current = inventory(args)
    if args.action == "inspect":
        print(json.dumps(current, ensure_ascii=False, indent=2))
        return
    if not args.output:
        parser.error("백업을 저장할 --output 경로가 필요합니다")
    # 자격증명이 포함되는 백업은 Git 외부의 새 디렉터리에만 저장한다.
    os.umask(0o077)
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    (args.output / "inventory.json").write_text(json.dumps(current, ensure_ascii=False, indent=2))
    (args.output / "resources.json").write_bytes(
        kubectl(args, "get", "deployments,services,configmaps,secrets", "-o", "json"))
    (args.output / "postgres.sql").write_bytes(
        kubectl(args, "exec", "deployment/postgres", "--", "sh", "-c",
                'pg_dumpall -U "$POSTGRES_USER"'))
    print("백업 완료. resources.json·postgres.sql에는 비밀정보가 있으므로 공유하지 마세요.")
    print("Kafka·Redis는 이 백업에 포함하지 않으며 기존 Pod를 교체하지 않습니다.")


if __name__ == "__main__":
    main()
