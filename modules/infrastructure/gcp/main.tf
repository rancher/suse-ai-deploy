locals {
  instance_count       = var.ha_setup ? 3 : 1
  is_ha                = var.ha_setup && local.instance_count == 3
  private_ssh_key_path = var.ssh_private_key_path == null ? "${path.cwd}/${var.prefix}-ssh_private_key.pem" : var.ssh_private_key_path
  public_ssh_key_path  = var.ssh_public_key_path == null ? "${path.cwd}/${var.prefix}-ssh_public_key.pem" : var.ssh_public_key_path
  ssh_username         = "opensuse"
  common_labels = {
    workload = "ai"
  }
  certified_image_name   = "opensuse-leap-15-6-suse-ai-deploy-cloud-image.x86_64.raw.tar.gz"
  certified_image_url    = "https://github.com/rancher/suse-ai-deploy/releases/download/${var.certified_os_image_tag}/${local.certified_image_name}"
  certified_image_sha512 = "806fcc47b510ac8e63b9ca1550a872958a0bfbdb4e74fadad0f6c91810aee1a954dab7d1b273a6e5b09300908ce4445f915b10618ad647a647b18718dfff84ab"
  ha_ingress_rules = local.is_ha ? [
    { description = "RKE2 node join", priority = 1000, direction = "INGRESS", protocol = "tcp", ports = ["9345"], source_ranges = ["0.0.0.0/0"], source_tags = [], target_tags = ["rke2-ha"] },
    { description = "etcd client port", priority = 1001, direction = "INGRESS", protocol = "tcp", ports = ["2379"], source_ranges = ["0.0.0.0/0"], source_tags = [], target_tags = ["rke2-ha"] },
    { description = "etcd peer port", priority = 1002, direction = "INGRESS", protocol = "tcp", ports = ["2380"], source_ranges = [], source_tags = ["rke2-ha"], target_tags = ["rke2-ha"] },
    { description = "etcd metrics port", priority = 1003, direction = "INGRESS", protocol = "tcp", ports = ["2381"], source_ranges = [], source_tags = ["rke2-ha"], target_tags = ["rke2-ha"] },
    { description = "Canal VXLAN overlay", priority = 1004, direction = "INGRESS", protocol = "udp", ports = ["8472"], source_ranges = [], source_tags = ["rke2-ha"], target_tags = ["rke2-ha"] },
    { description = "Canal health checks", priority = 1005, direction = "INGRESS", protocol = "tcp", ports = ["9099"], source_ranges = [], source_tags = ["rke2-ha"], target_tags = ["rke2-ha"] },
    { description = "Canal WireGuard IPv4", priority = 1006, direction = "INGRESS", protocol = "udp", ports = ["51820"], source_ranges = [], source_tags = ["rke2-ha"], target_tags = ["rke2-ha"] },
    { description = "Canal WireGuard IPv6", priority = 1007, direction = "INGRESS", protocol = "udp", ports = ["51821"], source_ranges = [], source_tags = ["rke2-ha"], target_tags = ["rke2-ha"] },
  ] : []
}

resource "tls_private_key" "ssh_private_key" {
  count     = var.create_ssh_key_pair ? 1 : 0
  algorithm = "ED25519"
}

resource "local_file" "private_key_pem" {
  count           = var.create_ssh_key_pair ? 1 : 0
  filename        = local.private_ssh_key_path
  content         = tls_private_key.ssh_private_key[0].private_key_openssh
  file_permission = "0600"
}

resource "local_file" "public_key_pem" {
  count           = var.create_ssh_key_pair ? 1 : 0
  filename        = local.public_ssh_key_path
  content         = tls_private_key.ssh_private_key[0].public_key_openssh
  file_permission = "0600"
}

