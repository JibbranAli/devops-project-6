#!/bin/bash

# setup_prereqs.sh - Install all required tools and dependencies
# This script installs Docker, kubectl, kind/k3s, helm, argocd CLI, trivy, velero, kustomize, git, mkdocs

set -e

echo "🚀 Setting up prerequisites for Unified DevOps Pipeline..."

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

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   print_error "This script should not be run as root. Please run as a regular user with sudo privileges."
   exit 1
fi

# Detect package manager / distro
print_status "Detecting package manager..."
PKG_MGR=""
if command -v apt-get &> /dev/null; then
    PKG_MGR="apt"
elif command -v dnf &> /dev/null; then
    PKG_MGR="dnf"
elif command -v yum &> /dev/null; then
    PKG_MGR="yum"
else
    print_error "Supported package manager not found (apt, dnf, yum). Please install prerequisites manually."
    exit 1
fi

# Update system packages
print_status "Updating system packages..."
if [[ "$PKG_MGR" == "apt" ]]; then
    sudo apt-get update -y
else
    sudo ${PKG_MGR} -y update || true
fi

# Install basic dependencies
print_status "Installing basic dependencies..."
if [[ "$PKG_MGR" == "apt" ]]; then
    sudo apt-get install -y \
        curl \
        wget \
        git \
        unzip \
        jq \
        python3 \
        python3-pip \
        python3-venv \
        build-essential \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        software-properties-common
else
    # Amazon Linux / RHEL-family
    # Avoid curl conflicts with curl-minimal; install curl only if not present
    if rpm -q curl-minimal &> /dev/null; then
        CURL_PKG=""
    else
        CURL_PKG="curl"
    fi
    sudo ${PKG_MGR} -y --allowerasing install \
        ${CURL_PKG} \
        wget \
        git \
        unzip \
        jq \
        python3 \
        python3-pip \
        tar \
        gcc \
        make \
        ca-certificates || true
    # Ensure pip is up to date
    if ! command -v pip3 &> /dev/null; then
        python3 -m ensurepip --upgrade || true
    fi
    python3 -m pip install --upgrade --user pip || true
fi

# Install Docker
print_status "Installing Docker..."
if ! command -v docker &> /dev/null; then
    if [[ "$PKG_MGR" == "apt" ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -y
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        # Amazon Linux / RHEL-family
        sudo ${PKG_MGR} -y --allowerasing install docker || \
        sudo ${PKG_MGR} -y --allowerasing install moby-engine moby-cli
        sudo systemctl enable docker || true
        sudo systemctl start docker || true
    fi

    # Add user to docker group
    sudo usermod -aG docker $USER || true
    print_success "Docker installed successfully"
else
    print_warning "Docker is already installed"
fi

# Install kubectl
print_status "Installing kubectl..."
if ! command -v kubectl &> /dev/null; then
    KUBECTL_STABLE=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -L "https://dl.k8s.io/release/${KUBECTL_STABLE}/bin/linux/amd64/kubectl" -o /tmp/kubectl
    chmod +x /tmp/kubectl
    sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    rm -f /tmp/kubectl
    print_success "kubectl installed successfully"
else
    print_warning "kubectl is already installed"
fi

# Install kind (Kubernetes in Docker)
print_status "Installing kind..."
if ! command -v kind &> /dev/null; then
    curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
    chmod +x /tmp/kind
    sudo mv /tmp/kind /usr/local/bin/kind
    print_success "kind installed successfully"
else
    print_warning "kind is already installed"
fi

# Install Helm
print_status "Installing Helm..."
if ! command -v helm &> /dev/null; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    print_success "Helm installed successfully"
else
    print_warning "Helm is already installed"
fi

# Install ArgoCD CLI
print_status "Installing ArgoCD CLI..."
if ! command -v argocd &> /dev/null; then
    curl -sSL -o /tmp/argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
    sudo install -m 555 /tmp/argocd-linux-amd64 /usr/local/bin/argocd
    rm -f /tmp/argocd-linux-amd64
    print_success "ArgoCD CLI installed successfully"
else
    print_warning "ArgoCD CLI is already installed"
fi

# Install Trivy
print_status "Installing Trivy..."
if ! command -v trivy &> /dev/null; then
    curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /tmp
    sudo install -m 755 /tmp/trivy /usr/local/bin/trivy
    rm -f /tmp/trivy
    print_success "Trivy installed successfully"
else
    print_warning "Trivy is already installed"
fi

# Install Velero
print_status "Installing Velero..."
if ! command -v velero &> /dev/null; then
    wget -O /tmp/velero.tar.gz https://github.com/vmware-tanzu/velero/releases/download/v1.12.0/velero-v1.12.0-linux-amd64.tar.gz
    tar -xvf /tmp/velero.tar.gz -C /tmp
    sudo mv /tmp/velero-v1.12.0-linux-amd64/velero /usr/local/bin/
    rm -rf /tmp/velero-v1.12.0-linux-amd64* /tmp/velero.tar.gz
    print_success "Velero installed successfully"
else
    print_warning "Velero is already installed"
fi

# Install Kustomize
print_status "Installing Kustomize..."
if ! command -v kustomize &> /dev/null; then
    cd /tmp
    curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
    sudo mv /tmp/kustomize /usr/local/bin/ || sudo mv kustomize /usr/local/bin/
    cd - > /dev/null
    print_success "Kustomize installed successfully"
else
    print_warning "Kustomize is already installed"
fi

# Install MkDocs
print_status "Installing MkDocs..."
if ! command -v mkdocs &> /dev/null; then
    pip3 install mkdocs mkdocs-material mkdocs-mermaid2-plugin
    print_success "MkDocs installed successfully"
else
    print_warning "MkDocs is already installed"
fi

# Install additional Python packages for documentation
print_status "Installing additional Python packages..."
pip3 install --user pygments pymdown-extensions

# Create local bin directory and add to PATH
print_status "Setting up local bin directory..."
mkdir -p ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

# Install Docker Compose (standalone)
print_status "Installing Docker Compose..."
if ! command -v docker-compose &> /dev/null; then
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    print_success "Docker Compose installed successfully"
else
    print_warning "Docker Compose is already installed"
fi

# Verify installations
print_status "Verifying installations..."
echo "Docker version: $(docker --version)"
echo "kubectl version: $(kubectl version --client --short)"
echo "kind version: $(kind version)"
echo "Helm version: $(helm version --short)"
echo "ArgoCD CLI version: $(argocd version --client --short)"
echo "Trivy version: $(trivy --version | head -1)"
echo "Velero version: $(velero version --client)"
echo "Kustomize version: $(kustomize version --short)"
echo "MkDocs version: $(mkdocs --version)"

print_success "All prerequisites installed successfully!"
print_warning "Please log out and log back in for Docker group changes to take effect."
print_status "Next steps:"
echo "  1. Log out and log back in"
echo "  2. Run: ./bootstrap_cluster.sh"
echo "  3. Run: ./deploy_pipeline.sh"

# Helpful URLs (after cluster bootstrap and app deploy)
print_status "Planned access URLs (available after bootstrap and deploy):"
echo "  Flask App: http://flask-app.local"
echo "  Gitea:     http://gitea.local (admin/admin123)"
echo "  MinIO:     http://minio.local (minioadmin/minioadmin123)"
echo "  ArgoCD:    http://argocd.local (admin/<see command below>)"
echo ""
echo "Get ArgoCD password once cluster is up:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d && echo"
