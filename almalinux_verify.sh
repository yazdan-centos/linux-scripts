#!/bin/bash

# AlmaLinux Package Verification Script
# Compatible with AlmaLinux 8, 9, and 10
# Verifies installation of JDK, Node.js, Git, PostgreSQL, and Nginx

# Disable exit on error to ensure all checks complete
set +e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Arrays to store package information
declare -a PACKAGE_NAMES
declare -a PACKAGE_STATUS
declare -a PACKAGE_VERSIONS
declare -a PACKAGE_DETAILS

# Counters
INSTALLED=0
NOT_INSTALLED=0

# Detect AlmaLinux version for default package versions
ALMA_MAJOR_VERSION=""

# Function to detect AlmaLinux version
detect_almalinux_version() {
    if [ -f /etc/almalinux-release ]; then
        ALMA_MAJOR_VERSION=$(cat /etc/almalinux-release | grep -oP 'release \K[0-9]+' | head -n 1)
    elif [ -f /etc/redhat-release ]; then
        ALMA_MAJOR_VERSION=$(cat /etc/redhat-release | grep -oP 'release \K[0-9]+' | head -n 1)
    else
        ALMA_MAJOR_VERSION="Unknown"
    fi
}

# Function to get default package versions based on AlmaLinux version
get_default_version() {
    local package=$1
    
    case $ALMA_MAJOR_VERSION in
        8)
            case $package in
                "JDK") echo "OpenJDK 1.8.0 / 11" ;;
                "Node.js") echo "10.24 / 18.x (AppStream)" ;;
                "Git") echo "2.43.x" ;;
                "PostgreSQL") echo "10.23 / 13.x (AppStream)" ;;
                "Nginx") echo "1.14.1 / 1.20.x (AppStream)" ;;
                *) echo "N/A" ;;
            esac
            ;;
        9)
            case $package in
                "JDK") echo "OpenJDK 1.8.0 / 11 / 17" ;;
                "Node.js") echo "16.x / 18.x (AppStream)" ;;
                "Git") echo "2.43.x" ;;
                "PostgreSQL") echo "13.x / 15.x (AppStream)" ;;
                "Nginx") echo "1.20.x / 1.22.x (AppStream)" ;;
                *) echo "N/A" ;;
            esac
            ;;
        10)
            case $package in
                "JDK") echo "OpenJDK 11 / 17 / 21" ;;
                "Node.js") echo "18.x / 20.x (AppStream)" ;;
                "Git") echo "2.45.x" ;;
                "PostgreSQL") echo "15.x / 16.x (AppStream)" ;;
                "Nginx") echo "1.24.x (AppStream)" ;;
                *) echo "N/A" ;;
            esac
            ;;
        *)
            echo "N/A"
            ;;
    esac
}

# Function to print system information
print_system_info() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         AlmaLinux Server Package Verification Script                      ║${NC}"
    echo -e "${BLUE}║         Compatible with AlmaLinux 8, 9, and 10                            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}SYSTEM INFORMATION${NC}"
    echo -e "${CYAN}$(printf '=%.0s' {1..80})${NC}"
    
    if [ -f /etc/almalinux-release ]; then
        ALMA_VERSION=$(cat /etc/almalinux-release)
        echo -e "OS: ${GREEN}$ALMA_VERSION${NC}"
    elif [ -f /etc/redhat-release ]; then
        ALMA_VERSION=$(cat /etc/redhat-release)
        echo -e "OS: ${YELLOW}$ALMA_VERSION${NC}"
    else
        echo -e "${RED}Warning: Could not detect AlmaLinux version${NC}"
    fi
    
    echo "Hostname: $(hostname)"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo ""
}

