resource "digitalocean_tag" "tag" {
  name = format("sc-%s", var.sc_env_name)
}

resource "digitalocean_ssh_key" "admin" {
  name       = "Admin key for droplets"
  public_key = file("../credentials/admin-key.pub")
}

resource "digitalocean_droplet" "vm" {
  image  = "ubuntu-20-04-x64"
  name   = format("sc-%s-vm", var.sc_env_name)
  region = var.do_region
  size   = "s-2vcpu-4gb-amd"
  private_networking = true
  ssh_keys = [digitalocean_ssh_key.admin.fingerprint]
  user_data = file("cloud-init.sh")
  tags   = [digitalocean_tag.tag.id]
}

resource "digitalocean_firewall" "fw" {
  name = format("sc-%s-fw", var.sc_env_name)

  droplet_ids = [digitalocean_droplet.vm.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.ssh_ips
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "udp"
    port_range       = "20208"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "icmp"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
