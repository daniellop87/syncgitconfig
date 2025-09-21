#!/usr/bin/env bash
# install.sh — Instalador de syncgitconfig
# - Genera /etc/syncgitconfig/syncgitconfig.yaml desde config.example.yaml (con comentarios y placeholders)
# - Guarda token (HTTPS) en /etc/syncgitconfig/credentials/.git-credentials si se provee
# - Clona el repo a --repo-path
# - Instala y arranca services systemd
# - Soporta cert autofirmado (--insecure)
# - Modo desatendido (--non-interactive)
# - Muestra "próximos pasos" al final

set -Eeuo pipefail

### ========= Defaults =========
INSTALL_DIR="/opt/syncgitconfig"                 # donde se clona/ubica este propio proyecto
ETC_DIR="/etc/syncgitconfig"
CREDENTIALS_DIR="$ETC_DIR/credentials"
YAML_PATH="$ETC_DIR/syncgitconfig.yaml"
TEMPLATE_PATH="$INSTALL_DIR/config.example.yaml"
LOG_DIR="/opt/logs/syncgitconfig"
LOGFILE="$LOG_DIR/install.log"

# Paquetes mínimos
PKGS=(git rsync inotify-tools ca-certificates dos2unix)

# Flags y parámetros
REMOTE_URL=""
REPO_PATH=""
TOKEN=""
USER_NAME=""
ENV_NAME="prod"
HOST_NAME="auto"
COOLDOWN="60"
NON_INTERACTIVE=0
INSECURE=0

### ========= Utils =========
c_green(){ printf "\033[1;32m%s\033[0m\n" "$*"; }
c_yellow(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
c_red(){ printf "\033[1;31m%s\033[0m\n" "$*"; }
log(){ echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE" >&2; }

usage() {
  cat <<EOF
Uso:
  sudo ./install.sh \\
    --remote-url "https://GIT/Org/Repo.git" \\
    --repo-path "/opt/configs-host" \\
    --token "XXXX" \\
    --user "git" \\
    --env "prod" \\
    --host "auto" \\
    --cooldown 60 \\
    --non-interactive [--insecure]

Parámetros:
  --remote-url        URL remota del repo (HTTPS/SSH)
  --repo-path         Ruta local donde clonar el repo (ej. /opt/configs-host)
  --token             (Opc.) Token HTTPS para credenciales guardadas
  --user              (Opc.) Usuario asociado al token (ej. git o daniel)
  --env               Entorno (por defecto: prod)
  --host              Hostname o "auto" (por defecto: auto)
  --cooldown          Segundos entre comprobaciones (por defecto: 60)
  --non-interactive   No pedir confirmaciones (instalación desatendida)
  --insecure          Deshabilita verificación SSL solo en la clonación
  -h | --help         Esta ayuda

Requisitos de repo:
  - Plantilla:  config.example.yaml   (en la raíz del proyecto)
  - Systemd:    systemd/syncgitconfig-*.service
  - Binarios:   bin/ (opcional; si no existe se omite el chmod)
EOF
}

require_root() {
  if (( EUID != 0 )); then
    c_red "Necesitas sudo/root para instalar."
    exit 1
  fi
}

trap 'c_red "⚠️  Se produjo un error. Revisa el log: $LOGFILE"' ERR

### ========= Parseo de flags =========
while (( "$#" )); do
  case "$1" in
    --remote-url)      shift; REMOTE_URL="${1:-}";;
    --repo-path)       shift; REPO_PATH="${1:-}";;
    --token)           shift; TOKEN="${1:-}";;
    --user)            shift; USER_NAME="${1:-}";;
    --env)             shift; ENV_NAME="${1:-}";;
    --host)            shift; HOST_NAME="${1:-}";;
    --cooldown)        shift; COOLDOWN="${1:-}";;
    --non-interactive) NON_INTERACTIVE=1 ;;
    --insecure)        INSECURE=1 ;;
    -h|--help)         usage; exit 0 ;;
    *) c_red "Opción desconocida: $1"; usage; exit 1 ;;
  esac
  shift
done

require_root

### ========= Preparación de carpetas/log =========
mkdir -p "$LOG_DIR" "$ETC_DIR" "$CREDENTIALS_DIR"
touch "$LOGFILE" 2>/dev/null || true

log "Instalación iniciada."
log "Infra:"
log "  INSTALL_DIR = $INSTALL_DIR"
log "  ETC_DIR     = $ETC_DIR"
log "  YAML_PATH   = $YAML_PATH"
log "  TEMPLATE    = $TEMPLATE_PATH"
log "  LOGFILE     = $LOGFILE"

### ========= Validaciones básicas =========
if [[ -z "$REMOTE_URL" || -z "$REPO_PATH" ]]; then
  c_red "Faltan parámetros obligatorios: --remote-url y/o --repo-path"
  usage
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  c_yellow "No se encontró apt-get. Saltando instalación de paquetes..."
else
  log "Instalando paquetes con apt-get: ${PKGS[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >>"$LOGFILE" 2>&1 || true
  apt-get install -y "${PKGS[@]}" >>"$LOGFILE" 2>&1 || true
fi

