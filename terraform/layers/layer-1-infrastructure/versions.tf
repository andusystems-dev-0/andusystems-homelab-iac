terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.14.0"
    }
  }

  # Remote state (configured in layer-0-state / backend.tf). Uncomment after layer-0 apply.
  # backend "s3" {
  #   bucket = "andusystems-tfstate"
  #   key    = "homelab/layer-1-infrastructure.tfstate"
  #   region = "us-east-1"
  # }
}
