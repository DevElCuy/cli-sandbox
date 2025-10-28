#!/bin/bash
set -euo pipefail

required_vars=(TARGET_UID TARGET_GID)
for var in "${required_vars[@]}"; do
    if [ -z "${!var-}" ]; then
        echo "Error: $var is not set." >&2
        exit 1
    fi
done

if [ "${TARGET_UID}" -eq 0 ]; then
    echo "Skipping user setup for root (UID 0)."
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: setup-host-user.sh must run as root." >&2
    exit 1
fi

# Get target username
TARGET_USER=$(id -un "$TARGET_UID")
if [ -z "$TARGET_USER" ]; then
    echo "Error: Could not determine username for UID $TARGET_UID." >&2
    exit 1
fi

# NVM and Node.js configuration
NVM_DIR="/home/$TARGET_USER/.nvm" # NVM will be installed in the user's home directory
NODE_VERSION="v22" # Use the same version as in the Dockerfile previously

# Check if nvm is already installed for the target user
if [ ! -d "$NVM_DIR" ]; then
    echo "Installing nvm for user $TARGET_USER..."
    su - "$TARGET_USER" -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash"
    echo "nvm installed."
fi

# Install Node.js for the target user
echo "Installing Node.js $NODE_VERSION for user $TARGET_USER..."
su - "$TARGET_USER" -c "export NVM_DIR=\"$NVM_DIR\" && [ -s \"$NVM_DIR/nvm.sh\" ] && \\. \"$NVM_DIR/nvm.sh\" && nvm install $NODE_VERSION && nvm alias default $NODE_VERSION"
echo "Node.js $NODE_VERSION installed and set as default."

echo "$(ip route | awk '/default/ {print $3}') host.docker.internal" >> /etc/hosts

MARKER_DIR=/etc/cli-sandbox
MARKER_FILE=${MARKER_DIR}/user-${TARGET_UID}.marker

mkdir -p "$MARKER_DIR"
cat > "$MARKER_FILE" <<EOF
uid=$TARGET_UID
gid=$TARGET_GID
generated=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
chmod 600 "$MARKER_FILE"
