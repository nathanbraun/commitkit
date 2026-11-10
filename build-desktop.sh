#!/usr/bin/env bash
# Pull every repo the desktop app needs, assemble its .env, and build
# CommitKit.app. Meant for a second Mac (the laptop) that has fallen behind.
#
#   ./build-desktop.sh                 # sync + build
#   ./build-desktop.sh --install       # ...then replace /Applications/CommitKit.app
#   ./build-desktop.sh --no-pull       # build what's on disk
#   ./build-desktop.sh --env-from Nathans-Mac-mini.local   # scp the .env over ssh
#
# The desktop's .env is gitignored. Sources, first match wins per key:
#   1. an existing commitkit-desktop/.env
#   2. --env-from HOST: copies that host's commitkit-desktop/.env first
#   3. Railway (server service): GOOGLE_DESKTOP_CLIENT_ID, GOOGLE_DESKTOP_CLIENT_SECRET,
#      STRIPE_PUBLISHABLE_KEY (needs `railway login` + `railway link` in this dir)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP="$ROOT/commitkit-desktop"
ENV_FILE="$DESKTOP/.env"
GH="git@github.com:nathanbraun"
# Everything the desktop build touches: Cargo path deps + the bundled monitor.
REPOS="commitkit-desktop commitkit-eval commitkit-rules commitkit-data commitkit-monitor"
# Worth keeping current on the same pass (the `commit` CLI shares the desktop DB).
EXTRA_REPOS="commitkit-cli"

ORIG_ARGS=("$@")
PULL=1 INSTALL=0 ENV_FROM="" EXT_CHANGED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-pull) PULL=0 ;;
    --install) INSTALL=1 ;;
    --env-from) ENV_FROM="${2:?--env-from needs a host}"; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

bold() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- toolchain -------------------------------------------------------------
bold "Checking toolchain"
# Non-interactive bash doesn't get zshrc's PATH; add the usual install spots
# as fallbacks *after* the inherited PATH, so a stale /usr/local/bin/node (old
# nodejs.org pkg install) can't shadow the shell's nvm node.
for d in "$HOME/.cargo/bin" "${PNPM_HOME:-$HOME/Library/pnpm}" /opt/homebrew/bin /usr/local/bin; do
  [ -d "$d" ] && PATH="$PATH:$d"
done
# Next 16 needs node >= 20.9 (and Homebrew's corepack, which serves pnpm, dies
# on < 18.17 with "URL.canParse is not a function"). If the node on PATH is
# missing or older, fall back to the newest nvm-installed one.
node_major() { node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/'; }
if [ "$(node_major || echo 0)" -lt 20 ] 2>/dev/null || ! command -v node >/dev/null; then
  if [ -d "$HOME/.nvm/versions/node" ]; then
    PATH="$(ls -d "$HOME"/.nvm/versions/node/*/bin | sort -V | tail -1):$PATH"
  fi
fi
export PATH
xcode-select -p >/dev/null 2>&1 || die "Xcode command line tools missing: xcode-select --install"
command -v cargo >/dev/null || die "cargo missing: install rustup (https://rustup.rs)"
command -v node  >/dev/null || die "node missing (nvm install 22 && nvm alias default 22)"
[ "$(node_major)" -ge 20 ] || die "node $(node -v) is too old; Next 16 needs >= 20.9 (nvm install 22 && nvm alias default 22)"
command -v pnpm  >/dev/null || die "pnpm missing: corepack enable pnpm  (or npm i -g pnpm)"
if ! cargo tauri --version >/dev/null 2>&1; then
  echo "tauri-cli missing; installing (a few minutes, once)"
  cargo install tauri-cli --version '^2' --locked
fi
echo "rust $(rustc --version | cut -d' ' -f2), node $(node -v), pnpm $(pnpm -v), $(cargo tauri --version)"

# --- repos -----------------------------------------------------------------
sync_repo() {  # $1 = dir name under ROOT
  local name="$1" dir="$ROOT/$1"
  [ "$name" = . ] && name="commitkit (root)"
  if [ ! -d "$dir/.git" ]; then
    echo "$name: cloning"
    git clone -q "$GH/$name.git" "$dir"
    return
  fi
  # next build / next dev each rewrite next-env.d.ts's import path; that flip
  # alone shouldn't count as local work and block the pull.
  if [ "$name" = commitkit-desktop ] && \
     [ "$(git -C "$dir" status --porcelain --untracked-files=no)" = " M next-env.d.ts" ]; then
    git -C "$dir" checkout -q -- next-env.d.ts
  fi
  local branch; branch="$(git -C "$dir" branch --show-current)"
  if [ "$branch" != "main" ]; then
    warn "$name is on '$branch', not main; leaving it alone"; return
  fi
  if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
    warn "$name has uncommitted changes; leaving it alone"; return
  fi
  local before; before="$(git -C "$dir" rev-parse --short HEAD)"
  if ! git -C "$dir" pull -q --ff-only; then
    warn "$name: can't fast-forward (local commits?); building what's there"; return
  fi
  local after; after="$(git -C "$dir" rev-parse --short HEAD)"
  if [ "$before" = "$after" ]; then echo "$name: up to date ($after)"
  else echo "$name: $before -> $after ($(git -C "$dir" rev-list --count "$before..$after") commits)"; fi
  if [ "$name" = commitkit-monitor ] && [ "$before" != "$after" ] && \
     ! git -C "$dir" diff --quiet "$before" "$after" -- chrome-extension firefox-extension; then
    EXT_CHANGED=1
  fi
}

if [ "$PULL" = 1 ]; then
  bold "Syncing repos"
  # The root repo first: if this script changed, rerun the new copy.
  self_before="$(shasum "$0" | cut -d' ' -f1)"
  sync_repo .
  if [ "$(shasum "$0" | cut -d' ' -f1)" != "$self_before" ]; then
    echo "build-desktop.sh changed upstream; re-running it"
    exec "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  fi
  for r in $REPOS $EXTRA_REPOS; do sync_repo "$r"; done
else
  for r in $REPOS; do [ -d "$ROOT/$r" ] || die "$r missing and --no-pull given"; done
fi

# --- .env ------------------------------------------------------------------
bold "Assembling commitkit-desktop/.env"
env_get() { [ -f "$ENV_FILE" ] && sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | tr -d '"' || true; }
env_set() {  # replace or append KEY=VALUE, quoting like the original file
  local tmp; tmp="$(mktemp)"
  { [ -f "$ENV_FILE" ] && grep -v "^$1=" "$ENV_FILE" || true; echo "$1=\"$2\""; } > "$tmp"
  mv "$tmp" "$ENV_FILE"; chmod 600 "$ENV_FILE"
}

if [ -n "$ENV_FROM" ] && [ ! -f "$ENV_FILE" ]; then
  echo "copying .env from $ENV_FROM"
  scp -q "$ENV_FROM:code/github.com/nathanbraun/commitkit/commitkit-desktop/.env" "$ENV_FILE" \
    || warn "scp from $ENV_FROM failed; falling back to Railway + prompt"
fi

railway_json=""
railway_var() {
  if [ -z "$railway_json" ]; then
    command -v railway >/dev/null || return 1
    railway_json="$(cd "$ROOT" && railway variable list --service commitkit-screentime-server --json 2>/dev/null)" \
      || { railway_json=""; return 1; }
  fi
  printf '%s' "$railway_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$1',''))"
}

[ -n "$(env_get API_BASE_URL)" ] || env_set API_BASE_URL "https://api.commitkit.com"

for pair in GOOGLE_DESKTOP_CLIENT_ID:GOOGLE_DESKTOP_CLIENT_ID \
            GOOGLE_DESKTOP_CLIENT_SECRET:GOOGLE_DESKTOP_CLIENT_SECRET \
            NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY:STRIPE_PUBLISHABLE_KEY; do
  key="${pair%%:*}" rkey="${pair##*:}"
  [ -n "$(env_get "$key")" ] && continue
  val="$(railway_var "$rkey" || true)"
  [ -n "$val" ] || die "$key not in .env and couldn't read $rkey from Railway (railway login; railway link --project CommitKit --environment production)"
  env_set "$key" "$val"; echo "$key: from Railway"
done

# The payment form's key must be the same Stripe mode as the server's secret key.
pk="$(env_get NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY)"
case "$pk" in pk_test_*) warn "NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY is a test key; the prod server is live, so adding a card will fail" ;; esac
for k in API_BASE_URL GOOGLE_DESKTOP_CLIENT_ID GOOGLE_DESKTOP_CLIENT_SECRET NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY; do
  echo "  $k: set"
