# syncgitconfig

Backup granular de configuraciones por servidor, en Git, con staging y watcher inotify.

## Piezas
- Config YAML: `/etc/syncgitconfig/syncgitconfig.yaml`
- Credenciales (HTTPS token): `/etc/syncgitconfig/credentials/.git-credentials` (600)
- Binarios: `/opt/syncgitconfig/bin/*`
- Estado: `/var/lib/syncgitconfig`
- Logs: `/var/log/syncgitconfig`
- Servicios: `syncgitconfig.service`, `syncgitconfig-watch.service`

## Primeros pasos
1. Edita `syncgitconfig.yaml` (remote_url, repo_path, paths/apps, watch_paths).
2. Pon token en `token_inline` o en `.git-credentials`.
3. Ejecuta `/opt/syncgitconfig/bin/syncgitconfig-install`.
4. Sembrar snapshot inicial (opcional): `/opt/syncgitconfig/bin/syncgitconfig-seed`.
5. Verifica con `/opt/syncgitconfig/bin/syncgitconfig-status`.
