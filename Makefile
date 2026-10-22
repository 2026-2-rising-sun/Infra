.PHONY: setup start status ui grafana-login
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
