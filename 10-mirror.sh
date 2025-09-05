#!/bin/bash
set -euo pipefail

LOGFILE="/var/log/mirror-download-$(date +%F_%H-%M-%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

# ===== 1. Check subscription =====
if ! command -v subscription-manager >/dev/null 2>&1; then
    echo "❌ subscription-manager not found. Please install it first."
    exit 4
fi

if ! subscription-manager status >/dev/null 2>&1; then
    echo "❌ System is not registered or subscription invalid."
    exit 5
fi
echo "✅ System registered with valid subscription."

# ===== 2. Ask user for OpenShift version =====
read -rp "Enter OpenShift version to mirror (format 4.X.Y, ie. 4.19.5): " OCP_VERSION

if [[ ! "$OCP_VERSION" =~ ^4\.([0-9]{1,2})\.([0-9]{1,2})$ ]]; then
    echo "❌ Invalid format. Must be 4.<0-99>.<0-99> (e.g., 4.19.5)"
    exit 1
fi

MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
echo "✅ OpenShift version validated: $OCP_VERSION"

# ===== 2a. Ask user for OpenShift version for upgrade =====
read -rp "Enter OpenShift version (in case of upgrade planned) to mirror (format 4.X.Y, ie. 4.19.7). If upgrade isn't planned please enter the same version as above: " OCP_VERSION_UPGRADE

if [[ ! "$OCP_VERSION_UPGRADE" =~ ^4\.([0-9]{1,2})\.([0-9]{1,2})$ ]]; then
    echo "❌ Invalid format. Must be 4.<0-99>.<0-99> (e.g., 4.19.7)"
    exit 1
fi

if [[ "$(printf '%s\n%s' "$OCP_VERSION" "$OCP_VERSION_UPGRADE" | sort -V | head -n1)" == "$OCP_VERSION" && "$OCP_VERSION" != "$OCP_VERSION_UPGRADE" ]]; then
    echo "ℹ️ Mirroring images of $OCP_VERSION and $OCP_VERSION_UPGRADE for upgrade task."
elif [[ "$OCP_VERSION" == "$OCP_VERSION_UPGRADE" ]]; then
    echo "ℹ️ No upgrade is planned, $OCP_VERSION is equal $OCP_VERSION_UPGRADE."
else
    echo "❌ $OCP_VERSION is greater than $OCP_VERSION_UPGRADE"
    exit 1
fi

MAJOR_UPGRADE="${BASH_REMATCH[1]}"
MINOR_UPGRADE="${BASH_REMATCH[2]}"
echo "✅ OpenShift upgrade version validated: $OCP_VERSION_UPGRADE"


# ===== 3. Ask user for directory path & check space =====
read -rp "Enter path to working directory: " WORKDIR

if [ ! -d "$WORKDIR" ]; then
    echo "❌ Directory does not exist."
    exit 2
fi

REQUIRED_SPACE=$((1024 * 1024 * 1024)) # 1TB in KB
AVAILABLE=$(df -k --output=avail "$WORKDIR" | tail -n1)

if [ "$AVAILABLE" -lt "$REQUIRED_SPACE" ]; then
    echo "❌ Not enough space in $WORKDIR. Required: 1TB, Available: $((AVAILABLE/1024/1024)) GB"
    exit 3
fi
echo "✅ Directory exists and has enough free space."

# ===== 3a. Ask user for bastion FQDN ===== 
read -rp "Enter bastion FQDN: " BASTION_FQDN

if ping -c 1 -W 2 "${BASTION_FQDN}" > /dev/null 2>&1; then
  echo "✔ Host ${BASTION_FQDN} is reachable"
  export NO_PROXY=${NO_PROXY},${BASTION_FQDN}
else
  echo "❌ Host ${BASTION_FQDN} is not reachable"
  exit 1
fi

# ===== 3b. Ask user for Quay credentials ====
read -rp "Enter USERNAME for Quay ${BASTION_FQDN}:8443: " QUAY_USERNAME
read -rp "Enter PASSWORD for Quay ${BASTION_FQDN}:8443: " QUAY_PASSWORD

# Prepare subfolders
TOOLS_DIR="$WORKDIR/tools"
RPMS_DIR="$WORKDIR/rpms"
MIRROR_DIR="$WORKDIR/mirror"
mkdir -p "$TOOLS_DIR" "$RPMS_DIR" "$MIRROR_DIR"



# ===== 4. Ensure podman is installed =====
if ! command -v podman >/dev/null 2>&1; then
    echo "ℹ Installing podman..."
    sudo dnf -y install podman
    echo "✅ podman installed."
else
    echo "✅ podman already installed."
fi

# ===== 5. Ensure jq is installed =====
if ! command -v jq >/dev/null 2>&1; then
    echo "ℹ Installing jq..."
    sudo dnf -y install jq
    echo "✅ jq installed."
else
    echo "✅ jq already installed."
fi

# ===== 5a. Ensure jq is installed =====
if ! command -v createrepo >/dev/null 2>&1; then
    echo "ℹ Installing createrepo_c..."
    sudo dnf -y install createrepo_c
    echo "✅ createrepo_c installed."
