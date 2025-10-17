This repository implements a **CI** for **http-echo-app**.

It provision a **multi-node KinD Kubernetes cluster**, deploy **Ingress and two HTTP echo apps (`foo` and `bar`)**, performs **load testing**, and posts metrics as a **comment on the PR**.

---

## Overview

- Triggers CI workflow on **each pull request** to the main branch.
- Provision a **multi-node Kubernetes cluster** using **KinD** on the CI runner (localhost).
- Deploys **Ingress-NGINX** controller for routing.
- Deploys two **http-echo** applications:
  - `foo` → returns `"foo"`
  - `bar` → returns `"bar"`
- Configures ingress routing:
  - `http://foo.localhost` → routes to `foo` service
  - `http://bar.localhost` → routes to `bar` service
- Verifies that **Ingress** and **Deployments** are healthy before proceeding.
- Runs a **randomized load test** targeting both endpoints.
- Captures **metrics** (avg, p90, p95, req/s, failure rate, etc.)
- Posts the **metrics summary as a PR comment**.

---

## Tech Stack

- **GitHub Actions** – CI workflow orchestration  
- **KinD (Kubernetes in Docker)** – Local multi-node Kubernetes cluster  
- **Helm** – Deployments and Ingress configuration  
- **Prometheus & Grafana (via kube-prometheus-stack)** – Metrics collection and visualization  
- **Bash / Python** – Orchestration and load testing scripts  

---

## Repository Structure

```bash
.
├── charts
│   └── http-echo
│       ├── Chart.yaml
│       ├── templates
│       │   ├── _helpers.tpl
│       │   ├── deployment.yaml
│       │   ├── ingress.yaml
│       │   └── service.yaml
│       └── values.yaml
├── kind-config.yaml
├── README.md
└── scripts
    ├── collect_metrics.py
    ├── loadtest.py
    ├── run_all.sh
    └── wait_for_ready.sh
```

---

## How It Works

### Workflow Summary (`.github/workflows/ci.yaml`)

The CI pipeline runs automatically on:
- `pull request` to the **main** branch  
- Every **pull request** targeting `main`

Steps performed:

1. **Set up environment**
   - Installs dependencies (kubectl, helm, kind, Python)
2. **Create KinD cluster**
   - Multi-node setup (1 control-plane + 2 workers)
3. **Install Ingress Controller**
   - Uses `ingress-nginx` Helm chart
4. **Deploy Monitoring**
   - Installs Prometheus and Grafana via `kube-prometheus-stack`
5. **Deploy Applications**
   - Installs `foo` and `bar` http-echo apps using Helm
6. **Configure Ingress Routing**
   - Routes `foo.localhost` → foo service  
     `bar.localhost` → bar service
7. **Run Health Checks**
   - Ensures pods, services, and ingress are healthy
8. **Run Load Tests**
   - Simulates traffic for 30 seconds and records metrics
9. **Post Results**
   - Saves results as `metrics_summary.json` and PNG graphs  
   - If running in PR context, posts metrics as a comment  

---

## Example Output



Example summary (from `metrics_summary.json`):

```json
{
   "summary": 
      [
         {"metric": "cpu_foo", "avg": 0.00013752621477202767, "p90": 0.0, "p95": 0.0}, 
         {"metric": "cpu_bar", "avg": 0.0001429976914409751, "p90": 0.00020460788598805475, "p95": 0.00020460788598805475}, 
         {"metric": "mem_foo", "avg": 2427107.5555555555, "p90": 1018538.6666666666, "p95": 1018538.6666666666}, 
         {"metric": "mem_bar", "avg": 2461696.0, "p90": 1040384.0, "p95": 1040384.0}, 
         {"metric": "mem_node", "avg": 7805156010.666667, "p90": 10068443136.0, "p95": 10068443136.0}
      ]
}
```

You should see the below in the artifact under metrics directory.

### CPU foo
![CPU foo](./example_metrics_outputs/cpu_foo.png)

---

### CPU bar
![CPU bar](./example_metrics_outputs/cpu_bar.png)

---

### Memory foo
![Mem foo](./example_metrics_outputs/mem_foo.png)

---

### Memory bar
![Mem bar](./example_metrics_outputs/mem_bar.png)

---

### Memory Node
![Mem Node](./example_metrics_outputs/mem_node.png)