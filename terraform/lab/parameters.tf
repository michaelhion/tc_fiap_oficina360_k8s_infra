resource "aws_ssm_parameter" "vpc_id" {
  name  = "/oficina360/network/vpc-id"
  type  = "String"
  value = module.vpc.vpc_id
}

resource "aws_ssm_parameter" "subnet_ids" {
  name  = "/oficina360/network/subnet-ids"
  type  = "StringList"
  value = join(",", module.vpc.public_subnets)
}

resource "aws_ssm_parameter" "database_access_security_group_id" {
  name  = "/oficina360/network/database-access-sg-id"
  type  = "String"
  value = aws_security_group.database_access.id
}