# syncgitconfig

Backup granular de configuraciones por servidor, en Git (HTTPS/SSH), con staging y watcher inotify.

## Piezas
- Config YAML: `/etc/syncgitconfig/syncgitconfig.yaml`
- Autenticación: token (`auth.token_file`), `.netrc` (`auth.method: https_netrc`) o clave SSH (`auth.method: ssh`).
- Binarios: `/opt/syncgitconfig/bin/*`
- Estado: `/var/lib/syncgitconfig`
- Logs: `/var/log/syncgitconfig`
- Servicios: `syncgitconfig.service`, `syncgitconfig-watch.service`

## Primeros pasos
1. Edita `syncgitconfig.yaml` (remote_url, repo_path, bloque `environments`/`apps`).
2. Define credenciales (`auth.method`: `https_token`, `https_netrc` o `ssh`).
3. Ejecuta `/opt/syncgitconfig/bin/syncgitconfig-install`.
4. Sembrar snapshot inicial (opcional): `/opt/syncgitconfig/bin/syncgitconfig-seed`.
5. Verifica con `/opt/syncgitconfig/bin/syncgitconfig-status`.

## Notas

- Cada ejecución de `syncgitconfig-run` contrasta los destinos configurados y elimina del staging/repositorio las carpetas que ya no aparecen en el YAML (apps, paths o watch_paths). Tras quitar una app o ruta basta con lanzar un run para que desaparezca del repo.
- Para desinstalar usa `sudo /opt/syncgitconfig/uninstall.sh --purge --purge-repo` si necesitas una limpieza total (estado, logs y repo local). El script acepta `--dry-run` para revisar qué se borrará y comprueba que `repo_path` pertenezca al host antes de eliminarlo.
