# Shortcuts — Run Shell Script bodies

Cada shortcut es un Quick Action (Finder) que:
- Recibe **Carpetas y Archivos**
- Acción **Ejecutar script de shell**, Shell = `/bin/zsh`, **Pasar entrada = como argumentos**
- Abre Terminal (`.command`) corriendo el script del proyecto

> IMPORTANTE: "Pasar entrada" DEBE estar en **como argumentos** (no "a stdin").
> Duplicar un shortcut que ya lo tiene así lo hereda.

Requisitos:
- Sync completo / Sync interactivo: **Docker Desktop corriendo** + share SMB montado en `/Volumes/usb-hdd-wd-5tb`
- Conversor temporal: `opusenc` (`brew install opus-tools`)

Rutas (definidas dentro de `sync-lossless.sh`, override con `SMB_BASE`/`SMB_LOSSLESS`/`SMB_LOSSY`):
- Lossless = `/Volumes/usb-hdd-wd-5tb/musicbucket/navidrome_library_flac`
- Lossy   = `/Volumes/usb-hdd-wd-5tb/musicbucket/navidrome_library`
- Inbox por defecto (fallback sin input) = `/Volumes/usb-hdd-wd-5tb/musicbucket/navidrome_inbox`
- Backup: no hay copia FLAC adicional en disco — la maneja rclone en el host PVE.

OJO: sync-lossless BORRA (rm -rf) cada subcarpeta fuente tras organizar OK. Comportamiento normal (vacía el inbox).
Si beets no importa el álbum (Skip interactivo, duplicado, sin match, error) la carpeta se MUEVE a
`navidrome_inbox_failed/` en vez de borrarse.

---

## 1. Sync completo  → sync-lossless.sh -o -j 2

SRC = carpeta **inbox padre** con álbumes dentro (tu comando manual).
Si no recibe input, usa el inbox por defecto.

```zsh
SCRIPT="$HOME/dev/workspace/alpargatify/library-organizer/sync-lossless.sh"
DEFAULT_INBOX="/Volumes/usb-hdd-wd-5tb/musicbucket/navidrome_inbox"

args=("$@")
if [ ${#args[@]} -eq 0 ]; then
  while IFS= read -r line; do [ -n "$line" ] && args+=("$line"); done
fi
if [ ${#args[@]} -eq 0 ]; then
  if [ -d "$DEFAULT_INBOX" ]; then
    args+=("$DEFAULT_INBOX")
  else
    echo "No input folder received and default inbox not found: $DEFAULT_INBOX" >&2
    exit 1
  fi
fi

launcher="/tmp/sync-lossless-$$.command"
{
  echo '#!/bin/zsh'
  echo 'echo "=== Sync completo (sync-lossless -o -j 2) ==="'
  for SRC in "${args[@]}"; do
    SRC="${SRC%/}"
    printf 'echo "\n>>> %q"\n' "$SRC"
    printf '%q -o -j 2 %q\n' "$SCRIPT" "$SRC"
  done
  echo 'echo "\n=== ALL DONE ==="'
  echo 'read "?Press Return to close..."'
} > "$launcher"
chmod +x "$launcher"
open "$launcher"
```

---

## 2. Sync interactivo  → sync-lossless.sh -i -o -j 1

Igual que Sync completo pero con `-i` (prompts de beets para resolver matches a mano).
`-j 1` obligatorio: los prompts interactivos no se pueden paralelizar.
Necesita TTY — el `.command` en Terminal.app lo proporciona.

```zsh
SCRIPT="$HOME/dev/workspace/alpargatify/library-organizer/sync-lossless.sh"
DEFAULT_INBOX="/Volumes/usb-hdd-wd-5tb/musicbucket/navidrome_inbox"

args=("$@")
if [ ${#args[@]} -eq 0 ]; then
  while IFS= read -r line; do [ -n "$line" ] && args+=("$line"); done
fi
if [ ${#args[@]} -eq 0 ]; then
  if [ -d "$DEFAULT_INBOX" ]; then
    args+=("$DEFAULT_INBOX")
  else
    echo "No input folder received and default inbox not found: $DEFAULT_INBOX" >&2
    exit 1
  fi
fi

launcher="/tmp/sync-interactivo-$$.command"
{
  echo '#!/bin/zsh'
  echo 'echo "=== Sync interactivo (sync-lossless -i -o -j 1) ==="'
  for SRC in "${args[@]}"; do
    SRC="${SRC%/}"
    printf 'echo "\n>>> %q"\n' "$SRC"
    printf '%q -i -o -j 1 %q\n' "$SCRIPT" "$SRC"
  done
  echo 'echo "\n=== ALL DONE ==="'
  echo 'read "?Press Return to close..."'
} > "$launcher"
chmod +x "$launcher"
open "$launcher"
```

---

## 3. Conversor temporal  → flac-to-lossy → /tmp/lossy-temp/<álbum>

Sin Docker ni SMB: solo convierte FLAC → Opus localmente.

