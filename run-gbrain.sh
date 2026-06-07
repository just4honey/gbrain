#!/usr/bin/env bash
set -euo pipefail

export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
source "$HOME/.gbrain/env"

VAULT="/home/just4honey/apps/Obsidian/myVault"

# gbrain sync — использует git last_commit, импортирует только новые/изменённые файлы
/home/just4honey/.local/bin/gbrain sync --skip-failed --no-pull --repo "$VAULT" --no-embed 2>&1

# embed --stale — эмбеддит только чанки без эмбеддинга (реально новые)
/home/just4honey/.local/bin/gbrain embed --stale 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done"
