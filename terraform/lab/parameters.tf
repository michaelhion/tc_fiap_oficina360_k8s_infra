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

resource "aws_ssm_parameter" "cluster_name" {
  name        = "/oficina360/cluster/name"
  description = "Nome do cluster EKS"
  type        = "String"
  value       = aws_eks_cluster.main.name

  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}

resource "aws_ssm_parameter" "cluster_endpoint" {
  name        = "/oficina360/cluster/endpoint"
  description = "Endpoint da API Kubernetes"
  type        = "String"
  value       = aws_eks_cluster.main.endpoint

  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}

resource "aws_ssm_parameter" "cluster_ca" {
  name        = "/oficina360/cluster/certificate-authority"
  description = "Certificate Authority do cluster EKS em Base64"
  type        = "String"
  value       = aws_eks_cluster.main.certificate_authority[0].data

  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}