else
    echo "✅ createrepo_c already installed."
fi

# ===== 6. Ask for pull-secret and validate JSON =====
echo "Paste your OpenShift pull-secret JSON (end with CTRL+D):"
PULL_SECRET=$(</dev/stdin)

if ! echo "$PULL_SECRET" | jq empty >/dev/null 2>&1; then
    echo "❌ Invalid JSON format for pull-secret."
    exit 6
fi

if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

AUTH_DIR="$XDG_RUNTIME_DIR/containers"
mkdir -p "$AUTH_DIR"
echo "$PULL_SECRET" > "$AUTH_DIR/auth.json"
chmod 600 "$AUTH_DIR/auth.json"
echo "✅ Pull-secret stored in $AUTH_DIR/auth.json"

# ===== 7. Download oc client =====
OC_TAR="$TOOLS_DIR/openshift-client-linux-$OCP_VERSION.tar.gz"
OC_URL="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$OCP_VERSION/openshift-client-linux-$OCP_VERSION.tar.gz"
echo "⬇ Downloading $OC_URL..."
curl -L "$OC_URL" -o "$OC_TAR"

# ===== 7a. Download oc client for upgrade task =====
if [[ "$OCP_VERSION" == "$OCP_VERSION_UPGRADE" ]]; then
    echo "✅ No upgrade is planned."
else
    OC_TAR_UPGRADE="$TOOLS_DIR/openshift-client-linux-$OCP_VERSION_UPGRADE.tar.gz"
    OC_URL_UPGRADE="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$OCP_VERSION_UPGRADE/openshift-client-linux-$OCP_VERSION_UPGRADE.tar.gz"
    echo "⬇ Downloading $OC_URL_UPGRADE for upgrade task..."
    curl -L "$OC_URL_UPGRADE" -o "$OC_TAR_UPGRADE"
fi


# ===== 8. Download oc-mirror tool =====
OCM_TAR="$TOOLS_DIR/oc-mirror.rhel9.tar.gz"
OC_MIRROR_URL="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest/oc-mirror.rhel9.tar.gz"
echo "⬇ Downloading $OC_MIRROR_URL..."
curl -L "$OC_MIRROR_URL" -o "$OCM_TAR"

# ===== 9. Download mirror-registry tool =====
MIRROR_REG_TAR="$TOOLS_DIR/mirror-registry-amd64.tar.gz"
MIRROR_REG_URL="https://mirror.openshift.com/pub/cgw/mirror-registry/latest/mirror-registry-amd64.tar.gz"
echo "⬇ Downloading $MIRROR_REG_URL..."
curl -L "$MIRROR_REG_URL" -o "$MIRROR_REG_TAR"

# ===== 9a. Download openshift-install tool =====
OPENSHIFT_INSTALL_TAR="$TOOLS_DIR/openshift-install-linux-${OCP_VERSION}.tar.gz"
OPENSHIFT_INSTALL_URL="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OCP_VERSION}/openshift-install-linux-${OCP_VERSION}.tar.gz"
echo "⬇ Downloading ${OPENSHIFT_INSTALL_URL}..."
curl -L "$OPENSHIFT_INSTALL_URL" -o "$OPENSHIFT_INSTALL_TAR"

# ===== 10. Download RPMs with dependencies =====
PKGS="nmstate vim mkpasswd tmux bash-completion podman wget git butane skopeo coreos-installer nginx createrepo_c dnsmasq tcpdump chrony"

echo "⬇ Downloading RPMs with dependencies to $RPMS_DIR..."
sudo dnf download --resolve --alldeps --destdir "$RPMS_DIR" $PKGS

# ===== 10a. Create repo
echo "ℹ Creating repo in $RPMS_DIR..."
sudo createrepo "$RPMS_DIR"

# ===== 10b. Disable all repos 
echo "Disabling all enabled repos..."
dnf config-manager --disable "*"

# ===== 3. Add repository to the system =====
REPO_FILE="/etc/yum.repos.d/local-mirror.repo"
echo "Adding local repository to $REPO_FILE"
sudo bash -c "cat > $REPO_FILE" <<EOF
[local-mirror]
name=Local Mirror Repository
baseurl=file://$RPMS_DIR
enabled=1
gpgcheck=0
priority=999
EOF

# ===== 4. Install required packages =====
PKGS="nmstate vim mkpasswd tmux bash-completion podman wget git butane skopeo coreos-installer nginx createrepo_c"
echo "Installing required packages..."
sudo dnf clean all
sudo dnf -y install $PKGS



# ===== 11. Extract & install oc-mirror =====
echo "📦 Extracting oc-mirror..."
tar -xzf "$OCM_TAR" -C "$TOOLS_DIR"
sudo cp "$TOOLS_DIR/oc-mirror" /usr/local/bin/
sudo chmod +x /usr/local/bin/oc-mirror
echo "✅ oc-mirror installed."

