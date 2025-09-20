#!/usr/bin/env bash
# install.sh — Bootstrap automático de syncgitconfig
# Uso rápido:
#   sudo bash install.sh --remote-url https://gitea/ORG/configs-$(hostname -f).git \
#                        --repo-path /opt/configs-host \
#                        --token TU_TOKEN \
#                        --env prod \
#                        --host auto
#
# Flags:
#   --remote-url URL     (https obligatorio)
#   --repo-path PATH     (checkout local del repo de ESTE servidor)
#   --token TOKEN        (token HTTPS de Git; se guardará en .git-credentials)
#   --username NAME      (usuario para la línea de credenciales; def: syncgit-bot)
#   --env ENV            (prod/dev/staging; def: prod)
#   --host HOST          (FQDN o 'auto'; def: auto)
#   --cooldown N         (segundos; def: 60)
#   --non-interactive    (no preguntar; fallar si falta algo crítico)
#   --no-copy-bundle     (no copiar ./opt ./etc ./var aunque existan)
#   --only-deps          (solo instalar paquetes, no configurar)
#   --help

set -euo pipefail

# ---- utilidades ----
color() { printf "\033[%sm%s\033[0m" "$1" "$2"; }
info()  { echo "$(color '1;34' '[INFO]') $*"; }
ok()    { echo "$(color '1;32' '[ OK ]') $*"; }
warn()  { echo "$(color '1;33' '[WARN]') $*"; }
err()   { echo "$(color '1;31' '[ERR ]') $*" >&2; }

need_root() { [[ $EUID -eq 0 ]] || { err "Ejecuta como root"; exit 1; }; }

have() { command -v "$1" >/dev/null 2>&1; }

pkg_install() {
  local pkgs=("$@")
  if have apt-get; then
    info "Instalando paquetes con apt-get: ${pkgs[*]}"
    apt-get update -y || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  elif have dnf; then
    info "Instalando paquetes con dnf: ${pkgs[*]}"
    dnf install -y "${pkgs[@]}"
  elif have yum; then
    info "Instalando paquetes con yum: ${pkgs[*]}"
    yum install -y "${pkgs[@]}"
  elif have zypper; then
    info "Instalando paquetes con zypper: ${pkgs[*]}"
    zypper --non-interactive install "${pkgs[@]}"
  else
    warn "No se detectó gestor de paquetes compatible. Instala manualmente: ${pkgs[*]}"
  fi
}

copy_bundle_if_present() {
  if [[ "$NO_COPY_BUNDLE" == "true" ]]; then
    info "NO_COPY_BUNDLE=true — no se copiará ningún bundle."
    return 0
  fi
  local did=0
  for d in opt etc var; do
    if [[ -d "./$d" ]]; then
      info "Copiando ./$d/ → /$d/"
      rsync -a "./$d/" "/$d/"
      did=1
    fi
  done
  if [[ $did -eq 1 ]]; then
    ok "Archivos del bundle copiados."
  else
    info "No se encontró bundle local (./opt ./etc ./var). Continuamos con lo que haya en el sistema."
  fi
}

