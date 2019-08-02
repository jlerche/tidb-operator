variable "gke_name" {
  description = "Name of the GKE cluster. Also used as a prefix in names of related resources."
  type        = string
}

variable "vpc_name" {
  description = "The name of the VPC in which to place the cluster"
}

variable "subnetwork_name" {
  description = "The name of the subnetwork in which to place the cluster"
}

variable "gcp_region" {
  description = "The GCP region"
}

variable "gcp_project" {
  description = "The GCP project name"
}

variable "gke_version" {
  description = "Kubernetes version to use for the EKS cluster"
  type        = string
  default     = "latest"
}

variable "tidb_operator_version" {
  description = "TiDB Operator version"
  type        = string
  default     = "v1.0.0-rc.1"
}

variable "tidb_operator_registry" {
  description = "TiDB operator registry"
  default     = "pingcap"
}


variable "operator_helm_values" {
  description = "Operator helm values"
  type        = string
  default     = ""
}

variable "kubeconfig_path" {
  description = "kubeconfig path"
}
