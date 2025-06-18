# Dev Ops Infrastructure: Django + PostgreSQL + Monitoring on **Yandex Cloud**

> **TL;DR** `terraform apply` → `ansible-playbook` → push **tag** → production‑ready cluster **&** monitoring.
> All steps are described below so that **a completely new engineer** can repeat them.

---

## Table of contents

1. [Architecture](#architecture)
2. [Before‑you‑begin](#before-you-begin)
3. [Step 1 — Provision infra with Terraform](#step-1—-provision-infra-with-terraform)
4. [Step 2 — Configure hosts with Ansible](#step-2—-configure-hosts-with-ansible)
5. [Step 3 — CI/CD via GitHub Actions](#step-3—-cicd-via-github-actions)
6. [Step 4 — Monitoring, Logs & Alerts](#step-4—-monitoring-logs--alerts)
7. [Manual actions checklist](#manual-actions-checklist)
8. [Cleanup](#cleanup)
9. [FAQ / Troubleshooting](#faq--troubleshooting)

---

## Architecture

```
┌──────────────────────────────┐  Git tag push  ┌──────────────────────────┐
│  GitHub  »  Actions runners  │───────────────▶│  Docker Hub (images)     │
└──────────────────────────────┘                └──────────────────────────┘
              │ helm upgrade                                ▲ pull
              ▼                                             │
┌──────────────────────────────────────────────────────────────────────────┐
│           Yandex Cloud (VPC 10.10.10.0/24  ■ ru-central1)                │
│                                                                          │
│  k8s‑master   k8s‑node             srv                                   │
│  (Ubuntu)     (Ubuntu)             (Ubuntu + Docker Compose)             │
│  ─────────   ─────────            ───────────────────────────────────────│
│  • kube‑API  • kubelet            • Prometheus 9090                      │
│  • etcd      • kube‑proxy         • Grafana    3000                      │
│  • Calico                         • Loki       3100                      │
│                                   • Blackbox   9115                      │
│                                   • Node‑Exporter 9100                   │
│                                                                          │
│  Sample Django app  (Helm chart) ──────▶  Cluster  (NodePort 30080)      │
└──────────────────────────────────────────────────────────────────────────┘
```

* **Terraform** – creates VPC, subnet & **3 VM** instances (`k8s-master`, `k8s-node`, `srv`).
* **Ansible** – installs Docker, Kubernetes (via `kubeadm`), Calico, Helm and the **monitoring stack** (Prometheus + Grafana + Loki + Promtail + Blackbox Exporter + Node Exporter).
* **GitHub Actions** – on every *version tag* builds a Docker image of the Django app, pushes to Docker Hub and upgrades the Helm release in the cluster.
* **Prometheus rules** + **Grafana contact points** → alert about **downtime, slow response, bad HTTP codes and expiring TLS certs**.

---

## Before‑you‑begin

| Tool                                                                                          | Minimum version | How we use it                  |
| --------------------------------------------------------------------------------------------- | --------------- | ------------------------------ |
| [Terraform](https://developer.hashicorp.com/terraform/downloads)                              | 1.5             | create cloud infra             |
| [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) | 2.15            | bootstrap servers              |
| [Yandex Cloud CLI](https://cloud.yandex.com/en/docs/cli/quickstart)                           | latest          | obtain cloud/folder ID & token |
| `ssh`                                                                                         | any             | log in to VMs                  |

```bash
# macOS example (brew)
brew install terraform ansible
brew install yandex-cloud/yandex-cloud/yc
```

1. **Generate/ensure an SSH key‑pair** (default uses `~/.ssh/id_rsa.pub`).
2. **Authenticate yc** and copy your `cloud-id`, `folder-id`, and OAuth token:

   ```bash
   yc init               # interactive login
   yc config list        # shows cloud-id & folder-id
   yc config get token   # shows OAuth token
   ```

---

## Step 1 — Provision infra with Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit values
terraform init                                 # downloads YC provider
terraform apply                                # type "yes" to confirm
```

**What will be created**

* VPC network + subnet (`10.10.10.0/24`)
* 3 Ubuntu 22.04 VMs (2 vCPU / 4 GB each) with **public IP**
* Outputs: `k8s_master_ip`, `k8s_node_ip`, `srv_ip`

> ℹ️  Yandex Cloud security groups allow all inbound traffic by default for a public IP. *After testing* tighten the rules (allow SSH 22 and monitoring/Grafana ports only from your IP).

---

## Step 2 — Configure hosts with Ansible

1. Fill `ansible/inventory.ini`:

   ```ini
   [k8s_master]
   k8s-master ansible_host=<MASTER_PUBLIC_IP> ansible_user=ubuntu

   [k8s_node]
   k8s-node   ansible_host=<NODE_PUBLIC_IP>   ansible_user=ubuntu

   [srv]
   srv        ansible_host=<SRV_PUBLIC_IP>    ansible_user=ubuntu
   ```
2. Run the playbook:

   ```bash
   cd ansible
   ansible-galaxy install -r requirements.yml   # if roles/collections used
   ansible-playbook -i inventory.ini playbook.yml
   ```

### What the playbook does

| Phase          | Hosts  | Tasks                                                               |                                                                                   
| -------------- | ------ | ------------------------------------------------------------------- |
| **common**     | all    | update APTinstall Docker + Compose plugindisable swap               |                                                                       
| **k8s-master** | master | install kubeadm/kubelet/kubectl`kubeadm init`apply Calico CNI       |
| **k8s-node**   | worker | install kube‑pkgs`kubeadm join` (token auto‑fetched from master)    |
| **srv**        | srv    | install Helm & jqcopy `/etc/kubernetes/admin.conf` from master →    |
|                |        |   `~/.kube/config`copy monitoring files (`prometheus.yml`,          |
|                |        |   `blackbox_alerts.yml`, `loki-config.yaml`, `docker-compose.yml`,  |
|                |        |   `promtail.yaml`) into `/opt/monitoring``docker compose up -d`     |

After \~5 min you will have:

* Kubernetes cluster **Ready** (`kubectl get nodes` on `srv`)
* Monitoring stack up (`docker compose ps` on `srv`)

---

## Step 3 — CI/CD via GitHub Actions

> The CI file lives in `.github/workflows/builddeploy.yml` (see `ci/` folder). Copy it into *your app repo*.

### Secrets to add in GitHub → Settings → **Actions → Secrets**

| Secret               | Description                                                 |              |
| -------------------- | ----------------------------------------------------------- | ------------ |
| `DOCKERHUB_USERNAME` | your Docker Hub login                                       |              |
| `DOCKERHUB_TOKEN`    | personal access token (not the password)                    |              |
| `KUBECONFIG`         | Base64‑encoded kubeconfig from `srv`: \`cat \~/.kube/config | base64 -w0\` |

### Workflow logic

1. Trigger — push a **git tag** `v*.*.*`.
2. Jobs:

   * **build** → `docker build`, `docker push` → produce output `${{ steps.meta.outputs.version }}`.
   * **deploy** → decode kubeconfig → `helm upgrade --install django-demo helm/django-postgres \ --set image.repository=$DOCKERHUB_USERNAME/devops-infra \ --set image.tag=$VERSION --wait`.
3. Result — new version rolls out via rolling update.

### Quick test

```bash
git tag v0.1.0
git push --tags        # watch Actions tab
```

---

## Step 4 — Monitoring, Logs & Alerts

| Service               | URL                            | Default creds               |
| --------------------- | ------------------------------ | --------------------------- |
| Grafana               | `http://<SRV_IP>:3000`         | `admin` / `admin` (change!) |
| Prometheus            | `http://<SRV_IP>:9090`         | —                           |
| Loki API              | `http://<SRV_IP>:3100`         | —                           |
| Blackbox Exporter     | `http://<SRV_IP>:9115`         | —                           |
| Node‑Exporter metrics | `http://<SRV_IP>:9100/metrics` | —                           |

### Adding data sources in Grafana

1. **Prometheus:** URL `http://prometheus:9090` (same Docker network).
2. **Loki:** URL `http://loki:3100`.

### Built‑in alert rules (`blackbox_alerts.yml`)

| Rule                   | When fires                                 | Severity |
| ---------------------- | ------------------------------------------ | -------- |
| **BlackboxDown**       | `probe_success==0` ≥ 2 m                   | critical |
| **BadHTTPStatus**      | HTTP ≥ 400 for 10 m                        | warning  |
| **SlowResponse**       | avg `probe_duration_seconds` > 2 s for 5 m | warning  |
| **SSLCertExpiresSoon** | cert expires ‹ 7 days                      | info     |

Connect Grafana **Contact points** (e.g. Telegram) to receive instant alerts.

---

## Manual actions checklist

* Everything else is **fully automated**.

---

## Cleanup

```bash
cd terraform
terraform destroy     # removes VMs, subnet, network
```

All monitoring data & cluster nodes are deleted → no charge in your YC account.

---

## FAQ / Troubleshooting

---

Made with ❤️ by the DevOps team (just me).
