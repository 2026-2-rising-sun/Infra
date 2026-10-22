#!/usr/bin/env python3
"""고정된 원격 소스로 팀 로컬 환경을 설치하고 실행한다."""
import argparse
import base64
from contextlib import contextmanager
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
CONFIG = json.loads((Path(__file__).with_name('versions.json')).read_text())
WORK = ROOT / '.local-team'
STATE = WORK / 'state.json'
CONTEXT = 'kind-' + CONFIG['cluster']
SERVICES = ['member', 'shopping', 'commerce', 'live', 'notification']
ENV = dict(os.environ, KUBECONFIG=str(WORK / 'kubeconfig'))


def run(*args, cwd=ROOT, capture=False, env=ENV):
    return subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True,
                          text=True, stdout=subprocess.PIPE if capture else None).stdout


def kubectl(*args, namespace=None, capture=False):
    return run('kubectl', '--context', CONTEXT, '-n', namespace or CONFIG['namespace'],
               '--request-timeout=30s', *args, capture=capture)


def state():
    return json.loads(STATE.read_text()) if STATE.exists() else {}


def save(values):
    # 비밀번호·키·백업은 전부 Git에서 제외된 보호 디렉터리에 저장한다.
    WORK.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = STATE.with_suffix('.tmp')
    temporary.write_text(json.dumps(values, ensure_ascii=False, indent=2))
    temporary.replace(STATE)


def prerequisites(build=False):
    for binary in ['docker', 'kind', 'kubectl', 'git', 'node', 'npm']:
        if not shutil.which(binary):
            raise RuntimeError(f'{binary}가 없습니다. 실행 가이드의 준비물을 먼저 설치하세요.')
    run('docker', 'info', '--format', '{{.ServerVersion}}', capture=True)
    if int(run('node', '--version', capture=True).strip().lstrip('v').split('.')[0]) < 24:
        raise RuntimeError('Node.js 24 이상이 필요합니다.')
    if build:
        candidates = [os.environ.get('JAVA_HOME'), '/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home',
                      '/usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home']
        for candidate in candidates:
            if candidate and (Path(candidate) / 'bin/java').exists():
                detected = subprocess.run([str(Path(candidate)/'bin/java'), '-version'], capture_output=True, text=True)
                if detected.returncode == 0 and re.search(r'version "21[.\"]', detected.stderr + detected.stdout):
                    ENV['JAVA_HOME'] = candidate
                    break
        java = str(Path(ENV['JAVA_HOME']) / 'bin/java') if ENV.get('JAVA_HOME') else 'java'
        version = subprocess.run([java, '-version'], capture_output=True, text=True)
        if version.returncode or not re.search(r'version "21[.\"]', version.stderr + version.stdout):
            raise RuntimeError('Java 21을 설치하고 JAVA_HOME을 지정하세요.')


def checkout(name):
    target = WORK / name.capitalize()
    spec = CONFIG[name]
    if not target.exists():
        run('git', 'clone', '--no-checkout', spec['url'], target)
        run('git', 'checkout', '--detach', spec['commit'], cwd=target)
    if run('git', 'rev-parse', 'HEAD', cwd=target, capture=True).strip() != spec['commit']:
        raise RuntimeError(f'{target}의 커밋이 versions.json과 다릅니다. 사용자 파일을 덮어쓰지 않습니다.')
    if run('git', 'status', '--porcelain', cwd=target, capture=True).strip():
        raise RuntimeError(f'{target}에 변경이 있습니다. 별도 개발 작업 공간으로 보존하고 다시 시도하세요.')
    return target


def require_cluster():
    data = state()
    if not data.get('cluster_owned') or not (WORK / 'kubeconfig').exists():
        raise RuntimeError('먼저 make setup을 실행하세요. 기존 개발 클러스터를 대신 변경하지 않습니다.')
    nodes = run('kind', 'get', 'nodes', '--name', CONFIG['cluster'], capture=True).split()
    if not nodes:
        raise RuntimeError('설치 기록은 있지만 kind 노드가 없습니다. 클러스터 삭제 여부를 확인하세요.')
    for node in nodes:
        if run('docker', 'inspect', '--format', '{{.State.Running}}', node, capture=True).strip() != 'true':
            run('docker', 'start', node)
    kubectl('wait', '--for=condition=Ready', 'node', '--all', '--timeout=180s')


