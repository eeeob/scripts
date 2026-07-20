#!/bin/bash

# ==============================================================================
# Nginx Install Script (Ubuntu 20.04 / 22.04 / 24.04)
# التثبيت من المصادر الرسمية فقط: nginx.org أو صورة nginx الرسمية عبر Docker Compose
# الاعدادات الأساسية تعمل خلف Cloudflare (Full strict) مع locations في ملفات منفصلة
# قابل لإعادة التشغيل أكثر من مرة بدون مشاكل، وآمن للتشغيل المنفرد عبر:
#   bash <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/install_nginx.sh)
# تمرير -y يوافق تلقائياً على جميع التحققات، و -n يرفضها تلقائياً
# تمرير -d example.com يحدد الدومين بدون سؤال تفاعلي
# ==============================================================================

set -e

# جلب الدوال المشتركة من utils.sh
sudo apt-get update -y && sudo apt-get install -y curl && source <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/utils.sh)


#shared
CONFIGS_REPO_URL="https://github.com/eeeob/configs.git"

TEMP_CONFIG_DIR="/root/.temp_configs/nginx"
CONFIG_DIR="/root/.configs/nginx"

CONFIG_FILE="$CONFIG_DIR/nginx_install.conf"

NGINX_CONF_DIR="/etc/nginx/conf.d"
LOCATIONS_DIR="/etc/nginx/locations"
CERTS_DIR="/etc/nginx/certs"
CERT_FILE="$CERTS_DIR/cloudflare-origin.pem"
KEY_FILE="$CERTS_DIR/cloudflare-origin.key"

SERVER_NAME=""
INSTALL_METHOD=""
RESTART_COMMAND=""
NGINX_FULL_VERSION="unknown"

#native
UBUNTU_CODENAME=$(_get_ubuntu_codename "20.04 22.04 24.04")

#docker
DOCKER_COMPOSE_FILE="$CONFIG_DIR/docker-compose.yml"
DOCKER_CONTAINER_NAME="nginx"
DOCKER_NETWORK_NAME="main_network"


# التعرف على الأعلام المشتركة (-y موافقة / -n رفض تلقائي) مع إعادة تعيين باقي args للسكربت
eval "$(_parse_common_flags --reset "$@")"

# العلم الخاص بالسكربت (-d للدومين) عبر دالة مساعدة من utils
_parse_flag_value "d" SERVER_NAME "$@"

# --- كشف تثبيت سابق موجود فعلياً لكن غير موثق في ملف config (حالة مخفية) ---
# عند وجود تثبيت شغّال وموافقة المستخدم على المتابعة، تتم تصفيته بالكامل بالطرق الرسمية
detect_previous_installation() {
    local found_native="no"
    local found_docker="no"
    local found=""

    if _package_installed nginx || _service_exists nginx; then
        found_native="yes"
        found="native package 'nginx'"
    fi

    if _container_exists "$DOCKER_CONTAINER_NAME"; then
        found_docker="yes"
        found="${found:+$found + }Docker container '$DOCKER_CONTAINER_NAME'"
    fi

    [ -z "$found" ] && return 0

    print_warning "Existing Nginx installation detected on this server: $found."

    if ! _confirm "Remove the existing installation completely (official cleanup) and reinstall from scratch? (y/n): "; then
        print_info "Aborted by user. Nothing was changed."
        exit 0
    fi

    print_step "Removing the existing Nginx installation (official cleanup)"

    # تصفية التثبيت المباشر بالطرق الرسمية (إيقاف الخدمة، إزالة الحزم والمصادر والاعدادات)
    # ملاحظة: يتم الإبقاء على مجلد الشهادات لتجنب فقدان شهادة Cloudflare Origin
    if [ "$found_native" = "yes" ]; then
        print_info "Cleaning up the native Nginx installation..."
        _destroy_service "nginx"
        sudo apt-get purge -y nginx 2>/dev/null || true
        sudo apt-get autoremove -y 2>/dev/null || true
        sudo rm -f /etc/apt/sources.list.d/nginx.list
        sudo rm -f /usr/share/keyrings/nginx-archive-keyring.gpg
        sudo rm -f "$NGINX_CONF_DIR/default.conf" "$NGINX_CONF_DIR/cloudflare.conf"
        sudo rm -rf "$LOCATIONS_DIR"
    fi

    # تصفية تثبيت Docker (حذف الحاوية مع صورتها وشبكاتها الخاصة)
    if [ "$found_docker" = "yes" ]; then
        print_info "Cleaning up the Docker Nginx installation..."
        _remove_container "$DOCKER_CONTAINER_NAME"
    fi

    print_info "Existing Nginx installation removed. Continuing with a fresh setup..."
}

