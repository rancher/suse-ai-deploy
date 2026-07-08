locals {
  instance_count         = var.ha_setup ? 3 : 1
  is_ha                  = var.ha_setup && local.instance_count == 3
  private_ssh_key_path   = var.ssh_private_key_path == null ? "${path.cwd}/${var.prefix}-ssh_private_key.pem" : var.ssh_private_key_path
  public_ssh_key_path    = var.ssh_public_key_path == null ? "${path.cwd}/${var.prefix}-ssh_public_key.pem" : var.ssh_public_key_path
  certified_image_name   = "opensuse-leap-15-6-suse-ai-deploy-cloud-image.x86_64.vhd"
  certified_image_url    = "https://github.com/rancher/suse-ai-deploy/releases/download/${var.certified_os_image_tag}/${local.certified_image_name}"
  certified_image_sha512 = "5d96f40c22786955d19ffdccfe2acb4817717ca476247bf91f870233f25c50da7609e8aa01e8242c3510fe80e20fbb6323a0e19bcd16ac67b66774c17bdaf992"
  ssh_username           = "opensuse"
  common_tags = {
    workload = "AI"
  }

  ha_ingress_rules = local.is_ha ? [
    {
      name                       = "rke2-node-join"
      priority                   = 1000
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "9345"
      source_address_prefix      = "*" # Equivalent to 0.0.0.0/0
      destination_address_prefix = "VirtualNetwork"
    },
    {
      name                       = "etcd-client-port"
      priority                   = 1010
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "2379"
      source_address_prefix      = "*"
      destination_address_prefix = "VirtualNetwork"
    },
    {
      name                       = "etcd-peer-port"
      priority                   = 1020
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "2380"
      source_address_prefix      = "VirtualNetwork" # Replaces self=true
      destination_address_prefix = "VirtualNetwork"
    },
    {
      name                       = "etcd-metrics-port"
      priority                   = 1030
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "2381"
      source_address_prefix      = "VirtualNetwork"
      destination_address_prefix = "VirtualNetwork"
    },
    {
      name                       = "canal-vxlan-overlay"
      priority                   = 1040
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Udp"
      source_port_range          = "*"
      destination_port_range     = "8472"
      source_address_prefix      = "VirtualNetwork"
      destination_address_prefix = "VirtualNetwork"
    },
    {
      name                       = "canal-health-checks"
      priority                   = 1050
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "9099"
      source_address_prefix      = "VirtualNetwork"
      destination_address_prefix = "VirtualNetwork"
    },
    {
      name                       = "canal-wireguard-ipv4"
      priority                   = 1060
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Udp"
      source_port_range          = "*"
      destination_port_range     = "51820"
      source_address_prefix      = "VirtualNetwork"
      destination_address_prefix = "VirtualNetwork"
    },
    {
      name                       = "canal-wireguard-ipv6"
      priority                   = 1070
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Udp"
      source_port_range          = "*"
      destination_port_range     = "51821"
      source_address_prefix      = "VirtualNetwork"
      destination_address_prefix = "VirtualNetwork"
    }
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

# --- Networking ---
resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_storage_account" "vhd" {
  name                            = var.prefix
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
  tags                            = local.common_tags
}

resource "azurerm_storage_container" "vhds" {
  name                  = "vhds"
  storage_account_id    = azurerm_storage_account.vhd.id
  container_access_type = "private"
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

resource "azurerm_storage_blob" "suseaitf_vhd" {
  depends_on             = [null_resource.download_certified_vhd]
  name                   = "suseaitfcloudcertified.vhd"
  storage_account_name   = azurerm_storage_account.vhd.name
  storage_container_name = azurerm_storage_container.vhds.name
  type                   = "Page"
  source                 = "${path.cwd}/${local.certified_image_name}"
}

resource "null_resource" "wait_blob_accessible" {
  depends_on = [azurerm_storage_blob.suseaitf_vhd]
  provisioner "local-exec" {
    command = <<EOT
      BLOB_URI=${azurerm_storage_blob.suseaitf_vhd.url}
      ACCOUNT_KEY=$(az storage account keys list -g ${azurerm_resource_group.rg.name} -n ${azurerm_storage_account.vhd.name} --query '[0].value' -o tsv)

      for i in {1..20}; do
        az disk create --name temp-check-disk --resource-group ${azurerm_resource_group.rg.name} --source "$BLOB_URI" --location ${azurerm_resource_group.rg.location} --sku Standard_LRS > /dev/null 2>&1 && break || echo "Blob not ready, retry in 15s" && sleep 15
      done
      echo "blob ready, creating Image from Blob"
      az disk delete --name temp-check-disk -g ${azurerm_resource_group.rg.name} --yes > /dev/null 2>&1
    EOT
  }
}

resource "azurerm_image" "suseaitf" {
  depends_on          = [null_resource.wait_blob_accessible]
  name                = "SUSEAITFCloudCertifiedImage"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.common_tags
  os_disk {
    os_type      = "Linux"
    os_state     = "Generalized"
    blob_uri     = azurerm_storage_blob.suseaitf_vhd.url
    storage_type = "Standard_LRS"
  }
}

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.prefix}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.common_tags
}