ensure_permissions() {
  # Ejecutables
  if [[ -d /opt/syncgitconfig/bin ]]; then
    chmod 755 /opt/syncgitconfig/bin/* || true
  fi
  # Credenciales
  mkdir -p /etc/syncgitconfig/credentials
  chmod 700 /etc/syncgitconfig/credentials
  [[ -f /etc/syncgitconfig/credentials/.git-credentials ]] && chmod 600 /etc/syncgitconfig/credentials/.git-credentials || true
  # Estado y logs
  mkdir -p /var/lib/syncgitconfig /var/log/syncgitconfig
  chmod 750 /var/lib/syncgitconfig
  touch /var/log/syncgitconfig/syncgitconfig.log || true
  chmod 640 /var/log/syncgitconfig/syncgitconfig.log || true
}

yaml_set_or_create() {
  # Crea YAML mínimo si no existe; si existe, asegura claves base (sustitución simple)
  local yaml="$1"
  if [[ ! -f "$yaml" ]]; then
    info "Creando YAML base en $yaml"
    mkdir -p "$(dirname "$yaml")"
    cat >"$yaml" <<'YAML'
repo_path: /opt/configs-host
remote_url: https://gitea.example.local/ORG/configs-host.git
env: prod
host: auto
staging_path: /var/lib/syncgitconfig/staging
cooldown_seconds: 60
auth:
  method: https_token
  username: syncgit-bot
  token_file: /etc/syncgitconfig/credentials/.git-credentials
exclude:
  - "*.key"
  - "*.pem"
  - "id_*"
  - "secrets/**"
  - "*.p12"
  - "*.jks"
  - "*.srl"
apps:
  - name: systemd
    dest: "apps/systemd"
    sources:
      - path: "/etc/systemd/system"
        type: dir
        strip_prefix: "/etc/systemd/system"
YAML
    ok "YAML base creado."
  fi

  # Sustituye claves si se pasaron por flag
  [[ -n "$REPO_PATH"   ]] && sed -i -E "s|^repo_path:.*$|repo_path: $REPO_PATH|" "$yaml"
  [[ -n "$REMOTE_URL"  ]] && sed -i -E "s|^remote_url:.*$|remote_url: $REMOTE_URL|" "$yaml"
  [[ -n "$ENV_NAME"    ]] && sed -i -E "s|^env:.*$|env: $ENV_NAME|" "$yaml"
  [[ -n "$HOST_NAME"   ]] && sed -i -E "s|^host:.*$|host: $HOST_NAME|" "$yaml"
  sed -i -E "s|^cooldown_seconds:.*$|cooldown_seconds: $COOLDOWN|" "$yaml"

  # Asegura token_file y username
  grep -qE '^\s*username:' "$yaml" || sed -i "/^auth:/a\  username: ${GIT_USERNAME}" "$yaml"
  sed -i -E "s|^(\s*)username:.*$|\1username: ${GIT_USERNAME}|" "$yaml"
  grep -qE '^\s*token_file:' "$yaml" || sed -i "/^  username:.*/a\  token_file: /etc/syncgitconfig/credentials/.git-credentials" "$yaml"

  ok "YAML actualizado."
}

write_credentials() {
  local yaml="$1"
  local cred_file="/etc/syncgitconfig/credentials/.git-credentials"
  if [[ -n "$GIT_TOKEN" ]]; then
    [[ "$REMOTE_URL" == https://* ]] || { err "remote_url debe ser HTTPS para usar token"; exit 1; }
    local rest="${REMOTE_URL#https://}"   # host/ORG/repo.git
    echo "https://${GIT_USERNAME}:${GIT_TOKEN}@${rest}" > "$cred_file"
    chmod 600 "$cred_file"
    ok "Token guardado en $cred_file"
    # Apunta el token_file en YAML por si no estuviera
    grep -q 'token_file:' "$yaml" || sed -i "/^auth:/a\  token_file: /etc/syncgitconfig/credentials/.git-credentials" "$yaml"
  else
    warn "No se proporcionó --token. Si el repo es privado, el clon/push fallará."
  fi
}

ensure_units() {
  # Crea units si no existen ya (por si el bundle no las trajo)
  local u1="/etc/systemd/system/syncgitconfig.service"
  local u2="/etc/systemd/system/syncgitconfig-watch.service"
  if [[ ! -f "$u1" ]]; then
cat > "$u1" <<'UNIT'
[Unit]
Description=syncgitconfig one-shot run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/syncgitconfig/bin/syncgitconfig-run

[Install]
WantedBy=multi-user.target
UNIT
  fi
  if [[ ! -f "$u2" ]]; then
cat > "$u2" <<'UNIT'
[Unit]
Description=syncgitconfig watcher (inotify)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/syncgitconfig/bin/syncgitconfig-watch
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
UNIT
  fi
  ok "Units systemd presentes."
}

clone_or_prepare_repo() {
  local repo="$REPO_PATH" url="$REMOTE_URL"
  [[ -d "$repo/.git" ]] && { info "Repo ya existe en $repo"; return 0; }
  mkdir -p "$repo"
  if [[ -n "$GIT_TOKEN" ]]; then
    local rest="${url#https://}"
    local authed="https://${GIT_USERNAME}:${GIT_TOKEN}@${rest}"
    info "Clonando repo (con token) en $repo"
    git clone "$authed" "$repo"
  else
    info "Clonando repo en $repo"
    git clone "$url" "$repo"
  fi
}

configure_repo_credentials() {
  # Usa el credential store apuntando al fichero de credenciales local
  git -C "$REPO_PATH" config credential.helper "store --file=/etc/syncgitconfig/credentials/.git-credentials" || true
  ok "Repo configurado con credential store."
}

enable_services_and_first_run() {
  systemctl daemon-reload || true
  systemctl enable --now syncgitconfig-watch.service || true

  # Primera pasada manual (si existe el runner)
  if [[ -x /opt/syncgitconfig/bin/syncgitconfig-run ]]; then
    /opt/syncgitconfig/bin/syncgitconfig-run || true
  else
    warn "No existe /opt/syncgitconfig/bin/syncgitconfig-run. ¿Copiaste el bundle?"
  fi
}

# ---- parseo de flags ----
REMOTE_URL=""
REPO_PATH=""
GIT_TOKEN=""
GIT_USERNAME="syncgit-bot"
ENV_NAME="prod"
HOST_NAME="auto"
COOLDOWN=60
NON_INTERACTIVE="false"
NO_COPY_BUNDLE="false"
ONLY_DEPS="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-url)    REMOTE_URL="$2"; shift 2;;
    --repo-path)     REPO_PATH="$2"; shift 2;;
    --token)         GIT_TOKEN="$2"; shift 2;;
    --username)      GIT_USERNAME="$2"; shift 2;;
    --env)           ENV_NAME="$2"; shift 2;;
    --host)          HOST_NAME="$2"; shift 2;;
    --cooldown)      COOLDOWN="$2"; shift 2;;
    --non-interactive) NON_INTERACTIVE="true"; shift ;;
    --no-copy-bundle) NO_COPY_BUNDLE="true"; shift ;;
    --only-deps)     ONLY_DEPS="true"; shift ;;
    -h|--help)
      sed -n '1,60p' "$0"; exit 0;;
    *)
      err "Flag desconocida: $1"; exit 2;;
  esac
