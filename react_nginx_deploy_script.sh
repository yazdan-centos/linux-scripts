#!/bin/bash

################################################################################
# React + Nginx Deployment Script for AlmaLinux/RHEL
################################################################################
# 
# Description: Automated deployment, build, and configuration for React
#              applications with Nginx reverse proxy and SSL support
#
# Usage: sudo bash react_nginx_deploy.sh [OPTIONS]
#
# Options:
#   --app-name NAME        Application name (default: daily-meal-web-app)
#   --domain DOMAIN        Domain name (default: localhost)
#   --backend-url URL      Backend API URL (default: http://localhost:9091)
#   --port PORT           Frontend port (default: 3000)
#   --skip-build          Skip npm build (use existing build)
#   --skip-ssl            Skip SSL certificate setup
#   --dev-mode            Run in development mode (npm start)
#
# Requirements:
#   - AlmaLinux/RHEL-based system
#   - Root or sudo privileges
#   - Project cloned to /srv/repos/frontend/
#
# Author: Enhanced React + Nginx Deployment Script
# Version: 2.0
################################################################################

set -euo pipefail  # Exit on error, undefined variables, and pipe failures
IFS=$'\n\t'        # Set Internal Field Separator for safer parsing

################################################################################
# CONFIGURATION VARIABLES
################################################################################

# Application Configuration
APP_NAME="${APP_NAME:-daily-meal-web-app}"
APP_VERSION="${APP_VERSION:-0.0.1}"
DOMAIN_NAME="${DOMAIN_NAME:-localhost}"
BACKEND_URL="${BACKEND_URL:-http://localhost:9091}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
BACKEND_PORT="${BACKEND_PORT:-9091}"

# Node.js Configuration
readonly NODE_VERSION="20"
readonly NODE_MAJOR="${NODE_VERSION}"

# Directory Structure
readonly REPO_BASE="/srv/repos/frontend"
readonly PROJECT_DIR="${REPO_BASE}"
readonly BUILD_DIR="${PROJECT_DIR}/build"
readonly DEPLOY_DIR="/var/www/${APP_NAME}"
readonly NGINX_AVAILABLE="/etc/nginx/sites-available"
readonly NGINX_ENABLED="/etc/nginx/sites-enabled"
readonly SSL_DIR="/etc/nginx/ssl"

# Configuration Files
readonly PACKAGE_JSON="${PROJECT_DIR}/package.json"
readonly ENV_FILE="${PROJECT_DIR}/.env"
readonly CONFIG_JS="${PROJECT_DIR}/src/config.js"

# Nginx Configuration
readonly NGINX_CONF="${NGINX_AVAILABLE}/${APP_NAME}.conf"
readonly NGINX_SERVICE="nginx"

# Logging Configuration
readonly LOG_FILE="/var/log/${APP_NAME}_deploy_$(date +%Y%m%d_%H%M%S).log"
readonly BACKUP_DIR="/var/backups/${APP_NAME}"

# Script Options
SKIP_BUILD=false
SKIP_SSL=false
DEV_MODE=false
FORCE_REINSTALL=false

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

################################################################################
# UTILITY FUNCTIONS
################################################################################

# Logging function with timestamp
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
}

# Print colored info message
print_info() {
    echo -e "${BLUE}ℹ ${NC}$*"
    log "INFO" "$*"
}

# Print colored success message
print_success() {
    echo -e "${GREEN}✓${NC} $*"
    log "SUCCESS" "$*"
}

# Print colored warning message
print_warning() {
    echo -e "${YELLOW}⚠${NC} $*"
    log "WARNING" "$*"
}

# Print colored error message
print_error() {
    echo -e "${RED}✗${NC} $*"
    log "ERROR" "$*"
}

# Print section header
print_header() {
    echo -e "\n${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}\n"
    log "HEADER" "$*"
}

# Error handler
error_exit() {
    print_error "$1"
    print_error "Deployment failed. Check log file: ${LOG_FILE}"
    cleanup_on_failure
    exit 1
}

# Show progress spinner
show_spinner() {
    local pid=$1
    local message=$2
    local spin='-\|/'
    local i=0
    
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r${BLUE}⟳${NC} ${message} ${spin:$i:1}"
        sleep 0.1
    done
    printf "\r"
}

# Cleanup function for graceful exit
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        print_error "Script terminated with errors (exit code: ${exit_code})"
    fi
    log "INFO" "Script execution completed with exit code: ${exit_code}"
}

# Cleanup on failure
cleanup_on_failure() {
    print_info "Performing cleanup..."
}

trap cleanup EXIT

################################################################################
# ARGUMENT PARSING
################################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --app-name)
                APP_NAME="$2"
                shift 2
                ;;
            --domain)
                DOMAIN_NAME="$2"
                shift 2
                ;;
            --backend-url)
                BACKEND_URL="$2"
                shift 2
                ;;
            --port)
                FRONTEND_PORT="$2"
                shift 2
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --skip-ssl)
                SKIP_SSL=true
                shift
                ;;
            --dev-mode)
                DEV_MODE=true
                shift
                ;;
            --force)
                FORCE_REINSTALL=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat << EOF
