#!/bin/bash
# Downloads the official Codex pet sprite sheets used for GPT/Codex sessions.
# They are not committed to this repository (© OpenAI); this fetches them from
# the agent-notch project, which mirrors them.
#
# The app runs fine without them — Codex sessions fall back to the pixel mascot.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="Sources/VibeIsland/Resources/pets"
BASE="https://raw.githubusercontent.com/realfishsam/agent-notch/main/pets"
PETS=(codex dewey fireball rocky seedy stacky bsod null-signal)

mkdir -p "$DEST"
for pet in "${PETS[@]}"; do
    printf 'fetching %s… ' "$pet"
    if curl -fsSL "$BASE/pet-$pet.webp" -o "$DEST/pet-$pet.webp"; then
        echo "ok"
    else
        echo "FAILED (skipping)"
    fi
done
echo "Done. Rebuild with ./scripts/make-app.sh"
