output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "lambda_subnet_ids" {
  value = module.vpc.public_subnets
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

output "database_access_security_group_id" {
  value = aws_security_group.database_access.id
}
