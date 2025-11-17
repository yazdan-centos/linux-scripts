#!/usr/bin/env bash
# --------------------------------------------------------------------------------------------------
# AlmaLinux 9 Full-Stack Deployment Helper
#
# Installs and configures:
#   • Java 21, Maven, Node.js 18+, PostgreSQL 16, Nginx, Certbot
#   • Dedicated Linux service users for backend/frontend
#   • Spring Boot JAR build + systemd service
#   • React production build hosted via Nginx reverse-proxy with TLS
#   • PostgreSQL database/user provisioning
#
# Features:
#   • Idempotent and safe to rerun
#   • Pre-flight checks (root, disk space, ports)
#   • Central logging to /var/log/deployment.log
#   • Health checks and deployment summary
#
# Usage (run as root):
#   ./deploy.sh \
#     --domain app.example.com \
#     --email ops@example.com \
#     --db-name food-reservation_db \
#     --db-user postgres \
#     --db-password 'Map@123456!' \
#     --backend-src /srv/repos/backend \
#     --frontend-src /srv/repos/frontend
#
# Optional flags:
#   --app-name food-reservation-web-app            # default: myapp
#   --spring-profile prod       # default: prod
#   --tls-cert-path /etc/pki/tls/certs/cert.pem --tls-key-path /etc/pki/tls/private/key.pem [--tls-chain-path /etc/pki/tls/certs/chain.pem]#
# Notes:
#   • Ensure BACKEND_SRC holds a Spring Boot Maven project, FRONTEND_SRC a React project.
#   • When providing custom TLS material, cert/key must be PEM-encoded.
# --------------------------------------------------------------------------------------------------

set -euo pipefail
set -o errtrace

LOG_FILE="/var/log/deployment.log"

log_info()    { printf '[INFO] %s\n' "$*"; }
log_warn()    { printf '[WARN] %s\n' "$*"; }
log_error()   { printf '[ERROR] %s\n' "$*"; }
log_success() { printf '[OK] %s\n' "$*"; }

usage() {
  cat <<'EOF'
AlmaLinux 9 Production Deployment Script

Required arguments:
  --domain <FQDN>            Public domain for TLS/Nginx
  --email <EMAIL>            Email for Let's Encrypt registration (ignored if custom cert provided)
  --db-name <NAME>           PostgreSQL database name to create/manage
  --db-user <USER>           PostgreSQL role/user to create/manage
  --db-password <PASS>       Password for the PostgreSQL role
  --backend-src <PATH>       Path to Spring Boot source root (Maven/Gradle project)
  --frontend-src <PATH>      Path to React source root

Optional arguments:
  --app-name <NAME>          Logical application name (defaults to "myapp")
  --spring-profile <NAME>    Spring Boot profile (defaults to "prod")
  --tls-cert-path <PATH>     Path to existing TLS certificate (PEM)
  --tls-key-path <PATH>      Path to existing TLS private key (PEM)
  --tls-chain-path <PATH>    (Optional) Path to certificate chain file (PEM)
  --help                     Show this help message

Example:
  sudo ./deploy.sh \
    --domain food.mapnaom.com \
    --email yazdanparast.ubuntu@gmail.com \
    --db-name food_reservation_db \
    --db-user postgres \
    --db-password 'Map@123456' \
    --backend-src /srv/backend \
    --frontend-src /srv/frontend
EOF
}

check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "This script must run with root privileges. Please use sudo or root."
    exit 1
  fi
}

catch_error() {
  local exit_code=$?
  log_error "Deployment failed on or near line ${BASH_LINENO[0]} (command: ${BASH_COMMAND})."
  log_error "Inspect ${LOG_FILE} for the complete trace."
  exit "${exit_code}"
}

trap catch_error ERR
trap 'log_warn "Deployment interrupted by signal."; exit 130' INT TERM

# Prepare logging early so all output is captured.
mkdir -p "$(dirname "${LOG_FILE}")"
touch "${LOG_FILE}"
chmod 640 "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log_info "=== AlmaLinux 9 full-stack deployment started ==="

# ------------------------------ Argument Parsing ---------------------------------