Usage: sudo bash react_nginx_deploy.sh [OPTIONS]

Options:
  --app-name NAME        Application name (default: daily-meal-web-app)
  --domain DOMAIN        Domain name (default: localhost)
  --backend-url URL      Backend API URL (default: http://localhost:9091)
  --port PORT           Frontend port (default: 3000)
  --skip-build          Skip npm build (use existing build)
  --skip-ssl            Skip SSL certificate setup
  --dev-mode            Run in development mode (npm start)
  --force               Force reinstallation
  --help                Show this help message

Examples:
  sudo bash react_nginx_deploy.sh
  sudo bash react_nginx_deploy.sh --domain example.com --backend-url https://api.example.com
  sudo bash react_nginx_deploy.sh --dev-mode
EOF
}

################################################################################
# VALIDATION FUNCTIONS
################################################################################

# Check if script is run with sudo/root privileges
check_root() {
    print_info "Checking for root privileges..."
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root or with sudo privileges"
    fi
    print_success "Running with appropriate privileges"
}

# Check system compatibility
check_system() {
    print_info "Checking system compatibility..."
    
    if [ ! -f /etc/redhat-release ]; then
        error_exit "This script is designed for RHEL-based systems (AlmaLinux, Rocky Linux, CentOS)"
    fi
    
    local os_version=$(cat /etc/redhat-release)
    print_success "System detected: ${os_version}"
}

# Check internet connectivity
check_internet() {
    print_info "Checking internet connectivity..."
    
    if ! ping -c 1 -W 3 nodejs.org &> /dev/null; then
        print_warning "Cannot reach nodejs.org. Internet connectivity may be limited."
    else
        print_success "Internet connectivity confirmed"
    fi
}

# Check project structure
check_project_structure() {
    print_info "Validating project structure..."
    
    if [ ! -d "${PROJECT_DIR}" ]; then
        error_exit "Project directory not found: ${PROJECT_DIR}"
    fi
    print_success "Found project directory"
    
    if [ ! -f "${PACKAGE_JSON}" ]; then
        error_exit "package.json not found in ${PROJECT_DIR}"
    fi
    print_success "Found package.json"
    
    # Check for React project
    if ! grep -q "react" "${PACKAGE_JSON}"; then
        print_warning "This doesn't appear to be a React project"
    else
        print_success "React project detected"
    fi
}

# Check available disk space
check_disk_space() {
    print_info "Checking available disk space..."
    
    local available_space=$(df /var 2>/dev/null | tail -1 | awk '{print $4}' || df / | tail -1 | awk '{print $4}')
    local min_space=2097152  # 2GB in KB
    
    if [ "$available_space" -lt "$min_space" ]; then
        print_warning "Low disk space detected. At least 2GB recommended for React build."
    else
        print_success "Sufficient disk space available"
    fi
}

# Check Node.js installation
check_nodejs() {
    print_info "Checking Node.js installation..."
    
    if ! command -v node &> /dev/null; then
        print_warning "Node.js is not installed"
        install_nodejs
    else
        local node_version=$(node --version)
        print_success "Node.js version: ${node_version}"
        
        # Check if version is adequate (v18+)
        local major_version=$(echo "$node_version" | sed 's/v//' | cut -d. -f1)
        if [ "$major_version" -lt 18 ]; then
            print_warning "Node.js ${major_version} detected. Upgrading to Node.js ${NODE_VERSION}..."
            install_nodejs
        fi
    fi
}

# Check npm installation
check_npm() {
    print_info "Checking npm installation..."
    
    if ! command -v npm &> /dev/null; then
        error_exit "npm is not installed. This should have been installed with Node.js"
    fi
    
    local npm_version=$(npm --version)
    print_success "npm version: ${npm_version}"
}

################################################################################
# INSTALLATION FUNCTIONS
################################################################################

# Install Node.js
install_nodejs() {
    print_info "Installing Node.js ${NODE_VERSION}..."
    
    # Add NodeSource repository
    print_info "Adding NodeSource repository..."
    if curl -fsSL https://rpm.nodesource.com/setup_${NODE_MAJOR}.x | bash - &>> "${LOG_FILE}"; then
        print_success "NodeSource repository added"
    else
        error_exit "Failed to add NodeSource repository"
    fi
    
    # Install Node.js
    print_info "Installing Node.js package..."
    if dnf install -y nodejs &>> "${LOG_FILE}"; then
        print_success "Node.js installed successfully"
    else
        error_exit "Failed to install Node.js"
    fi
    
    # Verify installation
    if command -v node &> /dev/null; then
        local installed_version=$(node --version)
        print_success "Node.js installed: ${installed_version}"
    else
        error_exit "Node.js installation completed but command not found"
    fi
    
    # Verify npm
    if command -v npm &> /dev/null; then
        local npm_version=$(npm --version)
        print_success "npm installed: ${npm_version}"
    else
        error_exit "npm not found after Node.js installation"
    fi
}

