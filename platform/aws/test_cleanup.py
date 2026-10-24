import subprocess
import unittest
from unittest.mock import patch
import cleanup


class CleanupTest(unittest.TestCase):
    def fixture(self, foreign=None, lb_error=False):
        own = {'metadata': {'name': 'own-envoy', 'namespace': 'shoppinglive-dev', 'labels': {'gateway.envoyproxy.io/owning-gateway-name': 'shoppinglive'}}, 'spec': {'type': 'LoadBalancer'}, 'status': {'loadBalancer': {'ingress': [{'hostname': 'own.example'}]}}}
        calls = []
        lb_reads = 0
        def read(*args):
            nonlocal lb_reads
            calls.append(args)
            if 'applications' in args:
                return {'items': [{'metadata': {'name': foreign or 'root-aws-platform'}}]}
            if 'svc' in args:
                return {'items': [own]}
            if 'nodepools' in args or 'nodeclaims' in args:
                return {'items': []}
            if 'describe-load-balancers' in args:
                lb_reads += 1
                if lb_error and lb_reads > 1:
                    raise subprocess.CalledProcessError(1, args)
                other = {'LoadBalancerArn': 'other', 'DNSName': 'other.example'}
                return {'LoadBalancers': [other] + ([{'LoadBalancerArn': 'own', 'DNSName': 'own.example'}] if lb_reads == 1 else [])}
            if 'describe-instances' in args:
                return {'Reservations': []}
            raise AssertionError(args)
        return calls, read

    def test_자신의_Gateway와_풀만_삭제하고_다른_NLB는_기다리지_않는다(self):
        calls, read = self.fixture()
        with patch.object(cleanup, 'read', side_effect=read), patch.object(cleanup, 'run') as run, patch.object(cleanup.time, 'sleep') as sleep:
            cleanup.cleanup('shoppinglive-dev', 'ap-northeast-2', 'shoppinglive-dev')
        self.assertEqual([c.args for c in run.call_args_list], [
            ('kubectl', '-n', 'shoppinglive-dev', 'delete', 'gateway', 'shoppinglive', '--ignore-not-found', '--timeout=300s'),
            ('kubectl', '-n', 'shoppinglive-dev', 'delete', 'svc', 'own-envoy', '--ignore-not-found', '--timeout=300s'),
            ('kubectl', 'delete', 'nodepool', 'app', 'kafka', '--ignore-not-found', '--timeout=300s')])
        sleep.assert_not_called()

    def test_별도_앱이_있으면_삭제_전에_중단한다(self):
        _, read = self.fixture(foreign='other-team')
        with patch.object(cleanup, 'read', side_effect=read), patch.object(cleanup, 'run') as run, self.assertRaises(RuntimeError):
            cleanup.cleanup('shoppinglive-dev', 'ap-northeast-2', 'shoppinglive-dev')
        run.assert_not_called()

    def test_AWS_조회_실패를_회수_완료로_처리하지_않는다(self):
        _, read = self.fixture(lb_error=True)
        with patch.object(cleanup, 'read', side_effect=read), patch.object(cleanup, 'run') as run, self.assertRaises(subprocess.CalledProcessError):
            cleanup.cleanup('shoppinglive-dev', 'ap-northeast-2', 'shoppinglive-dev')
        self.assertFalse(any('nodepool' in c.args for c in run.call_args_list))

    def test_회수_시간초과는_오류다(self):
        with patch.object(cleanup.time, 'sleep'), self.assertRaises(RuntimeError):
            cleanup.wait_empty(lambda: ['remaining'], 'NLB')
