#!/usr/bin/env python3
"""지정한 로컬 방송에 쿠폰과 준비 상태 이벤트를 추가한다."""
import datetime
import importlib.util
import json
import os
from pathlib import Path
import uuid

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('products', root/'local/team/seed-products.py')
products = importlib.util.module_from_spec(spec)
spec.loader.exec_module(products)
req = products.request
work = root/'.local-current'
record = None
state = {}

def save():
    record.write_text(json.dumps(state, ensure_ascii=False, indent=2))

def main():
    global record, state
    broadcast_id = os.environ.get('BROADCAST_ID', '')
    if not broadcast_id.isascii() or not broadcast_id.isdigit() or int(broadcast_id) < 1:
        raise RuntimeError('대상 방송 번호를 지정하세요: BROADCAST_ID=4 make local-coupon-seed')
    broadcast_id = str(int(broadcast_id))
    record = work/f'showcase-coupon-{broadcast_id}.json'
    state = json.loads(record.read_text()) if record.exists() else {}
    showcase = json.loads((work/'showcase.json').read_text())
    product_id = showcase['products'][products.PRODUCTS[0][3]]['productId']
    token = req('/member/v1/auth/login', 'POST', {'email':'seller@local.test','password':'seller'})['data']['accessToken']
    auth = {'Authorization':'Bearer '+token}
    path = f'/live/v1/seller/broadcasts/{broadcast_id}/promotions'
    events = req(path, headers=auth)['data']
    legacy = work/'showcase-coupon.json'
    if not state and legacy.exists():
        old = json.loads(legacy.read_text())
        if any(str(event['id']) == str(old.get('promotionId')) and
               event.get('attributes', {}).get('couponPolicyId') == old.get('couponId') for event in events):
            state = old
            save()
    items = req(f'/live/v1/seller/broadcasts/{broadcast_id}/products', headers=auth)['data']
    if str(product_id) not in {str(item['productId']) for item in items}:
        raise RuntimeError('선택한 방송에 대상 토너가 연결되지 않았습니다.')
    if 'couponId' not in state:
        if state.get('couponCreatePending'):
            raise RuntimeError('쿠폰 생성 결과가 불확실합니다. 판매자 쿠폰 목록과 시드 기록을 확인한 뒤 재시도하세요.')
        now = datetime.datetime.now(datetime.timezone.utc)
        state['couponCreatePending'] = True
        save()
        coupon = req('/commerce/v1/seller/coupons','POST',{
            'name':'독도 토너 2,000원 할인', 'fixedDiscount':2000, 'issuanceLimit':100,
            'startsAt':(now-datetime.timedelta(minutes=1)).isoformat(),
            'endsAt':(now+datetime.timedelta(days=1)).isoformat(),
            'expiresAt':(now+datetime.timedelta(days=2)).isoformat(),
            'productIds':[product_id],
        },auth)['data']
        state['couponId'] = coupon['id']; state['endsAt'] = coupon['endsAt']
        state.pop('couponCreatePending'); save()
    if 'promotionId' not in state:
        promotion = req(path,'POST',{
            'type':'COUPON_DROP','title':'독도 토너 2,000원 할인 쿠폰',
            'attributes':{'couponPolicyId':state['couponId']},
        },{**auth,'Idempotency-Key':str(uuid.uuid5(uuid.NAMESPACE_URL,f'shoppinglive-local/broadcast-{broadcast_id}-coupon'))})['data']
        state['promotionId'] = promotion['id']; save()
    coupons = req('/commerce/v1/seller/coupons/'+str(state['couponId']),headers=auth)['data']
    events = req(path,headers=auth)['data']
    event = next((event for event in events if str(event['id']) == str(state['promotionId'])),None)
    if not event:
        raise RuntimeError('저장된 쿠폰 이벤트를 찾을 수 없습니다. 로컬 DB 상태를 확인하세요.')
    print('쿠폰:',coupons['name'], '/ 할인:',coupons['fixedDiscount'],'원 / 발급:',coupons['issuedCount'],'장')
    print('발급 종료:',state['endsAt'],'/ 이벤트 상태:',event['status'])
    print(f'판매자 화면: http://127.0.0.1:6174/seller/lives/{broadcast_id}')

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError,OSError,ValueError,KeyError) as error:
        raise SystemExit(f'쿠폰 시드 실패: {error}') from None
