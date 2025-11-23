#!/bin/bash

################################################################################
# Spring Boot Application Deployment Script for AlmaLinux/RHEL
################################################################################
# 
# Description: Automated deployment, configuration, and service setup for
#              Spring Boot applications with comprehensive error handling
#
# Usage: sudo bash spring_boot_deploy.sh [OPTIONS]
#
# Options:
#   --app-name NAME        Application name (default: rahkaran-util)
#   --app-version VERSION  Application version (default: 0.0.1)
#   --port PORT           Server port (default: 9091)
#   --skip-build          Skip Maven build (use existing JAR)
#   --dev-mode            Run in development mode (no systemd service)
#
# Requirements:
#   - AlmaLinux/RHEL-based system
#   - Root or sudo privileges
#   - Java 21 installed
#   - Maven installed (if building)
#   - PostgreSQL accessible
#
# Author: Enhanced Spring Boot Deployment Script
# Version: 2.0
################################################################################

set -euo pipefail  # Exit on error, undefined variables, and pipe failures
IFS=$'\n\t'        # Set Internal Field Separator for safer parsing

################################################################################
# CONFIGURATION VARIABLES
################################################################################

# Application Configuration (can be overridden by command-line args)
APP_NAME="${APP_NAME:-rahkaran-util}"
APP_VERSION="${APP_VERSION:-0.0.1}"
APP_PORT="${APP_PORT:-9091}"
APP_GROUP_ID="com.mapnaom"
JAVA_VERSION="21"

# Directory Structure
readonly BASE_DIR="/opt/springboot"
readonly APP_DIR="${BASE_DIR}/${APP_NAME}"
readonly APP_LOGS_DIR="${APP_DIR}/logs"
readonly APP_CONFIG_DIR="${APP_DIR}/config"
readonly APP_BACKUP_DIR="${APP_DIR}/backups"
readonly APP_LIB_DIR="${APP_DIR}/lib"

# Source Configuration
readonly PROJECT_DIR="${PWD}"
readonly POM_FILE="${PROJECT_DIR}/pom.xml"
readonly TARGET_DIR="${PROJECT_DIR}/target"
readonly APP_PROPERTIES="${PROJECT_DIR}/src/main/resources/application.properties"

# Service Configuration
readonly SERVICE_NAME="${APP_NAME}"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly SERVICE_USER="${APP_NAME}"
readonly SERVICE_GROUP="${APP_NAME}"

# Java Configuration
readonly JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21}"
readonly JAVA_OPTS_DEFAULT="-Xms512m -Xmx2048m -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
readonly JAVA_OPTS="${JAVA_OPTS:-$JAVA_OPTS_DEFAULT}"

# Logging Configuration
readonly LOG_FILE="/var/log/${APP_NAME}_deploy_$(date +%Y%m%d_%H%M%S).log"
readonly APP_LOG_FILE="${APP_LOGS_DIR}/application.log"

# Database Configuration (from application.properties)
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="food_reservation_db"
DB_USER="yazdanparast"
DB_PASS="Map@123456"

# Script Options
SKIP_BUILD=false
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
    if [ "$DEV_MODE" = false ] && [ -f "${SERVICE_FILE}" ]; then
        print_info "Stopping service if running..."
        sudo systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    fi
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
            --app-version)
                APP_VERSION="$2"
                shift 2
                ;;
            --port)
                APP_PORT="$2"
                shift 2
                ;;
            --skip-build)
                SKIP_BUILD=true
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
Usage: sudo bash spring_boot_deploy.sh [OPTIONS]

Options:
  --app-name NAME        Application name (default: rahkaran-util)
  --app-version VERSION  Application version (default: 0.0.1)
  --port PORT           Server port (default: 9091)
  --skip-build          Skip Maven build (use existing JAR)
  --dev-mode            Run in development mode (no systemd service)
  --force               Force reinstallation
  --help                Show this help message

Examples:
  sudo bash spring_boot_deploy.sh
  sudo bash spring_boot_deploy.sh --app-name myapp --port 8080
  sudo bash spring_boot_deploy.sh --skip-build --dev-mode
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

# Check Java installation
check_java() {
    print_info "Checking Java ${JAVA_VERSION} installation..."
    
    if ! command -v java &> /dev/null; then
        print_warning "Java is not installed"
        install_java
    else
        local java_version=$(java -version 2>&1 | head -n 1 | awk -F '"' '{print $2}')
        print_success "Java version: ${java_version}"
        
        # Verify Java version is 21 or higher
        local major_version=$(echo "$java_version" | cut -d. -f1)
        if [ "$major_version" -lt "$JAVA_VERSION" ]; then
            print_warning "Java ${JAVA_VERSION} or higher is required. Current version: ${java_version}"
            print_info "Installing Java ${JAVA_VERSION}..."
            install_java
        fi
    fi
}

