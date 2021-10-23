terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "3.89.0"
    }
  }

  backend "gcs" {
    bucket      = var.backend_bucket
    prefix      = "terraform/state"
    credentials = var.credentials_file
  }
}

provider "google" {
  credentials = file(var.credentials_file)
  project     = var.project
  region      = var.region
  zone        = var.zone
}

variable "label" {
  type    = string
  default = var.label
}

locals {
  subnet_name            = "${var.label}-subnet"
  pod_range_name         = "${var.label}-pods"
  service_range_name     = "${var.label}-services"
  router_name            = "${var.label}-router"
  external_ip_name       = "${var.label}-external-ip"
  cluster_nat_name       = "${var.label}-nat"
  cluster_name           = "${var.label}-cluster"
  primary-node-pool-name = "${var.label}-primary-nodes"
}


resource "google_compute_subnetwork" "cluster_subnet" {
  name                     = local.subnet_name
  network                  = "default"
  ip_cidr_range            = "10.2.0.0/16"
  private_ip_google_access = true
  secondary_ip_range {
    range_name    = local.pod_range_name
    ip_cidr_range = "10.1.0.0/18"
  }
  secondary_ip_range {
    range_name    = local.service_range_name
    ip_cidr_range = "10.16.0.0/20"
  }
}

resource "google_compute_router" "cluster_router" {
  name    = local.router_name
  network = "default"
  bgp {
    asn = 64514
  }
}

resource "google_compute_address" "nat_external_ip" {
  count = 1
  name  = "${local.external_ip_name}-${count.index}"
}

resource "google_compute_router_nat" "cluster_nat" {
  name                               = local.cluster_nat_name
  router                             = google_compute_router.cluster_router.name
  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = google_compute_address.nat_external_ip[*].self_link
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.cluster_subnet.self_link
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

output "nat_ips" {
  value = google_compute_address.nat_external_ip[*].self_link
}

resource "google_container_cluster" "cluster" {
  name = local.cluster_name

  # We can't ask for 0 nodes, but as we want to manage them
  # in a seperate node pool we'll remove the default once
  # the cluster is up
  initial_node_count       = 1
  remove_default_node_pool = true

  # Don't view a change in the node count as a change - we don't
  # want Terraform undoing any scaling (auto or manual) that has
  # happened
  #  lifecycle = {
  #    ignore_changes = "node_count"
  #  }

  # Setting an empty username and password explicitly disables basic auth
  master_auth {
    username = ""
    password = ""
  }

  # Destroying and creating clusters can take 'a while'
  timeouts {
    create = "30m"
    update = "40m"
  }

  # Ensure the cluster is running on a subnet, and that pods and
  # services in the cluster are in defined ranges
  subnetwork = google_compute_subnetwork.cluster_subnet.self_link

  ip_allocation_policy {
    cluster_secondary_range_name  = local.pod_range_name
    services_secondary_range_name = local.service_range_name
  }

  # This is a Private Cluster, so we need to define who can run Kubectl
  # (assuming they can authenticate).
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block = var.cidr_block
    }
  }

  # Make sure we build a private cluster!
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.18.0.0/28"
  }
}

resource "google_container_node_pool" "primary_nodes" {
  name    = local.primary-node-pool-name
  cluster = google_container_cluster.cluster.name

  node_count = 1

  node_config {
    machine_type = "n1-standard-1"
    oauth_scopes = [
      "https://www.googleapis.com/auth/compute",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  autoscaling {
    min_node_count = 1
    max_node_count = 2
  }
}