# Function to check JDK
check_jdk() {
    local status="not installed"
    local version=""
    local details=""
    
    if command -v java &> /dev/null 2>&1; then
        version=$(java -version 2>&1 | head -n 1 | awk -F '"' '{print $2}' 2>/dev/null || echo "Unknown")
        status="$version"
        ((INSTALLED++))
        
        # Get JDK type
        if command -v javac &> /dev/null 2>&1; then
            JDK_TYPE=$(java -version 2>&1 | grep -i "openjdk\|oracle\|amazon" | head -n 1 2>/dev/null || echo "")
            if [ -n "$JDK_TYPE" ]; then
                details="Type: $JDK_TYPE"
            fi
        fi
        
        # Check JAVA_HOME
        if [ -n "${JAVA_HOME:-}" ] 2>/dev/null; then
            details="$details | JAVA_HOME: $JAVA_HOME"
        fi
    else
        ((NOT_INSTALLED++))
    fi
    
    PACKAGE_NAMES+=("JDK (Java Development Kit)")
    PACKAGE_STATUS+=("$status")
    PACKAGE_DETAILS+=("$details")
}

# Function to check Node.js
check_nodejs() {
    local status="not installed"
    local version=""
    local details=""
    
    if command -v node &> /dev/null 2>&1; then
        version=$(node --version 2>/dev/null || echo "Unknown")
        status="$version"
        ((INSTALLED++))
        
        # Check npm
        if command -v npm &> /dev/null 2>&1; then
            NPM_VERSION=$(npm --version 2>/dev/null || echo "Unknown")
            details="npm: $NPM_VERSION"
        fi
        
        # Check installation path
        NODE_PATH=$(which node 2>/dev/null || echo "Unknown")
        details="$details | Path: $NODE_PATH"
    else
        ((NOT_INSTALLED++))
    fi
    
    PACKAGE_NAMES+=("Node.js")
    PACKAGE_STATUS+=("$status")
    PACKAGE_DETAILS+=("$details")
}

# Function to check Git
check_git() {
    local status="not installed"
    local version=""
    local details=""
    
    if command -v git &> /dev/null 2>&1; then
        version=$(git --version 2>/dev/null | awk '{print $3}' || echo "Unknown")
        status="$version"
        ((INSTALLED++))
        
        # Check git configuration
        GIT_USER=$(git config --global user.name 2>/dev/null || echo "")
        if [ -n "$GIT_USER" ]; then
            details="User: $GIT_USER"
        fi
        
        GIT_EMAIL=$(git config --global user.email 2>/dev/null || echo "")
        if [ -n "$GIT_EMAIL" ]; then
            details="$details | Email: $GIT_EMAIL"
        fi
    else
        ((NOT_INSTALLED++))
    fi
    
    PACKAGE_NAMES+=("Git")
    PACKAGE_STATUS+=("$status")
    PACKAGE_DETAILS+=("$details")
}

# Function to check PostgreSQL
check_postgresql() {
    local status="not installed"
    local version=""
    local details=""
    
    if command -v psql &> /dev/null 2>&1; then
        version=$(psql --version 2>/dev/null | awk '{print $3}' || echo "Unknown")
        status="$version"
        ((INSTALLED++))
        
        # Check if PostgreSQL server is installed
        if rpm -qa 2>/dev/null | grep -q "postgresql.*-server"; then
            details="Server: Installed"
            
            # Check service status
            if systemctl is-active --quiet postgresql 2>/dev/null || \
               systemctl is-active --quiet postgresql-*.service 2>/dev/null; then
                details="$details | Status: Running"
            else
                details="$details | Status: Stopped"
            fi
        else
            details="Client only"
        fi
        
        # Check data directory
        if [ -d "/var/lib/pgsql" ]; then
            details="$details | Data: /var/lib/pgsql"
        fi
    else
        ((NOT_INSTALLED++))
    fi
    
    PACKAGE_NAMES+=("PostgreSQL")
    PACKAGE_STATUS+=("$status")
    PACKAGE_DETAILS+=("$details")
}

