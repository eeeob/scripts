#!/bin/bash

# ==============================================================================
# MongoDB Install Script (Ubuntu 20.04 / 22.04 / 24.04)
# التثبيت من المصادر الرسمية فقط: repo.mongodb.org أو صورة mongo الرسمية على Docker
# قابل لإعادة التشغيل أكثر من مرة بدون مشاكل، وآمن للتشغيل المنفرد عبر:
#   bash <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/install_mongodb.sh)
# تمرير -y يوافق تلقائياً على جميع التحققات، و -n يرفضها تلقائياً
# ==============================================================================

set -e

# جلب الدوال المشتركة من utils.sh
sudo apt-get update -y && sudo apt-get install -y curl && source <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/utils.sh)

TEMP_CONFIG_DIR="/root/.temp_configs/mongodb"
CONFIG_DIR="/root/.configs/mongodb"

CONFIG_FILE="$CONFIG_DIR/mongodb_install.conf"
DOCKER_COMPOSE_FILE="$CONFIG_DIR/docker-compose.yml"

CONFIGS_REPO_URL="https://github.com/eeeob/configs.git"

MONGO_VERSION="8.0"

DOCKER_CONTAINER_NAME="mongodb"
BIND_IP="127.0.0.1"

UBUNTU_CODENAME=$(_get_ubuntu_codename "20.04 22.04 24.04")

INSTALL_METHOD=""

# التعرف على الأعلام المشتركة (-y موافقة / -n رفض تلقائي) مع إعادة تعيين باقي args للسكربت
eval "$(_parse_common_flags --reset "$@")"

# --- كشف تثبيت سابق موجود فعلياً لكن غير موثق في ملف config (حالة مخفية) ---
detect_previous_installation() {
    local found=""

    dpkg -s mongodb-org >/dev/null 2>&1 && found="native package 'mongodb-org'"

    if command -v docker >/dev/null 2>&1 && _container_exists "$DOCKER_CONTAINER_NAME"; then
        found="${found:+$found + }Docker container '$DOCKER_CONTAINER_NAME'"
    fi

    [ -z "$found" ] && return 0

    print_warning "Existing MongoDB installation detected on this server: $found."

    if ! _confirm "Continue and reconfigure on top of the existing installation? (y/n): "; then
        print_info "Aborted by user. Nothing was changed."
        exit 0
    fi
}

# --- تخيير المستخدم بين التثبيت المباشر أو داخل Docker ---
choose_install_method() {
    print_step "Choose installation method"
    print_info "Native = official apt repo (repo.mongodb.org). Docker = official 'mongo' image."

    if _confirm "Install MongoDB inside Docker instead of the native installation? (y/n): "; then
        INSTALL_METHOD="docker"
    else
        INSTALL_METHOD="native"
    fi
}

# --- التثبيت المباشر من المستودع الرسمي ---
install_native() {
    print_step "Installing MongoDB ${MONGO_VERSION} (native, official repo)"
    
    _install_dependencies gnupg ca-certificates

    curl -fsSL "https://pgp.mongodb.com/server-${MONGO_VERSION}.asc" | \
        sudo gpg --dearmor --yes -o "/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg"

    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg ] https://repo.mongodb.org/apt/ubuntu ${UBUNTU_CODENAME}/mongodb-org/${MONGO_VERSION} multiverse" | \
        sudo tee "/etc/apt/sources.list.d/mongodb-org-${MONGO_VERSION}.list" >/dev/null

    _install_dependencies mongodb-org

    # التأكد من وجود مجلدي البيانات والسجلات بالملكية الصحيحة (قد يكونان مفقودين)
    sudo mkdir -p /var/lib/mongodb /var/log/mongodb
    sudo chown mongodb:mongodb /var/lib/mongodb /var/log/mongodb

    sudo systemctl daemon-reload
    sudo systemctl enable mongod >/dev/null 2>&1
    sudo systemctl restart mongod

    if ! _confirm "Make MongoDB accessible to Docker containers via docker0 (172.17.0.1)? (y/n): "; then
        print_info "Skipping Docker access configuration."
        return 0
    fi

    _install_docker

    print_step "Configuring MongoDB bindIp for docker0"

    sudo sed -i -E 's/^([[:space:]]*)bindIp:.*/\1bindIp: 127.0.0.1,172.17.0.1/' /etc/mongod.conf
    BIND_IP="127.0.0.1,172.17.0.1"

    # ربط mongod بـ docker.service حتى لا يفشل عند الإقلاع قبل ظهور docker0 (exit code 48)
    sudo mkdir -p /etc/systemd/system/mongod.service.d
    sudo cp "$TEMP_CONFIG_DIR/mongod_docker_override.conf" /etc/systemd/system/mongod.service.d/override.conf

    sudo systemctl daemon-reload
    sudo systemctl restart mongod
    
    print_info "MongoDB is now bound to 127.0.0.1 and 172.17.0.1 with a systemd dependency on docker.service."
}

