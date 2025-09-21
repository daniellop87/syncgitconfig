#!/usr/bin/env bash
set -euo pipefail

# =========================
# Syncgitconfig Installer
# =========================
# Requisitos que instala: git rsync inotify-tools ca-certificates dos2unix
# Crea/actualiza: /etc/syncgitconfig/syncgitconfig.yaml
# Configura credenciales: /etc/syncgitconfig/credentials/.git-credentials
# Instala service: /etc/systemd/system/syncgitconfig-watch.service
# Copia binarios a: /opt/syncgitconfig/bin
# Uso típico:
#   sudo ./install.sh \
#     --remote-url "https://GITEA_HOST/Org/Repo.git" \
#     --user "USUARIO" \
#     --token "TOKEN" \
#     --repo-path "/opt/configs-host" \
#     --env prod \
#     --host auto \
#     --cooldown 60 \
#     --non-interactive \
#     --insecure-skip-tls-verify true   # solo si cert no confiable
#
#   (o bien SSH sin token)
#   sudo ./install.sh --remote-url "git@GITEA:Org/Repo.git" --repo-path "/opt/configs-host" --env prod --host auto --non-interactive

REMOTE_URL=""
REPO_PATH=""
TOKEN=""
USER_NAME=""
ENVIRONMENT="dev"
HOSTNAME_ARG="auto"
COOLDOWN="60"
NON_INTERACTIVE=false
ALLOW_INSECURE_HTTP="false"
INSECURE_SKIP_TLS_VERIFY="false"

log(){ echo "[$(date '+%F %T')] $*"; }
fail(){ echo "[ERR] $*" >&2; exit 1; }

# --- Parseo args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-url)             REMOTE_URL="${2:-}"; shift 2 ;;
    --repo-path)              REPO_PATH="${2:-}"; shift 2 ;;
    --token)                  TOKEN="${2:-}"; shift 2 ;;
    --user)                   USER_NAME="${2:-}"; shift 2 ;;
    --env)                    ENVIRONMENT="${2:-}"; shift 2 ;;
    --host)                   HOSTNAME_ARG="${2:-}"; shift 2 ;;
    --cooldown)               COOLDOWN="${2:-}"; shift 2 ;;
    --allow-insecure-http)    ALLOW_INSECURE_HTTP="${2:-false}"; shift 2 ;;
    --insecure-skip-tls-verify) INSECURE_SKIP_TLS_VERIFY="${2:-false}"; shift 2 ;;
    --non-interactive)        NON_INTERACTIVE=true; shift ;;
    *) fail "Argumento no reconocido: $1" ;;
  esac
done

[[ -n "$REMOTE_URL" ]] || fail "Debes pasar --remote-url"
[[ -n "$REPO_PATH"  ]] || fail "Debes pasar --repo-path"
[[ -n "$ENVIRONMENT" ]] || ENVIRONMENT="dev"

if [[ "$HOSTNAME_ARG" == "auto" ]]; then
  HOSTNAME_ARG="$(hostname -s || hostname)"
fi

# --- Instala dependencias ---
log "Instalando paquetes con apt-get: git rsync inotify-tools ca-certificates dos2unix"
apt-get update -y >/dev/null
apt-get install -y git rsync inotify-tools ca-certificates dos2unix >/dev/null

# --- Crear rutas base ---
install -d -m 755 /opt/syncgitconfig/bin
install -d -m 700 /etc/syncgitconfig/credentials
install -d -m 755 /var/log/syncgitconfig

# --- Copiar binarios desde el bundle si existen (opcional) ---
# Asumimos que ejecutas desde la raíz del proyecto que contiene ./bin
if [[ -d ./bin ]]; then
  rsync -a ./bin/ /opt/syncgitconfig/bin/
fi

