provider "archive" {version = "~> 1.1"}
provider "local" {version = "~> 1.1"}
provider "null" {version = "~> 1.0"}
provider "random" {version = "~> 2.0"}

resource "random_id" "force_download" {byte_length=12}

data "local_file" "backup_lambda_ssh_private_key" {
  count = "${var.backup_lambda_ssh_private_key == "" ? 1 : 0}"

  filename = "${var.backup_lambda_ssh_private_key_path}"
}

resource "aws_s3_bucket_object" "encrypted_ssh_key" {
  count      = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  depends_on = ["data.aws_kms_ciphertext.encrypt_ssh_operation", "local_file.EncryptedSSHKey"]
  bucket     = "${aws_s3_bucket.quorum_backup.id}"
  key        = "${var.enc_ssh_key}"
  source     = "${var.enc_ssh_path}-${var.aws_region}"
}

resource "aws_sns_topic" "backup_event" {
  count       = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  name_prefix = "BackupLambda-${var.network_id}-${var.aws_region}-"
}

resource "aws_cloudwatch_event_rule" "backup_timer" {
  count               = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  name_prefix         = "BackupLambda-${var.network_id}-${var.aws_region}-" 
  schedule_expression = "${var.backup_interval}"
}

resource "aws_cloudwatch_event_target" "sns" {
  count     = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"  
  rule      = "${aws_cloudwatch_event_rule.backup_timer.name}"
  target_id = "SendToSNS"
  arn       = "${aws_sns_topic.backup_event.arn}"
}

resource "aws_sns_topic_subscription" "backup_lambda" {
  count     = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  topic_arn = "${aws_sns_topic.backup_event.arn}"
  protocol  = "lambda"
  endpoint  = "${aws_lambda_function.backup_lambda.arn}"
}

# Allow the SNS to trigger the backup lambda
resource "aws_lambda_permission" "backup_lambda" {
  count         = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  statement_id  = "AllowExecutionFromSNS-BackupLambda-${var.network_id}-${var.aws_region}"
  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.backup_lambda.arn}"
  principal     = "sns.amazonaws.com"
  source_arn    = "${aws_sns_topic.backup_event.arn}"
}

resource "aws_sns_topic_policy" "default" {
  count = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  arn    = "${aws_sns_topic.backup_event.arn}"
  policy = "${data.aws_iam_policy_document.sns_topic_policy.json}"
}

data "aws_iam_policy_document" "sns_topic_policy" {
  count = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  statement {
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = ["${aws_sns_topic.backup_event.arn}"]
  }
}

# Declare the Backup Lambda
# Lambdas are by default in a VPC
resource "aws_lambda_function" "backup_lambda" {
    count = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
    depends_on = ["aws_s3_bucket.quorum_backup", "aws_nat_gateway.backup_lambda",
    "null_resource.zip_backup_lambda"]
    filename         = "${var.aws_region}-${var.backup_lambda_output_path}"
    function_name    = "BackupLambda-${var.network_id}-${var.aws_region}"
    handler          = "BackupLambda" # Name of Go package after unzipping the filename above
    role             = "${aws_iam_role.backup_lambda.arn}"
    runtime          = "go1.x"
    source_code_hash = "${sha256("file(${var.aws_region}-${var.backup_lambda_output_path})")}" # 
    timeout          = 300

    vpc_config {
       subnet_ids = ["${aws_subnet.backup_lambda.id}"]
       security_group_ids = ["${aws_security_group.allow_all.*.id}"]
    }

    environment {
        variables {
            NetworkId = "${var.network_id}"
            Bucket = "${aws_s3_bucket.quorum_backup.id}"
            Key = "${var.enc_ssh_key}"
            SSHUser = "ubuntu"
        }
    }
}

