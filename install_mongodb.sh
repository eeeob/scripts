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


#shared
CONFIGS_REPO_URL="https://github.com/eeeob/configs.git"

TEMP_CONFIG_DIR="/root/.temp_configs/mongodb"
CONFIG_DIR="/root/.configs/mongodb"

CONFIG_FILE="$CONFIG_DIR/mongodb_install.conf"

MONGO_VERSION="8.0"
PORT="27017"

BIND_IP=""
INSTALL_METHOD=""

STOP_UFW=""



#native
UBUNTU_CODENAME=$(_get_ubuntu_codename "20.04 22.04 24.04")

#docker
DOCKER_COMPOSE_FILE="$CONFIG_DIR/docker-compose.yml"
DOCKER_CONTAINER_NAME="mongodb"
DOCKER_NETWORK_NAME="main_network"


# التعرف على الأعلام المشتركة (-y موافقة / -n رفض تلقائي) مع إعادة تعيين باقي args للسكربت
eval "$(_parse_common_flags --reset "$@")"
_parse_choice_value "native docker" INSTALL_METHOD "$@"

# --- كشف تثبيت سابق موجود فعلياً لكن غير موثق في ملف config (حالة مخفية) ---
# عند وجود تثبيت شغّال وموافقة المستخدم على المتابعة، تتم تصفيته بالكامل بالطرق الرسمية
detect_previous_installation() {
    local found_native="no"
    local found_docker="no"
    local found=""

    if _package_installed mongodb-org || _service_exists mongod; then
        found_native="yes"
        found="native package 'mongodb-org'"
    fi

    if _container_exists "$DOCKER_CONTAINER_NAME"; then
        found_docker="yes"
        found="${found:+$found + }Docker container '$DOCKER_CONTAINER_NAME'"
    fi

    [ -z "$found" ] && return 0

    print_warning "Existing MongoDB installation detected on this server: $found."

    if ! _confirm "Remove the existing installation completely (official cleanup) and reinstall from scratch? (y/n): "; then
        print_info "Aborted by user. Nothing was changed."
        exit 0
    fi

    print_step "Removing the existing MongoDB installation (official cleanup)"

    # تصفية التثبيت المباشر بالطرق الرسمية (إيقاف الخدمة، إزالة الحزم والمصادر والبيانات)
    if [ "$found_native" = "yes" ]; then
        print_info "Cleaning up the native MongoDB installation..."
        _destroy_service "mongod"
        sudo apt-get purge -y "mongodb-org*" 2>/dev/null || true
        sudo apt-get autoremove -y 2>/dev/null || true
        sudo rm -f /etc/apt/sources.list.d/mongodb-org-*.list
        sudo rm -f /usr/share/keyrings/mongodb-server-*.gpg
        sudo rm -rf /var/lib/mongodb /var/log/mongodb
    fi

    # تصفية تثبيت Docker (حذف الحاوية مع صورتها وشبكاتها الخاصة)
    if [ "$found_docker" = "yes" ]; then
        print_info "Cleaning up the Docker MongoDB installation..."
        _remove_container "$DOCKER_CONTAINER_NAME"
    fi

    sudo rm -rf "${CONFIG_DIR}"

    print_info "Existing MongoDB installation removed. Continuing with a fresh setup..."
}

install() {
    if [[ -z "$INSTALL_METHOD" ]]; then
        print_step "Choose installation method"
        print_info "Native = official apt repo (repo.mongodb.org). Docker = official 'mongo' image."

        if _confirm "Install MongoDB inside Docker instead of the native installation? (y/n): "; then
            INSTALL_METHOD="docker"
        else
            INSTALL_METHOD="native"
        fi
    fi

    if [[ "$INSTALL_METHOD" == "docker" ]]; then
        install_in_docker
    else
        install_native
    fi
    
}



