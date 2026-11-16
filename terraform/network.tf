data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  allowed_cidr = var.allowed_cidr != "" ? var.allowed_cidr : "${trimspace(data.http.my_ip.response_body)}/32"
}

resource "azurerm_resource_group" "main" {
  tags     = var.tags
  name     = "${var.prefix}-rg"
  location = var.region
}

resource "azurerm_virtual_network" "main" {
  tags                = var.tags
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.20.0.0/16"]
}

resource "azurerm_subnet" "main" {
  name                 = "${var.prefix}-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.20.1.0/24"]
}

resource "azurerm_network_security_group" "main" {
  tags                = var.tags
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "ssh-from-operator"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = local.allowed_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "rdp-from-operator"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = local.allowed_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "winrm-from-operator"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["5985", "5986"]
    source_address_prefix      = local.allowed_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "main" {
  subnet_id                 = azurerm_subnet.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}

resource "azurerm_public_ip" "linux" {
  tags                = var.tags
  name                = "${var.prefix}-linux-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "windows" {
  tags                = var.tags
  name                = "${var.prefix}-windows-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "linux" {
  tags = var.tags
  #checkov:skip=CKV_AZURE_119:Public IP is required for operator access to this demo VM; NSG restricts access to the operator /32
  name                = "${var.prefix}-linux-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.linux.id
  }
}

resource "azurerm_network_interface" "windows" {
  tags = var.tags
  #checkov:skip=CKV_AZURE_119:Public IP is required for operator access to this demo VM; NSG restricts access to the operator /32
  name                = "${var.prefix}-windows-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.windows.id
  }
}
