#!/bin/bash

# ==============================================================================
# UFW Firewall Setup Script (Ubuntu 20.04 / 22.04 / 24.04)
# يقوم بتفعيل UFW مع إبقاء SSH مفتوحاً، مع فحص الخدمات المتأثرة والقواعد القديمة
# قابل لإعادة التشغيل أكثر من مرة بدون مشاكل، وآمن للتشغيل المنفرد عبر:
#   bash <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/setup_ufw.sh)
# تمرير -y يوافق تلقائياً على جميع التحققات، و -n يرفضها تلقائياً
# ==============================================================================

set -e

# جلب الدوال المشتركة من utils.sh
sudo apt-get update -y && sudo apt-get install -y curl && source <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/utils.sh)

TEMP_CONFIG_DIR="/root/.temp_configs/ufw"
CONFIG_DIR="/root/.configs/ufw"

CONFIG_FILE="${CONFIG_DIR}/ufw_setup.conf"

CONFIGS_REPO_URL="https://github.com/eeeob/configs.git"
OLD_RULES_RESET="no"

SSH_PORT=$(_detect_ssh_port)

# التعرف على الأعلام المشتركة (-y موافقة / -n رفض تلقائي) مع إعادة تعيين باقي args للسكربت
eval "$(_parse_common_flags --reset "$@")"

print_info "Detected SSH port: $SSH_PORT"

# --- التحقق من وجود قواعد UFW قديمة وتخيير المستخدم بإلغائها ---
check_old_rules() {
    print_step "Checking existing UFW rules"

    _package_installed ufw || return 0

    local old_rules
    old_rules=$(sudo ufw status numbered | grep -E '^\[' || true)

    if [ -z "$old_rules" ]; then
        print_info "No existing UFW rules found."
        return 0
    fi

    print_warning "Existing UFW rules were found:"
    echo
    sudo ufw status numbered
    echo

    if _confirm "Reset (delete) these old rules and continue? (y/n): "; then
        print_info "Resetting UFW to defaults..."
        sudo ufw --force reset >/dev/null
        OLD_RULES_RESET="yes"
        print_info "Old rules removed."
    else
        print_info "Keeping existing rules and continuing."
    fi
}

check_affected_services() {
    print_step "Checking services that may be affected"

    local affected
    affected=$(sudo ss -tulnpH 2>/dev/null | awk -v ssh="$SSH_PORT" -f "$TEMP_CONFIG_DIR/affected_services.awk")

    if [ -z "$affected" ]; then
        print_info "No public listening services found other than SSH. Safe to enable."
        return 0
    fi

    print_warning "The following listening services will be BLOCKED for incoming connections after enabling UFW:"
    echo
    echo "$affected"
    echo
    print_info "SSH (port $SSH_PORT) will remain allowed via the OpenSSH profile."

    if ! _confirm "Do you want to continue and enable UFW anyway? (y/n): "; then
        print_info "Aborted by user. No changes were made to the firewall."
        exit 0
    fi
}

enable_ufw() {
    print_step "Enabling UFW"

    _ensure_packages ufw

    sudo ufw default deny incoming >/dev/null
    sudo ufw default allow outgoing >/dev/null

    sudo ufw allow OpenSSH >/dev/null
    print_info "Allowed SSH via the OpenSSH application profile."

    # لو كان SSH على بورت مخصص (غير 22) فبروفايل OpenSSH لا يغطيه، فنفتح البورت الفعلي لتجنب قفل الوصول
    if [ "$SSH_PORT" != "22" ]; then
        sudo ufw allow "$SSH_PORT/tcp" >/dev/null
        print_info "Also allowed the detected custom SSH port: $SSH_PORT/tcp."
    fi

    sudo ufw --force enable
    print_info "UFW is now active."
    echo
    sudo ufw status verbose
}

# --- كتابة ملف config يوثق الإعدادات المطبقة ---
write_config() {
    print_step "Writing config file"

    _render_template_file "$TEMP_CONFIG_DIR/ufw_setup.conf.template" "$CONFIG_FILE" \
        SSH_PORT OLD_RULES_RESET \
        CONFIGURED_AT="$(date '+%Y-%m-%d %H:%M:%S')" \
        CLEANUP_COMMAND="ufw --force reset"

    print_info "Config saved to $CONFIG_FILE"
}

# --- إضافة معلومات استخدام سريعة لشاشة الدخول عبر SSH (من template في configs) ---
add_ssh_quick_info() {
    print_step "Adding quick usage info to the SSH login screen"

    _add_motd_info "ufw" "$TEMP_CONFIG_DIR/motd-info.sh.tmpl" CONFIG_FILE="$CONFIG_FILE"

    print_info "Quick usage info will appear on the next SSH login."
}

trap 'rm -rf "$TEMP_CONFIG_DIR"' EXIT

_handle_existing_config_file "$CONFIG_FILE"
_download_github_path "$CONFIGS_REPO_URL" "ufw" "$TEMP_CONFIG_DIR"

check_old_rules
check_affected_services
enable_ufw
write_config
add_ssh_quick_info

print_step "UFW setup completed successfully"
