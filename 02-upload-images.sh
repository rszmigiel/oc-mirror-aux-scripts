#!/bin/bash
set -euo pipefail

LOGFILE="/var/log/mirror-upload-$(date +%F_%H-%M-%S).log"
exec > >(tee -a "$LOGFILE") 2>&1


# ===== 1. Ask user for directory path =====
read -rp "Enter path to working directory: " WORKDIR

if [ ! -d "$WORKDIR" ]; then
	    echo "❌ Directory does not exist."
	        exit 2
fi


DIRS=("tools" "rpms" "mirror")

for d in "${DIRS[@]}"; do
  if [ -d "$WORKDIR/$d" ]; then
    echo "✔ $WORKDIR/$d exists"
  else
    echo "❌ $WORKDIR/$d is missing"
    exit 1
  fi
done

TOOLS_DIR="$WORKDIR/tools"
RPMS_DIR="$WORKDIR/rpms"
MIRROR_DIR="$WORKDIR/mirror"
IMGSET_FILE="$WORKDIR/mirror.ImageSetConfiguration.yaml"
MIRROR_REG_TAR="$TOOLS_DIR/mirror-registry-amd64.tar.gz"


# ===== 1a. Ask user for bastion FQDN ===== 
read -rp "Enter bastion FQDN: " BASTION_FQDN

if ping -c 1 -W 2 "${BASTION_FQDN}" > /dev/null 2>&1; then
  echo "✔ Host ${BASTION_FQDN} is reachable"
else
  echo "❌ Host ${BASTION_FQDN} is not reachable"
  exit 1
fi

# ===== 1b. Ask user for Quay credentials ====
read -rp "Enter USERNAME for Quay ${BASTION_FQDN}:8443: " QUAY_USERNAME
read -rp "Enter PASSWORD for Quay ${BASTION_FQDN}:8443: " QUAY_PASSWORD



# ===== 2. Disable all repositories permanently =====
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
EOF

# ===== 4. Install required packages =====
PKGS="nmstate vim mkpasswd tmux bash-completion podman wget git butane skopeo coreos-installer nginx createrepo_c"
echo "Installing required packages..."
sudo dnf clean all
sudo dnf -y install $PKGS

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

oc mirror -c "$IMGSET_FILE" \
  --from "file://$MIRROR_DIR" \
  --cache-dir "$WORKDIR/cache" \
  "docker://${BASTION_FQDN}:8443" \
  --v2

echo "====================================================="
echo "✔ Local registry mirroring completed."
echo "Mirror registry available at: ${BASTION_FQDN}:8443"
echo "====================================================="

