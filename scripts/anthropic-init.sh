#!/usr/bin/env bash
#
# Anthropic Remote Environment init script for jetbrains-just-plugin.
#
# Goal: warm every cache the build needs so that later agent runs are fast and
# can work with little or no network access. Safe to run more than once
# (idempotent); each step is best-effort and logged.
#
# What it pre-fetches into the environment snapshot:
#   * a JDK 17 (the build targets Java 17 and IntelliJ 2024.2 needs JDK 17)
#   * the Gradle 8.6 wrapper distribution
#   * IntelliJ IDEA Ultimate 2024.2.6 (~1.3 GB, downloaded by the IntelliJ plugin)
#   * marketplace plugins (PsiViewer, com.jetbrains.sh, JavaScript)
#   * all Maven Central dependencies + Kotlin / GrammarKit / Changelog toolchains
#   * generated lexer/parser sources (src/main/gen)
#   * compiled main + test classes (Gradle build cache)
#   * the `just` CLI itself (best-effort, handy for this plugin)
#
# Everything is cached under $GRADLE_USER_HOME (~/.gradle) and the repo dir,
# both of which persist in the environment snapshot.

set -euo pipefail

# --------------------------------------------------------------------------- #
# Setup & helpers
# --------------------------------------------------------------------------- #

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
export GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.daemon=false"
# --no-daemon: a daemon would not survive into the snapshot anyway, and we want
# a clean process tree when the snapshot is taken.
GRADLE_ARGS=(--no-daemon --console=plain --stacktrace)

START_TS=$(date +%s)

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*"; }
step() {
  local desc="$1"; shift
  log "$desc"
  if "$@"; then
    printf '\033[1;32m[ok] %s\033[0m\n' "$desc"
  else
    warn "step failed (continuing): $desc"
    return 0
  fi
}

# --------------------------------------------------------------------------- #
# 1. Ensure a JDK 17 is available and selected
# --------------------------------------------------------------------------- #