# Install Nginx
install_nginx() {
    print_info "Checking Nginx installation..."
    
    if ! command -v nginx &> /dev/null; then
        print_info "Installing Nginx..."
        
        if dnf install -y nginx &>> "${LOG_FILE}"; then
            print_success "Nginx installed successfully"
        else
            error_exit "Failed to install Nginx"
        fi
    else
        local nginx_version=$(nginx -v 2>&1 | cut -d'/' -f2)
        print_success "Nginx already installed: ${nginx_version}"
    fi
    
    # Create sites-available and sites-enabled directories
    mkdir -p "${NGINX_AVAILABLE}"
    mkdir -p "${NGINX_ENABLED}"
    
    # Ensure main nginx.conf includes sites-enabled
    if ! grep -q "include.*sites-enabled" /etc/nginx/nginx.conf; then
        print_info "Configuring Nginx to include sites-enabled..."
        sed -i '/^http {/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
        print_success "Nginx configuration updated"
    fi
}

################################################################################
# BUILD FUNCTIONS
################################################################################

# Install npm dependencies
install_dependencies() {
    if [ "$SKIP_BUILD" = true ]; then
        print_info "Skipping dependency installation"
        return 0
    fi
    
    print_info "Installing npm dependencies..."
    
    cd "${PROJECT_DIR}"
    
    # Check if node_modules exists
    if [ -d "node_modules" ] && [ "$FORCE_REINSTALL" = false ]; then
        print_warning "node_modules already exists. Run with --force to reinstall."
        return 0
    fi
    
    # Create temporary log file for npm output
    local npm_log="/tmp/npm_install_$.log"
    
    # Clean install
    print_info "Running npm clean install (this may take several minutes)..."
    echo -e "${BLUE}ℹ${NC} You can monitor detailed progress in another terminal:"
    echo -e "  ${YELLOW}tail -f ${npm_log}${NC}"
    echo
    
    # Start npm install in background and capture output
    npm ci > "${npm_log}" 2>&1 &
    local npm_pid=$!
    
    # Show live progress
    show_npm_progress "${npm_pid}" "${npm_log}" "Installing dependencies"
    
    # Wait for npm to complete
    wait ${npm_pid}
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        print_success "Dependencies installed successfully"
        
        # Show summary of installed packages
        local pkg_count=$(find node_modules -maxdepth 1 -type d | wc -l)
        print_info "Installed packages: $((pkg_count - 1))"
    else
        print_warning "npm ci failed, trying npm install..."
        
        # Try npm install as fallback
        npm install > "${npm_log}" 2>&1 &
        npm_pid=$!
        
        show_npm_progress "${npm_pid}" "${npm_log}" "Installing dependencies (fallback)"
        
        wait ${npm_pid}
        exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            print_success "Dependencies installed successfully"
        else
            print_error "npm install failed. Last 20 lines of output:"
            tail -n 20 "${npm_log}"
            error_exit "Failed to install dependencies. Full log: ${npm_log}"
        fi
    fi
    
    # Copy npm log to main log
    cat "${npm_log}" >> "${LOG_FILE}"
    rm -f "${npm_log}"
}

# Configure environment variables
configure_environment() {
    print_info "Configuring environment variables..."
    
    # Extract backend host and port from URL
    local backend_host=$(echo "${BACKEND_URL}" | sed -n 's|.*://\([^:]*\).*|\1|p')
    local backend_port=$(echo "${BACKEND_URL}" | sed -n 's|.*:\([0-9]*\).*|\1|p')
    
    # If port not found in URL, use default
    if [ -z "${backend_port}" ]; then
        backend_port="${BACKEND_PORT}"
    fi
    
    # Create or update .env file
    cat > "${ENV_FILE}" << EOF
# Frontend Configuration
PORT=${FRONTEND_PORT}

# Backend API Configuration
REACT_APP_API_URL=${BACKEND_URL}/api
REACT_APP_IPADDRESS=${backend_host}
REACT_APP_PORT=${backend_port}

# Build Configuration
GENERATE_SOURCEMAP=false
EOF
    
    print_success "Environment file created: ${ENV_FILE}"
    
    # Update config.js if it exists
    if [ -f "${CONFIG_JS}" ]; then
        print_info "Updating config.js..."
        
        # Backup original
        cp "${CONFIG_JS}" "${CONFIG_JS}.backup"
        
        # Update config.js
        cat > "${CONFIG_JS}" << 'EOF'
const IPADDRESS = process.env.REACT_APP_IPADDRESS;
const PORT = process.env.REACT_APP_PORT;
const BASE_URL = `https://${IPADDRESS}:${PORT}/api`;

export { IPADDRESS, PORT, BASE_URL };
EOF
        
        print_success "config.js updated"
    fi
}

