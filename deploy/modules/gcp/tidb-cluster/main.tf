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
  num_availability_zones = length(data.google_compute_zones.available.names)
  default_values_file = "${path.module}/values/default.yaml"
  kubeconfig_path = var.kubeconfig_path
  cluster_name = var.cluster_name
}

resource "null_resource" "create_tidb_cluster_helm" {
  depends_on = [google_container_node_pool.pd_pool]
  provisioner "local-exec" {
    working_dir = path.cwd
    command = <<EOS
helm repo add pingcap https://charts.pingcap.org/
helm upgrade --install ${var.cluster_name} pingcap/tidb-cluster --namespace ${var.cluster_name} --version ${var.tidb_cluster_chart_version} \
  --set pd.image=pingcap/pd:${var.cluster_version} \
  --set pd.replicas=${var.pd_node_count * local.num_availability_zones} \
  --set pd.nodeSelector.dedicated=${var.cluster_name}-pd \
  --set pd.tolerations[0].key=dedicated \
  --set pd.tolerations[0].value=${var.cluster_name}-pd \
  --set pd.tolerations[0].operator=Equal \
  --set pd.tolerations[0].effect=NoSchedule \
  --set tikv.image=pingcap/tikv:${var.cluster_version} \
  --set tikv.replicas=${var.tidb_node_count * local.num_availability_zones} \
  --set tikv.nodeSelector.dedicated=${var.cluster_name}-tikv \
  --set tikv.tolerations[0].key=dedicated \
  --set tikv.tolerations[0].value=${var.cluster_name}-tikv \
  --set tikv.tolerations[0].operator=Equal \
  --set tikv.tolerations[0].effect=NoSchedule \
  --set tidb.replicas=${var.tidb_node_count * local.num_availability_zones} \
  --set tidb.nodeSelector.dedicated=${var.cluster_name}-tidb \
  --set tidb.tolerations[0].key=dedicated \
  --set tidb.tolerations[0].value=${var.cluster_name}-tidb \
  --set tidb.tolerations[0].operator=Equal \
  --set tidb.tolerations[0].effect=NoSchedule \
  -f ${coalesce(var.override_values, local.default_values_file)}
EOS
    environment = {
      KUBECONFIG = var.kubeconfig_path
    }
  }
}

resource "null_resource" "wait-lb-ip" {
  depends_on = [
    google_container_node_pool.tidb_pool,
    null_resource.create_tidb_cluster_helm,
  ]
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    working_dir = path.cwd
    command     = <<EOS
set -euo pipefail

until kubectl --kubeconfig ${local.kubeconfig_path} get svc -n ${local.cluster_name} ${local.cluster_name}-tidb -o json | jq '.status.loadBalancer.ingress[0]' | grep ip; do
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
    command = <<EOS
set -x
if KUBECONFIG=${local.kubeconfig_path} helm ls ${local.cluster_name} ; then
  kubectl --kubeconfig ${local.kubeconfig_path} get pvc -n ${local.cluster_name} -o jsonpath='{.items[*].spec.volumeName}'|fmt -1 | xargs -I {} kubectl --kubeconfig ${local.kubeconfig_path} patch pv {} -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
  helm del --purge ${local.cluster_name}
fi
EOS
    environment = {
      KUBECONFIG = var.kubeconfig_path
    }
  }
}