resource "null_resource" "download_image" {
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

resource "google_storage_bucket" "images_bucket" {
  name          = "${var.prefix}-certified-img-bucket"
  location      = var.region
  force_destroy = true
  labels        = local.common_labels
}

resource "google_storage_bucket_object" "certified_image" {
  depends_on = [null_resource.download_image]
  name       = "${var.prefix}-image-raw.tar.gz"
  bucket     = google_storage_bucket.images_bucket.name
  source     = "${path.cwd}/${local.certified_image_name}"
}

resource "google_compute_image" "upload_certified_image" {
  depends_on = [google_storage_bucket_object.certified_image]
  name       = "${var.prefix}-opensuse-certified-img"
  labels     = local.common_labels
  raw_disk {
    source = "https://storage.googleapis.com/${google_storage_bucket.images_bucket.name}/${google_storage_bucket_object.certified_image.name}"
  }
}

resource "google_compute_network" "vpc" {
  count                   = var.create_vpc == true ? 1 : 0
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = "false"
}

resource "google_compute_subnetwork" "subnet" {
  count         = var.create_vpc == true ? 1 : 0
  name          = "${var.prefix}-subnet"
  region        = var.region
  network       = var.vpc == null ? resource.google_compute_network.vpc[0].name : var.vpc
  ip_cidr_range = var.ip_cidr_range
}

resource "google_compute_firewall" "firewall_22" {
  count   = var.create_firewall ? 1 : 0
  name    = "${var.prefix}-firewall-22"
  network = var.vpc == null ? resource.google_compute_network.vpc[0].name : var.vpc
  allow {
    protocol = "icmp"
  }
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = var.public_ip_source_addresses
  target_tags   = ["${var.prefix}"]
}

resource "google_compute_firewall" "default" {
  count   = var.create_firewall ? 1 : 0
  name    = "${var.prefix}-firewall"
  network = var.vpc == null ? resource.google_compute_network.vpc[0].name : var.vpc
  allow {
    protocol = "icmp"
  }
  allow {
    protocol = "tcp"
    ports    = ["80", "6443", "443"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.prefix}"]
}

resource "google_compute_firewall" "ha_firewall" {
  for_each = {
    for rule in local.ha_ingress_rules :
    rule.description => rule
  }

  name    = "${var.prefix}-${replace(lower(each.value.description), " ", "-")}"
  network = var.vpc == null ? google_compute_network.vpc[0].name : var.vpc

  allow {
    protocol = each.value.protocol
    ports    = each.value.ports
  }

  source_ranges = lookup(each.value, "source_ranges", null)
  source_tags   = lookup(each.value, "source_tags", null)

  target_tags = local.is_ha ? ["${var.prefix}", "rke2-ha"] : ["${var.prefix}"]
  priority    = each.value.priority
}

data "google_compute_zones" "available" {
  region = var.region
  status = "UP"
}

resource "random_string" "random" {
  length  = 4
  lower   = true
  numeric = false
  special = false
  upper   = false
}


resource "google_compute_instance" "default" {
  count        = local.instance_count
  name         = "${var.prefix}-vm-${count.index + 1}-${random_string.random.result}"
  machine_type = var.instance_type
  zone         = var.zone
  tags         = local.is_ha ? ["${var.prefix}", "rke2-ha"] : ["${var.prefix}"]
  labels       = local.common_labels
  scheduling {
    preemptible         = var.spot_instance
    provisioning_model  = var.spot_instance ? "SPOT" : "STANDARD"
    automatic_restart   = var.spot_instance ? false : true
    on_host_maintenance = "TERMINATE"
  }
  boot_disk {
    initialize_params {
      type  = var.os_disk_type
      size  = var.os_disk_size
      image = google_compute_image.upload_certified_image.self_link
    }
  }
  # Add GPU here:
  guest_accelerator {
    type  = var.gpu_type  # e.g., "nvidia-tesla-t4"
    count = var.gpu_count # e.g., 1
  }

  dynamic "scratch_disk" {
    for_each = []
    content {
      interface = "SCSI"
    }
  }

  network_interface {
    network    = var.vpc == null ? resource.google_compute_network.vpc[0].name : var.vpc
    subnetwork = var.subnet == null ? resource.google_compute_subnetwork.subnet[0].name : var.subnet
    access_config {}
  }
  metadata = {
    serial-port-logging-enable = "TRUE"
    serial-port-enable         = "TRUE"
    ssh-keys                   = var.create_ssh_key_pair ? "${local.ssh_username}:${tls_private_key.ssh_private_key[0].public_key_openssh}" : "${local.ssh_username}:${file(local.public_ssh_key_path)}"
    startup-script = templatefile("${path.module}/../scripts/startupscript.tftpl", {
      cloud_provider = "gcp"
      hostname       = "${var.prefix}-rke2-${count.index + 1}"
    })
  }
  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      boot_disk[0].initialize_params[0].image
    ]
  }
}

