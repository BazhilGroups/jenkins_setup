#!/usr/bin/env bash

# ============================================================
# SELF-HOSTED JENKINS VPS INSTALLER
# ============================================================
#
# Installs:
#   - Ubuntu updates
#   - Swap
#   - Docker Engine
#   - Docker Compose
#   - Java 21
#   - Jenkins LTS
#   - Jenkins -> Docker access
#   - Existing Docker Traefik reverse proxy integration
#   - HTTPS Jenkins URL
#
# IMPORTANT:
#
# Before running:
#
# 1. Point your DNS A record to this VPS:
#
#    jenkins.bazhilgroups.in -> YOUR_VPS_PUBLIC_IP
#
# 2. Make sure TCP 80 and 443 are reachable.
#
# 3. Change the required variables in the CONFIGURATION
#    section below.
#
# ============================================================

set -Eeuo pipefail


# ============================================================
#                  CONFIGURATION VARIABLES
# ============================================================
#
# CHANGE VALUES HERE FOR EACH VPS.
#
# Do NOT define commands such as docker, curl, apt-get,
# or systemctl as variables.
#
# Only reusable configuration/value variables are declared here.
#
# ============================================================


# ------------------------------------------------------------
# 1. JENKINS DOMAIN
# ------------------------------------------------------------

# Public domain used to access Jenkins.
JENKINS_DOMAIN="jenkins.bazhilgroups.in"

# ------------------------------------------------------------
# 2. JENKINS SERVER
# ------------------------------------------------------------

# Internal Jenkins HTTP port.
# Do NOT expose this port publicly.
JENKINS_PORT="8080"

# Public Jenkins URL.
JENKINS_URL="https://${JENKINS_DOMAIN}/"

# Jenkins Linux user.
JENKINS_USER="jenkins"

# Jenkins systemd service name.
JENKINS_SERVICE="jenkins"

# Docker systemd service name.
DOCKER_SERVICE="docker"

# Jenkins initial administrator password file.
JENKINS_PASSWORD_FILE="/var/lib/jenkins/secrets/initialAdminPassword"

# Jenkins location configuration file.
JENKINS_LOCATION_CONFIG="/var/lib/jenkins/jenkins.model.JenkinsLocationConfiguration.xml"

# Jenkins systemd override directory.
JENKINS_CONFIG_DIR="/etc/systemd/system/jenkins.service.d"

# Dedicated override fragment owned by this installer. It never replaces an
# administrator's existing override.conf.
JENKINS_OVERRIDE_FILE="${JENKINS_CONFIG_DIR}/jenkins-port.conf"


# ------------------------------------------------------------
# 3. SWAP
# ------------------------------------------------------------

# Desired total swap size in MB.
#
# Example:
#   2048 = 2 GB
#   4096 = 4 GB
#
TARGET_SWAP_MB="2048"

# Swap file created by this installer.
SWAP_FILE="/swapfile-jenkins"


# ------------------------------------------------------------
# 4. SERVER REQUIREMENTS
# ------------------------------------------------------------

# Minimum free disk space required in GB.
MIN_FREE_DISK_GB="20"

# Minimum RAM requirement in MB.
MIN_RAM_MB="2048"

# A full distribution upgrade can restart unrelated production services.
# Keep it opt-in; routine package installation below remains idempotent.
ALLOW_SYSTEM_UPGRADE="false"


# ------------------------------------------------------------
# 5. EXISTING TRAEFIK REVERSE PROXY
# ------------------------------------------------------------

# Leave these empty to discover them from the running Traefik instance.  They
# are overrides only for a deployment whose static configuration cannot expose
# this information through Docker inspect.  Supplying an override does not
# enable a missing file provider.
TRAEFIK_CONTAINER_OVERRIDE=""
TRAEFIK_DYNAMIC_DIR_OVERRIDE=""
TRAEFIK_HTTPS_ENTRYPOINT_OVERRIDE=""
TRAEFIK_CERT_RESOLVER_OVERRIDE=""
TRAEFIK_JENKINS_PORT="8080"


# ------------------------------------------------------------
# 6. NETWORK PORTS
# ------------------------------------------------------------

# Public HTTP port.
HTTP_PORT="80"

# Public HTTPS port.
HTTPS_PORT="443"


# ------------------------------------------------------------
# 7. DOCKER REPOSITORY
# ------------------------------------------------------------

# Official Docker repository.
DOCKER_REPO="https://download.docker.com/linux/ubuntu"

# Docker GPG key.
DOCKER_GPG_URL="${DOCKER_REPO}/gpg"

# Docker keyring.
DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"

# Docker APT source file.
DOCKER_SOURCE_FILE="/etc/apt/sources.list.d/docker.sources"


