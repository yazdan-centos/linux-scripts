#!/bin/bash
#===============================================================================
# REACT (CRA) FRONTEND DEPLOYMENT — drop-in replacement for PHASE 6 of deploy.sh
#
# Your original deploy.sh builds a Vite app (VITE_API_BASE_URL, dist/ output).
# The collaboration2 repo (from /mnt/c/Users/Administrator/Desktop/collaboration2/)
# is Create React App, which differs in three ways that matter for deployment:
#   - env vars must be prefixed REACT_APP_ (Vite's VITE_ prefix is ignored)
#   - env vars are read from .env.production automatically by `npm run build`
#   - the build output directory is build/, not dist/
#
# Paste this in place of PHASE 6 in deploy.sh. It reuses variables/functions
# (log/warn/error, APP_USER, FRONTEND_DIR, NGINX_ROOT, SERVER_IP, SSH_PORT)
# already defined earlier in the full script. Standalone fallbacks below let
# you test this file in isolation.
#===============================================================================
set -euo pipefail

#------------------------------------------------------------------------------
# STANDALONE FALLBACKS — delete this block when pasting into the real deploy.sh
#------------------------------------------------------------------------------
: "${APP_USER:=appuser}"
: "${FRONTEND_DIR:=/opt/ticketing-platform/frontend}"
: "${NGINX_ROOT:=/usr/share/nginx/html}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"; }
warn()  { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN:${NC} $1"; }
error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"; exit 1; }

#------------------------------------------------------------------------------
# CONFIGURATION — fill in the placeholders
#------------------------------------------------------------------------------

# --- 1) GIT ------------------------------------------------------------------
# Unchanged from your existing CONFIGURATION block — kept here only for
# context. Do not duplicate if pasting into the full script.
FRONTEND_REPO="https://github.com/yazdan-centos/collaboration2.git"   # <-- CRA repo

# --- 2) SSH / REMOTE SERVER ----------------------------------------------------
# Reused from the top of deploy.sh (target host the script runs on as root).
SERVER_IP="${SERVER_IP:-155.117.13.33}"      # <-- target host
SSH_PORT="${SSH_PORT:-9011}"                 # <-- target sshd port
# Only needed if you invoke this FROM a separate CI/build box instead of
# running it locally on the target host (push-build pattern):
# SSH_USER="deploy"                          # <-- remote login user
# SSH_KEY_PATH="/etc/deploy-keys/id_ed25519" # <-- private key, chmod 600, never log its path contents

# --- 3) REACT_APP_API_BASE_URL SOURCE -----------------------------------------
# get_react_api_base_url() below tries these in order:
#   a) an already-exported REACT_APP_API_BASE_URL (e.g. injected by CI/CD)
#   b) a root-only secrets file on the target host
#   c) a secret-manager CLI call (Vault / AWS Secrets Manager / etc.)
#   d) fallback: empty -> same-origin "/api", proxied by nginx (matches your
#      existing nginx location /api/ block, no change needed there)
SECRETS_ENV_FILE="/etc/ticketing-platform/frontend.secrets.env"   # <-- create out-of-band, perms 600, root:root
# SECRET_MANAGER_CMD='vault kv get -field=api_base_url secret/ticketing/frontend'  # <-- example, uncomment to use

DRY_RUN="${DRY_RUN:-false}"   # 6) run:  DRY_RUN=true ./deploy.sh   to preview with no changes

#------------------------------------------------------------------------------
# HELPER — resolve REACT_APP_API_BASE_URL without ever printing the value
#------------------------------------------------------------------------------
get_react_api_base_url() {
    # (a) Caller already exported it.
    if [[ -n "${REACT_APP_API_BASE_URL:-}" ]]; then
        log "REACT_APP_API_BASE_URL resolved from process environment."
        return
    fi

    # (b) Root-only secrets file on the target host.
    if [[ -f "${SECRETS_ENV_FILE}" ]]; then
        local perms
        perms="$(stat -c '%a' "${SECRETS_ENV_FILE}")"
        [[ "${perms}" == "600" ]] || warn "${SECRETS_ENV_FILE} is mode ${perms}, expected 600."
        # shellcheck disable=SC1090
        set -a; source "${SECRETS_ENV_FILE}"; set +a
        if [[ -n "${REACT_APP_API_BASE_URL:-}" ]]; then
            log "REACT_APP_API_BASE_URL resolved from ${SECRETS_ENV_FILE}."
            return
        fi
    fi

    # (c) Optional secret-manager CLI.
    if [[ -n "${SECRET_MANAGER_CMD:-}" ]]; then
        REACT_APP_API_BASE_URL="$(eval "${SECRET_MANAGER_CMD}")" \
            || error "Failed to fetch REACT_APP_API_BASE_URL from secret manager."
        export REACT_APP_API_BASE_URL
        log "REACT_APP_API_BASE_URL resolved from secret manager."
        return
    fi

    # (d) Fallback: same-origin default.
    warn "No REACT_APP_API_BASE_URL source found; defaulting to same-origin '/api'."
    export REACT_APP_API_BASE_URL=""
}

#===============================================================================
# PHASE 6 (REPLACEMENT): FRONTEND — Create React App
#===============================================================================
log "Cloning/updating frontend repository..."
if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] Would clone/pull ${FRONTEND_REPO} into ${FRONTEND_DIR}"
elif [[ -d "${FRONTEND_DIR}/.git" ]]; then
    sudo -u "${APP_USER}" git -C "${FRONTEND_DIR}" fetch --all --prune \
        || error "git fetch failed for ${FRONTEND_DIR}"
    sudo -u "${APP_USER}" git -C "${FRONTEND_DIR}" reset --hard origin/HEAD \
        || error "git reset failed for ${FRONTEND_DIR}"
