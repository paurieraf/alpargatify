#!/usr/bin/env bash
# Sign every unsigned *.shortcut in this folder into *.signed.shortcut (macOS).
set -euo pipefail
cd "$(dirname "$0")"
for f in *.shortcut; do
    case "$f" in *.signed.shortcut) continue ;; esac
    out="${f%.shortcut}.signed.shortcut"
    shortcuts sign --mode people-who-know-me --input "$f" --output "$out"
    echo "$out"
done