# Function to check Nginx
check_nginx() {
    local status="not installed"
    local version=""
    local details=""
    
    if command -v nginx &> /dev/null 2>&1; then
        version=$(nginx -v 2>&1 | awk -F'/' '{print $2}' || echo "Unknown")
        status="$version"
        ((INSTALLED++))
        
        # Check service status
        if systemctl is-active --quiet nginx 2>/dev/null; then
            details="Status: Running"
            
            # Check listening ports
            if command -v ss &> /dev/null 2>&1; then
                PORTS=$(ss -tlnp 2>/dev/null | grep nginx | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | tr '\n' ',' | sed 's/,$//' || echo "")
                if [ -n "$PORTS" ]; then
                    details="$details | Ports: $PORTS"
                fi
            fi
        else
            details="Status: Stopped"
        fi
        
        # Check config file
        if [ -f "/etc/nginx/nginx.conf" ]; then
            details="$details | Config: /etc/nginx/nginx.conf"
        fi
    else
        ((NOT_INSTALLED++))
    fi
    
    PACKAGE_NAMES+=("Nginx")
    PACKAGE_STATUS+=("$status")
    PACKAGE_DETAILS+=("$details")
}

# Function to print table
print_table() {
    echo -e "${CYAN}PACKAGE VERIFICATION STATUS${NC}"
    echo -e "${CYAN}$(printf '=%.0s' {1..80})${NC}"
    echo ""
    
    # Print table header
    printf "${BLUE}%-35s %-25s %-20s${NC}\n" "PACKAGE NAME" "INSTALLED VERSION" "DEFAULT VERSION"
    printf "${BLUE}%-35s %-25s %-20s${NC}\n" "$(printf '─%.0s' {1..35})" "$(printf '─%.0s' {1..25})" "$(printf '─%.0s' {1..20})"
    
    # Print table rows
    for i in "${!PACKAGE_NAMES[@]}"; do
        local pkg_name="${PACKAGE_NAMES[$i]}"
        local pkg_status="${PACKAGE_STATUS[$i]}"
        local default_ver=$(get_default_version "$(echo $pkg_name | awk '{print $1}')")
        
        if [ "$pkg_status" = "not installed" ]; then
            printf "${RED}%-35s %-25s${NC} ${YELLOW}%-20s${NC}\n" "$pkg_name" "$pkg_status" "$default_ver"
        else
            printf "${GREEN}%-35s %-25s${NC} ${YELLOW}%-20s${NC}\n" "$pkg_name" "$pkg_status" "$default_ver"
        fi
    done
    
    echo ""
}

# Function to print package details
print_package_details() {
    echo -e "${CYAN}PACKAGE DETAILS${NC}"
    echo -e "${CYAN}$(printf '=%.0s' {1..80})${NC}"
    echo ""
    
    for i in "${!PACKAGE_NAMES[@]}"; do
        local pkg_name="${PACKAGE_NAMES[$i]}"
        local pkg_status="${PACKAGE_STATUS[$i]}"
        local pkg_details="${PACKAGE_DETAILS[$i]}"
        
        if [ "$pkg_status" != "not installed" ] && [ -n "$pkg_details" ]; then
            echo -e "${GREEN}●${NC} ${BLUE}$pkg_name${NC}"
            echo "  $pkg_details"
            echo ""
        fi
    done
}

# Function to print summary
print_summary() {
    echo -e "${CYAN}VERIFICATION SUMMARY${NC}"
    echo -e "${CYAN}$(printf '=%.0s' {1..80})${NC}"
    echo ""
    
    local total=$((INSTALLED + NOT_INSTALLED))
    local percentage=0
    if [ $total -gt 0 ]; then
        percentage=$((INSTALLED * 100 / total))
    fi
    
    echo -e "Total Packages: $total"
    echo -e "${GREEN}Installed: $INSTALLED${NC}"
    echo -e "${RED}Not Installed: $NOT_INSTALLED${NC}"
    echo -e "Installation Rate: ${percentage}%"
    echo ""
    
    if [ $NOT_INSTALLED -eq 0 ]; then
        echo -e "${GREEN}✓ All required packages are installed!${NC}"
        echo -e "${GREEN}✓ Server is ready for deployment.${NC}"
    else
        echo -e "${YELLOW}⚠ Some packages are missing.${NC}"
        echo -e "${YELLOW}⚠ Please install missing packages before deployment.${NC}"
    fi
    echo ""
}

