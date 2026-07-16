#!/usr/bin/env bash
# Ubuntu 24.04 - n8n + PostgreSQL + Caddy para Asterisk directo
# Uso: sudo bash install_n8n_asterisk_exam.sh

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

INSTALL_DIR="/opt/n8n"
LOG_FILE="/var/log/install_n8n_asterisk_exam.log"
SUMMARY_FILE="/root/N8N_ASTERISK_RESUMEN.txt"

exec > >(tee -a "$LOG_FILE") 2>&1
trap 'rc=$?; echo "ERROR en línea $LINENO (código $rc). Log: $LOG_FILE"; exit $rc' ERR

valid_ip() {
  local ip="$1" IFS=. a b c d
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r a b c d <<< "$ip"
  for n in "$a" "$b" "$c" "$d"; do (( n >= 0 && n <= 255 )) || return 1; done
}

wait_apt() {
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
        fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    echo "[INFO] Esperando APT/cloud-init..."
    sleep 5
  done
}

[[ $EUID -eq 0 ]] || { echo "Ejecuta con sudo."; exit 1; }
source /etc/os-release
[[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]] || {
  echo "Este script requiere Ubuntu 24.04."; exit 1;
}

echo "============================================================"
echo " n8n Docker para integración con Asterisk"
echo "============================================================"

