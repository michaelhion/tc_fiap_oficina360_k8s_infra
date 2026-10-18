locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = "${var.project_name}-vpc"
  cidr = "10.42.0.0/16"

  azs            = local.azs
  public_subnets = ["10.42.0.0/20", "10.42.16.0/20"]

  enable_nat_gateway      = false
  map_public_ip_on_launch = true

  enable_dns_support   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.project_name}" = "shared"
  }
}