# --- Forzar LF en binarios por si vinieran con CRLF ---
dos2unix /opt/syncgitconfig/bin/* >/dev/null 2>&1 || true
chmod +x /opt/syncgitconfig/bin/* || true

# --- Validación del remoto ---
IS_SSH=false; IS_HTTPS=false; IS_HTTP=false
if [[ "$REMOTE_URL" =~ ^[^@]+@[^:]+: ]] || [[ "$REMOTE_URL" =~ ^ssh:// ]]; then IS_SSH=true; fi
if [[ "$REMOTE_URL" =~ ^https:// ]]; then IS_HTTPS=true; fi
if [[ "$REMOTE_URL" =~ ^http:// ]]; then IS_HTTP=true; fi

if $IS_HTTPS; then
  [[ -n "$TOKEN" ]] || fail "Para HTTPS necesitas --token (PAT de Gitea/Git)"
  [[ -n "$USER_NAME" ]] || fail "Para HTTPS necesitas --user (usuario ligado al token)"
elif $IS_HTTP; then
  [[ "$ALLOW_INSECURE_HTTP" == "true" ]] || fail "remote_url es HTTP sin TLS. Pasa --allow-insecure-http true (NO recomendado)."
  # token opcional pero MUY mala idea enviarlo en claro
elif $IS_SSH; then
  if [[ -n "$TOKEN" || -n "$USER_NAME" ]]; then
    log "[WARN] Has pasado --token/--user pero el remoto es SSH; se ignorarán."
  fi
else
  fail "remote_url no reconocido. Usa https://..., http://... o SSH (git@host:org/repo.git)"
fi

# --- YAML de configuración ---
CONF_YAML="/etc/syncgitconfig/syncgitconfig.yaml"
{
  echo "env: $ENVIRONMENT"
  echo "host: $HOSTNAME_ARG"
  echo "repo_path: $REPO_PATH"
  echo "remote_url: $REMOTE_URL"
  echo "cooldown: $COOLDOWN"
  echo "watch_paths:"
  echo "  - /etc/systemd"  # Puedes añadir más rutas en este array
} > "$CONF_YAML"
log "[ OK ] YAML actualizado en $CONF_YAML"

# --- Credenciales (solo para HTTPS/HTTP) ---
if $IS_HTTPS || $IS_HTTP; then
  git config --global credential.helper "store --file=/etc/syncgitconfig/credentials/.git-credentials"
  git config --global credential.useHttpPath true

  # Extraer host base y ruta repo
  # REMOTE_URL esperado: https://host/Org/Repo(.git)
  base_host="$(echo "$REMOTE_URL" | awk -F'/' '{print $3}')"
  repo_path_rel="${REMOTE_URL#https://$base_host}"

  # Guardar credenciales a nivel host y a nivel repo
  {
    echo "https://$USER_NAME:$TOKEN@$base_host"
    echo "https://$USER_NAME:$TOKEN@$base_host$repo_path_rel"
  } > /etc/syncgitconfig/credentials/.git-credentials
  chmod 600 /etc/syncgitconfig/credentials/.git-credentials
  log "[ OK ] Token guardado en /etc/syncgitconfig/credentials/.git-credentials"

  if [[ "$INSECURE_SKIP_TLS_VERIFY" == "true" ]]; then
    git config --global http."https://$base_host/".sslVerify false
    log "[WARN] TLS verify DESACTIVADO para https://$base_host/ (solo entorno interno)"
  fi
fi

# --- Clonado/config del repo ---
if [[ ! -d "$REPO_PATH/.git" ]]; then
  install -d -m 755 "$REPO_PATH"
  if $IS_HTTPS; then
    # Forzamos usuario en la URL remota para evitar prompts
    REMOTE_WITH_USER="$(echo "$REMOTE_URL" | sed "s#^https://#https://$USER_NAME@#")"
    log "[INFO] Clonando repo (HTTPS) en $REPO_PATH"
    git clone "$REMOTE_WITH_USER" "$REPO_PATH" || fail "No se pudo clonar $REMOTE_URL"
  else
    log "[INFO] Clonando repo en $REPO_PATH"
    git clone "$REMOTE_URL" "$REPO_PATH" || fail "No se pudo clonar $REMOTE_URL"
  fi
else
  log "[INFO] Repo ya existente: $REPO_PATH"
  git -C "$REPO_PATH" remote set-url origin "$REMOTE_URL"
fi

# --- Templates de systemd (instalación) ---
cat >/etc/systemd/system/syncgitconfig-watch.service <<'UNIT'
[Unit]
Description=syncgitconfig watcher (inotify)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/syncgitconfig/bin/syncgitconfig-watch
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

log "[ OK ] Unit systemd instalada: syncgitconfig-watch.service"

# --- Activar service ---
systemctl daemon-reload
systemctl enable --now syncgitconfig-watch.service >/dev/null 2>&1 || true

# --- Status rápido ---
#/opt/syncgitconfig/bin/syncgitconfig-status || true

log "[ OK ] Instalación completa.\n\nResumen:\n  remote_url: $REMOTE_URL\n  repo_path : $REPO_PATH\n  yaml      : $CONF_YAML\n"
# == Fin de instalación ==

clear

cat <<'EOM'
========================================================
✅ Instalación de syncgitconfig completada
========================================================

Próximos pasos recomendados:

1. Revisa y edita el archivo de configuración:
   sudo nano /etc/syncgitconfig/syncgitconfig.yaml

   Ahí puedes definir:
     - apps que quieres sincronizar
     - rutas locales ↔ repositorio
     - opciones de exclusión, etc.

2. Comprueba el estado de los servicios systemd:
   systemctl status syncgitconfig-watch.service
   systemctl status syncgitconfig-sync.service

3. Forzar la primera sincronización manual (opcional):
   /opt/syncgitconfig/bin/syncgitconfig-sync --once

4. Logs en tiempo real:
   journalctl -u syncgitconfig-watch.service -f
   journalctl -u syncgitconfig-sync.service -f

--------------------------------------------------------
El repositorio se ha clonado en:
/opt/configs-host

La configuración YAML está en:
/etc/syncgitconfig/syncgitconfig.yaml

Las credenciales están en:
/etc/syncgitconfig/credentials/.git-credentials
--------------------------------------------------------

¡Ya puedes empezar a trabajar con GitOps de configuraciones!
EOM


