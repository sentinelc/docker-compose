resource "dme_dns_record" "api" {
  domain_id = var.dme_domain
  name = "api${var.dme_suffix}"
  type = "A"
  value = digitalocean_droplet.vm.ipv4_address
  ttl = 300
  gtd_location = "DEFAULT"
}

resource "dme_dns_record" "accounts" {
  domain_id = var.dme_domain
  name = "accounts${var.dme_suffix}"
  type = "A"
  value = digitalocean_droplet.vm.ipv4_address
  ttl = 300
  gtd_location = "DEFAULT"
}

resource "dme_dns_record" "app" {
  domain_id = var.dme_domain
  name = "app${var.dme_suffix}"
  type = "A"
  value = digitalocean_droplet.vm.ipv4_address
  ttl = 300
  gtd_location = "DEFAULT"
}

resource "dme_dns_record" "portal" {
  domain_id = var.dme_domain
  name = "portal${var.dme_suffix}"
  type = "A"
  value = digitalocean_droplet.vm.ipv4_address
  ttl = 300
  gtd_location = "DEFAULT"
}
