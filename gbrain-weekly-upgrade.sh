#!/usr/bin/env bash
# GBrain weekly upgrade & health check
# Runs every Sunday at 0300 UTC
set -euo pipefail

GBRAIN_DIR="$HOME/apps/tools/gbrain"
ENV_FILE="$HOME/.gbrain/env"
LOG_FILE="/tmp/gbrain-weekly-upgrade.log"
FORK_REMOTE="origin"      # just4honey/gbrain (наш форк с патчами)
UPSTREAM_REMOTE="upstream" # garrytan/gbrain (оригинал)

exec > "$LOG_FILE" 2>&1

echo "=== GBrain Weekly Upgrade: $(date -u '+%Y-%m-%d %H:%M:%S UTC') ===\n"

# ---- 1. Load env ----
source "$ENV_FILE"

# ---- 2. Capture pre-upgrade state ----
cd "$GBRAIN_DIR"
PRE_VERSION=$(gbrain version 2>/dev/null || echo "unknown")
PRE_COMMIT=$(git rev-parse HEAD)
echo "Current version: $PRE_VERSION"
echo "Current commit:  $PRE_COMMIT\n"

# Stash any local changes so they don't block pull
if [ -n "$(git status --porcelain)" ]; then
  echo "⚠️  Local changes detected, stashing..."
  git stash push -m "gbrain-weekly-auto-stash $(date -u '+%Y-%m-%d')"
  STASHED=true
else
  STASHED=false
fi

# ---- 3. Check for update ----
echo "=== Checking for updates ==="
echo "Fork remote: $FORK_REMOTE (just4honey/gbrain — наши патчи)"
echo "Upstream:    $UPSTREAM_REMOTE (garrytan/gbrain — оригинал)"

git fetch "$UPSTREAM_REMOTE" 2>&1 || echo "⚠️  upstream fetch failed (non-fatal)"
git fetch "$FORK_REMOTE" 2>&1 || { echo "❌ fork fetch failed"; exit 1; }

LOCAL=$(git rev-parse HEAD)
FORK_REMOTE_HASH=$(git rev-parse "$FORK_REMOTE/master" 2>/dev/null || echo "")
UPSTREAM_HASH=$(git rev-parse "$UPSTREAM_REMOTE/master" 2>/dev/null || echo "")

UPGRADE_NEEDED=false

# Проверяем upstream (garrytan/gbrain) — есть ли новые коммиты
if [ -n "$UPSTREAM_HASH" ] && [ "$UPSTREAM_HASH" != "$LOCAL" ]; then
  if git merge-base --is-ancestor "$LOCAL" "$UPSTREAM_HASH" 2>/dev/null; then
    echo "⬆️  Upstream has new commits: $LOCAL → $UPSTREAM_HASH"
    echo "Merging upstream changes (fast-forward)..."
    if git merge --ff-only "$UPSTREAM_REMOTE/master" 2>&1; then
      echo "✅ Upstream merge succeeded"
      UPGRADE_NEEDED=true
    else
      echo "⚠️  Diverged — upstream has changes that conflict with our fork."
      echo "   Skipping upstream this week; local patches preserved."
    fi
  fi
fi

# Проверяем форк (just4honey/gbrain) — есть ли новые коммиты
NEW_LOCAL=$(git rev-parse HEAD)
if [ -n "$FORK_REMOTE_HASH" ] && [ "$FORK_REMOTE_HASH" != "$NEW_LOCAL" ]; then
  echo "⬆️  Fork has new commits, pulling..."
  if git pull --ff-only "$FORK_REMOTE" master 2>&1; then
    echo "✅ Fork pull succeeded"
    UPGRADE_NEEDED=true
  else
    echo "❌ Fork pull failed, rolling back..."
    git reset --hard "$PRE_COMMIT"
    exit 1
  fi
fi

# ---- 4. Install & migrate (если были обновления) ----
if [ "$UPGRADE_NEEDED" = false ]; then
  echo "Already up-to-date ($PRE_VERSION @ $PRE_COMMIT).\n"
  echo "=== Running health check (no update needed) ==="
else
  NEW_VERSION=$(gbrain version 2>/dev/null || echo "unknown")
  NEW_COMMIT=$(git rev-parse HEAD)
  echo "\nUpgraded: $PRE_VERSION ($PRE_COMMIT) → $NEW_VERSION ($NEW_COMMIT)\n"

  echo "=== Running bun install ==="
  if bun install 2>&1; then
    echo "✅ bun install succeeded"
  else
    echo "❌ bun install failed, rolling back..."
    git reset --hard "$PRE_COMMIT"
    if [ "$STASHED" = true ]; then
      git stash pop || true
    fi
    exit 1
  fi

  echo "\n=== Running DB migrations ==="
  if gbrain apply-migrations --yes 2>&1; then
    echo "✅ Migrations applied"
  else
    echo "⚠️  apply-migrations failed"
    git reset --hard "$PRE_COMMIT"
    if [ "$STASHED" = true ]; then
      git stash pop || true
    fi
    exit 1
  fi
fi

# ---- 5. Health check ----
echo "\n=== Health check (gbrain doctor) ==="
DOCTOR_OUTPUT=$(gbrain doctor 2>&1) || true
echo "$DOCTOR_OUTPUT"

FAIL_COUNT=$(echo "$DOCTOR_OUTPUT" | grep -c "\[FAIL\]" || true)
WARN_COUNT=$(echo "$DOCTOR_OUTPUT" | grep -c "\[WARN\]" || true)
echo "\nHealth summary: $FAIL_COUNT FAIL, $WARN_COUNT WARN"

# ---- 6. Final status ----
echo "\n=== Final status ==="
FINAL_VERSION=$(gbrain version 2>/dev/null || echo "unknown")
FINAL_COMMIT=$(git rev-parse HEAD)

echo "\n=== Summary ==="
echo "  Version: $PRE_VERSION → $FINAL_VERSION"
if [ "$PRE_COMMIT" != "$FINAL_COMMIT" ]; then
  echo "  Commit:  $PRE_COMMIT → $FINAL_COMMIT"
  echo "  Result:  UPDATED ✅"
else
  echo "  Commit:  $PRE_COMMIT (unchanged)"
  echo "  Result:  UP-TO-DATE ✅"
fi
echo "  Health:  $FAIL_COUNT failures, $WARN_COUNT warnings"

# Restore stash if update happened successfully
if [ "$STASHED" = true ] && [ "$PRE_COMMIT" != "$FINAL_COMMIT" ]; then
  git stash pop || true
fi

echo "\n=== Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
