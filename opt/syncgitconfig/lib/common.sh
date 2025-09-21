# common.sh — utilidades compartidas para syncgitconfig
set -euo pipefail

# Rutas por defecto (pueden sobrescribirse desde YAML)
SYNCGITCONFIG_NAME="syncgitconfig"
CONF_PATH="${CONF_PATH:-/etc/syncgitconfig/syncgitconfig.yaml}"
STATE_DIR="${STATE_DIR:-/var/lib/syncgitconfig}"
LOG_DIR="${LOG_DIR:-/var/log/syncgitconfig}"
LOG_FILE="$LOG_DIR/syncgitconfig.log"
LOCK_FILE="$STATE_DIR/lock"
COOLDOWN_FILE="$STATE_DIR/cooldown"

mkdir -p "$LOG_DIR" "$STATE_DIR"

ts() { date +'%F %T'; }
log()  { echo "[$(ts)] $*"; echo "[$(ts)] $*" >> "$LOG_FILE"; }
ok()   { log "[OK] $*"; }
warn() { log "[WARN] $*"; }
err()  { log "[ERR] $*"; }

require_cmd() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if ((${#missing[@]})); then
    err "Faltan comandos: ${missing[*]}"; return 1
  fi
}

# Variables globales pobladas tras cargar YAML
CFG_repo_path=""; CFG_remote_url=""; CFG_env="prod"; CFG_host=""; CFG_staging_path=""
CFG_cooldown_seconds=60
AUTH_method=""; AUTH_username=""; AUTH_token_file=""; AUTH_token_inline=""
EXCLUDES=()
APP_NAMES=()     # index -> app name
APP_DESTS=()     # index -> dest path
SRC_APPIDX=()    # parallel arrays: por cada source
SRC_PATHS=()
SRC_TYPES=()
SRC_STRIPS=()

# Helpers para “inyectar” datos desde el parser
_add_exclude() { EXCLUDES+=("$1"); }
_add_app()     { APP_NAMES+=("$1"); APP_DESTS+=("$2"); }
_add_source()  { SRC_APPIDX+=("$1"); SRC_PATHS+=("$2"); SRC_TYPES+=("$3"); SRC_STRIPS+=("${4:-}"); }

# Parser YAML minimalista (formato estricto, 2 espacios por nivel)
# Soporta:
# - escalares al raíz: repo_path, remote_url, env, host, staging_path, cooldown
# - auth: method, username, token_file, token_inline
# - exclude: lista simple "- patrón"
# - apps: - name, dest, sources: - path, type, strip_prefix
load_config_yaml() {
  local yaml="$1"
  [[ -f "$yaml" ]] || { err "No existe config YAML: $yaml"; return 1; }

  # Resetea arrays y vars
  EXCLUDES=(); APP_NAMES=(); APP_DESTS=(); SRC_APPIDX=(); SRC_PATHS=(); SRC_TYPES=(); SRC_STRIPS=()
  CFG_repo_path=""; CFG_remote_url=""; CFG_env="prod"; CFG_host=""; CFG_staging_path=""
  CFG_cooldown_seconds=60; AUTH_method=""; AUTH_username=""; AUTH_token_file=""; AUTH_token_inline=""

  # Procesa YAML con awk siguiendo indentación de 0/2/4/6/8 espacios
  # Emitimos llamadas a _add_* y asignaciones CFG_* / AUTH_*
  local AWK='
  function ltrim(s){ sub(/^[ \t\r\n]+/,"",s); return s }
  function rtrim(s){ sub(/[ \t\r\n]+$/,"",s); return s }
  function trim(s){ return rtrim(ltrim(s)) }

  BEGIN{
    in_auth=0; in_excl=0; in_apps=0; have_app=0; in_sources=0;
    app_idx=-1;
    src_path=""; src_type=""; src_strip="";
  }
  # limpia comentarios y líneas vacías
  {
    line=$0
    gsub(/[[:space:]]+#.*/,"",line)
    if (line ~ /^[[:space:]]*$/) next
    # nivel de indentación (nº de espacios al inicio)
    indent=match(line,/[^ ]/) - 1
    key=""; val=""
    # líneas tipo "key: value"
    if (match(line, /^[ ]*[^:]+:[ ]*/)) {
      k=substr(line, RSTART, RLENGTH)
      key=trim(substr(k,1,length(k)-1))
      val=trim(substr(line, RLENGTH+1))
    }

    # nivel 0
    if (indent==0) {
      in_auth=0; in_excl=0;
      if (key=="repo_path")    { print "CFG_repo_path=\"" val "\"" }
      else if (key=="remote_url"){ print "CFG_remote_url=\"" val "\"" }
      else if (key=="env")     { print "CFG_env=\"" val "\"" }
      else if (key=="host")    { print "CFG_host=\"" val "\"" }
      else if (key=="staging_path"){ print "CFG_staging_path=\"" val "\"" }
      else if (key=="cooldown" || key=="cooldown_seconds"){ print "CFG_cooldown_seconds=" val }
      else if (key=="auth")    { in_auth=1 }
      else if (key=="exclude") { in_excl=1 }
      else if (key=="apps")    { in_apps=1 }
      next
    }

    # nivel 2
    if (indent==2) {
      if (in_auth && key!="") {
        if (key=="method")      print "AUTH_method=\"" val "\""
        else if (key=="username")   print "AUTH_username=\"" val "\""
        else if (key=="token_file") print "AUTH_token_file=\"" val "\""
        else if (key=="token_inline") print "AUTH_token_inline=\"" val "\""
        next
      }
      if (in_excl && match(line, /^[ ]*-[ ]+/)) {
        pat=trim(substr(line, index(line,"-")+1))
        print "_add_exclude \"" pat "\""
        next
      }
    }

    # apps
    if (in_apps) {
      # nueva app: "  - name: XXX"
      if (indent==2 && match(line, /^[ ]*-[ ]+name:[ ]*/)) {
        have_app=1; in_sources=0;
        app_idx++;
        aname=trim(substr(line, RLENGTH+1))
        # necesitamos leer dest más abajo; por ahora vacío
        print "_add_app \"" aname "\" \"\""
        next
      }
      # propiedades de la app (indent 4)
      if (have_app && indent==4 && key!="") {
        if (key=="dest") {
          print "APP_DESTS[" app_idx "]=\"" val "\""
        } else if (key=="sources") {
          in_sources=1; src_path=""; src_type=""; src_strip="";
        }
        next
      }
      # sources
      if (have_app && in_sources) {
        if (indent==6 && match(line, /^[ ]*-[ ]+path:[ ]*/)) {
          # si había un source acumulado, emítelo antes de empezar otro
          if (src_path!="") {
            print "_add_source " app_idx " \"" src_path "\" \"" src_type "\" \"" src_strip "\""
            src_path=""; src_type=""; src_strip="";
          }
          src_path=trim(substr(line, RLENGTH+1)); next
        }
        if (indent==8 && key!="") {
          if (key=="type")        src_type=val;
          else if (key=="strip_prefix") src_strip=val;
          next
        }
        # si volvemos a indentación <=4, cerramos el último source
        if (indent<=4 && src_path!="") {
          print "_add_source " app_idx " \"" src_path "\" \"" src_type "\" \"" src_strip "\""
          src_path=""; src_type=""; src_strip="";
          # y como hemos salido de sources, no hacemos next: dejar fluir a tratar nueva app/prop
        }
      }
    }
  }
  END{
    # emite el último source si quedó pendiente
    if (src_path!="") {
      print "_add_source " app_idx " \"" src_path "\" \"" src_type "\" \"" src_strip "\""
    }
  }'

  # Ejecutamos awk y evaluamos las llamadas generadas (_add_app/_add_source/variables)
  local __out
  __out="$(awk "$AWK" "$yaml")"
  eval "$__out"

  # Defaults
  [[ -z "$CFG_host" || "$CFG_host" == "auto" ]] && CFG_host="$(hostname -f 2>/dev/null || hostname)"
  [[ -z "$CFG_staging_path" ]] && CFG_staging_path="/var/lib/syncgitconfig/staging"
}

# Devuelve flags --exclude para rsync, según EXCLUDES
rsync_exclude_flags() {
  local f=()
  for pat in "${EXCLUDES[@]:-}"; do f+=( "--exclude=$pat" ); done
  # Siempre evitar .git, lock y logs
  f+=( "--exclude=.git" "--exclude=.git/**" )
  echo "${f[@]}"
}

# Lock y cooldown (cooldown en segundos desde YAML)
acquire_lock_or_exit() {
  exec 9>"$LOCK_FILE" || true
  flock -n 9 || { warn "Otra ejecución en curso, salgo."; exit 0; }
}

respect_cooldown_or_exit() {
  local now last=0 cdn="$CFG_cooldown_seconds"
  now=$(date +%s)
  [[ -f "$COOLDOWN_FILE" ]] && last=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  if (( now - last < cdn )); then
    warn "Dentro de cooldown (${cdn}s); salto."
    exit 0
  fi
  echo "$now" > "$COOLDOWN_FILE"
}

# Comprueba que el repo local existe y es Git
ensure_git_repo_ready() {
  local repo="$1" remote="$2" cred_file="${3:-}"

  if [[ ! -d "$repo/.git" ]]; then
    if [[ -z "$remote" ]]; then
      err "repo_path no es un checkout Git y remote_url no está definido: $repo"
      return 1
    fi

    if [[ -d "$repo" ]]; then
      if find "$repo" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
        err "repo_path existe pero no es un checkout Git y contiene archivos: $repo"
        return 1
      fi
      rmdir "$repo" 2>/dev/null || true
    fi

    mkdir -p "$(dirname "$repo")"
    log "Clonando repositorio remoto $remote en $repo"

    local -a git_clone_cmd=(git)
    if [[ -n "$cred_file" ]]; then
      git_clone_cmd+=(-c "credential.helper=store --file=$cred_file")
    fi
    git_clone_cmd+=(clone "$remote" "$repo")

    if ! "${git_clone_cmd[@]}" >>"$LOG_FILE" 2>&1; then
      err "git clone falló para $remote"
      return 1
    fi

    ok "Repositorio clonado en $repo"
  fi

  # Configura helper de credenciales si se indicó token_file
  if [[ -n "$cred_file" ]]; then
    git -C "$repo" config credential.helper "store --file=$cred_file" || true
  fi
  # Verifica remoto
  local rurl
  rurl="$(git -C "$repo" remote get-url origin 2>/dev/null || echo "")"
  if [[ -z "$rurl" ]]; then
    git -C "$repo" remote add origin "$remote"
  fi
}

# Añade y comitea cambios si los hay; empuja si PUSH=true (por defecto)
git_commit_and_push() {
  local repo="$1" hostroot="$2" env="$3" host="$4" app_tag="${5:-}"
  git -C "$repo" add -A "$hostroot"
  if git -C "$repo" diff --cached --quiet "$hostroot"; then
    ok "Sin cambios que comitear."
    return 0
  fi
  local msg="[auto][$env][$host]"
  [[ -n "$app_tag" ]] && msg="$msg[app:$app_tag]"
  msg="$msg snapshot @ $(ts)"
  git -C "$repo" -c user.name="Infra Backup Bot" -c user.email="infra-backup@${host}" commit -m "$msg" || true
  git -C "$repo" push || warn "git push falló (revisa credenciales/remoto)"
}
