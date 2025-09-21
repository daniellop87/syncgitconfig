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
CFG_repo_path=""; CFG_remote_url=""; CFG_env="prod"; CFG_host=""; CFG_staging_path=""; CFG_repo_layout="hierarchical"
CFG_cooldown_seconds=60
AUTH_method=""; AUTH_username=""; AUTH_token_file=""; AUTH_token_inline=""
AUTH_netrc_file=""; AUTH_ssh_key_path=""; AUTH_ssh_known_hosts=""; AUTH_ssh_extra_args=""
AUTH_effective_method=""
declare -A AUTH_GIT_ENV_MAP=()
AUTH_GIT_ENVS=()
ENV_APP_RECORDS=()
EXCLUDES=()
WATCH_PATHS=()
PATHS=()
APP_NAMES=()     # index -> app name
APP_DESTS=()     # index -> dest path
SRC_APPIDX=()    # parallel arrays: por cada source
SRC_PATHS=()
SRC_TYPES=()
SRC_STRIPS=()
SRC_DESTS=()
ENSURE_APP_LAST_IDX=-1

# Helpers para “inyectar” datos desde el parser
_add_exclude()    { EXCLUDES+=("$1"); }
_add_watch_path() { [[ -n "$1" ]] && WATCH_PATHS+=("$1"); }
_add_path()       { [[ -n "$1" ]] && PATHS+=("$1"); }
_add_app()        { APP_NAMES+=("$1"); APP_DESTS+=("$2"); }
_add_source()     { SRC_APPIDX+=("$1"); SRC_PATHS+=("$2"); SRC_TYPES+=("$3"); SRC_STRIPS+=("${4:-}"); SRC_DESTS+=("${5:-}"); }

__env_add_path() { ENV_APP_RECORDS+=("$1|$2|$3|$4|$5|$6|$7|$8"); }

