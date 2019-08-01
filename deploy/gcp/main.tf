variable "GCP_CREDENTIALS_PATH" {
}

variable "GCP_REGION" {
}

variable "GCP_PROJECT" {
}

provider "google" {
  credentials = file(var.GCP_CREDENTIALS_PATH)
  region      = var.GCP_REGION
  project     = var.GCP_PROJECT
}

// required for taints on node pools
provider "google-beta" {
  credentials = file(var.GCP_CREDENTIALS_PATH)
  region      = var.GCP_REGION
  project     = var.GCP_PROJECT
}

locals {
  credential_path          = "${path.cwd}/credentials"
  kubeconfig               = "${local.credential_path}/kubeconfig_${var.gke_name}"
  tidb_cluster_values_path = "${path.module}/rendered/tidb-cluster-values.yaml"
}

module "project-credentials" {
  source = "../modules/gcp/project-credentials"

  path = local.credential_path
  gcloud_project = var.GCP_PROJECT
}

module "vpc" {
  source = "../modules/gcp/vpc"
  create_vpc = var.create_vpc
  gcp_project = module.project-credentials.gcp_project
  gcp_region = var.GCP_REGION
  vpc_name = var.vpc_name
  private_subnet_name = "${var.gke_name}-${var.private_subnet_name}"
  public_subnet_name = "${var.gke_name}-${var.public_subnet_name}"
}

module "tidb-operator" {
  source = "../modules/gcp/tidb-operator"
  gke_name = var.gke_name
  vpc_name = var.vpc_name
  subnetwork_name = module.vpc.private_subnetwork_name
  gcp_project = var.GCP_PROJECT
  gcp_region = var.GCP_REGION
  kubeconfig_path = local.kubeconfig
  tidb_operator_version = var.tidb_operator_version
}

module "bastion" {
  source = "../modules/gcp/bastion"
  vpc_name = module.vpc.vpc_name
  public_subnet_name = module.vpc.public_subnetwork_name
  gcp_project = var.GCP_PROJECT
}


