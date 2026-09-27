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

  # State lives in S3 (survives even if the ops-runner is lost), so any runner can pick up
  # the cluster. Bucket/key/region are supplied at init via -backend-config in deploy.yml:
  #   terraform init -backend-config="bucket=andusystems-tfstate" \
  #     -backend-config="key=homelab/layer-1-infrastructure.tfstate" -backend-config="region=us-east-1"
  backend "s3" {}
}