resource "null_resource" "wait_for_gpu" {
  # This ensures the GPU driver and compute utils are installed correctly only starts after the VM is actually created
  depends_on = [google_compute_instance.default]

  provisioner "remote-exec" {
    connection {
      type = "ssh"
      user = local.ssh_username
      # Use the private key generated by your tls_private_key resource
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
      host        = google_compute_instance.default[0].network_interface[0].access_config[0].nat_ip
      timeout     = "15m"
    }

    inline = [
      "echo 'Waiting for GPU Driver installation to complete...'",
      # This loop waits for nvidia-smi to be available in the PATH
      # timeout 600 ensures it doesn't loop forever (10 minutes max)
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
        public_ip      = google_compute_instance.default[0].network_interface[0].access_config[0].nat_ip
        rke2_version   = var.rke2_version
        cloud_provider = "gcp"
      })
    ]

    connection {
      type        = "ssh"
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
      host        = google_compute_instance.default[0].network_interface[0].access_config[0].nat_ip
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
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
      host        = google_compute_instance.default[0].network_interface[0].access_config[0].nat_ip
    }
  }

  provisioner "local-exec" {
    command = <<EOT
scp -o StrictHostKeyChecking=no \
-i ${local.private_ssh_key_path} \
${local.ssh_username}@${google_compute_instance.default[0].network_interface[0].access_config[0].nat_ip}:/tmp/rke2-token ./rke2-token
EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f ./rke2-token"
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
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
      host        = google_compute_instance.default[count.index + 1].network_interface[0].access_config[0].nat_ip
    }
  }

  provisioner "remote-exec" {
    inline = [
      templatefile("${path.module}/../scripts/rke2-localpath-join-server-install.sh", {
        public_ip    = google_compute_instance.default[count.index + 1].network_interface[0].access_config[0].nat_ip
        private_ip   = google_compute_instance.default[0].network_interface[0].network_ip
        rke2_version = var.rke2_version
      })
    ]

    connection {
      type        = "ssh"
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
      host        = google_compute_instance.default[count.index + 1].network_interface[0].access_config[0].nat_ip
    }
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
      host        = google_compute_instance.default[0].network_interface[0].access_config[0].nat_ip
    }
  }

  provisioner "local-exec" {
    command = <<EOT
      scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -i ${local.private_ssh_key_path} \
          ${local.ssh_username}@${google_compute_instance.default[0].network_interface[0].access_config[0].nat_ip}:/tmp/rke2.yaml \
          ./kubeconfig-rke2.yaml
      
      # Detect OS and run the correct sed command
      if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/127.0.0.1/${google_compute_instance.default[0].network_interface[0].access_config[0].nat_ip}/g" ./kubeconfig-rke2.yaml
      else
        sed -i "s/127.0.0.1/${google_compute_instance.default[0].network_interface[0].access_config[0].nat_ip}/g" ./kubeconfig-rke2.yaml
      fi
      
      echo "Kubeconfig successfully retrieved and updated."
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f ./kubeconfig-rke2.yaml"
  }
}



#resource "null_resource" "cleanup_certified_raw" {
#  depends_on = [null_resource.retrieve_kubeconfig]
#  provisioner "local-exec" {
#    when    = destroy
#    command = "rm ${path.cwd}/opensuse-leap-15-6-suse-ai-deploy-cloud-image.x86_64.raw.tar.gz"
#  }
#}