install_native() {
    if _package_installed mongodb-org || _package_installed mongod || _service_exists mongod; then
        print_error "A native MongoDB installation still exists. Aborting to avoid a broken setup."
        exit 1
    fi

    print_step "Installing MongoDB ${MONGO_VERSION} (native, official repo)"
    
    _ensure_packages gnupg ca-certificates

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

    BIND_IP="127.0.0.1"

    if ! _confirm "Make MongoDB accessible to Docker containers via docker0 (172.17.0.1)? (y/n): "; then
        print_info "Skipping Docker access configuration."
        _wait_for_service "mongod" 10
        return 0
    fi

    _install_docker

    print_step "Configuring MongoDB bindIp for docker0"

    BIND_IP="127.0.0.1,172.17.0.1"

    sudo sed -i -E "s/^([[:space:]]*)bindIp:.*/\1bindIp: $BIND_IP/" /etc/mongod.conf
    
    # ربط mongod بـ docker.service حتى لا يفشل عند الإقلاع قبل ظهور docker0 (exit code 48)
    sudo mkdir -p /etc/systemd/system/mongod.service.d
    sudo cp "$TEMP_CONFIG_DIR/mongod_docker_override.conf" /etc/systemd/system/mongod.service.d/override.conf

    sudo systemctl daemon-reload
    sudo systemctl restart mongod
    
    print_info "MongoDB is now bound to 127.0.0.1 and 172.17.0.1 with a systemd dependency on docker.service."

    _wait_for_service "mongod" 10

    if _package_installed ufw && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        sudo ufw allow to 172.17.0.1 port "$PORT" proto tcp
        STOP_UFW="ufw delete allow to 172.17.0.1 port $PORT proto tcp"
    fi

    
}

# --- التثبيت داخل Docker عبر compose من الصورة الرسمية ---
install_in_docker() {
    if _container_exists "$DOCKER_CONTAINER_NAME"; then
        print_error "A Docker container named '$DOCKER_CONTAINER_NAME' still exists. Aborting to avoid a conflict."
        exit 1
    fi

    print_step "Installing MongoDB ${MONGO_VERSION} (Docker Compose, official image)"

    _install_docker
    _create_docker_network 

    BIND_IP="127.0.0.1"

    _render_template_file "$TEMP_CONFIG_DIR/docker-compose.yml.template" "$DOCKER_COMPOSE_FILE" \
        MONGO_VERSION PORT BIND_IP \
        CONTAINER_NAME="$DOCKER_CONTAINER_NAME" \
        NETWORK_NAME="$DOCKER_NETWORK_NAME"

    print_info "Compose file saved to $DOCKER_COMPOSE_FILE"

    sudo docker compose -f "$DOCKER_COMPOSE_FILE" up -d
    _wait_for_container "$DOCKER_CONTAINER_NAME" 30

    print_info "MongoDB container started (port 27017 published on 127.0.0.1 only)."
}

# --- كتابة ملف config يوثق تفاصيل التثبيت مع توليد سكربت التصفية ---
write_config() {
    print_step "Writing config file"

    local cleanup_script="$CONFIG_DIR/cleanup.sh"

    local docker_container_name=""
    local docker_network_name=""


    if [ "$INSTALL_METHOD" = "native" ]; then
        _render_template_file "$TEMP_CONFIG_DIR/cleanup_native.sh.template" "$cleanup_script" \
            STOP_UFW CONFIG_DIR \
            APT_SOURCE_FILE="/etc/apt/sources.list.d/mongodb-org-${MONGO_VERSION}.list" \
            KEYRING_FILE="/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg"
    else
        docker_container_name="$DOCKER_CONTAINER_NAME"
        docker_network_name="$DOCKER_NETWORK_NAME"

        _render_template_file "$TEMP_CONFIG_DIR/cleanup_docker.sh.template" "$cleanup_script" \
            CONFIG_DIR \
            COMPOSE_FILE="$DOCKER_COMPOSE_FILE" \
            CONTAINER_NAME="$DOCKER_CONTAINER_NAME"
    fi
    sudo chmod +x "$cleanup_script"

    _render_template_file "$TEMP_CONFIG_DIR/mongodb_install.conf.template" "$CONFIG_FILE" \
        INSTALL_METHOD BIND_IP PORT \
        CONFIGURED_AT="$(date '+%Y-%m-%d %H:%M:%S')" \
        CLEANUP_COMMAND="bash $cleanup_script" \
        DOCKER_CONTAINER_NAME="$docker_container_name" \
        DOCKER_NETWORK_NAME="$docker_network_name" 
        

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

    cleanup_command="sudo bash $CONFIG_DIR/cleanup.sh"

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
_download_github_path "$CONFIGS_REPO_URL" "mongodb" "$TEMP_CONFIG_DIR"

install
write_config
add_ssh_quick_info

print_step "MongoDB setup completed successfully"