# Install Java
install_java() {
    print_info "Installing Java ${JAVA_VERSION}..."
    
    # Install Java 21 from repository
    if dnf list available java-21-openjdk-devel &>/dev/null; then
        print_info "Installing OpenJDK ${JAVA_VERSION} from repository..."
        
        if dnf install -y java-21-openjdk-devel; then
            print_success "Java ${JAVA_VERSION} installed successfully"
        else
            error_exit "Failed to install Java ${JAVA_VERSION}"
        fi
    else
        error_exit "Java ${JAVA_VERSION} package not available in repositories. Please install manually."
    fi
    
    # Verify installation
    if command -v java &> /dev/null; then
        local installed_version=$(java -version 2>&1 | head -n 1 | awk -F '"' '{print $2}')
        print_success "Java installed: ${installed_version}"
        
        # Set JAVA_HOME if not set
        if [ -z "${JAVA_HOME}" ]; then
            export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
            print_info "JAVA_HOME set to: ${JAVA_HOME}"
            
            # Make JAVA_HOME persistent
            if ! grep -q "JAVA_HOME" /etc/profile.d/java.sh 2>/dev/null; then
                cat > /etc/profile.d/java.sh << EOF
# Java Configuration
export JAVA_HOME=${JAVA_HOME}
export PATH=\${JAVA_HOME}/bin:\${PATH}
EOF
                chmod +x /etc/profile.d/java.sh
                print_success "JAVA_HOME configured system-wide"
            fi
        fi
    else
        error_exit "Java installation completed but command not found"
    fi
}

# Check Maven installation (only if building)
check_maven() {
    if [ "$SKIP_BUILD" = true ]; then
        print_info "Skipping Maven check (build step skipped)"
        return 0
    fi
    
    print_info "Checking Maven installation..."
    
    if ! command -v mvn &> /dev/null; then
        print_warning "Maven is not installed"
        install_maven
    else
        local mvn_version=$(mvn -version 2>&1 | head -n 1)
        print_success "Maven detected: ${mvn_version}"
    fi
}

# Install Maven
install_maven() {
    print_info "Installing Apache Maven..."
    
    local maven_version="3.9.9"
    local maven_download_url="https://dlcdn.apache.org/maven/maven-3/${maven_version}/binaries/apache-maven-${maven_version}-bin.tar.gz"
    local maven_install_dir="/opt/maven"
    local maven_home="${maven_install_dir}/apache-maven-${maven_version}"
    
    # Create installation directory
    mkdir -p "${maven_install_dir}"
    
    # Download Maven
    print_info "Downloading Maven ${maven_version}..."
    if ! curl -fsSL "${maven_download_url}" -o "/tmp/apache-maven-${maven_version}-bin.tar.gz"; then
        error_exit "Failed to download Maven. Check your internet connection."
    fi
    print_success "Maven downloaded successfully"
    
    # Extract Maven
    print_info "Extracting Maven..."
    if ! tar -xzf "/tmp/apache-maven-${maven_version}-bin.tar.gz" -C "${maven_install_dir}"; then
        error_exit "Failed to extract Maven archive"
    fi
    print_success "Maven extracted to ${maven_home}"
    
    # Clean up download
    rm -f "/tmp/apache-maven-${maven_version}-bin.tar.gz"
    
    # Create symbolic link for easier updates
    ln -sf "${maven_home}" "${maven_install_dir}/current"
    
    # Set up environment variables
    print_info "Configuring Maven environment..."
    
    # Create profile.d script for system-wide Maven configuration
    cat > /etc/profile.d/maven.sh << EOF
# Apache Maven Configuration
export MAVEN_HOME=${maven_install_dir}/current
export PATH=\${MAVEN_HOME}/bin:\${PATH}
EOF
    
    chmod +x /etc/profile.d/maven.sh
    
    # Source the profile to make Maven available in current session
    export MAVEN_HOME="${maven_install_dir}/current"
    export PATH="${MAVEN_HOME}/bin:${PATH}"
    
    # Verify installation
    if command -v mvn &> /dev/null; then
        local installed_version=$(mvn -version 2>&1 | head -n 1)
        print_success "Maven installed successfully: ${installed_version}"
    else
        error_exit "Maven installation completed but command not found. Try logging out and back in."
    fi
    
    print_info "Maven home: ${MAVEN_HOME}"
    print_info "Maven will be available system-wide after logout/login or by running: source /etc/profile.d/maven.sh"
}

