# RDS PostgreSQL 1대. 서비스별 DB 5개는 같은 인스턴스 안에 만든다.
#
# 인스턴스를 서비스마다 분리하면 "서비스별 독립 DB" 그림은 예쁘지만 db.t4g.small 이 5대라 고정비가 다섯 배다.
# 지금 Backend 는 DB 이름만 다르고 같은 Postgres 를 쓰도록 돼 있어(dev 프로필 postgres:5432/<서비스>)
# 로컬·kind 와 같은 구성을 유지한다. 부하 테스트에서 DB 가 병목으로 잡히면 그때 분리한다.
#
# 마스터 비밀번호는 Terraform 이 만들지 않고 RDS 가 Secrets Manager 에 직접 넣는다(manage_master_user_password).
# 상태 파일에도 평문이 남지 않는다. 앱은 나중에 External Secrets 로 이 Secret 을 읽는다.

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.private_subnet_ids
}

resource "aws_security_group" "this" {
  name        = "${var.name}-rds"
  description = "RDS PostgreSQL. EKS 클러스터 보안그룹에서 오는 5432 만 허용"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "from_eks" {
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = var.source_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_db_instance" "this" {
  identifier = "${var.name}-postgres"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.allocated_storage_gb * 2
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name                     = "postgres"
  username                    = var.master_username
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = false

  # 개발 환경이라 백업은 하루만. 지우고 다시 만드는 환경이라 최종 스냅샷도 남기지 않는다.
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  performance_insights_enabled = false
}
