#!/bin/bash
#===============================================================================
# FULL AUTOMATIC PRODUCTION DEPLOYMENT SCRIPT
# AlmaLinux 9 | Spring Boot (Java 21) + PostgreSQL + React (CRA) + nginx
#
# Host:     155.117.13.33
# Backend:  https://github.com/yazdan-centos/rest-template.git
# Frontend: https://github.com/yazdan-centos/rest-template-react.git
#
# Usage (as root on the target host):
#   ./deploy.sh
#
# The script is idempotent: safe to re-run for updates (git pull + rebuild).
# It does NOT drop the database on re-runs (data-preserving deployment).
#===============================================================================
set -euo pipefail

#------------------------------------------------------------------------------
# CONFIGURATION
#------------------------------------------------------------------------------
BACKEND_REPO="https://github.com/yazdan-centos/rest-template.git"
FRONTEND_REPO="https://github.com/yazdan-centos/rest-template-react.git"

SERVER_IP="155.117.13.33"
SSH_PORT="9011"

BACKEND_BIND="127.0.0.1"          # backend is only reachable through nginx
BACKEND_PORT="8080"

APP_USER="appuser"
APP_DIR="/opt/rest-template"
BACKEND_DIR="${APP_DIR}/backend"
FRONTEND_DIR="${APP_DIR}/frontend"
NGINX_ROOT="/usr/share/nginx/html"
SERVICE_NAME="rest-template"

JAVA_VERSION="21"
NODE_MAJOR="20"

# Must match src/main/resources/application.properties of the backend
DB_NAME="rest-template-db"
DB_USER="postgres"
DB_PASS='sgsec!1390'
DB_HOST="localhost"
DB_PORT="5432"

PGDATA="/var/lib/pgsql/data"

#------------------------------------------------------------------------------
# HELPERS
#------------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"; }
warn()  { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN:${NC} $1"; }
error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"; exit 1; }

# Escape a value as a safe single-quoted SQL literal ('' doubling).
sql_literal() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\'}"
}

# Run psql as the postgres OS user from a directory it can read
# (avoids: could not change directory to "/root": Permission denied).
postgres_exec() {
    (cd /var/lib/pgsql && sudo -u postgres -H psql -v ON_ERROR_STOP=1 "$@")
}

[[ $EUID -ne 0 ]] && error "This script must be run as root."

log "Starting full deployment on ${SERVER_IP} (AlmaLinux 9)..."

#===============================================================================
# PHASE 1: SYSTEM PACKAGES
#===============================================================================
log "Updating system packages..."
dnf update -y

log "Installing base dependencies (git, nginx, Java ${JAVA_VERSION}, PostgreSQL)..."
dnf install -y git curl wget tar policycoreutils-python-utils firewalld nginx \
    java-${JAVA_VERSION}-openjdk java-${JAVA_VERSION}-openjdk-devel \
    postgresql-server postgresql-contrib

if ! command -v node &>/dev/null || [[ "$(node -v | sed 's/^v//' | cut -d'.' -f1)" -lt ${NODE_MAJOR} ]]; then
    log "Installing Node.js ${NODE_MAJOR}.x..."
    curl -fsSL https://rpm.nodesource.com/setup_${NODE_MAJOR}.x | bash -
    dnf install -y nodejs
else
    log "Node.js $(node -v) already installed."
fi

#===============================================================================
# PHASE 2: POSTGRESQL (init, password, auth, readiness, database)
#===============================================================================
if [[ ! -f "${PGDATA}/PG_VERSION" ]]; then
    log "Initializing PostgreSQL cluster..."
    postgresql-setup --initdb
fi
systemctl enable postgresql --now

log "Waiting for PostgreSQL (peer auth) to accept connections..."
for i in {1..30}; do
    if postgres_exec -c "SELECT 1;" &>/dev/null; then break; fi
    [[ $i -eq 30 ]] && error "PostgreSQL did not become ready via peer auth."
    sleep 1
done

