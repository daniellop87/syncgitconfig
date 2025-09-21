#!/usr/bin/env bash
# install.sh — Instalador de syncgitconfig (adaptado a tu árbol de repo)
# Estructura esperada en el repo:
#   ./opt/syncgitconfig/bin/*               -> se copia a /opt/syncgitconfig/bin
#   ./opt/syncgitconfig/config.example.yaml -> se copia y usa como plantilla
#   ./etc/systemd/system/*.service          -> se copia a /etc/systemd/system
#   ./etc/logrotate.d/syncgitconfig         -> se copia a /etc/logrotate.d (si existe)

set -Eeuo pipefail

### ========= Rutas ORIGEN (en el repo) =========
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SRC_INSTALL_DIR="$SCRIPT_DIR/opt/syncgitconfig"
SRC_SYSTEMD_DIR="$SCRIPT_DIR/etc/systemd/system"
SRC_LOGROTATE="$SCRIPT_DIR/etc/logrotate.d/syncgitconfig" # puede no existir

### ========= Rutas DESTINO (en el sistema) =========
INSTALL_DIR="/opt/syncgitconfig"
ETC_DIR="/etc/syncgitconfig"
CREDENTIALS_DIR="$ETC_DIR/credentials"
YAML_PATH="$ETC_DIR/syncgitconfig.yaml"
TEMPLATE_PATH_DEST="$INSTALL_DIR/config.example.yaml"
LOG_DIR="/opt/logs/syncgitconfig"
LOGFILE="$LOG_DIR/install.log"

### ========= Paquetes mínimos =========
PKGS=(git rsync inotify-tools ca-certificates dos2unix)

### ========= Flags / parámetros =========
REMOTE_URL=""
REPO_PATH=""
TOKEN=""
USER_NAME=""
ENV_NAME="prod"
HOST_NAME="auto"
COOLDOWN="60"
NON_INTERACTIVE=0
INSECURE=0
RESTORE_GIT_SSL_VERIFY=0
PREVIOUS_GIT_SSL_VERIFY_STATE=""

c_green(){ printf "\033[1;32m%s\033[0m\n" "$*"; }
c_yellow(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
c_red(){ printf "\033[1;31m%s\033[0m\n" "$*"; }
log(){ echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE" >&2; }

configure_insecure_git_ssl(){
  (( INSECURE )) || return 0
  command -v git >/dev/null 2>&1 || return 0

  if (( ! RESTORE_GIT_SSL_VERIFY )); then
    if git config --global --get http.sslVerify >/dev/null 2>&1; then
      PREVIOUS_GIT_SSL_VERIFY_STATE="$(git config --global --get http.sslVerify 2>/dev/null || echo false)"
    else
      PREVIOUS_GIT_SSL_VERIFY_STATE="__unset__"
    fi
    RESTORE_GIT_SSL_VERIFY=1
  fi

  git config --global http.sslVerify false >/dev/null 2>&1 || true
  log "[WARN] --insecure: http.sslVerify=false configurado temporalmente (global)."
}

restore_git_ssl_verify(){
  (( RESTORE_GIT_SSL_VERIFY )) || return 0
  command -v git >/dev/null 2>&1 || return 0

  if [[ "$PREVIOUS_GIT_SSL_VERIFY_STATE" == "__unset__" ]]; then
    git config --global --unset http.sslVerify >/dev/null 2>&1 || true
  else
    git config --global http.sslVerify "$PREVIOUS_GIT_SSL_VERIFY_STATE" >/dev/null 2>&1 || true
  fi
}

configure_git_identity(){
  local repo="$1" host="$2"
  [[ -d "$repo/.git" ]] || return 0

  local default_name="Infra Backup Bot"
  local default_email="infra-backup@${host}"

  if ! git -C "$repo" config user.name >/dev/null 2>&1; then
    git -C "$repo" config user.name "$default_name" || true
    log "[INFO] Configurado git user.name=$default_name en $repo"
  fi

  if ! git -C "$repo" config user.email >/dev/null 2>&1; then
    git -C "$repo" config user.email "$default_email" || true
    log "[INFO] Configurado git user.email=$default_email en $repo"
  fi
}

git_clone_repo(){
  local url="$1" dest="$2"
  local -a git_cmd

  if (( INSECURE )); then
    c_yellow "[WARN] --insecure activo: clonando sin verificación SSL."
    git_cmd=(git -c http.sslVerify=false clone "$url" "$dest")
    if ! env GIT_SSL_NO_VERIFY=true "${git_cmd[@]}" 2>&1 | tee -a "$LOGFILE"; then
      return 1
    fi
    return 0
  fi

  git_cmd=(git clone "$url" "$dest")
  "${git_cmd[@]}" 2>&1 | tee -a "$LOGFILE"
}

usage() {
  cat <<EOF
Uso:
  sudo ./install.sh \\
    --remote-url "https://GIT/Org/Repo.git" \\
    --repo-path "/opt/configs-host" \\
    --token "XXXX" \\
    --user "daniel" \\
    --env "prod" \\
    --host "auto" \\
    --cooldown 60 \\
    --non-interactive [--insecure]

Parámetros:
  --remote-url        URL remota del repo (HTTPS/SSH)
  --repo-path         Ruta local donde clonar el repo (p.ej. /opt/configs-host)
  --token             (Opc.) Token HTTPS para credenciales
  --user              (Opc.) Usuario asociado al token (p.ej. daniel o git)
  --env               Entorno (por defecto: prod)
  --host              Hostname o "auto" (por defecto: auto)
  --cooldown          Segundos entre comprobaciones (por defecto: 60)
  --non-interactive   No pedir confirmaciones
  --insecure          Deshabilita verificación SSL (usar solo con repos de confianza)
  -h | --help         Ayuda
EOF
}

require_root(){ (( EUID == 0 )) || { c_red "Necesitas sudo/root."; exit 1; }; }
trap 'c_red "⚠️  Error durante la instalación. Revisa el log: $LOGFILE"' ERR
trap 'restore_git_ssl_verify' EXIT

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
    --insecure)
      INSECURE=1
      if (( $# >= 2 )); then
        INSECURE_VALUE="${2,,}"
        if [[ "$INSECURE_VALUE" == --* ]]; then
          :
        else
          case "$INSECURE_VALUE" in
            1|true|yes) shift ;;
            0|false|no) INSECURE=0; shift ;;
            *) c_red "Valor inválido para --insecure: ${INSECURE_VALUE}"; usage; exit 1 ;;
          esac
        fi
      fi
      ;;
    --insecure=*)
      INSECURE_VALUE="${1#--insecure=}"
      case "${INSECURE_VALUE,,}" in
        1|true|yes) INSECURE=1 ;;
        0|false|no) INSECURE=0 ;;
        *) c_red "Valor inválido para --insecure: ${INSECURE_VALUE}"; usage; exit 1 ;;
      esac
      ;;
    -h|--help)         usage; exit 0 ;;
    *) c_red "Opción desconocida: $1"; usage; exit 1 ;;
  esac
  shift