# Build React application
build_application() {
    if [ "$SKIP_BUILD" = true ]; then
        print_info "Skipping build step as requested"
        return 0
    fi
    
    print_header "Building React Application"
    
    cd "${PROJECT_DIR}"
    
    print_info "Running production build (this may take several minutes)..."
    print_info "Build command: npm run build"
    
    # Run build in background to show progress
    npm run build &>> "${LOG_FILE}" &
    local build_pid=$!
    
    show_spinner $build_pid "Building React application"
    
    # Wait for build to complete and check exit status
    wait $build_pid
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        print_success "Application built successfully"
    else
        error_exit "Build failed. Check log: ${LOG_FILE}"
    fi
    
    # Verify build directory exists
    if [ ! -d "${BUILD_DIR}" ]; then
        error_exit "Build directory not found: ${BUILD_DIR}"
    fi
    
    # Check build size
    local build_size=$(du -sh "${BUILD_DIR}" | cut -f1)
    print_success "Build size: ${build_size}"
}

# Verify build
verify_build() {
    print_info "Verifying build..."
    
    if [ ! -d "${BUILD_DIR}" ]; then
        error_exit "Build directory not found. Run without --skip-build option."
    fi
    
    # Check for index.html
    if [ ! -f "${BUILD_DIR}/index.html" ]; then
        error_exit "index.html not found in build directory"
    fi
    print_success "Build verified successfully"
}

################################################################################
# DEPLOYMENT FUNCTIONS
################################################################################

# Create deployment directories
create_directories() {
    print_info "Creating deployment directory structure..."
    
    mkdir -p "${DEPLOY_DIR}"
    mkdir -p "${BACKUP_DIR}"
    mkdir -p "${SSL_DIR}"
    
    print_success "Directory structure created"
}

# Backup existing deployment
backup_existing() {
    print_info "Backing up existing deployment..."
    
    local backup_timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/${APP_NAME}_backup_${backup_timestamp}.tar.gz"
    
    if [ -d "${DEPLOY_DIR}" ] && [ "$(ls -A ${DEPLOY_DIR})" ]; then
        tar -czf "${backup_file}" -C "${DEPLOY_DIR}" . 2>/dev/null || true
        
        if [ -f "${backup_file}" ]; then
            print_success "Backup created: ${backup_file}"
        fi
    else
        print_info "No existing deployment to backup"
    fi
}

