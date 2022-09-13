provider "aws" {
  region     = var.region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

resource "aws_vpc" "my_vpc" {
  cidr_block = var.vcp_cidr
  tags = {
    Name = "vpc-bst"
  }
}

resource "aws_internet_gateway" "my" {
  vpc_id = aws_vpc.my_vpc.id
}

data "aws_availability_zones" "available" {
}
#--------------Public Subnets and Routing-------------------------
resource "aws_subnet" "public" {
  count = length(var.public_subnet)
  cidr_block = element(var.public_subnet, count.index)
  map_public_ip_on_launch = true
  vpc_id = aws_vpc.my_vpc.id
  availability_zone = data.aws_availability_zones.available.names[count.index]
}
resource "aws_route_table" "public" {
  count = length(var.public_subnet)
  vpc_id = aws_vpc.my_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.my.id
  }
  tags = {
    Name = "bst-public-${count.index + 1}"
  }
}
resource "aws_route_table_association" "public" {
  count = length(var.public_subnet)
  route_table_id = aws_route_table.public[count.index].id
  subnet_id = element(aws_subnet.public[*].id, count.index)
}

#--------------Private Subnets and Routing-------------------------
resource "aws_subnet" "private" {
  count = length(var.private_subnet)
  cidr_block = element(var.private_subnet, count.index)
  vpc_id = aws_vpc.my_vpc.id
  availability_zone = data.aws_availability_zones.available.names[count.index]
}

resource "aws_route_table" "private" {
  count = length(var.private_subnet)
  vpc_id = aws_vpc.my_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.nats[count.index].id
  }
  tags = {
    Name = "$bst-private-${count.index + 1}"
  }
}
resource "aws_route_table_association" "private" {
  count = length(var.public_subnet)
  route_table_id = aws_route_table.private[count.index].id
  subnet_id = element(aws_subnet.private[*].id, count.index)
}


#---------NAT GW---------------

resource "aws_eip" "nat" {
  vpc = true
  count = length(var.private_subnet)
  tags = {
    Name = "bst-ip-nat-gw ${count.index + 1}"
  }
}

resource "aws_nat_gateway" "nats" {
  allocation_id = aws_eip.nat[count.index].id
  subnet_id = element(aws_subnet.public[*].id, count.index)
  count = length(var.private_subnet)
}


output "subnets" {
  value = aws_subnet.public[*]
}
#---------AWS SECURITY GROUP-----------

resource "aws_security_group" "web_server2" {
  vpc_id = aws_vpc.my_vpc.id
  ingress {

    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
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

resource "aws_security_group" "sql_bst" {
  name        = "sql_bst"
   vpc_id     = aws_vpc.my_vpc.id

  ingress {

    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
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
#--------------Aws Launch Configuration and Autoscaling Group-------------------------

resource "aws_launch_configuration" "bositon" {
  name     = "ec2_bastion_host"
  image_id = "ami-01977e30682e5df74"
  instance_type = "t3.micro"
  security_groups = [aws_security_group.web_server2.id]
  key_name = "aws_02"
  user_data = file("web_server.sh")

}

resource "aws_autoscaling_group" "bositon" {
  name_prefix = "bositon"
  max_size = 4
  desired_capacity = 2
  min_size = 2
  vpc_zone_identifier = aws_subnet.public[*].id
  launch_configuration = aws_launch_configuration.bositon.name
  health_check_type = "EC2"
  health_check_grace_period = 60
  default_cooldown = 30
  target_group_arns = [aws_lb_target_group.web_http.arn]
  tag {
    key                 = "bositon"
    value               = "bositon_host"
    propagate_at_launch = true
  }

}


resource "aws_lb" "web" {
  name = "test-lb-tf"
  internal = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_server2.id]
  subnets            = aws_subnet.public.*.id
  enable_deletion_protection = false
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.web.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_http.arn
  }
}

resource "aws_lb_target_group" "web_http" {
  name     = "tf-example-lb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.my_vpc.id
}

resource "aws_autoscaling_attachment" "web" {
  autoscaling_group_name = aws_autoscaling_group.bositon.id
  alb_target_group_arn = aws_lb_target_group.web_http.arn
}

resource "aws_autoscaling_policy" "cpu-up" {
  name                   = "cpu-up"
  autoscaling_group_name = aws_autoscaling_group.bositon.name
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 60
  policy_type            = "SimpleScaling"
}

resource "aws_cloudwatch_metric_alarm" "cpu-alarm-up" {
  alarm_name          = "cpu-alarm-up"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "60"
  statistic           = "Average"
  threshold           = "20"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.bositon.name
  }
  alarm_description = "This metric monitors ec2 cpu utilization"
  actions_enabled   = "true"
  alarm_actions     = [aws_autoscaling_policy.cpu-up.arn]

}
resource "aws_autoscaling_policy" "cpu-down" {
  name                   = "cpu-down"
  autoscaling_group_name = aws_autoscaling_group.bositon.name
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 60
  policy_type            = "SimpleScaling"

}

resource "aws_cloudwatch_metric_alarm" "cpu-check-alarm-scaldown" {
  alarm_name = "cpu-check-alarm-scaldown"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods = "1"
  metric_name = "CPUUtilization"
  namespace = "AWS/EC2"
  period = "60"
  statistic = "Average"
  threshold = "10"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.bositon.name
  }

  alarm_description = "CPU utilization check-down"
  actions_enabled = "true"
  alarm_actions = [
    aws_autoscaling_policy.cpu-down.arn]
}

resource "aws_instance" "database" {
  count = length(var.private_subnet)
  ami           = "ami-01977e30682e5df74"
  instance_type = "t3.micro"
  subnet_id = element(aws_subnet.private[*].id, count.index)
  vpc_security_group_ids = [aws_security_group.sql_bst.id]
  key_name = "aws_02"

  tags = {
    Name = "database ${count.index + 1}"
    }
}
