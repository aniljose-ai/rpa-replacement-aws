# ---------------------------------------------------------------------------
# Networking — VPC, subnet, internet gateway, route table, security group
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {}

locals {
  automation_subnet_cidrs = {
    az1 = "10.0.1.0/24"
    az2 = "10.0.2.0/24"
  }
}

resource "aws_vpc" "automation_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.automation_name}-${var.environment}-automation-vpc"
  }
}

resource "aws_subnet" "automation_subnet" {
  for_each = local.automation_subnet_cidrs

  vpc_id                  = aws_vpc.automation_vpc.id
  cidr_block              = each.value
  availability_zone       = data.aws_availability_zones.available.names[tonumber(substr(each.key, 2, 1)) - 1]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.automation_name}-${var.environment}-automation-${each.key}-subnet"
  }
}

resource "aws_internet_gateway" "automation_igw" {
  vpc_id = aws_vpc.automation_vpc.id

  tags = {
    Name = "${var.automation_name}-${var.environment}-automation-igw"
  }
}

resource "aws_route_table" "automation_rt" {
  vpc_id = aws_vpc.automation_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.automation_igw.id
  }

  tags = {
    Name = "${var.automation_name}-${var.environment}-automation-rt"
  }
}

resource "aws_route_table_association" "automation_rta" {
  for_each = aws_subnet.automation_subnet

  subnet_id      = each.value.id
  route_table_id = aws_route_table.automation_rt.id
}

# Security group: all outbound, no inbound (ECS batch jobs initiate all connections)
resource "aws_security_group" "automation_sg" {
  name        = "${var.automation_name}-${var.environment}-automation-sg"
  description = "ECS batch job - all outbound, no inbound"
  vpc_id      = aws_vpc.automation_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.automation_name}-${var.environment}-automation-sg"
  }
}
