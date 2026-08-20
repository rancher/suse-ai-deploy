data "aws_caller_identity" "current" {}

locals {
  instance_count         = var.ha_setup ? 3 : 1
  is_ha                  = var.ha_setup && local.instance_count == 3
  private_ssh_key_path   = var.ssh_private_key_path == null ? "${path.cwd}/${var.prefix}-ssh_private_key.pem" : var.ssh_private_key_path
  public_ssh_key_path    = var.ssh_public_key_path == null ? "${path.cwd}/${var.prefix}-ssh_public_key.pem" : var.ssh_public_key_path
  target_vpc_id          = var.use_existing_vpc ? var.vpc_id : aws_vpc.default_vpc[0].id
  target_subnet_id       = var.use_existing_vpc ? var.subnet_id : aws_subnet.default_subnet[0].id
  host                   = var.associate_public_ip ? aws_instance.opensuse_gpu[0].public_ip : aws_instance.opensuse_gpu[0].private_ip
  ssh_username           = "opensuse"
  certified_image_name   = "opensuse-leap-15-6-suse-ai-deploy-cloud-image.x86_64.vhd"
  certified_image_url    = "https://github.com/rancher/suse-ai-deploy/releases/download/${var.certified_os_image_tag}/${local.certified_image_name}"
  certified_image_sha512 = "5d96f40c22786955d19ffdccfe2acb4817717ca476247bf91f870233f25c50da7609e8aa01e8242c3510fe80e20fbb6323a0e19bcd16ac67b66774c17bdaf992"
  username               = element(split("/", data.aws_caller_identity.current.arn), length(split("/", data.aws_caller_identity.current.arn)) - 1)
  common_tags = {
    workload = "AI"
  }

  ha_ingress_rules = local.is_ha ? [
    { description = "RKE2 node join", from_port = 9345, to_port = 9345, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"], self = true },
    { description = "etcd client port", from_port = 2379, to_port = 2379, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"], self = false },
    { description = "etcd peer port", from_port = 2380, to_port = 2380, protocol = "tcp", cidr_blocks = [], self = true },
    { description = "etcd metrics port", from_port = 2381, to_port = 2381, protocol = "tcp", cidr_blocks = [], self = true },
    { description = "Canal VXLAN overlay", from_port = 8472, to_port = 8472, protocol = "udp", cidr_blocks = [], self = true },
    { description = "Canal health checks", from_port = 9099, to_port = 9099, protocol = "tcp", cidr_blocks = [], self = true },
    { description = "Canal WireGuard IPv4", from_port = 51820, to_port = 51820, protocol = "udp", cidr_blocks = [], self = true },
    { description = "Canal WireGuard IPv6", from_port = 51821, to_port = 51821, protocol = "udp", cidr_blocks = [], self = true },
  ] : []
}

# 1. Create the IAM Role
resource "aws_iam_role" "ssm_role" {
  name = "ssm-managed-instance-role"

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

# 2. Attach the AWS Managed Policy for SSM
resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 3. Create the Instance Profile (this is what you attach to the EC2)
resource "aws_iam_instance_profile" "ssm_profile" {
  name = "ssm-instance-profile"
  role = aws_iam_role.ssm_role.name
}

resource "tls_private_key" "ssh_private_key" {
  count     = var.create_ssh_key_pair ? 1 : 0
  algorithm = "ED25519"
}

resource "aws_key_pair" "generated_key" {
  count      = var.create_ssh_key_pair ? 1 : 0
  key_name   = "${var.prefix}-opensuse-key"
  public_key = tls_private_key.ssh_private_key[0].public_key_openssh
}

resource "local_file" "private_key_pem" {
  count           = var.create_ssh_key_pair ? 1 : 0
  filename        = local.private_ssh_key_path
  content         = tls_private_key.ssh_private_key[0].private_key_openssh
  file_permission = "0600"
}

resource "null_resource" "download_certified_vhd" {
  provisioner "local-exec" {
    command = <<-EOT
      set -eu

      FILE="${path.cwd}/${local.certified_image_name}"
      EXPECTED="${local.certified_image_sha512}"

      if [ -f "$FILE" ]; then
        echo "File exists. Verifying checksum..."

        if echo "$EXPECTED  $FILE" | sha512sum -c - >/dev/null 2>&1; then
          echo "Checksum valid. Skipping download."
          exit 0
        else
          echo "Checksum mismatch. Re-downloading..."
          rm -f "$FILE"
        fi
      fi

      echo "Downloading + hashing in one pass..."

      ACTUAL=$(curl -L --fail --retry 5 --retry-delay 5 "${local.certified_image_url}" \
        | tee "$FILE" \
        | sha512sum | awk '{print $1}')

      if [ "$ACTUAL" != "$EXPECTED" ]; then
        echo "ERROR: Checksum mismatch!"
        rm -f "$FILE"
        exit 1
      fi

      echo "Download + checksum verification successful."
    EOT
  }
}

resource "aws_s3_bucket" "images" {
  bucket = "opensuse-vhd-${var.prefix}"
  tags   = local.common_tags
}

resource "aws_s3_object" "vhd" {
  depends_on = [null_resource.download_certified_vhd]
  bucket     = aws_s3_bucket.images.id
  key        = "opensuse-harv.vhd"
  source     = "${path.cwd}/${local.certified_image_name}"
}

resource "aws_iam_role" "vmimport" {
  name = "vmimport"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "vmie.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "vmimport" {
  name = "vmimport"
  role = aws_iam_role.vmimport.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Resource = [
          aws_s3_bucket.images.arn,
          "${aws_s3_bucket.images.arn}/*"
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "ec2:ModifySnapshotAttribute",
          "ec2:CopySnapshot",
          "ec2:RegisterImage",
          "ec2:Describe*"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_ebs_snapshot_import" "opensuse_snapshot" {
  description = "Opensuse Cerfied Image for SUSE AI DEPLOY"
  role_name   = aws_iam_role.vmimport.name
  lifecycle {
    ignore_changes = [description]
  }
  disk_container {
    format = "VHD"
    user_bucket {
      s3_bucket = aws_s3_bucket.images.id
      s3_key    = aws_s3_object.vhd.key
    }
  }
  depends_on = [aws_s3_object.vhd]
}

resource "aws_ami" "opensuse_ami" {
  name                = "opensuse-suse-ai-deploy-ami"
  virtualization_type = "hvm"
  root_device_name    = "/dev/xvda"
  ena_support         = true
  ebs_block_device {
    device_name = "/dev/xvda"
    snapshot_id = aws_ebs_snapshot_import.opensuse_snapshot.id
    volume_size = 2
    volume_type = "gp3"
  }
  tags = merge(local.common_tags, { Name = "${var.prefix}-ami" })
}

# VPC
resource "aws_vpc" "default_vpc" {
  count                = var.use_existing_vpc ? 0 : 1
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.common_tags, { Name = "${var.prefix}-vpc" })
}

# Internet Gateway
resource "aws_internet_gateway" "default_igw" {
  count  = var.use_existing_vpc ? 0 : 1
  vpc_id = local.target_vpc_id
  tags   = merge(local.common_tags, { Name = "${var.prefix}-igw" })
}

# Route Table
resource "aws_route_table" "default_rt" {
  count  = var.use_existing_vpc ? 0 : 1
  vpc_id = local.target_vpc_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.default_igw[0].id
  }

  tags = merge(local.common_tags, { Name = "${var.prefix}-rt" })
}

# Subnet
resource "aws_subnet" "default_subnet" {
  count                   = var.use_existing_vpc ? 0 : 1
  vpc_id                  = local.target_vpc_id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags                    = merge(local.common_tags, { Name = "${var.prefix}-subnet" })
}

# Associate Route Table with Subnet
resource "aws_route_table_association" "public_assoc" {
  count          = var.use_existing_vpc ? 0 : 1
  subnet_id      = local.target_subnet_id
  route_table_id = aws_route_table.default_rt[0].id
}

resource "aws_security_group" "default" {
  name        = "${var.prefix}-sg"
  description = "Allow RKE2, SSH, and optional HA inter-node ports"
  vpc_id      = local.target_vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.public_ip_source_addresses
  }

  ingress {
    description = "RKE2 API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "kubelet Metrics"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Kubernetes NodePorts"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = local.ha_ingress_rules
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
      self        = ingress.value.self
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.prefix}-sg" })
}

resource "aws_instance" "opensuse_gpu" {
  count         = local.instance_count
  ami           = aws_ami.opensuse_ami.id
  instance_type = var.instance_type

  key_name                    = var.create_ssh_key_pair ? aws_key_pair.generated_key[0].key_name : var.existing_key_name
  vpc_security_group_ids      = [aws_security_group.default.id]
  subnet_id                   = local.target_subnet_id
  associate_public_ip_address = var.associate_public_ip

  root_block_device {
    volume_size = var.os_disk_size
    volume_type = "gp3"
  }
  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

  user_data = templatefile("${path.module}/../scripts/startupscript.tftpl", {
    cloud_provider = "aws"
    hostname       = "${var.prefix}-rke2-${count.index + 1}"
  })

  tags = merge(local.common_tags, { Name = "${var.prefix}-opensuse-rke2-${count.index + 1}" })
}

resource "null_resource" "wait_for_gpu" {
  count      = local.instance_count
  depends_on = [aws_instance.opensuse_gpu]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
      host        = var.associate_public_ip ? aws_instance.opensuse_gpu[count.index].public_ip : aws_instance.opensuse_gpu[count.index].private_ip
      timeout     = "15m"
    }

    inline = [
      "echo 'Waiting for GPU Driver installation to complete...'",
      "timeout 600 bash -c 'until command -v nvidia-smi &> /dev/null; do echo \"Still waiting for nvidia-smi...\"; sleep 20; done'",
      "echo 'GPU Driver detected!'",
      "nvidia-smi",
      "echo 'Setup script verified. Environment is ready.'"
    ]
  }
}

