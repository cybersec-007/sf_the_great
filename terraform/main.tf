
terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = ">= 0.100"
    }
  }
}


provider "yandex" {
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  token     = var.yc_token
  zone      = "ru-central1-a"
}

data "yandex_compute_image" "ubuntu" {
  family = "ubuntu-2204-lts"
}

resource "yandex_vpc_network" "this" {
  name = "devops-network"
}

resource "yandex_vpc_subnet" "this" {
  name           = "devops-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.this.id
  v4_cidr_blocks = ["10.10.10.0/24"]
}

locals {
  nodes = [
    { name = "k8s-master", cores = 2, memory = 4 },
    { name = "k8s-node",   cores = 2, memory = 4 },
    { name = "srv",        cores = 2, memory = 4 },
  ]
}

resource "yandex_compute_instance" "nodes" {
  for_each = { for n in local.nodes : n.name => n }

  name  = each.value.name
  zone  = "ru-central1-a"

  resources {
    cores  = each.value.cores
    memory = each.value.memory
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 20
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.this.id
    nat       = true
  }

  metadata = {
    ssh-keys = "ubuntu:${file(var.public_key_path)}"
  }
}

output "external_ips" {
  value = { for k, v in yandex_compute_instance.nodes : k => v.network_interface.0.nat_ip_address }
}
