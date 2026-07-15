#!/usr/bin/env bash
#
# install_kamailio_exam.sh
# Ubuntu 24.04 - Kamailio + RTPEngine + TLS/SRTP
#
# Arquitectura:
#   Softphone -- TLS:5061 + SRTP/SDES --> Kamailio + RTPEngine
#   Kamailio  -- UDP:5060 + RTP ------> Asterisk privado
#
# Uso:
#   sudo bash install_kamailio_exam.sh
#

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/install_kamailio_exam.log"
SUMMARY_FILE="/root/KAMAILIO_EXAM_RESUMEN.txt"

exec > >(tee -a "$LOG_FILE") 2>&1

on_error() {
    local rc=$?
    echo
    echo "============================================================"
    echo "ERROR EN install_kamailio_exam.sh"
    echo "Linea: ${1:-desconocida}"
    echo "Codigo: $rc"
    echo "Log: $LOG_FILE"
    echo "============================================================"
    exit "$rc"
}
trap 'on_error $LINENO' ERR

is_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=.
    local a b c d
    read -r a b c d <<< "$ip"
    for octet in "$a" "$b" "$c" "$d"; do
        (( octet >= 0 && octet <= 255 )) || return 1
    done
}

prompt_ipv4() {
    local message="$1"
    local default_value="${2:-}"
    local value=""
    while true; do
        if [[ -n "$default_value" ]]; then
            read -r -p "$message [$default_value]: " value
            value="${value:-$default_value}"
        else
            read -r -p "$message: " value
        fi
        if is_ipv4 "$value"; then
            printf '%s' "$value"
            return
        fi
        echo "IPv4 invalida. Ejemplo: 172.31.10.25" >&2
    done
}

wait_for_apt() {
    local retries=72
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        echo "[INFO] Esperando que cloud-init/APT libere sus bloqueos..."
        sleep 5
        retries=$((retries - 1))
        if (( retries <= 0 )); then
            echo "ERROR: tiempo agotado esperando APT."
            exit 1
        fi
    done
}

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: ejecuta el script con sudo."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    echo "ERROR: este script esta preparado para Ubuntu 24.04."
    echo "Sistema detectado: ${PRETTY_NAME:-desconocido}"
    exit 1
fi

DETECTED_PRIVATE_IP="$(hostname -I | awk '{print $1}')"
DETECTED_PUBLIC_IP="$(curl -4 -fsS https://checkip.amazonaws.com 2>/dev/null | tr -d '\n' || true)"
if ! is_ipv4 "${DETECTED_PUBLIC_IP:-}"; then
    DETECTED_PUBLIC_IP="$(curl -4 -fsS https://api.ipify.org 2>/dev/null || true)"
fi

echo "============================================================"
echo "KAMAILIO PARA EXAMEN - CONFIGURACION"
echo "============================================================"
echo "Si AWS cambia la IP publica, vuelve a ejecutar este script."
echo

KAMAILIO_PRIVATE_IP="$(prompt_ipv4 "IP privada de esta VM Kamailio" "$DETECTED_PRIVATE_IP")"
KAMAILIO_PUBLIC_IP="$(prompt_ipv4 "IP publica actual de esta VM Kamailio" "${DETECTED_PUBLIC_IP:-}")"
ASTERISK_PRIVATE_IP="$(prompt_ipv4 "IP privada de la VM Asterisk")"

echo
echo "Configuracion:"
echo "  Kamailio privada : $KAMAILIO_PRIVATE_IP"
echo "  Kamailio publica : $KAMAILIO_PUBLIC_IP"
echo "  Asterisk privada : $ASTERISK_PRIVATE_IP"
echo

wait_for_apt
apt-get update -y
wait_for_apt
apt-get install -y software-properties-common
add-apt-repository -y universe
wait_for_apt
apt-get update -y
wait_for_apt
apt-get upgrade -y
wait_for_apt
apt-get install -y \
    kamailio \
    kamailio-extra-modules \
    kamailio-tls-modules \
    kamailio-outbound-modules \
    rtpengine-daemon \
    rtpengine-utils \
    openssl \
    curl \
    ca-certificates \
    vim \
    git \
    sngrep \
    tcpdump \
    netcat-openbsd \
    iproute2 \
    rsyslog

