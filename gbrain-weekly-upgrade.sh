#!/usr/bin/env bash
# GBrain weekly upgrade & health check
# Runs every Sunday at 0300 UTC
set -euo pipefail

GBRAIN_DIR="$HOME/apps/tools/gbrain"
ENV_FILE="$HOME/.gbrain/env"
LOG_FILE="/tmp/gbrain-weekly-upgrade.log"

exec > "$LOG_FILE" 2>&1

echo "=== GBrain Weekly Upgrade: $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
echo ""

# ---- 1. Load env ----
source "$ENV_FILE"

# ---- 2. Capture pre-upgrade state ----
cd "$GBRAIN_DIR"
PRE_VERSION=$(gbrain version 2>/dev/null || echo "unknown")
PRE_COMMIT=$(git rev-parse HEAD)
echo "Current version: $PRE_VERSION"
echo "Current commit:  $PRE_COMMIT"
echo ""

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
git fetch origin 2>&1 || { echo "❌ git fetch failed"; exit 1; }

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse @{upstream} 2>/dev/null || echo "")

if [ "$LOCAL" = "$REMOTE" ] || [ -z "$REMOTE" ]; then
  echo "Already up-to-date ($PRE_VERSION @ $PRE_COMMIT)."
  echo ""
  echo "=== Running health check (no update needed) ==="
else
  echo "Update available: $LOCAL -> $REMOTE"
  echo ""
  echo "=== Running upgrade ==="
  
  # Pull (uses upstream tracking: origin/master)
  if git pull --ff-only 2>&1; then
    echo "✅ git pull succeeded"
  else
    echo "❌ git pull failed"
    # Rollback
    echo "=== Rolling back ==="
    git reset --hard "$PRE_COMMIT"
    if [ "$STASHED" = true ]; then
      git stash pop || true
    fi
    exit 1
  fi
  
  # Install deps
  echo "Running bun install..."
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
  
  NEW_VERSION=$(gbrain version 2>/dev/null || echo "unknown")
  NEW_COMMIT=$(git rev-parse HEAD)
  echo ""
  echo "Upgraded: $PRE_VERSION ($PRE_COMMIT) → $NEW_VERSION ($NEW_COMMIT)"
  
  # Run DB migrations
  echo ""
  echo "=== Running DB migrations ==="
  if gbrain apply-migrations --yes 2>&1; then
    echo "✅ Migrations applied"
  else
    echo "⚠️  apply-migrations failed, trying gbrain upgrade..."
    if gbrain upgrade 2>&1; then
      echo "✅ gbrain upgrade completed"
      NEW_VERSION=$(gbrain version 2>/dev/null || echo "unknown")
      echo "Final version: $NEW_VERSION"
    else
      echo "❌ gbrain upgrade also failed, rolling back..."
      git reset --hard "$PRE_COMMIT"
      bun install 2>&1
      if [ "$STASHED" = true ]; then
        git stash pop || true
      fi
      exit 1
    fi
  fi
fi

# ---- 4. Health check ----
echo ""
echo "=== Health check (gbrain doctor) ==="
# Run doctor, capture all warnings/errors
DOCTOR_OUTPUT=$(gbrain doctor 2>&1) || true
echo "$DOCTOR_OUTPUT"

# Count failures
FAIL_COUNT=$(echo "$DOCTOR_OUTPUT" | grep -c "\[FAIL\]" || true)
WARN_COUNT=$(echo "$DOCTOR_OUTPUT" | grep -c "\[WARN\]" || true)
echo ""
echo "Health summary: $FAIL_COUNT FAIL, $WARN_COUNT WARN"

# ---- 5. Verify sync still works ----
echo ""
echo "=== Sync verification ==="
SYNC_OUTPUT=$(gbrain sync --skip-failed --no-pull --repo "$HOME/apps/Obsidian/myVault" --no-embed 2>&1) || true
echo "$SYNC_OUTPUT" | tail -10

if echo "$SYNC_OUTPUT" | grep -qi "error\|fail"; then
  echo "⚠️  Sync reported issues (non-critical)"
fi

# ---- 6. Status summary ----
echo ""
echo "=== Final status ==="
FINAL_VERSION=$(gbrain version 2>/dev/null || echo "unknown")
FINAL_COMMIT=$(git rev-parse HEAD)

gbrain status 2>&1

echo ""
echo "=== Summary ==="
echo "  Version: $PRE_VERSION → $FINAL_VERSION"
if [ "$PRE_COMMIT" != "$FINAL_COMMIT" ]; then
  echo "  Commit:  $PRE_COMMIT → $FINAL_COMMIT"
  echo "  Result:  UPDATED ✅"
else
  echo "  Commit:  $PRE_COMMIT (unchanged)"
  echo "  Result:  UP-TO-DATE ✅"
fi
echo "  Health:  $FAIL_COUNT failures, $WARN_COUNT warnings"

# Restore stash if not rolled back
if [ "$STASHED" = true ] && [ "$PRE_COMMIT" != "$FINAL_COMMIT" ] && [ "$(git rev-parse HEAD)" != "$PRE_COMMIT" ]; then
  git stash pop || true
fi

echo ""
echo "=== Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