done

unset -v INSECURE_VALUE || true

require_root
mkdir -p "$LOG_DIR" "$ETC_DIR" "$CREDENTIALS_DIR"
touch "$LOGFILE" 2>/dev/null || true

if (( INSECURE )); then
  export GIT_SSL_NO_VERIFY=true
  log "[WARN] --insecure activo: se deshabilitará la verificación SSL en las operaciones Git."
fi

log "Instalación iniciada."
log "Infra:"
log "  SRC_INSTALL_DIR = $SRC_INSTALL_DIR"
log "  SRC_SYSTEMD_DIR = $SRC_SYSTEMD_DIR"
log "  INSTALL_DIR     = $INSTALL_DIR"
log "  ETC_DIR         = $ETC_DIR"
log "  YAML_PATH       = $YAML_PATH"
log "  TEMPLATE_DEST   = $TEMPLATE_PATH_DEST"
log "  LOGFILE         = $LOGFILE"

### ========= Validaciones =========
[[ -n "$REMOTE_URL" ]] || { c_red "Falta --remote-url"; usage; exit 1; }
[[ -n "$REPO_PATH"  ]] || { c_red "Falta --repo-path";  usage; exit 1; }

if command -v apt-get >/dev/null 2>&1; then
  log "Instalando paquetes con apt-get: ${PKGS[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >>"$LOGFILE" 2>&1 || true
  apt-get install -y "${PKGS[@]}" >>"$LOGFILE" 2>&1 || true
else
  c_yellow "No hay apt-get; omito instalación de paquetes."
fi

if (( INSECURE )); then
  configure_insecure_git_ssl
fi

### ========= Desinstalación previa (si ya estaba instalado) =========
log "Verificando instalación previa..."
systemctl disable --now syncgitconfig-watch.service 2>/dev/null || true
systemctl disable --now syncgitconfig.service 2>/dev/null || true
log "[INFO] Servicios de syncgitconfig detenidos (si estaban activos)."

### ========= Copiar proyecto a /opt/syncgitconfig =========
if [[ -d "$SRC_INSTALL_DIR" ]]; then
  log "Copiando $SRC_INSTALL_DIR -> $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  rsync -a --delete "$SRC_INSTALL_DIR"/ "$INSTALL_DIR"/