APP_NAME="food_reservation_app"
SPRING_PROFILE="prod"
DOMAIN="food.mapnaom.com"
LE_EMAIL="yazdanparast.ubuntu@gmail.com"
DB_NAME="food_reservation_db"
DB_USER="postgres"
DB_PASSWORD="Map@123456"
BACKEND_SRC="/srv/backend"
FRONTEND_SRC="/srv/frontend"
TLS_CERT_SOURCE="/etc/pki/tls/certs/chain.pem"
TLS_KEY_SOURCE="/etc/pki/tls/private/key.pem"
TLS_CHAIN_SOURCE="/etc/pki/tls/certs/cert.pem"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)
      APP_NAME="$2"; shift 2;;
    --spring-profile)
      SPRING_PROFILE="$2"; shift 2;;
    --domain)
      DOMAIN="$2"; shift 2;;
    --email)
      LE_EMAIL="$2"; shift 2;;
    --db-name)
      DB_NAME="$2"; shift 2;;
    --db-user)
      DB_USER="$2"; shift 2;;
    --db-password)
      DB_PASSWORD="$2"; shift 2;;
    --backend-src)
      BACKEND_SRC="$2"; shift 2;;
    --frontend-src)
      FRONTEND_SRC="$2"; shift 2;;
    --tls-cert-path)
      TLS_CERT_SOURCE="$2"; shift 2;;
    --tls-key-path)
      TLS_KEY_SOURCE="$2"; shift 2;;
    --tls-chain-path)
      TLS_CHAIN_SOURCE="$2"; shift 2;;
    --help|-h)
      usage; exit 0;;
    *)
      log_error "Unknown argument: $1"
      usage
      exit 1;;
  esac
done

# Validate required arguments.
check_root
if [[ -z "${DOMAIN}" ]]; then
  log_error "--domain is required."
  exit 1
fi
if [[ -z "${BACKEND_SRC}" ]] || [[ ! -d "${BACKEND_SRC}" ]]; then
  log_error "Backend source directory '${BACKEND_SRC}' is missing or invalid."
  exit 1
fi
if [[ -z "${FRONTEND_SRC}" ]] || [[ ! -d "${FRONTEND_SRC}" ]]; then
  log_error "Frontend source directory '${FRONTEND_SRC}' is missing or invalid."
  exit 1
fi
if [[ -z "${DB_NAME}" ]] || [[ -z "${DB_USER}" ]] || [[ -z "${DB_PASSWORD}" ]]; then
  log_error "Database name, user, and password must be provided."
  exit 1
fi
if [[ -n "${TLS_CERT_SOURCE}" && -z "${TLS_KEY_SOURCE}" ]] || [[ -n "${TLS_KEY_SOURCE}" && -z "${TLS_CERT_SOURCE}" ]]; then
  log_error "Provide both --tls-cert-path and --tls-key-path when using custom TLS material."
  exit 1
fi
if [[ -z "${TLS_CERT_SOURCE}" ]] && [[ -z "${LE_EMAIL}" ]]; then
  log_error "--email is required when TLS certificates are not provided."
  exit 1
fi