resource "azurerm_subnet" "subnet" {
  name                 = "${var.prefix}-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "pip" {
  count               = local.instance_count
  name                = "${var.prefix}-pip-${count.index + 1}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

# --- Security Groups (NSG) ---
resource "azurerm_network_security_group" "default" {
  name                = "${var.prefix}-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  # Rule 1: SSH
  security_rule {
    name                       = "SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.public_ip_source_addresses # Ensure this variable is a list of CIDRs
    destination_address_prefix = "*"
  }

  # Rule 2: RKE2 API
  security_rule {
    name                       = "RKE2_API"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Rule 3: Kubelet Metrics
  security_rule {
    name                       = "Kubelet_Metrics"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "10250"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Rule 4: Kubernetes NodePorts
  security_rule {
    name                       = "Kubernetes_NodePorts"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "30000-32767" # Azure handles port ranges using a hyphen string
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Rule 5: HTTP
  security_rule {
    name                       = "HTTP"
    priority                   = 140
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Rule 6: HTTPS
  security_rule {
    name                       = "HTTPS"
    priority                   = 150
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Dynamic Rules for HA Ingress
  dynamic "security_rule" {
    for_each = local.ha_ingress_rules
    content {
      name                       = security_rule.value.name # Changed from .description
      priority                   = security_rule.value.priority
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = security_rule.value.protocol
      source_port_range          = "*"
      destination_port_range     = security_rule.value.destination_port_range # Changed inline ternary expression
      source_address_prefix      = security_rule.value.source_address_prefix  # Changed from conditional ternary on .self
      destination_address_prefix = security_rule.value.destination_address_prefix
    }

  }
  tags = merge(local.common_tags, { Name = "${var.prefix}-nsg" })
}

resource "azurerm_network_interface" "nic" {
  count               = local.instance_count
  name                = "${var.prefix}-nic-${count.index + 1}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip[count.index].id
  }
  tags = local.common_tags
}

resource "azurerm_network_interface_security_group_association" "nic_nsg" {
  count                     = local.instance_count
  network_interface_id      = azurerm_network_interface.nic[count.index].id
  network_security_group_id = azurerm_network_security_group.default.id

  depends_on = [
    azurerm_network_interface.nic
  ]
}

# --- Virtual Machine ---
resource "azurerm_linux_virtual_machine" "opensuse_gpu" {
  count               = local.instance_count
  name                = "${var.prefix}-vm-${count.index + 1}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.instance_type # e.g., Standard_NC6s_v3
  admin_username      = local.ssh_username

  network_interface_ids = [azurerm_network_interface.nic[count.index].id]

  admin_ssh_key {
    username   = local.ssh_username
    public_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].public_key_openssh : file(local.public_ssh_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size
  }

  source_image_id = azurerm_image.suseaitf.id

  custom_data = base64encode(templatefile("${path.module}/../scripts/startupscript.tftpl", {
    cloud_provider = "azure"
    hostname       = "${var.prefix}-rke2-${count.index + 1}"
  }))

  tags = merge(local.common_tags, { Name = "${var.prefix}-opensuse-rke2" })
}

# --- Provisioning Logic ---

resource "null_resource" "wait_for_gpu" {
  count      = local.instance_count
  depends_on = [azurerm_linux_virtual_machine.opensuse_gpu]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
      host        = azurerm_public_ip.pip[0].ip_address
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
        public_ip      = azurerm_public_ip.pip[0].ip_address
        rke2_version   = var.rke2_version
        cloud_provider = "azure"
      })
    ]

    connection {
      type        = "ssh"
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
      host        = azurerm_public_ip.pip[0].ip_address
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
      type = "ssh"
      # Azure uses public_ip_address and private_ip_address attributes
      host        = azurerm_linux_virtual_machine.opensuse_gpu[count.index + 1].public_ip_address
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
    }
  }

  provisioner "remote-exec" {
    inline = [
      templatefile("${path.module}/../scripts/rke2-localpath-join-server-install.sh", {
        public_ip    = azurerm_linux_virtual_machine.opensuse_gpu[count.index + 1].public_ip_address
        private_ip   = azurerm_linux_virtual_machine.opensuse_gpu[0].private_ip_address
        rke2_version = var.rke2_version
      })
    ]

    connection {
      type        = "ssh"
      host        = azurerm_linux_virtual_machine.opensuse_gpu[count.index + 1].public_ip_address
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
      host        = azurerm_public_ip.pip[0].ip_address
      user        = local.ssh_username
      private_key = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
    }
  }

  provisioner "local-exec" {
    command = <<EOT
scp -o StrictHostKeyChecking=no \
-i ${local.private_ssh_key_path} \
${local.ssh_username}@${azurerm_public_ip.pip[0].ip_address}:/tmp/rke2-token ./rke2-token
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
      host        = azurerm_public_ip.pip[0].ip_address
    }
  }

  provisioner "local-exec" {
    command = <<EOT
      scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -i ${local.private_ssh_key_path} \
          ${local.ssh_username}@${azurerm_public_ip.pip[0].ip_address}:/tmp/rke2.yaml \
          ./kubeconfig-rke2.yaml
      
      if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/127.0.0.1/${azurerm_public_ip.pip[0].ip_address}/g" ./kubeconfig-rke2.yaml
      else
        sed -i "s/127.0.0.1/${azurerm_public_ip.pip[0].ip_address}/g" ./kubeconfig-rke2.yaml
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f ./kubeconfig-rke2.yaml"
  }
}


#resource "null_resource" "cleanup_certified_vhd" {
#  depends_on = [null_resource.retrieve_kubeconfig]
#  count      = var.certified_os_image ? 1 : 0
#  provisioner "local-exec" {
#    when    = destroy
#    command = "rm ${path.cwd}/opensuse-leap-15-6-suse-ai-deploy-cloud-image.x86_64.vhd"
#  }
#}
