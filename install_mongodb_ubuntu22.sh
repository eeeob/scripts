#!/bin/bash

set -e

print_step() {
    echo
    echo "=================================================="
    echo "$1"
    echo "=================================================="
}

print_info() {
    echo "[INFO] $1"
}

print_error() {
    echo "[ERROR] $1"
}

print_step "Step 1/6 - Install required packages"

sudo apt-get update -y
sudo apt-get install -y curl gnupg 

print_step "Step 2/6 - Add MongoDB GPG key"

curl -fsSL https://pgp.mongodb.com/server-8.0.asc | \
   sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg \
   --dearmor

print_step "Step 3/6 - Add MongoDB repository"

echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/8.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list

sudo apt-get update -y

print_step "Step 4/6 - Install MongoDB"

sudo apt-get install -y mongodb-org

print_step "Step 5/6 - Enable and start MongoDB"

sudo systemctl enable mongod

if ! sudo systemctl is-active --quiet mongod; then
    print_info "Starting MongoDB service..."
    sudo systemctl start mongod
fi

print_step "Step 6/6 - Verify installation"

if sudo systemctl is-active --quiet mongod; then
    print_info "MongoDB is running successfully."
else
    print_error "MongoDB failed to start."
    sudo systemctl status mongod --no-pager
    exit 1
fi

echo
print_info "MongoDB version:"
mongod --version | head -n 1

echo
print_info "MongoDB service status:"
sudo systemctl --no-pager --full status mongod