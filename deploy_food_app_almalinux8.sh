#!/usr/bin/env bash
# Deploy food-app (Java backend) + daily-meal-web-app (React frontend) on AlmaLinux 8
# Target: serve frontend on 141.11.1.27:80 and proxy API requests to backend (localhost:8080)
#
# Usage:
#   sudo bash deploy_food_app_almalinux8.sh
#
# Notes / assumptions:
# - Runs as root (or with sudo). Script will exit if not root.
# - Backend repo: https://github.com/yazdan-centos/food-app
# - Frontend repo: https://github.com/yazdan-centos/daily-meal-web-app
# - Backend is a Java app buildable with Maven (if it's Gradle adjust manually).
# - Frontend is a React app buildable with npm/yarn (this script uses npm).
# - NGINX will serve the static frontend build at / and proxy /api/* to the backend at http://127.0.0.1:8080
# - Adjust proxy path (/api) in the nginx config below if your backend uses a different path.
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ---- Configuration (edit if needed) ----
BACKEND_REPO="https://github.com/yazdan-centos/food-app.git"
FRONTEND_REPO="https://github.com/yazdan-centos/daily-meal-web-app.git"
BACKEND_DIR="/opt/food-app"
FRONTEND_DIR="/opt/daily-meal-web-app"
RUN_SCRIPT="/opt/food-app/run-backend.sh"
SERVICE_NAME="food-app.service"
NGINX_CONF="/etc/nginx/conf.d/food-app.conf"
LISTEN_IP="141.11.1.27"    # public IP (used only for notes; nginx binds 0.0.0.0:80)
FRONTEND_BUILD_DIR="${FRONTEND_DIR}/build"
BACKEND_PORT=8080
# ----------------------------------------

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Try: sudo $0"
  exit 1
fi

echo "Starting deployment on AlmaLinux 8..."

# 1) Basic OS updates and required repos
dnf -y update
dnf -y install epel-release

# 2) Install required packages
dnf -y install git java-17-openjdk-devel maven nginx firewalld policycoreutils-python-utils setroubleshoot

# 3) Install Node.js (try module first, fall back to NodeSource)
echo "Installing Node.js (for building React frontend)..."
if dnf -q module list nodejs 2>/dev/null | grep -q "nodejs"; then
  # Try to install a supported module stream (prefer 16 if available)
  if dnf -y module list nodejs | grep -q "16/"; then
    dnf -y module enable nodejs:16
    dnf -y install nodejs
  else
    # best effort: install default nodejs package
    dnf -y install nodejs || true
  fi
fi

# If node not installed yet, use NodeSource RPM installer (Node 16)
if ! command -v node >/dev/null 2>&1; then
  echo "Node.js not found from modules. Installing from NodeSource (v16)..."
  curl -fsSL https://rpm.nodesource.com/setup_16.x | bash -
  dnf -y install nodejs
fi

# 4) Start and enable firewall and nginx services
systemctl enable --now firewalld
systemctl enable --now nginx

# Open firewall for HTTP (and HTTPS if you later enable it)
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --reload

# 5) Clone repositories
rm -rf "${BACKEND_DIR}" "${FRONTEND_DIR}"
git clone "${BACKEND_REPO}" "${BACKEND_DIR}"
git clone "${FRONTEND_REPO}" "${FRONTEND_DIR}"

# 6) Build backend (detect Maven or Gradle)
echo "Building backend in ${BACKEND_DIR}..."
cd "${BACKEND_DIR}"
if [ -f "pom.xml" ]; then
  # Maven build
  mvn -DskipTests package
  # find produced jar
  JAR_FILE=$(find target -maxdepth 1 -type f -name "*.jar" ! -name "*sources.jar" | head -n1 || true)
  if [ -z "${JAR_FILE}" ]; then
    echo "ERROR: No JAR found in target/. Inspect build output."
    exit 1
  fi
elif [ -f "build.gradle" ] || [ -f "gradlew" ]; then
  # Gradle build
  if [ -x "./gradlew" ]; then
    ./gradlew build -x test
  else
    dnf -y install gradle
    gradle build -x test
  fi
  JAR_FILE=$(find build/libs -maxdepth 1 -type f -name "*.jar" | head -n1 || true)
  if [ -z "${JAR_FILE}" ]; then
    echo "ERROR: No JAR found in build/libs/. Inspect build output."
    exit 1
  fi
