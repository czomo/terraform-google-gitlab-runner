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
set -e
echo "Installing GitLab CI Runner"
curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh | sudo bash
sudo yum install -y gitlab-runner-18.5.0-0

echo "Installing fleeting plugin for GCP"
# Download and install fleeting-plugin-googlecompute
curl -L "https://gitlab.com/gitlab-org/fleeting/fleeting-plugin-googlecompute/-/releases/permalink/latest/downloads/binaries/fleeting-plugin-googlecompute-linux-amd64" -o /tmp/fleeting-plugin-googlecompute
sudo install -m755 /tmp/fleeting-plugin-googlecompute /usr/local/bin/fleeting-plugin-googlecompute

echo "Setting GitLab concurrency"
sed -i "s/concurrent = .*/concurrent = ${var.ci_concurrency}/" /etc/gitlab-runner/config.toml

echo "Registering GitLab CI runner with GitLab instance."
sudo gitlab-runner register -n \
    --url ${var.gitlab_url} \
    --token ${var.ci_token} \
    --executor "docker-autoscaler" \
    --docker-image "alpine:latest" \
    --docker-privileged=${var.docker_privileged} \
    --autoscaler-connector-config-plugin "fleeting-plugin-googlecompute" \
    --autoscaler-plugin-config "name=fleeting-plugin-googlecompute" \
    --autoscaler-plugin-config "project=${var.gcp_project}" \
    --autoscaler-plugin-config "zone=${var.gcp_zone}" \
    --autoscaler-plugin-config "machine_type=${var.ci_worker_instance_type}" \
    --autoscaler-plugin-config "source_image=${var.ci_worker_image}" \
    --autoscaler-plugin-config "service_account=${google_service_account.ci_worker.email}" \
    --autoscaler-plugin-config "disk_size=${var.ci_worker_disk_size}" \
    --autoscaler-plugin-config "disk_type=pd-ssd" \
    --autoscaler-plugin-config "network=${var.ci_runner_network}" \
    %{if var.ci_runner_subnetwork != ""}--autoscaler-plugin-config "subnetwork=${var.ci_runner_subnetwork}"%{endif} \
    --autoscaler-plugin-config "tags=${var.ci_worker_instance_tags}" \
    --autoscaler-plugin-config "use_internal_ip=true" \
    --autoscaler-plugin-config "scopes=https://www.googleapis.com/auth/cloud-platform" \
    --autoscaler-capacity-idle ${var.ci_worker_idle_time} \
    --autoscaler-max-use-count 1 \
    --autoscaler-max-instances 10 \
    %{if var.pre_clone_script != ""}--pre-clone-script ${replace(format("%q", var.pre_clone_script), "$", "\\$")}%{endif} \
    %{if var.post_clone_script != ""}--post-clone-script ${replace(format("%q", var.post_clone_script), "$", "\\$")}%{endif} \
    %{if var.pre_build_script != ""}--pre-build-script ${replace(format("%q", var.pre_build_script), "$", "\\$")}%{endif} \
    %{if var.post_build_script != ""}--post-build-script ${replace(format("%q", var.post_build_script), "$", "\\$")}%{endif} \
    && true

gitlab-runner verify

echo "GitLab CI Runner installation complete"
SCRIPT

  service_account {
    email  = google_service_account.ci_runner.email
    scopes = ["cloud-platform"]
  }
}