def wait_apps():
    for name in ['postgres', 'redis', 'kafka', *SERVICES]:
        kubectl('rollout', 'status', 'deployment/'+name, '--timeout=300s')


def setup():
    prerequisites(build=True)
    WORK.mkdir(mode=0o700, parents=True, exist_ok=True)
    data = state()
    backend, frontend = checkout('backend'), checkout('frontend')
    clusters = run('kind', 'get', 'clusters', capture=True).split()
    if CONFIG['cluster'] in clusters and not data.get('cluster_owned'):
        raise RuntimeError('같은 이름의 기존 클러스터가 있습니다. 소유 기록이 없어 변경하지 않습니다.')
    if CONFIG['cluster'] not in clusters:
        if data.get('cluster_owned'):
            raise RuntimeError('기존 클러스터가 삭제되었습니다. 백업·데이터 상태를 먼저 확인하세요.')
        run('kind', 'create', 'cluster', '--name', CONFIG['cluster'], '--kubeconfig', WORK/'kubeconfig', '--image', CONFIG['node_image'], '--wait', '180s')
        data['cluster_owned'] = True
        save(data)
    require_cluster()
    if not data.get('base_installed'):
        print('공용 인프라와 백엔드 5개를 처음 설치합니다.', flush=True)
        deploy_env = dict(ENV, BACKEND_DIR=str(backend), KIND_CONTEXT=CONTEXT,
                          KIND_NAMESPACE=CONFIG['namespace'], KIND_KAFKA='true')
        run('node', 'scripts/kind-local.mjs', cwd=frontend, env=deploy_env)
        data['base_installed'] = True
        save(data)
    wait_apps()
    run(sys.executable, ROOT/'k8s/local/observe.py', 'tools', '--context', CONTEXT,
        '--namespace', CONFIG['namespace'], '--tools-namespace', CONFIG['observer_namespace'], '--apply')
    run(sys.executable, ROOT/'observability/local/deploy.py', '--context', CONTEXT,
        '--app-namespace', CONFIG['namespace'], '--namespace', CONFIG['observer_namespace'], '--apply')
    if data.get('instrumented_backend') != CONFIG['backend']['commit']:
        backup = WORK/'backups'/datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
        run(sys.executable, ROOT/'observability/local/instrument.py', '--backend', backend,
            '--backup', backup, '--context', CONTEXT, '--namespace', CONFIG['namespace'],
            '--observer-namespace', CONFIG['observer_namespace'], '--apply')
        data['instrumented_backend'] = CONFIG['backend']['commit']
        save(data)
    deployments = json.loads(kubectl('get', 'deployments', '-o', 'json', namespace=CONFIG['observer_namespace'], capture=True))
    for item in deployments['items']:
        kubectl('rollout', 'status', 'deployment/'+item['metadata']['name'], '--timeout=300s', namespace=CONFIG['observer_namespace'])
    kubectl('rollout', 'status', 'daemonset/node-exporter', '--timeout=180s', namespace=CONFIG['observer_namespace'])
    if not (frontend/'node_modules').exists():
        run('npm', 'ci', cwd=frontend)
    from seed import seed
    data['sample'] = seed(CONFIG, ENV, WORK)
    data['ready'] = True
    save(data)
    print('\n설치 완료. make start로 프론트와 관리 UI를 함께 연결하세요.', flush=True)
    print('테스트 로그인: user / user, seller / seller')


def free_ports(ports):
    for port in ports:
        with socket.socket() as sock:
            try:
                sock.bind(('127.0.0.1', port))
            except OSError:
                raise RuntimeError(f'{port} 포트가 사용 중입니다. 기존 실행을 종료하거나 PORT_OFFSET=1000 make start를 사용하세요.')


@contextmanager
def processes():
    children, files = [], []
    logdir = WORK/'logs'
    logdir.mkdir(parents=True, exist_ok=True)
    def start(name, command, cwd=ROOT, env=ENV):
        log = (logdir/(name+'.log')).open('a')
        files.append(log)
        child = subprocess.Popen([str(c) for c in command], cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT)
        children.append((name, child))
        return child
    try:
        yield start, children
    finally:
        for _, child in children:
            if child.poll() is None:
                child.terminate()
        for _, child in children:
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        for log in files:
            log.close()