# Sanitize names for filesystem/systemd use.
APP_SLUG=$(echo "${APP_NAME}" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//')
[[ -z "${APP_SLUG}" ]] && APP_SLUG="app"
APP_USER_PREFIX=$(echo "${APP_SLUG}" | tr -cs '[:alnum:]' '_')
BACKEND_USER="${APP_USER_PREFIX}_backend"
FRONTEND_USER="${APP_USER_PREFIX}_frontend"

# Directories and files.
APP_ROOT="/opt/${APP_SLUG}"
SRC_ROOT="${APP_ROOT}/src"
BACKEND_SRC_DIR="${SRC_ROOT}/backend"
FRONTEND_SRC_DIR="${SRC_ROOT}/frontend"
BACKEND_DEPLOY_DIR="${APP_ROOT}/backend"
FRONTEND_BUILD_DIR="${APP_ROOT}/frontend-build"
STATIC_DIR="/var/www/${APP_SLUG}"
ENV_DIR="/etc/${APP_SLUG}"
BACKEND_ENV_FILE="${ENV_DIR}/backend.env"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${APP_SLUG}-backend.service"
NGINX_CONF="/etc/nginx/conf.d/${APP_SLUG}.conf"
TLS_CERT_DEST="/etc/ssl/${APP_SLUG}"
BACKEND_PORT=9091
PG_VERSION="16"
PG_SERVICE="postgresql-${PG_VERSION}"

# ------------------------------ Helper Functions ---------------------------------

check_disk_space() {
  # Ensure at least 2 GiB of free space on root.
  local free_kb
  free_kb=$(df --output=avail / | tail -1)
  if (( free_kb < 2 * 1024 * 1024 )); then
    log_error "Insufficient disk space (<2 GiB free on /)."
    exit 1
  fi
}

check_port_conflict() {
  local port=$1
  local allowed_pattern=$2
  if ss -tulpn | awk -v p=":${port}" '$5 ~ p || $4 ~ p' | grep -vqE "${allowed_pattern}"; then
    log_error "Port ${port} is already in use. Resolve the conflict before continuing."
    exit 1
  fi
}

ensure_user() {
  local user=$1
  local home=$2
  if id "${user}" >/dev/null 2>&1; then
    log_info "User '${user}' already exists."
  else
    log_info "Creating system user '${user}'."
    useradd --system --shell /sbin/nologin --home-dir "${home}" "${user}"
  fi
}

ensure_package() {
  local pkg=$1
  if rpm -q "${pkg}" >/dev/null 2>&1; then
    log_info "Package '${pkg}' already installed."
  else
    log_info "Installing package '${pkg}'."
    dnf install -y "${pkg}"
  fi
}

install_node18() {
  if command -v node >/dev/null 2>&1; then
    local version
    version=$(node -v | sed 's/v//')
    if awk 'BEGIN{exit !('"${version%%.*}"' >= 18)}'; then
      log_info "Node.js $(node -v) already satisfies requirement."
      return
    fi
  fi
  log_info "Configuring NodeSource repo for Node.js 18."
  curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
  ensure_package nodejs
  log_success "Installed Node.js $(node -v)."
}

install_java21() {
  ensure_package java-21-openjdk-headless
  # The project uses Maven Wrapper (mvnw), so a system-wide Maven install is not strictly necessary.
  # We ensure it's present as a fallback.
  ensure_package maven
  log_success "Java $(java -version 2>&1 | head -1) and Maven ready."
}
 
install_postgres15() {
  local repo_pkg="https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
  if ! rpm -q pgdg-redhat-repo >/dev/null 2>&1; then
    log_info "Adding PostgreSQL PGDG repository."
    dnf install -y "${repo_pkg}"
  fi
  log_info "Disabling stock PostgreSQL module to avoid version conflicts."
  dnf -qy module disable postgresql
  ensure_package "postgresql${PG_VERSION}"
  ensure_package "postgresql${PG_VERSION}-server"
  ensure_package "postgresql${PG_VERSION}-contrib"

  # Initialize database cluster if not already done.
  local data_dir="/var/lib/pgsql/${PG_VERSION}/data"
  if [[ ! -f "${data_dir}/PG_VERSION" ]]; then
    log_info "Initializing PostgreSQL ${PG_VERSION} database cluster."
    /usr/pgsql-${PG_VERSION}/bin/postgresql-${PG_VERSION}-setup initdb
  else
    log_info "PostgreSQL data directory already initialized."
  fi

  systemctl enable --now "${PG_SERVICE}"
  log_success "PostgreSQL ${PG_VERSION} running ($(psql --version))."
}

configure_postgres_db() {
  local safe_password
  safe_password=${DB_PASSWORD//\'/\'\'}
  log_info "Provisioning PostgreSQL database '${DB_NAME}' and role '${DB_USER}'."

  # Create role if needed, update password.
  if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'\"" | grep -q 1; then
    su - postgres -c "psql -c \"CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${safe_password}';\""
    log_success "Created PostgreSQL role '${DB_USER}'."
  else
    su - postgres -c "psql -c \"ALTER ROLE ${DB_USER} WITH PASSWORD '${safe_password}';\""
    log_info "Updated password for existing role '${DB_USER}'."
  fi

  # Create database if missing.
  if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\"" | grep -q 1; then
    su - postgres -c "createdb -O ${DB_USER} ${DB_NAME}"
    log_success "Created database '${DB_NAME}' owned by '${DB_USER}'."
  else
    log_info "Database '${DB_NAME}' already exists."
  fi

  # Ensure pg_hba allows SCRAM-auth from localhost for this user.
  local pg_hba="/var/lib/pgsql/${PG_VERSION}/data/pg_hba.conf"
  local rule="host    ${DB_NAME}    ${DB_USER}    127.0.0.1/32    scram-sha-256"
  if ! grep -Fxq "${rule}" "${pg_hba}"; then
    echo "${rule}" >> "${pg_hba}"
    log_info "Added pg_hba rule for ${DB_USER}."
  fi

  # Limit listening to localhost for security.
  local pg_conf="/var/lib/pgsql/${PG_VERSION}/data/postgresql.conf"
  sed -ri "s/^#?\s*listen_addresses\s*=.*/listen_addresses = '127.0.0.1'/g" "${pg_conf}"

  systemctl restart "${PG_SERVICE}"
  log_success "PostgreSQL configuration refreshed."
}

ensure_firewall() {
  ensure_package firewalld
  systemctl enable --now firewalld

  # Allow only ssh, http, https, squid by default.
  for svc in $(firewall-cmd --permanent --list-services); do
    case "${svc}" in
      ssh|http|https|squid) continue;;
      *) firewall-cmd --permanent --remove-service="${svc}" ;;
    esac
  done
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --permanent --add-service=squid

  # Allow SSH on custom port 9011
  firewall-cmd --permanent --add-port=9011/tcp

  firewall-cmd --reload
  log_success "Firewall permits SSH (port 9011), HTTP, HTTPS, and Squid; other services removed."
}

