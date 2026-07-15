#!/usr/bin/env bash
#
# install_asterisk_exam.sh
# Ubuntu 24.04 - Asterisk backend para examen CUY5132
#
# Arquitectura:
#   Softphone -- TLS/SRTP --> Kamailio + RTPEngine -- UDP/RTP --> Asterisk
#
# Incluye:
#   - Asterisk desde repositorios de Ubuntu 24.04
#   - Extensiones 1001, 1002, 2003 y 2004
#   - Echo test 100, 9999 y *60
#   - AGI de confirmacion de citas en 7000
#   - SQLite con datos ficticios
#   - AMI preparado para integrar n8n posteriormente
#
# Uso:
#   sudo bash install_asterisk_exam.sh
#

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/install_asterisk_exam.log"
SUMMARY_FILE="/root/ASTERISK_EXAM_RESUMEN.txt"

exec > >(tee -a "$LOG_FILE") 2>&1

on_error() {
    local rc=$?
    echo
    echo "============================================================"
    echo "ERROR EN install_asterisk_exam.sh"
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

is_cidr() {
    local value="$1"
    local ip="${value%/*}"
    local prefix="${value#*/}"
    is_ipv4 "$ip" || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    (( prefix >= 0 && prefix <= 32 ))
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

prompt_cidr() {
    local message="$1"
    local default_value="$2"
    local value=""
    while true; do
        read -r -p "$message [$default_value]: " value
        value="${value:-$default_value}"
        if is_cidr "$value"; then
            printf '%s' "$value"
            return
        fi
        echo "CIDR invalido. Ejemplo: 172.31.0.0/16" >&2
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
DEFAULT_LOCAL_NET="$(awk -F. '{printf "%s.%s.0.0/16",$1,$2}' <<< "$DETECTED_PRIVATE_IP")"

echo "============================================================"
echo "ASTERISK PARA EXAMEN - CONFIGURACION"
echo "============================================================"
echo "Asterisk quedara privado detras de Kamailio."
echo

ASTERISK_PRIVATE_IP="$(prompt_ipv4 "IP privada de esta VM Asterisk" "$DETECTED_PRIVATE_IP")"
KAMAILIO_PRIVATE_IP="$(prompt_ipv4 "IP privada de la VM Kamailio")"
LOCAL_NET="$(prompt_cidr "Red privada/VPC" "$DEFAULT_LOCAL_NET")"

echo
echo "Configuracion:"
echo "  Asterisk privada : $ASTERISK_PRIVATE_IP"
echo "  Kamailio privada : $KAMAILIO_PRIVATE_IP"
echo "  Red privada/VPC  : $LOCAL_NET"
echo

wait_for_apt
apt-get update -y
wait_for_apt
apt-get upgrade -y
wait_for_apt
apt-get install -y \
    asterisk \
    asterisk-core-sounds-en-gsm \
    asterisk-core-sounds-es-gsm \
    curl \
    ca-certificates \
    vim \
    git \
    python3 \
    sqlite3 \
    espeak-ng \
    sox \
    sngrep \
    tcpdump \
    netcat-openbsd \
    iproute2

systemctl stop asterisk || true

BACKUP_DIR="/etc/asterisk/backup-exam-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
for file in pjsip.conf extensions.conf rtp.conf acl.conf manager.conf; do
    cp -a "/etc/asterisk/$file" "$BACKUP_DIR/" 2>/dev/null || true
done

cat > /etc/asterisk/acl.conf <<EOF
[kamailio_only]
deny=0.0.0.0/0.0.0.0
permit=${KAMAILIO_PRIVATE_IP}/255.255.255.255
EOF

cat > /etc/asterisk/pjsip.conf <<EOF
;
; Asterisk backend privado para Kamailio.
;

[global]
type=global
user_agent=CUY5132-Asterisk
endpoint_identifier_order=auth_username,username,ip

[transport-udp]
type=transport
protocol=udp
bind=${ASTERISK_PRIVATE_IP}:5060
local_net=${LOCAL_NET}
allow_reload=no

[endpoint_template](!)
type=endpoint
transport=transport-udp
context=internal
disallow=all
allow=ulaw
allow=alaw
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=no
identify_by=auth_username,username
acl=kamailio_only
dtmf_mode=rfc4733
timers=yes

[auth_template](!)
type=auth
auth_type=userpass
realm=voip.local

[aor_template](!)
type=aor
max_contacts=1
remove_existing=yes
remove_unavailable=yes
support_path=yes
qualify_frequency=0

[1001](endpoint_template)
auth=auth1001
aors=1001

[auth1001](auth_template)
username=1001
password=pass1001

[1001](aor_template)

[1002](endpoint_template)
auth=auth1002
aors=1002

[auth1002](auth_template)
username=1002
password=pass1002

[1002](aor_template)

[2003](endpoint_template)
auth=auth2003
aors=2003

[auth2003](auth_template)
username=2003
password=pass2003

[2003](aor_template)

[2004](endpoint_template)
auth=auth2004
aors=2004

[auth2004](auth_template)
username=2004
password=pass2004

[2004](aor_template)
EOF

cat > /etc/asterisk/extensions.conf <<'EOF'
[general]
static=yes
writeprotect=no
clearglobalvars=no

[globals]

[internal]
exten => 100,1,NoOp(Echo test)
 same => n,Answer()
 same => n,Playback(demo-echotest)
 same => n,Echo()
 same => n,Hangup()

exten => 9999,1,Goto(100,1)
exten => *60,1,Goto(100,1)

exten => _[12]XXX,1,NoOp(Llamada ${CALLERID(num)} hacia ${EXTEN})
 same => n,Dial(PJSIP/${EXTEN},35)
 same => n,Hangup()

; El AGI usa el numero de la extension que origina la llamada.
exten => 7000,1,NoOp(Confirmacion de cita para ${CALLERID(num)})
 same => n,Answer()
 same => n,Wait(1)
 same => n,AGI(confirmar_cita.py,${CALLERID(num)})
 same => n,Hangup()
EOF

cat > /etc/asterisk/rtp.conf <<'EOF'
[general]
rtpstart=10000
rtpend=20000
rtpchecksums=no
strictrtp=yes
icesupport=no
EOF

AMI_SECRET="$(openssl rand -hex 18)"
cat > /etc/asterisk/manager.conf <<EOF
[general]
enabled=yes
webenabled=no
port=5038
bindaddr=${ASTERISK_PRIVATE_IP}
displayconnects=yes
timestampevents=yes

[n8n]
secret=${AMI_SECRET}
deny=0.0.0.0/0.0.0.0
permit=${LOCAL_NET}
read=system,call,log,verbose,command,agent,user,config,reporting,cdr,dialplan
write=system,call,command,agent,user,config,originate,reporting
EOF

AGI_DIR="/var/lib/asterisk/agi-bin"
SOUNDS_DIR="/var/lib/asterisk/sounds/custom"
DB_FILE="${AGI_DIR}/citas.db"
AGI_LOG="/var/log/asterisk/confirmar_cita.log"
WEBHOOK_FILE="/etc/asterisk/n8n_webhook_url"

mkdir -p "$AGI_DIR" "$SOUNDS_DIR"
touch "$AGI_LOG" "$WEBHOOK_FILE"

sqlite3 "$DB_FILE" <<'SQL'
CREATE TABLE IF NOT EXISTS citas (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    extension TEXT UNIQUE NOT NULL,
    paciente TEXT NOT NULL,
    especialidad TEXT NOT NULL,
    fecha TEXT NOT NULL,
    hora TEXT NOT NULL,
    estado TEXT NOT NULL DEFAULT 'pendiente',
    respuesta_dtmf TEXT,
    actualizado_en TEXT
);

INSERT INTO citas(extension,paciente,especialidad,fecha,hora,estado)
VALUES
 ('1001','Camila Perez','Cardiologia','2026-07-20','10:30','pendiente'),
 ('1002','Daniel Soto','Traumatologia','2026-07-20','12:00','pendiente'),
 ('2003','Andrea Rojas','Medicina General','2026-07-21','09:15','pendiente'),
 ('2004','Felipe Munoz','Kinesiologia','2026-07-21','11:45','pendiente')
ON CONFLICT(extension) DO UPDATE SET
 paciente=excluded.paciente,
 especialidad=excluded.especialidad,
 fecha=excluded.fecha,
 hora=excluded.hora;
SQL

cat > /usr/local/sbin/regenerar_audios_citas.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

DB="/var/lib/asterisk/agi-bin/citas.db"
OUT="/var/lib/asterisk/sounds/custom"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUT"

sqlite3 -separator '|' "$DB" \
  "SELECT extension,paciente,especialidad,fecha,hora FROM citas ORDER BY extension;" |
while IFS='|' read -r ext paciente especialidad fecha hora; do
    texto="Hola ${paciente}. Tiene una cita de ${especialidad}, el dia ${fecha}, a las ${hora}."
    espeak-ng -v es -s 145 -w "${TMP}/cita-${ext}.wav" "$texto"
    sox "${TMP}/cita-${ext}.wav" -r 8000 -c 1 -e signed-integer -b 16 \
        "${OUT}/cita-${ext}.wav"
done

espeak-ng -v es -s 145 -w "${TMP}/menu.wav" \
  "Presione uno para confirmar, dos para cancelar, o tres para solicitar reagendamiento."
sox "${TMP}/menu.wav" -r 8000 -c 1 -e signed-integer -b 16 "${OUT}/menu-cita.wav"

espeak-ng -v es -s 145 -w "${TMP}/confirmada.wav" "Su cita fue confirmada."
sox "${TMP}/confirmada.wav" -r 8000 -c 1 -e signed-integer -b 16 "${OUT}/cita-confirmada.wav"

espeak-ng -v es -s 145 -w "${TMP}/cancelada.wav" "Su cita fue cancelada."
sox "${TMP}/cancelada.wav" -r 8000 -c 1 -e signed-integer -b 16 "${OUT}/cita-cancelada.wav"

espeak-ng -v es -s 145 -w "${TMP}/reagendar.wav" \
  "Su solicitud de reagendamiento fue registrada."
sox "${TMP}/reagendar.wav" -r 8000 -c 1 -e signed-integer -b 16 "${OUT}/cita-reagendar.wav"

espeak-ng -v es -s 145 -w "${TMP}/invalida.wav" "La opcion ingresada no es valida."
sox "${TMP}/invalida.wav" -r 8000 -c 1 -e signed-integer -b 16 "${OUT}/cita-invalida.wav"

chown -R asterisk:asterisk "$OUT"
find "$OUT" -type f -name '*.wav' -exec chmod 644 {} +
EOF
chmod 750 /usr/local/sbin/regenerar_audios_citas.sh

cat > "${AGI_DIR}/confirmar_cita.py" <<'PY'
#!/usr/bin/env python3

import json
import logging
import re
import sqlite3
import sys
import urllib.request
from datetime import datetime
from pathlib import Path

DB = Path("/var/lib/asterisk/agi-bin/citas.db")
LOG = Path("/var/log/asterisk/confirmar_cita.log")
WEBHOOK = Path("/etc/asterisk/n8n_webhook_url")

logging.basicConfig(
    filename=str(LOG),
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)

def agi_environment():
    env = {}
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        line = line.rstrip("\r\n")
        if not line:
            break
        if ":" in line:
            key, value = line.split(":", 1)
            env[key.strip()] = value.strip()
    return env

def command(value):
    print(value, flush=True)
    response = sys.stdin.readline().strip()
    logging.info("AGI cmd=%s response=%s", value, response)
    return response

def result_value(response):
    match = re.search(r"result=(-?\d+)", response)
    return int(match.group(1)) if match else -1

def stream(name):
    command(f'STREAM FILE {name} ""')

def notify(payload):
    try:
        url = WEBHOOK.read_text(encoding="utf-8").strip()
    except OSError:
        return
    if not url:
        return
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            logging.info("Webhook n8n status=%s", response.status)
    except Exception as exc:
        logging.warning("Webhook n8n fallo: %s", exc)

def main():
    env = agi_environment()
    extension = sys.argv[1] if len(sys.argv) > 1 else env.get("agi_callerid", "")
    extension = re.sub(r"\D", "", extension)

    command("ANSWER")

    with sqlite3.connect(DB) as con:
        con.row_factory = sqlite3.Row
        cita = con.execute(
            "SELECT * FROM citas WHERE extension=?",
            (extension,),
        ).fetchone()

        if not cita:
            logging.warning("No existe cita para extension=%s", extension)
            stream("custom/cita-invalida")
            return

        stream(f"custom/cita-{extension}")
        response = command('GET DATA custom/menu-cita 12000 1')
        digit = str(result_value(response))

        states = {
            "1": ("confirmada", "custom/cita-confirmada"),
            "2": ("cancelada", "custom/cita-cancelada"),
            "3": ("reagendar", "custom/cita-reagendar"),
        }

        if digit not in states:
            logging.warning("DTMF invalido extension=%s digit=%s", extension, digit)
            stream("custom/cita-invalida")
            state = "sin_respuesta"
        else:
            state, audio = states[digit]
            stream(audio)

        updated = datetime.now().isoformat(timespec="seconds")
        con.execute(
            """
            UPDATE citas
               SET estado=?, respuesta_dtmf=?, actualizado_en=?
             WHERE extension=?
            """,
            (state, digit, updated, extension),
        )
        con.commit()

        payload = {
            "extension": extension,
            "paciente": cita["paciente"],
            "especialidad": cita["especialidad"],
            "fecha": cita["fecha"],
            "hora": cita["hora"],
            "estado": state,
            "respuesta_dtmf": digit,
            "actualizado_en": updated,
        }
        logging.info("Resultado cita=%s", payload)
        notify(payload)

if __name__ == "__main__":
    try:
        main()
    except Exception:
        logging.exception("Fallo no controlado en AGI")
        try:
            stream("custom/cita-invalida")
        except Exception:
            pass
        sys.exit(1)
PY

chmod 750 "${AGI_DIR}/confirmar_cita.py"
chown asterisk:asterisk \
    "$DB_FILE" \
    "$AGI_LOG" \
    "$WEBHOOK_FILE" \
    "${AGI_DIR}/confirmar_cita.py"

chmod 660 "$DB_FILE" "$AGI_LOG"
chmod 640 "$WEBHOOK_FILE"

/usr/local/sbin/regenerar_audios_citas.sh

chown root:asterisk \
    /etc/asterisk/pjsip.conf \
    /etc/asterisk/extensions.conf \
    /etc/asterisk/rtp.conf \
    /etc/asterisk/acl.conf \
    /etc/asterisk/manager.conf

chmod 640 \
    /etc/asterisk/pjsip.conf \
    /etc/asterisk/extensions.conf \
    /etc/asterisk/rtp.conf \
    /etc/asterisk/acl.conf \
    /etc/asterisk/manager.conf

systemctl enable asterisk
systemctl restart asterisk
sleep 5

if ! systemctl is-active --quiet asterisk; then
    echo "ERROR: Asterisk no inicio."
    journalctl -u asterisk -n 120 --no-pager
    exit 1
fi

ASTERISK_VERSION="$(asterisk -V 2>/dev/null || true)"
ENDPOINTS="$(asterisk -rx "pjsip show endpoints" 2>/dev/null || true)"
TRANSPORTS="$(asterisk -rx "pjsip show transports" 2>/dev/null || true)"
DIALPLAN="$(asterisk -rx "dialplan show internal" 2>/dev/null || true)"
LISTENERS="$(ss -tulnp | grep -E ':(5060|5038)\b' || true)"

{
    echo "============================================================"
    echo "RESUMEN ASTERISK - EXAMEN"
    echo "============================================================"
    echo "Version              : $ASTERISK_VERSION"
    echo "IP privada Asterisk  : $ASTERISK_PRIVATE_IP"
    echo "IP privada Kamailio  : $KAMAILIO_PRIVATE_IP"
    echo "Red privada/VPC      : $LOCAL_NET"
    echo
    echo "Extensiones:"
    echo "  1001 / pass1001"
    echo "  1002 / pass1002"
    echo "  2003 / pass2003"
    echo "  2004 / pass2004"
    echo
    echo "Pruebas:"
    echo "  100, 9999 y *60 = echo"
    echo "  7000 = AGI confirmacion de cita segun CallerID"
    echo
    echo "Base de citas:"
    echo "  $DB_FILE"
    echo "  Ver: sqlite3 $DB_FILE 'SELECT * FROM citas;'"
    echo
    echo "Integracion n8n:"
    echo "  AMI usuario : n8n"
    echo "  AMI secreto : $AMI_SECRET"
    echo "  AMI puerto  : 5038/TCP"
    echo "  Webhook AGI : escribir URL en $WEBHOOK_FILE"
    echo
    echo "IMPORTANTE:"
    echo "  En AWS, 5060/UDP y 10000-20000/UDP solo desde SG-Kamailio."
    echo "  Cuando exista n8n, abrir 5038/TCP solo desde SG-n8n."
    echo
    echo "---- LISTENERS ----"
    echo "$LISTENERS"
    echo
    echo "---- TRANSPORTS ----"
    echo "$TRANSPORTS"
    echo
    echo "---- ENDPOINTS ----"
    echo "$ENDPOINTS"
    echo
    echo "---- DIALPLAN ----"
    echo "$DIALPLAN"
    echo "============================================================"
} | tee "$SUMMARY_FILE"

echo
echo "[OK] Asterisk instalado y preparado para Kamailio y n8n."
echo "Resumen: $SUMMARY_FILE"
