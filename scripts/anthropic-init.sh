#!/usr/bin/env bash
#
# Anthropic Remote Environment init script for jetbrains-just-plugin.
#
# Goal: warm every cache the build needs so later agent sessions are fast and
# can build with no network. Safe to re-run (idempotent).
#
# IMPORTANT — how to wire this up:
#   Configure the remote environment to RUN THE COMMITTED FILE, e.g.:
#       bash scripts/anthropic-init.sh
#   Do NOT paste the script body into the setup box: pasting mangles it and
#   breaks repo-path detection (this is what failed the first attempt).
#
# Pre-fetched into the snapshot (under $GRADLE_USER_HOME and the repo dir):
#   * JDK 17, pinned for Gradle and persisted to shell profiles
#   * Gradle 8.6 wrapper distribution
#   * IntelliJ IDEA Ultimate 2024.2.6 (~1.3 GB)
#   * marketplace plugins (PsiViewer, com.jetbrains.sh, JavaScript)
#   * all Maven Central deps + Kotlin / GrammarKit / Changelog plugins
#   * generated lexer/parser sources (src/main/gen)
#   * compiled main + test classes
#   * the `just` CLI (best-effort)

set -euo pipefail

# --------------------------------------------------------------------------- #
# Logging helpers
# --------------------------------------------------------------------------- #

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[ok] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }

# run: a core step. If it fails, the whole init fails (env build is marked
# broken loudly instead of snapshotting cold caches).
run() {
  local desc="$1"; shift
  log "$desc"
  "$@" || die "step failed: $desc"
  ok "$desc"
}

# try: an optional step. Failure logs a warning and continues.
try() {
  local desc="$1"; shift
  log "$desc"
  if "$@"; then ok "$desc"; else warn "optional step failed (continuing): $desc"; fi
}

# --------------------------------------------------------------------------- #
# Locate the repository (must contain ./gradlew). Hard-fail otherwise so we
# never silently run in the wrong directory with a cold cache.
# --------------------------------------------------------------------------- #

find_repo() {
  local d
  # 1. Explicit env hints used by various remote-agent runtimes.
  for d in "${ANTHROPIC_PROJECT_DIR:-}" "${PROJECT_DIR:-}" "${REPO_DIR:-}" \
           "${GITHUB_WORKSPACE:-}" "${CLAUDE_PROJECT_DIR:-}"; do
    [ -n "$d" ] && [ -x "$d/gradlew" ] && { echo "$d"; return; }
  done
  # 2. The directory this script lives in (when executed as a file).
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    [ -n "$d" ] && [ -x "$d/gradlew" ] && { echo "$d"; return; }
  fi
  # 3. Git toplevel from the current directory.
  d="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$d" ] && [ -x "$d/gradlew" ] && { echo "$d"; return; }
  # 4. Walk up from CWD looking for gradlew.
  d="$PWD"
  while [ "$d" != "/" ]; do
    [ -x "$d/gradlew" ] && { echo "$d"; return; }
    d="$(dirname "$d")"
  done
  return 1
}

REPO_DIR="$(find_repo || true)"
[ -n "$REPO_DIR" ] || die "Could not locate the repo (no ./gradlew found). \
Run this as: bash scripts/anthropic-init.sh from the cloned repo."
cd "$REPO_DIR"
log "Repository: $REPO_DIR"
chmod +x ./gradlew 2>/dev/null || true

export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
export GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.daemon=false"
GRADLE_ARGS=(--no-daemon --console=plain --stacktrace)
START_TS=$(date +%s)

# --------------------------------------------------------------------------- #
# Persist an env var into the shell profiles so it survives into later
# (fresh) agent sessions, not just this init process.
# --------------------------------------------------------------------------- #

persist_env() {
  local line="$1" f
  for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    touch "$f"
    grep -qxF "$line" "$f" 2>/dev/null || echo "$line" >> "$f"
  done
}

# --------------------------------------------------------------------------- #
# 1. Ensure a JDK 17 is installed, then PIN it (the build targets Java 17 and
#    IntelliJ 2024.2 needs JDK 17; the remote env ships Java 21).
# --------------------------------------------------------------------------- #

locate_jdk17() {
  local base c
  for base in /usr/lib/jvm /opt/java /opt/jdk /Library/Java/JavaVirtualMachines \
              "$HOME/.sdkman/candidates/java"; do
    [ -d "$base" ] || continue
    c="$(find "$base" -maxdepth 2 -type d \( -name '*-17-*' -o -name '*17*' \) 2>/dev/null \
         | grep -vi '17[0-9]' | head -1 || true)"
    [ -n "$c" ] && { [ -d "$c/Contents/Home" ] && c="$c/Contents/Home"; echo "$c"; return; }
  done
  if [ -x /usr/libexec/java_home ]; then
    c="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
    [ -n "$c" ] && { echo "$c"; return; }
  fi
  return 1
}

JAVA17="$(locate_jdk17 || true)"
if [ -z "$JAVA17" ] && command -v apt-get >/dev/null 2>&1; then
  log "Installing OpenJDK 17 via apt"
  SUDO=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"
  $SUDO apt-get update -y || warn "apt-get update failed"
  $SUDO apt-get install -y openjdk-17-jdk || warn "apt-get install openjdk-17-jdk failed"
  JAVA17="$(locate_jdk17 || true)"
