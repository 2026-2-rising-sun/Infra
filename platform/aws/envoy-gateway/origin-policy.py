#!/usr/bin/env python3
"""비밀값을 명령행 인자로 노출하지 않고 오리진 검증 정책을 렌더링한다."""
import json
import re
import sys


def render(outputs, namespace):
    secret = outputs["origin_verify_secret"]["value"]
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,}", secret):
        raise ValueError("오리진 검증 값 형식이 잘못되었습니다")
    return {
        "apiVersion": "gateway.envoyproxy.io/v1alpha1", "kind": "SecurityPolicy",
        "metadata": {"name": "cloudfront-origin", "namespace": namespace},
        "spec": {
            "targetRefs": [{"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": "shoppinglive"}],
            "authorization": {"defaultAction": "Deny", "rules": [{
                "name": "cloudfront", "action": "Allow", "principal": {
                    "headers": [{"name": "X-Origin-Verify", "values": [secret]}]
                }
            }]}
        }
    }


if __name__ == "__main__":
    json.dump(render(json.load(sys.stdin), sys.argv[1]), sys.stdout)
