#!/usr/bin/env bash
# uninstall.sh — Desinstala syncgitconfig con garantías
# Características:
#  - Confirma (o --yes)
#  - Dry-run (--dry-run)
#  - Backup comprimido (--backup [--backup-dir DIR])
#  - Mantener logs (--keep-logs) o purgar todo (--purge)
#  - Autodestrucción al final (omitible con --no-self-delete)
#  - Registra todo en /var/log/syncgitconfig_uninstall-*.log

set -Eeuo pipefail

### ====== Config por defecto (ajusta si tu instalación difiere) ======
INSTALL_DIR="/opt/syncgitconfig"
ETC_DIR="/etc/syncgitconfig"
LOG_BASE_DIR="/opt/logs/syncgitconfig"
STATE_DIR="/var/lib/syncgitconfig"
CONFIG_FILE="$ETC_DIR/syncgitconfig.yaml"
SYSTEMD_PATTERNS=( "/etc/systemd/system/syncgitconfig-*.service" )
CRON_CANDIDATES=( "/etc/cron.d/syncgitconfig" )
BIN_CANDIDATES=( "/usr/local/bin/syncgitconfig" "/usr/local/bin/syncgitconfig-status" "/usr/local/bin/sgc" "/usr/local/bin/sgc-status" )
PROCESS_GREP="syncgitconfig"

# Flags
YES=0
DRY_RUN=0
DO_BACKUP=0
BACKUP_DIR=""
KEEP_LOGS=0
PURGE=0
PURGE_REPO=0
SELF_DELETE=1
REPO_PATH=""
REPO_PATH_RESOLVED=""

# Log
TS="$(date +'%Y%m%d-%H%M%S')"
LOGFILE="/var/log/syncgitconfig_uninstall-${TS}.log"
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE" 2>/dev/null || LOGFILE="/tmp/syncgitconfig_uninstall-${TS}.log"

### ====== Utilidades ======
c_green(){ printf "\033[1;32m%s\033[0m\n" "$*"; }
c_yellow(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
c_red(){ printf "\033[1;31m%s\033[0m\n" "$*"; }
log(){ echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE" >&2; }
run(){ if ((DRY_RUN)); then log "[dry-run] $*"; else log ">> $*"; eval "$@"; fi; }
exists(){ test -e "$1"; }

resolve_repo_path() {
  local cfg="$CONFIG_FILE"
  [[ -f "$cfg" ]] || return
  local raw=""
  raw="$(awk '
    {
      line=$0
      sub(/[[:space:]]+#.*/, "", line)
      if (line ~ /^[[:space:]]*repo_path[[:space:]]*:/) {
        sub(/^[[:space:]]*repo_path[[:space:]]*:[[:space:]]*/, "", line)
        print line
        exit
      }
    }
  ' "$cfg")"
  raw="${raw%$'\r'}"
  raw="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [[ -z "$raw" ]]; then
    return
  fi
  if [[ "${raw:0:1}" == '"' && "${raw: -1}" == '"' ]]; then
    raw="${raw:1:-1}"
  elif [[ "${raw:0:1}" == "'" && "${raw: -1}" == "'" ]]; then
    raw="${raw:1:-1}"
  fi
  if [[ "$raw" == ~* ]]; then
    raw="${raw/#\~/$HOME}"
  fi
  REPO_PATH="$raw"
  if command -v realpath >/dev/null 2>&1; then
    REPO_PATH_RESOLVED="$(realpath -m "$raw" 2>/dev/null || echo "$raw")"
  else
    REPO_PATH_RESOLVED="$raw"
  fi
}

usage() {
  cat <<EOF
Uso: sudo $0 [opciones]

Opciones:
  --yes                No preguntar confirmación
  --dry-run            Simula (no borra nada)
  --backup             Crea backup .tar.gz antes de borrar
  --backup-dir DIR     Carpeta destino del backup (por defecto: ${LOG_BASE_DIR}/backups)
  --keep-logs          Mantiene ${LOG_BASE_DIR}
  --purge              BORRA TODO, incluidos logs y estado en ${STATE_DIR}
  --purge-repo         Elimina el checkout local definido en repo_path (requiere --purge para limpiar estado)
  --no-self-delete     No se autodestruye al finalizar
  -h, --help           Muestra esta ayuda

Componentes objetivo:
  - Servicios systemd: ${SYSTEMD_PATTERNS[*]}
  - Binarios/symlinks: ${BIN_CANDIDATES[*]}
  - Directorio app    : ${INSTALL_DIR}
  - Configuración     : ${ETC_DIR}
  - Estado            : ${STATE_DIR}
  - Logs              : ${LOG_BASE_DIR}
  - Cron              : ${CRON_CANDIDATES[*]}
  - Procesos que contengan: ${PROCESS_GREP}
EOF
}

### ====== Parseo de flags ======
while (( "$#" )); do
  case "$1" in
    --yes) YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --backup) DO_BACKUP=1 ;;
    --backup-dir) shift; BACKUP_DIR="${1:-}";;
    --keep-logs) KEEP_LOGS=1 ;;
    --purge) PURGE=1 ;;
    --purge-repo) PURGE_REPO=1 ;;
    --no-self-delete) SELF_DELETE=0 ;;
    -h|--help) usage; exit 0 ;;
    *) c_red "Opción desconocida: $1"; usage; exit 1 ;;
  esac
  shift