systemctl stop kamailio 2>/dev/null || true
systemctl stop rtpengine 2>/dev/null || true

BACKUP_DIR="/etc/kamailio/backup-exam-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a /etc/kamailio/kamailio.cfg "$BACKUP_DIR/" 2>/dev/null || true
cp -a /etc/kamailio/tls.cfg "$BACKUP_DIR/" 2>/dev/null || true
cp -a /etc/rtpengine/rtpengine.conf "$BACKUP_DIR/" 2>/dev/null || true

mkdir -p /etc/kamailio/certs

CERT_CONFIG="$(mktemp)"
cat > "$CERT_CONFIG" <<EOF
[req]
distinguished_name=req_dn
x509_extensions=v3_req
prompt=no

[req_dn]
C=CL
ST=RM
L=Santiago
O=DUOC-UC
OU=CUY5132
CN=${KAMAILIO_PUBLIC_IP}

[v3_req]
subjectAltName=@alt_names
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth

[alt_names]
IP.1=${KAMAILIO_PUBLIC_IP}
EOF

openssl req -new -x509 -nodes \
    -newkey rsa:2048 \
    -sha256 \
    -days 365 \
    -keyout /etc/kamailio/certs/kamailio-key.pem \
    -out /etc/kamailio/certs/kamailio-cert.pem \
    -config "$CERT_CONFIG"

rm -f "$CERT_CONFIG"

chown kamailio:kamailio \
    /etc/kamailio/certs/kamailio-key.pem \
    /etc/kamailio/certs/kamailio-cert.pem
chmod 640 /etc/kamailio/certs/kamailio-key.pem
chmod 644 /etc/kamailio/certs/kamailio-cert.pem

cat > /etc/kamailio/tls.cfg <<'EOF'
[server:default]
method = TLSv1.2+
verify_certificate = no
require_certificate = no
private_key = /etc/kamailio/certs/kamailio-key.pem
certificate = /etc/kamailio/certs/kamailio-cert.pem
ca_list = /etc/kamailio/certs/kamailio-cert.pem
EOF

chown root:kamailio /etc/kamailio/tls.cfg
chmod 640 /etc/kamailio/tls.cfg

mkdir -p /etc/rtpengine
cat > /etc/rtpengine/rtpengine.conf <<EOF
[rtpengine]
table = -1
interface = priv/${KAMAILIO_PRIVATE_IP};pub/${KAMAILIO_PRIVATE_IP}!${KAMAILIO_PUBLIC_IP}
listen-ng = 127.0.0.1:22222
port-min = 10000
port-max = 20000
log-level = 6
log-facility = daemon
timeout = 60
silent-timeout = 30
max-sessions = 1000
EOF

cat > /etc/kamailio/kamailio.cfg <<EOF
#!KAMAILIO
#
# Kamailio SBC para examen:
# - TLS/SRTP publico
# - UDP/RTP privado hacia Asterisk
#

debug=2
log_stderror=no
log_facility=LOG_LOCAL0
fork=yes
children=4

enable_tls=yes
tcp_connection_lifetime=3700
tcp_accept_no_cl=yes
auto_aliases=no
server_signature=no

listen=tls:${KAMAILIO_PRIVATE_IP}:5061 advertise ${KAMAILIO_PUBLIC_IP}:5061
listen=udp:${KAMAILIO_PRIVATE_IP}:5060

#!define ASTERISK_IP "${ASTERISK_PRIVATE_IP}"

loadmodule "tm.so"
loadmodule "sl.so"
loadmodule "rr.so"
loadmodule "pv.so"
loadmodule "maxfwd.so"
loadmodule "textops.so"
loadmodule "siputils.so"
loadmodule "xlog.so"
loadmodule "sanity.so"
loadmodule "ctl.so"
loadmodule "kex.so"
loadmodule "nathelper.so"
loadmodule "rtpengine.so"
loadmodule "tls.so"
loadmodule "outbound.so"
loadmodule "path.so"