# 1) Set the postgres password FIRST, while peer auth still works.
#    Force scram-sha-256 hashing in the same session: PostgreSQL 13 defaults
#    to md5, which would not satisfy the scram-sha-256 pg_hba rules below.
log "Setting password for role '${DB_USER}'..."
postgres_exec -c "SET password_encryption = 'scram-sha-256'; ALTER USER ${DB_USER} WITH ENCRYPTED PASSWORD $(sql_literal "${DB_PASS}");"

# 2) Ensure TCP binding on both loopbacks. Explicit addresses are used instead
#    of 'localhost' because /etc/hosts may map localhost only to ::1, which
#    would leave 127.0.0.1 unbound and break pg_isready/JDBC over IPv4.
if grep -Eq "^\s*listen_addresses" "${PGDATA}/postgresql.conf"; then
    sed -i -E "s|^\s*listen_addresses\s*=.*|listen_addresses = '127.0.0.1, ::1'|" "${PGDATA}/postgresql.conf"
else
    echo "listen_addresses = '127.0.0.1, ::1'" >> "${PGDATA}/postgresql.conf"
fi

# Make scram the cluster default for any future password changes.
if grep -Eq "^\s*password_encryption" "${PGDATA}/postgresql.conf"; then
    sed -i -E "s|^\s*password_encryption\s*=.*|password_encryption = scram-sha-256|" "${PGDATA}/postgresql.conf"
else
    echo "password_encryption = scram-sha-256" >> "${PGDATA}/postgresql.conf"
fi

# 3) Switch host auth (127.0.0.1 / ::1) to scram-sha-256.
sed -i -E 's|^(host\s+all\s+all\s+127\.0\.0\.1/32\s+)(ident\|peer\|trust\|md5)|\1scram-sha-256|' "${PGDATA}/pg_hba.conf"
sed -i -E 's|^(host\s+all\s+all\s+::1/128\s+)(ident\|peer\|trust\|md5)|\1scram-sha-256|' "${PGDATA}/pg_hba.conf"

systemctl restart postgresql

log "Polling pg_isready on ${DB_HOST}:${DB_PORT}..."
for i in {1..30}; do
    if (cd /var/lib/pgsql && sudo -u postgres -H pg_isready -h 127.0.0.1 -p "${DB_PORT}") &>/dev/null; then break; fi
    [[ $i -eq 30 ]] && error "PostgreSQL did not become ready on TCP ${DB_PORT}."
    sleep 1
done

# 4) Create the application database if missing (idempotent, non-destructive).
if ! postgres_exec -tAc "SELECT 1 FROM pg_database WHERE datname = $(sql_literal "${DB_NAME}");" | grep -q 1; then
    log "Creating database \"${DB_NAME}\" owned by ${DB_USER}..."
    postgres_exec -c "CREATE DATABASE \"${DB_NAME}\" OWNER ${DB_USER};"
else
    log "Database \"${DB_NAME}\" already exists; preserving data."
fi

# 5) Verify an application-style TCP login with the password.
log "Verifying TCP login as ${DB_USER}..."
PGPASSWORD="${DB_PASS}" psql -h 127.0.0.1 -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1;" >/dev/null \
    || error "TCP login to PostgreSQL failed. Check pg_hba.conf and password."
log "PostgreSQL ready. Database: ${DB_NAME}"

#===============================================================================
# PHASE 3: APPLICATION USER & DIRECTORIES
#===============================================================================
if ! id "${APP_USER}" &>/dev/null; then
    useradd -r -m -s /bin/bash -d "${APP_DIR}" "${APP_USER}"
fi
mkdir -p "${APP_DIR}"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"

#===============================================================================
# PHASE 4: BACKEND (clone/pull, configure, build)
#===============================================================================
log "Cloning/updating backend repository..."
if [[ -d "${BACKEND_DIR}/.git" ]]; then
    sudo -u "${APP_USER}" git -C "${BACKEND_DIR}" fetch --all --prune
    sudo -u "${APP_USER}" git -C "${BACKEND_DIR}" reset --hard origin/HEAD