resource "null_resource" "rke2_installation" {
  depends_on = [null_resource.wait_for_gpu]

  provisioner "remote-exec" {
    inline = [
      templatefile("${path.module}/../scripts/rke2-localpath-install.sh", {
        public_ip      = aws_instance.opensuse_gpu[0].public_ip
        rke2_version   = var.rke2_version
        cloud_provider = "aws"
      })
    ]

    connection {
      type        = "ssh"
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
      host        = local.host
    }
  }
}

resource "null_resource" "join_additional_servers" {
  count = local.is_ha ? local.instance_count - 1 : 0

  depends_on = [
    null_resource.rke2_installation,
    null_resource.get_server_token
  ]

  provisioner "file" {
    source      = "./rke2-token"
    destination = "/tmp/rke2-token"

    connection {
      type        = "ssh"
      host        = var.associate_public_ip ? aws_instance.opensuse_gpu[count.index + 1].public_ip : aws_instance.opensuse_gpu[count.index + 1].private_ip
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
    }
  }

  provisioner "remote-exec" {
    inline = [
      templatefile("${path.module}/../scripts/rke2-localpath-join-server-install.sh", {
        public_ip    = aws_instance.opensuse_gpu[count.index + 1].public_ip
        private_ip   = aws_instance.opensuse_gpu[0].private_ip
        rke2_version = var.rke2_version
      })
    ]

    connection {
      type        = "ssh"
      host        = var.associate_public_ip ? aws_instance.opensuse_gpu[count.index + 1].public_ip : aws_instance.opensuse_gpu[count.index + 1].private_ip
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
    }
  }
}

