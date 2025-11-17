#!/bin/bash

################################################################################
# Script: install_openjdk_23.sh
# Description: Automated installation script for Oracle OpenJDK 23 on AlmaLinux 9
# Author: System Administrator
# Date: 2025
# License: Oracle No-Fee Terms and Conditions License
################################################################################

# Exit immediately if a command exits with a non-zero status
set -e

# Enable command tracing for debugging (uncomment if needed)
# set -x

################################################################################
# Color codes for output
################################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

################################################################################
# Configuration Variables
################################################################################
JDK_VERSION="23.0.1"
JDK_MAJOR_VERSION="23"
DOWNLOAD_DIR="/tmp/jdk_download"
# Note: Oracle requires accepting license terms before download
# Download URL pattern (x64 RPM for Linux)
JDK_DOWNLOAD_URL="https://download.oracle.com/java/${JDK_MAJOR_VERSION}/latest/jdk-${JDK_MAJOR_VERSION}_linux-x64_bin.rpm"
JDK_INSTALL_DIR="/usr/lib/jvm/jdk-${JDK_MAJOR_VERSION}-oracle-x64"

################################################################################
# Function: Print colored messages
################################################################################
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

################################################################################
# Function: Check if script is run as root
################################################################################
check_root() {
    print_info "Checking for root privileges..."
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root or with sudo privileges"
        exit 1
    fi
    print_success "Running with root privileges"
}

################################################################################
# Function: Check system requirements
################################################################################
check_system() {
    print_info "Checking system compatibility..."
    
    # Check if running on AlmaLinux 9
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$ID" != "almalinux" ]]; then
            print_warning "This script is designed for AlmaLinux, but detected: $ID"
            read -p "Do you want to continue anyway? (yes/no): " response
            if [[ "$response" != "yes" ]]; then
                print_info "Installation cancelled by user"
                exit 0
            fi
        fi
        
        # Check version
        VERSION_MAJOR=$(echo $VERSION_ID | cut -d. -f1)
        if [[ "$VERSION_MAJOR" != "9" ]]; then
            print_warning "This script is optimized for AlmaLinux 9, detected version: $VERSION_ID"
        fi
    fi
    
    print_success "System check completed"
}

################################################################################
# Function: Install required dependencies
################################################################################
install_dependencies() {
    print_info "Installing required dependencies..."
    
    # Update system packages
    dnf update -y || {
        print_error "Failed to update system packages"
        exit 1
    }
    
    # Install wget if not present
    if ! command -v wget &> /dev/null; then
        print_info "Installing wget..."
        dnf install -y wget || {
            print_error "Failed to install wget"
            exit 1
        }
    fi
    
    print_success "Dependencies installed successfully"
}

################################################################################
# Function: Create download directory
################################################################################
create_download_dir() {
    print_info "Creating download directory: $DOWNLOAD_DIR"
    
    mkdir -p "$DOWNLOAD_DIR" || {
        print_error "Failed to create download directory"
        exit 1
    }
    
    cd "$DOWNLOAD_DIR" || {
        print_error "Failed to change to download directory"
        exit 1
    }
    
    print_success "Download directory created"
}

################################################################################
# Function: Download Oracle OpenJDK 23 RPM
################################################################################
download_jdk() {
    print_info "Attempting to download Oracle OpenJDK ${JDK_MAJOR_VERSION} RPM..."
    print_warning "Note: Oracle typically requires manual license acceptance"

    # Try multiple download URLs
    URLS=(
        "https://download.oracle.com/java/23/latest/jdk-23_linux-x64_bin.rpm"
        "https://download.oracle.com/java/23/archive/jdk-23.0.1_linux-x64_bin.rpm"
    )

    DOWNLOAD_SUCCESS=false

    for url in "${URLS[@]}"; do
        print_info "Trying URL: $url"

        if wget --spider "$url" 2>/dev/null; then
            wget --no-check-certificate --no-cookies \
                 --header "Cookie: oraclelicense=accept-securebackup-cookie" \
                 -O "jdk-${JDK_MAJOR_VERSION}_linux-x64_bin.rpm" \
                 "$url" 2>&1 || continue

            # Check if download was successful (file size > 100MB)
            if [[ -f "jdk-${JDK_MAJOR_VERSION}_linux-x64_bin.rpm" ]]; then
                FILE_SIZE=$(stat -c%s "jdk-${JDK_MAJOR_VERSION}_linux-x64_bin.rpm" 2>/dev/null || echo "0")
                if [[ $FILE_SIZE -gt 100000000 ]]; then
                    DOWNLOAD_SUCCESS=true
                    print_success "Download successful! File size: $(( FILE_SIZE / 1024 / 1024 )) MB"
                    break
                else
                    print_warning "Downloaded file seems too small ($FILE_SIZE bytes). May be incomplete."
                    rm -f "jdk-${JDK_MAJOR_VERSION}_linux-x64_bin.rpm"
                fi
            fi
        fi
    done

    if [[ "$DOWNLOAD_SUCCESS" == false ]]; then
        print_error "Automated download failed."
        echo ""
        print_info "Please download manually:"
        print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_info "1. Visit: https://www.oracle.com/java/technologies/javase/jdk23-archive-downloads.html"
        print_info "2. Accept the 'Oracle No-Fee Terms and Conditions' license"
        print_info "3. Download: 'Linux x64 RPM Package' (jdk-23.0.1_linux-x64_bin.rpm)"
        print_info "4. Move the file to: $DOWNLOAD_DIR"
        print_info "5. Run this script with: sudo $0 --skip-download"
        print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        # Try to find if file exists elsewhere
        print_info "Searching for RPM file in common locations..."
        FOUND_FILE=$(find /tmp /home -name "jdk-23*linux-x64*.rpm" 2>/dev/null | head -1)
        if [[ -n "$FOUND_FILE" ]]; then
            print_info "Found JDK RPM at: $FOUND_FILE"
            read -p "Would you like to use this file? (yes/no): " response
            if [[ "$response" == "yes" ]]; then
                cp "$FOUND_FILE" "$DOWNLOAD_DIR/jdk-${JDK_MAJOR_VERSION}_linux-x64_bin.rpm"
                print_success "File copied successfully"
                return 0
            fi
        fi

        exit 1
    fi
}