# ------------------------------------------------------------
# 8. JENKINS REPOSITORY
# ------------------------------------------------------------

# Official Jenkins repository.
JENKINS_REPO="https://pkg.jenkins.io/debian-stable"

# Jenkins GPG key.
JENKINS_GPG_URL="${JENKINS_REPO}/jenkins.io-2026.key"

# Jenkins keyring.
JENKINS_KEYRING="/etc/apt/keyrings/jenkins-keyring.asc"

# Jenkins APT source file.
JENKINS_SOURCE_FILE="/etc/apt/sources.list.d/jenkins.list"


# ------------------------------------------------------------
# 9. PUBLIC IP / DNS
# ------------------------------------------------------------

# Public IP detection service.
PUBLIC_IP_SERVICE="https://api.ipify.org"


# ------------------------------------------------------------
# 10. REQUIRED PACKAGES
# ------------------------------------------------------------

# Base packages required before installing Docker/Jenkins.
BASE_PACKAGES=(
    ca-certificates
    curl
    wget
    gnupg
    lsb-release
    apt-transport-https
    software-properties-common
    unzip
    git
    python3
)

# Java packages required by Jenkins.
JAVA_PACKAGES=(
    fontconfig
    openjdk-21-jre
)

# Docker packages.
DOCKER_PACKAGES=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
)


# ------------------------------------------------------------
# 11. RUNTIME VALUES
# ------------------------------------------------------------
#
# These variables are populated by the script.
# They are still declared together here so the script has
# one central variable section.
#

UBUNTU_CODENAME=""
TOTAL_RAM_MB="0"
AVAILABLE_DISK_GB="0"
CURRENT_SWAP_MB="0"
REQUIRED_SWAP_MB="0"
TRAEFIK_CONTAINER=""
TRAEFIK_DYNAMIC_DIR=""
TRAEFIK_JENKINS_CONFIG=""
TRAEFIK_HTTPS_ENTRYPOINT=""
TRAEFIK_CERT_RESOLVER=""
TRAEFIK_BACKEND_HOST=""
TRAEFIK_STATIC_CONFIG=""
JAVA_MAJOR=""


# ============================================================
#              END OF CONFIGURATION VARIABLES
# ============================================================


# ============================================================
# LOGGING
# ============================================================

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}


error_exit() {
    echo
    echo "ERROR: $1"
    echo
    exit 1
}


# Make a timestamped, root-only backup before changing a pre-existing file.
# The caller must have checked that the target is a regular file.
backup_file() {
    local target="$1"
    local backup="${target}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p -- "$target" "$backup"
    chmod 0600 "$backup"
    echo "Backed up ${target} to ${backup}"
}


require_command() {
    command -v "$1" >/dev/null 2>&1 || error_exit "Required command is unavailable: $1"
}


# Extract the first value passed as --option=value or --option value.
argument_value() {
    local option="$1"
    shift
    local previous=""
    local argument
    for argument in "$@"; do
        if [[ "$previous" == "$option" ]]; then
            printf '%s\n' "$argument"
            return 0
        fi
        if [[ "$argument" == "${option}="* ]]; then
            printf '%s\n' "${argument#*=}"
            return 0
        fi
        previous="$argument"
    done
    return 1
}