else
    rm -rf "${FRONTEND_DIR}"
    sudo -u "${APP_USER}" git clone "${FRONTEND_REPO}" "${FRONTEND_DIR}" \
        || error "git clone failed for ${FRONTEND_REPO}"
fi

log "Resolving REACT_APP_API_BASE_URL..."
get_react_api_base_url

log "Writing frontend .env.production (CRA convention: REACT_APP_ prefix)..."
# CRA only exposes vars prefixed REACT_APP_, and BAKES them into the JS bundle
# at build time — there's no runtime injection like server-side frameworks.
# Anyone can read the deployed bundle, so only put a base URL here, never an
# API key or anything genuinely secret.
if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] Would write ${FRONTEND_DIR}/.env.production (value not logged)"
else
    cat > "${FRONTEND_DIR}/.env.production" << EOF
# Base URL of the backend API. Empty = same-origin "/api", proxied by nginx.
# Populated at deploy time by get_react_api_base_url(); do not hardcode here.
REACT_APP_API_BASE_URL=${REACT_APP_API_BASE_URL}
# Keep ESLint warnings from failing the build in CI-like non-interactive shells.
CI=false
EOF
    chown "${APP_USER}:${APP_USER}" "${FRONTEND_DIR}/.env.production"
    chmod 640 "${FRONTEND_DIR}/.env.production"
fi
# Never cat/log this file from here on — that would leak REACT_APP_API_BASE_URL
# (and anything else added to it later) into deploy logs.

log "Installing dependencies and building (npm ci + react-scripts build)..."
cd "${FRONTEND_DIR}"
if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] Would run: npm ci (or npm install) && npm run build"
else
    if [[ -f package-lock.json ]]; then
        sudo -u "${APP_USER}" npm ci
    else
        sudo -u "${APP_USER}" npm install
    fi
    # react-scripts reads .env.production automatically for `npm run build` —
    # no need to pass REACT_APP_API_BASE_URL on the command line, which would
    # risk it showing up in `ps aux` output or shell history.
    sudo -u "${APP_USER}" npm run build

    [[ -f "${FRONTEND_DIR}/build/index.html" ]] \
        || error "CRA build produced no build/index.html."
fi
log "Frontend build complete: ${FRONTEND_DIR}/build"

#-------------------------------------------------------------------------------
# NOTE for PHASE 7 (nginx, unchanged otherwise): the copy source changes from
# Vite's dist/ to CRA's build/:
#   cp -r "${FRONTEND_DIR}/build/." "${NGINX_ROOT}/"
#-------------------------------------------------------------------------------

#===============================================================================
# ASSUMPTIONS ABOUT THE DESTINATION SERVER
#===============================================================================
# - Script still runs as root, locally on the target host (same model as the
#   rest of deploy.sh) — SERVER_IP/SSH_PORT are consumed by nginx/firewall
#   config elsewhere in the full script, not by this section directly.
# - Node.js version matches NODE_MAJOR from deploy.sh (>=18 recommended for
#   react-scripts 5.x). If the repo pins react-scripts 4.x on Node 17+, add
#   `NODE_OPTIONS=--openssl-legacy-provider` before `npm run build`.
# - CRA build output directory is build/ (hardcoded by react-scripts, not
#   configurable without ejecting or CRACO).
# - /etc/ticketing-platform exists and is root-owned if using the secrets-file
#   option; create it with e.g. `install -d -m 700 -o root -g root /etc/ticketing-platform`.
# - nginx's existing location /api/ proxy (from the current script) still
#   applies — no nginx changes needed if REACT_APP_API_BASE_URL resolves to "".