else
    rm -rf "${BACKEND_DIR}"
    sudo -u "${APP_USER}" git clone "${BACKEND_REPO}" "${BACKEND_DIR}"
fi

log "Writing deployment profile (application-deploy.properties)..."
cat > "${BACKEND_DIR}/src/main/resources/application-deploy.properties" << EOF
# Bind only on loopback; nginx is the public entry point
server.address=${BACKEND_BIND}
server.port=${BACKEND_PORT}
# PostgreSQL connection for the production host
spring.datasource.url=jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}
spring.datasource.username=${DB_USER}
spring.datasource.password=${DB_PASS}
spring.datasource.driverClassName=org.postgresql.Driver
# Keep schema in sync without destroying data
spring.jpa.hibernate.ddl-auto=update
spring.jpa.database-platform=org.hibernate.dialect.PostgreSQLDialect
# Quiet SQL logging in production
spring.jpa.show-sql=false
EOF
chown "${APP_USER}:${APP_USER}" "${BACKEND_DIR}/src/main/resources/application-deploy.properties"

log "Building backend with Maven wrapper (Java ${JAVA_VERSION})..."
JAVA_HOME_DIR="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
cd "${BACKEND_DIR}"
chmod +x ./mvnw
sudo -u "${APP_USER}" env JAVA_HOME="${JAVA_HOME_DIR}" ./mvnw -q -DskipTests clean package

JAR_FILE="$(ls -1 "${BACKEND_DIR}"/target/*.jar 2>/dev/null | grep -v '\.original$' | head -n1)"
[[ -z "${JAR_FILE}" ]] && error "Backend build produced no JAR in ${BACKEND_DIR}/target."
log "Backend JAR: ${JAR_FILE}"

#===============================================================================
# PHASE 5: SYSTEMD SERVICE
#===============================================================================
log "Installing systemd unit ${SERVICE_NAME}.service..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=rest-template Spring Boot backend
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${BACKEND_DIR}
ExecStart=${JAVA_HOME_DIR}/bin/java -Xms256m -Xmx512m -jar ${JAR_FILE} --spring.profiles.active=deploy
SuccessExitStatus=143
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"

#===============================================================================
# PHASE 6: FRONTEND (clone/pull, configure, build)
#===============================================================================
log "Cloning/updating frontend repository..."
if [[ -d "${FRONTEND_DIR}/.git" ]]; then
    sudo -u "${APP_USER}" git -C "${FRONTEND_DIR}" fetch --all --prune
    sudo -u "${APP_USER}" git -C "${FRONTEND_DIR}" reset --hard origin/HEAD
else
    rm -rf "${FRONTEND_DIR}"
    sudo -u "${APP_USER}" git clone "${FRONTEND_REPO}" "${FRONTEND_DIR}"
fi

log "Writing frontend .env.production..."
cat > "${FRONTEND_DIR}/.env.production" << 'EOF'
# Base URL of the backend API. Left empty so the Vite build falls back to the
# same-origin '/api' default; nginx proxies /api/ to the local Spring Boot app.
VITE_API_BASE_URL=
EOF
chown "${APP_USER}:${APP_USER}" "${FRONTEND_DIR}/.env.production"

log "Building frontend (npm ci + npm run build, Vite outputs dist/)..."
cd "${FRONTEND_DIR}"
if [[ -f package-lock.json ]]; then
    sudo -u "${APP_USER}" npm ci
else
    sudo -u "${APP_USER}" npm install
fi
sudo -u "${APP_USER}" npm run build
[[ -f "${FRONTEND_DIR}/dist/index.html" ]] || error "Frontend build produced no dist/index.html."

#===============================================================================
# PHASE 7: NGINX
#===============================================================================
log "Configuring nginx reverse proxy and static hosting..."
cat > /etc/nginx/conf.d/rest-template.conf << EOF
server {
    listen 80;
    server_name ${SERVER_IP} _;
    root ${NGINX_ROOT};
    index index.html;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 6M; access_log off; add_header Cache-Control "public, immutable";
    }

    location /api/ {
        proxy_pass http://${BACKEND_BIND}:${BACKEND_PORT}/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 30s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_buffering off;
        client_max_body_size 20m;
    }

    location / { try_files \$uri \$uri/ /index.html; }
    location ~ /\. { deny all; access_log off; log_not_found off; }
}
EOF

