#!/usr/bin/env bash
# Generates CPU load against the app from inside the cluster so you can watch
# the HPA add pods and the Cluster Autoscaler add nodes.
#
#   ./scripts/load-test.sh            # 4 load generators (default)
#   ./scripts/load-test.sh 8          # more load
#   ./scripts/load-test.sh stop       # remove the load generators
#
# In another terminal:
#   kubectl get hpa,pods -n hello-world -o wide -w
#   kubectl get nodes -w
set -euo pipefail

NAMESPACE="${NAMESPACE:-hello-world}"
SERVICE_URL="http://hello-world.${NAMESPACE}.svc.cluster.local/"

if [[ "${1:-}" == "stop" ]]; then
  kubectl delete deployment load-generator -n "$NAMESPACE" --ignore-not-found
  echo "Load stopped. The HPA scales back down after its 5-minute stabilisation window,"
  echo "and the Cluster Autoscaler removes idle nodes a few minutes after that."
  exit 0
fi

REPLICAS="${1:-4}"

kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: load-generator
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels: { app: load-generator }
  template:
    metadata:
      labels: { app: load-generator }
    spec:
      containers:
        - name: hey
          image: busybox:1.36
          command: ["/bin/sh", "-c", "while true; do wget -q -O- ${SERVICE_URL} >/dev/null; done"]
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits:   { cpu: 200m, memory: 32Mi }
EOF

echo "Started ${REPLICAS} load generators against ${SERVICE_URL}"
