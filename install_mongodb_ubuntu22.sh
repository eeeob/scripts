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

print_warning() {
    echo "[WARNING] $1"
}

print_error() {
    echo "[ERROR] $1"
}

check_existing_installation() {
    print_step "Checking existing MongoDB installation"

    if ! dpkg -s mongodb-org >/dev/null 2>&1; then
        print_info "MongoDB is not installed."
        return 0
    fi

    print_warning "MongoDB is already installed."
    
    # 1. التحقق مما إذا كانت الخدمة شغالة أم لا
    if ! sudo systemctl is-active --quiet mongod; then
        print_warning "MongoDB service is currently NOT running!"
        read -rp "Do you want to start the MongoDB service now? [y/N]: " start_choice </dev/tty || true
        if [[ "${start_choice,,}" =~ ^y ]]; then
            print_info "Starting MongoDB service..."
            sudo systemctl daemon-reload
            sudo systemctl start mongod
            print_info "MongoDB service started successfully."
        else
            print_info "Skipping starting MongoDB service."
        fi
    else
        print_info "MongoDB service is already running and active."
    fi

    # 2. التحقق مما إذا كانت الخدمة مفعلة عند الإقلاع أم لا
    if ! sudo systemctl is-enabled --quiet mongod; then
        print_warning "MongoDB service is NOT enabled to start on reboot!"
        read -rp "Do you want to enable MongoDB on system startup? [y/N]: " enable_choice </dev/tty || true
        if [[ "${enable_choice,,}" =~ ^y ]]; then
            print_info "Enabling MongoDB service on reboot..."
            sudo systemctl enable mongod
            print_info "MongoDB service enabled successfully."
        else
            print_info "Skipping enabling MongoDB on reboot."
        fi
    else
        print_info "MongoDB service is already enabled for startup."
    fi

    echo
    echo "Choose an option:"
    echo "  [R] Remove MongoDB and reinstall"
    echo "  [E] Exit / Continue setup"
    echo

    printf "Selection (default: Continue): "
    read -r choice </dev/tty || true
    choice="${choice,,}"

    case "$choice" in
        r)
            print_info "Stopping MongoDB service..."
            sudo systemctl stop mongod 2>/dev/null || true
            sudo systemctl disable mongod 2>/dev/null || true

            print_info "Removing MongoDB packages..."
            sudo apt-get purge -y mongodb-org*
            sudo apt-get autoremove -y

            sudo rm -f /etc/apt/sources.list.d/mongodb-org-8.0.list
            sudo rm -f /usr/share/keyrings/mongodb-server-8.0.gpg

            echo
            read -rp "Remove all MongoDB data? [y/N]: " remove_data </dev/tty
            if [[ "${remove_data,,}" =~ ^y ]]; then
                print_info "Removing MongoDB data..."
                sudo rm -rf /var/lib/mongodb
                sudo rm -rf /var/log/mongodb
            else
                print_info "Keeping MongoDB data."
            fi

            print_info "Previous MongoDB installation removed. Proceeding with fresh installation..."
            ;;
        *)
            print_info "Continuing with existing MongoDB installation."
            return 0
            ;;
    esac
}

check_existing_installation

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

SERVICE_FILE="/lib/systemd/system/mongod.service"
if [ -f "$SERVICE_FILE" ]; then
    if grep -q "MONGODB_CONFIG_OVERRIDE_NOFORK=1" "$SERVICE_FILE"; then
        print_info "Detected conflicting NOFORK environment variable in mongod.service. Fixing automatically..."
        sudo sed -i 's/Environment="MONGODB_CONFIG_OVERRIDE_NOFORK=1"/#Environment="MONGODB_CONFIG_OVERRIDE_NOFORK=1"/g' "$SERVICE_FILE"
    fi
fi

# يفضل استخدام systemctl الحديث بدلاً من service لضمان التوافق مع التمكين التلقائي عند الإقلاع
sudo systemctl daemon-reload
sudo systemctl enable mongod
sudo systemctl start mongod

print_info "Waiting for MongoDB to start..."

sleep 2

print_step "Step 6/6 - Verify Installation"

echo
print_info "MongoDB version:"
mongod --version | head -n 1

echo
print_info "MongoDB service status:"
sudo systemctl status mongod --no-pager -l 