#!/usr/bin/env python3
"""빌드된 Backend JAR를 계측 이미지로 만들고 기존 kind 앱만 교체한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request

AGENT_URL='https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.20.0/opentelemetry-javaagent.jar'
AGENT_SHA256='191666bf4346ab0677f92304bb272cd85f5954f49c03bb9636134e59c9a3276d'
SERVICES=['member','shopping','commerce','live','notification']


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--backend',type=Path,required=True)
    p.add_argument('--backup',type=Path,required=True,help='Git 밖에 새로 생성할 보호 디렉터리')
    p.add_argument('--context',default='kind-shoppinglive-dev')
    p.add_argument('--namespace',default='shoppinglive-fe-dev-integration')
    p.add_argument('--observer-namespace',default='shoppinglive-observability')
    p.add_argument('--services',nargs='+',choices=SERVICES,default=SERVICES)
    p.add_argument('--apply',action='store_true')
    a=p.parse_args()
    if not a.context.startswith('kind-'): p.error('로컬 kind만 허용합니다')
    def cmd(*args, data=None):
        return subprocess.run(list(args),input=data,capture_output=True,check=True).stdout
    def k(*args,data=None): return cmd('kubectl','--context',a.context,'-n',a.namespace,*args,data=data)
    if cmd('git','-C',str(a.backend),'status','--porcelain').strip(): p.error('Backend 변경을 커밋하고 같은 소스의 bootJar를 준비하세요')
    sha=cmd('git','-C',str(a.backend),'rev-parse','HEAD').decode().strip()
    if not a.apply:
        print(json.dumps(dict(backend=str(a.backend),commit=sha,services=a.services,namespace=a.namespace,backup=str(a.backup)),indent=2)); return
    cmd(str(a.backend/'gradlew'),'-p',str(a.backend),*[f':services:{service}-service:bootJar' for service in a.services],'--no-daemon','--max-workers=2')
    os.umask(0o077)
    a.backup.mkdir(mode=0o700,parents=True,exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='sl-instrument-') as temporary:
        work=Path(temporary)
        agent=work/'agent.jar'
        urllib.request.urlretrieve(AGENT_URL,agent)
        if hashlib.sha256(agent.read_bytes()).hexdigest()!=AGENT_SHA256: raise RuntimeError('OTel agent 체크섬 불일치')
        (work/'Dockerfile').write_text('FROM eclipse-temurin:21-jdk\nCOPY app.jar /app.jar\nCOPY agent.jar /otel/agent.jar\nENTRYPOINT ["java","-jar","/app.jar"]\n')
        for service in a.services:
            current=json.loads(k('get','deployment',service,'-o','json'))
            (a.backup/(service+'.json')).write_text(json.dumps(current))
            # 업로드 파일이 emptyDir에 있는 기존 환경을 보존한다.
            images=k('exec','deployment/'+service,'--','tar','-C','/tmp/images','-cf','-','.')
            (a.backup/(service+'-images.tar')).write_bytes(images)
            jars=[f for f in (a.backend/'services'/(service+'-service')/'build/libs').glob('*.jar') if not f.name.endswith('-plain.jar')]
            if len(jars)!=1: raise RuntimeError(service+': bootJar 하나가 필요합니다')
            shutil.copyfile(jars[0],work/'app.jar')
            image=f'shoppinglive-observability/{service}:{sha[:12]}'
            cmd('docker','build','-t',image,str(work))
            cmd('kind','load','docker-image',image,'--name',a.context[5:])
            container=current['spec']['template']['spec']['containers'][0]
            existing={e['name']:e.get('value','') for e in container.get('env',[])}
            if '-javaagent:' in existing.get('JAVA_TOOL_OPTIONS',''):
                original=existing['JAVA_TOOL_OPTIONS'].replace('-javaagent:/otel/agent.jar','').strip()
            else: original=existing.get('JAVA_TOOL_OPTIONS','')
            profiles=existing.get('SPRING_PROFILES_ACTIVE','local').split(',')
            if 'observability' not in profiles: profiles.append('observability')
            env={'SPRING_PROFILES_ACTIVE':','.join(profiles),'JAVA_TOOL_OPTIONS':original+' -javaagent:/otel/agent.jar',
                 'OBSERVABILITY_ENVIRONMENT':'kind-local','OTEL_SERVICE_NAME':service+'-service',
                 'OTEL_TRACES_EXPORTER':'otlp','OTEL_METRICS_EXPORTER':'none','OTEL_LOGS_EXPORTER':'none',
                 'OTEL_EXPORTER_OTLP_ENDPOINT':f'http://alloy.{a.observer_namespace}.svc.cluster.local:4318',
                 'OTEL_EXPORTER_OTLP_PROTOCOL':'http/protobuf','OTEL_TRACES_SAMPLER':'parentbased_traceidratio','OTEL_TRACES_SAMPLER_ARG':'1.0',
                 'OTEL_INSTRUMENTATION_COMMON_DEFAULT_ENABLED':'false'}
            for instrumentation in ['SERVLET','SPRING_WEB','SPRING_WEBMVC','JDBC','JDBC_DATASOURCE','JAVA_HTTP_CLIENT','HTTP_URL_CONNECTION','APACHE_HTTPCLIENT','LOGBACK_MDC']:
                env['OTEL_INSTRUMENTATION_'+instrumentation+'_ENABLED']='true'
            patch={'spec':{'template':{'metadata':{'annotations':{'shoppinglive/observability-commit':sha}},'spec':{'containers':[{'name':container['name'],'image':image,'env':[dict(name=n,value=v) for n,v in env.items()]}]}}}}
            k('patch','deployment',service,'--type=strategic','-p',json.dumps(patch))
            k('rollout','status','deployment/'+service,'--timeout=240s')
            k('exec','-i','deployment/'+service,'--','tar','-C','/tmp/images','-xf','-',data=images)
            print(service+': '+image+' 준비 완료',flush=True)
    print('원복은 백업의 spec을 검토해 적용하세요. DB 마이그레이션은 앱 원복으로 되돌아가지 않습니다.')

if __name__=='__main__': main()
