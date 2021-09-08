
provider "digitalocean" {
  token = var.do_token
}

provider "dme" {
    api_key = var.dme_api_key
    secret_key = var.dme_secret_key
    insecure = false
}
