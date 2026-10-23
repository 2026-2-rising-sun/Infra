# terraform/modules/network

VPC, 서브넷(public/private × 2 AZ), IGW, NAT 1개, 라우팅 테이블.

## 결정한 것

| 항목 | 결정 | 이유 |
|---|---|---|
| AZ | ap-northeast-2a, 2c | 서울에서 모든 인스턴스 타입을 지원하는 두 AZ. EKS 는 최소 2 AZ 를 요구한다 |
| CIDR | 10.20.0.0/16, 서브넷 /20 | 노드·파드 IP(vpc-cni 는 파드마다 VPC IP 를 쓴다)가 넉넉하도록 |
| NAT | 1개 (2a) | 시간당 과금이라 2개면 고정비 두 배. 2a 장애 시 2c 아웃바운드 단절은 감수 |
| DB 서브넷 | 분리하지 않음 | RDS 는 프라이빗 서브넷에 두고 보안그룹으로 막는다. 서브넷을 더 나누면 복잡해지는데 얻는 게 없다 |

## 태그 규약

- `kubernetes.io/role/elb` / `internal-elb`: AWS Load Balancer Controller 가 NLB 를 놓을 서브넷을 찾는 태그.
- `karpenter.sh/discovery=<cluster>`: Karpenter `EC2NodeClass.subnetSelectorTerms` 가 찾는 태그. 프라이빗 서브넷에만 붙여 노드가 퍼블릭 IP 를 받지 않게 한다.