# Function to print installation hints
print_installation_hints() {
    if [ $NOT_INSTALLED -gt 0 ]; then
        echo -e "${CYAN}INSTALLATION COMMANDS${NC}"
        echo -e "${CYAN}$(printf '=%.0s' {1..80})${NC}"
        echo ""
        
        local hints_printed=false
        
        for i in "${!PACKAGE_NAMES[@]}"; do
            local pkg_name="${PACKAGE_NAMES[$i]}"
            local pkg_status="${PACKAGE_STATUS[$i]}"
            
            if [ "$pkg_status" = "not installed" ]; then
                hints_printed=true
                
                case "$pkg_name" in
                    "JDK"*)
                        echo -e "${YELLOW}► JDK (Java Development Kit)${NC}"
                        echo "  # Install OpenJDK 11:"
                        echo "  sudo dnf install -y java-11-openjdk java-11-openjdk-devel"
                        echo ""
                        echo "  # Or install OpenJDK 17:"
                        echo "  sudo dnf install -y java-17-openjdk java-17-openjdk-devel"
                        echo ""
                        ;;
                    "Node.js"*)
                        echo -e "${YELLOW}► Node.js${NC}"
                        echo "  # Install Node.js from AppStream (recommended):"
                        echo "  sudo dnf module list nodejs"
                        echo "  sudo dnf module enable nodejs:20"
                        echo "  sudo dnf install -y nodejs"
                        echo ""
                        echo "  # Or install from NodeSource repository:"
                        echo "  curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -"
                        echo "  sudo dnf install -y nodejs"
                        echo ""
                        ;;
                    "Git"*)
                        echo -e "${YELLOW}► Git${NC}"
                        echo "  # Install Git:"
                        echo "  sudo dnf install -y git"
                        echo ""
                        echo "  # Configure Git (optional):"
                        echo "  git config --global user.name \"Your Name\""
                        echo "  git config --global user.email \"your.email@example.com\""
                        echo ""
                        ;;
                    "PostgreSQL"*)
                        echo -e "${YELLOW}► PostgreSQL${NC}"
                        echo "  # Install PostgreSQL 15 from AppStream:"
                        echo "  sudo dnf module list postgresql"
                        echo "  sudo dnf module enable postgresql:15"
                        echo "  sudo dnf install -y postgresql postgresql-server"
                        echo ""
                        echo "  # Initialize and start PostgreSQL:"
                        echo "  sudo postgresql-setup --initdb"
                        echo "  sudo systemctl enable postgresql"
                        echo "  sudo systemctl start postgresql"
                        echo ""
                        ;;
                    "Nginx"*)
                        echo -e "${YELLOW}► Nginx${NC}"
                        echo "  # Install Nginx:"
                        echo "  sudo dnf install -y nginx"
                        echo ""
                        echo "  # Enable and start Nginx:"
                        echo "  sudo systemctl enable nginx"
                        echo "  sudo systemctl start nginx"
                        echo ""
                        echo "  # Configure firewall (if needed):"
                        echo "  sudo firewall-cmd --permanent --add-service=http"
                        echo "  sudo firewall-cmd --permanent --add-service=https"
                        echo "  sudo firewall-cmd --reload"
                        echo ""
                        ;;
                esac
            fi
        done
        
        if [ "$hints_printed" = false ]; then
            echo "No installation hints needed - all packages are installed."
            echo ""
        fi
    fi
}

# Main execution
main() {
    clear
    
    # Detect AlmaLinux version first
    detect_almalinux_version
    
    # Print system information
    print_system_info
    
    # Check all packages
    check_jdk
    check_nodejs
    check_git
    check_postgresql
    check_nginx
    
    # Print results
    print_table
    print_package_details
    print_summary
    print_installation_hints
    
    echo -e "${BLUE}$(printf '=%.0s' {1..80})${NC}"
    echo -e "${BLUE}Verification completed at: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${BLUE}$(printf '=%.0s' {1..80})${NC}"
    echo ""
    
    # Exit with appropriate code
    if [ $NOT_INSTALLED -eq 0 ]; then
        exit 0
    else
        exit 1
    fi
}

# Run main function
main