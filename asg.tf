resource "aws_eip" "openproject_eip" {
  domain = "vpc"

  tags = {
    Name = "OpenProject-Permanent-IP"
  }
}

# Allow the EC2 instance to associate the EIP to itself
resource "aws_iam_role_policy" "eip_associate" {
  name = "openproject-eip-associate"
  role = aws_iam_role.ec2_ssm_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "ec2:AssociateAddress"
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

resource "aws_launch_template" "openproject" {
  name_prefix   = "openproject-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t3.large"

  iam_instance_profile {
    name = aws_iam_instance_profile.openproject_profile.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.openproject_sg.id]
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 20 # Reduced from 50 since we use S3/RDS
      volume_type = "gp3"
    }
  }

  user_data = base64encode(<<-EOF
#!/bin/bash
# Log all output for debugging
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "Deploy SHA: ${var.deploy_sha}"

# 1. Associate Elastic IP
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
aws ec2 associate-address --instance-id $INSTANCE_ID --allocation-id ${aws_eip.openproject_eip.id} --region ${data.aws_region.current.name}

# 2. Install Docker
apt-get update
apt-get install -y ca-certificates curl gnupg unzip
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# 3. Setup OpenProject
if [ ! -d /opt/openproject ]; then
  git clone https://github.com/opf/openproject-docker-compose.git --depth=1 --branch=stable/14 /opt/openproject
fi

cd /opt/openproject
cp -n .env.example .env || true

# Inject configurations into .env
sed -i "/^PORT=/d" .env
echo "PORT=80" >> .env
sed -i "/^OPENPROJECT_HOST__NAME=/d" .env
echo "OPENPROJECT_HOST__NAME=pmo.nearborrow.com.au" >> .env
sed -i "/^OPENPROJECT_HTTPS=/d" .env
echo "OPENPROJECT_HTTPS=true" >> .env

# Remove local database volumes
sed -i "/^PGDATA=/d" .env
sed -i "/^OPDATA=/d" .env

# S3 Configuration
sed -i "/^OPENPROJECT_ATTACHMENTS__STORAGE__TYPE=/d" .env
echo "OPENPROJECT_ATTACHMENTS__STORAGE__TYPE=fog" >> .env
sed -i "/^OPENPROJECT_FOG__CREDENTIALS__PROVIDER=/d" .env
echo "OPENPROJECT_FOG__CREDENTIALS__PROVIDER=AWS" >> .env
sed -i "/^OPENPROJECT_FOG__CREDENTIALS__USE__IAM__PROFILE=/d" .env
echo "OPENPROJECT_FOG__CREDENTIALS__USE__IAM__PROFILE=true" >> .env
sed -i "/^OPENPROJECT_FOG__CREDENTIALS__REGION=/d" .env
echo "OPENPROJECT_FOG__CREDENTIALS__REGION=${data.aws_region.current.name}" >> .env
sed -i "/^OPENPROJECT_FOG__DIRECTORY=/d" .env
echo "OPENPROJECT_FOG__DIRECTORY=${aws_s3_bucket.openproject_attachments.bucket}" >> .env

# RDS Configuration
sed -i "/^DATABASE_URL=/d" .env
echo "DATABASE_URL=postgres://${aws_db_instance.openproject_db.username}:${random_password.db_password.result}@${aws_db_instance.openproject_db.endpoint}/${aws_db_instance.openproject_db.db_name}?pool=20&encoding=unicode&reconnect=true" >> .env

# Force Caddy HTTPS
sed -i "s/{header.X-Forwarded-Proto}/https/g" proxy/Caddyfile.template

# Inject Admin Password
grep -q OPENPROJECT_SEED__ADMIN__USER__PASSWORD docker-compose.yml || sed -i "/IMAP_ENABLED:/a \    OPENPROJECT_SEED__ADMIN__USER__PASSWORD: \"admin12345\"" docker-compose.yml

# We DO NOT need the local db or cache for data anymore, but we'll leave cache for session storage.
# We will completely remove the local 'db' container so it doesn't run and waste RAM!
# Wait, docker-compose.yml has 'depends_on: - db'. If we remove db, it will fail to start.
# Instead, we just stop it after it starts. Or we can sed out the db service!
sed -i '/depends_on:/!b;n;/- db/d' docker-compose.yml
# Remove db service block completely using awk or simply ignoring it and stopping it:
docker compose pull
docker compose build proxy
docker compose up -d

# Stop and remove the unneeded local db container
docker compose stop db
docker compose rm -f db
EOF
  )

  instance_market_options {
    market_type = "spot"
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "OpenProject-Server-Spot"
    }
  }
}

resource "aws_autoscaling_group" "openproject_asg" {
  name                = "openproject-asg"
  vpc_zone_identifier = data.aws_subnets.default.ids
  desired_capacity    = 1
  max_size            = 1
  min_size            = 0

  launch_template {
    id      = aws_launch_template.openproject.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
    }
  }

  tag {
    key                 = "Name"
    value               = "OpenProject-Server-Spot"
    propagate_at_launch = true
  }
}

# --- ASG Scheduling ---

resource "aws_autoscaling_schedule" "start_asg" {
  scheduled_action_name  = "start-openproject"
  min_size               = 0
  max_size               = 1
  desired_capacity       = 1
  recurrence             = var.schedule_start_cron
  autoscaling_group_name = aws_autoscaling_group.openproject_asg.name
}

resource "aws_autoscaling_schedule" "stop_asg" {
  scheduled_action_name  = "stop-openproject"
  min_size               = 0
  max_size               = 1
  desired_capacity       = 0
  recurrence             = var.schedule_stop_cron
  autoscaling_group_name = aws_autoscaling_group.openproject_asg.name
}