################################################################################
# Function: Remove old JDK versions (optional)
################################################################################
remove_old_jdk() {
    print_info "Checking for existing JDK installations..."
    
    # Check for installed JDK packages
    INSTALLED_JDKS=$(rpm -qa | grep -E "jdk-[0-9]+" | sort)
    
    if [[ -n "$INSTALLED_JDKS" ]]; then
        print_warning "Found existing JDK installations:"
        echo "$INSTALLED_JDKS"
        read -p "Do you want to remove them? (yes/no): " response
        if [[ "$response" == "yes" ]]; then
            echo "$INSTALLED_JDKS" | xargs rpm -e --nodeps 2>/dev/null || true
            print_success "Old JDK packages removed"
        else
            print_info "Keeping existing JDK installations"
        fi
    else
        print_info "No existing JDK installations found"
    fi
}

################################################################################
# Function: Install Oracle OpenJDK 23 from RPM
################################################################################
install_jdk() {
    print_info "Installing Oracle OpenJDK ${JDK_MAJOR_VERSION}..."
    
    # Install the RPM package
    rpm -ivh "jdk-${JDK_MAJOR_VERSION}_linux-x64_bin.rpm" || {
        print_error "Failed to install JDK RPM"
        print_info "Attempting upgrade instead of install..."
        rpm -Uvh "jdk-${JDK_MAJOR_VERSION}_linux-x64_bin.rpm" || {
            print_error "Failed to upgrade JDK RPM"
            exit 1
        }
    }
    
    print_success "Oracle OpenJDK ${JDK_MAJOR_VERSION} installed successfully"
}

################################################################################
# Function: Configure JAVA_HOME environment variable
################################################################################
configure_environment() {
    print_info "Configuring JAVA_HOME environment variable..."
    
    # Detect actual installation directory
    ACTUAL_INSTALL_DIR=$(ls -d /usr/lib/jvm/jdk-${JDK_MAJOR_VERSION}* 2>/dev/null | head -1)
    
    if [[ -z "$ACTUAL_INSTALL_DIR" ]]; then
        # Try alternative location
        ACTUAL_INSTALL_DIR=$(ls -d /usr/java/jdk-${JDK_MAJOR_VERSION}* 2>/dev/null | head -1)
    fi
    
    if [[ -z "$ACTUAL_INSTALL_DIR" ]]; then
        print_error "Could not find JDK installation directory"
        exit 1
    fi
    
    print_info "JDK installed at: $ACTUAL_INSTALL_DIR"
    
    # Create system-wide environment configuration
    cat > /etc/profile.d/jdk.sh << EOF
# Java Environment Variables
export JAVA_HOME=$ACTUAL_INSTALL_DIR
export PATH=\$JAVA_HOME/bin:\$PATH
EOF
    
    chmod +x /etc/profile.d/jdk.sh
    
    # Source the file for current session
    source /etc/profile.d/jdk.sh
    
    print_success "Environment variables configured"
    print_info "JAVA_HOME set to: $ACTUAL_INSTALL_DIR"
}

################################################################################
# Function: Configure alternatives system
################################################################################
configure_alternatives() {
    print_info "Configuring Java alternatives..."
    
    # Detect actual installation directory
    ACTUAL_INSTALL_DIR=$(ls -d /usr/lib/jvm/jdk-${JDK_MAJOR_VERSION}* 2>/dev/null | head -1)
    
    if [[ -z "$ACTUAL_INSTALL_DIR" ]]; then
        ACTUAL_INSTALL_DIR=$(ls -d /usr/java/jdk-${JDK_MAJOR_VERSION}* 2>/dev/null | head -1)
    fi
    
    if [[ -n "$ACTUAL_INSTALL_DIR" ]]; then
        # Set up alternatives for java
        alternatives --install /usr/bin/java java "$ACTUAL_INSTALL_DIR/bin/java" 20000 || true
        alternatives --install /usr/bin/javac javac "$ACTUAL_INSTALL_DIR/bin/javac" 20000 || true
        alternatives --install /usr/bin/jar jar "$ACTUAL_INSTALL_DIR/bin/jar" 20000 || true
        
        # Set as default
        alternatives --set java "$ACTUAL_INSTALL_DIR/bin/java" || true
        alternatives --set javac "$ACTUAL_INSTALL_DIR/bin/javac" || true
        
        print_success "Alternatives configured successfully"
    fi
}