ensure_app_entry() {
  local name="$1" dest="$2"
  local idx
  for ((idx=0; idx<${#APP_NAMES[@]}; idx++)); do
    if [[ "${APP_NAMES[$idx]}" == "$name" ]]; then
      if [[ -n "$dest" ]]; then
        APP_DESTS[$idx]="$dest"
      fi
      ENSURE_APP_LAST_IDX=$idx
      return 0
    fi
  done
  APP_NAMES+=("$name")
  APP_DESTS+=("$dest")
  ENSURE_APP_LAST_IDX=$(( ${#APP_NAMES[@]} - 1 ))
}

repo_host_root_path() {
  if [[ "$CFG_repo_layout" == "flat" ]]; then
    printf '%s\n' "$CFG_repo_path"
  else
    printf '%s\n' "$CFG_repo_path/envs/$CFG_env/hosts/$CFG_host"
  fi
}

build_command_string() {
  local out=""
  local part
  for part in "$@"; do
    if [[ -n "$out" ]]; then
      out+=" "
    fi
    out+="$(printf '%q' "$part")"
  done
  echo "$out"
}

configure_git_auth_environment() {
  AUTH_GIT_ENV_MAP=()
  AUTH_GIT_ENVS=()

  case "$AUTH_effective_method" in
    https_token|https_inline|https_netrc|https)
      AUTH_GIT_ENV_MAP["GIT_TERMINAL_PROMPT"]="0"
      ;;
  esac

  if [[ "$AUTH_effective_method" == "https_netrc" ]]; then
    local netrc_raw="${AUTH_netrc_file:-$HOME/.netrc}"
    local netrc="$netrc_raw"
    if [[ "$netrc" == ~* ]]; then
      netrc="${netrc/#\~/$HOME}"
    fi
    if [[ ! -f "$netrc" ]]; then
      warn "auth.method=https_netrc pero no existe netrc: $netrc"
    else
      local existing_opts="${GIT_CURL_OPTS:-}"
      local new_opts=""
      if [[ -n "$existing_opts" ]]; then
        new_opts="$existing_opts "
      fi
      if [[ -n "$AUTH_netrc_file" ]]; then
        new_opts+="--netrc-file=$netrc"
      else
        new_opts+="--netrc"
      fi
      AUTH_GIT_ENV_MAP["GIT_CURL_OPTS"]="$new_opts"
    fi
  fi

  if [[ "$AUTH_effective_method" == "ssh" ]]; then
    local -a ssh_cmd=(ssh)
    local ssh_key="$AUTH_ssh_key_path"
    local known_hosts="$AUTH_ssh_known_hosts"
    if [[ "$ssh_key" == ~* ]]; then
      ssh_key="${ssh_key/#\~/$HOME}"
    fi
    if [[ "$known_hosts" == ~* ]]; then
      known_hosts="${known_hosts/#\~/$HOME}"
    fi
    if [[ -n "$ssh_key" ]]; then
      ssh_cmd+=(-i "$ssh_key")
    fi
    if [[ -n "$known_hosts" ]]; then
      ssh_cmd+=(-o "UserKnownHostsFile=$known_hosts")
      ssh_cmd+=(-o "StrictHostKeyChecking=yes")
    fi
    if [[ -n "$AUTH_ssh_extra_args" ]]; then
      local -a extra=()
      # shellcheck disable=SC2206 # palabra dividida intencionadamente
      extra=($AUTH_ssh_extra_args)
      ssh_cmd+=("${extra[@]}")
    fi
    AUTH_GIT_ENV_MAP["GIT_SSH_COMMAND"]="$(build_command_string "${ssh_cmd[@]}")"
  fi

  local key
  for key in "${!AUTH_GIT_ENV_MAP[@]}"; do
    AUTH_GIT_ENVS+=("$key=${AUTH_GIT_ENV_MAP[$key]}")
  done
}

run_git() {
  if (( ${#AUTH_GIT_ENVS[@]} )); then
    env "${AUTH_GIT_ENVS[@]}" git "$@"
  else
    git "$@"
  fi
}

apply_environment_apps() {
  local env="$CFG_env" host="$CFG_host"
  declare -A added_paths=()
  local entry
  for entry in "${ENV_APP_RECORDS[@]}"; do
    IFS='|' read -r e_env e_host e_app e_dest e_strip e_path e_type e_path_dest <<<"$entry"
    [[ -n "$e_env" ]] || continue
    [[ "$e_env" == "$env" ]] || continue

    local host_match=0
    if [[ -z "$e_host" || "$e_host" == "*" || "$e_host" == "auto" ]]; then
      host_match=1
    elif [[ "$host" == "$e_host" ]]; then
      host_match=1
    elif [[ "$host" == $e_host ]]; then
      host_match=1
    fi
    (( host_match )) || continue

    local dest="$e_dest"
    [[ -n "$dest" ]] || dest="apps/$e_app"
    local idx
    ensure_app_entry "$e_app" "$dest"
    idx="$ENSURE_APP_LAST_IDX"
    APP_DESTS[$idx]="$dest"

    local type="$e_type"
    [[ -n "$type" ]] || type="auto"
    local strip="$e_strip"
    local path_dest="$e_path_dest"
    local key="$idx|$e_path|$type|$strip|$path_dest"
    if [[ -n "${added_paths[$key]:-}" ]]; then
      continue
    fi
    added_paths[$key]=1
    _add_source "$idx" "$e_path" "$type" "$strip" "$path_dest"
  done
}

determine_auth_effective_method() {
  local url="$CFG_remote_url"
  local method="$AUTH_method"
  local inline_credentials=0
  if [[ "$url" =~ ^https?://[^/@]+@ ]] || [[ "$url" =~ ^https?://[^/]*:[^@]+@ ]]; then
    inline_credentials=1
  fi

  if [[ -z "$method" ]]; then
    if [[ "$url" == git@* || "$url" == ssh://* ]]; then
      method="ssh"
    elif [[ "$url" =~ ^https?:// || "$url" =~ ^http:// ]]; then
      if (( inline_credentials )); then
        method="https_inline"
      elif [[ -n "$AUTH_token_file" || -n "$AUTH_token_inline" ]]; then
        method="https_token"
      elif [[ -n "$AUTH_netrc_file" || -f "$HOME/.netrc" ]]; then
        method="https_netrc"
      else
        method="https"
      fi
    else
      method="none"
    fi
  else
    case "$method" in
      https_token|token) method="https_token" ;;
      https_netrc|netrc) method="https_netrc" ;;
      https_inline|inline) method="https_inline" ;;
      ssh|ssh_key|deploy_key) method="ssh" ;;
      https) method="https" ;;
      none|manual) method="none" ;;
      *) ;;
    esac
  fi

  if [[ "$method" == "https" && (( inline_credentials )) ]]; then
    method="https_inline"
  fi

  AUTH_effective_method="$method"
}

redact_remote_url() {
  local url="$1"
  if [[ "$url" == git@* ]]; then
    echo "$url"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$url" <<'PY'
import sys
from urllib.parse import urlsplit, urlunsplit

url = sys.argv[1]
parts = urlsplit(url)
if not parts.scheme:
    print(url)
    sys.exit(0)
netloc = parts.netloc
if "@" in netloc:
    userinfo, hostpart = netloc.rsplit("@", 1)
    if ":" in userinfo:
        user, _ = userinfo.split(":", 1)
        userinfo = f"{user}:***"
    else:
        userinfo = f"{userinfo}:***"
    netloc = f"{userinfo}@{hostpart}"
print(urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment)))
PY
  else
    echo "$url"
  fi
}

: "${BYPASS_COOLDOWN:=0}"

# Parser YAML minimalista (formato estricto, 2 espacios por nivel)
# Soporta:
# - escalares al raíz: repo_path, remote_url, env, host, staging_path, cooldown
# - auth: method, username, token_file, token_inline
# - exclude: lista simple "- patrón"
# - paths: lista simple de rutas para snapshot directo
# - apps: - name, dest, sources: - path, type, strip_prefix
load_config_yaml() {
  local yaml="$1"
  [[ -f "$yaml" ]] || { err "No existe config YAML: $yaml"; return 1; }

  # Resetea arrays y vars
  EXCLUDES=(); WATCH_PATHS=(); PATHS=(); APP_NAMES=(); APP_DESTS=(); SRC_APPIDX=(); SRC_PATHS=(); SRC_TYPES=(); SRC_STRIPS=(); SRC_DESTS=()
  CFG_repo_path=""; CFG_remote_url=""; CFG_env="prod"; CFG_host=""; CFG_staging_path=""; CFG_repo_layout="hierarchical"
  CFG_cooldown_seconds=60; AUTH_method=""; AUTH_username=""; AUTH_token_file=""; AUTH_token_inline=""
  AUTH_netrc_file=""; AUTH_ssh_key_path=""; AUTH_ssh_known_hosts=""; AUTH_ssh_extra_args=""; AUTH_effective_method=""
  AUTH_GIT_ENV_MAP=(); AUTH_GIT_ENVS=(); ENV_APP_RECORDS=()

  # Procesa YAML con awk siguiendo indentación de 0/2/4/6/8 espacios
  # Emitimos llamadas a _add_* y asignaciones CFG_* / AUTH_*
  local AWK='
  function ltrim(s){ sub(/^[ \t\r\n]+/,"",s); return s }
  function rtrim(s){ sub(/[ \t\r\n]+$/,"",s); return s }
  function trim(s){ return rtrim(ltrim(s)) }
  function dequote(s){
    if (length(s) >= 2) {
      if (s ~ /^".*"$/ || s ~ /^'\''.*'\''$/) {
        return substr(s, 2, length(s)-2)
      }
    }
    return s
  }

  BEGIN{
    in_auth=0; in_excl=0; in_watch=0; in_paths=0; in_apps=0; have_app=0; in_sources=0;
    in_envs=0; in_env_hosts=0; in_env_apps=0; in_env_app_paths=0;
    current_env=""; current_host=""; env_app=""; env_app_dest=""; env_app_strip=""; env_app_type="";
    in_env_path_item=0; env_path=""; env_path_dest=""; env_path_strip=""; env_path_type="";
    app_idx=-1;
    src_path=""; src_type=""; src_strip=""; src_dest="";
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
      sub(/:$/, "", key)
      val=dequote(trim(substr(line, RLENGTH+1)))
    }

    # nivel 0
    if (indent==0) {
      in_auth=0; in_excl=0; in_watch=0; in_paths=0; in_apps=0;
      if (key=="repo_path")    { print "CFG_repo_path=\"" val "\"" }
      else if (key=="remote_url"){ print "CFG_remote_url=\"" val "\"" }
      else if (key=="env")     { print "CFG_env=\"" val "\"" }
      else if (key=="host")    { print "CFG_host=\"" val "\"" }
      else if (key=="staging_path"){ print "CFG_staging_path=\"" val "\"" }
      else if (key=="repo_layout") { print "CFG_repo_layout=\"" val "\"" }
      else if (key=="cooldown" || key=="cooldown_seconds"){ print "CFG_cooldown_seconds=" val }
      else if (key=="auth")    { in_auth=1 }
      else if (key=="exclude") { in_excl=1 }
      else if (key=="watch_paths") { in_watch=1 }
      else if (key=="paths") { in_paths=1 }
      else if (key=="apps")    { in_apps=1 }
      else if (key=="environments") {
        in_envs=1; current_env=""; current_host=""; in_env_hosts=0; in_env_apps=0; in_env_app_paths=0;
      } else {
        in_envs=0;
      }
      next
    }

    # nivel 2
    if (indent==2) {
      if (in_auth && key!="") {
        if (key=="method")      print "AUTH_method=\"" val "\""
        else if (key=="username")   print "AUTH_username=\"" val "\""
        else if (key=="token_file") print "AUTH_token_file=\"" val "\""
        else if (key=="token_inline") print "AUTH_token_inline=\"" val "\""
        else if (key=="netrc_file") print "AUTH_netrc_file=\"" val "\""
        else if (key=="ssh_key_path") print "AUTH_ssh_key_path=\"" val "\""
        else if (key=="ssh_known_hosts") print "AUTH_ssh_known_hosts=\"" val "\""
        else if (key=="ssh_extra_args") print "AUTH_ssh_extra_args=\"" val "\""
        next
      }
      if (in_watch && match(line, /^[ ]*-[ ]+/)) {
        pat=dequote(trim(substr(line, index(line,"-")+1)))
        print "_add_watch_path \"" pat "\""
        next
      }
      if (in_paths && match(line, /^[ ]*-[ ]+/)) {
        pat=dequote(trim(substr(line, index(line,"-")+1)))
        print "_add_path \"" pat "\""
        next
      }
      if (in_excl && match(line, /^[ ]*-[ ]+/)) {
        pat=dequote(trim(substr(line, index(line,"-")+1)))
        print "_add_exclude \"" pat "\""
        next
      }
    }

    if (in_envs) {
      if (in_env_app_paths && indent<=10) {
        if (env_app!="" && env_path!="") {
          print "__env_add_path \"" current_env "\" \"" current_host "\" \"" env_app "\" \"" env_app_dest "\" \"" env_path_strip "\" \"" env_path "\" \"" env_path_type "\" \"" env_path_dest "\""
        }
        env_path=""; env_path_dest=""; env_path_strip=""; env_path_type=""; in_env_path_item=0; in_env_app_paths=0;
      }
      if (indent==2 && key!="") {
        current_env=key; in_env_hosts=0; in_env_apps=0; in_env_app_paths=0;
        next
      }
      if (indent==4 && key=="hosts") {
        in_env_hosts=1; current_host=""; next
      }
      if (in_env_hosts && indent==6 && key!="") {
        current_host=key; in_env_apps=0; in_env_app_paths=0;
        next
      }
      if (indent==8 && key=="apps") {
        in_env_apps=1; env_app=""; env_app_dest=""; env_app_strip=""; env_app_type=""; in_env_app_paths=0;
        next
      }
      if (in_env_apps && indent==10 && key!="") {
        env_app=key; env_app_dest=""; env_app_strip=""; env_app_type=""; in_env_app_paths=0;
        next
      }
      if (in_env_apps && indent==12 && key!="") {
        if (key=="dest") { env_app_dest=val; next }
        else if (key=="strip_prefix") { env_app_strip=val; next }
        else if (key=="type") { env_app_type=val; next }
        else if (key=="paths") {
          in_env_app_paths=1; in_env_path_item=0;
          env_path=""; env_path_dest=""; env_path_strip=""; env_path_type="";
          next
        }
      }
      if (in_env_app_paths && env_app!="") {
        if (match(line, /^[ ]*-[ ]+/)) {
          if (env_path!="") {
            print "__env_add_path \"" current_env "\" \"" current_host "\" \"" env_app "\" \"" env_app_dest "\" \"" env_path_strip "\" \"" env_path "\" \"" env_path_type "\" \"" env_path_dest "\""
          }
          env_path=""; env_path_dest=""; env_path_strip=env_app_strip; env_path_type=env_app_type; in_env_path_item=1;
          entry=dequote(trim(substr(line, index(line,"-")+1)));
          if (entry!="" && entry ~ /^[^:]+:[ ]*/) {
            split(entry, kv, ":");
            ekey=trim(kv[1]);
            eval=trim(substr(entry, index(entry, ":")+1));
            eval=dequote(eval);
            if (ekey=="path" || ekey=="src") env_path=eval;
            else if (ekey=="dest") env_path_dest=eval;
            else if (ekey=="strip_prefix") env_path_strip=eval;
            else if (ekey=="type") env_path_type=eval;
          } else if (entry!="") {
            env_path=entry;
          }
          next
        }
        if (in_env_path_item && key!="") {
          if (key=="path" || key=="src") env_path=val;
          else if (key=="dest") env_path_dest=val;
          else if (key=="strip_prefix") env_path_strip=val;
          else if (key=="type") env_path_type=val;
          next
        }
      }
    }

    # apps
    if (in_apps) {
      # nueva app: "  - name: XXX"
      if (indent==2 && match(line, /^[ ]*-[ ]+name:[ ]*/)) {
        have_app=1; in_sources=0;
        app_idx++;
        aname=dequote(trim(substr(line, RLENGTH+1)))
        # necesitamos leer dest más abajo; por ahora vacío
        print "_add_app \"" aname "\" \"\""
        next
      }
      # propiedades de la app (indent 4)
      if (have_app && indent==4 && key!="") {
        if (key=="dest") {
          print "APP_DESTS[" app_idx "]=\"" val "\""
        } else if (key=="sources") {
          in_sources=1; src_path=""; src_type=""; src_strip=""; src_dest="";
        }
        next
      }
      # sources
      if (have_app && in_sources) {
        if (indent==6 && match(line, /^[ ]*-[ ]+path:[ ]*/)) {
          # si había un source acumulado, emítelo antes de empezar otro
          if (src_path!="") {
            print "_add_source " app_idx " \"" src_path "\" \"" src_type "\" \"" src_strip "\" \"" src_dest "\""
            src_path=""; src_type=""; src_strip=""; src_dest="";
          }
          src_path=dequote(trim(substr(line, RLENGTH+1))); next
        }
        if (indent==8 && key!="") {
          if (key=="type")        src_type=val;
          else if (key=="strip_prefix") src_strip=val;
          else if (key=="dest") src_dest=val;
          next
        }
        # si volvemos a indentación <=4, cerramos el último source
        if (indent<=4 && src_path!="") {
          print "_add_source " app_idx " \"" src_path "\" \"" src_type "\" \"" src_strip "\" \"" src_dest "\""
          src_path=""; src_type=""; src_strip=""; src_dest="";
          # y como hemos salido de sources, no hacemos next: dejar fluir a tratar nueva app/prop
        }
      }
    }
  }
  END{
    # emite el último source si quedó pendiente
    if (src_path!="") {
      print "_add_source " app_idx " \"" src_path "\" \"" src_type "\" \"" src_strip "\" \"" src_dest "\""
    }
    if (env_app!="" && env_path!="") {
      print "__env_add_path \"" current_env "\" \"" current_host "\" \"" env_app "\" \"" env_app_dest "\" \"" env_path_strip "\" \"" env_path "\" \"" env_path_type "\" \"" env_path_dest "\""
    }
  }'

  # Ejecutamos awk y evaluamos las llamadas generadas (_add_app/_add_source/variables)
  local __out
  __out="$(awk "$AWK" "$yaml")"
  eval "$__out"

  # Defaults
  [[ -z "$CFG_host" || "$CFG_host" == "auto" ]] && CFG_host="$(hostname -f 2>/dev/null || hostname)"
  [[ -z "$CFG_staging_path" ]] && CFG_staging_path="/var/lib/syncgitconfig/staging"

  local layout_lc="${CFG_repo_layout,,}"
  case "$layout_lc" in
    ""|hierarchical|default|env_host|nested)
      CFG_repo_layout="hierarchical"
      ;;
    flat|root)
      CFG_repo_layout="flat"
      ;;
    *)
      warn "repo_layout desconocido '$CFG_repo_layout'; usando 'hierarchical'."
      CFG_repo_layout="hierarchical"
      ;;
  esac

  determine_auth_effective_method
  apply_environment_apps

  if (( ${#APP_NAMES[@]} > 0 && ${#PATHS[@]} > 0 )); then
    warn "Se ignoran 'paths' (modo legacy) porque hay 'apps' declarados."
    PATHS=()
  fi
  if [[ "$CFG_repo_layout" == "flat" && ${#APP_NAMES[@]} -gt 0 && ${#WATCH_PATHS[@]} -gt 0 ]]; then
    warn "repo_layout=flat con 'apps' declarados: se ignoran 'watch_paths'."
    WATCH_PATHS=()
  fi

  configure_git_auth_environment
  return 0
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
  if (( BYPASS_COOLDOWN )); then
    now=$(date +%s)
    log "[INFO] Cooldown ignorado (--no-cooldown)."
    echo "$now" > "$COOLDOWN_FILE"
    return 0
  fi
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
    local display_remote
    display_remote="$(redact_remote_url "$remote")"
    log "Clonando repositorio remoto $display_remote en $repo"

    local -a git_clone_cmd=()
    if [[ "$AUTH_effective_method" == "https_token" && -n "$cred_file" ]]; then
      git_clone_cmd+=(-c "credential.helper=store --file=$cred_file")
    fi
    git_clone_cmd+=(clone "$remote" "$repo")

    if ! run_git "${git_clone_cmd[@]}" >>"$LOG_FILE" 2>&1; then
      err "git clone falló para $display_remote"
      return 1
    fi

    ok "Repositorio clonado en $repo"
  fi

  # Configura helper de credenciales si se indicó token_file
  if [[ "$AUTH_effective_method" == "https_token" && -n "$cred_file" ]]; then
    run_git -C "$repo" config credential.helper "store --file=$cred_file" || true
  fi
  # Verifica remoto
  local rurl
  rurl="$(run_git -C "$repo" remote get-url origin 2>/dev/null || echo "")"
  if [[ -z "$rurl" ]]; then
    run_git -C "$repo" remote add origin "$remote"
  fi
}

# Añade y comitea cambios si los hay; empuja si PUSH=true (por defecto)
git_commit_and_push() {
  local repo="$1" hostroot="$2" env="$3" host="$4" staging_root="${5:-}"
  local staging_changed="${6:-0}" staging_has_content="${7:-1}" app_tag="${8:-}"

  run_git -C "$repo" add -A "$hostroot"
  if run_git -C "$repo" diff --cached --quiet "$hostroot"; then
    if [[ -n "$staging_root" && "$staging_has_content" == 0 ]]; then
      warn "Sin cambios que comitear: staging ${staging_root} está vacío."
      log "[INFO] staging vacío. Usa 'syncgitconfig-seed' o ejecuta syncgitconfig-run --seed para generar un snapshot inicial."
    elif [[ "$staging_changed" == 0 ]]; then
      ok "Sin cambios que comitear: ${hostroot} ya coincide con staging."
    else
      ok "Sin cambios que comitear."
    fi
    return 0
  fi

  local msg="[auto][$env][$host]"
  [[ -n "$app_tag" ]] && msg="$msg[app:$app_tag]"
  msg="$msg snapshot @ $(ts)"
  run_git -C "$repo" -c user.name="Infra Backup Bot" -c user.email="infra-backup@${host}" commit -m "$msg" || true
  if ! run_git -C "$repo" push; then
    warn "git push falló (revisa credenciales/remoto)"
  fi
}
