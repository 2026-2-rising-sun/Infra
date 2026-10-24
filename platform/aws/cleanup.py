#!/usr/bin/env python3
"""이 환경이 만든 Gateway/NLB와 NodePool만 정리한다. 조회 실패·시간 초과 시 중단한다."""
import json
import subprocess
import sys
import time


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def read(*args):
    return json.loads(run(*args))


def wait_empty(query, description):
    for _ in range(30):
        if not query():
            return
        time.sleep(10)
    raise RuntimeError(f"{description} 정리 시간 초과. Terraform destroy를 실행하지 않습니다.")


def cleanup(namespace, region, cluster):
    # 모르는 워크로드가 있으면 삭제 전에 멈춰 대상 환경을 다시 확인한다.
    apps = read('kubectl', '-n', 'argocd', 'get', 'applications', '-o', 'json')['items']
    known = {'root-aws-platform', 'envoy-gateway', 'strimzi', 'keda'}
    if any(a['metadata']['name'] not in known for a in apps):
        raise RuntimeError('별도 ArgoCD 앱이 있습니다. 먼저 해당 앱의 정리 절차를 수행하세요.')
    services = read('kubectl', 'get', 'svc', '-A', '-o', 'json')['items']
    lbs = [s for s in services if s['spec'].get('type') == 'LoadBalancer']
    def owned(s):
        meta = s['metadata']
        return meta['namespace'] == namespace and meta.get('labels', {}).get('gateway.envoyproxy.io/owning-gateway-name') == 'shoppinglive'
    if any(not owned(s) for s in lbs):
        raise RuntimeError('이 Gateway 외의 LoadBalancer가 있습니다. 자동 삭제를 중단합니다.')
    pools = read('kubectl', 'get', 'nodepools', '-o', 'json')['items']
    if any(p['metadata']['name'] not in {'app', 'kafka'} for p in pools):
        raise RuntimeError('별도 NodePool이 있습니다. 자동 삭제를 중단합니다.')
    hostnames = {i['hostname'] for s in lbs for i in s.get('status', {}).get('loadBalancer', {}).get('ingress', []) if 'hostname' in i}
    def load_balancers():
        return read('aws', 'elbv2', 'describe-load-balancers', '--region', region, '--output', 'json')['LoadBalancers']
    owned_arns = {lb['LoadBalancerArn'] for lb in load_balancers() if lb['DNSName'] in hostnames}

    # Gateway부터 지워 Envoy가 Service를 다시 만들지 못하게 한다. 컨트롤러는 회수 완료까지 유지한다.
    run('kubectl', '-n', namespace, 'delete', 'gateway', 'shoppinglive', '--ignore-not-found', '--timeout=300s')
    for service in lbs:
        run('kubectl', '-n', namespace, 'delete', 'svc', service['metadata']['name'], '--ignore-not-found', '--timeout=300s')
    wait_empty(lambda: [lb for lb in load_balancers() if lb['LoadBalancerArn'] in owned_arns], 'NLB')
    run('kubectl', 'delete', 'nodepool', 'app', 'kafka', '--ignore-not-found', '--timeout=300s')
    wait_empty(lambda: read('kubectl', 'get', 'nodeclaims', '-l', 'karpenter.sh/nodepool in (app,kafka)', '-o', 'json')['items'], 'NodeClaim')
    # NodeClaim이 없어졌어도 남은 EC2가 있다면 destroy를 막는다.
    wait_empty(lambda: [i for r in read('aws', 'ec2', 'describe-instances', '--region', region, '--filters',
        f'Name=tag:eks:eks-cluster-name,Values={cluster}', 'Name=tag:karpenter.sh/nodepool,Values=app,kafka',
        'Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down', '--output', 'json')['Reservations'] for i in r['Instances']], 'Karpenter EC2')


if __name__ == '__main__':
    cleanup(*sys.argv[1:])
