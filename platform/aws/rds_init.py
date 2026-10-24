#!/usr/bin/env python3
"""자신이 만든 일회성 Secret/Pod만 정리하며 비밀번호를 인자나 로그에 노출하지 않는다."""
import json
from pathlib import Path
import subprocess
import sys
import uuid


def capture(*args):
    return subprocess.check_output(args, text=True).strip()


def initialize(tf_dir, region, namespace):
    address = capture('terraform', f'-chdir={tf_dir}', 'output', '-raw', 'rds_address')
    arn = capture('terraform', f'-chdir={tf_dir}', 'output', '-raw', 'rds_master_user_secret_arn')
    credentials = json.loads(capture('aws', 'secretsmanager', 'get-secret-value', '--secret-id', arn, '--region', region, '--query', 'SecretString', '--output', 'text'))
    name = 'rds-init-' + uuid.uuid4().hex[:12]
    meta = {'name': name, 'namespace': namespace}
    secret = {'apiVersion': 'v1', 'kind': 'Secret', 'metadata': meta, 'stringData': {
        'PGUSER': credentials['username'], 'PGPASSWORD': credentials['password'],
        'init.sql': Path(__file__).with_name('rds').joinpath('init.sql').read_text()}}
    pod = {'apiVersion': 'v1', 'kind': 'Pod', 'metadata': meta, 'spec': {
        'restartPolicy': 'Never', 'activeDeadlineSeconds': 300,
        'nodeSelector': {'shoppinglive.io/node-role': 'system'},
        'volumes': [{'name': 'init', 'secret': {'secretName': name, 'items': [{'key': 'init.sql', 'path': 'init.sql'}]}}],
        'containers': [{'name': 'psql', 'image': 'postgres:17-alpine',
            'command': ['psql', '-v', 'ON_ERROR_STOP=1', '-f', '/init/init.sql'],
            'volumeMounts': [{'name': 'init', 'mountPath': '/init', 'readOnly': True}],
            'env': [{'name': key, 'valueFrom': {'secretKeyRef': {'name': name, 'key': key}}} for key in ['PGUSER', 'PGPASSWORD']] + [{'name': 'PGHOST', 'value': address}, {'name': 'PGDATABASE', 'value': 'postgres'}, {'name': 'PGSSLMODE', 'value': 'require'}],
            'resources': {'requests': {'cpu': '50m', 'memory': '64Mi'}, 'limits': {'memory': '256Mi'}}}]}}
    try:
        # create는 last-applied 어노테이션에 비밀번호를 중복 저장하지 않는다.
        subprocess.run(['kubectl', 'create', '-f', '-'], input=json.dumps(secret), text=True, check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['kubectl', 'create', '-f', '-'], input=json.dumps(pod), text=True, check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['kubectl', '-n', namespace, 'wait', '--for=jsonpath={.status.phase}=Succeeded', f'pod/{name}', '--timeout=320s'], check=True)
    finally:
        subprocess.run(['kubectl', '-n', namespace, 'delete', 'pod,secret', name, '--ignore-not-found', '--timeout=60s'], check=True)


if __name__ == '__main__':
    initialize(*sys.argv[1:])
