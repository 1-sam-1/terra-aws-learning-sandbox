terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
  required_version = "~> 1.0.8"
}

provider "aws" {
  region = var.aws_region
}

locals {
  instance_user_data = <<EOF
#!/bin/bash
echo ECS_CLUSTER=example > /etc/ecs/ecs.config
rm -f /var/lib/ecs/data/agent.db
EOF
}

## VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.10.0"

  name = var.vpc_name
  cidr = var.vpc_cidr

  azs             = var.vpc_azs
  private_subnets = var.vpc_private_subnets
  public_subnets  = var.vpc_public_subnets

  enable_nat_gateway = var.vpc_enable_nat_gateway

  tags = var.vpc_tags
}

module "web_server_sg" {
  source = "terraform-aws-modules/security-group/aws//modules/http-80"

  name        = "web-server"
  description = "Security group for web-server with HTTP ports open within VPC"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [var.vpc_cidr]
}

module "alb_sg" {
  source = "terraform-aws-modules/security-group/aws//modules/http-80"

  name        = "alb"
  description = "Security group for alb with HTTP ports open to all"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
}

## Load Balancer
module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 6.0"

  name = var.alb_name

  load_balancer_type = "application"

  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [module.alb_sg.security_group_id]

  target_groups = [
    {
      name_prefix      = "pref-"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "instance"
    }
  ]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    }
  ]

  tags = {
    Environment = "Test"
  }
}

resource "aws_iam_instance_profile" "ecs_register" {
  name = "ecs_register"
  role = "AmazonEC2ContainerServiceforEC2Role"
}

module "asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 4.7"

  # Autoscaling group
  name = "example-asg"


  min_size                  = 0
  max_size                  = 3
  desired_capacity          = 2
  wait_for_capacity_timeout = 0
  health_check_type         = "EC2"
  vpc_zone_identifier       = module.vpc.private_subnets[*]
  #protect_from_scale_in     = true

  initial_lifecycle_hooks = [
    {
      name                  = "ExampleStartupLifeCycleHook"
      default_result        = "CONTINUE"
      heartbeat_timeout     = 60
      lifecycle_transition  = "autoscaling:EC2_INSTANCE_LAUNCHING"
      notification_metadata = jsonencode({ "hello" = "world" })
    },
    {
      name                  = "ExampleTerminationLifeCycleHook"
      default_result        = "CONTINUE"
      heartbeat_timeout     = 180
      lifecycle_transition  = "autoscaling:EC2_INSTANCE_TERMINATING"
      notification_metadata = jsonencode({ "goodbye" = "world" })
    }
  ]

  instance_refresh = {
    strategy = "Rolling"
    preferences = {
      min_healthy_percentage = 50
    }
    triggers = ["tag"]
  }


  # Launch template
  lt_name                = "example-asg"
  description            = "Launch template example"
  update_default_version = true

  use_lt    = true
  create_lt = true

  image_id          = var.image_id
  instance_type     = "t2.micro"

  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 32
  }

  iam_instance_profile_arn = aws_iam_instance_profile.ecs_register.arn
  security_groups = [module.web_server_sg.security_group_id]
  target_group_arns = module.alb.target_group_arns
  key_name = "myNginxInstance"
  user_data_base64 = base64encode(local.instance_user_data)

   tags =[
    {
      key                 = "AmazonECSManaged"
      value               = ""
      propagate_at_launch = true
    }
   ]

}

resource "aws_ecs_capacity_provider" "autoscaling_ec2_capacity" {
  name = "tetris-asg-capacity"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = module.asg.autoscaling_group_arn

    managed_scaling {
      maximum_scaling_step_size = 1
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 2
    }
  }
}

resource "aws_iam_service_linked_role" "AWSServiceRoleForECS" {
  aws_service_name = "ecs.amazonaws.com"
}

resource "aws_kms_key" "example" {
  description             = "example"
  deletion_window_in_days = 7
}

resource "aws_cloudwatch_log_group" "example" {
  name = "example"
}

resource "aws_ecs_cluster" "test" {
  name = "example"
  capacity_providers = [aws_ecs_capacity_provider.autoscaling_ec2_capacity.name]

  configuration {
    execute_command_configuration {
      kms_key_id = aws_kms_key.example.arn
      logging    = "OVERRIDE"

      log_configuration {
        cloud_watch_encryption_enabled = true
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.example.name
      }
    }
  }
}

resource "aws_ecs_task_definition" "tetris-task" {
  family = "service"
  container_definitions = jsonencode([
    {
      name      = "tetris"
      image     = "572248248342.dkr.ecr.eu-central-1.amazonaws.com/testing-ecs:latest"
      cpu       = 10
      memory    = 512
      essential = true
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
        }
      ]
    }
  ])

}

resource "aws_ecs_service" "tetris" {
  name            = "tetris-service"
  cluster         = aws_ecs_cluster.test.id
  task_definition = aws_ecs_task_definition.tetris-task.arn
  desired_count   = 3

  ordered_placement_strategy {
    type  = "binpack"
    field = "cpu"
  }
}

resource "aws_security_group" "bastion_sg" {
  count = var.create_bastion == true ? 1 : 0
  name        = "SSH"
  vpc_id      = module.vpc.vpc_id

  ingress {
      from_port        = 22
      to_port          = 22
      protocol         = "tcp"
      cidr_blocks      = ["0.0.0.0/0"]
    }

  egress {
      from_port        = 0
      to_port          = 0
      protocol         = "-1"
      cidr_blocks      = ["0.0.0.0/0"]
    }

}

resource "aws_instance" "bastion" {
  count = var.create_bastion == true ? 1 : 0
  ami = "ami-058e6df85cfc7760b"
  instance_type = "t2.micro"
  subnet_id = module.vpc.public_subnets[0]
  associate_public_ip_address = true
  security_groups = [aws_security_group.bastion_sg[0].name]

  tags = {
    Name = "Bastion"
  }
  key_name = "myNginxInstance"
}