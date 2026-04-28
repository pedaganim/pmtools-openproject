resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_security_group" "rds_sg" {
  name        = "openproject-rds-sg"
  description = "Security group for OpenProject RDS database"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "PostgreSQL from EC2"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.openproject_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "openproject_db" {
  identifier        = "openproject-db"
  engine            = "postgres"
  engine_version    = "13"
  instance_class    = "db.t4g.micro"
  allocated_storage = 20
  db_name           = "openproject"
  username          = "postgres"
  password          = random_password.db_password.result

  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  publicly_accessible    = false
  skip_final_snapshot    = true

  # Ensure the database can be stopped
  apply_immediately = true
}

# --- EventBridge Rules for RDS Scheduling ---

resource "aws_iam_role" "rds_scheduler_role" {
  name = "openproject-rds-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "rds_scheduler_policy" {
  name = "openproject-rds-scheduler-policy"
  role = aws_iam_role.rds_scheduler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "rds:StartDBInstance",
          "rds:StopDBInstance"
        ]
        Effect   = "Allow"
        Resource = aws_db_instance.openproject_db.arn
      },
      {
        Action = "ssm:StartAutomationExecution"
        Effect = "Allow"
        Resource = [
          "arn:aws:ssm:*:*:document/AWS-StartRdsInstance",
          "arn:aws:ssm:*:*:document/AWS-StopRdsInstance"
        ]
      }
    ]
  })
}

# Start RDS Rule
resource "aws_cloudwatch_event_rule" "start_rds" {
  name                = "openproject-start-rds"
  description         = "Start RDS instance on a schedule"
  schedule_expression = "cron(${var.schedule_start_cron_eb})"
}

resource "aws_cloudwatch_event_target" "start_rds_target" {
  rule      = aws_cloudwatch_event_rule.start_rds.name
  target_id = "StartRDS"
  arn       = "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-StartRdsInstance"
  role_arn  = aws_iam_role.rds_scheduler_role.arn

  input = jsonencode({
    InstanceId           = aws_db_instance.openproject_db.identifier
    AutomationAssumeRole = aws_iam_role.rds_scheduler_role.arn
  })
}

# Stop RDS Rule
resource "aws_cloudwatch_event_rule" "stop_rds" {
  name                = "openproject-stop-rds"
  description         = "Stop RDS instance on a schedule"
  schedule_expression = "cron(${var.schedule_stop_cron_eb})"
}

resource "aws_cloudwatch_event_target" "stop_rds_target" {
  rule      = aws_cloudwatch_event_rule.stop_rds.name
  target_id = "StopRDS"
  arn       = "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-StopRdsInstance"
  role_arn  = aws_iam_role.rds_scheduler_role.arn

  input = jsonencode({
    InstanceId           = aws_db_instance.openproject_db.identifier
    AutomationAssumeRole = aws_iam_role.rds_scheduler_role.arn
  })
}

data "aws_region" "current" {}