# Check project structure
check_project_structure() {
    print_info "Validating project structure..."
    
    if [ ! -f "${POM_FILE}" ]; then
        error_exit "pom.xml not found in ${PROJECT_DIR}"
    fi
    print_success "Found pom.xml"
    
    if [ ! -f "${APP_PROPERTIES}" ]; then
        print_warning "application.properties not found at expected location"
    else
        print_success "Found application.properties"
    fi
}

# Check database connectivity
check_database() {
    print_info "Checking PostgreSQL database connectivity..."
    
    # Extract database configuration from application.properties if it exists
    if [ -f "${APP_PROPERTIES}" ]; then
        DB_HOST=$(grep "spring.datasource.url" "${APP_PROPERTIES}" | sed -n 's/.*:\/\/\([^:]*\):.*/\1/p' || echo "localhost")
        DB_PORT=$(grep "spring.datasource.url" "${APP_PROPERTIES}" | sed -n 's/.*:\([0-9]*\)\/.*/\1/p' || echo "5432")
        DB_NAME=$(grep "spring.datasource.url" "${APP_PROPERTIES}" | sed -n 's/.*\/\([^?]*\).*/\1/p' || echo "food_reservation_db")
        DB_USER=$(grep "spring.datasource.username" "${APP_PROPERTIES}" | cut -d'=' -f2 | tr -d ' ' || echo "yazdanparast")
    fi
    
    print_info "Database: ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    
    # Test database connection
    if PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1" &>/dev/null; then
        print_success "Database connection successful"
    else
        print_warning "Cannot connect to database. Application may fail to start."
        print_warning "Ensure PostgreSQL is running and credentials are correct."
    fi
}

# Check if port is available
check_port() {
    print_info "Checking if port ${APP_PORT} is available..."
    
    if ss -tuln | grep -q ":${APP_PORT} "; then
        print_warning "Port ${APP_PORT} is already in use"
        
        if [ "$FORCE_REINSTALL" = false ]; then
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                error_exit "Deployment cancelled by user"
            fi
        fi
    else
        print_success "Port ${APP_PORT} is available"
    fi
}

# Check available disk space
check_disk_space() {
    print_info "Checking available disk space..."
    
    local available_space=$(df /opt 2>/dev/null | tail -1 | awk '{print $4}' || df / | tail -1 | awk '{print $4}')
    local min_space=1048576  # 1GB in KB
    
    if [ "$available_space" -lt "$min_space" ]; then
        print_warning "Low disk space detected. At least 1GB recommended."
    else
        print_success "Sufficient disk space available"
    fi
}

################################################################################
# BUILD FUNCTIONS
################################################################################

# Clean previous build artifacts
clean_build() {
    if [ "$SKIP_BUILD" = true ]; then
        return 0
    fi
    
    print_info "Cleaning previous build artifacts..."
    
    cd "${PROJECT_DIR}"
    
    if mvn clean &>> "${LOG_FILE}"; then
        print_success "Build artifacts cleaned"
    else
        print_warning "Clean failed, continuing anyway..."
    fi
}

# Build application with Maven
build_application() {
    if [ "$SKIP_BUILD" = true ]; then
        print_info "Skipping build step as requested"
        return 0
    fi
    
    print_header "Building Application"
    
    cd "${PROJECT_DIR}"
    
    print_info "Running Maven build (this may take several minutes)..."
    print_info "Build command: mvn clean package -DskipTests"
    
    # Run Maven build in background to show progress
    mvn clean package -DskipTests &>> "${LOG_FILE}" &
    local mvn_pid=$!
    
    show_spinner $mvn_pid "Building application"
    
    # Wait for Maven to complete and check exit status
    wait $mvn_pid
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        print_success "Application built successfully"
    else
        error_exit "Maven build failed. Check log: ${LOG_FILE}"
    fi
    
    # Verify JAR file exists
    local jar_file="${TARGET_DIR}/${APP_NAME}-${APP_VERSION}.jar"
    if [ ! -f "${jar_file}" ]; then
        # Try to find any JAR file in target directory
        jar_file=$(find "${TARGET_DIR}" -name "*.jar" -not -name "*-sources.jar" -not -name "*-javadoc.jar" | head -n 1)
        if [ -z "${jar_file}" ]; then
            error_exit "Built JAR file not found in ${TARGET_DIR}"
        fi
        print_warning "Using JAR file: ${jar_file}"
    fi
    
    print_success "JAR file located: ${jar_file}"
}