modparam("ctl", "binrpc", "unix:/run/kamailio/kamailio_ctl")
modparam("rr", "enable_full_lr", 1)
modparam("rr", "append_fromtag", 1)
modparam("nathelper", "natping_interval", 30)
modparam("nathelper", "ping_nated_only", 0)
modparam("rtpengine", "rtpengine_sock", "udp:127.0.0.1:22222")
modparam("tls", "config", "/etc/kamailio/tls.cfg")
modparam("path", "use_received", 1)
modparam("path", "received_format", 0)

request_route {
    xlog("L_INFO", "[\$rm] \$fu -> \$ru src=\$si:\$sp proto=\$proto\n");

    if (!mf_process_maxfwd_header("20")) {
        sl_send_reply("483", "Too Many Hops");
        exit;
    }

    if (!sanity_check("1511", "7")) {
        sl_send_reply("400", "Bad Request");
        exit;
    }

    force_rport();

    if (is_method("CANCEL")) {
        if (t_check_trans()) {
            rtpengine_delete();
            t_relay();
        }
        exit;
    }

    # Trafico dentro de dialogo.
    if (has_totag()) {
        if (!loose_route()) {
            if (is_method("ACK") && t_check_trans()) {
                t_relay();
            } else if (!is_method("ACK")) {
                sl_send_reply("404", "Not here");
            }
            exit;
        }

        handle_ruri_alias();

        if (is_method("BYE")) {
            rtpengine_delete();
        } else if (has_body("application/sdp")) {
            if (\$si == ASTERISK_IP) {
                rtpengine_manage("direction=priv direction=pub RTP/SAVP replace-origin replace-session-connection ICE=remove");
            } else {
                rtpengine_manage("direction=pub direction=priv RTP/AVP replace-origin replace-session-connection ICE=remove");
            }
        }

        if (!t_relay()) {
            sl_reply_error();
        }
        exit;
    }

    # Los registros externos deben usar TLS.
    if (is_method("REGISTER")) {
        if (\$proto != "tls") {
            sl_send_reply("403", "TLS Required");
            exit;
        }

        set_contact_alias();

        if (!add_path_received()) {
            sl_send_reply("500", "Path Error");
            exit;
        }

        \$du = "sip:" + ASTERISK_IP + ":5060;transport=udp";
        if (!t_relay()) {
            sl_reply_error();
        }
        exit;
    }

    # INVITE originado por Asterisk: debe incluir Path/Route guardado.
    if (\$si == ASTERISK_IP && is_method("INVITE")) {
        if (!loose_route()) {
            sl_send_reply("480", "No Registered Path");
            exit;
        }

        handle_ruri_alias();
        record_route();

        if (has_body("application/sdp")) {
            rtpengine_offer("direction=priv direction=pub RTP/SAVP replace-origin replace-session-connection ICE=remove");
        }

        t_on_reply("REPLY_TO_ASTERISK");
        t_on_failure("FAIL_MEDIA");

        if (!t_relay()) {
            sl_reply_error();
        }
        exit;
    }

    if (is_method("OPTIONS") && \$rU == \$null) {
        sl_send_reply("200", "OK");
        exit;
    }

    # INVITE originado por softphone: TLS obligatorio.
    if (is_method("INVITE")) {
        if (\$proto != "tls") {
            sl_send_reply("403", "TLS Required");
            exit;
        }

        set_contact_alias();
        record_route();

        if (has_body("application/sdp")) {
            rtpengine_offer("direction=pub direction=priv RTP/AVP replace-origin replace-session-connection ICE=remove");
        }

        \$du = "sip:" + ASTERISK_IP + ":5060;transport=udp";
        t_on_reply("REPLY_TO_CLIENT");
        t_on_failure("FAIL_MEDIA");

        if (!t_relay()) {
            sl_reply_error();
        }
        exit;
    }

    if (is_method("ACK|BYE|UPDATE|INFO|MESSAGE|SUBSCRIBE|NOTIFY|OPTIONS")) {
        if (\$si != ASTERISK_IP && \$proto != "tls") {
            sl_send_reply("403", "TLS Required");
            exit;
        }
        if (\$si != ASTERISK_IP) {
            \$du = "sip:" + ASTERISK_IP + ":5060;transport=udp";
        }
        if (!t_relay()) {
            sl_reply_error();
        }
        exit;
    }

    sl_send_reply("405", "Method Not Allowed");
}