```zsh
SCRIPT="$HOME/dev/workspace/alpargatify/library-organizer/flac-to-lossy.sh"
BASEDEST="/tmp/lossy-temp"

args=("$@")
if [ ${#args[@]} -eq 0 ]; then
  while IFS= read -r line; do [ -n "$line" ] && args+=("$line"); done
fi
if [ ${#args[@]} -eq 0 ]; then
  echo "No input folder received" >&2
  exit 1
fi

launcher="/tmp/conversor-temporal-$$.command"
{
  echo '#!/bin/zsh'
  echo 'echo "=== Conversor temporal (flac-to-lossy) ==="'
  for SRC in "${args[@]}"; do
    SRC="${SRC%/}"
    DEST="$BASEDEST/$(basename "$SRC")"
    printf 'echo "\n>>> %q"\n' "$SRC"
    printf '%q %q %q\n' "$SCRIPT" "$SRC" "$DEST"
  done
  echo 'echo "\n=== ALL DONE ==="'
  echo 'read "?Press Return to close..."'
} > "$launcher"
chmod +x "$launcher"
open "$launcher"
```

---

## DEPRECATED — Importador / Organizador / Organizador en paralelo (wrapper.sh)

No crear estos shortcuts: `wrapper.sh` y `parallel-wrapper.sh` exportan `DEST_PATH`
al docker-compose de beets, que hace **bind-mount de la ruta destino en el contenedor**.
Docker en macOS no puede bind-montar shares SMB, así que cualquier destino en
`/Volumes/usb-hdd-wd-5tb/...` falla ("error while creating mount source path").
Por eso `sync-lossless.sh` fue reescrito (jul 2026) con staging local + rsync.

Estos modos quedan cubiertos por los shortcuts 1 y 2 de arriba:
- Importar FLAC directo (--import-only) → `Sync completo` (organiza lossless + lossy en una pasada)
- Convertir + importar a lossy     → `Sync completo`
- Procesar varios álbumes a la vez → `Sync completo` (usa `-j` internamente, parallel-wrapper)
- Matching manual de beets         → `Sync interactivo`

---

## macOS — barra de menús y vista de todos

- **Ver todos:** app Atajos → barra lateral "Todos los atajos" (o carpeta propia, p.ej. "Alpargatify"). Terminal: `shortcuts list`.
- **Barra de menús:** app Atajos → seleccionar atajo → panel **Detalles** (icono ⓘ arriba a la derecha) → marcar **Fijar en la barra de menús**. Aparece en el icono de Atajos de la barra de menús. Si el icono no sale: Atajos → Ajustes → General → "Mostrar en la barra de menús".
- Lanzados desde la barra de menús (sin carpeta de entrada) usan el inbox por defecto.
- Otras vías: mismo panel → **Usar como Acción rápida** (Finder/Servicios) y **Añadir atajo de teclado**.

---

## iOS — ejecución en el server (LXC 101) por SSH

Ficheros en `shortcuts/ios/` (generados con `build.py`, firmados con `sign.sh`). Usan la acción
**Ejecutar script por SSH** contra `root@10.1.1.101` (alcanzable vía Tailscale, subnet router LXC 104).
También aparecen en el Mac vía iCloud.

**Alpargatify** (el principal, guiado) — menú con los pasos en orden:

| Paso | Qué hace |
|---|---|
| 1. Moure àlbums a l'inbox | lista FLAC de slskd/torrents → elegir (multi) → mover; al acabar ofrece "2. Llançar el sync automàtic ara" |
| 2. Llançar sync automàtic | `sync.sh auto` (tmux en el server, vuelve al instante) |
| 3. Veure progrés | `status.sh`: fase 1/3–3/3, álbumes hechos/total, tiempo, últimas líneas |
| 4. Àlbums fallits | `status.sh failed`: cada álbum en `navidrome_inbox_failed/` y su motivo |
| 5. Reintentar fallits | devuelve los elegidos al inbox y copia al portapapeles el comando del modo interactivo |
| Com funciona? | texto con el orden y qué hace cada paso |

Sueltos (para Siri / widgets): **Mou a inbox**, **Sync server**, **Estat sync**.

Control de errores: cada comando remoto termina en `2>&1 || true` (la acción SSH siempre devuelve la salida);
si la salida contiene `ERROR` el atajo muestra una alerta con el mensaje y se detiene. Lista vacía → alerta "Res a moure".
El progreso no se empuja al móvil: se consulta con "3. Veure progrés" / "Estat sync".

Primera importación: abrir cada acción SSH → Autenticación **Clave SSH** → copiar la clave pública
y añadirla a `/root/.ssh/authorized_keys` de LXC 101 (todas las acciones del dispositivo comparten clave).

Interactivo desde el móvil: app SSH (Termius/Blink) →
`ssh root@10.1.1.101 /opt/alpargatify/library-organizer/server/sync.sh interactive`. Si se corta la conexión, repetir el comando: re-attach a tmux.
