##
## Region, credentials, image
##  

#
# AWS region, and credentials, keys
#
provider "aws" {
  region                  = "${var.aws_region}"
  shared_credentials_file = "${var.aws_credentials}"
}

#
# deployer key
#

resource "aws_key_pair" "deployer" {
  key_name   = "${var.key_name}"
  public_key = "${file(var.key_file)}"
}

#
# Fetch latest RHEL image ami id
# 
data "aws_ami" "rhel75" {
  most_recent = true

  owners = ["${var.ami_owner}"]

  filter {
    name   = "name"
    values = ["${var.ami_name}"]
  }
}


##
## VPC, and subnets, internet gateway
##

#
# main VPC
# 
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags {
    Name = "main"
  }
}

#
# DMZ subnet
# 
resource "aws_subnet" "dmz" {
  vpc_id                  = "${aws_vpc.main.id}"
  cidr_block              = "${cidrsubnet(aws_vpc.main.cidr_block, 8, 1)}"
  map_public_ip_on_launch = true

  /* this is recommended in the docs */
  depends_on              = ["aws_internet_gateway.internet"]
}

#
# APP subnet
# 
resource "aws_subnet" "app" {
  vpc_id     = "${aws_vpc.main.id}"
  cidr_block = "${cidrsubnet(aws_vpc.main.cidr_block, 8, 2)}"
}

#
# internet gateway
#
resource "aws_internet_gateway" "internet" {
  vpc_id = "${aws_vpc.main.id}"

  tags {
    Name = "main"
  }
}

##
## Security groups and firewalls
##

#
# security group for incomging ssh
#
resource "aws_security_group" "allow_ssh" {
  name        = "allow_ssh"
  description = "Allow inbound ssh traffic, and all outbound traffic"
  vpc_id      = "${aws_vpc.main.id}"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

##
## Instances
##

#
# Bastion instance
#
resource "aws_instance" "bastion" {
  count                  = 1
  ami                    = "${data.aws_ami.rhel75.image_id}"
  instance_type          = "t2.micro"
  key_name               = "${aws_key_pair.deployer.key_name}"
  subnet_id              = "${aws_subnet.dmz.id}"
  # first IP addresses are reserved by AWS, we'll start from .10
  private_ip             = "${cidrhost(aws_subnet.dmz.cidr_block, count.index + 10)}"
  vpc_security_group_ids = ["${aws_security_group.allow_ssh.id}"]
  tags {
    Name = "bastion"
  }  

  depends_on      = ["aws_internet_gateway.internet", "aws_key_pair.deployer"]
}


#
# Instances for app
#
resource "aws_instance" "app" {
  count         = 3
  ami           = "${data.aws_ami.rhel75.image_id}"
  instance_type = "t2.micro"
  key_name      = "${aws_key_pair.deployer.key_name}"
  subnet_id     = "${aws_subnet.app.id}"
  # first IP addresses are reserved by AWS, we'll start from .10
  private_ip    = "${cidrhost(aws_subnet.app.cidr_block, count.index + 10)}"
  vpc_security_group_ids = ["${aws_security_group.allow_ssh.id}"]
  tags {
    Name = "app-${count.index}"
  }  
}

##
## Network routing
##

#
# route table for routing traffic to internet
# 
resource "aws_route_table" "internet" {
  vpc_id = "${aws_vpc.main.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.internet.id}"
  }

  tags {
    Name = "internet"
  }
}

resource "aws_route_table_association" "dmz_internet" {
  subnet_id      = "${aws_subnet.dmz.id}"
  route_table_id = "${aws_route_table.internet.id}"
}

#
# route: app->bastion
#
resource "aws_route_table" "app_bastion" {
    vpc_id = "${aws_vpc.main.id}"
    route {
        cidr_block = "0.0.0.0/0"
        instance_id = "${aws_instance.bastion.id}"
    }
}

resource "aws_route_table_association" "app" {
    subnet_id = "${aws_subnet.app.id}"
    route_table_id = "${aws_route_table.app_bastion.id}"
}

##
## Provisioner for creating ansible inventory file
##

data "template_file" "ansible_hosts" {
  template          = "${file("ansible-inventory.tpl")}"
  vars {
    bastion_hosts   = "${join("\n",aws_instance.bastion.*.public_ip)}"
    app_hosts       = "${join("\n",aws_instance.app.*.private_ip)}"
  }
}

resource "null_resource" "cluster" {
  provisioner "local-exec" {
    command = "echo '${data.template_file.ansible_hosts.rendered}' > ../ansible_inventory.properties"
  }
}

##
## Output
## 

output "app_ips" {
    value = "${aws_instance.app.*.private_ip}"
}

output "bastion_ip" {
    value = "${aws_instance.bastion.public_ip}"
}