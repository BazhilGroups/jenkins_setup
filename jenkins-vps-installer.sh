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
#   - Nginx
#   - Domain reverse proxy
#   - Let's Encrypt SSL
#   - HTTPS Jenkins URL
#
# IMPORTANT:
#
# Before running:
#
# 1. Point your DNS A record to this VPS:
#
#    jenkins.example.com -> YOUR_VPS_PUBLIC_IP
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
# systemctl, nginx or certbot as variables.
#
# Only reusable configuration/value variables are declared here.
#
# ============================================================


# ------------------------------------------------------------
# 1. JENKINS DOMAIN
# ------------------------------------------------------------

# Public domain used to access Jenkins.
JENKINS_DOMAIN="jenkins.example.com"

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

# Jenkins systemd override file.
JENKINS_OVERRIDE_FILE="${JENKINS_CONFIG_DIR}/override.conf"


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


# ------------------------------------------------------------
# 5. NGINX
# ------------------------------------------------------------

# Nginx site name.
NGINX_SITE_NAME="jenkins"

# Nginx configuration path.
NGINX_CONFIG="/etc/nginx/sites-available/${NGINX_SITE_NAME}"

# Nginx enabled site path.
NGINX_ENABLED="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"

# Default Nginx site.
NGINX_DEFAULT="/etc/nginx/sites-enabled/default"


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