done

resolve_repo_path

if (( EUID != 0 )); then
  c_red "Necesitas sudo/root."
  exit 1
fi

trap 'c_red "⚠️  Ha ocurrido un error. Revisa el log: $LOGFILE"' ERR

c_green "== Desinstalador de syncgitconfig =="
log "Log: $LOGFILE"
((DRY_RUN)) && c_yellow "Modo DRY-RUN: no se eliminará nada."

# Confirmación
if (( ! YES )); then
  echo
  c_yellow "Esto va a desinstalar syncgitconfig del sistema."
  ((DO_BACKUP)) && echo " - Se hará un BACKUP previo."
  if (( PURGE )); then
    echo " - PURGE: se eliminarán ${STATE_DIR} y ${LOG_BASE_DIR} (ignora --keep-logs)."
  else
    ((KEEP_LOGS)) && echo " - Mantendrás los logs en ${LOG_BASE_DIR}."
  fi
  if (( PURGE_REPO )); then
    if [[ -n "$REPO_PATH_RESOLVED" ]]; then
      echo " - PURGE-REPO: se borrará el checkout local en ${REPO_PATH_RESOLVED}."
    else
      echo " - PURGE-REPO: solicitado, pero no se detectó repo_path en ${CONFIG_FILE}."
    fi
  fi
  read -rp "¿Continuar? [y/N] " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "s" ]] || { log "Cancelado por usuario."; exit 0; }
fi