# Verify JAR file
verify_jar() {
    print_info "Verifying JAR file integrity..."
    
    local jar_file="${TARGET_DIR}/${APP_NAME}-${APP_VERSION}.jar"
    
    if [ ! -f "${jar_file}" ]; then
        jar_file=$(find "${TARGET_DIR}" -name "*.jar" -not -name "*-sources.jar" -not -name "*-javadoc.jar" | head -n 1)
    fi
    
    if [ ! -f "${jar_file}" ]; then
        error_exit "JAR file not found. Run without --skip-build option."
    fi
    
    # Check if JAR is valid
    if jar tf "${jar_file}" &>/dev/null; then
        print_success "JAR file is valid"
    else
        error_exit "JAR file is corrupted or invalid"
    fi
    
    # Get JAR file size
    local jar_size=$(du -h "${jar_file}" | cut -f1)
    print_info "JAR file size: ${jar_size}"
}

################################################################################
# DIRECTORY AND USER SETUP
################################################################################

# Create application directories
create_directories() {
    print_info "Creating application directory structure..."
    
    # Create base directories
    mkdir -p "${APP_DIR}"
    mkdir -p "${APP_LOGS_DIR}"
    mkdir -p "${APP_CONFIG_DIR}"
    mkdir -p "${APP_BACKUP_DIR}"
    mkdir -p "${APP_LIB_DIR}"
    
    print_success "Directory structure created at ${APP_DIR}"
}

# Create service user and group
create_service_user() {
    if [ "$DEV_MODE" = true ]; then
        print_info "Skipping service user creation (dev mode)"
        return 0
    fi
    
    print_info "Creating service user: ${SERVICE_USER}..."
    
    # Check if group exists
    if ! getent group "${SERVICE_GROUP}" &>/dev/null; then
        if groupadd -r "${SERVICE_GROUP}"; then
            print_success "Group '${SERVICE_GROUP}' created"
        else
            error_exit "Failed to create group '${SERVICE_GROUP}'"
        fi
    else
        print_warning "Group '${SERVICE_GROUP}' already exists"
    fi
    
    # Check if user exists
    if ! id "${SERVICE_USER}" &>/dev/null; then
        if useradd -r -g "${SERVICE_GROUP}" -d "${APP_DIR}" -s /sbin/nologin -c "Spring Boot Service User" "${SERVICE_USER}"; then
            print_success "User '${SERVICE_USER}' created"
        else
            error_exit "Failed to create user '${SERVICE_USER}'"
        fi
    else
        print_warning "User '${SERVICE_USER}' already exists"
    fi
}