discover_traefik_container() {
    local candidates=()
    local id image name
    while IFS='|' read -r id image name; do
        [[ -n "$id" ]] || continue
        if [[ "$image" =~ (^|/)traefik(:|@|$) ]] || [[ "$name" =~ traefik ]]; then
            candidates+=("$name")
        fi
    done < <(docker ps --format '{{.ID}}|{{.Image}}|{{.Names}}')

    if [[ -n "$TRAEFIK_CONTAINER_OVERRIDE" ]]; then
        docker ps --format '{{.Names}}' | grep -Fxq "$TRAEFIK_CONTAINER_OVERRIDE" || \
            error_exit "Configured Traefik container is not running: ${TRAEFIK_CONTAINER_OVERRIDE}"
        TRAEFIK_CONTAINER="$TRAEFIK_CONTAINER_OVERRIDE"
    elif (( ${#candidates[@]} == 1 )); then
        TRAEFIK_CONTAINER="${candidates[0]}"
    elif (( ${#candidates[@]} == 0 )); then
        error_exit "No running Traefik container was found. Refusing to create proxy configuration."
    else
        error_exit "More than one Traefik-like container is running (${candidates[*]}). Set TRAEFIK_CONTAINER_OVERRIDE explicitly."
    fi
}


discover_static_configuration() {
    local -a args=()
    local arg source destination mode
    mapfile -t args < <(docker inspect -f '{{range .Args}}{{println .}}{{end}}' "$TRAEFIK_CONTAINER")
    if (( ${#args[@]} == 0 )); then
        mapfile -t args < <(docker inspect -f '{{range .Config.Cmd}}{{println .}}{{end}}' "$TRAEFIK_CONTAINER")
    fi

    TRAEFIK_STATIC_CONFIG=$(argument_value --configFile "${args[@]}" || true)
    if [[ -n "$TRAEFIK_STATIC_CONFIG" && ! -f "$TRAEFIK_STATIC_CONFIG" ]]; then
        # Translate a container config-file path to its host bind mount.
        while IFS='|' read -r source destination mode; do
            if [[ "$TRAEFIK_STATIC_CONFIG" == "$destination" && -f "$source" ]]; then
                TRAEFIK_STATIC_CONFIG="$source"
                break
            fi
        done < <(docker inspect -f '{{range .Mounts}}{{println .Source "|" .Destination "|" .Mode}}{{end}}' "$TRAEFIK_CONTAINER")
    fi

    if [[ -z "$TRAEFIK_DYNAMIC_DIR_OVERRIDE" ]]; then
        TRAEFIK_DYNAMIC_DIR=$(argument_value --providers.file.directory "${args[@]}" || true)
    else
        TRAEFIK_DYNAMIC_DIR="$TRAEFIK_DYNAMIC_DIR_OVERRIDE"
    fi

    # A static YAML config may hold the file-provider setting instead.  Limit
    # this search to the `providers.file` block; a random `directory:` key is
    # not evidence that the file provider is enabled.
    if [[ -z "$TRAEFIK_DYNAMIC_DIR" && -n "$TRAEFIK_STATIC_CONFIG" && -r "$TRAEFIK_STATIC_CONFIG" ]]; then
        TRAEFIK_DYNAMIC_DIR=$(awk '
            /^[[:space:]]*providers:[[:space:]]*(#.*)?$/ { providers=1; next }
            providers && /^[[:space:]]+file:[[:space:]]*(#.*)?$/ { file=1; next }
            providers && file && /^[[:space:]]+directory:[[:space:]]*/ {
                sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]#].*$/, ""); gsub(/^["'"'']|["'"'']$/, ""); print; exit
            }
            providers && /^[^[:space:]]/ { providers=0; file=0 }
        ' "$TRAEFIK_STATIC_CONFIG" || true)
    fi

    [[ -n "$TRAEFIK_DYNAMIC_DIR" ]] || error_exit "Traefik file-provider directory could not be discovered. Configure its file provider first, then set TRAEFIK_DYNAMIC_DIR_OVERRIDE only if necessary."

    # File-provider paths are normally container paths; translate only an exact
    # bind mount destination.  Named volumes are intentionally rejected.
    if [[ ! -d "$TRAEFIK_DYNAMIC_DIR" ]]; then
        while IFS='|' read -r source destination mode; do
            if [[ "$TRAEFIK_DYNAMIC_DIR" == "$destination" && -d "$source" ]]; then
                TRAEFIK_DYNAMIC_DIR="$source"
                break
            fi
        done < <(docker inspect -f '{{range .Mounts}}{{println .Source "|" .Destination "|" .Mode}}{{end}}' "$TRAEFIK_CONTAINER")
    fi
    [[ -d "$TRAEFIK_DYNAMIC_DIR" && -w "$TRAEFIK_DYNAMIC_DIR" ]] || \
        error_exit "The discovered Traefik file-provider directory is not a writable host directory: ${TRAEFIK_DYNAMIC_DIR}"

    if [[ -n "$TRAEFIK_HTTPS_ENTRYPOINT_OVERRIDE" ]]; then
        TRAEFIK_HTTPS_ENTRYPOINT="$TRAEFIK_HTTPS_ENTRYPOINT_OVERRIDE"
    else
        for arg in "${args[@]}"; do
            if [[ "$arg" =~ ^--entrypoints\.([A-Za-z0-9_-]+)\.address=.*:443$ ]]; then
                TRAEFIK_HTTPS_ENTRYPOINT="${BASH_REMATCH[1]}"
                break
            fi
        done
        if [[ -z "$TRAEFIK_HTTPS_ENTRYPOINT" && -n "$TRAEFIK_STATIC_CONFIG" && -r "$TRAEFIK_STATIC_CONFIG" ]]; then
            TRAEFIK_HTTPS_ENTRYPOINT=$(awk '
                /^[[:space:]]*entryPoints:[[:space:]]*(#.*)?$/ { inside=1; next }
                inside && /^[[:space:]]{2}[A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ { name=$1; sub(/:$/, "", name); next }
                inside && name != "" && /^[[:space:]]+address:[[:space:]]*/ && $0 ~ /:443(["'"'']|[[:space:]]|$)/ { print name; exit }
                inside && /^[^[:space:]]/ { inside=0 }
            ' "$TRAEFIK_STATIC_CONFIG" || true)
        fi
    fi
    [[ -n "$TRAEFIK_HTTPS_ENTRYPOINT" ]] || error_exit "HTTPS entrypoint (:443) could not be discovered. Set TRAEFIK_HTTPS_ENTRYPOINT_OVERRIDE after inspecting Traefik's static configuration."

    if [[ -n "$TRAEFIK_CERT_RESOLVER_OVERRIDE" ]]; then
        TRAEFIK_CERT_RESOLVER="$TRAEFIK_CERT_RESOLVER_OVERRIDE"
    else
        for arg in "${args[@]}"; do
            if [[ "$arg" =~ ^--certificatesresolvers\.([A-Za-z0-9_-]+)\. ]]; then
                TRAEFIK_CERT_RESOLVER="${BASH_REMATCH[1]}"
                break
            fi
        done
        if [[ -z "$TRAEFIK_CERT_RESOLVER" ]]; then
            TRAEFIK_CERT_RESOLVER=$(awk '
                /^[[:space:]]*certificatesResolvers:[[:space:]]*(#.*)?$/ { inside=1; next }
                inside && /^[[:space:]]{2}[A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ { name=$1; sub(/:$/, "", name); print name; exit }
                inside && /^[^[:space:]]/ { inside=0 }
            ' "$TRAEFIK_STATIC_CONFIG" 2>/dev/null || true)
        fi
        if [[ -z "$TRAEFIK_CERT_RESOLVER" ]]; then
            TRAEFIK_CERT_RESOLVER=$(grep -RhsE '^[[:space:]]*certResolver:[[:space:]]*[^[:space:]#]+' "$TRAEFIK_DYNAMIC_DIR" 2>/dev/null | sed -nE 's/^[[:space:]]*certResolver:[[:space:]]*([^[:space:]#]+).*/\1/p' | sort -u | head -n1 || true)
        fi
    fi
    [[ -n "$TRAEFIK_CERT_RESOLVER" ]] || error_exit "No existing certificate resolver could be discovered. Set TRAEFIK_CERT_RESOLVER_OVERRIDE only to a resolver already configured in Traefik."
}


verify_dns() {
    local public_ip ipv4_records ipv6_records
    public_ip=$(curl --fail --silent --show-error --connect-timeout 10 "$PUBLIC_IP_SERVICE") || error_exit "Could not determine this server's public IPv4 address."
    ipv4_records=$(getent ahostsv4 "$JENKINS_DOMAIN" | awk '{print $1}' | sort -u || true)
    ipv6_records=$(getent ahostsv6 "$JENKINS_DOMAIN" | awk '{print $1}' | sort -u || true)
    echo "DNS A records    : ${ipv4_records:-none}"
    echo "DNS AAAA records : ${ipv6_records:-none}"
    [[ "$ipv4_records" == *"$public_ip"* ]] || error_exit "DNS A record for ${JENKINS_DOMAIN} does not include this VPS (${public_ip})."
    [[ -z "$ipv6_records" ]] || error_exit "${JENKINS_DOMAIN} has AAAA records. Verify this VPS serves IPv6 before continuing; refusing to risk an unreachable TLS endpoint."
}


choose_backend_host() {
    local gateway
    gateway=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{println .Gateway}}{{end}}' "$TRAEFIK_CONTAINER" | sed '/^$/d' | head -n1)
    [[ -n "$gateway" ]] || error_exit "Traefik has no discoverable Docker network gateway for host access."

    # ExtraHosts is Docker's authoritative declaration for a host-gateway
    # mapping.  It is safer than assuming host.docker.internal exists on Linux.
    if docker inspect -f '{{range .HostConfig.ExtraHosts}}{{println .}}{{end}}' "$TRAEFIK_CONTAINER" | grep -Eq '^host\.docker\.internal:(host-gateway|[0-9a-fA-F:.]+)$'; then
        TRAEFIK_BACKEND_HOST="host.docker.internal"
    else
        TRAEFIK_BACKEND_HOST="$gateway"
    fi

    # Test via the Docker gateway even when host.docker.internal is selected:
    # that name is container-scoped and generally does not resolve on the host.
    curl --fail --silent --show-error --connect-timeout 5 "http://${gateway}:${TRAEFIK_JENKINS_PORT}/login" >/dev/null || \
        error_exit "Jenkins is not reachable from the Docker gateway at http://${gateway}:${TRAEFIK_JENKINS_PORT}/login. Ensure Jenkins listens beyond loopback before adding Traefik routing."
}


# ============================================================
# ERROR HANDLER
# ============================================================

trap 'error_exit "Installation failed at line $LINENO. Check the output above."' ERR


# ============================================================
# ROOT CHECK
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    error_exit "Run this script as root or with sudo."
fi


# ============================================================
# CONFIGURATION VALIDATION
# ============================================================

if [[ -z "$JENKINS_DOMAIN" ]]; then
    error_exit "JENKINS_DOMAIN cannot be empty."
fi

if [[ ! "$JENKINS_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    error_exit "Invalid Jenkins domain: $JENKINS_DOMAIN"
fi

if ! [[ "$JENKINS_PORT" =~ ^[0-9]+$ ]]; then
    error_exit "JENKINS_PORT must be a number."
fi

if ! [[ "$TARGET_SWAP_MB" =~ ^[0-9]+$ ]]; then
    error_exit "TARGET_SWAP_MB must be a number."
fi

if ! [[ "$MIN_FREE_DISK_GB" =~ ^[0-9]+$ ]]; then
    error_exit "MIN_FREE_DISK_GB must be a number."
fi

if ! [[ "$MIN_RAM_MB" =~ ^[0-9]+$ ]]; then
    error_exit "MIN_RAM_MB must be a number."
fi


# ============================================================
# OS CHECK
# ============================================================

log "Checking operating system"

if [[ ! -f /etc/os-release ]]; then
    error_exit "Cannot detect operating system."
fi

source /etc/os-release

if [[ "$ID" != "ubuntu" ]]; then
    error_exit "This installer is intended for Ubuntu."
fi

echo "Ubuntu version : $VERSION_ID"
echo "CPU cores      : $(nproc)"

echo
echo "Memory:"
free -h

echo
echo "Disk:"
df -h /


# ============================================================
# RESOURCE CHECK
# ============================================================

log "Checking server resources"

TOTAL_RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)

AVAILABLE_DISK_GB=$(
    df -BG / |
    awk 'NR==2 {
        gsub("G","",$4);
        print $4
    }'
)

echo "Total RAM          : ${TOTAL_RAM_MB} MB"
echo "Available disk     : ${AVAILABLE_DISK_GB} GB"
echo "Minimum RAM        : ${MIN_RAM_MB} MB"
echo "Minimum disk       : ${MIN_FREE_DISK_GB} GB"

if (( TOTAL_RAM_MB < MIN_RAM_MB )); then
    echo
    echo "WARNING: Server has less than ${MIN_RAM_MB} MB RAM."
fi

if (( AVAILABLE_DISK_GB < MIN_FREE_DISK_GB )); then
    error_exit "Less than ${MIN_FREE_DISK_GB} GB free disk space."
fi


# ============================================================
# STEP 1 - UPDATE UBUNTU
# ============================================================

log "STEP 1 - Updating Ubuntu"

export DEBIAN_FRONTEND=noninteractive

apt-get update

if [[ "$ALLOW_SYSTEM_UPGRADE" == "true" ]]; then
    apt-get upgrade -y
else
    echo "Skipping full system upgrade (ALLOW_SYSTEM_UPGRADE is not true)."
fi

apt-get install -y "${BASE_PACKAGES[@]}"


# ============================================================
# STEP 2 - SWAP
# ============================================================

log "STEP 2 - Configuring swap"

CURRENT_SWAP_MB=$(free -m | awk '/^Swap:/ {print $2}')

echo "Current swap : ${CURRENT_SWAP_MB} MB"
echo "Target swap  : ${TARGET_SWAP_MB} MB"

if (( CURRENT_SWAP_MB < TARGET_SWAP_MB )); then

    REQUIRED_SWAP_MB=$((TARGET_SWAP_MB - CURRENT_SWAP_MB))

    echo "Additional swap required: ${REQUIRED_SWAP_MB} MB"

    # If our swap file already exists, remove it safely.
    if [[ -f "$SWAP_FILE" ]]; then

        swapoff "$SWAP_FILE" 2>/dev/null || true

        sed -i "\|${SWAP_FILE}|d" /etc/fstab

        rm -f "$SWAP_FILE"

    fi

    fallocate -l "${REQUIRED_SWAP_MB}M" "$SWAP_FILE"

    chmod 600 "$SWAP_FILE"

    mkswap "$SWAP_FILE"

    if swapon "$SWAP_FILE"; then

        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab

        echo "Additional swap enabled."

    else

        echo "WARNING: The VPS environment does not permit enabling swap (swapon)."
        echo "Continuing without the additional swap file."

        rm -f "$SWAP_FILE"

    fi

else

    echo "Existing swap is already sufficient."

fi

echo
echo "Swap status:"
swapon --show

echo
free -h


# ============================================================
# STEP 3 - DOCKER
# ============================================================

log "STEP 3 - Installing Docker"

if command -v docker >/dev/null 2>&1; then

    echo "Docker is already installed."

else

    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL \
        "$DOCKER_GPG_URL" \
        -o "$DOCKER_KEYRING"

    chmod a+r "$DOCKER_KEYRING"

    UBUNTU_CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"

    cat > "$DOCKER_SOURCE_FILE" <<EOF
Types: deb
URIs: ${DOCKER_REPO}
Suites: ${UBUNTU_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: ${DOCKER_KEYRING}
EOF

    apt-get update

    apt-get install -y "${DOCKER_PACKAGES[@]}"

fi


systemctl enable "$DOCKER_SERVICE"

systemctl start "$DOCKER_SERVICE"


if ! systemctl is-active --quiet "$DOCKER_SERVICE"; then
    error_exit "Docker is not running."
fi


echo
docker --version

docker compose version


# ============================================================
# STEP 4 - JAVA 21
# ============================================================

log "STEP 4 - Installing Java 21"

apt-get install -y "${JAVA_PACKAGES[@]}"


JAVA_MAJOR=$(
    java -version 2>&1 |
    awk -F '"' '/version/ {print $2}' |
    cut -d. -f1
)


if [[ -z "$JAVA_MAJOR" ]] || (( JAVA_MAJOR < 21 )); then
    error_exit "Java 21 or newer is required."
fi


echo
java -version


# ============================================================
# STEP 5 - JENKINS LTS
# ============================================================

log "STEP 5 - Installing Jenkins LTS"

install -m 0755 -d /etc/apt/keyrings


curl -fsSL \
    "$JENKINS_GPG_URL" \
    -o "$JENKINS_KEYRING"


chmod 0644 "$JENKINS_KEYRING"


cat > "$JENKINS_SOURCE_FILE" <<EOF
deb [signed-by=${JENKINS_KEYRING}] ${JENKINS_REPO} binary/
EOF


apt-get update

apt-get install -y jenkins


# ============================================================
# STEP 6 - JENKINS SERVICE
# ============================================================

log "STEP 6 - Configuring Jenkins service"

systemctl daemon-reload

systemctl enable "$JENKINS_SERVICE"


mkdir -p "$JENKINS_CONFIG_DIR"

TMP_JENKINS_OVERRIDE=$(mktemp)
cat > "$TMP_JENKINS_OVERRIDE" <<EOF
[Service]
Environment="JENKINS_PORT=${JENKINS_PORT}"
EOF

if [[ -f "$JENKINS_OVERRIDE_FILE" ]] && ! cmp -s "$TMP_JENKINS_OVERRIDE" "$JENKINS_OVERRIDE_FILE"; then
    backup_file "$JENKINS_OVERRIDE_FILE"
fi
install -m 0644 "$TMP_JENKINS_OVERRIDE" "$JENKINS_OVERRIDE_FILE"
rm -f -- "$TMP_JENKINS_OVERRIDE"


systemctl daemon-reload


# ============================================================
# STEP 7 - JENKINS DOCKER ACCESS
# ============================================================

log "STEP 7 - Configuring Jenkins Docker access"

if id "$JENKINS_USER" >/dev/null 2>&1; then

    usermod -aG docker "$JENKINS_USER"

    echo "Jenkins added to Docker group."

else

    error_exit "Jenkins user '${JENKINS_USER}' was not created."

fi


# ============================================================
# STEP 8 - START JENKINS
# ============================================================

log "STEP 8 - Starting Jenkins"

systemctl restart "$JENKINS_SERVICE"


sleep 8


if ! systemctl is-active --quiet "$JENKINS_SERVICE"; then

    echo
    journalctl -u "$JENKINS_SERVICE" --no-pager -n 50

    error_exit "Jenkins failed to start."

fi


echo "Jenkins is running."


# ============================================================
# STEP 9 - EXISTING TRAEFIK REVERSE PROXY
# ============================================================

log "STEP 9 - Safely integrating with existing Traefik"

# Traefik owns public ports. This script writes one isolated dynamic file only
# after proving that the existing file provider can read it.
require_command docker
require_command curl
require_command getent
discover_traefik_container
discover_static_configuration

echo "Traefik container       : ${TRAEFIK_CONTAINER}"
echo "File-provider directory : ${TRAEFIK_DYNAMIC_DIR}"
echo "HTTPS entrypoint        : ${TRAEFIK_HTTPS_ENTRYPOINT}"
echo "Certificate resolver    : ${TRAEFIK_CERT_RESOLVER}"
echo "Published ports:"
docker port "$TRAEFIK_CONTAINER" || true
docker port "$TRAEFIK_CONTAINER" | grep -Eq '80|443' || error_exit "The discovered Traefik container does not publish HTTP(S) ports."

verify_dns

TRAEFIK_JENKINS_CONFIG="${TRAEFIK_DYNAMIC_DIR}/jenkins.yml"
if grep -RFl --exclude='jenkins.yml' -- "$JENKINS_DOMAIN" "$TRAEFIK_DYNAMIC_DIR" 2>/dev/null | grep -q .; then
    error_exit "An existing dynamic Traefik configuration already references ${JENKINS_DOMAIN}. Refusing to create a competing router."
fi
if docker ps -q | while read -r id; do docker inspect -f '{{range $key, $value := .Config.Labels}}{{println $key "=" $value}}{{end}}' "$id"; done | grep -F -- "$JENKINS_DOMAIN" >/dev/null; then
    error_exit "An existing Docker-label Traefik router already references ${JENKINS_DOMAIN}. Refusing to create a competing router."
fi
if [[ -e "$TRAEFIK_JENKINS_CONFIG" && ! -f "$TRAEFIK_JENKINS_CONFIG" ]]; then
    error_exit "Refusing to replace non-regular path: ${TRAEFIK_JENKINS_CONFIG}"
fi

choose_backend_host
TMP_TRAEFIK_CONFIG=$(mktemp "${TRAEFIK_DYNAMIC_DIR}/.jenkins.yml.XXXXXX")
trap 'rm -f -- "${TMP_TRAEFIK_CONFIG:-}"' EXIT
cat > "$TMP_TRAEFIK_CONFIG" <<EOF
# Managed by jenkins-vps-installer.sh. Do not add unrelated routers here.
http:
  routers:
    jenkins-https:
      rule: "Host(\`${JENKINS_DOMAIN}\`)"
      entryPoints:
        - "${TRAEFIK_HTTPS_ENTRYPOINT}"
      service: jenkins-service
      tls:
        certResolver: "${TRAEFIK_CERT_RESOLVER}"
  services:
    jenkins-service:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://${TRAEFIK_BACKEND_HOST}:${TRAEFIK_JENKINS_PORT}"
EOF

grep -Fq "Host(\`${JENKINS_DOMAIN}\`)" "$TMP_TRAEFIK_CONFIG" || error_exit "Generated router validation failed."
grep -Fq "http://${TRAEFIK_BACKEND_HOST}:${TRAEFIK_JENKINS_PORT}" "$TMP_TRAEFIK_CONFIG" || error_exit "Generated backend validation failed."

if [[ -f "$TRAEFIK_JENKINS_CONFIG" ]]; then
    if cmp -s "$TMP_TRAEFIK_CONFIG" "$TRAEFIK_JENKINS_CONFIG"; then
        rm -f -- "$TMP_TRAEFIK_CONFIG"
        unset TMP_TRAEFIK_CONFIG
        echo "Jenkins Traefik configuration is already current."
    else
        backup_file "$TRAEFIK_JENKINS_CONFIG"
        install -m 0644 "$TMP_TRAEFIK_CONFIG" "$TRAEFIK_JENKINS_CONFIG"
    fi
else
    install -m 0644 "$TMP_TRAEFIK_CONFIG" "$TRAEFIK_JENKINS_CONFIG"
fi

echo "Jenkins Traefik config : ${TRAEFIK_JENKINS_CONFIG}"
echo "Jenkins backend        : http://${TRAEFIK_BACKEND_HOST}:${TRAEFIK_JENKINS_PORT}"
echo "The existing file provider will reload the new file; Traefik was not restarted."


# ============================================================
# STEP 15 - JENKINS EXTERNAL URL
# ============================================================

log "STEP 15 - Configuring Jenkins URL"


if [[ -f "$JENKINS_LOCATION_CONFIG" ]]; then

    if grep -Fq "<jenkinsUrl>${JENKINS_URL}</jenkinsUrl>" "$JENKINS_LOCATION_CONFIG"; then
        echo "Jenkins external URL is already current."
    else
        backup_file "$JENKINS_LOCATION_CONFIG"

        python3 - <<PY
from pathlib import Path
import re

path = Path("${JENKINS_LOCATION_CONFIG}")

text = path.read_text()

text, replacements = re.subn(
    r"<jenkinsUrl>.*?</jenkinsUrl>",
    "<jenkinsUrl>${JENKINS_URL}</jenkinsUrl>",
    text,
    count=1,
    flags=re.DOTALL,
)
if replacements != 1:
    raise SystemExit("Jenkins location configuration has no jenkinsUrl element; it was not changed.")

path.write_text(text)
PY
    fi

else

    echo "Jenkins location configuration file does not exist yet."
    echo "Jenkins URL can be configured from Jenkins administration."

fi


systemctl restart "$JENKINS_SERVICE"


sleep 5


# ============================================================
# FINAL VERIFICATION
# ============================================================

log "FINAL VERIFICATION"


echo
echo "Jenkins:"
systemctl is-active "$JENKINS_SERVICE"


echo
echo "Docker:"
systemctl is-active "$DOCKER_SERVICE"


echo
echo "Java:"
java -version 2>&1 | head -1


echo
echo "Docker:"
docker --version


echo
echo "Docker Compose:"
docker compose version


echo
echo "Swap:"
swapon --show


echo
echo "Jenkins local port:"
ss -lntp | grep ":${JENKINS_PORT}" || true

echo
echo "Jenkins local HTTP status:"
LOCAL_JENKINS_STATUS=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --connect-timeout 5 "http://127.0.0.1:${JENKINS_PORT}/login" || true)
echo "${LOCAL_JENKINS_STATUS:-connection-failed}"
[[ "$LOCAL_JENKINS_STATUS" =~ ^(200|302|403)$ ]] || error_exit "Jenkins did not provide an expected local HTTP response."

echo
echo "Traefik Jenkins router:"
grep -E 'rule:|entryPoints:|certResolver:|url:' "$TRAEFIK_JENKINS_CONFIG"

echo
echo "Public HTTPS status:"
PUBLIC_HTTPS_STATUS=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --connect-timeout 10 --max-time 30 "$JENKINS_URL" || true)
echo "${PUBLIC_HTTPS_STATUS:-connection-failed}"
if [[ "$PUBLIC_HTTPS_STATUS" == "404" ]]; then
    error_exit "Public HTTPS returned Traefik-style 404: the Jenkins router was not loaded or a conflicting router remains."
fi
[[ "$PUBLIC_HTTPS_STATUS" =~ ^(200|302|403)$ ]] || error_exit "Public Jenkins HTTPS verification failed with status ${PUBLIC_HTTPS_STATUS:-connection-failed}."

echo
echo "TLS certificate (issuer and expiry only):"
require_command openssl
openssl s_client -connect "${JENKINS_DOMAIN}:443" -servername "$JENKINS_DOMAIN" </dev/null 2>/dev/null |
    openssl x509 -noout -issuer -enddate -subject
echo "TLS hostname validation: verified by the successful HTTPS curl above."


# ============================================================
# FINAL JENKINS INFORMATION
# ============================================================

echo
echo "============================================================"
echo "          SELF-HOSTED JENKINS SETUP COMPLETE"
echo "============================================================"


echo


echo "Jenkins URL:"
echo
echo "${JENKINS_URL}"
echo
echo "TLS termination and HTTPS redirect are managed by existing Traefik."


# ============================================================
# INITIAL PASSWORD
# ============================================================

echo


if [[ -f "$JENKINS_PASSWORD_FILE" ]]; then
    echo "The initial Jenkins administrator password is present at:"
    echo "${JENKINS_PASSWORD_FILE}"
    echo "It is intentionally not printed by this installer."
else
    echo "Initial Jenkins password file not present yet: ${JENKINS_PASSWORD_FILE}"
fi


# ============================================================
# INSTALLATION SUMMARY
# ============================================================

echo
echo "============================================================"
echo "WHAT WAS INSTALLED"
echo "============================================================"

echo

echo "Ubuntu preparation       : DONE"
echo "Swap                     : DONE"
echo "Docker                   : DONE"
echo "Docker Compose           : DONE"
echo "Java 21                  : DONE"
echo "Jenkins LTS              : DONE"
echo "Jenkins Docker access    : DONE"
echo "Jenkins service          : DONE"
echo "Existing Traefik proxy  : VERIFIED"
echo "Nginx/Certbot/UFW       : NOT TOUCHED"


# ============================================================
# NEXT STEPS
# ============================================================

echo
echo "============================================================"
echo "NEXT STEP"
echo "============================================================"

echo

echo "1. Open the Jenkins URL in your browser."

echo

echo "2. Complete the Jenkins initial setup."

echo

echo "3. Configure Jenkins credentials."

echo

echo "4. Connect GitHub/Bitbucket."

echo

echo "5. Configure webhooks."

echo

echo "6. Create your CI/CD pipelines."

echo

echo "GitHub/Bitbucket webhooks and CI/CD pipelines"
echo "are NOT configured by this installation script."

echo

echo "============================================================"
echo "JENKINS INSTALLATION FINISHED"
echo "============================================================"