# Deploy build files
deploy_build() {
    print_info "Deploying build files to ${DEPLOY_DIR}..."
    
    # Clear existing deployment
    if [ -d "${DEPLOY_DIR}" ]; then
        rm -rf "${DEPLOY_DIR:?}"/*
    fi
    
    # Copy build files
    if cp -r "${BUILD_DIR}"/* "${DEPLOY_DIR}/"; then
        print_success "Build files deployed successfully"
    else
        error_exit "Failed to deploy build files"
    fi
    
    # Set proper permissions
    chown -R nginx:nginx "${DEPLOY_DIR}"
    find "${DEPLOY_DIR}" -type f -exec chmod 644 {} \;
    find "${DEPLOY_DIR}" -type d -exec chmod 755 {} \;
    
    print_success "Permissions set correctly"
}

################################################################################
# NGINX CONFIGURATION
################################################################################

# Create Nginx configuration
create_nginx_config() {
    print_info "Creating Nginx configuration..."
    
    local use_ssl="false"
    if [ "$SKIP_SSL" = false ] && [ "${DOMAIN_NAME}" != "localhost" ]; then
        use_ssl="true"
    fi
    
    cat > "${NGINX_CONF}" << EOF
# ${APP_NAME} - Nginx Configuration
# Generated: $(date)

upstream backend {
    server localhost:${BACKEND_PORT};
}

server {
    listen 80;
    server_name ${DOMAIN_NAME};
    
    root ${DEPLOY_DIR};
    index index.html;
    
    # Logging
    access_log /var/log/nginx/${APP_NAME}_access.log;
    error_log /var/log/nginx/${APP_NAME}_error.log;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/x-javascript application/xml+rss application/json application/javascript;
    
    # Static files with caching
    location /static/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    
    # API proxy
    location /api/ {
        proxy_pass ${BACKEND_URL}/api/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # React Router - serve index.html for all non-file requests
    location / {
        try_files \$uri \$uri/ /index.html;
    }
    
    # Deny access to hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF
    
    print_success "Nginx configuration created: ${NGINX_CONF}"
}

# Enable Nginx site
enable_nginx_site() {
    print_info "Enabling Nginx site..."
    
    # Create symlink
    ln -sf "${NGINX_CONF}" "${NGINX_ENABLED}/${APP_NAME}.conf"
    
    print_success "Site enabled"
}

# Test Nginx configuration
test_nginx_config() {
    print_info "Testing Nginx configuration..."
    
    if nginx -t &>> "${LOG_FILE}"; then
        print_success "Nginx configuration is valid"
    else
        print_error "Nginx configuration test failed"
        nginx -t
        error_exit "Please fix Nginx configuration errors"
    fi
}

# Configure firewall
configure_firewall() {
    print_info "Checking firewall configuration..."
    
    if systemctl is-active --quiet firewalld; then
        print_info "Firewalld is active. Configuring HTTP/HTTPS..."
        
        firewall-cmd --permanent --add-service=http &>> "${LOG_FILE}" || true
        firewall-cmd --permanent --add-service=https &>> "${LOG_FILE}" || true
        firewall-cmd --reload &>> "${LOG_FILE}" || true
        
        print_success "Firewall configured"
    else
        print_info "Firewalld is not active, skipping firewall configuration"
    fi
}

# Setup SSL certificates
setup_ssl() {
    if [ "$SKIP_SSL" = true ]; then
        print_info "Skipping SSL setup as requested"
        return 0
    fi
    
    if [ "${DOMAIN_NAME}" = "localhost" ]; then
        print_info "Skipping SSL for localhost"
        return 0
    fi
    
    print_info "Setting up SSL certificates..."
    
    # Check if certbot is installed
    if ! command -v certbot &> /dev/null; then
        print_info "Installing certbot..."
        dnf install -y certbot python3-certbot-nginx &>> "${LOG_FILE}" || true
    fi
    
    if command -v certbot &> /dev/null; then
        print_info "Run the following command to obtain SSL certificate:"
        echo -e "${YELLOW}sudo certbot --nginx -d ${DOMAIN_NAME}${NC}"
        print_warning "SSL setup requires manual intervention"
    else
        print_warning "Certbot installation failed. SSL must be configured manually."
    fi
}

# Start/Restart Nginx
restart_nginx() {
    print_info "Restarting Nginx..."
    
    # Enable Nginx to start on boot
    if systemctl enable nginx &>> "${LOG_FILE}"; then
        print_success "Nginx enabled for auto-start on boot"
    fi
    
    # Restart Nginx
    if systemctl restart nginx; then
        print_success "Nginx restarted successfully"
    else
        error_exit "Failed to restart Nginx"
    fi
    
    # Verify Nginx is running
    if systemctl is-active --quiet nginx; then
        print_success "Nginx is running"
    else
        error_exit "Nginx is not running"
    fi
}

################################################################################
# DEVELOPMENT MODE
################################################################################

# Run in development mode
run_dev_mode() {
    if [ "$DEV_MODE" = false ]; then
        return 0
    fi
    
    print_header "Running in Development Mode"
    
    cd "${PROJECT_DIR}"
    
    print_info "Starting development server..."
    print_info "Press Ctrl+C to stop"
    echo
    
    # Run the development server
    npm start
}

################################################################################
# VERIFICATION FUNCTIONS
################################################################################

# Verify deployment
verify_deployment() {
    if [ "$DEV_MODE" = true ]; then
        return 0
    fi
    
    print_info "Verifying deployment..."
    
    # Check if Nginx is running
    if systemctl is-active --quiet nginx; then
        print_success "Nginx is running"
    else
        error_exit "Nginx is not running"
    fi
    
    # Check if build files exist
    if [ -f "${DEPLOY_DIR}/index.html" ]; then
        print_success "Build files deployed correctly"
    else
        error_exit "index.html not found at expected location"
    fi
    
    # Check Nginx configuration
    if [ -L "${NGINX_ENABLED}/${APP_NAME}.conf" ]; then
        print_success "Nginx site configuration enabled"
    else
        print_warning "Nginx site configuration not properly enabled"
    fi
}

# Health check
health_check() {
    if [ "$DEV_MODE" = true ]; then
        return 0
    fi
    
    print_info "Performing health check..."
    
    sleep 2
    
    # Try to access the application
    if curl -s -f "http://localhost/" &>/dev/null; then
        print_success "Application is accessible"
    else
        print_warning "Application may not be accessible yet"
    fi
}

################################################################################
# DISPLAY FUNCTIONS
################################################################################

# Display deployment information
display_deployment_info() {
    print_header "Deployment Complete!"
    
    echo -e "${GREEN}${APP_NAME} has been successfully deployed!${NC}\n"
    
    echo -e "${CYAN}Application Information:${NC}"
    echo -e "  Name:          ${MAGENTA}${APP_NAME}${NC}"
    echo -e "  Version:       ${MAGENTA}${APP_VERSION}${NC}"
    echo -e "  Domain:        ${MAGENTA}${DOMAIN_NAME}${NC}"
    echo -e "  Deploy Path:   ${MAGENTA}${DEPLOY_DIR}${NC}"
    
    echo -e "\n${CYAN}Access URLs:${NC}"
    echo -e "  HTTP:          ${YELLOW}http://${DOMAIN_NAME}${NC}"
    if [ "$SKIP_SSL" = false ] && [ "${DOMAIN_NAME}" != "localhost" ]; then
        echo -e "  HTTPS:         ${YELLOW}https://${DOMAIN_NAME}${NC}"
    fi
    
    echo -e "\n${CYAN}Backend Configuration:${NC}"
    echo -e "  API URL:       ${MAGENTA}${BACKEND_URL}${NC}"
    echo -e "  Proxy Path:    ${MAGENTA}/api/*${NC}"
    
    echo -e "\n${CYAN}Nginx Management:${NC}"
    echo -e "  Status:        ${YELLOW}sudo systemctl status nginx${NC}"
    echo -e "  Start:         ${YELLOW}sudo systemctl start nginx${NC}"
    echo -e "  Stop:          ${YELLOW}sudo systemctl stop nginx${NC}"
    echo -e "  Restart:       ${YELLOW}sudo systemctl restart nginx${NC}"
    echo -e "  Test Config:   ${YELLOW}sudo nginx -t${NC}"
    echo -e "  Reload:        ${YELLOW}sudo systemctl reload nginx${NC}"
    
    echo -e "\n${CYAN}Files and Directories:${NC}"
    echo -e "  Source:        ${YELLOW}${PROJECT_DIR}${NC}"
    echo -e "  Build:         ${YELLOW}${BUILD_DIR}${NC}"
    echo -e "  Deployment:    ${YELLOW}${DEPLOY_DIR}${NC}"
    echo -e "  Nginx Config:  ${YELLOW}${NGINX_CONF}${NC}"
    echo -e "  Backups:       ${YELLOW}${BACKUP_DIR}${NC}"
    echo -e "  Logs:          ${YELLOW}/var/log/nginx/${APP_NAME}_*.log${NC}"
    
    echo -e "\n${CYAN}Logs:${NC}"
    echo -e "  Access Log:    ${YELLOW}tail -f /var/log/nginx/${APP_NAME}_access.log${NC}"
    echo -e "  Error Log:     ${YELLOW}tail -f /var/log/nginx/${APP_NAME}_error.log${NC}"
    echo -e "  Deployment:    ${YELLOW}${LOG_FILE}${NC}"
    
    echo -e "\n${YELLOW}Next Steps:${NC}"
    echo -e "  1. Test the application: ${YELLOW}curl http://${DOMAIN_NAME}${NC}"
    echo -e "  2. Check Nginx logs for any issues"
    echo -e "  3. Configure SSL certificate (if not using localhost)"
    echo -e "  4. Set up monitoring and backup strategies"
    echo -e "  5. Configure CDN if needed"
    
    if [ "${DOMAIN_NAME}" != "localhost" ] && [ "$SKIP_SSL" = false ]; then
        echo -e "\n${YELLOW}SSL Certificate Setup:${NC}"
        echo -e "  Run: ${YELLOW}sudo certbot --nginx -d ${DOMAIN_NAME}${NC}"
        echo -e "  Auto-renewal: ${YELLOW}sudo certbot renew --dry-run${NC}"
    fi
    
    echo -e "\n${YELLOW}Rebuild and Redeploy:${NC}"
    echo -e "  ${YELLOW}cd ${PROJECT_DIR} && sudo bash react_nginx_deploy.sh${NC}"
    
    echo -e "\n${GREEN}Documentation: https://reactjs.org/ | https://nginx.org/en/docs/${NC}\n"
}

# Show Nginx status
show_nginx_status() {
    if [ "$DEV_MODE" = true ]; then
        return 0
    fi
    
    print_header "Nginx Status"
    systemctl status nginx --no-pager || true
    
    echo -e "\n${CYAN}Recent Access Logs:${NC}"
    if [ -f "/var/log/nginx/${APP_NAME}_access.log" ]; then
        tail -n 10 "/var/log/nginx/${APP_NAME}_access.log"
    else
        echo "No access logs available yet"
    fi
    
    echo -e "\n${CYAN}Recent Error Logs:${NC}"
    if [ -f "/var/log/nginx/${APP_NAME}_error.log" ]; then
        tail -n 10 "/var/log/nginx/${APP_NAME}_error.log"
    else
        echo "No error logs available yet"
    fi
}

################################################################################
# MONITORING AND MAINTENANCE
################################################################################

# Create monitoring script
create_monitoring_script() {
    if [ "$DEV_MODE" = true ]; then
        return 0
    fi
    
    print_info "Creating monitoring script..."
    
    local monitor_script="${DEPLOY_DIR}/../monitor.sh"
    
    cat > "${monitor_script}" << 'MONITOR_EOF'
#!/bin/bash

# Frontend Monitoring Script
APP_NAME="APP_NAME_PLACEHOLDER"
DEPLOY_DIR="DEPLOY_DIR_PLACEHOLDER"
DOMAIN_NAME="DOMAIN_NAME_PLACEHOLDER"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "========================================="
echo "  ${APP_NAME} Status Monitor"
echo "========================================="
echo

# Check Nginx status
echo -n "Nginx Status: "
if systemctl is-active --quiet nginx; then
    echo -e "${GREEN}RUNNING${NC}"
else
    echo -e "${RED}STOPPED${NC}"
fi

# Check HTTP response
echo -n "HTTP Response: "
if curl -s -f "http://${DOMAIN_NAME}/" &>/dev/null; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAILED${NC}"
fi

# Check disk usage
echo -n "Disk Usage: "
DISK_USAGE=$(df -h "${DEPLOY_DIR}" | tail -1 | awk '{print $5}')
echo -e "${YELLOW}${DISK_USAGE}${NC}"

# Count files in deployment
echo -n "Deployed Files: "
FILE_COUNT=$(find "${DEPLOY_DIR}" -type f | wc -l)
echo -e "${YELLOW}${FILE_COUNT}${NC}"

# Recent errors
echo
echo "Recent Nginx Errors (last 5):"
if [ -f "/var/log/nginx/${APP_NAME}_error.log" ]; then
    tail -n 5 "/var/log/nginx/${APP_NAME}_error.log" || echo "No recent errors"
else
    echo "Log file not found"
fi

# Recent requests
echo
echo "Recent HTTP Requests (last 5):"
if [ -f "/var/log/nginx/${APP_NAME}_access.log" ]; then
    tail -n 5 "/var/log/nginx/${APP_NAME}_access.log"
else
    echo "Log file not found"
fi

echo
echo "========================================="
MONITOR_EOF
    
    # Replace placeholders
    sed -i "s/APP_NAME_PLACEHOLDER/${APP_NAME}/g" "${monitor_script}"
    sed -i "s|DEPLOY_DIR_PLACEHOLDER|${DEPLOY_DIR}|g" "${monitor_script}"
    sed -i "s/DOMAIN_NAME_PLACEHOLDER/${DOMAIN_NAME}/g" "${monitor_script}"
    
    chmod +x "${monitor_script}"
    
    print_success "Monitoring script created: ${monitor_script}"
}

# Create maintenance script
create_maintenance_script() {
    if [ "$DEV_MODE" = true ]; then
        return 0
    fi
    
    print_info "Creating maintenance script..."
    
    local maint_script="${DEPLOY_DIR}/../maintenance.sh"
    
    cat > "${maint_script}" << 'MAINT_EOF'
#!/bin/bash

# Frontend Maintenance Script
APP_NAME="APP_NAME_PLACEHOLDER"
PROJECT_DIR="PROJECT_DIR_PLACEHOLDER"
DEPLOY_DIR="DEPLOY_DIR_PLACEHOLDER"
BACKUP_DIR="BACKUP_DIR_PLACEHOLDER"

show_help() {
    cat << EOF
Usage: sudo bash maintenance.sh [COMMAND]

Commands:
  backup       Create a backup of the deployment
  clean-logs   Clean old Nginx log files (older than 30 days)
  clean-backups Clean old backups (older than 90 days)
  rebuild      Rebuild and redeploy the application
  rollback     Rollback to previous version
  clear-cache  Clear Nginx cache
  restart      Restart Nginx
  help         Show this help message

Examples:
  sudo bash maintenance.sh backup
  sudo bash maintenance.sh rebuild
  sudo bash maintenance.sh rollback
EOF
}

backup_deployment() {
    echo "Creating backup..."
    local backup_file="${BACKUP_DIR}/${APP_NAME}_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czf "${backup_file}" -C "${DEPLOY_DIR}" .
    echo "Backup created: ${backup_file}"
}

clean_logs() {
    echo "Cleaning old logs..."
    find /var/log/nginx -name "${APP_NAME}_*.log.*" -mtime +30 -delete
    echo "Old logs cleaned"
}

clean_backups() {
    echo "Cleaning old backups..."
    find "${BACKUP_DIR}" -name "*.tar.gz" -mtime +90 -delete
    echo "Old backups cleaned"
}

rebuild_application() {
    echo "Rebuilding application..."
    cd "${PROJECT_DIR}"
    bash react_nginx_deploy.sh
}

rollback_deployment() {
    echo "Rolling back to previous version..."
    local latest_backup=$(ls -t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | head -n 1)
    
    if [ -z "${latest_backup}" ]; then
        echo "No backup found for rollback"
        exit 1
    fi
    
    echo "Restoring from: ${latest_backup}"
    rm -rf "${DEPLOY_DIR:?}"/*
    tar -xzf "${latest_backup}" -C "${DEPLOY_DIR}"
    systemctl reload nginx
    echo "Rollback completed"
}

clear_nginx_cache() {
    echo "Clearing Nginx cache..."
    systemctl reload nginx
    echo "Cache cleared"
}

restart_nginx() {
    echo "Restarting Nginx..."
    systemctl restart nginx
    echo "Nginx restarted"
}

case "${1:-help}" in
    backup)
        backup_deployment
        ;;
    clean-logs)
        clean_logs
        ;;
    clean-backups)
        clean_backups
        ;;
    rebuild)
        rebuild_application
        ;;
    rollback)
        rollback_deployment
        ;;
    clear-cache)
        clear_nginx_cache
        ;;
    restart)
        restart_nginx
        ;;
    help|*)
        show_help
        ;;
esac
MAINT_EOF
    
    # Replace placeholders
    sed -i "s/APP_NAME_PLACEHOLDER/${APP_NAME}/g" "${maint_script}"
    sed -i "s|PROJECT_DIR_PLACEHOLDER|${PROJECT_DIR}|g" "${maint_script}"
    sed -i "s|DEPLOY_DIR_PLACEHOLDER|${DEPLOY_DIR}|g" "${maint_script}"
    sed -i "s|BACKUP_DIR_PLACEHOLDER|${BACKUP_DIR}|g" "${maint_script}"
    
    chmod +x "${maint_script}"
    
    print_success "Maintenance script created: ${maint_script}"
}

# Create update script
create_update_script() {
    if [ "$DEV_MODE" = true ]; then
        return 0
    fi
    
    print_info "Creating update script..."
    
    local update_script="${PROJECT_DIR}/update.sh"
    
    cat > "${update_script}" << 'UPDATE_EOF'
#!/bin/bash

# Quick Update Script
# This script pulls latest changes and rebuilds

PROJECT_DIR="PROJECT_DIR_PLACEHOLDER"

echo "Updating application..."

cd "${PROJECT_DIR}"

# Pull latest changes
echo "Pulling latest changes from git..."
git pull

# Run deployment script
echo "Rebuilding and deploying..."
sudo bash react_nginx_deploy.sh

echo "Update complete!"
UPDATE_EOF
    
    sed -i "s|PROJECT_DIR_PLACEHOLDER|${PROJECT_DIR}|g" "${update_script}"
    
    chmod +x "${update_script}"
    
    print_success "Update script created: ${update_script}"
}

################################################################################
# SEO AND PERFORMANCE
################################################################################

# Configure performance optimizations
configure_performance() {
    print_info "Configuring performance optimizations..."
    
    # Create robots.txt if not exists
    if [ ! -f "${DEPLOY_DIR}/robots.txt" ]; then
        cat > "${DEPLOY_DIR}/robots.txt" << EOF
User-agent: *
Allow: /
Sitemap: http://${DOMAIN_NAME}/sitemap.xml
EOF
        print_success "robots.txt created"
    fi
    
    # Set proper MIME types
    if [ -f "/etc/nginx/mime.types" ]; then
        print_success "MIME types already configured"
    fi
}

# Create systemd timer for log rotation
create_log_rotation() {
    print_info "Configuring log rotation..."
    
    cat > "/etc/logrotate.d/${APP_NAME}" << EOF
/var/log/nginx/${APP_NAME}_*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl reload nginx > /dev/null 2>&1 || true
    endscript
}
EOF
    
    print_success "Log rotation configured"
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
    # Parse command-line arguments
    parse_arguments "$@"
    
    # Initialize log file
    touch "${LOG_FILE}"
    chmod 600 "${LOG_FILE}"
    
    print_header "React + Nginx Deployment"
    
    log "INFO" "Starting deployment process"
    log "INFO" "Application: ${APP_NAME} v${APP_VERSION}"
    log "INFO" "Domain: ${DOMAIN_NAME}"
    log "INFO" "Script version: 2.0"
    
    # Pre-deployment checks
    print_header "Pre-Deployment Checks"
    check_root
    check_system
    check_internet
    check_project_structure
    check_disk_space
    check_nodejs
    check_npm
    
    # Configure environment
    print_header "Configuring Environment"
    configure_environment
    
    # Install dependencies and build
    if [ "$SKIP_BUILD" = false ]; then
        print_header "Installing Dependencies"
        install_dependencies
        
        print_header "Building Application"
        build_application
    else
        print_header "Verifying Existing Build"
        verify_build
    fi
    
    # Install Nginx
    print_header "Setting Up Nginx"
    install_nginx
    
    # Deployment phase
    print_header "Deploying Application"
    create_directories
    backup_existing
    deploy_build
    
    # Configure Nginx
    print_header "Configuring Nginx"
    create_nginx_config
    enable_nginx_site
    test_nginx_config
    configure_firewall
    configure_performance
    create_log_rotation
    
    # SSL setup
    if [ "$SKIP_SSL" = false ]; then
        print_header "SSL Configuration"
        setup_ssl
    fi
    
    # Start Nginx
    print_header "Starting Services"
    restart_nginx
    
    # Create utility scripts
    print_header "Creating Utility Scripts"
    create_monitoring_script
    create_maintenance_script
    create_update_script
    
    # Verification phase
    if [ "$DEV_MODE" = false ]; then
        print_header "Verifying Deployment"
        verify_deployment
        health_check
    fi
    
    # Display results
    display_deployment_info
    
    if [ "$DEV_MODE" = false ]; then
        show_nginx_status
    fi
    
    log "INFO" "Deployment completed successfully"
    
    # Run in dev mode if requested
    if [ "$DEV_MODE" = true ]; then
        run_dev_mode
    fi
}

# Execute main function
main "$@"