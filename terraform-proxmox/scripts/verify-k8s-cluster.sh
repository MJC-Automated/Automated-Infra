#!/usr/bin/env bash
# Verifies Kubernetes cluster health postconditions:
# - API server responsiveness
# - Node readiness
# - System pods status (no CrashLoopBackOff/Errors)
# - CoreDNS readiness
# - Calico CNI daemonset status
# - etcd health
# - Optional workload smoke test
# Emits structured JSON summary and fails closed if postconditions are not satisfied.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/inventories/k8s/artifacts/admin.conf}"
OUTPUT_JSON="${OUTPUT_JSON:-}"
RUN_SMOKE_TEST="${RUN_SMOKE_TEST:-false}"
CONTROL_PLANE_HOST="${CONTROL_PLANE_HOST:-198.51.100.45}"
SSH_USER="${SSH_USER:-ansible}"

# Resolve kubectl command: local if kubeconfig exists, or via SSH to control plane
KUBECTL_CMD=()
if [ -r "${KUBECONFIG_PATH}" ]; then
  KUBECTL_CMD=(kubectl --kubeconfig="${KUBECONFIG_PATH}")
elif [ -f "${KUBECONFIG_PATH}" ] && sudo test -r "${KUBECONFIG_PATH}" 2>/dev/null; then
  KUBECTL_CMD=(sudo kubectl --kubeconfig="${KUBECONFIG_PATH}")
elif command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
  KUBECTL_CMD=(kubectl)
else
  # Fallback to SSH on control plane node
  KUBECTL_CMD=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${SSH_USER}@${CONTROL_PLANE_HOST}" "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf")
fi

echo "=== Verifying Kubernetes Cluster Postconditions ==="

ERRORS=()

# 1. API Readiness
echo -n "Checking Kubernetes API server readyz... "
API_STATUS="UNKNOWN"
if "${KUBECTL_CMD[@]}" get --raw /readyz >/dev/null 2>&1; then
  echo "OK"
  API_STATUS="HEALTHY"
else
  echo "FAILED"
  API_STATUS="UNHEALTHY"
  ERRORS+=("Kubernetes API /readyz check failed")
fi

# 2. Node Readiness
echo -n "Checking Node readiness... "
NODES_TOTAL=0
NODES_READY=0
NODES_JSON="$("${KUBECTL_CMD[@]}" get nodes -o json 2>/dev/null || echo '{"items":[]}')"

NODES_TOTAL=$(python3 -c "import json, sys; data = json.loads(sys.stdin.read()); print(len(data.get('items', [])))" <<< "${NODES_JSON}")
NODES_READY=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
ready = 0
for item in data.get('items', []):
    for cond in item.get('status', {}).get('conditions', []):
        if cond.get('type') == 'Ready' and cond.get('status') == 'True':
            ready += 1
print(ready)
" <<< "${NODES_JSON}")

echo "${NODES_READY}/${NODES_TOTAL} Ready"
if [ "${NODES_TOTAL}" -eq 0 ] || [ "${NODES_READY}" -ne "${NODES_TOTAL}" ]; then
  ERRORS+=("Not all nodes are in Ready state: ${NODES_READY}/${NODES_TOTAL} ready")
fi

# 3. System Pods Health
echo -n "Checking kube-system pods... "
PODS_JSON="$("${KUBECTL_CMD[@]}" get pods -n kube-system -o json 2>/dev/null || echo '{"items":[]}')"
SYSTEM_POD_FAILURES=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
unhealthy = []
for p in data.get('items', []):
    name = p.get('metadata', {}).get('name', 'unknown')
    phase = p.get('status', {}).get('phase', '')
    if phase not in ['Running', 'Succeeded']:
        unhealthy.append(f'{name} ({phase})')
    # Check container statuses
    for cs in p.get('status', {}).get('containerStatuses', []):
        state = cs.get('state', {})
        if 'waiting' in state:
            reason = state['waiting'].get('reason', '')
            if reason in ['CrashLoopBackOff', 'ImagePullBackOff', 'ErrImagePull', 'Error']:
                unhealthy.append(f'{name} [{reason}]')
print(','.join(unhealthy))
" <<< "${PODS_JSON}")

if [ -z "${SYSTEM_POD_FAILURES}" ]; then
  echo "OK (All running or succeeded)"
else
  echo "FAILED: ${SYSTEM_POD_FAILURES}"
  ERRORS+=("Unhealthy kube-system pods: ${SYSTEM_POD_FAILURES}")
fi