# Certbot packages.
CERTBOT_PACKAGES=(
    certbot
    python3-certbot-nginx
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
SERVER_IP=""
DNS_IP=""
SSL_READY="false"
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

if [[ "$JENKINS_DOMAIN" == "jenkins.example.com" ]]; then
    error_exit "Change JENKINS_DOMAIN before running the script."
fi

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

apt-get upgrade -y

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

    swapon "$SWAP_FILE"

    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab

    echo "Additional swap enabled."

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


cat > "$JENKINS_OVERRIDE_FILE" <<EOF
[Service]
Environment="JENKINS_PORT=${JENKINS_PORT}"
EOF


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
# STEP 9 - INSTALL NGINX
# ============================================================

log "STEP 9 - Installing Nginx"

apt-get install -y nginx


systemctl enable nginx

systemctl start nginx


# ============================================================
# STEP 10 - NGINX JENKINS REVERSE PROXY
# ============================================================

log "STEP 10 - Configuring Nginx"


cat > "$NGINX_CONFIG" <<EOF
server {

    listen ${HTTP_PORT};
    listen [::]:${HTTP_PORT};

    server_name ${JENKINS_DOMAIN};

    location / {

        proxy_pass http://127.0.0.1:${JENKINS_PORT};

        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 90;

        proxy_redirect off;
    }
}
EOF


ln -sf \
    "$NGINX_CONFIG" \
    "$NGINX_ENABLED"


# Remove default Nginx site.
rm -f "$NGINX_DEFAULT"


nginx -t


systemctl reload nginx


# ============================================================
# STEP 11 - FIREWALL
# ============================================================

log "STEP 11 - Configuring firewall"

apt-get install -y ufw


# Allow SSH.
ufw allow OpenSSH


# Allow public HTTP.
ufw allow "${HTTP_PORT}/tcp"


# Allow public HTTPS.
ufw allow "${HTTPS_PORT}/tcp"


# IMPORTANT:
#
# Jenkins port ${JENKINS_PORT} is intentionally NOT opened.
#
# Traffic flow:
#
# Internet
#    |
#    | HTTPS : ${HTTPS_PORT}
#    v
# Nginx
#    |
#    | HTTP : ${JENKINS_PORT}
#    v
# Jenkins
#


ufw --force enable


echo
ufw status


# ============================================================
# STEP 12 - INSTALL CERTBOT
# ============================================================

log "STEP 12 - Installing Let's Encrypt Certbot"

apt-get install -y "${CERTBOT_PACKAGES[@]}"


# ============================================================
# STEP 13 - DNS CHECK
# ============================================================

log "STEP 13 - Checking DNS"


SERVER_IP=$(
    curl -4 -s \
        --max-time 10 \
        "$PUBLIC_IP_SERVICE" ||
    true
)


DNS_IP=$(
    getent ahostsv4 "$JENKINS_DOMAIN" |
    awk 'NR==1 {print $1}' ||
    true
)


echo "VPS public IP : ${SERVER_IP}"
echo "Domain IP     : ${DNS_IP}"


if [[ -z "$SERVER_IP" ]]; then

    echo
    echo "WARNING: Could not determine VPS public IP."
    echo
    echo "SSL installation will be skipped."

    SSL_READY="false"


elif [[ -z "$DNS_IP" ]]; then

    echo
    echo "WARNING: DNS is not resolving yet."
    echo
    echo "Make sure:"
    echo "${JENKINS_DOMAIN} -> ${SERVER_IP}"
    echo
    echo "SSL installation will be skipped."

    SSL_READY="false"


elif [[ "$DNS_IP" != "$SERVER_IP" ]]; then

    echo
    echo "WARNING: Domain does not point to this VPS."
    echo
    echo "Expected:"
    echo "${SERVER_IP}"
    echo
    echo "Current:"
    echo "${DNS_IP}"
    echo
    echo "SSL installation will be skipped."

    SSL_READY="false"


else

    echo "DNS correctly points to this VPS."

    SSL_READY="true"

fi


# ============================================================
# STEP 14 - LET'S ENCRYPT SSL
# ============================================================

if [[ "$SSL_READY" == "true" ]]; then

    log "STEP 14 - Installing Let's Encrypt SSL"


    certbot \
        --nginx \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --redirect \
        -d "$JENKINS_DOMAIN"


    systemctl reload nginx


else

    log "STEP 14 - SSL SKIPPED"

    echo "Fix DNS first, then run:"
    echo

    echo "sudo certbot --nginx -d ${JENKINS_DOMAIN}"

fi


# ============================================================
# STEP 15 - JENKINS EXTERNAL URL
# ============================================================

log "STEP 15 - Configuring Jenkins URL"


if [[ -f "$JENKINS_LOCATION_CONFIG" ]]; then

    python3 - <<PY
from pathlib import Path

path = Path("${JENKINS_LOCATION_CONFIG}")

text = path.read_text()

text = text.replace(
    "<jenkinsUrl>http://localhost:8080/</jenkinsUrl>",
    "<jenkinsUrl>${JENKINS_URL}</jenkinsUrl>"
)

text = text.replace(
    "<jenkinsUrl>http://127.0.0.1:8080/</jenkinsUrl>",
    "<jenkinsUrl>${JENKINS_URL}</jenkinsUrl>"
)

path.write_text(text)
PY

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
echo "Nginx:"
systemctl is-active nginx


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
echo "Firewall:"
ufw status


# ============================================================
# FINAL JENKINS INFORMATION
# ============================================================

echo
echo "============================================================"
echo "          SELF-HOSTED JENKINS SETUP COMPLETE"
echo "============================================================"


echo


if [[ "$SSL_READY" == "true" ]]; then

    echo "Jenkins URL:"
    echo
    echo "${JENKINS_URL}"

else

    echo "Jenkins URL:"
    echo
    echo "http://${JENKINS_DOMAIN}"
    echo
    echo "SSL was not configured because DNS was not ready."

fi


# ============================================================
# INITIAL PASSWORD
# ============================================================

echo


if [[ -f "$JENKINS_PASSWORD_FILE" ]]; then

    echo "Initial Jenkins Administrator Password:"
    echo

    cat "$JENKINS_PASSWORD_FILE"

    echo

else

    echo "Initial password:"
    echo

    echo "sudo cat ${JENKINS_PASSWORD_FILE}"

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
echo "Nginx                    : DONE"
echo "Domain reverse proxy     : DONE"


if [[ "$SSL_READY" == "true" ]]; then

    echo "Let's Encrypt SSL        : DONE"
    echo "HTTPS redirect           : DONE"

else

    echo "Let's Encrypt SSL        : NOT CONFIGURED"

fi


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
