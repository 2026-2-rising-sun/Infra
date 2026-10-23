#!/usr/bin/env python3
"""로컬 관측 UI 세 개를 연결한다. Ctrl+C로 이 실행의 연결만 종료한다."""
import signal
import socket
import subprocess
import sys
import time

CONTEXT = 'kind-shoppinglive-dev'
NAMESPACE = 'shoppinglive-observability'
FORWARDS = [('grafana', 13000, 3000), ('kafka-ui', 18080, 8080), ('redisinsight', 15540, 5540)]


def main():
    children = []
    def stop(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    try:
        # 이미 쓰는 포트는 가로채거나 기존 프로세스를 종료하지 않는다.
        for name, port, _ in FORWARDS:
            with socket.socket() as sock:
                try:
                    sock.bind(('127.0.0.1', port))
                except OSError:
                    print(f'{port} 포트가 사용 중입니다. 기존 {name} 화면 http://127.0.0.1:{port} 을 확인하세요.', file=sys.stderr)
                    return 1
        command = ['kubectl', '--context', CONTEXT, '-n', NAMESPACE]
        subprocess.run([*command, 'get', 'service', *[x[0] for x in FORWARDS], '--request-timeout=10s'], check=True, stdout=subprocess.DEVNULL)
        for name, port, target in FORWARDS:
            children.append(subprocess.Popen([*command, 'port-forward', 'svc/'+name, f'{port}:{target}', '--address=127.0.0.1']))
        print('\nUI 연결을 시작합니다. 이 터미널을 유지하고 Ctrl+C로 종료하세요.', flush=True)
        for name, port, _ in FORWARDS:
            print(f'  {name}: http://127.0.0.1:{port}', flush=True)
        while True:
            for (name, _, _), child in zip(FORWARDS, children):
                if child.poll() is not None:
                    print(f'{name} 연결이 종료됐습니다. 위 오류를 확인한 뒤 make ui를 다시 실행하세요.', file=sys.stderr)
                    return 1
            time.sleep(0.5)
    except KeyboardInterrupt:
        print('\n이번 실행에서 만든 UI 연결을 종료합니다. kind와 서비스는 계속 실행됩니다.')
        return 0
    except (OSError, subprocess.CalledProcessError) as error:
        print(f'UI 연결 실패: {error}\nDocker·kind 및 관측 스택 설치 상태를 확인하세요.', file=sys.stderr)
        return 1
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
        for child in children:
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


if __name__ == '__main__':
    sys.exit(main())
