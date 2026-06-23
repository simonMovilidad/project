# ─────────────────────────────────────────────────────────────────────────────
# Terraform IaC — Simon Movilidad Fleet Telemetry Platform
# Target: AWS (MSK Kafka + RDS TimescaleDB + ECS Fargate)
# Note: This is a blueprint for production deployment. Adjust variables for
#       your AWS account, VPC IDs, and region before applying.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}

variable "project_name" {
  default = "simon-movilidad"
}

# ─── RDS (PostgreSQL + TimescaleDB extension) ─────────────────────────────────
resource "aws_db_instance" "timescaledb" {
  identifier           = "${var.project_name}-db"
  engine               = "postgres"
  engine_version       = "15"
  instance_class       = "db.t3.medium"
  allocated_storage    = 50
  storage_encrypted    = true
  db_name              = "telemetry_db"
  username             = "postgres"
  password             = var.db_password
  skip_final_snapshot  = true
  publicly_accessible  = false

  tags = {
    Project = var.project_name
    Tier    = "database"
  }
}

variable "db_password" {
  description = "Master password for RDS instance"
  sensitive   = true
}

# ─── MSK (Amazon Managed Streaming for Kafka) ────────────────────────────────
resource "aws_msk_cluster" "kafka" {
  cluster_name           = "${var.project_name}-kafka"
  kafka_version          = "3.5.1"
  number_of_broker_nodes = 3

  broker_node_group_info {
    instance_type   = "kafka.m5.large"
    client_subnets  = []  # Add your subnet IDs here
    security_groups = []  # Add your SG IDs here

    storage_info {
      ebs_storage_info {
        volume_size = 100
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
    }
  }

  tags = {
    Project = var.project_name
    Tier    = "messaging"
  }
}

# ─── ECS Fargate (NestJS Backend) ────────────────────────────────────────────
resource "aws_ecs_cluster" "backend" {
  name = "${var.project_name}-cluster"
}

resource "aws_ecs_task_definition" "backend" {
  family                   = "${var.project_name}-backend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"

  container_definitions = jsonencode([{
    name  = "backend"
    image = "your-ecr-repo/simon-movilidad-backend:latest"
    portMappings = [{
      containerPort = 3002
      protocol      = "tcp"
    }]
    environment = [
      { name = "PORT",          value = "3002" },
      { name = "DATABASE_URL",  value = "postgresql://postgres:${var.db_password}@${aws_db_instance.timescaledb.endpoint}/telemetry_db" },
      { name = "KAFKA_BROKER",  value = aws_msk_cluster.kafka.bootstrap_brokers_tls }
    ]
  }])
}

output "db_endpoint" {
  value = aws_db_instance.timescaledb.endpoint
}

output "kafka_bootstrap_brokers" {
  value = aws_msk_cluster.kafka.bootstrap_brokers_tls
}

# ─── ECS Service (required to actually run the task) ─────────────────────────
resource "aws_ecs_service" "backend" {
  name            = "${var.project_name}-backend-svc"
  cluster         = aws_ecs_cluster.backend.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = []  # Add your subnet IDs here
    security_groups  = []  # Add your SG IDs here
    assign_public_ip = false
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}
