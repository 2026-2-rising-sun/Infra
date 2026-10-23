"""새 팀 환경에 상품·진행 중인 stub 방송을 한 번 준비한다."""
import base64
from contextlib import ExitStack
import datetime
import json
import socket
import subprocess
import time
import urllib.error
import urllib.request
import uuid

PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF1cAAAAASUVORK5CYII=')


def seed(config, env, work):
    record = work/'sample.json'
    saved = json.loads(record.read_text()) if record.exists() else {}
    def save():
        temporary = record.with_suffix('.tmp')
        temporary.write_text(json.dumps(saved, indent=2))
        temporary.replace(record)
    with ExitStack() as stack:
        endpoints = {}
        for service in ['member', 'shopping', 'commerce', 'live']:
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            log = stack.enter_context((work/('seed-'+service+'.log')).open('a'))
            proc = subprocess.Popen(['kubectl', '--context', 'kind-'+config['cluster'], '-n', config['namespace'],
                                     'port-forward', 'svc/'+service, f'{port}:8080', '--address=127.0.0.1'],
                                    env=env, stdout=log, stderr=subprocess.STDOUT)
            def stop(child=proc):
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            stack.callback(stop)
            for _ in range(60):
                if proc.poll() is not None:
                    raise RuntimeError(f'{service} 샘플 연결 실패. .local-team/seed-{service}.log 확인')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.5):
                        break
                except OSError:
                    time.sleep(.5)
            else:
                raise RuntimeError(f'{service} 연결 시간 초과')
            endpoints[service] = f'http://127.0.0.1:{port}'
        def api(service, path, method='GET', body=None, headers=None):
            h = dict(headers or {})
            if body is not None and not isinstance(body, bytes):
                h['Content-Type'] = 'application/json'
                body = json.dumps(body).encode()
            request = urllib.request.Request(endpoints[service]+path, data=body, headers=h, method=method)
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    raw = response.read()
                    return json.loads(raw) if raw else None
            except urllib.error.HTTPError as error:
                # 요청 헤더·토큰은 출력하지 않는다.
                raise RuntimeError(f'샘플 {service} {method} {path}: HTTP {error.code} {error.read().decode()[:500]}') from None
        token = api('member', '/v1/auth/login', 'POST', {'email':'seller@local.test','password':'seller'})['data']['accessToken']
        auth = {'Authorization':'Bearer '+token}
        if saved.get('complete'):
            api('shopping', f'/v1/products/{saved["productId"]}')
            api('live', f'/v1/broadcasts/{saved["liveId"]}')
            return saved
        if 'imageId' not in saved:
            boundary = 'shoppinglive-'+uuid.uuid4().hex
            body = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="sample.png"\r\nContent-Type: image/png\r\n\r\n'.encode()+PNG+f'\r\n--{boundary}--\r\n'.encode())
            saved['imageId'] = api('shopping', '/v1/seller/product-images', 'POST', body,
                                    {**auth, 'Content-Type':'multipart/form-data; boundary='+boundary})['data']['imageId']
            save()
        if 'productId' not in saved:
            saved['productId'] = api('shopping', '/v1/seller/products', 'POST',
                {'name':'로컬 체험 상품','description':'Mock 구매·환불·Kafka 이벤트 확인용 상품','mainImageId':saved['imageId']},
                {**auth,'X-Idempotency-Key':str(uuid.uuid5(uuid.NAMESPACE_URL, config['cluster']+'/sample-product'))})['data']['productId']
            save()
        if 'salesId' not in saved:
            # 중단 후 재실행에서도 이미 등록된 판매정보를 복구한다.
            credentials = json.loads((work/'Frontend/test-artifacts/kind/credentials.json').read_text())
            existing = api('commerce', '/v1/sales?productIds='+str(saved['productId']),
                           headers={'X-Service-Token': credentials['env']['SHOPPING_COMMERCE_SERVICE_TOKEN']})
            if existing:
                saved['salesId'] = existing[0]['salesId']
            else:
                saved['salesId'] = api('commerce','/v1/sales','POST',{'productId':saved['productId'],'price':10000,'initialStock':100},auth)['id']
            save()
        if not saved.get('sale_ready'):
            api('commerce',f'/v1/sales/{saved["salesId"]}/status','PATCH',{'status':'ON_SALE'},auth)
            saved['sale_ready'] = True
            save()
        if 'liveId' not in saved:
            scheduled = (datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=1)).isoformat()
            saved['liveId'] = api('live','/v1/seller/broadcasts','POST',
                {'title':'로컬 체험 방송','scheduledAt':scheduled,
                 'channelArn':'arn:aws:ivs:ap-northeast-2:123456789012:channel/localdemo',
                 'playbackUrl':'https://stub.live-video.net/localdemo.m3u8'},
                {**auth,'Idempotency-Key':str(uuid.uuid5(uuid.NAMESPACE_URL,config['cluster']+'/sample-live'))})['data']['id']
            save()
        live_path = f'/v1/seller/broadcasts/{saved["liveId"]}'
        detail = api('live',live_path,headers=auth)['data']
        products = api('live',live_path+'/products',headers=auth)['data']
        if not any(str(p['productId']) == str(saved['productId']) for p in products):
            api('live',live_path+'/products','POST',{'productId':saved['productId'],'expectedVersion':detail['version']},auth)
        detail = api('live',live_path,headers=auth)['data']
        if detail['status'] != 'LIVE':
            api('live',live_path+'/start?expectedVersion='+str(detail['version']),'POST',headers=auth)
        saved['complete'] = True
        save()
        return saved
