provider "aws" {
  region = "ap-southeast-2" # matching the other project's region
}

# Use default VPC
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Create Security Group
resource "aws_security_group" "openproject_sg" {
  name        = "openproject-sg"
  description = "Security group for OpenProject EC2 instance"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# SSH Key Pair
resource "aws_key_pair" "openproject_key" {
  key_name   = "openproject-key"
  public_key = file("${path.module}/openproject-key.pub")
}

# Get latest Ubuntu 22.04 AMI
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

# EC2 Instance
resource "aws_instance" "openproject" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.large"
  key_name      = aws_key_pair.openproject_key.key_name
  
  vpc_security_group_ids = [aws_security_group.openproject_sg.id]
  subnet_id              = data.aws_subnets.default.ids[0]
  iam_instance_profile   = aws_iam_instance_profile.openproject_profile.name

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y ca-certificates curl gnupg
              install -m 0755 -d /etc/apt/keyrings
              curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
              chmod a+r /etc/apt/keyrings/docker.gpg

              echo \
                "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
                "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
                tee /etc/apt/sources.list.d/docker.list > /dev/null

              apt-get update
              apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
              systemctl enable docker
              systemctl start docker
              usermod -aG docker ubuntu
              EOF

  tags = {
    Name = "OpenProject-Server"
  }
}

output "public_ip" {
  value = aws_instance.openproject.public_ip
}

# --- IAM Role for EC2 (SSM) ---
resource "aws_iam_role" "ec2_ssm_role" {
  name = "openproject-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.ec2_ssm_role.name
}

resource "aws_iam_instance_profile" "openproject_profile" {
  name = "openproject-ec2-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

# --- GitHub OIDC Provider ---
# Assuming the OIDC provider might already exist in the account, we use 'data' instead of 'resource' if possible, or create it if not.
# Since the user has 'data "aws_iam_openid_connect_provider" "github"' in pmo project, we use 'data' here as well.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# --- IAM Role for GitHub Actions ---
resource "aws_iam_role" "github_actions_role" {
  name = "github-actions-openproject-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.github.arn
        }
        Condition = {
          StringLike = {
            "token.actions.githubusercontent.com:sub" : "repo:pedaganim/pmtools-openproject:*"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "github_actions_ssm_policy" {
  name   = "github-actions-openproject-ssm-policy"
  role   = aws_iam_role.github_actions_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation"
        ]
        Resource = [
          "arn:aws:ssm:*:*:document/AWS-RunShellScript",
          "arn:aws:ec2:*:*:instance/*"
        ]
      }
    ]
  })
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions_role.arn
}
