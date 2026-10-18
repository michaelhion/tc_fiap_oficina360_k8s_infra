variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "oficina360"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.large"]
}

variable "allowed_cidr" {
  description = "CIDR autorizado a acessar o endpoint publico do EKS"
  type        = string
  default     = "0.0.0.0/0"
}

variable "eks_cluster_role_arn" {
  description = "ARN da role preexistente do Learner Lab para o cluster EKS"
  type        = string

  validation {
    condition = can(regex(
      "^arn:aws:iam::[0-9]{12}:role/.+LabEksClusterRole.+$",
      var.eks_cluster_role_arn
    ))

    error_message = "Informe o ARN da role LabEksClusterRole."
  }
}

variable "eks_node_role_arn" {
  description = "ARN da role preexistente do Learner Lab para o node group EKS"
  type        = string

  validation {
    condition = can(regex(
      "^arn:aws:iam::[0-9]{12}:role/.+LabEksNodeRole.+$",
      var.eks_node_role_arn
    ))

    error_message = "Informe o ARN da role LabEksNodeRole."
  }
}