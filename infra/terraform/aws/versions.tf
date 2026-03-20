# =============================================================================
# ZeroNAT Terraform Module — Provider Requirements
# =============================================================================
#
# This file declares the minimum Terraform version and required providers.
#
# IMPORTANT: This is a reusable module — it must NOT contain `provider` or
# `backend` blocks. The calling root module supplies the provider configuration.
# =============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