def alive(children):
    for name, child in children:
        if child.poll() is not None:
            raise RuntimeError(f'{name}이 종료되었습니다. {WORK}/logs/{name}.log를 확인하세요.')


def wait_http(url, children):
    deadline = time.monotonic()+60
    while time.monotonic() < deadline:
        alive(children)
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                if response.status == 200:
                    return
        except OSError:
            time.sleep(.5)
    raise RuntimeError(f'{url} 응답을 기다리다 종료했습니다. .local-team/logs를 확인하세요.')


def start(only_ui=False):
    if only_ui and not STATE.exists():
        # 기존 1단계 환경의 make ui 사용도 유지한다.
        run(sys.executable, ROOT/'observability/local/ui.py')
        return
    prerequisites()
    require_cluster()
    if not state().get('ready'):
        raise RuntimeError('최초 설치가 완료되지 않았습니다. make setup을 다시 실행하세요.')
    frontend = checkout('frontend')
    offset = int(os.environ.get('PORT_OFFSET', '0'))
    ports = {name: port+offset for name, port in CONFIG['ports'].items()}
    ui = [('grafana', 3000), ('kafka-ui', 8080), ('redisinsight', 5540)]
    required = [ports[name] for name, _ in ui]
    if not only_ui:
        required += [ports['frontend'], *range(ports['api'], ports['api']+5)]
    if any(p < 1024 or p > 65535 for p in required):
        raise RuntimeError('PORT_OFFSET으로 지정한 포트 범위가 잘못됐습니다.')
    free_ports(required)
    urls = {name: f'http://127.0.0.1:{ports[name]}' for name, _ in ui}
    with processes() as (launch, children):
        def forward(name, port, target, namespace):
            launch(name, ['kubectl', '--context', CONTEXT, '-n', namespace, 'port-forward',
                          'svc/'+name, f'{port}:{target}', '--address=127.0.0.1'])
        for name, target in ui:
            forward(name, ports[name], target, CONFIG['observer_namespace'])
        if not only_ui:
            wait_apps()
            env = dict(ENV)
            for index, name in enumerate(SERVICES):
                port = ports['api']+index
                forward(name, port, 8080, CONFIG['namespace'])
                env[name.upper()+'_URL'] = f'http://127.0.0.1:{port}'
            launch('frontend', [frontend/'node_modules/.bin/vite', '--host', '127.0.0.1',
                               '--port', ports['frontend'], '--strictPort'], cwd=frontend, env=env)
            urls['frontend'] = f'http://127.0.0.1:{ports["frontend"]}'
        for name, url in urls.items():
            wait_http(url, children)
            print(f'{name}: {url}', flush=True)
        if not only_ui:
            sample = state()['sample']
            print(f'상품: {urls["frontend"]}/products/{sample["productId"]}', flush=True)
            print(f'방송: {urls["frontend"]}/lives/{sample["liveId"]}', flush=True)
        print('연결 완료. Ctrl+C로 프론트·UI 연결만 종료합니다. kind·데이터는 유지합니다.', flush=True)
        while True:
            alive(children)
            time.sleep(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['setup', 'start', 'ui', 'status', 'grafana-login'])
    args = parser.parse_args()
    os.umask(0o077)
    def interrupt(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupt)
    try:
        if args.command == 'setup':
            setup()
        elif args.command in ['start', 'ui']:
            start(args.command == 'ui')
        else:
            if not STATE.exists():
                raise RuntimeError('설치 기록이 없습니다. make setup부터 실행하세요.')
            if args.command == 'grafana-login':
                secret = json.loads(kubectl('get', 'secret/grafana-admin', '-o', 'json',
                                           namespace=CONFIG['observer_namespace'], capture=True))
                print('Grafana 사용자: admin')
                print('Grafana 비밀번호: ' + base64.b64decode(secret['data']['password']).decode())
                print('이 로컬 환경의 비밀번호입니다. 문서·메신저에 복사하지 마세요.')
            else:
                for namespace in [CONFIG['namespace'], CONFIG['observer_namespace']]:
                    kubectl('get', 'pods', namespace=namespace)
    except KeyboardInterrupt:
        print('\n실행을 종료했습니다. 데이터와 클러스터는 삭제하지 않았습니다.')
        return 130 if args.command == 'setup' else 0
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'실행 실패: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
