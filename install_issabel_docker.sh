#!/usr/bin/env bash
#
# install_issabel_docker.sh
# Despliegue académico de Issabel PBX en Docker sobre Ubuntu 24.04.
#
# Puertos publicados en la EC2:
#   80/TCP   -> 880/TCP dentro del contenedor (HTTP Issabel)
#   443/TCP  -> 4443/TCP dentro del contenedor (HTTPS Issabel)
#   5060/UDP -> 5060/UDP dentro del contenedor (SIP)
#   5060/TCP -> 5060/TCP dentro del contenedor (SIP TCP)
#   5061/TCP -> 5061/TCP dentro del contenedor (SIP TLS, opcional)
#   10000-10100/UDP -> RTP de audio
#
# Uso:
#   sudo bash install_issabel_docker.sh
#
# Nota:
#   Esta imagen es antigua y se utiliza solamente como demostración académica
#   de containerización. No se recomienda para producción.
#

set -Eeuo pipefail

readonly IMAGE="technoexpress/issabel-pbx:latest"
readonly CONTAINER_NAME="issabel-pbx"
readonly INSTALL_DIR="/opt/issabel-docker"
readonly COMPOSE_FILE="${INSTALL_DIR}/compose.yaml"
readonly LOG_FILE="/var/log/install_issabel_docker.log"
readonly SUMMARY_FILE="/var/log/issabel_docker_resumen.txt"

exec > >(tee -a "$LOG_FILE") 2>&1

on_error() {
    local exit_code=$?
    local line_number="${1:-desconocida}"

    echo
    echo "============================================================"
    echo "ERROR DE INSTALACIÓN"
    echo "Línea: ${line_number}"
    echo "Código: ${exit_code}"
    echo "Revisar: ${LOG_FILE}"
    echo "============================================================"
    exit "$exit_code"
}

trap 'on_error $LINENO' ERR

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: ejecuta el script con sudo."
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    echo "ERROR: no se pudo identificar el sistema operativo."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    echo "ERROR: este script está preparado para Ubuntu 24.04."
    echo "Sistema detectado: ${PRETTY_NAME:-desconocido}"
    exit 1
fi

wait_for_apt() {
    local retries=60

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        echo "[INFO] Esperando que cloud-init o APT liberen sus bloqueos..."
        sleep 5
        retries=$((retries - 1))

        if [[ $retries -le 0 ]]; then
            echo "ERROR: se agotó el tiempo esperando APT."
            exit 1
        fi
    done
}

wait_for_docker() {
    local retries=30

    until docker info >/dev/null 2>&1; do
        echo "[INFO] Esperando al daemon de Docker..."
        sleep 3
        retries=$((retries - 1))

        if [[ $retries -le 0 ]]; then
            echo "ERROR: Docker no respondió."
            systemctl status docker --no-pager || true
            exit 1
        fi
    done
}

check_host_ports() {
    local port

    for port in 80 443 5060; do
        if ss -H -lntup 2>/dev/null | grep -Eq ":${port}[[:space:]]"; then
            echo "ERROR: el puerto ${port} ya está ocupado en la VM."
            echo "Revisa con: sudo ss -lntup | grep ':${port}'"
            exit 1
        fi
    done
}

wait_for_issabel() {
    local retries=72

    while [[ $retries -gt 0 ]]; do
        if docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true; then
            if curl -fsS --max-time 5 "http://127.0.0.1/" >/dev/null 2>&1 || \
               curl -kfsS --max-time 5 "https://127.0.0.1/" >/dev/null 2>&1; then
                return 0
            fi
        fi

        echo "[INFO] Esperando que Issabel publique la interfaz web..."
        sleep 5
        retries=$((retries - 1))
    done

    echo "ADVERTENCIA: el contenedor está creado, pero la web no respondió dentro del tiempo esperado."
    echo "Revisa con: sudo docker logs --tail 150 ${CONTAINER_NAME}"
    return 0
}

echo "============================================================"
echo "INSTALACIÓN DE ISSABEL PBX EN DOCKER"
echo "Inicio: $(date '+%F %T')"
echo "Imagen: ${IMAGE}"
echo "============================================================"

wait_for_apt
apt-get update -y

wait_for_apt
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    iproute2 \
    net-tools

echo "[INFO] Eliminando paquetes Docker que podrían generar conflictos..."
apt-get remove -y \
    docker.io \
    docker-compose \
    docker-compose-v2 \
    docker-doc \
    podman-docker \
    containerd \
    runc 2>/dev/null || true

echo "[INFO] Configurando el repositorio oficial de Docker..."
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

wait_for_apt
apt-get update -y

wait_for_apt
apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

systemctl enable --now docker
wait_for_docker

echo "[INFO] Versiones instaladas:"
docker --version
docker compose version

mkdir -p "$INSTALL_DIR"

# Si el script se vuelve a ejecutar, retira el contenedor anterior,
# pero mantiene los volúmenes persistentes.
if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    echo "[INFO] Eliminando el contenedor anterior sin borrar sus volúmenes..."
    docker rm -f "$CONTAINER_NAME"
fi

check_host_ports

cat > "$COMPOSE_FILE" <<'EOF'
name: issabel-demo

