# Specify the provider and access details
provider "aws" {
  profile = "${var.aws_profile}"
  region = "${var.aws_region}"
}

# Runs a local script to return the current user in bash
data "external" "whoami" {
  program = ["${path.module}/scripts/local/whoami.sh"]
}

resource "random_id" "uuid" {
  byte_length = 8
}

# Allow overrides of the owner variable or default to whoami.sh
data "template_file" "cluster-name" {
 template = "$${username}-tf$${uuid}"

  vars {
    uuid = "${lower(substr(random_id.uuid.hex,0,4))}"
    username = "${format("%.10s", coalesce(var.owner, data.external.whoami.result["owner"]))}"
  }
}

# Create a VPC to launch our instances into
resource "aws_vpc" "default" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = "true"

  tags {
    Name = "${data.template_file.cluster-name.rendered}-vpc"
    cluster = "${data.template_file.cluster-name.rendered}"
  }
}

# Create DCOS Bucket regardless of what exhibitor backend was chosen
resource "aws_s3_bucket" "dcos_bucket" {
  bucket = "${data.template_file.cluster-name.rendered}-bucket"
  acl    = "private"
  force_destroy = "true"

  tags {
    Name = "${data.template_file.cluster-name.rendered}-bucket"
    cluster = "${data.template_file.cluster-name.rendered}"
  }
}

# Create public route table with internet gateway route
resource "aws_route_table" "public-route-table" {
  vpc_id = "${aws_vpc.default.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.default.id}"
  }

  tags {
    Name = "${data.template_file.cluster-name.rendered}-pub-rt"
    cluster = "${data.template_file.cluster-name.rendered}"
  }
}

# Create private route table with nat gateway route
resource "aws_route_table" "private-route-table" {
  vpc_id = "${aws_vpc.default.id}"

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = "${aws_nat_gateway.default.id}"
  }

  tags {
    Name = "${data.template_file.cluster-name.rendered}-priv-rt"
    cluster = "${data.template_file.cluster-name.rendered}"
  }
}

# Create an internet gateway to give our subnet access to the outside world
resource "aws_internet_gateway" "default" {
  vpc_id = "${aws_vpc.default.id}"

  tags {
    Name = "${data.template_file.cluster-name.rendered}-ig"
    cluster = "${data.template_file.cluster-name.rendered}"
  }
}

resource "aws_eip" "nat-eip" {
  vpc = true
}

resource "aws_nat_gateway" "default" {
  allocation_id = "${aws_eip.nat-eip.id}"
  subnet_id     = "${aws_subnet.public.id}"

  tags {
    Name = "${data.template_file.cluster-name.rendered}-ng"
    cluster = "${data.template_file.cluster-name.rendered}"
  }
}

# Create a subnet to launch public nodes into
resource "aws_subnet" "public" {
  vpc_id                  = "${aws_vpc.default.id}"
  cidr_block              = "10.0.0.0/22"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_availability_zone}"

  tags {
    Name = "${data.template_file.cluster-name.rendered}-pub-sub"
    cluster = "${data.template_file.cluster-name.rendered}"
  }
}

# Create a subnet to launch slave private node into
resource "aws_subnet" "private" {
  vpc_id                  = "${aws_vpc.default.id}"
  cidr_block              = "10.0.4.0/22"
  map_public_ip_on_launch = false
  availability_zone       = "${var.aws_availability_zone}"

  tags {
    Name = "${data.template_file.cluster-name.rendered}-priv-sub"
    cluster = "${data.template_file.cluster-name.rendered}"
  }
}

# A security group that allows all port access to internal vpc and to talk to
# internet
resource "aws_security_group" "any-access-internal" {
  name = "any-access-internal-sg"

  description = "Manage all ports cluster level"
  vpc_id      = "${aws_vpc.default.id}"

  # full access internally
  ingress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["${aws_vpc.default.cidr_block}"]
  }

  # internet access
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "any-access-internal-sg"
    cluster = "${data.template_file.cluster-name.rendered}"
  }
}

resource "aws_security_group" "bootstrap" {
  name = "bootstrap-sg"
  description = "Public bootstrap"
  vpc_id      = "${aws_vpc.default.id}"

  # SSH in
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # OpenVPN in
  ingress {
    from_port   = 1194
    to_port     = 1194
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "bootstrap-sg"
    cluster = "${data.template_file.cluster-name.rendered}"
  }
}

# A security group for the ELB so it is accessible via the web
# with some master ports for internal access only
resource "aws_security_group" "internal-master-elb" {
  name = "internal-master-elb-sg"
  description = "Security group for masters"
  vpc_id      = "${aws_vpc.default.id}"

  # Mesos Master access from within the vpc
  ingress {
    to_port = 5050
    from_port = 5050
    protocol = "tcp"
    cidr_blocks = ["${aws_vpc.default.cidr_block}"]
  }

  # Adminrouter access from within the vpc
  ingress {
    to_port = 80
    from_port = 80
    protocol = "tcp"
    cidr_blocks = ["${var.admin_cidr}"]
  }

  # Adminrouter SSL access from anywhere
  ingress {
    to_port = 443
    from_port = 443
    protocol = "tcp"
    cidr_blocks = ["${var.admin_cidr}"]
  }

  # Marathon access from within the vpc
  ingress {
    to_port = 8080
    from_port = 8080
    protocol = "tcp"
    cidr_blocks = ["${aws_vpc.default.cidr_block}"]
  }

  # Exhibitor access from within the vpc
  ingress {
    to_port = 8181
    from_port = 8181
    protocol = "tcp"
    cidr_blocks = ["${aws_vpc.default.cidr_block}"]
  }

  # Zookeeper Access from within the vpc
  ingress {
    to_port = 2181
    from_port = 2181
    protocol = "tcp"
    cidr_blocks = ["${aws_vpc.default.cidr_block}"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "internal-master-elb-sg"
    cluster = "${data.template_file.cluster-name.rendered}"
  }
}

# A security group for public slave so it is accessible via the web
resource "aws_security_group" "public-elb" {
  name = "public-elb-sg"

  description = "security group for public elb"
  vpc_id      = "${aws_vpc.default.id}"

  # Allow ports within range
  ingress {
    to_port = 21
    from_port = 0
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow ports within range
  ingress {
    to_port = 5050
    from_port = 23
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow ports within range
  ingress {
    to_port = 32000
    from_port = 5052
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow ports within range
  ingress {
    to_port = 21
    from_port = 0
    protocol = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow ports within range
  ingress {
    to_port = 5050
    from_port = 23
    protocol = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow ports within range
  ingress {
    to_port = 32000
    from_port = 5052
    protocol = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "public-elb-sg"
    cluster = "${data.template_file.cluster-name.rendered}"
  }
}

# Assign route tables to subnets
resource "aws_route_table_association" "public-routes-public-subnet" {
  route_table_id = "${aws_route_table.public-route-table.id}"
  subnet_id      = "${aws_subnet.public.id}"
}

resource "aws_route_table_association" "private-routes-private-subnet" {
  route_table_id = "${aws_route_table.private-route-table.id}"
  subnet_id      = "${aws_subnet.private.id}"
}

# Provide tested AMI and user from listed region startup commands
module "aws-tested-oses" {
  source        = "./modules/dcos-tested-aws-oses"
  os            = "${var.os}"
  region        = "${var.aws_region}"
  user_aws_ami  = "${var.user_aws_ami}"
}
