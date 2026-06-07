#!/usr/bin/env bash
# GBrain weekly upgrade & health check
# Runs every Sunday at 0300 UTC
#
# Strategy:
#   1. Checkout clean upstream/master
#   2. Apply patches/0001-cyrillic-slug.patch (Cyrillic in slugs)
#      Apply patches/0002-protect-yo-nfd.patch (protect й/ё from NFD)
#      Apply patches/0004-propose-takes-deepseek.patch (DeepSeek prompt)
#   3. Copy our own files (upgrade script + patches/) that don't exist in upstream
#   4. Commit as a release branch
#   5. Fast-forward master to release branch
#   6. Build, migrate, health check
#   7. Push to just4honey/gbrain
set -euo pipefail

GBRAIN_DIR="$HOME/apps/tools/gbrain"
ENV_FILE="$HOME/.gbrain/env"
LOG_FILE="/tmp/gbrain-weekly-upgrade.log"
FORK_REMOTE="origin"          # just4honey/gbrain
UPSTREAM_REMOTE="upstream"    # garrytan/gbrain
PATCHES_DIR="patches"

exec > "$LOG_FILE" 2>&1

echo "=== GBrain Weekly Upgrade: $(date -u '+%Y-%m-%d %H:%M:%S UTC') ===
"

# ---- 1. Load env ----
source "$ENV_FILE"

# ---- 2. Capture pre-upgrade state ----
cd "$GBRAIN_DIR"
PRE_VERSION=$(gbrain version 2>/dev/null || echo "unknown")
PRE_COMMIT=$(git rev-parse HEAD)
echo "Current version: $PRE_VERSION"
echo "Current commit:  $(git rev-parse --short "$PRE_COMMIT")
"

# Stash any local changes so they don't block
if [ -n "$(git status --porcelain)" ]; then
  echo "⚠️  Local changes detected, stashing..."
  git stash push -m "gbrain-weekly-auto-stash $(date -u '+%Y-%m-%d')"
  STASHED=true
else
  STASHED=false
fi

# ---- 3. Fetch remotes ----
echo "=== Fetching remotes ==="
git fetch "$UPSTREAM_REMOTE" 2>&1 || echo "⚠️  upstream fetch failed (non-fatal)"
git fetch "$FORK_REMOTE" 2>&1 || { echo "❌ fork fetch failed"; exit 1; }

LOCAL=$(git rev-parse HEAD)
UPSTREAM_HASH=$(git rev-parse "$UPSTREAM_REMOTE/master" 2>/dev/null || echo "")
UPSTREAM_SHORT=$(git rev-parse --short "$UPSTREAM_HASH" 2>/dev/null || echo "none")

PATCH_OK=0
PATCH_FAIL=0
UPGRADE_NEEDED=false

# ---- 4. Build release from upstream + patches ----
# We always build from upstream/master so our patches apply cleanly.
# If upstream hasn't changed, we skip (already up-to-date).
if [ -n "$UPSTREAM_HASH" ] && [ "$UPSTREAM_HASH" != "$LOCAL" ]; then
  if ! git merge-base --is-ancestor "$LOCAL" "$UPSTREAM_HASH" 2>/dev/null; then
    echo "⚠️  Upstream has diverged from our fork. Skipping."
  else
    echo "⬆️  Upstream has new commits $(git rev-parse --short "$LOCAL")..$UPSTREAM_SHORT"
    echo "=== Building release branch ==="

    RELEASE_BRANCH="release-$(date -u '+%Y%m%d')"
    git branch -D "$RELEASE_BRANCH" 2>/dev/null || true
    git checkout -b "$RELEASE_BRANCH" "$UPSTREAM_HASH"

    # --- Step A: Apply patches to upstream files ---
    for pf in "$PATCHES_DIR"/0001-*.patch "$PATCHES_DIR"/0002-*.patch "$PATCHES_DIR"/0004-*.patch; do
      [ -f "$pf" ] || continue
      pname=$(basename "$pf")
      echo "  Applying $pname..."
      if git am "$pf" 2>/dev/null; then
        echo "    ✅ $pname applied"
        PATCH_OK=$((PATCH_OK + 1))
      else
        git am --abort 2>/dev/null || true
        echo "    ⚠️  $pname FAILED — upstream changed these files, skipping"
        PATCH_FAIL=$((PATCH_FAIL + 1))
      fi
    done

    # --- Step B: Copy our own files (not in upstream) ---
    # These are files that exist in our fork but not in garrytan/gbrain
    # Currently: gbrain-weekly-upgrade.sh and patches/ directory
    OUR_FILES_COPIED=0
    if [ -f "$GBRAIN_DIR/gbrain-weekly-upgrade.sh" ]; then
      echo "  Copying gbrain-weekly-upgrade.sh..."
      cp "$GBRAIN_DIR/gbrain-weekly-upgrade.sh" /tmp/gbrain-weekly-upgrade-for-release.sh
      OUR_FILES_COPIED=$((OUR_FILES_COPIED + 1))
    fi

    # --- Step C: Commit our files ---
    if [ "$OUR_FILES_COPIED" -gt 0 ]; then
      cp /tmp/gbrain-weekly-upgrade-for-release.sh "$GBRAIN_DIR/gbrain-weekly-upgrade.sh"
      mkdir -p "$PATCHES_DIR"
      git add "$PATCHES_DIR" gbrain-weekly-upgrade.sh
      git commit -m "chore: add fork-specific files (upgrade script + patches)" 2>/dev/null || true
    fi

    # --- Step D: Merge into master ---
    git checkout master
    if git merge --ff-only "$RELEASE_BRANCH" 2>&1; then
      echo "✅ Merged (fast-forward)"
      UPGRADE_NEEDED=true
    else
      echo "⚠️  Fast-forward failed — doing 3-way merge"
      if git merge "$RELEASE_BRANCH" --no-edit 2>&1; then
        echo "✅ Merged (3-way)"
        UPGRADE_NEEDED=true
      else
        echo "❌ Merge failed — rolling back"
        git reset --hard "$PRE_COMMIT"
        exit 1
      fi
    fi

    git branch -D "$RELEASE_BRANCH" 2>/dev/null || true
  fi