fi

if [ -n "$JAVA17" ]; then
  export JAVA_HOME="$JAVA17"
  export PATH="$JAVA_HOME/bin:$PATH"
  persist_env "export JAVA_HOME=\"$JAVA17\""
  persist_env "export PATH=\"$JAVA17/bin:\$PATH\""
  ok "JDK 17: $JAVA17"
  "$JAVA17/bin/java" -version 2>&1 | sed 's/^/     /'
else
  warn "Could not obtain a JDK 17 — Gradle will run on the system JDK ($(java -version 2>&1 | head -1)). The build may fail."
fi

# --------------------------------------------------------------------------- #
# 2. Gradle properties: tune memory/caching AND pin the JDK so every later
#    Gradle invocation (in fresh agent shells) uses 17 regardless of env vars.
# --------------------------------------------------------------------------- #

mkdir -p "$GRADLE_USER_HOME"
PROPS="$GRADLE_USER_HOME/gradle.properties"
MARKER="# managed-by: anthropic-init.sh"
[ -f "$PROPS" ] && ! grep -qF "$MARKER" "$PROPS" && cp "$PROPS" "$PROPS.bak.$(date +%s)"
{
  echo "$MARKER"
  echo "org.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8"
  echo "org.gradle.caching=true"
  echo "org.gradle.parallel=true"
  echo "org.gradle.daemon=false"
  [ -n "$JAVA17" ] && echo "org.gradle.java.home=$JAVA17"
} > "$PROPS"
persist_env "export GRADLE_USER_HOME=\"$GRADLE_USER_HOME\""
ok "Wrote $PROPS"

# --------------------------------------------------------------------------- #
# 3. Core cache warm — these MUST succeed or the snapshot is useless.
# --------------------------------------------------------------------------- #

run "Download Gradle 8.6 wrapper distribution" \
  ./gradlew "${GRADLE_ARGS[@]}" --version

run "Generate lexer & parser (GrammarKit)" \
  ./gradlew "${GRADLE_ARGS[@]}" generateLexer generateParser

run "Build plugin (IntelliJ IDEA + plugins + deps, then compile + assemble)" \
  ./gradlew "${GRADLE_ARGS[@]}" buildPlugin

run "Compile test sources (warm test classpath)" \
  ./gradlew "${GRADLE_ARGS[@]}" compileTestKotlin compileTestJava testClasses

try "Resolve full test dependency graph" \
  ./gradlew "${GRADLE_ARGS[@]}" dependencies --configuration testRuntimeClasspath

# --------------------------------------------------------------------------- #
# 4. Best-effort: install the `just` CLI (this is a plugin for `just`).
# --------------------------------------------------------------------------- #

install_just() {
  command -v just >/dev/null 2>&1 && { ok "just present: $(just --version)"; return 0; }
  mkdir -p "$HOME/.local/bin"
  curl -fsSL https://just.systems/install.sh | bash -s -- --to "$HOME/.local/bin" >/dev/null 2>&1 || return 1
  export PATH="$HOME/.local/bin:$PATH"
  persist_env 'export PATH="$HOME/.local/bin:$PATH"'
  ok "Installed just: $("$HOME/.local/bin/just" --version 2>/dev/null || echo unknown)"
}
try "Install just CLI" install_just

# --------------------------------------------------------------------------- #
# 5. Hard verification: assert the snapshot is actually warm. Fail loudly if
#    not, so a cold environment is never silently accepted.
# --------------------------------------------------------------------------- #

log "Verifying warm caches under $GRADLE_USER_HOME"
CACHES="$GRADLE_USER_HOME/caches"
assert_cached() {
  find "$CACHES" "$GRADLE_USER_HOME/wrapper" -path "*$1*" 2>/dev/null | grep -q . \
    || die "cache MISS for '$1' — the snapshot would be cold. See errors above."
  ok "cached: $1"
}
assert_cached "gradle-8.6"                         # wrapper distribution
assert_cached "org.jetbrains.kotlin.jvm.gradle.plugin"  # the plugin that failed before
assert_cached "com.jetbrains.intellij.idea"        # the ~1.3 GB IDE
[ -d src/main/gen/org/mvnsearch ] || die "src/main/gen was not generated"
ok "src/main/gen generated"

# --------------------------------------------------------------------------- #
# 6. Offline sanity check (non-fatal). Note: the gradlew *wrapper* bootstrap
#    re-checks services.gradle.org, but since the distro is cached in
#    $GRADLE_USER_HOME/wrapper/dists it is NOT re-downloaded.
# --------------------------------------------------------------------------- #

try "Offline build (proves caches are warm)" \
  ./gradlew "${GRADLE_ARGS[@]}" --offline buildPlugin -q

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #

ELAPSED=$(( $(date +%s) - START_TS ))
log "Init complete in ${ELAPSED}s."
echo "  REPO_DIR         : $REPO_DIR"
echo "  GRADLE_USER_HOME : $GRADLE_USER_HOME   <-- must be in the env snapshot"
echo "  JAVA_HOME        : ${JAVA_HOME:-<system default>}"
du -sh "$GRADLE_USER_HOME" 2>/dev/null | sed 's/^/  gradle cache size: /' || true
echo "  Built artifact   : $(ls build/distributions/*.zip 2>/dev/null | head -1 || echo '<none>')"