# --- التأكد من تحديد الدومين (من العلم -d أو تفاعلياً) ---
ensure_domain() {
    print_step "Domain configuration"

    if [ -n "$SERVER_NAME" ]; then
        _check_variable_required "SERVER_NAME" "$SERVER_NAME" '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    else
        _prompt_required "Enter your domain (e.g. example.com): " SERVER_NAME '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    fi

    print_info "Domain: $SERVER_NAME"
}

# --- التحقق من أن البورتين 80 و 443 غير مستخدمين من خدمات أخرى ---
check_ports() {
    print_step "Checking ports 80 and 443"

    local port holder blocked=""
    for port in 80 443; do
        holder=$(sudo ss -tlnpH "( sport = :$port )" 2>/dev/null | grep -v nginx || true)
        if [ -n "$holder" ]; then
            print_warning "Port $port is already in use by another service:"
            echo "$holder"
            blocked="yes"
        fi
    done

    if [ -z "$blocked" ]; then
        print_info "Ports 80 and 443 are free (or already used by Nginx itself)."
        return 0
    fi

    echo
    if ! _confirm "Continue anyway? Nginx may fail to start. (y/n): "; then
        print_info "Aborted by user. Nothing was changed."
        exit 0
    fi
}

# --- طلب شهادة Cloudflare Origin أو توليد شهادة مؤقتة موقّعة ذاتياً ---
ensure_certificates() {
    print_step "Cloudflare Origin certificates"

    if sudo test -f "$CERT_FILE" && sudo test -f "$KEY_FILE"; then
        print_info "Existing certificates found in $CERTS_DIR. Keeping them."
        return 0
    fi

    sudo mkdir -p "$CERTS_DIR"

    if _confirm "Paste your Cloudflare Origin certificate and key now? (y/n): "; then
        sudo touch "$CERT_FILE" "$KEY_FILE"
        sudo chmod 600 "$KEY_FILE"
        _prompt_paste_file "Paste the Cloudflare Origin CERTIFICATE (PEM) then save and exit" "$CERT_FILE"
        _prompt_paste_file "Paste the Cloudflare Origin PRIVATE KEY then save and exit" "$KEY_FILE"

        if ! sudo test -s "$CERT_FILE" || ! sudo test -s "$KEY_FILE"; then
            print_error "Certificate or key file is still empty. Nginx will fail to start on 443."
            exit 1
        fi
        print_info "Cloudflare Origin certificate saved."
    else
        # شهادة self-signed مؤقتة حتى يعمل nginx، تُستبدل لاحقاً بشهادة Cloudflare الحقيقية
        print_warning "Generating a TEMPORARY self-signed certificate so Nginx can start..."
        _ensure_packages openssl
        sudo openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
            -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SERVER_NAME}" >/dev/null 2>&1
        sudo chmod 600 "$KEY_FILE"
        print_warning "Replace it later with your real Cloudflare Origin certificate:"
        print_warning "  $CERT_FILE"
        print_warning "  $KEY_FILE"
    fi
}