services:
  issabel:
    image: technoexpress/issabel-pbx:latest
    container_name: issabel-pbx
    hostname: issabel-pbx
    privileged: true
    cap_add:
      - NET_ADMIN
    restart: unless-stopped

    # La imagen escucha internamente en 880/HTTP y 4443/HTTPS.
    # Se publican como 80 y 443 en la instancia EC2.
    ports:
      - "80:880/tcp"
      - "443:4443/tcp"
      - "5060:5060/udp"
      - "5060:5060/tcp"
      - "5061:5061/tcp"
      - "5061:5061/udp"
      - "10000-10100:10000-10100/udp"

    volumes:
      - issabel_etc:/etc
      - issabel_www:/var/www
      - issabel_log:/var/log
      - issabel_lib:/var/lib
      - issabel_home:/home
      - /etc/resolv.conf:/etc/resolv.conf:ro
      - /sys/fs/cgroup:/sys/fs/cgroup:ro

volumes:
  issabel_etc:
  issabel_www:
  issabel_log:
  issabel_lib:
  issabel_home:
EOF

echo "[INFO] Validando Docker Compose..."
docker compose -f "$COMPOSE_FILE" config >/dev/null

echo "[INFO] Descargando la imagen..."
docker compose -f "$COMPOSE_FILE" pull

echo "[INFO] Creando el contenedor..."
docker compose -f "$COMPOSE_FILE" up -d

wait_for_issabel

PUBLIC_IP="$(curl -4 -fsS https://checkip.amazonaws.com 2>/dev/null | tr -d '\n' || true)"
PRIVATE_IP="$(hostname -I | awk '{print $1}')"
CONTAINER_STATUS="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)"
PORT_BINDINGS="$(docker port "$CONTAINER_NAME" 2>/dev/null || true)"
IMAGE_DIGEST="$(docker image inspect "$IMAGE" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"

{
    echo "============================================================"
    echo "RESUMEN DE DESPLIEGUE ISSABEL DOCKER"
    echo "Fecha: $(date '+%F %T')"
    echo "============================================================"
    echo "Sistema anfitrión: ${PRETTY_NAME}"
    echo "IP privada EC2: ${PRIVATE_IP:-no detectada}"
    echo "IP pública EC2: ${PUBLIC_IP:-no detectada}"
    echo "Imagen: ${IMAGE}"
    echo "Digest: ${IMAGE_DIGEST:-no disponible}"
    echo "Contenedor: ${CONTAINER_NAME}"
    echo "Estado: ${CONTAINER_STATUS:-desconocido}"
    echo
    echo "Acceso web:"
    echo "  HTTP : http://${PUBLIC_IP:-IP_PUBLICA}/"
    echo "  HTTPS: https://${PUBLIC_IP:-IP_PUBLICA}/"
    echo
    echo "Mapeo web aplicado:"
    echo "  Host 80/TCP  -> contenedor 880/TCP"
    echo "  Host 443/TCP -> contenedor 4443/TCP"
    echo
    echo "Puertos requeridos en el Security Group:"
    echo "  22/TCP             SSH, solo desde tu IP pública"
    echo "  80/TCP             HTTP, 0.0.0.0/0"
    echo "  443/TCP            HTTPS, 0.0.0.0/0"
    echo "  5060/UDP           SIP, 0.0.0.0/0 para la demostración"
    echo "  10000-10100/UDP    RTP, 0.0.0.0/0 para la demostración"
    echo
    echo "Puertos publicados por Docker:"
    echo "${PORT_BINDINGS:-no disponibles}"
    echo
    echo "Archivos:"
    echo "  Compose: ${COMPOSE_FILE}"
    echo "  Log: ${LOG_FILE}"
    echo "  Resumen: ${SUMMARY_FILE}"
    echo
    echo "Comandos de verificación:"
    echo "  sudo docker ps"
    echo "  sudo docker port ${CONTAINER_NAME}"
    echo "  sudo docker logs --tail 150 ${CONTAINER_NAME}"
    echo "  sudo ss -lntup | grep -E ':(80|443|5060)\\b'"
    echo "  sudo docker exec ${CONTAINER_NAME} asterisk -rx 'pjsip show endpoints'"
    echo "  sudo docker exec ${CONTAINER_NAME} asterisk -rx 'core show channels verbose'"
    echo
    echo "NOTA:"
    echo "  Imagen comunitaria antigua; uso exclusivamente académico."
    echo "============================================================"
} | tee "$SUMMARY_FILE"

echo
echo "[VERIFICACIÓN] Contenedor:"
docker ps --filter "name=${CONTAINER_NAME}" \
    --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

echo
echo "[VERIFICACIÓN] Puertos publicados:"
docker port "$CONTAINER_NAME" || true

echo
echo "[VERIFICACIÓN] Puertos en escucha:"
ss -lntup | grep -E ':(80|443|5060)\b' || true

echo
echo "Instalación finalizada."
echo "Acceso HTTP : http://${PUBLIC_IP:-IP_PUBLICA}/"
echo "Acceso HTTPS: https://${PUBLIC_IP:-IP_PUBLICA}/"
echo "Resumen: ${SUMMARY_FILE}"
