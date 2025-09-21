# syncgitconfig

Backup **granular** de configuraciones por **servidor** usando **Git** (HTTPS + token), con staging local y **watcher** basado en `inotify` para disparar commits automáticamente cuando hay cambios.

* **Modelo por host**: 1 repositorio por servidor (p. ej. `configs-n8n`, `configs-web01`).
* **Modelo por app**: agrupas rutas como “apps” (systemd, ssh, monitoring, …).
* **Seguro**: excluyes secretos; token con permisos mínimos; sin `.git` en `/etc`.
* **Automático**: watcher + cooldown (60 s) para evitar tormentas de commits.

---

## Índice

* [Requisitos](#requisitos)
* [Arquitectura y rutas](#arquitectura-y-rutas)
* [Instalación rápida (recomendada)](#instalación-rápida-recomendada)
* [Configuración (`syncgitconfig.yaml`)](#configuración-syncgitconfigyaml)
* [Autenticación (HTTPS + token)](#autenticación-https--token)
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
Salida a `https://` del servidor Git (Gitea/GitLab/GitHub Enterprise).

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
   → /var/lib/syncgitconfig/staging/<host>/apps/<app>/… 
   → /opt/configs-host/envs/<env>/hosts/<host>/apps/<app>/…
   → git add / commit / push (HTTPS + token)
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

```yaml
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
  # token_inline: "OPCIONAL: el instalador lo migrará y lo borrará de aquí"

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

  # - name: ssh
  #   dest: "apps/ssh"
  #   sources:
  #     - path: "/etc/ssh/sshd_config"
  #       type: file
  #       strip_prefix: "/etc/ssh"

  # - name: monitoring
  #   dest: "apps/monitoring"
  #   sources:
  #     - path: "/etc/nagios"
  #       type: dir
  #       strip_prefix: "/etc/nagios"
```

* `apps[]` permite **carpetas completas** (`type: dir`) o **archivos sueltos** (`type: file`).
* `strip_prefix` **recorta** el prefijo del origen para dejar una jerarquía limpia bajo `dest`.

---

## Autenticación (HTTPS + token)

**Opción A (recomendada)**: archivo de credenciales (git-credential-store):

* `/etc/syncgitconfig/credentials/.git-credentials` (permisos `600`)
* El instalador y los scripts configuran:

  ```
  git -C /opt/configs-host config credential.helper "store --file=/etc/syncgitconfig/credentials/.git-credentials"
  ```
* Contenido de ejemplo:

  ```
  https://syncgit-bot:TU_TOKEN@gitea.example.local/ORG/configs-host.git
  ```

**Opción B**: `auth.token_inline` en el YAML (solo bootstrap). El instalador lo migra a `.git-credentials` y **lo elimina** del YAML.

---

## Servicios systemd

* **Watcher** (inotify): `syncgitconfig-watch.service`
  Arranca al boot, monitoriza rutas de `apps[].sources`, aplica **cooldown 60 s** y ejecuta el run.

* **One-shot** manual: `syncgitconfig.service`
  Ejecuta una pasada bajo demanda.

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
      └─ hosts/
         └─ <host-fqdn>/
            └─ apps/
               ├─ systemd/…      # desde /etc/systemd/system
               ├─ ssh/…          # desde /etc/ssh o archivos sueltos
               └─ monitoring/…   # desde /etc/nagios
```

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

* **`git push` pide credenciales / falla**
  Verifica `remote_url` y el contenido/permisos de `.git-credentials` (600).
  Comprueba conectividad HTTPS y CA.

* **Muchos commits pequeños**
  Sube `cooldown_seconds` (p. ej., 120 o 300).

* **Se subió algo sensible**
  Revierte commit, añade patrón a `exclude`, limpia el histórico si fuese necesario (BFG/`filter-repo`), y rota claves.

---

## Desinstalación

Detener servicios y (opcionalmente) limpiar estado/logs:

```bash
/opt/syncgitconfig/bin/syncgitconfig-uninstall
```

> No borra ni el **repo** ni la **config** a menos que lo hagas explícitamente.

---

## Licencia

MIT
