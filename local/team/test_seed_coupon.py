"""기존 쿠폰 이벤트 기록의 재사용을 검증한다."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


class CouponSeedTest(unittest.TestCase):
    def test_existing_event_is_reused_without_creating_coupon(self):
        spec = importlib.util.spec_from_file_location('seed_coupon', Path(__file__).with_name('seed-coupon.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            image = module.products.PRODUCTS[0][3]
            (work/'showcase.json').write_text(json.dumps({'products': {image: {'productId': 12}}}))
            (work/'showcase-coupon.json').write_text(json.dumps({'couponId': 'coupon-1', 'promotionId': 5, 'endsAt': 'later'}))
            events = [{'id': 5, 'status': 'READY', 'attributes': {'couponPolicyId': 'coupon-1'}}]
            def request(path, method='GET', data=None, headers=None):
                if method == 'POST' and path.endswith('/auth/login'):
                    return {'data': {'accessToken': 'test'}}
                self.assertEqual(method, 'GET', '이미 준비된 쿠폰·이벤트를 중복 생성하면 안 된다')
                if path.endswith('/promotions'): return {'data': events}
                if path.endswith('/products'): return {'data': [{'productId': 12}]}
                if path.endswith('/seller/coupons/coupon-1'):
                    return {'data': {'name': '쿠폰', 'fixedDiscount': 2000, 'issuedCount': 0}}
                self.fail(f'예상하지 못한 요청: {path}')
            with patch.object(module, 'work', work), patch.object(module, 'req', side_effect=request), \
                 patch.dict(os.environ, {'BROADCAST_ID': '4'}):
                module.main()
            saved = json.loads((work/'showcase-coupon-4.json').read_text())
            self.assertEqual(saved['couponId'], 'coupon-1')

    def test_unknown_coupon_creation_is_not_repeated(self):
        spec = importlib.util.spec_from_file_location('seed_coupon', Path(__file__).with_name('seed-coupon.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            image = module.products.PRODUCTS[0][3]
            (work/'showcase.json').write_text(json.dumps({'products': {image: {'productId': 12}}}))
            (work/'showcase-coupon-4.json').write_text(json.dumps({'couponCreatePending': True}))
            def request(path, method='GET', data=None, headers=None):
                if path.endswith('/auth/login'): return {'data': {'accessToken': 'test'}}
                self.assertEqual(method, 'GET', '쿠폰 생성 요청을 다시 보내면 안 된다')
                return {'data': [{'productId': 12}] if path.endswith('/products') else []}
            with patch.object(module, 'work', work), patch.object(module, 'req', side_effect=request), \
                 patch.dict(os.environ, {'BROADCAST_ID': '4'}):
                with self.assertRaisesRegex(RuntimeError, '생성 결과가 불확실'):
                    module.main()


if __name__ == '__main__':
    unittest.main()