read -r -p "Dominio DuckDNS (sin https://): " DOMAIN
DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%/}"
[[ "$DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] || {
  echo "Dominio inválido."; exit 1;
}

read -r -p "Correo para Let's Encrypt (Enter para omitir): " LE_EMAIL

while true; do
  read -r -p "IP privada de Asterisk: " ASTERISK_IP
  valid_ip "$ASTERISK_IP" && break
  echo "IP inválida."
done

timedatectl set-timezone America/Santiago

wait_apt
apt-get update -y
wait_apt
apt-get install -y ca-certificates curl gnupg openssl netcat-openbsd dnsutils vim git

PUBLIC_IP="$(curl -4 -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
DNS_IP="$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | head -n1 || true)"

echo "IP pública VM : $PUBLIC_IP"
echo "IP en DuckDNS : ${DNS_IP:-sin resolución}"

[[ "$PUBLIC_IP" == "$DNS_IP" ]] || {
  echo "ERROR: DuckDNS debe apuntar a $PUBLIC_IP antes de instalar."
  exit 1
}

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  apt-get remove -y docker.io docker-compose docker-compose-v2 docker-doc \
    podman-docker containerd runc 2>/dev/null || true

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  wait_apt
  apt-get update -y
  wait_apt
  apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
fi

systemctl enable --now docker

MEM_MB="$(free -m | awk '/^Mem:/ {print $2}')"
if (( MEM_MB < 3500 )) && ! swapon --show --noheadings | grep -q .; then
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

mkdir -p "$INSTALL_DIR/shared"
chown -R 1000:1000 "$INSTALL_DIR/shared"
chmod 750 "$INSTALL_DIR/shared"

if [[ -f "$INSTALL_DIR/.env" ]]; then
  PG_PASS="$(grep '^POSTGRES_PASSWORD=' "$INSTALL_DIR/.env" | cut -d= -f2- || true)"
  ENC_KEY="$(grep '^N8N_ENCRYPTION_KEY=' "$INSTALL_DIR/.env" | cut -d= -f2- || true)"
else
  PG_PASS=""
  ENC_KEY=""
fi

PG_PASS="${PG_PASS:-$(openssl rand -hex 24)}"
ENC_KEY="${ENC_KEY:-$(openssl rand -hex 32)}"

cat > "$INSTALL_DIR/.env" <<EOF
DOMAIN=$DOMAIN
LETSENCRYPT_EMAIL=$LE_EMAIL
POSTGRES_USER=n8n
POSTGRES_PASSWORD=$PG_PASS
POSTGRES_DB=n8n
N8N_ENCRYPTION_KEY=$ENC_KEY
GENERIC_TIMEZONE=America/Santiago
ASTERISK_PRIVATE_IP=$ASTERISK_IP
EOF
chmod 600 "$INSTALL_DIR/.env"

cat > "$INSTALL_DIR/compose.yaml" <<'EOF'
name: n8n-asterisk-exam

services:
  postgres:
    image: postgres:16-alpine
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 10

  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_HOST: ${DOMAIN}
      N8N_PORT: 5678
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://${DOMAIN}/
      N8N_EDITOR_BASE_URL: https://${DOMAIN}/
      N8N_PROXY_HOPS: 1
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS: "true"
      N8N_DEFAULT_BINARY_DATA_MODE: filesystem
      N8N_DIAGNOSTICS_ENABLED: "false"
      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
      TZ: ${GENERIC_TIMEZONE}
    volumes:
      - n8n_data:/home/node/.n8n
      - ./shared:/files
    expose:
      - "5678"

  caddy:
    image: caddy:2-alpine
    container_name: n8n-caddy
    restart: unless-stopped
    depends_on:
      - n8n
    ports:
      - "80:80/tcp"
      - "443:443/tcp"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  postgres_data:
  n8n_data:
  caddy_data:
  caddy_config:
EOF

if [[ -n "$LE_EMAIL" ]]; then
  cat > "$INSTALL_DIR/Caddyfile" <<EOF
{
  email $LE_EMAIL
}
$DOMAIN {
  encode zstd gzip
  reverse_proxy n8n:5678
}
EOF
else
  cat > "$INSTALL_DIR/Caddyfile" <<EOF
$DOMAIN {
  encode zstd gzip
  reverse_proxy n8n:5678
}
EOF
fi

cd "$INSTALL_DIR"
docker compose config --quiet
docker compose pull
docker compose up -d --remove-orphans

echo "[INFO] Esperando HTTPS..."
for _ in $(seq 1 60); do
  if curl -fsS --max-time 8 "https://$DOMAIN/healthz" >/dev/null 2>&1; then
    HTTPS_OK="sí"
    break
  fi
  HTTPS_OK="no"
  sleep 5
done

SSH_OK="no"
AMI_OK="no"
nc -z -w 3 "$ASTERISK_IP" 22 && SSH_OK="sí" || true
nc -z -w 3 "$ASTERISK_IP" 5038 && AMI_OK="sí" || true

{
  echo "============================================================"
  echo "RESUMEN n8n + ASTERISK"
  echo "============================================================"
  echo "URL n8n             : https://$DOMAIN"
  echo "IP pública n8n      : $PUBLIC_IP"
  echo "IP privada Asterisk : $ASTERISK_IP"
  echo "HTTPS operativo     : $HTTPS_OK"
  echo "SSH Asterisk 22     : $SSH_OK"
  echo "AMI Asterisk 5038   : $AMI_OK"
  echo
  echo "Webhook AGI:"
  echo "https://$DOMAIN/webhook/cita-resultado"
  echo
  echo "Comando de llamada desde nodo SSH:"
  echo 'sudo -n asterisk -rx "channel originate PJSIP/1001 extension 7000@internal"'
  echo
  echo "Archivos:"
  echo "$INSTALL_DIR/compose.yaml"
  echo "$INSTALL_DIR/Caddyfile"
  echo "$INSTALL_DIR/.env"
  echo "$INSTALL_DIR/shared  (visible como /files dentro de n8n)"
  echo
  echo "Seguridad:"
  echo "- SG-n8n: 22 desde tu IP; 80 y 443 desde Internet."
  echo "- SG-Asterisk: 22 desde SG-n8n."
  echo "- No abrir 5678 ni 5432."
  echo
  echo "Comandos:"
  echo "cd $INSTALL_DIR"
  echo "sudo docker compose ps"
  echo "sudo docker compose logs -f n8n"
  echo "sudo docker compose logs -f caddy"
  echo "============================================================"
} | tee "$SUMMARY_FILE"

docker compose ps
echo
echo "[OK] Abre https://$DOMAIN y crea la cuenta propietaria."
echo "Resumen: $SUMMARY_FILE"