# --- نشر ملفات الاعدادات (مشتركة بين الوضعين native و docker) ---
deploy_nginx_config() {
    print_step "Deploying Nginx configuration"

    sudo mkdir -p "$NGINX_CONF_DIR" "$LOCATIONS_DIR" "$CERTS_DIR"

    # الاعدادات الأساسية (خلف Cloudflare) مع استبدال الدومين
    _render_template_file "$TEMP_CONFIG_DIR/conf/default.conf.template" "$NGINX_CONF_DIR/default.conf" \
        SERVER_NAME="$SERVER_NAME"

    # تعريف $is_cloudflare (نطاقات Cloudflare الرسمية)
    sudo cp "$TEMP_CONFIG_DIR/conf/cloudflare.conf" "$NGINX_CONF_DIR/cloudflare.conf"

    # مثال جاهز لملف location منفصل (لا يُحمّل لأن امتداده .example وليس .conf)
    sudo cp "$TEMP_CONFIG_DIR/locations-examples/api_proxy.conf.example" "$LOCATIONS_DIR/"

    print_info "Base config deployed to $NGINX_CONF_DIR/default.conf"
    print_info "Put your per-service location blocks in $LOCATIONS_DIR/*.conf"
}

# --- التثبيت المباشر من المستودع الرسمي (nginx.org) ---
install_native() {
    if _package_installed nginx || _service_exists nginx; then
        print_error "A native Nginx installation still exists. Aborting to avoid a broken setup."
        exit 1
    fi

    print_step "Installing Nginx (native, official nginx.org repo)"

    _ensure_packages gnupg ca-certificates

    curl -fsSL https://nginx.org/keys/nginx_signing.key | \
        sudo gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg

    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu ${UBUNTU_CODENAME} nginx" | \
        sudo tee /etc/apt/sources.list.d/nginx.list >/dev/null

    _install_dependencies nginx

    deploy_nginx_config

    print_info "Testing Nginx configuration..."
    sudo nginx -t

    sudo systemctl enable nginx >/dev/null 2>&1
    sudo systemctl restart nginx
    _wait_for_service "nginx" 10

    NGINX_FULL_VERSION=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || echo "unknown")
    RESTART_COMMAND="sudo systemctl restart nginx"
    INSTALL_METHOD="native"

    print_info "Nginx is running (native) on ports 80 and 443."
}

# --- التثبيت داخل Docker عبر compose من الصورة الرسمية ---
install_in_docker() {
    if _container_exists "$DOCKER_CONTAINER_NAME"; then
        print_error "A Docker container named '$DOCKER_CONTAINER_NAME' still exists. Aborting to avoid a conflict."
        exit 1
    fi

    print_step "Installing Nginx (Docker Compose, official image)"

    _install_docker
    _create_docker_network

    deploy_nginx_config

    # ملف compose الحقيقي يُحفظ في /root/.configs/nginx ويبقى للاستخدام لاحقاً
    _render_template_file "$TEMP_CONFIG_DIR/docker-compose.yml.template" "$DOCKER_COMPOSE_FILE" \
        CONTAINER_NAME="$DOCKER_CONTAINER_NAME" \
        NETWORK_NAME="$DOCKER_NETWORK_NAME"
    print_info "Compose file saved to $DOCKER_COMPOSE_FILE"

    print_info "Testing Nginx configuration inside a temporary container..."
    sudo docker run --rm \
        -v "$NGINX_CONF_DIR":/etc/nginx/conf.d:ro \
        -v "$LOCATIONS_DIR":/etc/nginx/locations:ro \
        -v "$CERTS_DIR":/etc/nginx/certs:ro \
        nginx:stable nginx -t

    sudo docker compose -f "$DOCKER_COMPOSE_FILE" up -d
    _wait_for_container "$DOCKER_CONTAINER_NAME" 10

    NGINX_FULL_VERSION=$(sudo docker exec "$DOCKER_CONTAINER_NAME" nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || echo "unknown")
    RESTART_COMMAND="sudo docker compose -f $DOCKER_COMPOSE_FILE restart"
    INSTALL_METHOD="docker"

    print_info "Nginx container started on ports 80 and 443."
}

