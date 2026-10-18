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