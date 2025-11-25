#!/bin/bash

################################################################################
#                 AlmaLinux 8/9/10 Package Removal Script                      #
################################################################################
# Description: Removes specified software packages (JDK, PostgreSQL, Node.js,  #
#              Git) from AlmaLinux 8, 9, and 10 systems with flexible CLI opts #
# Author: System Administrator                                                 #
# Version: 2.0                                                                 #
# Date: 2025-11-25                                                             #
################################################################################

# Color codes for enhanced output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

################################################################################
# Function: display_banner
# Description: Shows a visually appealing banner with usage instructions
################################################################################
display_banner() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}      ${MAGENTA}AlmaLinux 8/9/10 Package Removal Utility${NC}                  ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Usage:${NC} $0 [OPTIONS]"
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo -e "  ${GREEN}-j, --jdk${NC}         Remove JDK (Java Development Kit)"
    echo -e "  ${GREEN}-p, --postgresql${NC}  Remove PostgreSQL database"
    echo -e "  ${GREEN}-n, --nodejs${NC}      Remove Node.js and npm"
    echo -e "  ${GREEN}-g, --git${NC}         Remove Git version control"
    echo -e "  ${GREEN}-a, --all${NC}         Remove all packages (JDK, PostgreSQL, Node.js, Git)"
    echo -e "  ${GREEN}-h, --help${NC}        Display this help message"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo -e "  $0 -j -p           ${BLUE}# Remove JDK and PostgreSQL${NC}"
    echo -e "  $0 --nodejs --git  ${BLUE}# Remove Node.js and Git${NC}"
    echo -e "  $0 -a              ${BLUE}# Remove all packages${NC}"
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

################################################################################
# Function: check_root
# Description: Verifies script is running with root privileges
################################################################################
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR]${NC} This script must be run as root or with sudo privileges"
        exit 1
    fi
}

################################################################################
# Function: detect_alma_version
# Description: Detects AlmaLinux version and sets appropriate package manager
################################################################################
detect_alma_version() {
    if [ -f /etc/almalinux-release ]; then
        ALMA_VERSION=$(grep -oP '(?<=release )\d+' /etc/almalinux-release)
        echo -e "${GREEN}[INFO]${NC} Detected AlmaLinux version: ${CYAN}${ALMA_VERSION}${NC}"
        
        # AlmaLinux 9+ uses dnf as the primary package manager
        if [ "$ALMA_VERSION" -ge 9 ]; then
            PKG_MGR="dnf"
        else
            PKG_MGR="yum"
        fi
        echo -e "${GREEN}[INFO]${NC} Using package manager: ${CYAN}${PKG_MGR}${NC}"
        echo ""
    else
        echo -e "${YELLOW}[WARNING]${NC} Could not detect AlmaLinux version. Defaulting to yum."
        PKG_MGR="yum"
        echo ""
    fi
}

################################################################################
# Function: remove_jdk
# Description: Removes all installed JDK packages from the system
################################################################################
remove_jdk() {
    echo -e "${YELLOW}[INFO]${NC} Checking for JDK installations..."
    
    # Check if any JDK package is installed
    if rpm -qa | grep -qE 'java.*openjdk|java.*jdk'; then
        echo -e "${GREEN}[FOUND]${NC} JDK packages detected. Removing..."
        
        # Remove OpenJDK and related packages
        $PKG_MGR remove -y java-*-openjdk* 2>/dev/null
        
        # Remove any remaining Java alternatives
        alternatives --remove-all java 2>/dev/null
        alternatives --remove-all javac 2>/dev/null
        
        echo -e "${GREEN}[SUCCESS]${NC} JDK packages removed successfully"
    else
        echo -e "${BLUE}[SKIP]${NC} No JDK packages found on the system"
    fi
    echo ""
}

