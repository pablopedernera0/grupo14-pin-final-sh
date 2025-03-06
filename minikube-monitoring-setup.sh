#!/bin/bash
# Complete Minikube Monitoring Solution
# This script sets up a fully functional monitoring stack on Minikube

# Step 1: Start with a clean Minikube cluster
echo "Stopping and removing existing Minikube cluster..."
minikube stop
minikube delete

echo "Starting new Minikube cluster with sufficient resources..."
minikube start --driver=docker --memory=6144 --cpus=4 --kubernetes-version=v1.26.3

# Step 2: Add Helm repositories
echo "Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add nginx-stable https://helm.nginx.com/stable
helm repo update

# Step 3: Create namespaces
echo "Creating namespaces..."
kubectl create namespace monitoring
kubectl create namespace ingress-nginx

# Step 4: Install Nginx Ingress Controller
echo "Installing Nginx Ingress Controller..."
helm install nginx-ingress nginx-stable/nginx-ingress \
  --namespace ingress-nginx \
  --set controller.metrics.enabled=true \
  --set controller.service.type=NodePort

# Step 5: Install Prometheus Operator Stack with minimized resource usage
echo "Installing Prometheus Operator stack with modified resource requirements..."
cat <<EOF > monitoring-values.yaml
prometheusOperator:
  resources:
    limits:
      cpu: 200m
      memory: 200Mi
    requests:
      cpu: 100m
      memory: 100Mi

prometheus:
  prometheusSpec:
    resources:
      limits:
        cpu: 300m
        memory: 1Gi
      requests:
        cpu: 100m
        memory: 512Mi
    retention: 1d
    storageSpec:
      emptyDir: {}

alertmanager:
  alertmanagerSpec:
    resources:
      limits:
        cpu: 100m
        memory: 200Mi
      requests:
        cpu: 50m
        memory: 100Mi
    storage:
      emptyDir: {}

grafana:
  resources:
    limits:
      cpu: 200m
      memory: 300Mi
    requests:
      cpu: 100m
      memory: 128Mi
  persistence:
    enabled: true
    size: 1Gi
    storageClassName: standard
  adminPassword: admin
  service:
    type: NodePort
  ingress:
    enabled: true
    ingressClassName: nginx
    path: /grafana
    hosts:
      - monitoring.local

nodeExporter:
  resources:
    limits:
      cpu: 100m
      memory: 100Mi
    requests:
      cpu: 50m
      memory: 50Mi

kubeStateMetrics:
  resources:
    limits:
      cpu: 100m
      memory: 200Mi
    requests:
      cpu: 50m
      memory: 100Mi
EOF

helm install monitoring-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring-values.yaml

# Step 6: Configure Nginx Ingress monitoring
echo "Setting up Nginx Ingress monitoring..."
cat <<EOF > nginx-servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nginx-ingress
  namespace: monitoring
  labels:
    release: monitoring-stack
spec:
  jobLabel: nginx-ingress
  selector:
    matchLabels:
      app: nginx-ingress
  namespaceSelector:
    matchNames:
      - ingress-nginx
  endpoints:
  - port: metrics
    interval: 30s
EOF

kubectl apply -f nginx-servicemonitor.yaml

# Step 7: Wait for pods to be ready
echo "Waiting for pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n monitoring --timeout=300s || true
kubectl wait --for=condition=Ready pods --all -n ingress-nginx --timeout=300s || true

# Step 8: Set up port-forwarding for Grafana
echo "Setting up port-forwarding for Grafana..."
GRAFANA_POD=$(kubectl get pods -n monitoring -l "app.kubernetes.io/name=grafana" -o jsonpath="{.items[0].metadata.name}")
kubectl port-forward -n monitoring pod/$GRAFANA_POD 3000:3000 &
PORT_FORWARD_PID=$!

echo "Setting up port-forwarding for Prometheus..."
PROMETHEUS_POD=$(kubectl get pods -n monitoring -l "app=prometheus" -o jsonpath="{.items[0].metadata.name}")
kubectl port-forward -n monitoring pod/$PROMETHEUS_POD 9090:9090 &
PROM_PORT_FORWARD_PID=$!

# Step 9: Configure Grafana dashboards
echo "Importing Nginx Ingress dashboard into Grafana..."
sleep 5 # Give port-forwarding time to establish

# Get Grafana admin password
GRAFANA_PASSWORD=$(kubectl get secret -n monitoring monitoring-stack-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
echo "Grafana credentials:"
echo "  URL: http://localhost:3000"
echo "  Username: admin"
echo "  Password: $GRAFANA_PASSWORD"

# Import dashboard
curl -s -k -u admin:$GRAFANA_PASSWORD -X POST \
  -H "Content-Type: application/json" \
  -d '{"dashboard":{"id":null,"uid":null,"title":"NGINX Ingress Controller","tags":["nginx"],"timezone":"browser","schemaVersion":16,"version":0},"folderId":0,"overwrite":true}' \
  http://localhost:3000/api/dashboards/db

# Print out info and next steps
MINIKUBE_IP=$(minikube ip)
echo ""
echo "==== Monitoring Setup Complete ===="
echo ""
echo "Access Grafana at: http://localhost:3000"
echo "Access Prometheus at: http://localhost:9090"
echo ""
echo "To access Grafana via Ingress, add this to your /etc/hosts file:"
echo "$MINIKUBE_IP monitoring.local"
echo "Then go to: http://monitoring.local/grafana"
echo ""
echo "Useful Dashboard IDs to Import:"
echo "- 9614 or 14314: NGINX Ingress Controller"
echo "- 1860: Node Exporter Full"
echo "- 10856: Kubernetes Cluster Overview"
echo "- 8588: Kubernetes Deployment Metrics"
echo ""
echo "Import dashboards via:"
echo "1. Grafana UI → + → Import → Enter Dashboard ID"
echo "2. Select the 'Prometheus' data source"
echo ""
echo "Press Ctrl+C to stop port-forwarding when done."

# Wait for user to stop script
wait $PORT_FORWARD_PID
wait $PROM_PORT_FORWARD_PID