# --- التثبيت داخل Docker عبر compose من الصورة الرسمية ---
install_in_docker() {
    print_step "Installing MongoDB ${MONGO_VERSION} (Docker Compose, official image)"

    _install_docker
    _create_docker_network

    
    _render_template_file "$TEMP_CONFIG_DIR/docker-compose.yml.template" "$DOCKER_COMPOSE_FILE" MONGO_VERSION="$MONGO_VERSION"
    
    print_info "Compose file saved to $DOCKER_COMPOSE_FILE"

    if _handle_existing_container "$DOCKER_CONTAINER_NAME"; then
        sudo docker compose -f "$DOCKER_COMPOSE_FILE" up -d
        print_info "MongoDB container started (port 27017 published on 127.0.0.1 only)."
    else
        sudo docker start "$DOCKER_CONTAINER_NAME" >/dev/null 2>&1 || true
        print_info "Existing container kept and started."
    fi
}

# --- التحقق من نجاح التثبيت ---
verify_installation() {
    print_step "Verify installation"

    if [ "$INSTALL_METHOD" = "native" ]; then
        mongod --version | head -n 1
        
        if sudo systemctl is-active --quiet mongod; then
            print_info "MongoDB service is running."
        else
            print_error "MongoDB service is NOT running. Check: sudo journalctl -u mongod -e"
            exit 1
        fi
    else
        sudo docker ps --filter "name=^${DOCKER_CONTAINER_NAME}$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

        if ! _container_exists "$DOCKER_CONTAINER_NAME" || ! sudo docker ps --format '{{.Names}}' | grep -qx "$DOCKER_CONTAINER_NAME"; then
            print_error "MongoDB container is NOT running. Check: sudo docker logs $DOCKER_CONTAINER_NAME"
            exit 1
        fi
        print_info "MongoDB container is running."
    fi
}

# --- كتابة ملف config يوثق تفاصيل التثبيت مع توليد سكربت التصفية ---
write_config() {
    print_step "Writing config file"

    local cleanup_script="$CONFIG_DIR/cleanup.sh"
    local container_name=""


    if [ "$INSTALL_METHOD" = "native" ]; then
        _render_template_file "$TEMP_CONFIG_DIR/cleanup_native.sh.template" "$cleanup_script" \
            APT_SOURCE_FILE="/etc/apt/sources.list.d/mongodb-org-${MONGO_VERSION}.list" \
            KEYRING_FILE="/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg"
    else
        container_name="$DOCKER_CONTAINER_NAME"

        _render_template_file "$TEMP_CONFIG_DIR/cleanup_docker.sh.template" "$cleanup_script" \
            COMPOSE_FILE="$DOCKER_COMPOSE_FILE" \
            CONTAINER_NAME="$DOCKER_CONTAINER_NAME"
    fi
    sudo chmod +x "$cleanup_script"

    _render_template_file "$TEMP_CONFIG_DIR/mongodb_install.conf.template" "$CONFIG_FILE" \
        CONFIGURED_AT="$(date '+%Y-%m-%d %H:%M:%S')" \
        INSTALL_METHOD="$INSTALL_METHOD" \
        BIND_IP="$BIND_IP" \
        DOCKER_CONTAINER_NAME="$container_name" \
        CLEANUP_COMMAND="bash $cleanup_script"

    print_info "Config saved to $CONFIG_FILE"
}

# --- إضافة معلومات استخدام سريعة لشاشة الدخول عبر SSH (من template في configs) ---
add_ssh_quick_info() {
    print_step "Adding quick usage info to the SSH login screen"

    local status_command logs_command shell_command restart_command cleanup_command

    if [ "$INSTALL_METHOD" = "native" ]; then
        restart_command="sudo systemctl restart mongod"
        status_command="sudo systemctl status mongod"
        logs_command="sudo journalctl -u mongod -e"
        shell_command="mongosh"
    else
        restart_command="sudo docker compose -f $DOCKER_COMPOSE_FILE restart"
        status_command="sudo docker ps --filter name=$DOCKER_CONTAINER_NAME"
        logs_command="sudo docker logs -f $DOCKER_CONTAINER_NAME"
        shell_command="sudo docker exec -it $DOCKER_CONTAINER_NAME mongosh"
    fi

    cleanup_command="bash $CONFIG_DIR/cleanup.sh"

    _add_motd_info "mongodb" "$TEMP_CONFIG_DIR/motd-info.sh.tmpl" \
        RESTART_COMMAND="$restart_command" \
        STATUS_COMMAND="$status_command" \
        CLEANUP_COMMAND="$cleanup_command" \
        LOGS_COMMAND="$logs_command" \
        SHELL_COMMAND="$shell_command" \
        CONFIG_FILE="$CONFIG_FILE"

    print_info "Quick usage info will appear on the next SSH login."
}

trap 'rm -rf "$TEMP_CONFIG_DIR"' EXIT

_handle_existing_config_file "$CONFIG_FILE"

detect_previous_installation
choose_install_method

_download_github_path "$CONFIGS_REPO_URL" "mongodb" "$TEMP_CONFIG_DIR"

print_info "Detected supported Ubuntu release: $UBUNTU_CODENAME"

if [ "$INSTALL_METHOD" = "native" ]; then
    install_native
else
    install_in_docker
fi

verify_installation
write_config
add_ssh_quick_info

print_step "MongoDB setup completed successfully"
