#!/usr/bin/env bash

set -Eeuo pipefail

SSH_PORT="9011"
APP_USER="webapp"
APP_GROUP="webapp"
APP_BASE="/opt/webapps"
BACKEND_DIR="${APP_BASE}/ticketing-platform"
FRONTEND_DIR="${APP_BASE}/collaboration2"
LOG_DIR="/var/log/webapps"
NGINX_CONF="/etc/nginx/conf.d/ticketing-platform.conf"

BACKEND_REPO="https://github.com/yazdan-centos/ticketing-platform.git"
FRONTEND_REPO="https://github.com/yazdan-centos/collaboration2.git"

DB_NAME="ticketing_platform_db"
DB_USER="postgres"
DB_PASS="sgsec!1390"
DB_PORT="5432"

JAVA_HOME="/usr/lib/jvm/java-21-openjdk"
BACKEND_PORT="8080"
SERVER_IP="155.117.13.33"
PUBLIC_ORIGIN="http://${SERVER_IP}"
PRODUCTION_CORS_ORIGINS="${PUBLIC_ORIGIN},https://${SERVER_IP}"

log() {
  printf '\n[INFO] %s\n' "$1"
}

fail() {
  printf '\n[ERROR] %s\n' "$1" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Run this script as root."
  fi
}

configure_ssh_port() {
  log "Configuring sshd to keep port ${SSH_PORT} open."

  cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

  if grep -Eq "^[#[:space:]]*Port[[:space:]]+" /etc/ssh/sshd_config; then
    sed -i "s/^[#[:space:]]*Port[[:space:]].*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
  else
    printf '\nPort %s\n' "${SSH_PORT}" >> /etc/ssh/sshd_config
  fi

  if command -v semanage >/dev/null 2>&1; then
    semanage port -a -t ssh_port_t -p tcp "${SSH_PORT}" 2>/dev/null || \
    semanage port -m -t ssh_port_t -p tcp "${SSH_PORT}" || true
  fi

  sshd -t
  systemctl enable sshd
  systemctl restart sshd
}

install_base_packages() {
  log "Installing base packages and build tools."
  dnf -y update
  dnf -y install epel-release
  dnf -y install \
    git curl wget unzip tar vim-enhanced nano htop jq lsof rsync which \
    net-tools bind-utils policycoreutils-python-utils firewalld \
    nginx maven gcc gcc-c++ make
}

install_java() {
  log "Installing OpenJDK 21."
  dnf -y install java-21-openjdk java-21-openjdk-devel
  java -version
}

install_node() {
  log "Installing Node.js 20."
  curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
  dnf -y install nodejs
  node -v
  npm -v
}

install_postgresql() {
  log "Installing PostgreSQL 16 from PGDG."
  dnf -y install https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
  dnf -qy module disable postgresql
  dnf -y install postgresql16-server postgresql16

  /usr/pgsql-16/bin/postgresql-16-setup initdb

  sed -i "s/^#\?listen_addresses[[:space:]]*=.*/listen_addresses = '127.0.0.1,::1'/" /var/lib/pgsql/16/data/postgresql.conf
  if ! grep -q "^host[[:space:]]\+all[[:space:]]\+all[[:space:]]\+127.0.0.1/32[[:space:]]\+scram-sha-256" /var/lib/pgsql/16/data/pg_hba.conf; then
    printf '\nhost all all 127.0.0.1/32 scram-sha-256\n' >> /var/lib/pgsql/16/data/pg_hba.conf
  fi

  systemctl enable postgresql-16
  systemctl start postgresql-16

  sudo -u postgres psql <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';
  ELSE
    ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';
  END IF;
END
\$\$;
SQL

  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
    sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}"

  systemctl restart postgresql-16
}

configure_firewall() {
  log "Configuring firewalld for SSH, HTTP, and HTTPS."
  systemctl enable firewalld
  systemctl start firewalld

  firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
  firewall-cmd --permanent --add-port="${SSH_PORT}/udp"
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --permanent --remove-port="${DB_PORT}/tcp" || true
  firewall-cmd --reload
}

create_app_user() {
  log "Creating application user and directories."
  getent group "${APP_GROUP}" >/dev/null || groupadd --system "${APP_GROUP}"
  id "${APP_USER}" >/dev/null 2>&1 || useradd --system --gid "${APP_GROUP}" --create-home --home-dir /home/"${APP_USER}" --shell /bin/bash "${APP_USER}"

  mkdir -p "${APP_BASE}" "${LOG_DIR}"
  chown -R "${APP_USER}:${APP_GROUP}" "${APP_BASE}" "${LOG_DIR}"
}

clone_or_update_repos() {
  log "Cloning or updating application repositories."

  if [[ ! -d "${BACKEND_DIR}/.git" ]]; then
    sudo -u "${APP_USER}" git clone "${BACKEND_REPO}" "${BACKEND_DIR}"
  else
    sudo -u "${APP_USER}" git -C "${BACKEND_DIR}" pull --ff-only
  fi

  if [[ ! -d "${FRONTEND_DIR}/.git" ]]; then
    sudo -u "${APP_USER}" git clone "${FRONTEND_REPO}" "${FRONTEND_DIR}"
  else
    sudo -u "${APP_USER}" git -C "${FRONTEND_DIR}" pull --ff-only
  fi
}

build_backend() {
  log "Building backend with Maven wrapper."
  chmod +x "${BACKEND_DIR}/mvnw"
  pushd "${BACKEND_DIR}" >/dev/null
  sudo -u "${APP_USER}" ./mvnw -DskipTests clean package
  popd >/dev/null
}