prepare_directories() {
  log_info "Preparing application directories."
  mkdir -p "${SRC_ROOT}" "${BACKEND_SRC_DIR}" "${FRONTEND_SRC_DIR}" \
           "${BACKEND_DEPLOY_DIR}" "${FRONTEND_BUILD_DIR}" "${STATIC_DIR}" "${ENV_DIR}"

  ensure_user "${BACKEND_USER}" "${APP_ROOT}"
  ensure_user "${FRONTEND_USER}" "${APP_ROOT}"

  chown -R root:root "${APP_ROOT}"
  chown -R root:root "${ENV_DIR}"
  chown -R root:root "${STATIC_DIR}"
}

# Synchronizes backend and frontend source code to their deployment directories.
# Uses rsync with archive mode (-a) and --delete to ensure exact mirror copies,
# removing any files in the destination that don't exist in the source.
sync_sources() {
  ensure_package rsync
  log_info "Syncing backend sources from ${BACKEND_SRC}."
  rsync -a --delete "${BACKEND_SRC}/" "${BACKEND_SRC_DIR}/"

  log_info "Syncing frontend sources from ${FRONTEND_SRC}."
  rsync -a --delete "${FRONTEND_SRC}/" "${FRONTEND_SRC_DIR}/"
}

build_frontend() {
  log_info "Building React frontend in ${FRONTEND_SRC_DIR}."
  pushd "${FRONTEND_SRC_DIR}" >/dev/null
  if [[ -f package-lock.json ]]; then
    npm ci
  else
    npm install
  fi
  npm run build
  popd >/dev/null

  log_info "Deploying React build artifacts to ${STATIC_DIR}."
  rsync -a --delete "${FRONTEND_SRC_DIR}/build/" "${STATIC_DIR}/"
  chown -R root:nginx "${STATIC_DIR}"
  find "${STATIC_DIR}" -type d -exec chmod 750 {} \;
  find "${STATIC_DIR}" -type f -exec chmod 640 {} \;
  log_success "Frontend build deployed."
}