else
  c_red "[ERROR] No existe $SRC_INSTALL_DIR. Ejecuta este script desde la raíz del repo."
  exit 1
fi

# Permisos de binarios (si existen)
if [[ -d "$INSTALL_DIR/bin" ]]; then
  find "$INSTALL_DIR/bin" -maxdepth 1 -type f -exec chmod +x {} + 2>/dev/null || true
else
  log "[INFO] No existe $INSTALL_DIR/bin, omito chmod."
fi

### ========= Generar YAML desde plantilla comentada =========
if [[ ! -f "$TEMPLATE_PATH_DEST" ]]; then
  c_red "[ERROR] Plantilla no encontrada en destino: $TEMPLATE_PATH_DEST"
  c_yellow "Asegúrate de que opt/syncgitconfig/config.example.yaml existe en el repo."
  exit 1
fi

cp -f "$TEMPLATE_PATH_DEST" "$YAML_PATH"
command -v dos2unix >/dev/null 2>&1 && dos2unix -q "$YAML_PATH" || true

# Sustitución de placeholders
sed -i "s|__ENV__|${ENV_NAME}|g"         "$YAML_PATH"
sed -i "s|__HOST__|${HOST_NAME}|g"       "$YAML_PATH"
sed -i "s|__REPO_PATH__|${REPO_PATH}|g"  "$YAML_PATH"
sed -i "s|__REMOTE_URL__|${REMOTE_URL}|g" "$YAML_PATH"
sed -i "s|__COOLDOWN__|${COOLDOWN}|g"    "$YAML_PATH"

log "[ OK ] YAML actualizado en ${YAML_PATH}"

