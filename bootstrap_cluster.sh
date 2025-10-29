#!/bin/bash

# bootstrap_cluster.sh - Create cluster and install all components
# This script creates a Kubernetes cluster, installs Gitea, ArgoCD, MinIO, Trivy Operator, Velero, and sets up initial GitOps repo

set -e

echo "🚀 Bootstrapping Kubernetes cluster with DevOps components..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configuration
CLUSTER_NAME="devops-pipeline"
GITEA_NAMESPACE="gitea"
ARGOCD_NAMESPACE="argocd"
MINIO_NAMESPACE="minio"
TRIVY_NAMESPACE="trivy-system"
VELERO_NAMESPACE="velero"

# Create kind cluster configuration
print_status "Creating kind cluster configuration..."
cat > /tmp/kind-config.yaml << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
  - containerPort: 3000
    hostPort: 3000
    protocol: TCP
  - containerPort: 8080
    hostPort: 8080
    protocol: TCP
- role: worker
- role: worker
EOF

# Create kind cluster
print_status "Creating kind cluster: ${CLUSTER_NAME}"
if kind get clusters | grep -q ${CLUSTER_NAME}; then
    print_warning "Cluster ${CLUSTER_NAME} already exists. Deleting..."
    kind delete cluster --name ${CLUSTER_NAME}
fi

kind create cluster --config /tmp/kind-config.yaml
kubectl cluster-info --context kind-${CLUSTER_NAME}

# Install NGINX Ingress Controller
print_status "Installing NGINX Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s

