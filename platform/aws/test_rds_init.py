import json
import subprocess
import unittest
from unittest.mock import patch
import rds_init


class RdsInitTest(unittest.TestCase):
    def execute(self, failed=False):
        calls = []
        def run(args, **kwargs):
            calls.append((args, kwargs))
            if failed and 'wait' in args:
                raise subprocess.CalledProcessError(1, args)
        with patch.object(rds_init, 'capture', side_effect=['db.internal', 'secret-arn', json.dumps({'username': 'postgres', 'password': 'synthetic-password'})]), patch.object(rds_init.subprocess, 'run', side_effect=run):
            if failed:
                with self.assertRaises(subprocess.CalledProcessError):
                    rds_init.initialize('/test', 'ap-northeast-2', 'shoppinglive-dev')
            else:
                rds_init.initialize('/test', 'ap-northeast-2', 'shoppinglive-dev')
        return calls

    def test_비밀번호는_인자가_아닌_Secret으로_전달한다(self):
        calls = self.execute()
        self.assertNotIn('synthetic-password', str([a for a, _ in calls]))
        secret = json.loads(calls[0][1]['input'])
        pod = json.loads(calls[1][1]['input'])
        self.assertEqual(secret['stringData']['PGPASSWORD'], 'synthetic-password')
        self.assertIn('\\gexec', secret['stringData']['init.sql'])
        self.assertEqual(pod['spec']['containers'][0]['command'][-2:], ['-f', '/init/init.sql'])
        self.assertEqual(pod['spec']['containers'][0]['env'][1]['valueFrom']['secretKeyRef']['name'], secret['metadata']['name'])
        self.assertEqual(calls[-1][0][3:5], ['delete', 'pod,secret'])

    def test_초기화_실패해도_자신의_Secret과_Pod만_정리한다(self):
        calls = self.execute(failed=True)
        secret = json.loads(calls[0][1]['input'])
        self.assertIn(secret['metadata']['name'], calls[-1][0])
        self.assertNotIn('--all', calls[-1][0])
