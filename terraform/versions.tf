terraform {
  required_providers {
    digitalocean = {
      source = "digitalocean/digitalocean"
      version = "~> 2.4.0"
    }
    dme = {
      source = "dnsmadeeasy/dme"
      version = "~> 0.1.3"
    }
  }
  required_version = ">= 0.13"
}
