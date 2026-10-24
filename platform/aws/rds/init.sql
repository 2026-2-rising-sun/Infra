-- RDS 인스턴스 하나에 서비스별 DB 5개를 만든다. local/init/postgres 와 같은 결과를 RDS 에서 재현한다.
-- 실행: platform/aws/install.sh 의 rds-init 단계가 클러스터 안 일회성 파드에서 psql 로 돌린다.
-- 이미 있는 DB 는 건너뛴다(\gexec).
SELECT format('CREATE DATABASE %I OWNER %I', name, current_user)
FROM (VALUES ('member'), ('shopping'), ('commerce'), ('live'), ('notification')) AS required(name)
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = required.name)
\gexec