### ====== Backup (opcional) ======
if (( DO_BACKUP )); then
  DEST="${BACKUP_DIR:-$LOG_BASE_DIR/backups}"
  ARCHIVE="$DEST/syncgitconfig-backup-${TS}.tar.gz"
  run "mkdir -p '$DEST'"
  # Construye lista de paths existentes
  TO_BACKUP=()
  for p in "$INSTALL_DIR" "$ETC_DIR" "${SYSTEMD_PATTERNS[@]}" "${BIN_CANDIDATES[@]}"; do
    for x in $p; do
      [[ -e "$x" ]] && TO_BACKUP+=("$x")
    done
  done
  if ((${#TO_BACKUP[@]})); then
    log "Incluyendo en backup: ${TO_BACKUP[*]}"
    ((DRY_RUN)) || tar -czf "$ARCHIVE" --absolute-names "${TO_BACKUP[@]}" 2>>"$LOGFILE"
    log "Backup creado en: $ARCHIVE"
  else
    log "No hay elementos que respaldar; se omite backup."
  fi
fi

### ====== Parar/Deshabilitar servicios ======
log "Deteniendo servicios systemd (si existen)..."
for pattern in "${SYSTEMD_PATTERNS[@]}"; do
  for unit in $pattern; do
    [[ -e "$unit" ]] || continue
    name="$(basename "$unit")"
    run "systemctl stop '$name' || true"
    run "systemctl disable '$name' || true"
  done
done

### ====== Matar procesos residuales ======
log "Matando procesos con patrón '${PROCESS_GREP}'..."
PIDS="$(pgrep -f "$PROCESS_GREP" || true)"
if [[ -n "$PIDS" ]]; then
  run "kill $PIDS || true"
  sleep 0.5
  # Forzar si persisten
  PIDS2="$(pgrep -f "$PROCESS_GREP" || true)"
  [[ -n "$PIDS2" ]] && run "kill -9 $PIDS2 || true"
else
  log "Sin procesos coincidentes."
fi

### ====== Eliminar unidades systemd ======
log "Eliminando unidades systemd..."
for pattern in "${SYSTEMD_PATTERNS[@]}"; do
  for unit in $pattern; do
    [[ -e "$unit" ]] || continue
    run "rm -f '$unit'"
  done
done
run "systemctl daemon-reload"

### ====== Eliminar cron si existe ======
log "Eliminando cron relacionado..."
for c in "${CRON_CANDIDATES[@]}"; do
  [[ -e "$c" ]] && run "rm -f '$c'"
done

### ====== Eliminar binarios/symlinks ======
log "Eliminando binarios/symlinks..."
for b in "${BIN_CANDIDATES[@]}"; do
  [[ -e "$b" ]] && run "rm -f '$b'"
done

### ====== Eliminar directorios: app, config, logs ======
log "Eliminando directorio de instalación: $INSTALL_DIR"
[[ -e "$INSTALL_DIR" ]] && run "rm -rf '$INSTALL_DIR'"

log "Eliminando configuración: $ETC_DIR"
[[ -e "$ETC_DIR" ]] && run "rm -rf '$ETC_DIR'"

if (( PURGE )); then
  log "PURGE activado: eliminando estado: $STATE_DIR"
  [[ -e "$STATE_DIR" ]] && run "rm -rf '$STATE_DIR'"
  log "PURGE activado: eliminando logs: $LOG_BASE_DIR"
  [[ -e "$LOG_BASE_DIR" ]] && run "rm -rf '$LOG_BASE_DIR'"
else
  log "Conservando estado en $STATE_DIR (por defecto). Usa --purge para borrarlo."
  if (( KEEP_LOGS )); then
    log "Manteniendo logs en $LOG_BASE_DIR (por petición)."
  else
    # Por defecto, conservamos logs (mejor para auditoría). No hacemos nada.
    log "Conservando logs en $LOG_BASE_DIR (por defecto). Usa --purge para borrarlos."
  fi
fi

if (( PURGE_REPO )); then
  if [[ -n "$REPO_PATH_RESOLVED" && -e "$REPO_PATH_RESOLVED" ]]; then
    if [[ "$REPO_PATH_RESOLVED" == "/" ]]; then
      log "--purge-repo detectó repo_path='/' (se omite por seguridad)."
    else
      if [[ -d "$REPO_PATH_RESOLVED/.git" ]]; then
        log "Eliminando repo local: $REPO_PATH_RESOLVED"
        run "rm -rf '$REPO_PATH_RESOLVED'"
      else
        log "Repo_path no parece un checkout Git: $REPO_PATH_RESOLVED (se omite)."
      fi
    fi
  else
    if [[ -n "$REPO_PATH" ]]; then
      log "Repo_path no encontrado en disco: $REPO_PATH (nada que borrar)."
    else
      log "--purge-repo solicitado pero no se detectó repo_path en ${CONFIG_FILE}."
    fi
  fi
fi

c_green "✅ syncgitconfig se ha desinstalado correctamente."
log "Desinstalación finalizada."

### ====== Autodestrucción ======
if (( SELF_DELETE )); then
  # Nota: si el script vive dentro de INSTALL_DIR y ya lo borramos, quizás ya no exista.
  SCRIPT_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
  if [[ -f "$SCRIPT_PATH" ]]; then
    c_yellow "Autodestrucción del desinstalador..."
    if ((DRY_RUN)); then
      log "[dry-run] rm -f '$SCRIPT_PATH'"
    else
      rm -f "$SCRIPT_PATH" || true
      c_green "💣 El script uninstall.sh se ha autodestruido correctamente."
    fi
  else
    log "El desinstalador ya no está en disco (probablemente se eliminó al borrar $INSTALL_DIR)."
  fi
else
  log "Autodestrucción desactivada por --no-self-delete."
fi

echo "📄 Log guardado en: $LOGFILE"
