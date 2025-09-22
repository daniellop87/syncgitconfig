# syncgitconfig

Backup **granular** de configuraciones por **servidor** usando **Git** (HTTPS con token/`.netrc` o SSH con deploy key), con staging local y **watcher** basado en `inotify` para disparar commits automáticamente cuando hay cambios.

* **Modelo por host**: 1 repositorio por servidor (p. ej. `configs-n8n`, `configs-web01`).
* **Modelo por app**: agrupas rutas como “apps” (systemd, ssh, monitoring, …) declaradas por entorno/host.
* **Seguro**: excluyes secretos; token con permisos mínimos; sin `.git` en `/etc`.
* **Automático**: watcher + cooldown (60 s) para evitar tormentas de commits.

---

## Índice

* [Requisitos](#requisitos)
* [Arquitectura y rutas](#arquitectura-y-rutas)
* [Instalación rápida (recomendada)](#instalación-rápida-recomendada)
* [Configuración (`syncgitconfig.yaml`)](#configuración-syncgitconfigyaml)
* [Autenticación (HTTPS/SSH)](#autenticación-httpsssh)
* [Servicios systemd](#servicios-systemd)
* [Estructura del repo por servidor](#estructura-del-repo-por-servidor)
* [Operativa habitual](#operativa-habitual)
* [Buenas prácticas de seguridad](#buenas-prácticas-de-seguridad)
* [Solución de problemas](#solución-de-problemas)
* [Desinstalación](#desinstalación)
* [Licencia](#licencia)

---

## Requisitos

**Paquetes mínimos**
`git`, `rsync`, `inotify-tools`, `ca-certificates` (además de `bash`, `coreutils`, `systemd`).

> Debian/Ubuntu:
>
> ```bash
> apt-get update && apt-get install -y git rsync inotify-tools ca-certificates
> ```

**Acceso al remoto Git**
Salida a `https://` o `ssh://`/`git@` del servidor Git (Gitea/GitLab/GitHub Enterprise).

---

## Arquitectura y rutas

* **Config**: `/etc/syncgitconfig/`
* **Código**: `/opt/syncgitconfig/`
* **Estado**: `/var/lib/syncgitconfig/`
* **Logs**: `/var/log/syncgitconfig/`
* **Servicios**: `/etc/systemd/system/syncgitconfig*.service`

Staging y commit:

```
(origenes /etc/... )
   → /var/lib/syncgitconfig/staging/<env>/apps/<app>/…
   → /opt/configs-host/envs/<env>/apps/<app>/…
   → git add / commit / push (HTTPS o SSH según `auth.method`)
```

---

## Instalación rápida (recomendada)

1. **Copia el bundle** (este repo empaquetado con `opt/`, `etc/`, `var/`) al servidor y ejecuta:

```bash
chmod +x install.sh
sudo ./install.sh \
  --remote-url "https://gitea.example.local/ORG/configs-$(hostname -f).git" \
  --repo-path "/opt/configs-host" \
  --token "TU_TOKEN" \
  --env prod \
  --host auto \
  --non-interactive
```

2. **Verifica estado**:

```bash
/opt/syncgitconfig/bin/syncgitconfig-status
systemctl status syncgitconfig-watch.service --no-pager
tail -n 50 /var/log/syncgitconfig/syncgitconfig.log
```

> El instalador: instala paquetes (si puede), copia archivos (si detecta `./opt`, `./etc`), crea credenciales HTTPS, clona el repo local, habilita servicios y ejecuta la **primera pasada**.

---

## Configuración (`syncgitconfig.yaml`)

Archivo: `/etc/syncgitconfig/syncgitconfig.yaml` (el **único** que editas).

> ℹ️ Después de cambiar el YAML reinicia los servicios para que recojan la nueva configuración:
>
> ```bash
> sudo systemctl restart syncgitconfig.service
> sudo systemctl restart syncgitconfig-watch.service
> ```

```yaml
repo_path: /opt/configs-host
remote_url: https://gitea.example.local/ORG/configs-host.git
env: prod
host: auto
repo_layout: hierarchical     # hierarchical (env/apps, por defecto) | hierarchical_host (legado) | flat
staging_path: /var/lib/syncgitconfig/staging
cooldown_seconds: 60

environments:
  prod:
    hosts:
      auto:
        apps:
          systemd:
            paths:
              - /etc/systemd/system
              # - src: /etc/ssh/sshd_config
              #   dest: apps/ssh
              #   type: file
              #   strip_prefix: /etc/ssh
          # phpipam:
          #   paths:
          #     - /var/www/phpipam

# watch_paths:
#   - "/etc/systemd/system"

# paths:
#   - "/etc/systemd/system"

auth:
  method: https_token
  username: syncgit-bot
  token_file: /etc/syncgitconfig/credentials/.git-credentials
  # token_inline: "OPCIONAL: el instalador lo migrará y lo borrará de aquí"
  # method: https_netrc
  # netrc_file: /root/.netrc
  # method: ssh
  # ssh_key_path: /root/.ssh/id_ed25519
  # ssh_known_hosts: /etc/ssh/ssh_known_hosts

exclude:
  - "*.key"
  - "*.pem"
  - "id_*"
  - "secrets/**"
  - "*.p12"
  - "*.jks"
  - "*.srl"

# apps:
#   - name: systemd
#     dest: "apps/systemd"
#     sources:
#       - path: "/etc/systemd/system"
#         type: dir
#         strip_prefix: "/etc/systemd/system"
```

* `repo_layout` define si el árbol se crea bajo `envs/<env>/…` (`hierarchical`, por defecto), conserva el nivel `hosts/<host>` (`hierarchical_host`) o escribe directamente en la raíz del repo (`flat`).
* `environments.<env>.hosts.<host>.apps.<app>.paths` agrupa rutas bajo `apps/<app>` y acepta entradas simples o mapas `src`/`dest` para personalizar el destino relativo al repositorio.
* `watch_paths` indica qué rutas vigilar; si no se define se derivan de `paths`/`apps`. Con `repo_layout: flat` y rutas declaradas en `apps` se ignora automáticamente.
* `paths` crea snapshots planos bajo `paths/` (modo legacy sencillo) y admite directorios o archivos individuales.
* `apps[]` (formato clásico) sigue disponible para casos avanzados mezclando `dir` y `file` o para layout plano manual.

---

## Autenticación (HTTPS/SSH)

syncgitconfig soporta tres flujos sin intervención manual:

1. **HTTPS + token** (`auth.method: https_token`).
   * Guarda el token en `auth.token_file` (o usa `token_inline` en el YAML para bootstrap: el instalador lo migra y lo borra).
   * Los scripts configuran `git config credential.helper "store --file=…"` automáticamente.
   * Ejemplo de entrada: `https://syncgit-bot:TU_TOKEN@gitea.example.local/ORG/configs-host.git`.
2. **HTTPS + `.netrc`** (`auth.method: https_netrc`).
   * Usa la misma credencial que otros procesos (curl, ansible, etc.).
   * Puedes indicar un fichero concreto con `auth.netrc_file`; si no, se utiliza `~/.netrc`.
   * Se exporta `GIT_CURL_OPTS=--netrc(--file=…)` y `GIT_TERMINAL_PROMPT=0` para evitar prompts.
3. **SSH + deploy key** (`auth.method: ssh`).
   * `remote_url` admite `git@host:ORG/repo.git` o `ssh://`.
   * Opcionalmente define `auth.ssh_key_path`, `auth.ssh_known_hosts` o `auth.ssh_extra_args` para personalizar `GIT_SSH_COMMAND`.

> 💡 Si el `remote_url` ya incluye `https://usuario:token@…`, la detección automática lo tratará como `https_inline` y se evitarán prompts interactivos.

---

## Servicios systemd

* **Watcher** (inotify): `syncgitconfig-watch.service`
  Arranca al boot, monitoriza rutas de `apps[].sources`, aplica **cooldown 60 s** y ejecuta el run. Si staging y repo están vacíos lanza automáticamente `syncgitconfig-run --seed --no-cooldown` para generar el snapshot inicial.

* **One-shot** manual: `syncgitconfig.service`
  Ejecuta una pasada bajo demanda. Es de tipo *oneshot*: tras completarse aparece como `inactive (dead)` en `systemctl status`.

Comandos útiles:

```bash
systemctl enable --now syncgitconfig-watch.service
systemctl restart syncgitconfig-watch.service
systemctl start syncgitconfig.service
journalctl -u syncgitconfig-watch -e
```

---

## Estructura del repo por servidor

Checkout local (ej.: `/opt/configs-host`):

```
/opt/configs-host/
├─ .git/
└─ envs/
   └─ prod/
      └─ apps/
         ├─ systemd/…      # desde /etc/systemd/system
         ├─ ssh/…          # desde /etc/ssh o archivos sueltos
         └─ monitoring/…   # desde /etc/nagios
```

> Con `repo_layout: hierarchical_host` se conserva el nivel `hosts/<host>`. Con `repo_layout: flat` los archivos se almacenan directamente bajo la raíz del repositorio (p. ej. `apps/…`, `paths/…`).

---

## Operativa habitual

**Estado rápido**

```bash
/opt/syncgitconfig/bin/syncgitconfig-status
```

**Reconfigurar remoto/token sin reinstalar**

```bash
/opt/syncgitconfig/bin/syncgitconfig-reconfigure
```

**Forzar una pasada manual**

```bash
systemctl start syncgitconfig.service
```

> También puedes lanzar `/opt/syncgitconfig/bin/syncgitconfig-run --no-cooldown` para saltarte temporalmente la ventana de protección.

**Sembrar un snapshot inicial (SOURCES → STAGING)**

```bash
/opt/syncgitconfig/bin/syncgitconfig-seed
```

> Ejecuta `syncgitconfig-run --seed --no-cooldown` y copia todo el contenido de las rutas configuradas aunque staging/repo estén vacíos.

> ℹ️ Las ejecuciones de `syncgitconfig-run` comparan los destinos declarados (apps/paths/watch_paths) y eliminan automáticamente del *staging* y del repositorio las carpetas que ya no figuran en el YAML. Tras quitar una app o ruta basta con lanzar un run para purgar los restos antiguos.

**Logs**

```bash
tail -f /var/log/syncgitconfig/syncgitconfig.log
```

---

## Buenas prácticas de seguridad

* **Token** con scope mínimo (solo push al repo del host) y rotación periódica.
* **Nunca** incluyas secretos: usa `exclude` (ya trae patrones base).
* Permisos:

  * `/etc/syncgitconfig/credentials/.git-credentials` → `600`
  * `/var/lib/syncgitconfig` → `750`/`700`
  * `/var/log/syncgitconfig/syncgitconfig.log` → `640`
* Protege la rama `main` si trabajas con PRs; si haces push directo, limita el token a ese repo.

---

## Solución de problemas

* **No hay commits nuevos**
  Revisa `/var/log/syncgitconfig/syncgitconfig.log`. Asegúrate de que las rutas de `apps[].sources` **existen** y que el watcher está **activo**:

  ```bash
  systemctl is-active syncgitconfig-watch.service
  ```

  * Si aparece `[ERR] No hay rutas declaradas (apps/paths)`, añade rutas en el YAML (`apps`/`environments` o `paths`).
  * Si el log indica `[INFO] staging vacío...`, ejecuta `/opt/syncgitconfig/bin/syncgitconfig-seed` para generar el snapshot inicial.
  * Si ves avisos tipo `Detectadas N rutas ignoradas por .gitignore...`, elimina esos patrones del `.gitignore` del repo (o define exclusiones en el YAML). Git está descartando esos archivos y no llegarán al remoto hasta que lo ajustes.

* **Fallo TLS/CA al clonar o hacer pull**
  Importa la CA corporativa en el sistema (por ejemplo, copia el `.crt` a `/usr/local/share/ca-certificates/` y ejecuta `update-ca-certificates`). Utiliza `--insecure` únicamente como medida temporal.

* **`git push` pide credenciales / falla**
  Verifica `remote_url` y el contenido/permisos de `.git-credentials` (600).
  Comprueba conectividad HTTPS y CA.

* **Muchos commits pequeños**
  Sube `cooldown_seconds` (p. ej., 120 o 300).

* **Se subió algo sensible**
  Revierte commit, añade patrón a `exclude`, limpia el histórico si fuese necesario (BFG/`filter-repo`), y rota claves.

---

## Desinstalación

Usa el desinstalador empaquetado (`/opt/syncgitconfig/uninstall.sh`) para detener servicios y limpiar la instalación. Admite modo `--dry-run` y flags de purga:

```bash
sudo /opt/syncgitconfig/uninstall.sh --purge --purge-repo
```

* `--purge` borra también `/var/lib/syncgitconfig` (staging, lock, cooldown) y `/opt/logs/syncgitconfig`.
* `--purge-repo` elimina el checkout local indicado en `repo_path` cuando pertenece al host y contiene un `.git/`.

Si prefieres un asistente mínimo existe `/opt/syncgitconfig/bin/syncgitconfig-uninstall`, que sólo detiene servicios y pregunta si quieres borrar estado/logs.

---

## Licencia

MIT