# Set proper permissions
set_permissions() {
    print_info "Setting file permissions..."
    
    if [ "$DEV_MODE" = true ]; then
        # In dev mode, use current user
        chown -R "$(whoami):$(whoami)" "${APP_DIR}"
    else
        # In production mode, use service user
        chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${APP_DIR}"
    fi
    
    # Set appropriate permissions
    chmod 755 "${APP_DIR}"
    chmod 755 "${APP_LOGS_DIR}"
    chmod 755 "${APP_CONFIG_DIR}"
    chmod 644 "${APP_LIB_DIR}"/*.jar 2>/dev/null || true
    
    print_success "Permissions set successfully"
}

################################################################################
# DEPLOYMENT FUNCTIONS
################################################################################

# Backup existing deployment
backup_existing() {
    print_info "Backing up existing deployment..."
    
    local backup_timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${APP_BACKUP_DIR}/${APP_NAME}_backup_${backup_timestamp}.tar.gz"
    
    if [ -f "${APP_LIB_DIR}/${APP_NAME}.jar" ]; then
        tar -czf "${backup_file}" -C "${APP_LIB_DIR}" "${APP_NAME}.jar" 2>/dev/null || true
        
        if [ -f "${backup_file}" ]; then
            print_success "Backup created: ${backup_file}"
        fi
    else
        print_info "No existing deployment to backup"
    fi
}

# Deploy JAR file
deploy_jar() {
    print_info "Deploying application JAR..."
    
    local source_jar="${TARGET_DIR}/${APP_NAME}-${APP_VERSION}.jar"
    
    if [ ! -f "${source_jar}" ]; then
        source_jar=$(find "${TARGET_DIR}" -name "*.jar" -not -name "*-sources.jar" -not -name "*-javadoc.jar" | head -n 1)
    fi
    
    local dest_jar="${APP_LIB_DIR}/${APP_NAME}.jar"
    
    if cp "${source_jar}" "${dest_jar}"; then
        print_success "JAR deployed to ${dest_jar}"
    else
        error_exit "Failed to deploy JAR file"
    fi
}

# Deploy configuration files
deploy_config() {
    print_info "Deploying configuration files..."
    
    # Copy application.properties if it exists
    if [ -f "${APP_PROPERTIES}" ]; then
        if cp "${APP_PROPERTIES}" "${APP_CONFIG_DIR}/application.properties"; then
            print_success "application.properties deployed"
        else
            print_warning "Failed to copy application.properties"
        fi
    fi
    
    # Create application.yml if needed (template)
    if [ ! -f "${APP_CONFIG_DIR}/application.yml" ]; then
        cat > "${APP_CONFIG_DIR}/application.yml" << 'EOF'
# Spring Boot Application Configuration
# Override properties as needed

server:
  port: ${SERVER_PORT:9091}

spring:
  application:
    name: rahkaran-util
  
logging:
  file:
    name: logs/application.log
  level:
    root: INFO
    com.mapnaom: DEBUG
EOF
        print_success "Default application.yml created"
    fi
}

################################################################################
# SYSTEMD SERVICE FUNCTIONS
################################################################################

# Create systemd service file
create_service() {
    if [ "$DEV_MODE" = true ]; then
        print_info "Skipping service creation (dev mode)"
        return 0
    fi
    
    print_info "Creating systemd service..."
    
    cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=${APP_NAME} Spring Boot Application
Documentation=https://spring.io/projects/spring-boot
After=network.target postgresql.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}

# Working directory
WorkingDirectory=${APP_DIR}

# Java command
ExecStart=${JAVA_HOME}/bin/java ${JAVA_OPTS} \\
    -jar ${APP_LIB_DIR}/${APP_NAME}.jar \\
    --spring.config.location=file:${APP_CONFIG_DIR}/application.properties \\
    --logging.file.name=${APP_LOG_FILE}

# Service management
SuccessExitStatus=143
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}

# Process management
Restart=on-failure
RestartSec=10
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30

# Security settings
NoNewPrivileges=true
PrivateTmp=true

# Resource limits
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF
    
    print_success "Systemd service file created: ${SERVICE_FILE}"
}

# Enable and start service
start_service() {
    if [ "$DEV_MODE" = true ]; then
        print_info "Skipping service start (dev mode)"
        return 0
    fi
    
    print_info "Reloading systemd daemon..."
    systemctl daemon-reload
    
    print_info "Enabling ${SERVICE_NAME} service..."
    if systemctl enable "${SERVICE_NAME}"; then
        print_success "Service enabled for auto-start on boot"
    else
        error_exit "Failed to enable service"
    fi
    
    print_info "Starting ${SERVICE_NAME} service..."
    if systemctl start "${SERVICE_NAME}"; then
        print_success "Service started successfully"
    else
        error_exit "Failed to start service"
    fi
    
    # Wait for application to be ready
    print_info "Waiting for application to be ready..."
    local max_attempts=60
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            # Check if port is listening
            if ss -tuln | grep -q ":${APP_PORT} "; then
                print_success "Application is ready and accepting connections"
                return 0
            fi
        fi
        sleep 1
        ((attempt++))
    done
    
    print_error "Application failed to start within expected time"
    print_info "Checking service status..."
    systemctl status "${SERVICE_NAME}" --no-pager || true
}

# Run in development mode
run_dev_mode() {
    if [ "$DEV_MODE" = false ]; then
        return 0
    fi
    
    print_header "Running in Development Mode"
    
    local jar_file="${APP_LIB_DIR}/${APP_NAME}.jar"
    
    print_info "Starting application..."
    print_info "Press Ctrl+C to stop"
    echo
    
    # Run the application
    java ${JAVA_OPTS} \
        -jar "${jar_file}" \
        --spring.config.location=file:"${APP_CONFIG_DIR}/application.properties" \
        --logging.file.name="${APP_LOG_FILE}"
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
    
    # Check if service is active
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        print_success "Service is running"
    else
        error_exit "Service is not running"
    fi
    
    # Check if application is listening on configured port
    if ss -tuln | grep -q ":${APP_PORT} "; then
        print_success "Application is listening on port ${APP_PORT}"
    else
        print_warning "Application may not be listening on port ${APP_PORT}"
    fi
    
    # Check if JAR file exists
    if [ -f "${APP_LIB_DIR}/${APP_NAME}.jar" ]; then
        print_success "JAR file deployed correctly"
    else
        error_exit "JAR file not found at expected location"
    fi
    
    # Check log file
    if [ -f "${APP_LOG_FILE}" ]; then
        print_success "Application log file created"
        
        # Check for errors in recent logs
        if grep -i "error\|exception" "${APP_LOG_FILE}" | tail -n 5 | grep -q .; then
            print_warning "Errors detected in application logs. Review: ${APP_LOG_FILE}"
        fi
    fi
}

# Health check
health_check() {
    if [ "$DEV_MODE" = true ]; then
        return 0
    fi
    
    print_info "Performing health check..."
    
    # Try to connect to actuator health endpoint if available
    local health_url="http://localhost:${APP_PORT}/actuator/health"
    
    sleep 5  # Give the app time to start
    
    if curl -s -f "${health_url}" &>/dev/null; then
        print_success "Health check passed"
    else
        print_warning "Health endpoint not accessible (may not be configured)"
    fi
}

################################################################################
# CONFIGURATION FUNCTIONS
################################################################################

# Configure firewall
configure_firewall() {
    print_info "Checking firewall configuration..."
    
    if systemctl is-active --quiet firewalld; then
        print_info "Firewalld is active. Configuring application port..."
        
        if firewall-cmd --permanent --add-port="${APP_PORT}/tcp"; then
            firewall-cmd --reload
            print_success "Firewall configured to allow port ${APP_PORT}"
        else
            print_warning "Failed to configure firewall. You may need to manually allow port ${APP_PORT}"
        fi
    else
        print_info "Firewalld is not active, skipping firewall configuration"
    fi
}

# Create logrotate configuration
configure_logrotate() {
    if [ "$DEV_MODE" = true ]; then
        return 0
    fi
    
    print_info "Configuring log rotation..."
    
    cat > "/etc/logrotate.d/${APP_NAME}" << EOF
${APP_LOGS_DIR}/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0644 ${SERVICE_USER} ${SERVICE_GROUP}
    sharedscripts
    postrotate
        systemctl reload ${SERVICE_NAME} > /dev/null 2>&1 || true
    endscript
}
EOF
    
    print_success "Log rotation configured"
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
    echo -e "  Port:          ${MAGENTA}${APP_PORT}${NC}"
    echo -e "  Installation:  ${MAGENTA}${APP_DIR}${NC}"
    
    if [ "$DEV_MODE" = false ]; then
        echo -e "\n${CYAN}Service Management:${NC}"
        echo -e "  Status:   ${YELLOW}sudo systemctl status ${SERVICE_NAME}${NC}"
        echo -e "  Start:    ${YELLOW}sudo systemctl start ${SERVICE_NAME}${NC}"
        echo -e "  Stop:     ${YELLOW}sudo systemctl stop ${SERVICE_NAME}${NC}"
        echo -e "  Restart:  ${YELLOW}sudo systemctl restart ${SERVICE_NAME}${NC}"
        echo -e "  Logs:     ${YELLOW}sudo journalctl -u ${SERVICE_NAME} -f${NC}"
    fi
    
    echo -e "\n${CYAN}Application Access:${NC}"
    echo -e "  URL:            ${YELLOW}http://localhost:${APP_PORT}${NC}"
    echo -e "  Health Check:   ${YELLOW}http://localhost:${APP_PORT}/actuator/health${NC}"
    echo -e "  Swagger UI:     ${YELLOW}http://localhost:${APP_PORT}/swagger-ui.html${NC}"
    
    echo -e "\n${CYAN}Files and Directories:${NC}"
    echo -e "  JAR File:       ${YELLOW}${APP_LIB_DIR}/${APP_NAME}.jar${NC}"
    echo -e "  Configuration:  ${YELLOW}${APP_CONFIG_DIR}/application.properties${NC}"
    echo -e "  Application Log:${YELLOW}${APP_LOG_FILE}${NC}"
    echo -e "  Deployment Log: ${YELLOW}${LOG_FILE}${NC}"
    echo -e "  Backups:        ${YELLOW}${APP_BACKUP_DIR}${NC}"
    
    echo -e "\n${CYAN}Database Connection:${NC}"
    echo -e "  Host:     ${MAGENTA}${DB_HOST}${NC}"
    echo -e "  Port:     ${MAGENTA}${DB_PORT}${NC}"
    echo -e "  Database: ${MAGENTA}${DB_NAME}${NC}"
    echo -e "  User:     ${MAGENTA}${DB_USER}${NC}"
    
    echo -e "\n${YELLOW}Next Steps:${NC}"
    echo -e "  1. Test the application: ${YELLOW}curl http://localhost:${APP_PORT}/actuator/health${NC}"
    echo -e "  2. Monitor logs: ${YELLOW}tail -f ${APP_LOG_FILE}${NC}"
    echo -e "  3. Configure application.properties as needed"
    echo -e "  4. Set up SSL/TLS certificates for production"
    echo -e "  5. Configure backup strategy"
    
    if [ "$DEV_MODE" = false ]; then
        echo -e "\n${YELLOW}Security Reminders:${NC}"
        echo -e "  ⚠ Review and update default passwords"
        echo -e "  ⚠ Configure Spring Security properly"
        echo -e "  ⚠ Enable HTTPS for production"
        echo -e "  ⚠ Set up monitoring and alerting"
        echo -e "  ⚠ Regular security updates"
    fi
    
    echo -e "\n${GREEN}Documentation: https://spring.io/projects/spring-boot${NC}\n"
}

# Show service status
show_service_status() {
    if [ "$DEV_MODE" = true ]; then
        return 0
    fi
    
    print_header "Service Status"
    systemctl status "${SERVICE_NAME}" --no-pager || true
    
    echo -e "\n${CYAN}Recent Application Logs:${NC}"
    if [ -f "${APP_LOG_FILE}" ]; then
        tail -n 20 "${APP_LOG_FILE}"
    else
        journalctl -u "${SERVICE_NAME}" -n 20 --no-pager || echo "No logs available yet"
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
    
    local monitor_script="${APP_DIR}/monitor.sh"
    
    cat > "${monitor_script}" << 'MONITOR_EOF'
#!/bin/bash

# Application Monitoring Script
APP_NAME="APP_NAME_PLACEHOLDER"
SERVICE_NAME="${APP_NAME}"
APP_PORT="APP_PORT_PLACEHOLDER"
APP_LOG_FILE="APP_LOG_FILE_PLACEHOLDER"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "========================================="
echo "  ${APP_NAME} Status Monitor"
echo "========================================="
echo

# Check service status
echo -n "Service Status: "
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    echo -e "${GREEN}RUNNING${NC}"
else
    echo -e "${RED}STOPPED${NC}"
fi

# Check port
echo -n "Port ${APP_PORT}: "
if ss -tuln | grep -q ":${APP_PORT} "; then
    echo -e "${GREEN}LISTENING${NC}"
else
    echo -e "${RED}NOT LISTENING${NC}"
fi

# Memory usage
echo -n "Memory Usage: "
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    MEMORY=$(systemctl status "${SERVICE_NAME}" | grep Memory | awk '{print $2}')
    echo -e "${YELLOW}${MEMORY}${NC}"
else
    echo "N/A"
fi

# CPU usage
echo -n "CPU Usage: "
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    CPU=$(systemctl status "${SERVICE_NAME}" | grep CPU | awk '{print $2}')
    echo -e "${YELLOW}${CPU}${NC}"
else
    echo "N/A"
fi

# Uptime
echo -n "Uptime: "
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    UPTIME=$(systemctl status "${SERVICE_NAME}" | grep "Active:" | sed 's/.*since //')
    echo -e "${GREEN}${UPTIME}${NC}"
else
    echo "N/A"
fi

# Recent errors
echo
echo "Recent Errors (last 10):"
if [ -f "${APP_LOG_FILE}" ]; then
    grep -i "error\|exception" "${APP_LOG_FILE}" | tail -n 10 || echo "No recent errors"
else
    echo "Log file not found"
fi

echo
echo "========================================="
MONITOR_EOF
    
    # Replace placeholders
    sed -i "s/APP_NAME_PLACEHOLDER/${APP_NAME}/g" "${monitor_script}"
    sed -i "s/APP_PORT_PLACEHOLDER/${APP_PORT}/g" "${monitor_script}"
    sed -i "s|APP_LOG_FILE_PLACEHOLDER|${APP_LOG_FILE}|g" "${monitor_script}"
    
    chmod +x "${monitor_script}"
    
    print_success "Monitoring script created: ${monitor_script}"
}

# Create maintenance script
create_maintenance_script() {
    if [ "$DEV_MODE" = true ]; then
        return 0
    fi
    
    print_info "Creating maintenance script..."
    
    local maint_script="${APP_DIR}/maintenance.sh"
    
    cat > "${maint_script}" << 'MAINT_EOF'
#!/bin/bash

# Application Maintenance Script
APP_NAME="APP_NAME_PLACEHOLDER"
SERVICE_NAME="${APP_NAME}"
APP_DIR="APP_DIR_PLACEHOLDER"
APP_LOGS_DIR="${APP_DIR}/logs"
APP_BACKUP_DIR="${APP_DIR}/backups"

show_help() {
    cat << EOF
Usage: sudo bash maintenance.sh [COMMAND]

Commands:
  backup       Create a backup of the application
  clean-logs   Clean old log files (older than 30 days)
  clean-backups Clean old backups (older than 90 days)
  update       Update application (requires new JAR file path)
  rollback     Rollback to previous version
  health       Perform health check
  restart      Restart the application
  help         Show this help message

Examples:
  sudo bash maintenance.sh backup
  sudo bash maintenance.sh update /path/to/new.jar
  sudo bash maintenance.sh rollback
EOF
}

backup_application() {
    echo "Creating backup..."
    local backup_file="${APP_BACKUP_DIR}/${APP_NAME}_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czf "${backup_file}" -C "${APP_DIR}" lib config
    echo "Backup created: ${backup_file}"
}

clean_logs() {
    echo "Cleaning old logs..."
    find "${APP_LOGS_DIR}" -name "*.log.*" -mtime +30 -delete
    echo "Old logs cleaned"
}

clean_backups() {
    echo "Cleaning old backups..."
    find "${APP_BACKUP_DIR}" -name "*.tar.gz" -mtime +90 -delete
    echo "Old backups cleaned"
}

restart_application() {
    echo "Restarting ${SERVICE_NAME}..."
    systemctl restart "${SERVICE_NAME}"
    echo "Service restarted"
}

health_check() {
    echo "Performing health check..."
    systemctl status "${SERVICE_NAME}" --no-pager
}

case "${1:-help}" in
    backup)
        backup_application
        ;;
    clean-logs)
        clean_logs
        ;;
    clean-backups)
        clean_backups
        ;;
    restart)
        restart_application
        ;;
    health)
        health_check
        ;;
    help|*)
        show_help
        ;;
esac
MAINT_EOF
    
    # Replace placeholders
    sed -i "s/APP_NAME_PLACEHOLDER/${APP_NAME}/g" "${maint_script}"
    sed -i "s|APP_DIR_PLACEHOLDER|${APP_DIR}|g" "${maint_script}"
    
    chmod +x "${maint_script}"
    
    print_success "Maintenance script created: ${maint_script}"
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
    
    print_header "Spring Boot Application Deployment"
    
    log "INFO" "Starting deployment process"
    log "INFO" "Application: ${APP_NAME} v${APP_VERSION}"
    log "INFO" "Port: ${APP_PORT}"
    log "INFO" "Script version: 2.0"
    
    # Pre-deployment checks
    print_header "Pre-Deployment Checks"
    check_root
    check_system
    check_java
    check_maven
    check_project_structure
    check_disk_space
    check_port
    check_database
    
    # Build phase
    if [ "$SKIP_BUILD" = false ]; then
        print_header "Building Application"
        clean_build
        build_application
        verify_jar
    else
        print_header "Verifying Existing Build"
        verify_jar
    fi
    
    # Setup phase
    print_header "Setting Up Application Environment"
    create_directories
    create_service_user
    
    # Deployment phase
    print_header "Deploying Application"
    backup_existing
    deploy_jar
    deploy_config
    set_permissions
    
    # Service configuration
    if [ "$DEV_MODE" = false ]; then
        print_header "Configuring System Service"
        create_service
        configure_firewall
        configure_logrotate
        start_service
    fi
    
    # Create utility scripts
    print_header "Creating Utility Scripts"
    create_monitoring_script
    create_maintenance_script
    
    # Verification phase
    if [ "$DEV_MODE" = false ]; then
        print_header "Verifying Deployment"
        verify_deployment
        health_check
    fi
    
    # Display results
    display_deployment_info
    
    if [ "$DEV_MODE" = false ]; then
        show_service_status
    fi
    
    log "INFO" "Deployment completed successfully"
    
    # Run in dev mode if requested
    if [ "$DEV_MODE" = true ]; then
        run_dev_mode
    fi
}

# Execute main function
main "$@"