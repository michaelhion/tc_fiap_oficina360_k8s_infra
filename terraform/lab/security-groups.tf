resource "aws_security_group" "database_access" {
  name        = "${var.project_name}-database-access"
  description = "Acesso compartilhado entre EKS, Lambda e RDS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "PostgreSQL entre recursos associados ao mesmo SG"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}