# --- كتابة ملف config يوثق تفاصيل التثبيت مع توليد سكربت التصفية ---
write_config() {
    print_step "Writing config file"

    local cleanup_script="$CONFIG_DIR/cleanup.sh"

    local docker_container_name=""
    local docker_network_name=""

    # توليد سكربت التصفية الحقيقي المطابق لطريقة التثبيت الحالية
    if [ "$INSTALL_METHOD" = "native" ]; then
        _render_template_file "$TEMP_CONFIG_DIR/cleanup_native.sh.template" "$cleanup_script" \
            LOCATIONS_DIR="$LOCATIONS_DIR" \
            CERTS_DIR="$CERTS_DIR"
    else
        docker_container_name="$DOCKER_CONTAINER_NAME"
        docker_network_name="$DOCKER_NETWORK_NAME"

        _render_template_file "$TEMP_CONFIG_DIR/cleanup_docker.sh.template" "$cleanup_script" \
            COMPOSE_FILE="$DOCKER_COMPOSE_FILE" \
            CONTAINER_NAME="$DOCKER_CONTAINER_NAME" \
            LOCATIONS_DIR="$LOCATIONS_DIR" \
            CERTS_DIR="$CERTS_DIR"
    fi
    sudo chmod +x "$cleanup_script"

    _render_template_file "$TEMP_CONFIG_DIR/nginx_install.conf.template" "$CONFIG_FILE" \
        CONFIGURED_AT="$(date '+%Y-%m-%d %H:%M:%S')" \
        INSTALL_METHOD="$INSTALL_METHOD" \
        NGINX_VERSION="$NGINX_FULL_VERSION" \
        SERVER_NAME="$SERVER_NAME" \
        RESTART_COMMAND="$RESTART_COMMAND" \
        CLEANUP_COMMAND="bash $cleanup_script" \
        DOCKER_CONTAINER_NAME="$docker_container_name" \
        DOCKER_NETWORK_NAME="$docker_network_name"

    print_info "Config saved to $CONFIG_FILE"
}

# --- إضافة معلومات استخدام سريعة لشاشة الدخول عبر SSH (من template في configs) ---
add_ssh_quick_info() {
    print_step "Adding quick usage info to the SSH login screen"

    local test_command="sudo nginx -t"
    [ "$INSTALL_METHOD" = "docker" ] && test_command="sudo docker exec $DOCKER_CONTAINER_NAME nginx -t"

    _add_motd_info "nginx" "$TEMP_CONFIG_DIR/motd-info.sh.tmpl" \
        SERVER_NAME="$SERVER_NAME" \
        RESTART_COMMAND="$RESTART_COMMAND" \
        TEST_COMMAND="$test_command" \
        LOCATIONS_DIR="$LOCATIONS_DIR" \
        CERT_FILE="$CERT_FILE" \
        CONFIG_FILE="$CONFIG_FILE"

    print_info "Quick usage info will appear on the next SSH login."
}

trap 'rm -rf "$TEMP_CONFIG_DIR"' EXIT

_handle_existing_config_file "$CONFIG_FILE"
detect_previous_installation
_download_github_path "$CONFIGS_REPO_URL" "nginx" "$TEMP_CONFIG_DIR"

ensure_domain
check_ports
ensure_certificates

print_step "Choose installation method"
print_info "Native = official apt repo (nginx.org). Docker = official 'nginx' image via compose."

if _confirm "Install Nginx inside Docker instead of the native installation? (y/n): "; then
    install_in_docker
else
    install_native
fi

write_config
add_ssh_quick_info

print_step "Nginx setup completed successfully"
print_info "Restart command: $RESTART_COMMAND"
