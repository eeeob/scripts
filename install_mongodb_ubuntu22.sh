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
        return
    fi

    print_warning "MongoDB is already installed."
    echo

    while true; do
        echo "Choose an option:"
        echo "  [R] Remove MongoDB and reinstall"
        echo "  [E] Exit"
        echo

        printf "Selection: "
        read -r choice </dev/tty || true

        choice="${choice,,}"  # تحويل إلى lowercase

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

                while true; do
                    # تعديل مهم: إضافة </dev/tty هنا لمنع السكربت من التعليق عند تشغيله عبر curl/wget
                    read -rp "Remove all MongoDB data? [y/N]: " remove_data </dev/tty

                    case "${remove_data,,}" in
                        y|yes)
                            print_info "Removing MongoDB data..."

                            sudo rm -rf /var/lib/mongodb
                            sudo rm -rf /var/log/mongodb

                            break
                            ;;

                        n|no|"")
                            print_info "Keeping MongoDB data."
                            break
                            ;;

                        *)
                            print_error "Invalid selection."
                            ;;
                    esac
                done

                print_info "Previous MongoDB installation removed."

                break
                ;;

            e)
                print_info "Installation cancelled."
                exit 0
                ;;

            *)
                print_error "Invalid selection."
                ;;
        esac
    done
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