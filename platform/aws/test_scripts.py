import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ScriptsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scripts = self.root / 'platform/aws'
        self.scripts.mkdir(parents=True)
        for name in ['common.sh', 'down.sh']:
            shutil.copy(Path(__file__).with_name(name), self.scripts / name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'calls.jsonl'
        self.original = self.root / 'original-kubeconfig'
        self.original.write_text('other-work-context')
        self.env = {**os.environ, 'PATH': str(self.bin) + os.pathsep + os.environ['PATH'], 'KUBECONFIG': str(self.original), 'TEST_LOG': str(self.log)}
        # 외부 명령을 모두 가짜 실행 파일로 대체한다. AWS/Kubernetes에 연결하지 않는다.
        stub = '''#!/usr/bin/env python3
import json,os,sys,pathlib
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['TEST_LOG'],'a') as f: f.write(json.dumps({'name':name,'args':args,'kubeconfig':os.environ.get('KUBECONFIG')})+'\\n')
if name=='terraform' and 'output' in args:
 if '-json' in args: print(json.dumps({'origin_verify_secret':{'value':'synthetic-test-secret-not-real-0001'}}))
 else: print({'cluster_name':'test-cluster','aws_region':'ap-northeast-2','cluster_arn':'arn:test:cluster','karpenter_node_role_name':'test-node','karpenter_interruption_queue':'test-queue','nlb_security_group_id':'sg-test','origin_certificate_arn':'arn:test:certificate'}[args[-1]])
if name=='aws' and 'describe-cluster' in args: print('vpc-test' if 'cluster.resourcesVpcConfig.vpcId' in args else 'arn:test:cluster')
if name=='aws' and 'update-kubeconfig' in args: pathlib.Path(args[args.index('--kubeconfig')+1]).write_text('temporary')
'''
        # python3 자리에 같은 shebang을 쓰면 재귀하므로 인터프리터 절대 경로를 고정한다.
        import sys
        stub = stub.replace('#!/usr/bin/env python3', '#!' + sys.executable)
        stub += '''
if name=='kubectl' and 'crd' in args and os.environ.get('FAIL_CRD'): sys.exit(1)
if name=='kubectl' and 'create' in args: print('apiVersion: v1')
if (name=='kubectl' and 'apply' in args and '-' in args) or (name=='helm' and '--values' in args and '-' in args):
 data=sys.stdin.read()
 with open(os.environ['TEST_LOG'],'a') as f: f.write(json.dumps({'name':'stdin','args':[], 'body':data})+'\\n')
'''
        for name in ['terraform', 'aws', 'kubectl', 'helm', 'sleep']:
            p = self.bin / name
            p.write_text(stub)
            p.chmod(0o755)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_사용자_접속설정을_보존하고_임시파일을_정리한다(self):
        result = subprocess.run(['bash', '-c', 'set -euo pipefail; source "$1"; aws_context', 'test', str(self.scripts / 'common.sh')], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        update = next(c for c in self.calls() if 'update-kubeconfig' in c['args'])
        self.assertNotEqual(update['kubeconfig'], str(self.original))
        self.assertFalse(Path(update['kubeconfig']).exists())
        self.assertEqual(self.original.read_text(), 'other-work-context')

    def test_정리_실패_후에는_destroy를_실행하지_않는다(self):
        p = self.bin / 'python3'
        p.write_text('#!/bin/sh\nexit 42\n')
        p.chmod(0o755)
        result = subprocess.run(['bash', str(self.scripts / 'down.sh')], input='test-cluster\n', env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertFalse(any('destroy' in c['args'] for c in self.calls()))
        self.assertEqual(self.original.read_text(), 'other-work-context')

    def test_대상명_불일치시_삭제하지_않는다(self):
        result = subprocess.run(['bash', str(self.scripts / 'down.sh')], input='other-cluster\n', env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('destroy' in c['args'] for c in self.calls()))

    def install(self, failed=False):
        source = Path(__file__).parent
        shutil.copytree(source, self.scripts, dirs_exist_ok=True)
        shutil.copytree(source.parents[1] / 'argocd', self.root / 'argocd')
        (self.scripts / 'rds-init.sh').write_text('#!/bin/sh\nexit 0\n')
        if failed:
            self.env['FAIL_CRD'] = '1'
        return subprocess.run(['bash', str(self.scripts / 'install.sh')], env=self.env, capture_output=True, text=True)

    def test_원본검증정책을_Gateway보다_먼저_적용한다(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        bodies = [c['body'] for c in self.calls() if c['name'] == 'stdin']
        policy = next(i for i, body in enumerate(bodies) if 'SecurityPolicy' in body)
        gateway = next(i for i, body in enumerate(bodies) if 'kind: Gateway\n' in body)
        self.assertLess(policy, gateway)
        self.assertFalse(any('platform/kind' in str(c) for c in self.calls()))

    def test_CRD_대기실패시_Gateway를_만들지_않는다(self):
        result = self.install(failed=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('kind: Gateway\n' in c.get('body', '') for c in self.calls()))
