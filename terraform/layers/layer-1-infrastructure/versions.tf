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

  # State lives on the persistent ops-runner at a fixed path (survives repo checkouts
  # and cluster teardowns). Init with:
  #   terraform init -backend-config="path=/opt/homelab/tfstate/layer-1.tfstate"
  backend "local" {}
}