################################################################################
# Function: remove_postgresql
# Description: Removes PostgreSQL database and all related components
################################################################################
remove_postgresql() {
    echo -e "${YELLOW}[INFO]${NC} Checking for PostgreSQL installations..."
    
    # Check if PostgreSQL is installed
    if rpm -qa | grep -q postgresql; then
        echo -e "${GREEN}[FOUND]${NC} PostgreSQL detected. Removing..."
        
        # Stop PostgreSQL service if running
        systemctl stop postgresql* 2>/dev/null
        
        # Remove PostgreSQL packages
        $PKG_MGR remove -y postgresql* 2>/dev/null
        
        # Remove PostgreSQL data directory (optional - uncomment if needed)
        # rm -rf /var/lib/pgsql
        
        echo -e "${GREEN}[SUCCESS]${NC} PostgreSQL removed successfully"
    else
        echo -e "${BLUE}[SKIP]${NC} No PostgreSQL packages found on the system"
    fi
    echo ""
}

################################################################################
# Function: remove_nodejs
# Description: Removes Node.js runtime and npm package manager
################################################################################
remove_nodejs() {
    echo -e "${YELLOW}[INFO]${NC} Checking for Node.js installations..."
    
    # Check if Node.js is installed
    if rpm -qa | grep -qE 'nodejs|npm'; then
        echo -e "${GREEN}[FOUND]${NC} Node.js detected. Removing..."
        
        # Remove Node.js and npm packages
        $PKG_MGR remove -y nodejs npm 2>/dev/null
        
        # Clean up global npm packages directory (optional)
        # rm -rf /usr/lib/node_modules
        
        echo -e "${GREEN}[SUCCESS]${NC} Node.js and npm removed successfully"
    else
        echo -e "${BLUE}[SKIP]${NC} No Node.js packages found on the system"
    fi
    echo ""
}

################################################################################
# Function: remove_git
# Description: Removes Git version control system
################################################################################
remove_git() {
    echo -e "${YELLOW}[INFO]${NC} Checking for Git installations..."
    
    # Check if Git is installed
    if rpm -qa | grep -q '^git-'; then
        echo -e "${GREEN}[FOUND]${NC} Git detected. Removing..."
        
        # Remove Git packages
        $PKG_MGR remove -y git* 2>/dev/null
        
        echo -e "${GREEN}[SUCCESS]${NC} Git removed successfully"
    else
        echo -e "${BLUE}[SKIP]${NC} No Git packages found on the system"
    fi
    echo ""
}

################################################################################
# Function: cleanup_cache
# Description: Cleans up package manager cache after package removal
################################################################################
cleanup_cache() {
    echo -e "${YELLOW}[INFO]${NC} Cleaning up package cache..."
    $PKG_MGR clean all >/dev/null 2>&1
    echo -e "${GREEN}[SUCCESS]${NC} Cache cleaned successfully"
    echo ""
}

################################################################################
# Main Script Execution
################################################################################

# Initialize flags for package removal
REMOVE_JDK=false
REMOVE_POSTGRESQL=false
REMOVE_NODEJS=false
REMOVE_GIT=false
REMOVE_ALL=false

# Display banner
display_banner

# Check if no arguments provided
if [ $# -eq 0 ]; then
    echo -e "${RED}[ERROR]${NC} No options specified. Use -h or --help for usage information."
    exit 1
fi

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -j|--jdk)
            REMOVE_JDK=true
            shift
            ;;
        -p|--postgresql)
            REMOVE_POSTGRESQL=true
            shift
            ;;
        -n|--nodejs)
            REMOVE_NODEJS=true
            shift
            ;;
        -g|--git)
            REMOVE_GIT=true
            shift
            ;;
        -a|--all)
            REMOVE_ALL=true
            shift
            ;;
        -h|--help)
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Unknown option: $1"
            echo -e "Use -h or --help for usage information."
            exit 1
            ;;
    esac
done

# Verify root privileges
check_root

# Detect AlmaLinux version and set package manager
detect_alma_version

# Display operation summary
echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}Starting Package Removal Process${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
echo ""

# Execute removal based on flags
if [ "$REMOVE_ALL" = true ]; then
    remove_jdk
    remove_postgresql
    remove_nodejs
    remove_git
else
    [ "$REMOVE_JDK" = true ] && remove_jdk
    [ "$REMOVE_POSTGRESQL" = true ] && remove_postgresql
    [ "$REMOVE_NODEJS" = true ] && remove_nodejs
    [ "$REMOVE_GIT" = true ] && remove_git
fi

# Clean up cache
cleanup_cache

# Display completion message
echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Package removal process completed successfully!${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
echo ""

exit 0