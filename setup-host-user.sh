#!/bin/bash
set -euo pipefail

required_vars=(TARGET_UID TARGET_GID)
for var in "${required_vars[@]}"; do
    if [ -z "${!var-}" ]; then
        echo "Error: $var is not set." >&2
        exit 1
    fi
done

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: setup-host-user.sh must run as root." >&2
    exit 1
fi

MARKER_DIR=/etc/cli-sandbox
MARKER_FILE=${MARKER_DIR}/user-${TARGET_UID}.marker

mkdir -p "$MARKER_DIR"
cat > "$MARKER_FILE" <<EOF
uid=$TARGET_UID
gid=$TARGET_GID
generated=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
chmod 600 "$MARKER_FILE"
