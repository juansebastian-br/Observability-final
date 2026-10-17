terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Local state for the lab. For a shared environment use a GCS backend:
  # backend "gcs" { bucket = "<bucket>" prefix = "modulo-b" }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
