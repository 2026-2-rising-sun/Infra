#!/usr/bin/env python3
"""실제 상품을 참고한 로컬 시연 데이터. 기존 상품과 주문은 건드리지 않는다."""
import json
from pathlib import Path
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / '.local-current'
RECORD = WORK / 'showcase.json'
BASE = 'http://127.0.0.1:6174/api'
PRODUCTS = [
    ('라운드랩 1025 독도 토너 200ml', '가볍게 닦아내고 수분을 채우는 데일리 토너', 13500, '39a271609a8788ab6cfc0c644ac85088.jpg'),
    ('라운드랩 1025 독도 로션 200ml', '산뜻하게 바르는 데일리 보습 로션', 17900, '2dd888803d6d54c8b485b169485230e7.jpg'),
    ('라운드랩 1025 독도 클렌저 150ml', '풍성한 거품으로 세안하는 약산성 클렌저', 10900, 'bf2a60867cb8d63b9f31b409818dd822.jpg'),
]
IMAGE_URL = 'https://roundlab.co.kr/web/product/medium/202511/'


def request(path, method='GET', data=None, headers=None, raw=False):
    headers = dict(headers or {})
    if data is not None and not isinstance(data, bytes):
        data = json.dumps(data, ensure_ascii=False).encode()
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            result = response.read()
            return result if raw else json.loads(result) if result else None
    except urllib.error.HTTPError as error:
        raise RuntimeError(f'{path}: HTTP {error.code} {error.read().decode()[:400]}') from None


def upload(path, image, auth):
    boundary = 'shoppinglive-' + uuid.uuid4().hex
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="product.jpg"\r\n'
            f'Content-Type: image/jpeg\r\n\r\n').encode() + image + f'\r\n--{boundary}--\r\n'.encode()
    return request(path, 'POST', body, {**auth, 'Content-Type': f'multipart/form-data; boundary={boundary}'})['data']


def main():
    if not (WORK / 'state.json').exists():
        raise RuntimeError('먼저 make local-setup과 make local-start를 실행하세요.')
    state = json.loads(RECORD.read_text()) if RECORD.exists() else {'products': {}}
    def save():
        RECORD.write_text(json.dumps(state, ensure_ascii=False, indent=2))
    token = request('/member/v1/auth/login', 'POST', {'email': 'seller@local.test', 'password': 'seller'})['data']['accessToken']
    auth = {'Authorization': 'Bearer ' + token}
    images = WORK / 'showcase-images'
    images.mkdir(exist_ok=True)
    for name, description, price, filename in PRODUCTS:
        item = state['products'].setdefault(filename, {})
        image_file = images / filename
        if not image_file.exists():
            with urllib.request.urlopen(IMAGE_URL + filename, timeout=30) as response:
                image_file.write_bytes(response.read())
        if 'imageId' not in item:
            item['imageId'] = upload('/shopping/v1/seller/product-images', image_file.read_bytes(), auth)['imageId']; save()
        if 'productId' not in item:
            key = str(uuid.uuid5(uuid.NAMESPACE_URL, 'shoppinglive-local/showcase/' + filename))
            result = request('/shopping/v1/seller/products', 'POST', {'name': name, 'description': description, 'mainImageId': item['imageId']}, {**auth, 'X-Idempotency-Key': key})
            item['productId'] = result['data']['productId']; save()
        if 'salesId' not in item:
            credentials = json.loads((WORK/'Frontend/test-artifacts/kind/credentials.json').read_text())
            existing = request(f"/commerce/v1/sales?productIds={item['productId']}", headers={
                'X-Service-Token': credentials['env']['SHOPPING_COMMERCE_SERVICE_TOKEN']})
            if existing:
                item['salesId'] = existing[0]['salesId']
            else:
                result = request('/commerce/v1/sales', 'POST', {'productId': item['productId'], 'price': price, 'initialStock': 100}, auth)
                item['salesId'] = result['id']
            save()
        if not item.get('onSale'):
            request(f"/commerce/v1/sales/{item['salesId']}/status", 'PATCH', {'status': 'ON_SALE'}, auth)
            item['onSale'] = True; save()
    if 'thumbnailId' not in state:
        state['thumbnailId'] = upload('/live/v1/seller/broadcast-thumbnails', (images / PRODUCTS[0][3]).read_bytes(), auth)['thumbnailId']; save()
    if 'broadcastId' not in state:
        result = request('/live/v1/seller/broadcasts', 'POST', {
            'title': '오늘의 스킨케어 루틴 | 독도 라인 라이브', 'hostName': '쇼핑라이브',
            'description': '토너부터 로션, 클렌저까지 데일리 스킨케어 루틴을 함께 살펴보세요.',
            'scheduledAt': '2026-10-31T12:00:00Z', 'thumbnailId': state['thumbnailId'],
            'channelArn': 'arn:aws:ivs:ap-northeast-2:123456789012:channel/skincare',
            'playbackUrl': 'https://stub.live-video.net/skincare.m3u8',
        }, {**auth, 'Idempotency-Key': str(uuid.uuid5(uuid.NAMESPACE_URL, 'shoppinglive-local/showcase/broadcast'))})
        state['broadcastId'] = result['data']['id']; save()
    path = '/live/v1/seller/broadcasts/' + str(state['broadcastId'])
    existing = request(path + '/products', headers=auth)['data']
    linked = {str(product['productId']) for product in existing}
    for item in state['products'].values():
        if str(item['productId']) not in linked:
            detail = request(path, headers=auth)['data']
            request(path + '/products', 'POST', {'productId': item['productId'], 'expectedVersion': detail['version']}, auth)
    detail = request(path, headers=auth)['data']
    if detail['status'] == 'PREPARING':
        request(path + '/start?expectedVersion=' + str(detail['version']), 'POST', headers=auth)
    elif detail['status'] != 'LIVE':
        raise RuntimeError('시연 방송이 종료된 상태입니다. 기존 방송을 삭제하거나 자동 재생성하지 않습니다.')
    print(f"시연 방송: http://127.0.0.1:6174/lives/{state['broadcastId']}")
    print('상품 가격은 시연용이며 실제 판매가나 행사와 관계없습니다.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        raise SystemExit(f'시드 실패: {error}') from None
