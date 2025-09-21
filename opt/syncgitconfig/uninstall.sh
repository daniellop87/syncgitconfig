#!/usr/bin/env bash
# uninstall.sh - Desinstala syncgitconfig del sistema

set -e

echo "== Desinstalando syncgitconfig =="

# 1. Parar y deshabilitar servicios
echo "-> Parando servicios systemd..."
systemctl stop syncgitconfig-watch.service 2>/dev/null || true
systemctl disable syncgitconfig-watch.service 2>/dev/null || true
systemctl stop syncgitconfig-sync.service 2>/dev/null || true
systemctl disable syncgitconfig-sync.service 2>/dev/null || true

# 2. Eliminar unidades systemd
echo "-> Eliminando unidades de systemd..."
rm -f /etc/systemd/system/syncgitconfig-*.service
systemctl daemon-reload

# 3. Eliminar binarios y scripts
echo "-> Eliminando directorio de instalación /opt/syncgitconfig..."
rm -rf /opt/syncgitconfig

# 4. Eliminar configuración y logs
echo "-> Eliminando configuración y logs..."
rm -rf /etc/syncgitconfig
rm -rf /opt/logs/syncgitconfig

echo "✅ syncgitconfig ha sido desinstalado completamente."

# 5. Borrarse a sí mismo
SCRIPT_PATH="$(realpath "$0")"
if [ -f "$SCRIPT_PATH" ]; then
    echo "-> Eliminando el propio script de desinstalación..."
    rm -f "$SCRIPT_PATH"
fi