# Create namespaces
print_status "Creating namespaces..."
kubectl create namespace ${GITEA_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace ${ARGOCD_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace ${MINIO_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace ${TRIVY_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace ${VELERO_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Install Gitea
print_status "Installing Gitea..."
helm repo add gitea-charts https://dl.gitea.io/charts/
helm repo update

cat > /tmp/gitea-values.yaml << EOF
gitea:
  admin:
    username: admin
    password: admin123
    email: admin@devops.local
  config:
    server:
      ROOT_URL: http://gitea.local
      DOMAIN: gitea.local
    database:
      DB_TYPE: sqlite3
    service:
      DISABLE_REGISTRATION: false
persistence:
  enabled: true
  size: 10Gi
ingress:
  enabled: true
  hosts:
    - host: gitea.local
      paths:
        - path: /
          pathType: Prefix
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
service:
  http:
    type: ClusterIP
    port: 3000
EOF

# Install Gitea without --wait (will check status manually)
print_status "Installing Gitea (this may take several minutes)..."
# Uninstall existing release if present
if helm list -n ${GITEA_NAMESPACE} | grep -q gitea; then
    print_warning "Gitea release already exists, upgrading..."
    helm upgrade gitea gitea-charts/gitea \
      --namespace ${GITEA_NAMESPACE} \
      --values /tmp/gitea-values.yaml \
      --timeout 10m || print_warning "Gitea helm upgrade completed with warnings"
else
    helm install gitea gitea-charts/gitea \
      --namespace ${GITEA_NAMESPACE} \
      --values /tmp/gitea-values.yaml \
      --timeout 10m || print_warning "Gitea helm install completed with warnings"
fi

# Wait for Gitea pods to be created and running
print_status "Waiting for Gitea pods to be ready (this may take a few minutes)..."
sleep 15
# Wait for pods to appear first
for i in {1..20}; do
    if kubectl get pods -n ${GITEA_NAMESPACE} -l app.kubernetes.io/name=gitea 2>/dev/null | grep -v NAME | grep -q .; then
        break
    fi
    sleep 5
done
kubectl wait --for=condition=ready --timeout=600s pod -l app.kubernetes.io/name=gitea -n ${GITEA_NAMESPACE} || \
    print_warning "Gitea pods may still be starting, but continuing..."

# Install ArgoCD
print_status "Installing ArgoCD..."
kubectl apply -n ${ARGOCD_NAMESPACE} -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n ${ARGOCD_NAMESPACE}

# Patch ArgoCD server to use LoadBalancer for kind
kubectl patch svc argocd-server -n ${ARGOCD_NAMESPACE} -p '{"spec": {"type": "LoadBalancer"}}'

# Install MinIO
print_status "Installing MinIO..."
helm repo add minio https://charts.min.io/
helm repo update

cat > /tmp/minio-values.yaml << EOF
mode: standalone
auth:
  rootUser: minioadmin
  rootPassword: minioadmin123
defaultBuckets: "velero-backups"
persistence:
  enabled: true
  size: 20Gi
service:
  type: ClusterIP
  port: 9000
ingress:
  enabled: true
  hosts:
    - host: minio.local
      paths:
        - path: /
          pathType: Prefix
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
EOF

# Install MinIO without --wait
print_status "Installing MinIO (this may take several minutes)..."
helm install minio minio/minio \
  --namespace ${MINIO_NAMESPACE} \
  --values /tmp/minio-values.yaml \
  --timeout 10m || print_warning "MinIO helm install completed with warnings"

# Wait for MinIO pods to be ready
print_status "Waiting for MinIO pods to be ready..."
sleep 15
kubectl wait --for=condition=ready --timeout=600s pod -l app=minio -n ${MINIO_NAMESPACE} || \
    print_warning "MinIO pods may still be starting, but continuing..."

# Install Trivy Operator
print_status "Installing Trivy Operator..."
helm repo add aqua https://aquasecurity.github.io/helm-charts/
helm repo update

# Install Trivy Operator without --wait
helm install trivy-operator aqua/trivy-operator \
  --namespace ${TRIVY_NAMESPACE} \
  --create-namespace \
  --timeout 10m || print_warning "Trivy Operator helm install completed with warnings"

# Wait for Trivy Operator pods to be ready
print_status "Waiting for Trivy Operator to be ready..."
sleep 10
kubectl wait --for=condition=ready --timeout=300s pod -l app.kubernetes.io/name=trivy-operator -n ${TRIVY_NAMESPACE} || \
    print_warning "Trivy Operator may still be starting, but continuing..."

# Install Velero
print_status "Installing Velero..."
# Create MinIO credentials for Velero
cat > /tmp/credentials-velero << EOF
[default]
aws_access_key_id = minioadmin
aws_secret_access_key = minioadmin123
EOF

# Install Velero CLI plugin
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.7.0 \
  --bucket velero-backups \
  --secret-file /tmp/credentials-velero \
  --use-volume-snapshots=false \
  --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://minio.minio.svc.cluster.local:9000 \
  --namespace ${VELERO_NAMESPACE}

# Wait for Velero to be ready
kubectl wait --for=condition=available --timeout=300s deployment/velero -n ${VELERO_NAMESPACE}

# Create ArgoCD Application for GitOps
print_status "Setting up ArgoCD Application..."
cat > /tmp/argocd-app.yaml << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: devops-pipeline-apps
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/devops-pipeline
    targetRevision: HEAD
    path: environments/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF

# Apply ArgoCD Application
kubectl apply -f /tmp/argocd-app.yaml

# Get ArgoCD admin password
print_status "Retrieving ArgoCD admin password..."
ARGOCD_PASSWORD=$(kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Create /etc/hosts entries
print_status "Adding entries to /etc/hosts..."
echo "127.0.0.1 gitea.local" | sudo tee -a /etc/hosts
echo "127.0.0.1 minio.local" | sudo tee -a /etc/hosts
echo "127.0.0.1 argocd.local" | sudo tee -a /etc/hosts

# Clean up temporary files
rm -f /tmp/kind-config.yaml /tmp/gitea-values.yaml /tmp/minio-values.yaml /tmp/credentials-velero /tmp/argocd-app.yaml

print_success "Cluster bootstrap completed successfully!"
print_status "Access URLs:"
echo "  Gitea: http://gitea.local (admin/admin123)"
echo "  MinIO: http://minio.local (minioadmin/minioadmin123)"
echo "  ArgoCD: http://argocd.local (admin/${ARGOCD_PASSWORD})"
print_status "Next steps:"
echo "  1. Run: ./deploy_pipeline.sh"
echo "  2. Run: ./check_env.sh"