done

# Next only reads .env for NEXT_PUBLIC_*; build.rs reads it for the Google pair.
# Export everything so both see the same values regardless of cwd.
set -a; . "$ENV_FILE"; set +a

# --- signing ---------------------------------------------------------------
bold "Signing identity"
identity="${APPLE_SIGNING_IDENTITY:-$(python3 -c "import json; print(json.load(open('$DESKTOP/src-tauri/tauri.conf.json'))['bundle']['macOS'].get('signingIdentity',''))")}"
if [ -n "$identity" ] && security find-identity -v -p codesigning | grep -qF "\"$identity\""; then
  echo "$identity"
else
  warn "'$identity' isn't in this Mac's keychain; building ad-hoc signed."
  warn "Screen Recording / Accessibility grants won't survive rebuilds. For a stable"
  warn "identity: export the Developer ID Application cert (+ key) as .p12 from a Mac that has it."
  export APPLE_SIGNING_IDENTITY="-"
fi

# --- build -----------------------------------------------------------------
bold "Installing frontend deps"
(cd "$DESKTOP" && pnpm install --frozen-lockfile)

bold "Building CommitKit.app (first build compiles everything: ~5-10 min)"
# --bundles app: skip the .dmg, which needs Finder scripting and isn't used here.
(cd "$DESKTOP" && cargo tauri build --bundles app)

APP="$DESKTOP/src-tauri/target/release/bundle/macos/CommitKit.app"
[ -d "$APP" ] || die "build finished but $APP is missing"
echo "built: $APP"

# --- install ---------------------------------------------------------------
if [ "$INSTALL" = 1 ]; then
  bold "Installing to /Applications"
  if pgrep -xq commitkit; then
    osascript -e 'quit app "CommitKit"' || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq commitkit || break; sleep 1; done
    pgrep -xq commitkit && die "CommitKit is still running; quit it and rerun with --install"
  fi
  rm -rf /Applications/CommitKit.app
  ditto "$APP" /Applications/CommitKit.app
  open /Applications/CommitKit.app
  echo "installed and launched (it reinstalls the bundled monitor into ~/.commitkit/bin on start)"
else
  echo "run with --install to replace /Applications/CommitKit.app, or: open \"$APP\""
fi

# --- browser extensions ----------------------------------------------------
# They're loaded unpacked from the monitor repo, outside the .app; Chrome
# doesn't notice changed files on its own.
EXT="$ROOT/commitkit-monitor/chrome-extension"
if [ "$EXT_CHANGED" = 1 ]; then
  bold "Browser extension changed"
  echo "Reload it: chrome://extensions > CommitKit > reload (Firefox: about:debugging > Reload)."
fi
echo
echo "Chrome extension (first time on this Mac): chrome://extensions > Developer mode >"
echo "  Load unpacked > $EXT"