build_backend() {
  log_info "Packaging Spring Boot backend."
  pushd "${BACKEND_SRC_DIR}" >/dev/null
  if [[ -x mvnw ]]; then
    ./mvnw -B clean package -DskipTests
  else
    mvn -B clean package -DskipTests
  fi

  local jar_file
  jar_file=$(find target -maxdepth 1 -type f -name "*.jar" ! -name "*-sources.jar" ! -name "*-javadoc.jar" | head -n1)
  if [[ -z "${jar_file}" ]]; then
    log_error "No runnable JAR produced under target/. Check the build output."
    exit 1
  fi
  popd >/dev/null

  log_info "Deploying backend JAR to ${BACKEND_DEPLOY_DIR}."
  cp "${BACKEND_SRC_DIR}/${jar_file}" "${BACKEND_DEPLOY_DIR}/app.jar"
  chown "${BACKEND_USER}:${BACKEND_USER}" "${BACKEND_DEPLOY_DIR}/app.jar"
  chmod 750 "${BACKEND_DEPLOY_DIR}"
  chmod 640 "${BACKEND_DEPLOY_DIR}/app.jar"
  log_success "Backend artifact ready."
}

configure_backend_env() {
  log_info "Creating backend environment configuration."
  cat > "${BACKEND_ENV_FILE}" <<EOF
SPRING_PROFILES_ACTIVE=${SPRING_PROFILE}
SPRING_DATASOURCE_URL=jdbc:postgresql://127.0.0.1:5432/${DB_NAME}
SPRING_DATASOURCE_USERNAME=${DB_USER}
SPRING_DATASOURCE_PASSWORD=${DB_PASSWORD}
SPRING_JPA_PROPERTIES_HIBERNATE_DIALECT=org.hibernate.dialect.PostgreSQLDialect
SPRING_SERVLET_MULTIPART_ENABLED=true
SERVER_PORT=${BACKEND_PORT}
SPRING_WEB_RESOURCES_STATIC_LOCATIONS=file:${STATIC_DIR}/
EOF

  chown root:"${BACKEND_USER}" "${BACKEND_ENV_FILE}"
  chmod 640 "${BACKEND_ENV_FILE}"
}

configure_systemd_service() {
  log_info "Configuring systemd service ${APP_SLUG}-backend."
  cat > "${SYSTEMD_SERVICE_FILE}" <<EOF
[Unit]
Description=${APP_NAME} Spring Boot Service
After=network.target ${PG_SERVICE}.service
Wants=${PG_SERVICE}.service

[Service]
User=${BACKEND_USER}
Group=${BACKEND_USER}
EnvironmentFile=${BACKEND_ENV_FILE}
WorkingDirectory=${BACKEND_DEPLOY_DIR}
ExecStart=/usr/bin/java -jar ${BACKEND_DEPLOY_DIR}/app.jar
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${APP_SLUG}-backend.service"
  log_success "Backend service enabled and started."
}

configure_nginx_base() {
  log_info "Creating base Nginx reverse proxy configuration."
  cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root ${STATIC_DIR};
    index index.html;

    # Static React assets
    location / {
        try_files \$uri /index.html;
    }

    # Spring Boot API proxy
    location /api/ {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_read_timeout 60s;
    }

    # Health endpoint passthrough (optional)
    location /actuator/health {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_set_header Host \$host;
    }

    client_max_body_size 25m;
}
EOF

  systemctl enable --now nginx
  nginx -t
  systemctl reload nginx
  log_success "Nginx base configuration applied."
}

configure_nginx_with_tls() {
  local cert_path=$1
  local key_path=$2
  local chain_path=$3
  local ssl_certificate=${cert_path}
  [[ -n "${chain_path}" ]] && ssl_certificate="${chain_path}"

  log_info "Rendering Nginx configuration with TLS certificate."
  cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate ${ssl_certificate};
    ssl_certificate_key ${key_path};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    root ${STATIC_DIR};
    index index.html;

    location / {
        try_files \$uri /index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_read_timeout 60s;
    }

    location /actuator/health {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_set_header Host \$host;
    }

    client_max_body_size 25m;
}
EOF

  nginx -t
  systemctl reload nginx
  log_success "Nginx TLS configuration active."
}

