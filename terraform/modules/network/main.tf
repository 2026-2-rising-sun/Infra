# VPC 1개, AZ 2개(ap-northeast-2a / 2c), 퍼블릭·프라이빗 서브넷 각 2개, NAT 게이트웨이 1개.
#
# NAT 를 AZ 마다 두지 않고 하나만 둔 이유: NAT 는 시간당 과금이라 2개면 고정비가 두 배다.
# 2c 의 프라이빗 서브넷은 2a 의 NAT 를 거치므로 2a 가 죽으면 2c 노드의 아웃바운드가 끊긴다.
# 이 프로젝트는 "필요할 때만 켜는" 클러스터라 그 가용성 손실을 감수한다.
#
# 서브넷 태그는 EKS 로드밸런서 컨트롤러(kubernetes.io/role/*)와 Karpenter(karpenter.sh/discovery)가
# 서브넷을 찾을 때 쓰는 규약이다. 값을 바꾸면 두 컨트롤러가 서브넷을 못 찾는다.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = [for suffix in var.az_suffixes : "${var.aws_region}${suffix}"]
  # /16 을 /20 단위로 자른다. 0~1 은 퍼블릭, 8~9 는 프라이빗. 사이를 비워 두어 나중에 DB 전용 서브넷 등을 끼울 수 있다.
  public_cidrs  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  private_cidrs = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${var.name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name                                        = "${var.name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "karpenter.sh/discovery"                    = var.cluster_name
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat" }
}

# NAT 는 첫 번째 AZ 의 퍼블릭 서브넷에 하나만 둔다.
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.name}-nat" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = length(local.azs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-private" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  count = length(local.azs)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
