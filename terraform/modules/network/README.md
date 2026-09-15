# terraform/modules/network

VPC, 서브넷(public/private), NAT 게이트웨이, 라우팅 테이블, 보안 그룹을 정의할 모듈.

**상태: 향후 정의.** 팀이 AWS 사용 범위(계정/리전/비용 한도)를 합의한 뒤 채운다.

채울 때 최소한 다음을 결정해야 한다.

- VPC CIDR과 AZ 개수 (EKS 노드가 들어갈 private 서브넷 포함)
- NAT 게이트웨이를 AZ마다 둘지 하나로 공유할지 (비용 대 가용성 트레이드오프)
- RDS가 들어갈 DB 서브넷 그룹 분리 여부
