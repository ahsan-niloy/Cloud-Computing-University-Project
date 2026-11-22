# ------------------------------------------------------------------------------
# Security Groups & Rules
# ------------------------------------------------------------------------------

# ALB security group: accepts public HTTP and forwards only to the app tier
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Security group for the internet-facing Aura ALB; allows HTTP 80 inbound from internet and egress to app tier"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_in" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP 80 inbound from the internet"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow HTTP 80 outbound to the app security group only"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.app.id
}

# App security group: accepts HTTP from ALB only; allows HTTPS outbound (SSM/Secrets/updates) and MySQL to DB
resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app-sg"
  description = "Security group for Aura Ledger EC2 instances; allows HTTP 80 from ALB, HTTPS 443 outbound, and MySQL 3306 to DB"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-app-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Allow HTTP 80 inbound from the ALB security group only"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "Allow HTTPS 443 outbound for SSM, Secrets Manager, and package updates via NAT"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "Allow MySQL 3306 outbound to the database security group"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = var.db_sg_id
}

# Database ingress rule managed here to avoid circular dependencies between database and app modules
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = var.db_sg_id
  description                  = "Allow MySQL 3306 inbound from the Aura app security group"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.app.id
}

# ------------------------------------------------------------------------------
# Application Load Balancer & Target Group
# ------------------------------------------------------------------------------

# Internet-facing ALB in the public subnets with invalid header dropping enabled
resource "aws_lb" "this" {
  name                       = "${var.name_prefix}-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.public_subnet_ids
  drop_invalid_header_fields = true

  tags = {
    Name = "${var.name_prefix}-alb"
  }
}

# Target group for the Aura Ledger PHP app on port 80
resource "aws_lb_target_group" "this" {
  name                 = "${var.name_prefix}-ledger-tg"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/health.php"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name = "${var.name_prefix}-ledger-tg"
  }
}

# HTTP:80 listener forwarding all traffic to the ledger target group
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# ------------------------------------------------------------------------------
# IAM Identity (Imported from existing live resources)
# ------------------------------------------------------------------------------

# EC2 role for Aura Ledger instances; imported so the pipeline never replaces or deletes it
resource "aws_iam_role" "ledger" {
  name        = "${var.name_prefix}-ledger-ec2-role"
  description = "Machine identity for the Aura ledger EC2 servers"

  # Matches the live trust policy and legacy/phase1-5/ec2-ledger-trust.json (including the Sid)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2ToAssumeLedgerRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Inline policy granting read access to Secrets Manager and SSM; JSON is the live policy exported in legacy/phase1-5/
resource "aws_iam_role_policy" "ledger_secrets" {
  name = "${var.name_prefix}-ledger-secrets-read"
  role = aws_iam_role.ledger.id

  policy = file("${path.module}/../../../legacy/phase1-5/ec2-ledger-permissions.json")
}

# Managed policy attachment enabling AWS Systems Manager Session Manager access without SSH keys
resource "aws_iam_role_policy_attachment" "ledger_ssm" {
  role       = aws_iam_role.ledger.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile binding the ledger role to EC2 instances
resource "aws_iam_instance_profile" "ledger" {
  name = "${var.name_prefix}-ledger-ec2-profile"
  role = aws_iam_role.ledger.name
}

# ------------------------------------------------------------------------------
# SSM Parameter (Imported from existing live resource)
# ------------------------------------------------------------------------------

# Stores the RDS database host endpoint for the Aura Ledger application
resource "aws_ssm_parameter" "db_host" {
  name  = "/aura/dev/db_host"
  type  = "String"
  value = var.db_endpoint
}

# ------------------------------------------------------------------------------
# Launch Template, Auto Scaling Group & Scaling Policy
# ------------------------------------------------------------------------------

# Launch template enforcing IMDSv2, encrypted gp3 root volume, detailed monitoring, and no SSH key pair
resource "aws_launch_template" "this" {
  name                   = "${var.name_prefix}-ledger-lt"
  image_id               = var.ami_id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.app.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ledger.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 8
      volume_type = "gp3"
      encrypted   = true
    }
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.name_prefix}-ledger-app"
    }
  }
}

# Auto Scaling Group running 2-4 instances across the private subnets behind the ALB
resource "aws_autoscaling_group" "this" {
  name                      = "${var.name_prefix}-ledger-asg"
  min_size                  = 2
  max_size                  = 4
  vpc_zone_identifier       = var.private_subnet_ids
  target_group_arns         = [aws_lb_target_group.this.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120
  default_instance_warmup   = 120
  metrics_granularity       = "1Minute"

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupStandbyInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
  ]

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

# Target tracking scaling policy maintaining average ASG CPU utilization at 50%
resource "aws_autoscaling_policy" "cpu_target_50" {
  name                   = "${var.name_prefix}-cpu-target-50"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 50.0
  }
}