resource "aws_iam_role" "backup_lambda" {
  count = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  name = "iam_for_backup_lambda-${var.network_id}-${var.aws_region}"
# See also https://aws.amazon.com/blogs/compute/easy-authorization-of-aws-lambda-functions/
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com",
        "Service": "events.amazonaws.com",
        "Service": "sns.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy" "backup_lambda_permissions" {
  count = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  path = "/"
  description = "IAM policy for accesing EC2 and S3 buckets from Lambda"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "ec2:*"
      ],
      "Effect": "Allow",
      "Resource": "*"
    },
    {
      "Action": ["s3:*"],
      "Effect": "Allow",
      "Resource": [
        "${aws_s3_bucket.quorum_backup.arn}",
        "${aws_s3_bucket.quorum_backup.arn}/*"
      ]
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "allow_backup_lambda_access_s3_and_ec2_resources" {
   count      = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
   role       = "${aws_iam_role.backup_lambda.name}"
   policy_arn = "${aws_iam_policy.backup_lambda_permissions.arn}"
}


resource "aws_iam_policy" "allow_backup_lambda_logging" {
  count = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  name = "BackupLambda-${var.network_id}-${var.aws_region}"
  path = "/"
  description = "IAM policy for logging from a lambda"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "logs:*"
      ],
      "Resource": "arn:aws:logs:*:*:*",
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "allow_backup_lambda_logging" {
   count = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
   role = "${aws_iam_role.backup_lambda.name}"
   policy_arn = "${aws_iam_policy.allow_backup_lambda_logging.arn}"
}

resource "null_resource" "makedir" {
  count = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  provisioner "local-exec" {
    command = "mkdir ${var.aws_region}"
  }
  provisioner "local-exec" {
    when = "destroy"
    command = "rm -rf ${var.aws_region}"
    on_failure = "continue"
  }
}

resource "null_resource" "fetch_backup_lambda" {
  count = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  provisioner "local-exec" {
    command = "wget -O ${var.aws_region}/${var.backup_lambda_binary} ${var.backup_lambda_binary_url}"
  }
  provisioner "local-exec" {
    when = "destroy"
    command = "rm ${var.aws_region}/${var.backup_lambda_binary}"
    on_failure = "continue"
  }
  depends_on = ["null_resource.makedir"]
}

resource "null_resource" "make_executable_permission" {
  count = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  provisioner "local-exec" {
    command = "chmod a+x ${var.aws_region}/${var.backup_lambda_binary}"
  }
  provisioner "local-exec" {
    when = "destroy"
    command = "chmod a-x ${var.aws_region}/${var.backup_lambda_binary}"
    on_failure = "continue"
  }
  depends_on = ["null_resource.fetch_backup_lambda"]
}

resource "null_resource" "zip_backup_lambda" {
  count = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  provisioner "local-exec" {
    command = "zip -j BackupLambda ${var.aws_region}/${var.backup_lambda_binary}"
  }
  provisioner "local-exec" {
    when = "destroy"
    command = "rm BackupLambda.zip"
    on_failure = "continue"
  }
  depends_on = ["null_resource.fetch_backup_lambda", "null_resource.make_executable_permission"]
}

resource "aws_kms_key" "ssh_encryption_key" {
  count       = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  description = "Used for encrypting SSH keys on S3"
  tags {
     name = "BackupLambda-${var.network_id}-${var.aws_region}-KMS"
  }
}

# Encrypt the contents of the file located at var.backup_lambda_ssh_private_key_path
data "aws_kms_ciphertext" "encrypt_ssh_operation" {
  count     = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  key_id    = "${aws_kms_key.ssh_encryption_key.id}"  
  plaintext = "${var.backup_lambda_ssh_private_key}"
}

# Save the encrypted contents to the file specified at filename
resource "local_file" "EncryptedSSHKey" {
  count    = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  content  = "${base64decode("${data.aws_kms_ciphertext.encrypt_ssh_operation.ciphertext_blob}")}"
  filename = "${var.enc_ssh_path}-${var.aws_region}"
}

resource "aws_kms_grant" "backup_lambda" {
  count             = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  name              = "kms-grant-${var.network_id}-${var.aws_region}"
  key_id            = "${aws_kms_key.ssh_encryption_key.key_id}"
  grantee_principal = "${aws_iam_role.backup_lambda.arn}"
  operations        = ["Encrypt", "Decrypt"]
}

resource "aws_security_group" "allow_all" {
    count       = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
    name        = "BackupLambdaSSH-${var.network_id}-${var.aws_region}-allow_all"
    description = "Allow all outgoing traffic"
    vpc_id      = "${aws_vpc.quorum_cluster.id}"

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
        description = "Allow all traffic"
    }
    ingress {
      from_port = 22
      to_port = 22
      protocol = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "Allow all SSH traffic"
    }
  tags {
     name = "BackupLambda-${var.network_id}-${var.aws_region}-SG"
  }
}

// use the next value after data.template_file.quorum_observer_cidr_block
data "template_file" "quorum_maker_cidr_block_lambda" {
  template = "$${cidr_block}"

  vars {
    cidr_block = "${cidrsubnet(data.template_file.quorum_cidr_block.rendered, 2, 3)}"
  }
}

resource "aws_subnet" "backup_lambda" {
  count              = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  vpc_id             = "${aws_vpc.quorum_cluster.id}"
  availability_zone  = "${lookup(var.az_override, var.aws_region, "") == "" ? element(data.aws_availability_zones.available.names, count.index) : element(split(",", lookup(var.az_override, var.aws_region, "")), count.index)}"
  cidr_block         = "${cidrsubnet(data.template_file.quorum_maker_cidr_block_lambda.rendered, 3, count.index)}"
  tags {
    Name      = "quorum-network-${var.network_id}-BackupLambda-NAT"
    NodeType  = "BackupLambda"
    NetworkId = "${var.network_id}"
    Region    = "${var.aws_region}"
  }
}

resource "aws_eip" "gateway_ip" {
  count      = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  vpc        = true
  depends_on = ["aws_internet_gateway.quorum_cluster"]
  tags {
    Name      = "quorum-network-${var.network_id}-BackupLambda"
    NodeType  = "BackupLambda-EIP"
    NetworkId = "${var.network_id}"
    Region    = "${var.aws_region}"
  }
}

resource "aws_nat_gateway" "backup_lambda" {
  count         = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  allocation_id = "${aws_eip.gateway_ip.0.id}"
  subnet_id     = "${aws_subnet.quorum_maker.0.id}"
  depends_on    = ["aws_internet_gateway.quorum_cluster"]
  tags {
    Name      = "quorum-network-${var.network_id}-BackupLambda-NAT"
    NodeType  = "NAT"
    NetworkId = "${var.network_id}"
    Region    = "${var.aws_region}"
  }
}

data "aws_ami" "nat" {
  most_recent = true
  filter {
    name   = "name"
    values = ["amzn-ami-vpc-nat*"]
  }
  owners = ["amazon"]
}

resource "aws_route_table" "backup_lambda" {
  count  = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  vpc_id = "${aws_vpc.quorum_cluster.id}"
  tags {
     Name = "BackupLambdaSSH-${var.network_id}-${var.aws_region}-RouteTable"
  }
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = "${aws_nat_gateway.backup_lambda.0.id}"
  }
}

resource "aws_route_table_association" "backup_lambda" {
  count          = "${signum(lookup(var.maker_node_counts, var.aws_region, 0))}"
  subnet_id      = "${aws_subnet.backup_lambda.id}"
  route_table_id = "${aws_route_table.backup_lambda.id}" 
}