# ===== 12. Extract & install oc + kubectl =====
echo "📦 Extracting OpenShift client..."
tar -xzf "$OC_TAR" -C "$TOOLS_DIR"
sudo cp "$TOOLS_DIR/oc" /usr/local/bin/
sudo cp "$TOOLS_DIR/kubectl" /usr/local/bin/
sudo chmod +x /usr/local/bin/oc /usr/local/bin/kubectl
echo "✅ oc and kubectl installed."

# ===== 13. Create ImageSetConfiguration YAML =====
IMGSET_FILE="$WORKDIR/mirror.ImageSetConfiguration.yaml"

cat > "$IMGSET_FILE" <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
    - name: stable-4.$MAJOR
      minVersion: 4.$MAJOR.$MINOR
      maxVersion: 4.$MAJOR.$MINOR_UPGRADE
    graph: true
  operators:
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.$MAJOR
      packages:
       - name: advanced-cluster-management
       - name: cephcsi-operator
       - name: cincinnati-operator
       - name: cluster-kube-descheduler-operator
       - name: cluster-logging
       - name: cluster-observability-operator
       - name: clusterresourceoverride
       - name: fence-agents-remediation
       - name: kubernetes-nmstate-operator
       - name: kubevirt-hyperconverged
       - name: lightspeed-operator
       - name: local-storage-operator
       - name: machine-deletion-remediation
       - name: metallb-operator
       - name: mtv-operator
       - name: multicluster-engine
       - name: multicluster-global-hub-operator-rh
       - name: netobserv-operator
       - name: nfd
       - name: node-healthcheck-operator
       - name: node-maintenance-operator
       - name: node-observability-operator
       - name: numaresources-operator
       - name: ocs-client-operator
       - name: odf-operator
       - name: odf-dependencies
       - name: recipe
       - name: rook-ceph-operator
       - name: mcg-operator
       - name: openshift-cert-manager-operator
       - name: openshift-gitops-operator
       - name: openshift-pipelines-operator-rh
       - name: redhat-oadp-operator
       - name: self-node-remediation
       - name: sriov-network-operator
       - name: web-terminal
       - name: devworkspace-operator
       - name: ocs-operator
       - name: odf-csi-addons-operator
       - name: odr-cluster-operator
       - name: odr-hub-operator
       - name: odf-prometheus-operator
    - catalog: registry.redhat.io/redhat/redhat-marketplace-index:v4.$MAJOR
      packages:
       - name: k10-kasten-operator-rhmp
  additionalImages:
   - name: registry.redhat.io/ubi8/ubi:latest
   - name: registry.redhat.io/ubi9/ubi:latest
   - name: quay.io/rszmigie/net-tools:latest
EOF

echo "✅ ImageSetConfiguration file created at $IMGSET_FILE"

# ===== 5. Extract mirror-registry =====
echo "Extracting mirror-registry..."
tar -xzf "$MIRROR_REG_TAR" -C "$TOOLS_DIR"

# ===== 6. Run mirror-registry install =====
echo "Running mirror-registry install..."
sudo "$TOOLS_DIR/mirror-registry" install \
  --quayHostname ${BASTION_FQDN} \
  --initUser ${QUAY_USERNAME} \
  --initPassword ${QUAY_PASSWORD} \
  --quayRoot $WORKDIR \
  --quayStorage $WORKDIR/quay-storage \
  --sqliteStorage $WORKDIR/sqliteStorage

# ===== 6a. Ensure Quay's CA is known locally=====
echo "Ensure Quay's CA is known locally"
sudo cp $WORKDIR/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust

# ===== 7. Podman login to registry =====
echo "Logging in to quay registry with podman..."
podman login ${BASTION_FQDN}:8443 \
  --username ${QUAY_USERNAME} \
  --password ${QUAY_PASSWORD}

# ===== 8. Install oc, kubectl, oc-mirror =====
echo "Installing oc, kubectl, oc-mirror..."
if [ -f "$TOOLS_DIR/oc" ] && [ -f "$TOOLS_DIR/kubectl" ] && [ -f "$TOOLS_DIR/oc-mirror" ]; then
  sudo cp "$TOOLS_DIR/oc" /usr/local/bin/
  sudo cp "$TOOLS_DIR/kubectl" /usr/local/bin/
  sudo cp "$TOOLS_DIR/oc-mirror" /usr/local/bin/
  sudo chmod +x /usr/local/bin/oc /usr/local/bin/kubectl /usr/local/bin/oc-mirror
else
  echo "❌ Missing binaries in $TOOLS_DIR. Please ensure oc, kubectl, oc-mirror are downloaded and extracted."
  exit 1
fi

# ===== 9. Run oc mirror =====
echo "Running oc mirror..."
if [ ! -f "$IMGSET_FILE" ]; then
  echo "❌ ImageSetConfiguration not found at $IMGSET_FILE"
  exit 2
fi

oc mirror --v2 -c ${IMGSET_FILE} \
  --workspace file://${WORKDIR}/mirror \
  --retry-times 20 --retry-delay 5s \
  docker://${BASTION_FQDN}:8443

echo "====================================================="
echo "✔ Local registry mirroring completed."
echo "Mirror registry available at: ${BASTION_FQDN}:8443"
echo "====================================================="