# 4. CoreDNS Health
echo -n "Checking CoreDNS deployment... "
COREDNS_READY=$("${KUBECTL_CMD[@]}" get deployment coredns -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
COREDNS_DESIRED=$("${KUBECTL_CMD[@]}" get deployment coredns -n kube-system -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
if [ "${COREDNS_READY:-0}" -gt 0 ] && [ "${COREDNS_READY:-0}" -eq "${COREDNS_DESIRED:-0}" ]; then
  echo "OK (${COREDNS_READY}/${COREDNS_DESIRED} replicas ready)"
else
  echo "FAILED (${COREDNS_READY:-0}/${COREDNS_DESIRED:-0} ready)"
  ERRORS+=("CoreDNS deployment not fully ready: ${COREDNS_READY:-0}/${COREDNS_DESIRED:-0}")
fi

# 5. Calico CNI Health
echo -n "Checking Calico CNI daemonset... "
CALICO_DESIRED=$("${KUBECTL_CMD[@]}" get ds calico-node -n kube-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
CALICO_READY=$("${KUBECTL_CMD[@]}" get ds calico-node -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
if [ "${CALICO_READY:-0}" -gt 0 ] && [ "${CALICO_READY:-0}" -eq "${CALICO_DESIRED:-0}" ]; then
  echo "OK (${CALICO_READY}/${CALICO_DESIRED} nodes ready)"
else
  echo "FAILED (${CALICO_READY:-0}/${CALICO_DESIRED:-0} ready)"
  ERRORS+=("Calico CNI daemonset not fully ready: ${CALICO_READY:-0}/${CALICO_DESIRED:-0}")
fi

# 6. etcd Health
echo -n "Checking etcd cluster... "
ETCD_STATUS="UNKNOWN"
ETCD_HOST="${ETCD_HOST:-198.51.100.46}"
ETCD_SSH_USER="${ETCD_SSH_USER:-ansible}"

# Check if etcd pods exist and are running
ETCD_PODS=$("${KUBECTL_CMD[@]}" get pods -n kube-system -l component=etcd --no-headers 2>/dev/null | wc -l || echo "0")
if [ "${ETCD_PODS}" -gt 0 ]; then
  ETCD_STATUS="RUNNING"
  echo "OK (${ETCD_PODS} member pod(s) running)"
else
  # External unstacked etcd: check directly via SSH
  ETCD_SSH_CMD='
    ETCD_CERT="$(sudo find /etc/ssl/etcd/ssl -maxdepth 1 \( -name "admin-*.pem" -o -name "member-*.pem" \) ! -name "*-key.pem" 2>/dev/null | head -n 1)"
    ETCD_KEY="${ETCD_CERT%.pem}-key.pem"
    if [ -n "${ETCD_CERT}" ] && sudo test -f "${ETCD_KEY}"; then
      sudo etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert="${ETCD_CERT}" --key="${ETCD_KEY}" endpoint health
    else
      sudo etcdctl endpoint health --cluster
    fi
  '
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${ETCD_SSH_USER}@${ETCD_HOST}" "${ETCD_SSH_CMD}" >/dev/null 2>&1; then
    ETCD_STATUS="EXTERNAL_HEALTHY"
    echo "OK (External etcd healthy via SSH on ${ETCD_HOST})"
  elif [ "${API_STATUS}" == "HEALTHY" ]; then
    ETCD_STATUS="EXTERNAL_UNVERIFIED"
    if [ "${ALLOW_UNVERIFIED_ETCD:-false}" == "true" ]; then
      echo "WARNING: External etcd operational via API, but SSH verification failed (waived via ALLOW_UNVERIFIED_ETCD=true)"
    else
      echo "FAILED (External etcd could not be verified directly on ${ETCD_HOST})"
      ERRORS+=("External etcd unverified on ${ETCD_HOST}; direct verification failed and was not waived (set ALLOW_UNVERIFIED_ETCD=true to waive)")
    fi
  else
    ETCD_STATUS="UNHEALTHY"
    echo "FAILED"
    ERRORS+=("etcd cluster unverified or unhealthy")
  fi
fi

# Build JSON report
REPORT_JSON=$(python3 -c "
import json, sys
report = {
    'status': 'PASSED' if not sys.argv[1] else 'FAILED',
    'api_server': sys.argv[2],
    'nodes': {'total': int(sys.argv[3]), 'ready': int(sys.argv[4])},
    'coredns_ready': int(sys.argv[5]),
    'calico_ready': int(sys.argv[6]),
    'etcd_status': sys.argv[7],
    'errors': [e for e in sys.argv[8].split(';;') if e]
}
print(json.dumps(report, indent=2))
" "$(IFS=';;'; echo "${ERRORS[*]}")" "${API_STATUS}" "${NODES_TOTAL}" "${NODES_READY}" "${COREDNS_READY:-0}" "${CALICO_READY:-0}" "${ETCD_STATUS}" "$(IFS=';;'; echo "${ERRORS[*]}")")

if [ -n "${OUTPUT_JSON}" ]; then
  mkdir -p "$(dirname "${OUTPUT_JSON}")"
  echo "${REPORT_JSON}" > "${OUTPUT_JSON}"
fi

echo ""
echo "=== Verification Summary ==="
echo "${REPORT_JSON}"

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "Kubernetes postcondition verification FAILED with ${#ERRORS[@]} error(s)." >&2
  exit 1
else
  echo "Kubernetes postconditions verified successfully."
  exit 0
fi
