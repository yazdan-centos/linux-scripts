#!/bin/bash

# Script to automate Git setup, SSH key generation, and GitHub repository cloning
# For AlmaLinux 9

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
SSH_KEY_TYPE="ed25519"

# Function to print colored messages
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to extract repository name from URL
extract_repo_name() {
    local url=$1
    # Remove .git suffix if present
    url="${url%.git}"
    # Extract last part of the path
    basename "$url"
}

# Function to validate GitHub URL
validate_github_url() {
    local url=$1
    if [[ $url =~ ^git@github\.com:.+/.+\.git$ ]] || \
       [[ $url =~ ^https://github\.com/.+/.+\.git$ ]] || \
       [[ $url =~ ^git@github\.com:.+/.+$ ]] || \
       [[ $url =~ ^https://github\.com/.+/.+$ ]]; then
        return 0
    else
        return 1
    fi
}

# Print header
print_message "$BLUE" "=========================================="
print_message "$BLUE" "GitHub Repository Setup Script"
print_message "$BLUE" "For AlmaLinux 9"
print_message "$BLUE" "=========================================="
echo

# Prompt for repository URL
print_message "$YELLOW" "Please enter the GitHub repository URL:"
print_message "$BLUE" "Examples:"
print_message "$BLUE" "  - git@github.com:username/repo.git"
print_message "$BLUE" "  - https://github.com/username/repo.git"
echo

while true; do
    read -p "Repository URL: " REPO_URL
    
    if [ -z "$REPO_URL" ]; then
        print_message "$RED" "Error: Repository URL cannot be empty."
        continue
    fi
    
    if validate_github_url "$REPO_URL"; then
        break
    else
        print_message "$RED" "Error: Invalid GitHub URL format."
        print_message "$YELLOW" "Please enter a valid GitHub repository URL."
    fi
done

# Extract repository name
REPO_NAME=$(extract_repo_name "$REPO_URL")

# Prompt for destination directory (with default)
DEFAULT_DEST="/srv/repos/${REPO_NAME}"
print_message "$YELLOW" "\nEnter destination directory (press Enter for default: $DEFAULT_DEST):"
read -p "Destination: " DEST_DIR

if [ -z "$DEST_DIR" ]; then
    DEST_DIR="$DEFAULT_DEST"
fi

# Convert SSH URL to HTTPS if needed for initial authentication check
if [[ $REPO_URL =~ ^https:// ]]; then
    REPO_URL_SSH="git@github.com:$(echo $REPO_URL | sed 's|https://github.com/||' | sed 's|\.git$||').git"
else
    REPO_URL_SSH="$REPO_URL"
fi

# Display configuration
print_message "$GREEN" "\n=========================================="
print_message "$GREEN" "Configuration Summary:"
print_message "$GREEN" "=========================================="
print_message "$GREEN" "Repository URL: $REPO_URL"
print_message "$GREEN" "Repository Name: $REPO_NAME"
print_message "$GREEN" "Destination: $DEST_DIR"
print_message "$GREEN" "=========================================="
echo

read -p "Continue with this configuration? (Y/n): " confirm
if [[ $confirm =~ ^[Nn]$ ]]; then
    print_message "$YELLOW" "Setup cancelled by user."
    exit 0
fi

# Step 1: Check Git and OpenSSH installation
print_message "$YELLOW" "\nStep 1: Checking Git and OpenSSH installation..."

if ! command_exists git; then
    print_message "$YELLOW" "Git is not installed. Installing Git..."
    sudo dnf install -y git
    print_message "$GREEN" "Git installed successfully."
else
    print_message "$GREEN" "Git is already installed ($(git --version))."
fi

if ! command_exists ssh; then
    print_message "$YELLOW" "OpenSSH client is not installed. Installing OpenSSH..."
    sudo dnf install -y openssh-clients
    print_message "$GREEN" "OpenSSH installed successfully."
else
    print_message "$GREEN" "OpenSSH is already installed ($(ssh -V 2>&1))."
fi

# Step 2: Generate a personal SSH key (if not available)
print_message "$YELLOW" "\nStep 2: Checking for SSH key..."

if [ -f "$SSH_KEY_PATH" ]; then
    print_message "$GREEN" "SSH key already exists at $SSH_KEY_PATH"
else
    print_message "$YELLOW" "Generating new SSH key..."
    
    # Create .ssh directory if it doesn't exist
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    
    # Prompt for email
    read -p "Enter your email address for the SSH key: " user_email
    
    # Generate SSH key
    ssh-keygen -t "$SSH_KEY_TYPE" -C "$user_email" -f "$SSH_KEY_PATH" -N ""
    
    print_message "$GREEN" "SSH key generated successfully."
    print_message "$YELLOW" "\n=========================================="
    print_message "$YELLOW" "Your public SSH key:"
    print_message "$YELLOW" "=========================================="
    cat "${SSH_KEY_PATH}.pub"
    print_message "$YELLOW" "=========================================="
    print_message "$YELLOW" "\nPlease add this key to your GitHub account:"
    print_message "$YELLOW" "1. Go to https://github.com/settings/keys"
    print_message "$YELLOW" "2. Click 'New SSH key'"
    print_message "$YELLOW" "3. Paste the key above"
    print_message "$YELLOW" "4. Click 'Add SSH key'"
    print_message "$YELLOW" "=========================================="
    
    read -p "Press Enter after adding the key to GitHub..."
fi

# Step 3: Add the key to the SSH Agent
print_message "$YELLOW" "\nStep 3: Adding SSH key to SSH Agent..."

# Start ssh-agent if not running
if [ -z "$SSH_AGENT_PID" ]; then
    eval "$(ssh-agent -s)"
    print_message "$GREEN" "SSH Agent started."
else
    print_message "$GREEN" "SSH Agent is already running."
fi

# Add SSH key to the agent
ssh-add "$SSH_KEY_PATH" 2>/dev/null && \
    print_message "$GREEN" "SSH key added to agent." || \
    print_message "$YELLOW" "SSH key may already be added to agent."

# Step 4: Test the connection to GitHub
print_message "$YELLOW" "\nStep 4: Testing connection to GitHub..."

# Add GitHub to known_hosts if not already present
if ! grep -q "github.com" "$HOME/.ssh/known_hosts" 2>/dev/null; then
    ssh-keyscan -H github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
    print_message "$GREEN" "GitHub added to known_hosts."
fi

# Test SSH connection
if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    print_message "$GREEN" "Successfully authenticated with GitHub!"
else
    print_message "$RED" "Failed to authenticate with GitHub."
    print_message "$YELLOW" "Please make sure you've added your SSH key to GitHub."
    exit 1
fi

# Step 5: Clone the repository
print_message "$YELLOW" "\nStep 5: Cloning repository from GitHub..."

# Create parent directory if it doesn't exist
PARENT_DIR=$(dirname "$DEST_DIR")
if [ ! -d "$PARENT_DIR" ]; then
    print_message "$YELLOW" "Creating parent directory: $PARENT_DIR"
    sudo mkdir -p "$PARENT_DIR"
    sudo chown "$USER:$USER" "$PARENT_DIR"
fi

# Clone the repository
if [ -d "$DEST_DIR" ]; then
    print_message "$YELLOW" "Directory $DEST_DIR already exists."
    read -p "Do you want to remove it and clone fresh? (y/N): " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        rm -rf "$DEST_DIR"
        git clone "$REPO_URL" "$DEST_DIR"
        print_message "$GREEN" "Repository cloned successfully to $DEST_DIR"
    else
        print_message "$YELLOW" "Skipping clone. Existing directory preserved."
    fi
else
    git clone "$REPO_URL" "$DEST_DIR"
    print_message "$GREEN" "Repository cloned successfully to $DEST_DIR"
fi

# Display repository information if clone was successful
if [ -d "$DEST_DIR/.git" ]; then
    print_message "$BLUE" "\nRepository Information:"
    cd "$DEST_DIR"
    print_message "$BLUE" "Current branch: $(git branch --show-current)"
    print_message "$BLUE" "Latest commit: $(git log -1 --pretty=format:'%h - %s (%cr)')"
fi

# Final summary
print_message "$GREEN" "\n=========================================="
print_message "$GREEN" "Setup completed successfully!"
print_message "$GREEN" "=========================================="
print_message "$GREEN" "Repository URL: $REPO_URL"
print_message "$GREEN" "Repository location: $DEST_DIR"
print_message "$GREEN" "SSH key location: $SSH_KEY_PATH"
print_message "$GREEN" "=========================================="