################################################################################
# Function: Verify installation
################################################################################
verify_installation() {
    print_info "Verifying Oracle OpenJDK ${JDK_MAJOR_VERSION} installation..."
    
    # Source environment variables
    source /etc/profile.d/jdk.sh 2>/dev/null || true
    
    # Check java command
    if command -v java &> /dev/null; then
        print_success "Java command found in PATH"
        
        # Display Java version
        print_info "Java version:"
        java -version 2>&1 | head -3
        
        # Verify it's the correct version
        INSTALLED_VERSION=$(java -version 2>&1 | head -1 | cut -d'"' -f2)
        if [[ "$INSTALLED_VERSION" =~ ^${JDK_MAJOR_VERSION} ]]; then
            print_success "Correct version installed: $INSTALLED_VERSION"
        else
            print_warning "Installed version ($INSTALLED_VERSION) may not match expected ($JDK_MAJOR_VERSION)"
        fi
    else
        print_error "Java command not found in PATH"
        print_info "You may need to log out and log back in, or run: source /etc/profile.d/jdk.sh"
        exit 1
    fi
    
    # Check javac (compiler)
    if command -v javac &> /dev/null; then
        print_success "Java compiler (javac) found"
        print_info "Javac version:"
        javac -version 2>&1
    else
        print_warning "Java compiler (javac) not found in PATH"
    fi
    
    # Check JAVA_HOME
    if [[ -n "$JAVA_HOME" ]] && [[ -d "$JAVA_HOME" ]]; then
        print_success "JAVA_HOME is set: $JAVA_HOME"
    else
        print_warning "JAVA_HOME not set or invalid"
    fi
    
    # Display installation summary
    echo ""
    print_success "============================================"
    print_success "Oracle OpenJDK ${JDK_MAJOR_VERSION} Installation Complete!"
    print_success "============================================"
    echo ""
    print_info "Installation Details:"
    echo "  - Java Version: $(java -version 2>&1 | head -1)"
    echo "  - JAVA_HOME: $JAVA_HOME"
    echo "  - Java Binary: $(which java)"
    echo "  - Javac Binary: $(which javac 2>/dev/null || echo 'Not in PATH')"
    echo ""
    print_info "To use Java in new terminal sessions:"
    echo "  - Environment is automatically configured in /etc/profile.d/jdk.sh"
    echo "  - Or run: source /etc/profile.d/jdk.sh"
    echo ""
}

################################################################################
# Function: Cleanup
################################################################################
cleanup() {
    print_info "Cleaning up temporary files..."
    
    if [[ -d "$DOWNLOAD_DIR" ]]; then
        rm -rf "$DOWNLOAD_DIR"
        print_success "Temporary files removed"
    fi
}

################################################################################
# Function: Display usage
################################################################################
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --skip-download    Skip the download step (use existing RPM)"
    echo "  --skip-cleanup     Don't remove temporary files"
    echo "  --help             Display this help message"
    echo ""
    echo "Example:"
    echo "  sudo $0"
    echo "  sudo $0 --skip-download"
    echo ""
}

################################################################################
# Main Script Execution
################################################################################
main() {
    # Parse command line arguments
    SKIP_DOWNLOAD=false
    SKIP_CLEANUP=false
    
    for arg in "$@"; do
        case $arg in
            --skip-download)
                SKIP_DOWNLOAD=true
                shift
                ;;
            --skip-cleanup)
                SKIP_CLEANUP=true
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $arg"
                usage
                exit 1
                ;;
        esac
    done
    
    # Display banner
    echo ""
    echo "============================================"
    echo "  Oracle OpenJDK ${JDK_MAJOR_VERSION} Installation Script"
    echo "  for AlmaLinux 9"
    echo "============================================"
    echo ""
    
    # Execute installation steps
    check_root
    check_system
    install_dependencies
    create_download_dir
    
    if [[ "$SKIP_DOWNLOAD" == false ]]; then
        download_jdk
    else
        print_warning "Skipping download step"
        if [[ ! -f "jdk-${JDK_MAJOR_VERSION}_linux-x64_bin.rpm" ]]; then
            print_error "RPM file not found: jdk-${JDK_MAJOR_VERSION}_linux-x64_bin.rpm"
            exit 1
        fi
    fi
    
    remove_old_jdk
    install_jdk
    configure_environment
    configure_alternatives
    verify_installation
    
    if [[ "$SKIP_CLEANUP" == false ]]; then
        cleanup
    else
        print_warning "Skipping cleanup step"
    fi
    
    echo ""
    print_success "Installation script completed successfully!"
    echo ""
}

# Trap errors and cleanup
trap 'print_error "Script failed at line $LINENO"' ERR

# Run main function
main "$@"