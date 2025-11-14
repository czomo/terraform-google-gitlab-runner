/**
 * Copyright 2021 Mantel Group Pty Ltd
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

# Compute the runner name to use for registration in GitLab.  We provide a default based on the GCP project name but it
# can be overridden if desired.
locals {
  ci_runner_gitlab_name_final = (var.ci_runner_gitlab_name != "" ? var.ci_runner_gitlab_name : "gcp-${var.gcp_project}")
}

# Service account for the Gitlab CI runner.  It doesn't run builds but it spawns other instances that do.
resource "google_service_account" "ci_runner" {
  project      = var.gcp_project
  account_id   = "${var.gcp_resource_prefix}-runner"
  display_name = "GitLab CI Runner"
}
resource "google_project_iam_member" "instanceadmin_ci_runner" {
  project = var.gcp_project
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.ci_runner.email}"
}
resource "google_project_iam_member" "networkadmin_ci_runner" {
  project = var.gcp_project
  role    = "roles/compute.networkAdmin"
  member  = "serviceAccount:${google_service_account.ci_runner.email}"
}
resource "google_project_iam_member" "securityadmin_ci_runner" {
  project = var.gcp_project
  role    = "roles/compute.securityAdmin"
  member  = "serviceAccount:${google_service_account.ci_runner.email}"
}
resource "google_project_iam_member" "logwriter_ci_runner" {
  project = var.gcp_project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.ci_runner.email}"
}

# Service account for Gitlab CI build instances that are dynamically spawned by the runner.
resource "google_service_account" "ci_worker" {
  project      = var.gcp_project
  account_id   = "${var.gcp_resource_prefix}-worker"
  display_name = "GitLab CI Worker"
}

# Allow GitLab CI runner to use the worker service account.
resource "google_service_account_iam_member" "ci_worker_ci_runner" {
  service_account_id = google_service_account.ci_worker.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.ci_runner.email}"
}

resource "google_compute_instance" "ci_runner" {
  project      = var.gcp_project
  name         = "${var.gcp_resource_prefix}-runner"
  machine_type = var.ci_runner_instance_type
  zone         = var.gcp_zone

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = var.ci_runner_image
      size  = var.ci_runner_disk_size
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = var.ci_runner_network
    subnetwork = var.ci_runner_subnetwork


    access_config {
      // Ephemeral IP
    }
  }

  metadata_startup_script = <<SCRIPT
echo "Installing GitLab CI Runner"
curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh | sudo bash
sudo yum install -y gitlab-runner-18.5.0-1

echo "Creating GitLab Runner configuration"
cat > /etc/gitlab-runner/config.toml <<EOF
concurrent = ${var.ci_concurrency}
check_interval = 0

[[runners]]
  name = "gcp-docker-autoscaler"
  url = "${var.gitlab_url}"
  token = "${var.ci_token}"
  executor = "docker-autoscaler"
  
  [runners.docker]
    image = "alpine:latest"
    privileged = ${var.docker_privileged}
  
  %{if var.pre_clone_script != ""}
  pre_clone_script = ${replace(format("%q", var.pre_clone_script), "$", "\\$")}
  %{endif}
  %{if var.post_clone_script != ""}
  post_clone_script = ${replace(format("%q", var.post_clone_script), "$", "\\$")}
  %{endif}
  %{if var.pre_build_script != ""}
  pre_build_script = ${replace(format("%q", var.pre_build_script), "$", "\\$")}
  %{endif}
  %{if var.post_build_script != ""}
  post_build_script = ${replace(format("%q", var.post_build_script), "$", "\\$")}
  %{endif}
  
  [runners.autoscaler]
    plugin = "googlecloud"
    capacity_per_instance = 1
    max_use_count = 1
    max_instances = 10
    
    [runners.autoscaler.plugin_config]
      name = "googlecloud"
      project = "${var.gcp_project}"
      zone = "${var.gcp_zone}"

    [runners.autoscaler.connector_config]
      username               = "ubuntu"
      use_external_addr      = false
      use_static_credentials = true
      key_path               = "/root/.ssh/id_rsa"

    [[runners.autoscaler.policy]]
      idle_count = 0
      idle_time = "${var.ci_worker_idle_time}s"
      preemptive_mode = false
EOF

echo "Installing fleeting plugin for GCP"
sudo gitlab-runner fleeting install

echo "    StrictHostKeyChecking no" >> /etc/ssh/ssh_config

# Download static private key
curl http://metadata.google.internal/computeMetadata/v1/instance/attributes/ssh-key-to-use -H 'Metadata-Flavor: Google' -o /root/.ssh/id_rsa
sudo chmod 600 /root/.ssh/id_rsa

echo "Starting GitLab Runner service"
sudo systemctl enable gitlab-runner
sudo systemctl restart gitlab-runner

echo "Verifying GitLab Runner"
sudo gitlab-runner verify

echo "GitLab CI Runner installation complete"
SCRIPT

  service_account {
    email  = google_service_account.ci_runner.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    block-project-ssh-keys = true
    ssh-key-to-use         = tls_private_key.access_key.private_key_pem
  }
}


data "google_compute_image" "ci_worker_image" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

data "cloudinit_config" "cloud_config" {
  gzip          = false
  base64_encode = false

  part {
    filename     = "cloud-config.yaml"
    content_type = "text/cloud-config"

    content = templatefile("${path.module}/cloud-config.yaml", {
      SSH_AUTHORIZED_KEY   = tls_private_key.access_key.public_key_openssh
    })
  }
}

/// This is a resource that does nothing but include the pool-ignition.yaml file in the dependency graph
/// Inclusion in the graph then allows us to recreate the runner when the config changes
resource "null_resource" "cloudinit" {
  triggers = {
    config = sha1(data.cloudinit_config.cloud_config.rendered)
  }
}

resource "google_compute_instance_template" "gitlab_runner_worker" {
  name_prefix  = "gitlab-runner-worker-"
  description  = "Template for GitLab Runner worker instances"
  machine_type = "n1-standard-1"
  project      = "kitopi-terraform-admin"

  disk {
    source_image = data.google_compute_image.ci_worker_image.self_link
    disk_type    = "pd-ssd"
    disk_size_gb = 10
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network = "default"
  }

  service_account {
    email  = "gitlab-ci-worker@kitopi-terraform-admin.iam.gserviceaccount.com"
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  # Tags for firewall rules
  tags = ["gitlab-ci-worker"]

  metadata = {
    google-logging-enabled    = "true"
    block-project-ssh-keys    = true
    user-data                 = data.cloudinit_config.cloud_config.rendered
  }

  lifecycle {
    create_before_destroy = true
    replace_triggered_by = [
      null_resource.cloudinit.id
    ]
  }
}

resource "google_compute_instance_group_manager" "gitlab_runner_mig" {
  name               = "googlecloud"
  base_instance_name = "gitlab-runner-worker"
  zone               = "europe-west2-a"
  project            = "kitopi-terraform-admin"
  description        = "Managed Instance Group for GitLab Runner workers"

  version {
    instance_template = google_compute_instance_template.gitlab_runner_worker.id
  }

  target_size = 0

  update_policy {
    type                         = "OPPORTUNISTIC"
    minimal_action               = "REPLACE"
    max_surge_fixed              = 0
    max_unavailable_percent      = 50
    replacement_method           = "SUBSTITUTE"
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.gitlab_runner_hc.id
    initial_delay_sec = 300
  }

#  instance_lifecycle_policy {
#    default_action_on_failure = "DO_NOTHING"
#  }

  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      target_size
    ]
  }
}

resource "google_compute_health_check" "gitlab_runner_hc" {
  name                = "gitlab-runner-hc"
  project             = "kitopi-terraform-admin"
  check_interval_sec  = 30
  timeout_sec         = 10
  healthy_threshold   = 2
  unhealthy_threshold = 3

  tcp_health_check {
    port = "22"
  }
}

# Firewall rule to allow internal communication
resource "google_compute_firewall" "gitlab_runner_internal" {
  name    = "gitlab-runner-internal"
  network = "default"
  project = "kitopi-terraform-admin"

  allow {
    protocol = "tcp"
    ports    = ["22", "2376"]
  }

  source_ranges = ["10.128.0.0/9"]
  target_tags   = ["gitlab-ci-worker"]
}