write_backend_config() {
  log "Writing Spring Boot production overrides."

  mkdir -p "${BACKEND_DIR}/config"
  cat > "${BACKEND_DIR}/config/application-prod.properties" <<EOF
server.port=${BACKEND_PORT}

spring.datasource.url=jdbc:postgresql://127.0.0.1:${DB_PORT}/${DB_NAME}
spring.datasource.username=${DB_USER}
spring.datasource.password=${DB_PASS}
spring.datasource.driver-class-name=org.postgresql.Driver

spring.jpa.hibernate.ddl-auto=update
spring.jpa.properties.hibernate.dialect=org.hibernate.dialect.PostgreSQLDialect

server.forward-headers-strategy=framework
app.cors.allowed-origin-patterns=${PRODUCTION_CORS_ORIGINS}
EOF

  chown -R "${APP_USER}:${APP_GROUP}" "${BACKEND_DIR}/config"
}

find_backend_jar() {
  BACKEND_JAR="$(find "${BACKEND_DIR}/target" -maxdepth 1 -type f -name '*.jar' ! -name '*sources.jar' ! -name '*javadoc.jar' | head -n 1)"
  [[ -n "${BACKEND_JAR}" ]] || fail "Backend JAR not found under ${BACKEND_DIR}/target."
}

build_frontend() {
  log "Installing frontend dependencies and creating production build."
  pushd "${FRONTEND_DIR}" >/dev/null
  sudo -u "${APP_USER}" npm install
  sudo -u "${APP_USER}" env REACT_APP_API_BASE_URL="${PUBLIC_ORIGIN}" CI=false npm run build
  popd >/dev/null
}

write_systemd_units() {
  log "Creating systemd units."

  cat > /etc/systemd/system/ticketing-backend.service <<EOF
[Unit]
Description=Ticketing Platform Spring Boot Backend
After=network.target postgresql-16.service
Wants=postgresql-16.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${BACKEND_DIR}
Environment=JAVA_HOME=${JAVA_HOME}
Environment=SPRING_PROFILES_ACTIVE=prod
ExecStart=${JAVA_HOME}/bin/java -jar ${BACKEND_JAR} --spring.config.additional-location=${BACKEND_DIR}/config/application-prod.properties
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
StandardOutput=append:${LOG_DIR}/ticketing-backend.log
StandardError=append:${LOG_DIR}/ticketing-backend-error.log

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/collaboration2-frontend-build.service <<EOF
[Unit]
Description=Build collaboration2 React frontend
After=network.target

[Service]
Type=oneshot
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${FRONTEND_DIR}
Environment=REACT_APP_API_BASE_URL=${PUBLIC_ORIGIN}
Environment=CI=false
ExecStart=/usr/bin/npm install
ExecStart=/usr/bin/npm run build
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable ticketing-backend.service
}

write_nginx_config() {
  log "Configuring Nginx for frontend and backend proxy."

  setsebool -P httpd_can_network_connect 1

  cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    server_name ${SERVER_IP} fastcreate-674227 _;

    root ${FRONTEND_DIR}/build;
    index index.html;

    access_log /var/log/nginx/ticketing-platform-access.log;
    error_log /var/log/nginx/ticketing-platform-error.log;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /uploads/ {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  nginx -t
  systemctl enable nginx
  systemctl restart nginx
}

start_services() {
  log "Starting application services."
  systemctl restart ticketing-backend.service
  systemctl start collaboration2-frontend-build.service
}

verify_deployment() {
  log "Verifying frontend, backend, and production CORS."

  for attempt in {1..30}; do
    if curl -fsS -o /dev/null "http://127.0.0.1:${BACKEND_PORT}/v3/api-docs"; then
      break
    fi
    [[ "${attempt}" -lt 30 ]] || fail "Backend did not become ready on port ${BACKEND_PORT}."
    sleep 2
  done

  curl -fsS -o /dev/null -H "Host: ${SERVER_IP}" http://127.0.0.1/
  curl -fsS -D - -o /dev/null -X OPTIONS \
    -H "Host: ${SERVER_IP}" \
    -H "Origin: ${PUBLIC_ORIGIN}" \
    -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: content-type" \
    http://127.0.0.1/api/auth/authenticate \
    | tr -d '\r' \
    | grep -Fqi "Access-Control-Allow-Origin: ${PUBLIC_ORIGIN}" \
    || fail "Production CORS preflight verification failed."
}

show_summary() {
  cat <<EOF

Setup complete.

Services:
  systemctl status ticketing-backend
  systemctl status collaboration2-frontend-build
  systemctl status nginx
  systemctl status postgresql-16

Application paths:
  Backend:  ${BACKEND_DIR}
  Frontend: ${FRONTEND_DIR}

Public endpoints:
  Frontend: http://${SERVER_IP}/
  Backend:  http://${SERVER_IP}/api/

SSH:
  Port kept open: ${SSH_PORT}/tcp and ${SSH_PORT}/udp

PostgreSQL local access:
  Host: 127.0.0.1
  Port: ${DB_PORT}
  Database: ${DB_NAME}
  Username: ${DB_USER}
  Password: ${DB_PASS}

Important:
  1. Change DB_PASS in this script before running on a real server.
  2. PostgreSQL is restricted to loopback and is not exposed by firewalld.
  3. The frontend service is a build helper, not a persistent web server. Nginx serves the built files.
EOF
}

main() {
  require_root
  install_base_packages
  configure_ssh_port
  install_java
  install_node
  install_postgresql
  configure_firewall
  create_app_user
  clone_or_update_repos
  build_backend
  write_backend_config
  find_backend_jar
  build_frontend
  write_systemd_units
  write_nginx_config
  start_services
  verify_deployment
  show_summary
}

main "$@"
