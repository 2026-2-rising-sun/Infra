.PHONY: setup start status ui grafana-login aws-bootstrap aws-up aws-down argocd-ui
setup:
	python3 local/team/run.py setup
start:
	python3 local/team/run.py start
status:
	python3 local/team/run.py status
ui:
	python3 local/team/run.py ui
grafana-login:
	python3 local/team/run.py grafana-login

# --- AWS (terraform/README.md 참고) ---
# 상태 저장소. 계정당 한 번만.
aws-bootstrap:
	terraform -chdir=terraform/bootstrap init -input=false
	terraform -chdir=terraform/bootstrap apply -input=false
# 전체 생성: terraform apply → 클러스터 부품 설치 → NLB 를 CloudFront 에 연결. 약 30분, 시간당 약 $0.7.
aws-up:
	bash platform/aws/up.sh
# 전체 삭제: LoadBalancer Service·NodePool 먼저 비우고 destroy. 별도 상태 저장소만 남는다. RDS 데이터·ECR 이미지도 삭제한다.
aws-down:
	bash platform/aws/down.sh
argocd-ui:
	@echo "admin 비밀번호: $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
	@echo "http://127.0.0.1:18443"
	kubectl -n argocd port-forward svc/argocd-server 18443:80
