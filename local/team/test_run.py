"""기존 사용자 환경과 실행 프로세스 보호 규칙을 검증한다."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import run


class TeamEnvironmentSafetyTest(unittest.TestCase):
    def test_local_config_is_separate_and_pins_commits(self):
        """최신 로컬 구성은 팀 환경과 클러스터·포트를 공유하지 않는다."""
        config = json.loads((Path(__file__).with_name('versions-local.json')).read_text())
        self.assertNotEqual(config['cluster'], run.CONFIG['cluster'])
        self.assertNotEqual(config['namespace'], run.CONFIG['namespace'])
        self.assertTrue(set(config['ports'].values()).isdisjoint(run.CONFIG['ports'].values()))
        for name in ('backend', 'frontend'):
            self.assertRegex(config[name]['commit'], r'^[0-9a-f]{40}$')

    def test_occupied_port_is_not_taken_over(self):
        """다른 프로세스가 쓰는 포트를 뺏지 않고 실행을 중단한다."""
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            with self.assertRaisesRegex(RuntimeError, '포트가 사용 중'):
                run.free_ports([listener.getsockname()[1]])
            self.assertGreater(listener.fileno(), 0)

    def test_existing_cluster_without_ownership_is_untouched(self):
        """설치 기록 없는 동명 클러스터는 생성·변경하지 않는다."""
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(run, 'WORK', Path(directory)), patch.object(run, 'state', return_value={}), \
                 patch.object(run, 'prerequisites'), patch.object(run, 'checkout'), \
                 patch.object(run, 'run', return_value=run.CONFIG['cluster']) as command:
                with self.assertRaisesRegex(RuntimeError, '소유 기록'):
                    run.setup()
                command.assert_called_once_with('kind', 'get', 'clusters', capture=True)

    def test_stop_requires_owned_cluster(self):
        """중지 명령도 소유 기록이 없는 클러스터를 건드리지 않는다."""
        with patch.object(run, 'state', return_value={}), patch.object(run, 'run') as command:
            with self.assertRaisesRegex(RuntimeError, '소유 기록'):
                run.stop()
            command.assert_not_called()

    def test_coupon_seed_requires_explicit_broadcast_id(self):
        """쿠폰 시드는 지정되지 않은 방송에 쿠폰을 만들지 않는다."""
        env = dict(os.environ)
        env.pop('BROADCAST_ID', None)
        result = subprocess.run([sys.executable, str(Path(__file__).with_name('seed-coupon.py'))],
                                capture_output=True, text=True, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('대상 방송 번호를 지정', result.stderr)

    def test_failed_start_cleans_up_only_owned_children(self):
        """실행 중 실패해도 이 명령이 만든 자식 프로세스는 회수한다."""
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(run, 'WORK', Path(directory)):
                with self.assertRaisesRegex(RuntimeError, '검증용 실패'):
                    with run.processes() as (launch, children):
                        child = launch('test', [sys.executable, '-c', 'import time; time.sleep(60)'])
                        raise RuntimeError('검증용 실패')
                self.assertIsNotNone(child.poll())


if __name__ == '__main__':
    unittest.main()