done

main() {
  need_root

  # 1) Paquetes
  pkg_install git rsync inotify-tools ca-certificates
  [[ "$ONLY_DEPS" == "true" ]] && { ok "Paquetes instalados (--only-deps)."; exit 0; }

  # 2) Bundle (si existe ./opt ./etc ./var)
  copy_bundle_if_present
  ensure_permissions

  # 3) YAML y credenciales
  local YAML="/etc/syncgitconfig/syncgitconfig.yaml"
  yaml_set_or_create "$YAML"

  # Defaults si no se pasaron por flags (lectura simple del YAML)
  [[ -z "$REPO_PATH"  ]] && REPO_PATH="$(grep -E '^repo_path:' "$YAML" | awk '{print $2}')"
  [[ -z "$REMOTE_URL" ]] && REMOTE_URL="$(grep -E '^remote_url:' "$YAML" | awk '{print $2}')"

  if [[ -z "$REMOTE_URL" || -z "$REPO_PATH" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      err "Faltan --remote-url o --repo-path y --non-interactive está activo."; exit 1
    fi
    read -rp "remote_url (https://...): " REMOTE_URL
    read -rp "repo_path (/opt/configs-host): " REPO_PATH
    yaml_set_or_create "$YAML"
  fi

  write_credentials "$YAML"

  # 4) Units y repo
  ensure_units

  if [[ ! -d /opt/syncgitconfig/bin ]]; then
    err "Falta /opt/syncgitconfig/bin (no se ha desplegado el código). Copia el bundle o vuelve a lanzar sin --no-copy-bundle."
    exit 1
  fi

  clone_or_prepare_repo
  configure_repo_credentials

  # 5) Arranque y primera pasada
  enable_services_and_first_run

  ok "Instalación completa."
  echo
  echo "Resumen:"
  echo "  remote_url: $REMOTE_URL"
  echo "  repo_path : $REPO_PATH"
  echo "  yaml      : $YAML"
  echo
  echo "Estado rápido:"
  [[ -x /opt/syncgitconfig/bin/syncgitconfig-status ]] && /opt/syncgitconfig/bin/syncgitconfig-status || true
}

main
