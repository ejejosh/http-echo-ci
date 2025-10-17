#!/usr/bin/env bash
set -euo pipefail
WORKDIR=$(pwd)
KIND_NAME=prci
KUBECONFIG=${KUBECONFIG:-"${WORKDIR}/kubeconfig.yaml"}
PF_PID=""

cleanup() {
  echo "Cleaning up background processes..."
  if [[ -n "${PF_PID:-}" ]]; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "=== Creating KinD cluster ==="
kind create cluster --name "$KIND_NAME" --config kind-config.yaml --wait 60s

echo "=== Exporting kubeconfig ==="
kind get kubeconfig --name "$KIND_NAME" > "${KUBECONFIG}"

# ------------------------------------------------------------------------
# Install ingress-nginx via Helm (tolerations/nodeSelector so it schedules in CI)
# ------------------------------------------------------------------------
echo "=== Installing ingress-nginx (Helm-based) ==="
kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true

helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx \
  --set controller.nodeSelector."kubernetes\.io/os"=linux \
  --set controller.tolerations[0].key="node-role.kubernetes.io/control-plane" \
  --set controller.tolerations[0].effect="NoSchedule" \
  --set controller.hostNetwork=true \
  --set controller.metrics.enabled=true

echo "=== Waiting for ingress-nginx controller to be Ready (timeout 5m) ==="
if ! kubectl wait --namespace ingress-nginx \
  --for=condition=Ready pod \
  -l app.kubernetes.io/component=controller \
  --timeout=300s; then
  echo "ingress-nginx failed to become Ready — collecting diagnostics..."
  kubectl get pods -n ingress-nginx -o wide || true
  kubectl describe pod -n ingress-nginx -l app.kubernetes.io/component=controller || true
  kubectl get events -n ingress-nginx --sort-by=.lastTimestamp | tail -n 50 || true
  echo "=== Node taints (may explain scheduling issues) ==="
  kubectl describe nodes | grep -A5 Taints || true
  exit 1
fi

# Wait validating webhook
echo "=== Waiting for validatingwebhookconfiguration 'ingress-nginx-admission' ==="
for i in {1..30}; do
  if kubectl get validatingwebhookconfigurations.admissionregistration.k8s.io ingress-nginx-admission >/dev/null 2>&1; then
    echo "validatingwebhookconfiguration exists."
    break
  fi
  echo "Waiting for validatingwebhookconfiguration (attempt $i/30)..."
  sleep 5
done

# Wait admission endpoints
ADMISSION_SVC="ingress-nginx-controller-admission"
echo "=== Ensuring admission service endpoints ($ADMISSION_SVC) have addresses ==="
for i in {1..40}; do
  EP_IPS=$(kubectl -n ingress-nginx get endpoints "$ADMISSION_SVC" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
  if [[ -n "${EP_IPS}" ]]; then
    echo "admission endpoints ready: ${EP_IPS}"
    break
  fi
  echo "⏳ Waiting for admission endpoints to appear (attempt $i/40)..."
  sleep 5
done

echo "=== ingress-nginx pods ==="
kubectl -n ingress-nginx get pods -o wide || true
echo "=== admission endpoints ==="
kubectl -n ingress-nginx get endpoints "$ADMISSION_SVC" -o yaml || true

# ------------------------------------------------------------------------
# Prometheus installation
# ------------------------------------------------------------------------
echo "=== Installing Prometheus (kube-prometheus-stack) via Helm ==="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace --wait --timeout 5m

echo "=== Waiting for Prometheus pods to be Ready (namespace monitoring) ==="
kubectl wait --for=condition=Ready pods --all -n monitoring --timeout=300s || true

# ------------------------------------------------------------------------
# Helm install helper with better diagnostics
# ------------------------------------------------------------------------
install_with_retries() {
  NAME="$1"
  CHART="$2"
  VALUES="$3"   # optional
  MAX_RETRIES=3
  SLEEP_BETWEEN=8
  ATTEMPT=0

  while true; do
    ((ATTEMPT++))
    echo "=== Helm install attempt ${ATTEMPT}/${MAX_RETRIES} for ${NAME} ==="
    TMP_OUT="$(mktemp)"
    set +e
    # capture both stdout and stderr
    helm upgrade --install "${NAME}" "${CHART}" ${VALUES:-} --wait --timeout 120s > "${TMP_OUT}" 2>&1 || rc=$?
    rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
      echo "Helm install ${NAME} succeeded"
      rm -f "${TMP_OUT}" || true
      break
    fi

    echo "Helm install ${NAME} failed with exit code ${rc}. Dumping helm output:"
    echo "----- HELM OUTPUT START (${NAME}) -----"
    sed -n '1,200p' "${TMP_OUT}" || true
    echo "----- HELM OUTPUT END (${NAME}) -----"

    # print helm status if any
    echo "=== Helm status for ${NAME} (best-effort) ==="
    helm status "${NAME}" || true

    # describe related K8s objects in default namespace to help debugging
    echo "=== kubectl get all for namespace 'default' (filtering by release ${NAME}) ==="
    kubectl get all -o wide --selector app.kubernetes.io/instance="${NAME}" || true

    echo "=== kubectl describe pods with release label (default namespace) ==="
    kubectl describe pods -l app.kubernetes.io/instance="${NAME}" || true

    echo "=== Recent events in default namespace ==="
    kubectl get events -n default --sort-by=.lastTimestamp | tail -n 50 || true

    # check admission endpoints again
    EP_CHECK=$(kubectl -n ingress-nginx get endpoints ingress-nginx-controller-admission -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
    if [[ -z "${EP_CHECK}" && "${ATTEMPT}" -lt "${MAX_RETRIES}" ]]; then
      echo "Webhook endpoints not ready (empty). Will wait ${SLEEP_BETWEEN}s and retry (attempt ${ATTEMPT}/${MAX_RETRIES})..."
      sleep "${SLEEP_BETWEEN}"
      rm -f "${TMP_OUT}" || true
      continue
    fi

    # if endpoints exist but helm still fails — print detailed pod/ingress info and exit
    echo "=== Detailed diagnostics (ingress-nginx namespace) ==="
    kubectl -n ingress-nginx get pods -o wide || true
    kubectl -n ingress-nginx describe pod -l app.kubernetes.io/component=controller || true
    kubectl -n ingress-nginx get svc -o wide || true
    echo "Helm install ${NAME} failed and is not retryable (or max retries reached). Failing now."
    rm -f "${TMP_OUT}" || true
    return $rc
  done

  return 0
}

echo "=== Deploying http-echo apps via Helm (declarative) ==="
install_with_retries foo charts/http-echo "--set app=foo" || true
install_with_retries bar charts/http-echo "--set app=bar" || true

# ------------------------------------------------------------------------
# host mapping, probing, load test, metrics collection, PR comment
# ------------------------------------------------------------------------
echo "=== Mapping hostnames to 127.0.0.1 in /etc/hosts (requires sudo) ==="
sudo -- sh -c 'grep -q "foo.localhost" /etc/hosts || echo "127.0.0.1 foo.localhost bar.localhost" >> /etc/hosts'
grep "foo.localhost" /etc/hosts || true

echo "=== Probing endpoints via curl ==="
for host in foo.localhost bar.localhost; do
  echo -n "HEAD $host -> "
  curl -sS -o /dev/null -w "%{http_code}\n" "http://$host/" || true
done

DURATION=30
echo "=== Starting Python load test (duration ${DURATION}s) ==="
START_TS=$(date +%s)
python3 scripts/loadtest.py 50 ${DURATION} > loadtest_json.txt || true
END_TS=$(date +%s)
echo "Load test completed. start=${START_TS} end=${END_TS}"

echo "=== Port-forwarding Prometheus to localhost:9090 (background) ==="
kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 >/tmp/pf-prom.log 2>&1 &
PF_PID=$!
sleep 4

echo "=== Collecting Prometheus range metrics between ${START_TS} and ${END_TS} ==="
python3 scripts/collect_metrics.py ${START_TS} ${END_TS} 15s

METRICS_JSON=$(cat metrics_summary.json | jq -c '.' )
BODY_HEADER="Automated Helm+Prometheus loadtest summary:\n\n"
BODY_SUMMARY="$(cat loadtest_json.txt | sed 's/\"/\\\"/g')\n\n"
BODY_METRICS="$(jq -r '.summary[] | "- \(.metric): avg=\(.avg), p90=\(.p90), p95=\(.p95)"' metrics_summary.json | sed 's/\"/\\\"/g')\n\n"

python3 - <<'PY' > images_md.txt
import json
m=json.load(open('metrics_summary.json'))
for name, datauri in m.get('images',{}).items():
    print(f"![{name}]({datauri})\n")
PY

BODY="${BODY_HEADER}${BODY_SUMMARY}${BODY_METRICS}$(cat images_md.txt)"
BODY_ESC=$(printf '%s' "$BODY" | sed -e ':a;N;$!ba;s/\\n/\\\\n/g' -e 's/\"/\\\\\"/g')

if [ -n "${PR_NUMBER:-}" ]; then
  echo "=== Posting comment to PR #${PR_NUMBER} ==="
  OWNER_REPO="$GITHUB_REPOSITORY"
  curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"body\": \"${BODY_ESC}\"}" \
    "https://api.github.com/repos/${OWNER_REPO}/issues/${PR_NUMBER}/comments" \
    | jq -r '.html_url' || true
else
  echo "PR_NUMBER not set; skipping comment step."
fi

echo "=== Done ==="
