terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "3.89.0"
    }
  }
}

provider "google" {
  credentials = file("../terraform-deploy.json")
  project     = "gitops-terraform-and-circleci"
  region      = "europe-west2"
  zone        = "europe-west2-a"
}

resource "google_storage_bucket" "terraform_state" {
  name          = "tf-state-gitops-terraform-and-circleci"
  location      = "EU"
  force_destroy = true

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }
}

output "gcs_bucket_url" {
  value = google_storage_bucket.terraform_state.url
}
