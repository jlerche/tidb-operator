resource "google_container_node_pool" "pd_pool" {
  // The monitor pool is where tiller must first be deployed to.
  depends_on = [google_container_node_pool.monitor_pool]
  provider   = google-beta
  project    = var.gcp_project
  cluster    = var.gke_cluster_name
  location   = var.gke_cluster_location
  name       = "${var.cluster_name}-pd-pool"
  node_count = var.pd_node_count

  management {
    auto_repair  = true
    auto_upgrade = false
  }

  node_config {
    machine_type    = var.pd_instance_type
    local_ssd_count = 0

    taint {
      effect = "NO_SCHEDULE"
      key    = "dedicated"
      value  = "${var.cluster_name}-pd"
    }

    labels = {
      dedicated = "${var.cluster_name}-pd"
    }

    tags         = ["pd"]
    oauth_scopes = ["storage-ro", "logging-write", "monitoring"]
  }
}

resource "google_container_node_pool" "tikv_pool" {
  provider   = google-beta
  project    = var.gcp_project
  cluster    = var.gke_cluster_name
  location   = var.gke_cluster_location
  name       = "${var.cluster_name}-tikv-pool"
  node_count = var.tikv_node_count

  management {
    auto_repair  = false
    auto_upgrade = false
  }

  node_config {
    machine_type = var.tikv_instance_type
    // This value cannot be changed (instead a new node pool is needed)
    // 1 SSD is 375 GiB
    local_ssd_count = 1

    taint {
      effect = "NO_SCHEDULE"
      key    = "dedicated"
      value  = "${var.cluster_name}-tikv"
    }

    labels = {
      dedicated = "${var.cluster_name}-tikv"
    }

    tags         = ["tikv"]
    oauth_scopes = ["storage-ro", "logging-write", "monitoring"]
  }
}

resource "google_container_node_pool" "tidb_pool" {
  // The pool order is tikv -> monitor -> pd -> tidb
  depends_on = [google_container_node_pool.pd_pool]
  provider   = google-beta
  project    = var.gcp_project
  cluster    = var.gke_cluster_name
  location   = var.gke_cluster_location
  name       = "${var.cluster_name}-tidb-pool"
  node_count = var.tidb_node_count

  management {
    auto_repair  = true
    auto_upgrade = false
  }

  node_config {
    machine_type = var.tidb_instance_type

    taint {
      effect = "NO_SCHEDULE"
      key    = "dedicated"
      value  = "${var.cluster_name}-tidb"
    }

    labels = {
      dedicated = "${var.cluster_name}-tidb"
    }

    tags         = ["tidb"]
    oauth_scopes = ["storage-ro", "logging-write", "monitoring"]
  }
}

resource "google_container_node_pool" "monitor_pool" {
  // Setup local SSD on TiKV nodes first (this can take some time)
  // Create the monitor pool next because that is where tiller will be deployed to
  depends_on = [google_container_node_pool.tikv_pool]
  project    = var.gcp_project
  cluster    = var.gke_cluster_name
  location   = var.gke_cluster_location
  name       = "${var.cluster_name}-monitor-pool"
  node_count = var.monitor_node_count

  management {
    auto_repair  = true
    auto_upgrade = false
  }

  node_config {
    machine_type = var.monitor_instance_type
    tags         = ["monitor"]
    oauth_scopes = ["storage-ro", "logging-write", "monitoring"]
  }
}

locals {
  num_availability_zones = length(data.google_compute_zones.available)
}

module "tidb-cluster" {
  source                     = "../../share/tidb-cluster-release"
  cluster_name               = var.cluster_name
  pd_count                   = var.pd_node_count * local.num_availability_zones
  tikv_count                 = var.tikv_node_count * local.num_availability_zones
  tidb_count                 = var.tidb_node_count * local.num_availability_zones
  tidb_cluster_chart_version = var.tidb_cluster_chart_version
  override_values            = var.override_values
  kubeconfig_filename        = var.kubeconfig_path
  base_values                = file("${path.module}/values/default.yaml")
  wait_on_resource           = [google_container_node_pool.tidb_pool]
}

resource "null_resource" "wait-lb-ip" {
  depends_on = [
    google_container_node_pool.tidb_pool,
    module.tidb-cluster.tidb_endpoint
  ]
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    working_dir = path.cwd
    command     = <<EOS
set -euo pipefail

until kubectl get svc -n ${var.cluster_name} ${var.cluster_name}-tidb -o json | jq '.status.loadBalancer.ingress[0]' | grep ip; do
  echo "Wait for TiDB internal loadbalancer IP"
  sleep 5
done
EOS

    environment = {
      KUBECONFIG = var.kubeconfig_path
    }
  }

  provisioner "local-exec" {
    when = destroy
    interpreter = ["bash", "-c"]
    working_dir = path.cwd
    command     = <<EOS
kubectl get pvc -n tidb -o jsonpath='{.items[*].spec.volumeName}'|fmt -1 | xargs -I {} kubectl patch pv {} -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
EOS

    environment = {
      KUBECONFIG = var.kubeconfig_path
    }
  }
}