else
  echo "No recognized Java build file (pom.xml or build.gradle). Please build the backend manually."
  exit 1
fi

# Create a small run script that finds the jar and exec's Java with desired options
cat > "${RUN_SCRIPT}" <<EOF
#!/usr/bin/env bash
cd "${BACKEND_DIR}"
# find jar (prefer latest modification time)
JAR=\$(ls -t target/*.jar 2>/dev/null | grep -v 'sources' | head -n1 || true)
/bin/false
# fallback for gradle layout:
if [ -z "\$JAR" ]; then
  JAR=\$(ls -t build/libs/*.jar 2>/dev/null | head -n1 || true)
fi
if [ -z "\$JAR" ]; then
  echo "No executable JAR found."
  exit 2
fi
exec /usr/bin/java -jar "\$JAR" --server.port=${BACKEND_PORT} --server.address=127.0.0.1
EOF
chmod +x "${RUN_SCRIPT}"

# 7) Create systemd service for backend
cat > "/etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=Food App Java Backend
After=network.target

[Service]
Type=simple
User=root
ExecStart=${RUN_SCRIPT}
Restart=on-failure
Environment=JAVA_OPTS=

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

# 8) Build frontend
echo "Building frontend in ${FRONTEND_DIR}..."
cd "${FRONTEND_DIR}"
# Install dependencies
if [ -f package-lock.json ] || [ -f package.json ]; then
  npm install --unsafe-perm
else
  echo "No package.json in frontend repo; skipping frontend build."
fi

# Build using npm (assumes `npm run build` exists)
if [ -f package.json ]; then
  npm run build --if-present
fi

# Verify build
if [ ! -d "${FRONTEND_BUILD_DIR}" ]; then
  echo "WARNING: Frontend build directory not found (${FRONTEND_BUILD_DIR}). Continuing but nginx may have no files to serve."
fi

# 9) Configure nginx to serve frontend and proxy /api to backend
echo "Configuring nginx (${NGINX_CONF})..."
cat > "${NGINX_CONF}" <<'NGINX_CONF'
server {
    listen 80;
    listen [::]:80;
    server_name _;

    root /opt/daily-meal-web-app/build;
    index index.html;

    # Serve static assets
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Proxy API calls to backend Java app (on localhost:8080)
    # Adjust the /api path if your backend uses a different base path.
    location /api/ {
        proxy_pass http://127.0.0.1:8080/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # If backend serves other endpoints not under /api, add additional proxy rules.
    # Example to proxy everything under /backend: 
    # location /backend/ { proxy_pass http://127.0.0.1:8080/backend/; ... }
}
NGINX_CONF

# Ensure nginx can read the built static files
chown -R nginx:nginx "${FRONTEND_BUILD_DIR}" 2>/dev/null || true

# SELinux: allow nginx to make network connections (so it can proxy)
if command -v setsebool >/dev/null 2>&1; then
  setsebool -P httpd_can_network_connect on || true
fi

# 10) Restart nginx to apply config
nginx -t && systemctl restart nginx

# 11) Final checks
echo
echo "Deployment complete. Service status:"
systemctl --no-pager status "${SERVICE_NAME}" | sed -n '1,6p'
echo
echo "NGINX status:"
systemctl --no-pager status nginx | sed -n '1,6p'
echo
echo "If everything started OK, your frontend should be reachable at: http://${LISTEN_IP}/"
echo "API proxy is configured so requests to http://${LISTEN_IP}/api/* are forwarded to the backend at localhost:${BACKEND_PORT}."
echo
echo "If you need HTTPS, obtain a certificate (for example with certbot) and update nginx config."
echo "If your backend exposes endpoints at locations other than /api, update ${NGINX_CONF} accordingly and restart nginx."
echo
echo "Logs:"
echo " - Backend logs: journalctl -u ${SERVICE_NAME} -f"
echo " - Nginx access/error logs: /var/log/nginx/"