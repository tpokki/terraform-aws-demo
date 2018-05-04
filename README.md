Simple introduction to using terraform in AWS
=============================================

Disclaimer
----------

TL;DR: Executing the commands in this demo may cost you money !!


Using this demo requires Amazon Web Services account, and therefore the commands and examples may cause you to run billable instances in Amazon (especially if you are not entitled to free tier). Most likely the cost wont be much, even if you are not entitled to free tier. Just remember to destroy the machines you've created after you've done. 

This should go without saying; I cannot held responsible for any of the expenses that running this demo may cause to you or the AWS account owner you are using.

About
-----

This is simple terraform demo that sets up following simple infrastructure into AWS EC2 cloud.

```
        internet            
            |
            |
 -----------+-------------------------------------
            |        virtual private cloud (vpc)
            |
       +---------+  
       | bastion |  +---------+
       +---------+  |+---------+
             |______+|+---------+
                     +|   app   |
                      +---------+

```

That is, we create bastion host into own subnet with public ip address and possibility to login with ssh. 
Inside the cloud network we create another subnet, where we create three app servers. 

This infrastructure can be extended to add other servers, such as database and web servers, to make it more practical. 

Usage
-----

In this chapter we go quickly through the commands to use this terraform-aws-demo to setup infrastructure into AWS.  

### Prerequisites

* You need AWS account, and credentials (access key, secret key) to create new resources in AWS EC2 cloud. 
* You need to download terraform binary and place it in your PATH

### Setup 

Use `setup-keys.sh` to create ssh keys and property files for aws credentials

```
$ ./setup-keys.sh
aws_access_key_id: DEMOACCESSKEY
aws_secret_access_key: DEMOSECRETACCESSKEY
Creating AWS credentials file ...
Generating public/private rsa key pair.
Your identification has been saved in ./keys/aws-deployer.
Your public key has been saved in ./keys/aws-deployer.pub.
...
```

As a result you should have ssh keys and credentials file in `keys/` directory. Keep them safe!

### Initialize terraform

Initialize terraform by downloading plugins.

```
$ cd terraform/
$ terraform init
```

### Create infrastructure

First, you can preview the changes with `terraform plan`. If preferred, you can save your plan with `-out` option. 

```
$ terraform plan -out=aws-demo.plan
```

Once you're happy with the plan, you can execute it. If you saved you plan, you can give it as an argument. Without the saved plan, `apply` will confirm you once more the changes. 

```
$ terraform apply aws-demo.plan
```

### Connect to your infrastructure

You're ready to connect to your infrastructure. The RHEL Amazon Machine Image has `ec2-user` account that we can use to log in. Also, we use `terraform output` command to get the public ip of the bastion host. 


```
$ cd ../
$ ssh -i keys/aws-deployer -l ec2-user $(terraform output bastion_ip)
```

### Destroy your infrastructure

Once you're done with playing with your AWS EC2 machines, you can destroy them with `terraform destroy`

```
$ cd terraform/
$ terraform destroy
```

Code walkthrough
----------------

In this chapter we go through the relevant parts of the terraform code.
 
### Variables

The terraform plan can be parameterized with command line `-var` options, or separate parameter files. By default terraform reads variables from `terraform.tfvars` and `*.auto.tfvars` files. 

In this demo we have parametrized couple of things. Such as key names and files, AWS region and Amazon Machine Image properties (see `variables.auto.tfvars`).

In order to the variables to be loaded, they need to have placeholder defined in `*.tf` file. In this demo we have own `variables.tf` that contains the placeholders, but they could easily be in the `aws-demo.tf` as well.

The variables can be referred in terraform files with `var.` prefix, for example `${var.key_name}`. 

Note that `terraform` command reads always all `*.tf` files in the working directory.

### Keys 

Typically you cannot access the hosts that you create unless you define key pair and define the public key to the created hosts. In this example we have automated that process as well by using the rsa key created with `setup-keys.sh`. 

```hcl
resource "aws_key_pair" "deployer" {
  key_name   = "${var.key_name}"
  public_key = "${file(var.key_file)}"
}
```

### Amazon Machine Image

Amazon machine images are identified by `ami id`. Easiest way is to hardcode the `ami id` directly in your script. However, in this demo we use `aws_ami` date source (named as "rhel75") to query amazon for image that matches to our criteria: 

* defined owner
* name match
* most recent 

```hcl
data "aws_ami" "rhel75" {
  most_recent = true

  owners = ["${var.ami_owner}"]

  filter {
    name   = "name"
    values = ["${var.ami_name}"]
  }
}
```

Note that you can use `aws` commandline tool (https://aws.amazon.com/cli/) to query the images, and try out different filtering criterias. 

With the data source defined, we can refer to the fetched `ami id` with `${data.aws_ami.rhel75.image_id}`. 

### Virtual Private Cloud

We create own virtual private cloud (VPC) for all the hosts created in this demo. This is done simply by defining top level cidr block for our private cloud.

```hcl
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags {
    Name = "main"
  }
}
```

### Subnets and routes

Once we have defined the VPC, we can allocate subnets for our hosts. We define two subnets (dmz and app), and for dmz we instruct to allocate public ip addresses on launch. 

```hcl
resource "aws_subnet" "dmz" {
  vpc_id                  = "${aws_vpc.main.id}"
  cidr_block              = "${cidrsubnet(aws_vpc.main.cidr_block, 8, 1)}"
  map_public_ip_on_launch = true
}
```

Additionally we define gateway for Internet connectivity, and define the necessary route for it.

```hcl
resource "aws_internet_gateway" "internet" {
  vpc_id = "${aws_vpc.main.id}"

  tags {
    Name = "main"
  }
}

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
```

### Security groups / Firewall

In order to access the hosts created in our subnets, we need to define security group and associate them to the each host. First we define the security group where we accept only incoming ssh from any host, and all outgoing traffic to any host. 

```hcl
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
```

### Instances

Finally we are ready to define the actual hosts. At this point we can refer to other resources that we have created so far, such as: 
* amazon machine identifier
* ssh key
* subnet
* security group

In this example we also allocate specific private IP address for the host. AWS reserves couple of first IP addresses for each cidr block for internal use, so we start the numbering from `.10`.

```hcl
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
}
```

The app hosts are almost identical, we define to have three of them and create them of course in their respective subnet.

```hcl
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
```

### Output, templates, provisioners

Finally, we can look what to provide the information about built infrastructure to next steps (e.g. ansible). In this example we create simple ansible inventory file by using `template_file` date source, and dummy `null_resource` resource to call the `local-exec` provisioner. 

```hcl
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
```

This will create `../ansible_inventory.properties` file that contains public ip of bastion host, and private addresses for application hosts.

The more direct approach is to define `output` values for terraform.

```hcl
output "bastion_ip" {
    value = "${aws_instance.bastion.public_ip}"
}
``` 

The value of output values can be accessed with following command

```
$ terraform output bastion_ip
```
