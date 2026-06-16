# ==========================================
# 1. TERRAFORM RUNTIME & PROVIDERS
# ==========================================
# This tells Terraform which cloud plugins to download.
terraform {
  required_version = ">= 1.1.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0.2"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "2.3.3"
    }
  }
}

provider "azurerm" {
  features {} # Leave blank to accept standard Azure defaults
}

provider "cloudinit" {}

# ==========================================
# 2. INPUT VARIABLES
# ==========================================
variable "labelPrefix" {
  type        = string
  description = "Your college username prefix"
}

variable "region" {
  type        = string
  default     = "eastus"
  description = "Azure region to deploy resources"
}

variable "admin_username" {
  type        = string
  default     = "azureadmin"
  description = "Admin username for the VM"
}

# ==========================================
# 3. INFRASTRUCTURE RESOURCE DEFINITIONS
# ==========================================

# Create the primary container sandbox
resource "azurerm_resource_group" "rg" {
  name     = "${var.labelPrefix}-A05-RG"
  location = var.region
}

# Create a dynamic Public IP Address
resource "azurerm_public_ip" "pip" {
  name                = "${var.labelPrefix}-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Dynamic"
}

# Create the internal Private Network
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.labelPrefix}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# Carve out a room inside that network for our server
resource "azurerm_subnet" "subnet" {
  name                 = "${var.labelPrefix}-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Create security firewall rules allowing SSH and Web Traffic
resource "azurerm_network_security_group" "nsg" {
  name                = "${var.labelPrefix}-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "HTTP"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Create the virtual network card and attach the Public IP address
resource "azurerm_network_interface" "nic" {
  name                = "${var.labelPrefix}-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }
}

# Lock down this specific network card with our firewall rules
resource "azurerm_network_interface_security_group_association" "nic_nsg" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# Pack up the init.sh script into a format the VM can read upon startup
data "cloudinit_config" "config" {
  gzip          = false
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content      = file("${path.module}/init.sh")
  }
}

# Build the Virtual Machine hardware profile
resource "azurerm_linux_virtual_machine" "vm" {
  name                = "${var.labelPrefix}-webserver"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_B2s" # Economical tier
  admin_username      = var.admin_username
  custom_data         = data.cloudinit_config.config.rendered

  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]

  # Links your computer's public security key to login without a password
  admin_ssh_key {
    username   = var.admin_username
    public_key = file("${path.module}/id_rsa.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

# ==========================================
# 4. OUTPUT VALUES
# ==========================================
# Prints important details on your screen once done!
output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "public_ip_address" {
  value = azurerm_linux_virtual_machine.vm.public_ip_address
}