onreply_route[REPLY_TO_CLIENT] {
    # Respuesta de Asterisk hacia el softphone.
    if (status =~ "18[0-9]|2[0-9][0-9]") {
        if (has_body("application/sdp")) {
            rtpengine_answer("RTP/SAVP replace-origin replace-session-connection ICE=remove");
        }
    }
}

onreply_route[REPLY_TO_ASTERISK] {
    # Respuesta del softphone hacia Asterisk.
    set_contact_alias();
    if (status =~ "18[0-9]|2[0-9][0-9]") {
        if (has_body("application/sdp")) {
            rtpengine_answer("RTP/AVP replace-origin replace-session-connection ICE=remove");
        }
    }
}

failure_route[FAIL_MEDIA] {
    if (t_is_canceled()) {
        exit;
    }
    rtpengine_delete();
}
EOF

chown root:kamailio /etc/kamailio/kamailio.cfg
chmod 640 /etc/kamailio/kamailio.cfg

systemctl enable rtpengine
systemctl restart rtpengine
sleep 4

if ! systemctl is-active --quiet rtpengine; then
    echo "ERROR: RTPEngine no inicio."
    journalctl -u rtpengine -n 140 --no-pager
    exit 1
fi

kamailio -c -f /etc/kamailio/kamailio.cfg

systemctl enable kamailio
systemctl restart kamailio
sleep 5

if ! systemctl is-active --quiet kamailio; then
    echo "ERROR: Kamailio no inicio."
    journalctl -u kamailio -n 140 --no-pager
    exit 1
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow 22/tcp
    ufw allow 5061/tcp
    ufw allow 10000:20000/udp
    ufw allow from "$ASTERISK_PRIVATE_IP" to any port 5060 proto udp
fi

CERT_INFO="$(openssl x509 \
    -in /etc/kamailio/certs/kamailio-cert.pem \
    -noout -subject -ext subjectAltName 2>/dev/null || true)"

LISTENERS="$(ss -tulnp | grep -E ':(5060|5061|22222)\b' || true)"
KAMAILIO_VERSION="$(kamailio -v 2>&1 | head -1 || true)"
RTPENGINE_VERSION="$(rtpengine --version 2>&1 | head -1 || true)"

{
    echo "============================================================"
    echo "RESUMEN KAMAILIO - EXAMEN"
    echo "============================================================"
    echo "Kamailio            : $KAMAILIO_VERSION"
    echo "RTPEngine           : $RTPENGINE_VERSION"
    echo "IP privada Kamailio : $KAMAILIO_PRIVATE_IP"
    echo "IP publica Kamailio : $KAMAILIO_PUBLIC_IP"
    echo "IP privada Asterisk : $ASTERISK_PRIVATE_IP"
    echo
    echo "Softphones:"
    echo "  Servidor   : $KAMAILIO_PUBLIC_IP"
    echo "  Puerto     : 5061"
    echo "  Transporte : TLS"
    echo "  Media      : SRTP/SDES obligatorio"
    echo
    echo "Cuentas Asterisk:"
    echo "  1001 / pass1001"
    echo "  1002 / pass1002"
    echo "  2003 / pass2003"
    echo "  2004 / pass2004"
    echo
    echo "Certificado:"
    echo "$CERT_INFO"
    echo
    echo "IMPORTANTE:"
    echo "  El certificado es autofirmado."
    echo "  Importalo en el softphone o desactiva solo la validacion del certificado."
    echo "  No desactives TLS ni SRTP."
    echo "  Si cambia la IP publica AWS, vuelve a ejecutar este script."
    echo
    echo "---- LISTENERS ----"
    echo "$LISTENERS"
    echo
    echo "Comandos:"
    echo "  sudo journalctl -u kamailio -f"
    echo "  sudo journalctl -u rtpengine -f"
    echo "  sudo sngrep -d any"
    echo "  sudo tcpdump -i any -n 'port 5061 or portrange 10000-20000'"
    echo "============================================================"
} | tee "$SUMMARY_FILE"

echo
echo "[OK] Kamailio, TLS y RTPEngine instalados."
echo "Resumen: $SUMMARY_FILE"