### ========= Credenciales Git (si HTTPS + token + user) =========
if [[ -n "${TOKEN:-}" && -n "${USER_NAME:-}" && "$REMOTE_URL" =~ ^https:// ]]; then
  GIT_CREDS_PATH="$CREDENTIALS_DIR/.git-credentials"
  echo "https://${USER_NAME}:${TOKEN}@${REMOTE_URL#https://}" > "$GIT_CREDS_PATH"
  git config --global credential.helper "store --file=$GIT_CREDS_PATH"
  chmod 600 "$GIT_CREDS_PATH"
  log "[ OK ] Token guardado en $GIT_CREDS_PATH"
else
  log "[INFO] No se configuraron credenciales (faltan --token/--user o URL no HTTPS)."
fi

### ========= Clonado del repo =========
log "[INFO] Clonando repo en ${REPO_PATH}"
mkdir -p "$REPO_PATH"
if [[ -d "$REPO_PATH/.git" ]]; then
  log "[INFO] Ya existe un repositorio en ${REPO_PATH}, omito clonación."
else
  if ! git_clone_repo "$REMOTE_URL" "$REPO_PATH"; then
    log "[ERROR] git clone falló incluso con --insecure (si estaba habilitado)."
    c_red "[ERROR] No se pudo clonar el repositorio remoto $REMOTE_URL"
    exit 1
  fi
fi

# Actualizar repo local al remoto y realizar commit inicial si hace falta
if [[ -d "$REPO_PATH/.git" ]]; then
  if (( INSECURE )); then
    git -C "$REPO_PATH" config http.sslVerify false || true
    log "[WARN] --insecure: http.sslVerify=false configurado en $REPO_PATH"
  fi
  # Si el repo local existe o se acaba de clonar, asegurar que está actualizado
  if git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD &>/dev/null; then
    log "[INFO] Actualizando repositorio local desde remoto (git pull)."
    if git -C "$REPO_PATH" pull --ff-only >>"$LOGFILE" 2>&1; then
      log "[OK] Repositorio local al día con remoto."
    else
      c_yellow "[WARN] Pull falló; aplicando stash y reset duro."
      git -C "$REPO_PATH" stash push -u -m "syncgitconfig-autostash-install" || true
      git -C "$REPO_PATH" fetch --prune
      BRANCH_NAME="$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
      git -C "$REPO_PATH" reset --hard "origin/$BRANCH_NAME"
      log "[OK] Repositorio sincronizado con origin/$BRANCH_NAME."
    fi
  else
    # Repositorio vacío (sin commits en remoto)
    log "[INFO] Repositorio remoto vacío. Creando commit inicial de validación."
    git -C "$REPO_PATH" checkout -b main
    echo "Repositorio inicializado por syncgitconfig" > "$REPO_PATH/README-syncgitconfig.txt"
    git -C "$REPO_PATH" add README-syncgitconfig.txt
    git -C "$REPO_PATH" -c user.name="Infra Backup Bot" -c user.email="infra-backup@${HOST_NAME}" commit -m "Initial commit (syncgitconfig instalado)"
    git -C "$REPO_PATH" push -u origin main || c_red "[ERROR] Error al realizar push inicial. Verifica credenciales."
    log "[OK] Commit inicial realizado en el repo remoto."
  fi

  configure_git_identity "$REPO_PATH" "$HOST_NAME"
fi

### ========= Commit de verificación de sincronización =========
if [[ -d "$REPO_PATH/.git" ]]; then
  CHECK_FILE_NAME="syncgitconfig-install-check.txt"
  CHECK_FILE_PATH="$REPO_PATH/$CHECK_FILE_NAME"
  CHECK_TIMESTAMP="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  DETECTED_HOST="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)"

  cat >"$CHECK_FILE_PATH" <<EOF
syncgitconfig install verification
Fecha UTC: $CHECK_TIMESTAMP
Host configurado: $HOST_NAME
Host detectado: $DETECTED_HOST
Remote URL: $REMOTE_URL
EOF

  git -C "$REPO_PATH" add "$CHECK_FILE_NAME"

  if [[ -n "$(git -C "$REPO_PATH" status --porcelain)" ]]; then
    git -C "$REPO_PATH" -c user.name="Infra Backup Bot" -c user.email="infra-backup@${HOST_NAME}" commit -m "Install verification $CHECK_TIMESTAMP"

    CURRENT_BRANCH="$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
    if git -C "$REPO_PATH" rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null; then
      git -C "$REPO_PATH" push 2>&1 | tee -a "$LOGFILE"
    else
      git -C "$REPO_PATH" push --set-upstream origin "$CURRENT_BRANCH" 2>&1 | tee -a "$LOGFILE"
    fi

    log "[OK] Commit de verificación sincronizado con el remoto."
  else
    log "[INFO] No hay cambios para el commit de verificación; se omite el push."
  fi
else
  c_yellow "[WARN] No se pudo crear el commit de verificación: $REPO_PATH no es un repo Git válido."
fi

### ========= Systemd (desde etc/systemd/system del repo) =========
if [[ -d "$SRC_SYSTEMD_DIR" ]]; then
  cp -f "$SRC_SYSTEMD_DIR"/syncgitconfig*.service /etc/systemd/system/ 2>/dev/null || true
  systemctl daemon-reload
  # En tu repo existen: syncgitconfig.service y syncgitconfig-watch.service
  systemctl enable syncgitconfig.service 2>/dev/null || true
  systemctl enable syncgitconfig-watch.service 2>/dev/null || true
  systemctl restart syncgitconfig.service 2>/dev/null || true
  systemctl restart syncgitconfig-watch.service 2>/dev/null || true
  log "[ OK ] Units systemd instaladas y servicios activos."
else
  log "[WARN] No se encontró $SRC_SYSTEMD_DIR; omito instalación de units."
fi

### ========= logrotate (si existe en el repo) =========
if [[ -f "$SRC_LOGROTATE" ]]; then
  cp -f "$SRC_LOGROTATE" /etc/logrotate.d/syncgitconfig
  log "[ OK ] logrotate instalado en /etc/logrotate.d/syncgitconfig"
fi

### ========= Enlaces de comando para uso manual =========
mkdir -p /usr/local/bin
ln -sf "$INSTALL_DIR/bin/syncgitconfig-run" /usr/local/bin/syncgitconfig
ln -sf "$INSTALL_DIR/bin/syncgitconfig-status" /usr/local/bin/syncgitconfig-status
ln -sf "$INSTALL_DIR/bin/syncgitconfig-run" /usr/local/bin/sgc
ln -sf "$INSTALL_DIR/bin/syncgitconfig-status" /usr/local/bin/sgc-status
log "[ OK ] Enlaces /usr/local/bin/{syncgitconfig,sgc} creados."

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

Próximos pasos:

1) Revisa/edita la configuración:
   sudo nano $YAML_PATH

2) Comprueba servicios:
   systemctl status syncgitconfig.service
   systemctl status syncgitconfig-watch.service

3) Forzar una primera sync (opcional):
   $INSTALL_DIR/bin/syncgitconfig-run --once  || true
   $INSTALL_DIR/bin/syncgitconfig-status      || true

4) Logs en tiempo real:
   journalctl -u syncgitconfig.service -f
   journalctl -u syncgitconfig-watch.service -f

Plantilla copiada a destino:
  $TEMPLATE_PATH_DEST

Configuración YAML:
  $YAML_PATH

Archivo verificación:
  $REPO_PATH/syncgitconfig-install-check.txt

Credenciales (si configuradas):
  $CREDENTIALS_DIR/.git-credentials

Log de instalación:
  $LOGFILE
--------------------------------------------------------
EOM

c_green "Listo."
exit 0
