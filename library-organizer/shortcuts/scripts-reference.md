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