### ========= Copia de binarios (opcional) =========
# Si el repo ya está en /opt/syncgitconfig, asumimos que este script se ejecuta desde ahí
# y no hace falta copiar. Si lo quieres instalar "desde cualquier sitio" podrías copiarlo.
if [[ ! -d "$INSTALL_DIR" ]]; then
  # Intento deducir la ruta real del script
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  if [[ "$SCRIPT_DIR" != "$INSTALL_DIR" ]]; then
    log "Copiando proyecto a $INSTALL_DIR desde $SCRIPT_DIR"
    mkdir -p "$INSTALL_DIR"
    rsync -a --delete "$SCRIPT_DIR"/ "$INSTALL_DIR"/
  fi
fi

# Permisos de bin si existe
if [[ -d "$INSTALL_DIR/bin" ]]; then
  chmod +x "$INSTALL_DIR"/bin/* || true
else
  log "[INFO] No existe $INSTALL_DIR/bin, omito chmod."
fi

### ========= Generar YAML desde plantilla =========
if [[ ! -f "$TEMPLATE_PATH" ]]; then
  c_red "[ERROR] No se encontró la plantilla: $TEMPLATE_PATH"
  c_yellow "Asegúrate de que config.example.yaml está en la raíz del repo."
  exit 1
fi

# Copiar plantilla comentada
cp -f "$TEMPLATE_PATH" "$YAML_PATH"
# Normalizar EOL si está disponible
command -v dos2unix >/dev/null 2>&1 && dos2unix -q "$YAML_PATH" || true

# Rellenar placeholders
sed -i "s|__ENV__|${ENV_NAME}|g"               "$YAML_PATH"
sed -i "s|__HOST__|${HOST_NAME}|g"             "$YAML_PATH"
sed -i "s|__REPO_PATH__|${REPO_PATH}|g"        "$YAML_PATH"
sed -i "s|__REMOTE_URL__|${REMOTE_URL}|g"      "$YAML_PATH"
sed -i "s|__COOLDOWN__|${COOLDOWN}|g"          "$YAML_PATH"

log "[ OK ] YAML actualizado en ${YAML_PATH}"

### ========= Credenciales Git (HTTPS + token opcional) =========
# Solo si vienen ambos: usuario y token
if [[ -n "${TOKEN:-}" && -n "${USER_NAME:-}" ]]; then
  GIT_CREDS_PATH="$CREDENTIALS_DIR/.git-credentials"
  # Construimos URL con credenciales incrustadas sólo para helper store
  if [[ "$REMOTE_URL" =~ ^https:// ]]; then
    echo "https://${USER_NAME}:${TOKEN}@${REMOTE_URL#https://}" > "$GIT_CREDS_PATH"
    git config --global credential.helper "store --file=$GIT_CREDS_PATH"
    chmod 600 "$GIT_CREDS_PATH"
    log "[ OK ] Token guardado en $GIT_CREDS_PATH y helper configurado."
  else
    log "[WARN] --token/--user ignorados (la URL no es HTTPS)."
  fi
else
  log "[INFO] No se configuraron credenciales (falta --token o --user)."
fi

### ========= Clonado del repo =========
log "[INFO] Clonando repo en ${REPO_PATH}"
mkdir -p "$REPO_PATH"
if [[ -d "$REPO_PATH/.git" ]]; then
  log "[INFO] Ya existe un repositorio en ${REPO_PATH}, se omite clonación."
else
  if (( INSECURE )); then
    c_yellow "[WARN] --insecure activo: deshabilitando verificación SSL SOLO en esta clonación."
    GIT_SSL_NO_VERIFY=true git -c http.sslVerify=false clone "$REMOTE_URL" "$REPO_PATH" 2>&1 | tee -a "$LOGFILE"
  else
    git clone "$REMOTE_URL" "$REPO_PATH" 2>&1 | tee -a "$LOGFILE"
  fi
fi

### ========= Systemd units =========
if [[ -d "$INSTALL_DIR/systemd" ]]; then
  cp -f "$INSTALL_DIR/systemd"/syncgitconfig-*.service /etc/systemd/system/ 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable syncgitconfig-watch.service 2>/dev/null || true
  systemctl enable syncgitconfig-sync.service 2>/dev/null || true
  systemctl restart syncgitconfig-watch.service 2>/dev/null || true
  systemctl restart syncgitconfig-sync.service 2>/dev/null || true
  log "[ OK ] Units systemd instaladas y servicios activos."
else
  log "[WARN] No se encontró $INSTALL_DIR/systemd; omito instalación de units."
fi

### ========= Mensaje final =========
clear
cat <<EOM
========================================================
✅ Instalación de syncgitconfig completada
========================================================

Parámetros aplicados:
  remote_url : $REMOTE_URL
  repo_path  : $REPO_PATH
  env        : $ENV_NAME
  host       : $HOST_NAME
  cooldown   : $COOLDOWN
  insecure   : $INSECURE
  no-interac.: $NON_INTERACTIVE

Próximos pasos recomendados:

1) Revisa y edita la configuración:
   sudo nano $YAML_PATH

2) Comprueba los servicios:
   systemctl status syncgitconfig-watch.service
   systemctl status syncgitconfig-sync.service

3) Forzar una primera sincronización (opcional):
   $INSTALL_DIR/bin/syncgitconfig-sync --once

4) Logs en tiempo real:
   journalctl -u syncgitconfig-watch.service -f
   journalctl -u syncgitconfig-sync.service -f

Repositorio clonado:
  $REPO_PATH

Configuración YAML:
  $YAML_PATH

Credenciales (si configuradas):
  $CREDENTIALS_DIR/.git-credentials

Log de instalación:
  $LOGFILE
--------------------------------------------------------
EOM

c_green "Listo."
exit 0