# Disable the distro default server block if it conflicts on :80
if grep -q "listen\s*80" /etc/nginx/nginx.conf && grep -q "server_name\s*_" /etc/nginx/nginx.conf; then
    sed -i 's|^\(\s*\)listen\s\+80;|\1listen 8081;|' /etc/nginx/nginx.conf || true
    sed -i 's|^\(\s*\)listen\s\+\[::\]:80;|\1listen [::]:8081;|' /etc/nginx/nginx.conf || true
fi

rm -rf "${NGINX_ROOT:?}"/*
cp -r "${FRONTEND_DIR}/dist/." "${NGINX_ROOT}/"
chown -R nginx:nginx "${NGINX_ROOT}"
chmod -R 755 "${NGINX_ROOT}"
nginx -t || error "nginx configuration test failed."

#===============================================================================
# PHASE 8: SELINUX
#===============================================================================
if command -v getenforce &>/dev/null && getenforce | grep -qi "enforcing"; then
    log "Configuring SELinux booleans and contexts..."
    setsebool -P httpd_can_network_connect 1 || true
    setsebool -P httpd_can_network_relay 1 || true
    semanage fcontext -a -t httpd_sys_content_t "${NGINX_ROOT}(/.*)?" 2>/dev/null \
        || semanage fcontext -m -t httpd_sys_content_t "${NGINX_ROOT}(/.*)?" 2>/dev/null || true
    restorecon -R "${NGINX_ROOT}" || true
fi

#===============================================================================
# PHASE 9: FIREWALL
#===============================================================================
log "Configuring firewalld (HTTP + SSH ${SSH_PORT})..."
systemctl enable firewalld --now
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-port=${SSH_PORT}/tcp
firewall-cmd --reload

#===============================================================================
# PHASE 10: START & VERIFY
#===============================================================================
log "Starting backend service..."
systemctl restart "${SERVICE_NAME}"

log "Waiting for backend on ${BACKEND_BIND}:${BACKEND_PORT}..."
BACKEND_UP=0
for i in {1..45}; do
    if ss -tln | grep -q ":${BACKEND_PORT} "; then BACKEND_UP=1; break; fi
    sleep 2
done
[[ ${BACKEND_UP} -eq 1 ]] || error "Backend failed to start. Check: journalctl -u ${SERVICE_NAME} -n 100"

log "Starting nginx..."
systemctl enable nginx
systemctl restart nginx

FE_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/ || echo "000")
API_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/api/employees/all || echo "000")

echo ""
echo -e "${GREEN}============================================================"
echo "  DEPLOYMENT COMPLETE"
echo -e "============================================================${NC}"
echo ""
echo -e "  ${BLUE}Frontend:${NC}  http://${SERVER_IP}/            (HTTP ${FE_CODE})"
echo -e "  ${BLUE}API:${NC}       http://${SERVER_IP}/api/        (HTTP ${API_CODE} on /api/employees/all)"
echo -e "  ${BLUE}Database:${NC}  ${DB_NAME} on ${DB_HOST}:${DB_PORT}"
echo ""
echo -e "  ${YELLOW}Useful commands:${NC}"
echo "    journalctl -u ${SERVICE_NAME} -f"
echo "    sudo -u postgres psql -d \"${DB_NAME}\""
echo "    tail -f /var/log/nginx/error.log"
echo ""

if [[ "${FE_CODE}" == "200" && "${API_CODE}" == "200" ]]; then
    echo -e "  ${GREEN}✓ Frontend and API verified locally.${NC}"
elif [[ "${API_CODE}" == "502" ]]; then
    echo -e "  ${RED}✗ API returned 502 — backend not reachable through nginx. Check backend logs.${NC}"
else
    warn "Unexpected HTTP codes — verify manually with the commands above."
fi