select_jdk17() {
  # Already on 17?
  if command -v java >/dev/null 2>&1; then
    local cur
    cur="$(java -version 2>&1 | head -1 | grep -oE '"1?[0-9]+' | tr -d '"' | head -1 || true)"
    if [ "${cur:-}" = "17" ] && [ -n "${JAVA_HOME:-}" ]; then
      log "JDK 17 already active: $JAVA_HOME"
      return 0
    fi
  fi

  # Look for an installed JDK 17 in the usual places.
  local candidate=""
  for base in /usr/lib/jvm /opt/java /opt/jdk /Library/Java/JavaVirtualMachines "$HOME/.sdkman/candidates/java"; do
    [ -d "$base" ] || continue
    candidate="$(find "$base" -maxdepth 2 -type d -name '*17*' 2>/dev/null | head -1 || true)"
    [ -n "$candidate" ] && break
  done
  # macOS layout
  if [ -z "$candidate" ] && [ -x /usr/libexec/java_home ]; then
    candidate="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
  fi

  # Try to install Temurin/OpenJDK 17 if nothing found and we can use apt.
  if [ -z "$candidate" ] && command -v apt-get >/dev/null 2>&1; then
    log "No JDK 17 found; attempting apt install of OpenJDK 17"
    local SUDO=""
    [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"
    $SUDO apt-get update -y >/dev/null 2>&1 || true
    $SUDO apt-get install -y openjdk-17-jdk >/dev/null 2>&1 || true
    candidate="$(find /usr/lib/jvm -maxdepth 1 -type d -name '*17*' 2>/dev/null | head -1 || true)"
  fi

  if [ -n "$candidate" ]; then
    if [ -d "$candidate/Contents/Home" ]; then candidate="$candidate/Contents/Home"; fi
    export JAVA_HOME="$candidate"
    export PATH="$JAVA_HOME/bin:$PATH"
    log "Using JDK 17 at $JAVA_HOME"
  else
    warn "Could not find or install JDK 17 — falling back to system java:"
    java -version 2>&1 | sed 's/^/       /' || true
    warn "The build targets Java 17; if it fails, install a JDK 17 in the environment."
  fi
}
select_jdk17

# --------------------------------------------------------------------------- #
# 2. Tune Gradle for the environment (memory + caching)
# --------------------------------------------------------------------------- #

write_gradle_props() {
  mkdir -p "$GRADLE_USER_HOME"
  local props="$GRADLE_USER_HOME/gradle.properties"
  local marker="# managed-by: anthropic-init.sh"
  if [ -f "$props" ] && grep -qF "$marker" "$props"; then
    log "Gradle properties already configured: $props"
    return 0
  fi
  [ -f "$props" ] && cp "$props" "$props.bak.$(date +%s)"
  cat > "$props" <<EOF
$marker
org.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8
org.gradle.caching=true
org.gradle.parallel=true
org.gradle.configureondemand=false
org.gradle.daemon=false
EOF
  # Deliberately NOT setting org.gradle.java.home: we rely on JAVA_HOME/PATH so
  # the same snapshot stays portable.
  log "Wrote $props"
}
write_gradle_props

chmod +x ./gradlew 2>/dev/null || true

# --------------------------------------------------------------------------- #
# 3. Pre-fetch the Gradle wrapper distribution (gradle 8.6)
# --------------------------------------------------------------------------- #

step "Download Gradle 8.6 wrapper distribution" \
  ./gradlew "${GRADLE_ARGS[@]}" --version

# --------------------------------------------------------------------------- #
# 4. Generate lexer/parser sources (downloads JFlex + Grammar-Kit)
# --------------------------------------------------------------------------- #

step "Generate lexer & parser (GrammarKit)" \
  ./gradlew "${GRADLE_ARGS[@]}" generateLexer generateParser

# --------------------------------------------------------------------------- #
# 5. Full plugin build — the big cache warm.
#    Pulls IntelliJ IDEA IU 2024.2.6, marketplace plugins, every dependency,
#    then compiles and assembles the distribution zip.
# --------------------------------------------------------------------------- #

step "Build plugin (downloads IntelliJ IDEA + plugins + deps, then compiles)" \
  ./gradlew "${GRADLE_ARGS[@]}" buildPlugin

# --------------------------------------------------------------------------- #
# 6. Warm test compilation & resolve test dependencies
# --------------------------------------------------------------------------- #

step "Compile test sources (warm test classpath)" \
  ./gradlew "${GRADLE_ARGS[@]}" compileTestKotlin compileTestJava testClasses

step "Resolve full dependency graph" \
  ./gradlew "${GRADLE_ARGS[@]}" dependencies --configuration testRuntimeClasspath

# --------------------------------------------------------------------------- #
# 7. Best-effort: install the `just` CLI (this is a plugin for `just`)
# --------------------------------------------------------------------------- #

install_just() {
  if command -v just >/dev/null 2>&1; then
    log "just already installed: $(just --version)"
    return 0
  fi
  mkdir -p "$HOME/.local/bin"
  if curl -fsSL https://just.systems/install.sh \
       | bash -s -- --to "$HOME/.local/bin" >/dev/null 2>&1; then
    export PATH="$HOME/.local/bin:$PATH"
    log "Installed just: $("$HOME/.local/bin/just" --version 2>/dev/null || echo unknown)"
  else
    warn "Could not install the just CLI (non-fatal)."
  fi
}
step "Install just CLI" install_just

# --------------------------------------------------------------------------- #
# 8. Offline sanity check — proves the caches are warm enough to build offline
# --------------------------------------------------------------------------- #

log "Offline sanity check: ./gradlew buildPlugin --offline"
if ./gradlew "${GRADLE_ARGS[@]}" --offline buildPlugin -q; then
  printf '\033[1;32m[ok] Offline build succeeded — caches are warm.\033[0m\n'
else
  warn "Offline build failed; some artifacts may still require network at run time."
fi

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #

ELAPSED=$(( $(date +%s) - START_TS ))
log "Init complete in ${ELAPSED}s."
echo "  GRADLE_USER_HOME : $GRADLE_USER_HOME"
echo "  JAVA_HOME        : ${JAVA_HOME:-<system default>}"
du -sh "$GRADLE_USER_HOME" 2>/dev/null | sed 's/^/  gradle cache size: /' || true
echo "  Built artifact   : $(ls build/distributions/*.zip 2>/dev/null | head -1 || echo '<none>')"