else
  echo "Upstream at same commit ($UPSTREAM_SHORT) — no new changes."
fi

# ---- 5. Sync with fork remote (just4honey/gbrain) ----
NEW_LOCAL=$(git rev-parse HEAD)
FORK_HASH=$(git rev-parse "$FORK_REMOTE/master" 2>/dev/null || echo "")
if [ -n "$FORK_HASH" ] && [ "$FORK_HASH" != "$NEW_LOCAL" ]; then
  echo "⬆️  Fork has new commits, pulling..."
  if git pull --ff-only "$FORK_REMOTE" master 2>&1; then
    echo "✅ Fork pull succeeded"
    UPGRADE_NEEDED=true
  else
    echo "ℹ️  Our branch is ahead of fork — that's fine"
  fi
fi

# ---- 6. Install & build (if updated) ----
if [ "$UPGRADE_NEEDED" = false ]; then
  echo "Already up-to-date ($PRE_VERSION @ $(git rev-parse --short HEAD)).
"
else
  NEW_VERSION=$(gbrain version 2>/dev/null || echo "unknown")
  NEW_COMMIT=$(git rev-parse HEAD)
  echo "Upgraded: $PRE_VERSION → $NEW_VERSION ($(git rev-parse --short HEAD))
"

  echo "=== Running bun install ==="
  bun install 2>&1 || { echo "❌ bun install failed"; git reset --hard "$PRE_COMMIT"; exit 1; }
  echo "✅ bun install done"

  echo "
=== Running build ==="
  bun run build 2>&1 || { echo "❌ Build failed"; git reset --hard "$PRE_COMMIT"; exit 1; }
  echo "✅ Build done"

  echo "
=== Running DB migrations ==="
  gbrain apply-migrations --yes 2>&1 || { echo "⚠️  apply-migrations failed"; git reset --hard "$PRE_COMMIT"; exit 1; }
  echo "✅ Migrations done"
fi

# ---- 7. Push to our fork ----
PUSH_OK=false
FORK_REMOTE_URL=$(git remote get-url "$FORK_REMOTE" 2>/dev/null || echo "")
if echo "$FORK_REMOTE_URL" | grep -q "just4honey/gbrain"; then
  echo "
=== Pushing to just4honey/gbrain ==="
  if git push "$FORK_REMOTE" master 2>&1; then
    echo "✅ Push succeeded"
    PUSH_OK=true
  else
    echo "⚠️  Push failed (non-fatal — retries next week)"
  fi
fi

# ---- 8. Health check ----
echo "
=== Health check (gbrain doctor) ==="
DOCTOR_OUTPUT=$(gbrain doctor 2>&1) || true
echo "$DOCTOR_OUTPUT"

FAIL_COUNT=$(echo "$DOCTOR_OUTPUT" | grep -c "\[FAIL\]" || true)
WARN_COUNT=$(echo "$DOCTOR_OUTPUT" | grep -c "\[WARN\]" || true)
echo "
Health: $FAIL_COUNT FAIL, $WARN_COUNT WARN"

# ---- 9. Summary ----
echo "
=== Summary ==="
FINAL_VERSION=$(gbrain version 2>/dev/null || echo "unknown")
FINAL_COMMIT=$(git rev-parse HEAD)
echo "  Version: $PRE_VERSION → $FINAL_VERSION"
echo "  Commit:  $(git rev-parse --short "$PRE_COMMIT") → $(git rev-parse --short "$FINAL_COMMIT")"
if [ "$PRE_COMMIT" != "$FINAL_COMMIT" ]; then
  echo "  Result:  UPDATED ✅"
else
  echo "  Result:  UP-TO-DATE ✅"
fi
echo "  Health:  $FAIL_COUNT FAIL, $WARN_COUNT WARN"
echo "  Patches: $PATCH_OK applied, $PATCH_FAIL skipped"
[ "$PUSH_OK" = true ] && echo "  Pushed:  ✅" || echo "  Pushed:  —"

# Restore stash if needed
if [ "$STASHED" = true ] && [ "$PRE_COMMIT" != "$FINAL_COMMIT" ]; then
  git stash pop || true
fi

echo "
=== Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
