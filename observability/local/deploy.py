#!/usr/bin/env python3
"""기존 kind에 단일 인스턴스 관측 스택을 생성한다. 기본은 manifest 출력만 한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess

ROOT = Path(__file__).resolve().parent


def run(args, *command, data=None, namespace=None):
    namespace_flags = [] if namespace is False else ['-n', namespace or args.namespace]
    result = subprocess.run(['kubectl', '--context', args.context, *namespace_flags, *command],
                            input=data, capture_output=True, check=True)
    return result.stdout


def manifest(args, kubelets=(), ca_bundle=""):
    ns = args.namespace
    items = [{'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': ns}}]
    def add(kind, name, spec=None, **rest):
        item = dict(apiVersion='apps/v1' if kind == 'Deployment' else 'v1', kind=kind,
                    metadata=dict(name=name, namespace=ns), **rest)
        if spec is not None: item['spec'] = spec
        items.append(item)
        return item
    # 수집기마다 필요한 API만 허용하며 UI/저장소에는 토큰을 주입하지 않는다.
    def rbac(account, rules, namespace=None):
        name = ns + '-' + account
        metadata = dict(name=name)
        if namespace: metadata['namespace'] = namespace
        kind = 'Role' if namespace else 'ClusterRole'
        items.extend([
            dict(apiVersion='rbac.authorization.k8s.io/v1', kind=kind, metadata=metadata, rules=rules),
            dict(apiVersion='rbac.authorization.k8s.io/v1', kind=kind+'Binding', metadata=metadata,
                 roleRef=dict(apiGroup='rbac.authorization.k8s.io', kind=kind, name=name),
                 subjects=[dict(kind='ServiceAccount', name=account, namespace=ns)])])
    read = ['get', 'list', 'watch']
    for account in ['prometheus', 'alloy', 'kube-state-metrics']:
        add('ServiceAccount', account)
    for namespace in [args.app_namespace, ns]:
        rbac('prometheus', [dict(apiGroups=[''], resources=['pods'], verbs=read)], namespace)
        rbac('kube-state-metrics', [dict(apiGroups=[''], resources=['pods'], verbs=read),
             dict(apiGroups=['apps'], resources=['deployments','replicasets','statefulsets','daemonsets'], verbs=read),
             # KEDA 가 만드는 HPA 의 현재/상한 replica 를 읽어 "상한 도달" 알림에 쓴다.
             dict(apiGroups=['autoscaling'], resources=['horizontalpodautoscalers'], verbs=read)], namespace)
    rbac('prometheus', [dict(apiGroups=[''], resources=['nodes'], verbs=read),
         dict(apiGroups=[''], resources=['nodes/metrics'], verbs=['get'])])
    rbac('kube-state-metrics', [dict(apiGroups=[''], resources=['nodes'], verbs=read)])
    rbac('alloy', [dict(apiGroups=[''], resources=['pods'], verbs=read),
         dict(apiGroups=[''], resources=['pods/log'], verbs=['get'])], args.app_namespace)
    add('ConfigMap', 'kubelet-ca', data={'ca.crt': ca_bundle})
    def workload(name, image, ports, command_args=(), configs=None, env=None, storage=False, memory='192Mi', extra=None):
        volumes, mounts = [], []
        for index, (file, dest) in enumerate((configs or {}).items()):
            key = 'config'+str(index)
            content = (ROOT/file).read_text().replace('__APP_NAMESPACE__', args.app_namespace).replace('__OBSERVER_NAMESPACE__', ns)
            add('ConfigMap', name+'-'+key, data={file: content})
            volumes.append(dict(name=key, configMap=dict(name=name+'-'+key)))
            mounts.append(dict(name=key, mountPath=dest, subPath=file))
        if storage:
            add('PersistentVolumeClaim', name, spec=dict(accessModes=['ReadWriteOnce'], resources=dict(requests={'storage':'2Gi'})))
            volumes.append(dict(name='data', persistentVolumeClaim=dict(claimName=name)))
            mounts.append(dict(name='data', mountPath='/var/lib/grafana' if name == 'grafana' else '/data'))
        container = dict(name=name, image=image, args=list(command_args), ports=[dict(containerPort=p) for p in ports],
                         volumeMounts=mounts, env=env or [], resources=dict(requests=dict(cpu='20m',memory='64Mi'),limits=dict(memory=memory)))
        pod = dict(automountServiceAccountToken=name in ['prometheus','alloy','kube-state-metrics'], securityContext=dict(fsGroup=10001), containers=[container], volumes=volumes)
        pod['serviceAccountName'] = name if pod['automountServiceAccountToken'] else 'default'
        if extra: pod.update(extra)
        add('Deployment', name, spec=dict(replicas=1, strategy={'type':'Recreate'}, selector=dict(matchLabels={'app':name}), template=dict(metadata=dict(labels={'app':name},annotations={'shoppinglive/config':hashlib.sha256(json.dumps([i for i in items if i['kind']=='ConfigMap' and i['metadata']['name'].startswith(name+'-')],sort_keys=True).encode()).hexdigest()}),spec=pod)))
        add('Service', name, spec=dict(selector={'app':name},ports=[dict(name='p'+str(p),port=p,targetPort=p) for p in ports]))
    workload('prometheus','prom/prometheus:v3.5.0',[9090],['--config.file=/etc/prometheus/prometheus.yml','--storage.tsdb.path=/data','--storage.tsdb.retention.time=24h','--storage.tsdb.retention.size=1GB'], {'prometheus.yml':'/etc/prometheus/prometheus.yml','alerts.yml':'/etc/prometheus/alerts.yml'}, storage=True,memory='384Mi')
    prometheus = next(i for i in items if i['kind']=='Deployment' and i['metadata']['name']=='prometheus')
    template = prometheus['spec']['template']
    template['metadata']['annotations']['shoppinglive/kubelet-tls'] = hashlib.sha256((ca_bundle+json.dumps(kubelets)).encode()).hexdigest()
    template['spec']['hostAliases'] = list(kubelets)
    template['spec']['volumes'].append(dict(name='kubelet-ca', configMap={'name':'kubelet-ca'}))
    template['spec']['containers'][0]['volumeMounts'].append(dict(name='kubelet-ca', mountPath='/etc/kubelet', readOnly=True))
    # Slack webhook 은 Secret alertmanager-slack 을 파일로 마운트해 읽는다 (alertmanager.yml 의 slack_api_url_file).
    workload('alertmanager','prom/alertmanager:v0.34.1',[9093],['--config.file=/etc/alertmanager/alertmanager.yml','--storage.path=/data'],{'alertmanager.yml':'/etc/alertmanager/alertmanager.yml'},storage=True,memory='128Mi')
    alertmanager = next(i for i in items if i['kind']=='Deployment' and i['metadata']['name']=='alertmanager')
    alertmanager['spec']['template']['spec']['volumes'].append(dict(name='slack', secret=dict(secretName='alertmanager-slack')))
    alertmanager['spec']['template']['spec']['containers'][0]['volumeMounts'].append(dict(name='slack', mountPath='/etc/alertmanager/slack', readOnly=True))
    workload('loki','grafana/loki:3.5.3',[3100],['-config.file=/etc/loki/config.yml'],{'loki.yml':'/etc/loki/config.yml'},storage=True,memory='384Mi')
    workload('tempo','grafana/tempo:2.8.2',[3200,4318],['-config.file=/etc/tempo/config.yml'],{'tempo.yml':'/etc/tempo/config.yml'},storage=True,memory='768Mi',env=[dict(name='GOMEMLIMIT',value='600MiB'),dict(name='GOMAXPROCS',value='2')])
    workload('alloy','grafana/alloy:v1.10.2',[12345,4318],['run','--server.http.listen-addr=0.0.0.0:12345','--storage.path=/data','/etc/alloy/config.alloy'],{'alloy.alloy':'/etc/alloy/config.alloy'},storage=True,memory='192Mi')
    grafana_env = [dict(name='GF_AUTH_ANONYMOUS_ENABLED',value='true'),dict(name='GF_AUTH_ANONYMOUS_ORG_ROLE',value='Viewer'),dict(name='GF_SECURITY_ADMIN_PASSWORD',valueFrom={'secretKeyRef':{'name':'grafana-admin','key':'password'}})]
    dashboards = {str(p.name):'/var/lib/grafana/dashboards/'+p.name for p in ROOT.glob('dashboard-*.json')}
    workload('grafana','grafana/grafana:12.1.1',[3000],configs={'datasources.yml':'/etc/grafana/provisioning/datasources/local.yml','dashboards.yml':'/etc/grafana/provisioning/dashboards/local.yml',**dashboards},env=grafana_env,storage=True,memory='256Mi')
    workload('redis-exporter','oliver006/redis_exporter:v1.77.0',[9121],[f'--redis.addr=redis://redis.{args.app_namespace}.svc.cluster.local:6379'],memory='64Mi')
    workload('kafka-exporter','danielqsj/kafka-exporter:v1.9.0',[9308],[f'--kafka.server=kafka.{args.app_namespace}.svc.cluster.local:9092','--kafka.version=3.9.0','--topic.filter=.*','--group.filter=.*'],memory='96Mi')
    workload('postgres-exporter','quay.io/prometheuscommunity/postgres-exporter:v0.17.1',[9187],['--extend.query-path=/etc/postgres/queries.yml'], {'postgres-queries.yml':'/etc/postgres/queries.yml'},env=[dict(name='DATA_SOURCE_NAME',valueFrom={'secretKeyRef':{'name':'postgres-exporter','key':'dsn'}})],memory='64Mi')
    workload('kube-state-metrics','registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.17.0',[8080],['--resources=pods,deployments,replicasets,statefulsets,daemonsets,nodes,horizontalpodautoscalers',f'--namespaces={args.app_namespace},{ns}'],memory='96Mi')
    workload('node-exporter','prom/node-exporter:v1.9.1',[9100],['--path.rootfs=/host','--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+|var/lib/kubelet/.+)($|/)'],memory='64Mi',extra={'hostPID':True,'volumes':[{'name':'host','hostPath':{'path':'/'}}]})
    node=next(i for i in items if i['kind']=='Deployment' and i['metadata']['name']=='node-exporter')
    node['kind']='DaemonSet'
    node['spec'].pop('replicas')
    node['spec'].pop('strategy')
    node['spec']['template']['spec']['tolerations']=[{'operator':'Exists','effect':'NoSchedule'}]
    node['spec']['template']['spec']['containers'][0]['volumeMounts']=[dict(name='host',mountPath='/host',readOnly=True)]
    # 외부 공개 없이 로컬 port-forward로만 접근한다. kind 단일 노드의 파일시스템을 관측한다.
    return dict(apiVersion='v1',kind='List',items=items)


def secret_exists(args, name):
    return bool(run(args,'get','secret',name,'--ignore-not-found','-o','name'))


def create_secret(args, name, values):
    obj=dict(apiVersion='v1',kind='Secret',metadata=dict(name=name,namespace=args.namespace),stringData=values)
    run(args,'apply','-f','-',data=json.dumps(obj).encode())


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--context',default='kind-shoppinglive-dev')
    parser.add_argument('--app-namespace',default='shoppinglive-fe-dev-integration')
    parser.add_argument('--namespace',default='shoppinglive-observability')
    parser.add_argument('--apply',action='store_true')
    args=parser.parse_args()
    if not args.context.startswith('kind-') or args.app_namespace==args.namespace:
        parser.error('kind 컨텍스트와 별도 관측 네임스페이스가 필요합니다')
    if not args.apply:
        resources=manifest(args)
        print(json.dumps(resources,ensure_ascii=False,indent=2)); return
    # kind 노드의 공개 인증서 체인을 직접 읽어 신뢰한다. 개인 키는 읽지 않는다.
    kind_nodes = subprocess.check_output(['kind','get','nodes','--name',args.context[5:]], text=True).split()
    nodes = json.loads(run(args,'get','nodes','-o','json'))['items']
    if {n['metadata']['name'] for n in nodes} != set(kind_nodes):
        parser.error('선택한 Kubernetes 컨텍스트와 kind 노드가 다릅니다')
    aliases, certificates = [], []
    for node in nodes:
        name = node['metadata']['name']
        address = next(a['address'] for a in node['status']['addresses'] if a['type']=='InternalIP')
        aliases.append(dict(ip=address, hostnames=[name]))
        certificates.append(subprocess.check_output(['docker','exec',name,'cat','/var/lib/kubelet/pki/kubelet.crt'], text=True))
    resources=manifest(args, aliases, '\n'.join(certificates))
    ns=dict(apiVersion='v1',kind='Namespace',metadata=dict(name=args.namespace))
    run(args,'apply','-f','-',data=json.dumps(ns).encode())
    if not secret_exists(args,'grafana-admin'):
        create_secret(args,'grafana-admin',{'password':secrets.token_urlsafe(32)})
    # webhook 이 환경변수로 오면 항상 갱신하고, 없으면 자리표시자를 한 번만 만든다.
    # 자리표시자로는 Slack 전송이 실패하고 Alertmanager 로그에 남는다. 값은 출력하거나 Git 에 저장하지 않는다.
    webhook=os.environ.get('SLACK_WEBHOOK_URL')
    if webhook:
        create_secret(args,'alertmanager-slack',{'url':webhook})
    elif not secret_exists(args,'alertmanager-slack'):
        create_secret(args,'alertmanager-slack',{'url':'https://hooks.slack.com/services/NOT-CONFIGURED'})
        print('SLACK_WEBHOOK_URL 이 없어 Slack 알림은 자리표시자로 둡니다. 설정하려면 SLACK_WEBHOOK_URL=... 로 다시 실행하세요.')
    if not secret_exists(args,'postgres-exporter'):
        password=secrets.token_hex(24)
        # pg_monitor만 부여한다. 실제 비밀번호·연결 문자열은 출력하거나 Git에 저장하지 않는다.
        sql=("SELECT 'CREATE ROLE sl_observer LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='sl_observer')\\gexec\n"
             f"ALTER ROLE sl_observer PASSWORD '{password}';\nGRANT pg_monitor TO sl_observer;\n")
        run(args,'exec','-i','deployment/postgres','--','sh','-c','psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres',data=sql.encode(),namespace=args.app_namespace)
        create_secret(args,'postgres-exporter',{'dsn':f'postgresql://sl_observer:{password}@postgres.{args.app_namespace}.svc.cluster.local:5432/postgres?sslmode=disable'})
    print(run(args,'apply','-f','-',data=json.dumps(resources).encode(),namespace=False).decode())
    # 기존 배포에서 남은 공통 권한도 회수한다. 다른 관측 리소스는 삭제하지 않는다.
    run(args,'delete','clusterrolebinding',args.namespace,'--ignore-not-found')
    run(args,'delete','clusterrole',args.namespace,'--ignore-not-found')
    run(args,'delete','serviceaccount','observer','--ignore-not-found')

if __name__=='__main__': main()
