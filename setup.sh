#!/bin/bash

# Script to automate system updates and install Node.js and PM2
# Run with: bash setup.sh or chmod +x setup.sh && ./setup.sh

set -e  # Exit on error

echo "========================================="
echo "Starting system setup..."
echo "========================================="

# Update package list and upgrade system
echo ""
echo "Step 1: Updating package list and upgrading system..."
apt update && apt upgrade -y

# Install prerequisites
echo ""
echo "Step 2: Installing prerequisites (curl, build-essential)..."
apt install -y curl build-essential

# Install Node.js (using NodeSource repository for LTS version)
echo ""
echo "Step 3: Installing Node.js..."
if ! command -v node &> /dev/null; then
    # Install Node.js 20.x LTS
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
    echo "Node.js installed successfully"
    node --version
    npm --version
else
    echo "Node.js is already installed: $(node --version)"
fi

# Install PM2 globally
echo ""
echo "Step 4: Installing PM2..."
if ! command -v pm2 &> /dev/null; then
    npm install -g pm2
    echo "PM2 installed successfully"
    pm2 --version
else
    echo "PM2 is already installed: $(pm2 --version)"
fi

# Setup PM2 to start on system boot
echo ""
echo "Step 5: Setting up PM2 startup script..."
pm2 startup systemd -u $USER --hp $HOME || echo "PM2 startup already configured or requires manual setup"

# Start fix_wai.sh with PM2
echo ""
echo "Step 6: Starting fix_wai.sh monitor with PM2..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_SCRIPT="$SCRIPT_DIR/fix_wai.sh"

if [ -f "$FIX_SCRIPT" ]; then
    # Check if already running, delete and restart if needed
    pm2 delete fix_stuck_wai 2>/dev/null || true
    pm2 start "$FIX_SCRIPT" --interpreter bash --name fix_wai
    echo "fix_wai.sh started with PM2"
else
    echo "Warning: fix_wai.sh not found at $FIX_SCRIPT"
fi

# Install wai CLI tool
echo ""
echo "Step 7: Installing wai CLI tool..."
if ! command -v wai &> /dev/null; then
    curl -fsSL https://app.w.ai/install.sh | bash
    echo "wai CLI tool installed successfully"
else
    echo "wai CLI tool is already installed"
fi

echo ""
echo "========================================="
echo "Setup completed successfully!"
echo "========================================="
echo ""
echo "Installed versions:"
echo "  Node.js: $(node --version)"
echo "  npm: $(npm --version)"
echo "  PM2: $(pm2 --version)"
echo ""
echo "You can now use PM2 to manage your W.AI instances"
echo "Run: pm2 start ecosystem.config.js" --only wai-1
