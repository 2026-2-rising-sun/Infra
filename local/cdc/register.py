#!/usr/bin/env python3
"""Validate configuration (including installed SMTs), then idempotently PUT it."""
import argparse
import json
import os
from pathlib import Path
import urllib.request


def request(base, path, method="GET", body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base.rstrip("/") + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as response:
        return json.load(response)


def configuration():
    config = json.loads(Path(__file__).with_name("connector.json").read_text())
    config["database.password"] = os.environ["CDC_DATABASE_PASSWORD"]
    for env, key in [("CDC_DATABASE_HOST", "database.hostname"),
                     ("CDC_DATABASE_NAME", "database.dbname"),
                     ("CDC_SLOT_NAME", "slot.name"),
                     ("CDC_PUBLICATION_NAME", "publication.name")]:
        if env in os.environ:
            config[key] = os.environ[env]
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default=os.getenv("CONNECT_URL", "http://127.0.0.1:18083"))
    parser.add_argument("--name", default="core-catalog-outbox")
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()
    config = configuration()
    config["name"] = args.name
    result = request(args.url, "/connector-plugins/" + config["connector.class"] +
                     "/config/validate", "PUT", config)
    if result["error_count"]:
        # Print validation errors only, never the returned password/config values.
        errors = {c["definition"]["name"]: c["value"]["errors"] for c in result["configs"]
                  if c["value"]["errors"]}
        raise SystemExit(json.dumps(errors))
    print("Connector config validation: 0 errors")
    if not args.validate_only:
        request(args.url, "/connectors/" + args.name + "/config", "PUT", config)
        print("Registered connector:", args.name)


if __name__ == "__main__":
    main()