resource "null_resource" "get_server_token" {
  count      = local.is_ha ? 1 : 0
  depends_on = [null_resource.rke2_installation]

  provisioner "remote-exec" {
    inline = [
      "sudo cat /var/lib/rancher/rke2/server/node-token > /tmp/rke2-token"
    ]

    connection {
      type        = "ssh"
      host        = local.host
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
    }
  }

  provisioner "local-exec" {
    command = <<EOT
scp -o StrictHostKeyChecking=no \
-i ${local.private_ssh_key_path} \
${local.ssh_username}@${local.host}:/tmp/rke2-token ./rke2-token
EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f ./rke2-token"
  }
}

resource "null_resource" "retrieve_kubeconfig" {
  depends_on = [null_resource.rke2_installation]

  provisioner "remote-exec" {
    inline = [
      "sudo cp /etc/rancher/rke2/rke2.yaml /tmp/rke2.yaml",
      "sudo chown ${local.ssh_username} /tmp/rke2.yaml",
      "sudo chmod 644 /tmp/rke2.yaml"
    ]

    connection {
      type        = "ssh"
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
      host        = local.host
    }
  }

  provisioner "local-exec" {
    command = <<EOT
      scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -i ${local.private_ssh_key_path} \
          ${local.ssh_username}@${aws_instance.opensuse_gpu[0].public_ip}:/tmp/rke2.yaml \
          ./kubeconfig-rke2.yaml
      
      # Detect OS and run the correct sed command
      if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/127.0.0.1/${aws_instance.opensuse_gpu[0].public_ip}/g" ./kubeconfig-rke2.yaml
      else
        sed -i "s/127.0.0.1/${aws_instance.opensuse_gpu[0].public_ip}/g" ./kubeconfig-rke2.yaml
      fi
      
      echo "Kubeconfig successfully retrieved and updated."
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f ./kubeconfig-rke2.yaml"
  }
}
