module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  endpoint_public_access_cidrs = [var.allowed_cidr]

  name               = var.project_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access  = true
  endpoint_private_access = true

  enable_cluster_creator_admin_permissions = true

  compute_config = {
    enabled = false
  }

  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = { before_compute = true }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  eks_managed_node_groups = {
    lab = {
      name           = "${var.project_name}-lab"
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = 1
      max_size     = 1
      desired_size = 1

      subnet_ids = module.vpc.public_subnets

      additional_security_group_ids = [
        aws_security_group.database_access.id
      ]
    }
  }
}
