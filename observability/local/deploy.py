#!/usr/bin/env python3
"""기존 kind에 단일 인스턴스 관측 스택을 생성한다. 기본은 manifest 출력만 한다."""
import argparse
import hashlib
import json
from pathlib import Path
import secrets
import subprocess

ROOT = Path(__file__).resolve().parent


def run(args, *command, data=None, namespace=None):
    result = subprocess.run(['kubectl', '--context', args.context,
                             '-n', namespace or args.namespace, *command],
                            input=data, capture_output=True, check=True)
    return result.stdout


def manifest(args):
    ns = args.namespace
    items = [{'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': ns}}]
    def add(kind, name, spec=None, **rest):
        item = dict(apiVersion='apps/v1' if kind == 'Deployment' else 'v1', kind=kind,
                    metadata=dict(name=name, namespace=ns), **rest)
        if spec is not None: item['spec'] = spec
        items.append(item)
        return item
    add('ServiceAccount', 'observer')
    rules = [dict(apiGroups=[''], resources=['pods', 'pods/log', 'services', 'endpoints', 'nodes', 'nodes/proxy'], verbs=['get', 'list', 'watch']),
             dict(apiGroups=['apps'], resources=['deployments', 'replicasets', 'statefulsets', 'daemonsets'], verbs=['get', 'list', 'watch'])]
    items += [dict(apiVersion='rbac.authorization.k8s.io/v1', kind='ClusterRole', metadata={'name': ns}, rules=rules),
              dict(apiVersion='rbac.authorization.k8s.io/v1', kind='ClusterRoleBinding', metadata={'name': ns}, roleRef=dict(apiGroup='rbac.authorization.k8s.io', kind='ClusterRole', name=ns), subjects=[dict(kind='ServiceAccount', name='observer', namespace=ns)])]
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
        pod = dict(serviceAccountName='observer', securityContext=dict(fsGroup=10001), containers=[container], volumes=volumes)
        if extra: pod.update(extra)
        add('Deployment', name, spec=dict(replicas=1, strategy={'type':'Recreate'}, selector=dict(matchLabels={'app':name}), template=dict(metadata=dict(labels={'app':name},annotations={'shoppinglive/config':hashlib.sha256(json.dumps([i for i in items if i['kind']=='ConfigMap' and i['metadata']['name'].startswith(name+'-')],sort_keys=True).encode()).hexdigest()}),spec=pod)))
        add('Service', name, spec=dict(selector={'app':name},ports=[dict(name='p'+str(p),port=p,targetPort=p) for p in ports]))
    workload('prometheus','prom/prometheus:v3.5.0',[9090],['--config.file=/etc/prometheus/prometheus.yml','--storage.tsdb.path=/data','--storage.tsdb.retention.time=24h','--storage.tsdb.retention.size=1GB'], {'prometheus.yml':'/etc/prometheus/prometheus.yml'}, storage=True,memory='384Mi')
    workload('loki','grafana/loki:3.5.3',[3100],['-config.file=/etc/loki/config.yml'],{'loki.yml':'/etc/loki/config.yml'},storage=True,memory='384Mi')
    workload('tempo','grafana/tempo:2.8.2',[3200,4318],['-config.file=/etc/tempo/config.yml'],{'tempo.yml':'/etc/tempo/config.yml'},storage=True,memory='256Mi')
    workload('alloy','grafana/alloy:v1.10.2',[12345,4318],['run','--server.http.listen-addr=0.0.0.0:12345','--storage.path=/data','/etc/alloy/config.alloy'],{'alloy.alloy':'/etc/alloy/config.alloy'},storage=True,memory='192Mi')
    grafana_env = [dict(name='GF_AUTH_ANONYMOUS_ENABLED',value='true'),dict(name='GF_AUTH_ANONYMOUS_ORG_ROLE',value='Viewer'),dict(name='GF_SECURITY_ADMIN_PASSWORD',valueFrom={'secretKeyRef':{'name':'grafana-admin','key':'password'}})]
    dashboards = {str(p.name):'/var/lib/grafana/dashboards/'+p.name for p in ROOT.glob('dashboard-*.json')}
    workload('grafana','grafana/grafana:12.1.1',[3000],configs={'datasources.yml':'/etc/grafana/provisioning/datasources/local.yml','dashboards.yml':'/etc/grafana/provisioning/dashboards/local.yml',**dashboards},env=grafana_env,storage=True,memory='256Mi')
    workload('redis-exporter','oliver006/redis_exporter:v1.77.0',[9121],[f'--redis.addr=redis://redis.{args.app_namespace}.svc.cluster.local:6379'],memory='64Mi')
    workload('kafka-exporter','danielqsj/kafka-exporter:v1.9.0',[9308],[f'--kafka.server=kafka.{args.app_namespace}.svc.cluster.local:9092','--kafka.version=3.9.0','--topic.filter=.*','--group.filter=.*'],memory='96Mi')
    workload('postgres-exporter','quay.io/prometheuscommunity/postgres-exporter:v0.17.1',[9187],['--extend.query-path=/etc/postgres/queries.yml'], {'postgres-queries.yml':'/etc/postgres/queries.yml'},env=[dict(name='DATA_SOURCE_NAME',valueFrom={'secretKeyRef':{'name':'postgres-exporter','key':'dsn'}})],memory='64Mi')
    workload('kube-state-metrics','registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.17.0',[8080],['--resources=pods,deployments,replicasets,statefulsets,daemonsets,nodes',f'--namespaces={args.app_namespace},{ns}'],memory='96Mi')
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
    resources=manifest(args)
    if not args.apply:
        print(json.dumps(resources,ensure_ascii=False,indent=2)); return
    ns=dict(apiVersion='v1',kind='Namespace',metadata=dict(name=args.namespace))
    run(args,'apply','-f','-',data=json.dumps(ns).encode())
    if not secret_exists(args,'grafana-admin'):
        create_secret(args,'grafana-admin',{'password':secrets.token_urlsafe(32)})
    if not secret_exists(args,'postgres-exporter'):
        password=secrets.token_hex(24)
        # pg_monitor만 부여한다. 실제 비밀번호·연결 문자열은 출력하거나 Git에 저장하지 않는다.
        sql=("SELECT 'CREATE ROLE sl_observer LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='sl_observer')\\gexec\n"
             f"ALTER ROLE sl_observer PASSWORD '{password}';\nGRANT pg_monitor TO sl_observer;\n")
        run(args,'exec','-i','deployment/postgres','--','sh','-c','psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres',data=sql.encode(),namespace=args.app_namespace)
        create_secret(args,'postgres-exporter',{'dsn':f'postgresql://sl_observer:{password}@postgres.{args.app_namespace}.svc.cluster.local:5432/postgres?sslmode=disable'})
    print(run(args,'apply','-f','-',data=json.dumps(resources).encode()).decode())

if __name__=='__main__': main()