handle_tls() {
  if [[ -n "${TLS_CERT_SOURCE}" ]]; then
    log_info "Using provided TLS certificate materials."
    mkdir -p "${TLS_CERT_DEST}"
    cp "${TLS_CERT_SOURCE}" "${TLS_CERT_DEST}/cert.pem"
    cp "${TLS_KEY_SOURCE}" "${TLS_CERT_DEST}/privkey.pem"
    [[ -n "${TLS_CHAIN_SOURCE}" ]] && cp "${TLS_CHAIN_SOURCE}" "${TLS_CERT_DEST}/chain.pem"

    chmod 640 "${TLS_CERT_DEST}/"*.pem
    chown root:nginx "${TLS_CERT_DEST}/"*.pem

    local chain_file="${TLS_CERT_DEST}/cert.pem"
    if [[ -f "${TLS_CERT_DEST}/chain.pem" ]]; then
      chain_file="${TLS_CERT_DEST}/chain.pem"
    fi
    configure_nginx_with_tls "${TLS_CERT_DEST}/cert.pem" "${TLS_CERT_DEST}/privkey.pem" "${chain_file}"
  else
    log_info "Requesting/renewing Let's Encrypt certificate via certbot."
    ensure_package certbot
    ensure_package python3-certbot-nginx

    certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos --email "${LE_EMAIL}" --redirect
    systemctl enable --now certbot-renew.timer
    nginx -t
    systemctl reload nginx
    log_success "Let's Encrypt certificate installed; auto-renew timer active."
  fi
}

health_check() {
  log_info "Performing post-deployment health checks."

  if systemctl is-active --quiet "${PG_SERVICE}"; then
    log_success "PostgreSQL service is active."
  else
    log_error "PostgreSQL service is NOT active. Check 'systemctl status ${PG_SERVICE}'."
    return 1
  fi

  if systemctl is-active --quiet "${APP_SLUG}-backend.service"; then
    log_success "Backend service is active."
  else
    log_error "Backend service is NOT active. Check 'systemctl status ${APP_SLUG}-backend.service'."
    return 1
  fi

  log_info "Waiting up to 30s for backend to become healthy..."
  for _ in {1..15}; do
    if curl --fail --silent --insecure "https://127.0.0.1/actuator/health" | grep -q '"status":"UP"'; then
      log_success "Backend health endpoint is UP."
      return 0
    fi
    sleep 2
  done

  log_error "Backend health check failed after 30 seconds."
  return 1
}

print_summary() {
  cat <<EOF

----------------------------------------------------------------------
 Deployment Summary
----------------------------------------------------------------------
Application Name:   ${APP_NAME} (${APP_SLUG})
# Set ownership and permissions
                                     sudo chown -R $USER:$USER /srv/frontend
                                     sudo chown -R $USER:$USER /srv/backend
                                     sudo chmod -R 755 /srv/frontend
                                     sudo chmod -R 755 /srv/backend
Domain:             https://${DOMAIN}

Services:
  - Backend:        ${APP_SLUG}-backend.service (active and running)
  - Database:       ${PG_SERVICE} (active and running)
  - Web Server:     nginx (active and running)

Paths:
  - App Root:       ${APP_ROOT}
  - Backend JAR:    ${BACKEND_DEPLOY_DIR}/app.jar
  - Frontend Root:  ${STATIC_DIR}
  - Environment:    ${BACKEND_ENV_FILE}
  - Logs:           ${LOG_FILE}

----------------------------------------------------------------------
 Deployment complete.
----------------------------------------------------------------------
EOF
}

# ------------------------------ Main Execution ---------------------------------

main() {
  check_disk_space
  check_port_conflict 80 "nginx"
  check_port_conflict 443 "nginx"

  log_info "--- Phase 1: System & Dependency Setup ---"
  ensure_firewall
  install_java21
  install_node18
  install_postgres15
  ensure_package nginx

  log_info "--- Phase 2: Application & Database Provisioning ---"
  configure_postgres_db
  prepare_directories
  sync_sources

  log_info "--- Phase 3: Build & Deploy Artifacts ---"
  build_frontend
  build_backend

  log_info "--- Phase 4: Service Configuration & Activation ---"
  configure_backend_env
  configure_systemd_service
  configure_nginx_base
  handle_tls

  log_info "--- Phase 5: Final Health Checks ---"
  health_check

  log_success "All deployment steps completed successfully."
  print_summary
}

main "$@"
