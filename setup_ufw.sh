#!/usr/bin/env bash

# ==============================================================================
# UFW Firewall Setup Script
# يقوم بتفعيل UFW مع إبقاء SSH مفتوحاً، مع فحص الخدمات المتأثرة والقواعد القديمة
# آمن للتشغيل المنفرد عبر:
#   bash <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/setup_ufw.sh)
# ==============================================================================

set -e

# جلب الدوال المشتركة من utils.sh
sudo apt-get update -y && sudo apt-get install -y curl && source <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/utils.sh)

CONFIG_DIR="/root/.configs"
CONFIG_FILE="$CONFIG_DIR/ufw_setup.conf"
SSH_PORT="22"
OLD_RULES_RESET="no"

# --- التحقق من وجود ملف config قديم من تشغيل سابق ---
check_existing_config() {
    sudo test -f "$CONFIG_FILE" || return 0

    print_step "Existing configuration detected"
    print_warning "A previous UFW setup config was found at: $CONFIG_FILE"
    echo
    sudo cat "$CONFIG_FILE"
    echo

    if _confirm "Delete the old config and redo the setup from scratch? (y/n): "; then
        sudo rm -f "$CONFIG_FILE"
        print_info "Old config deleted. Continuing with a fresh setup..."
    else
        print_info "Keeping the existing setup. Exiting without changes."
        exit 0
    fi
}

# --- اكتشاف بورت SSH الفعلي بدلاً من افتراض 22 ---
detect_ssh_port() {
    local detected_port=""

    detected_port=$(sudo ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]; exit}')

    if [ -z "$detected_port" ] && [ -f /etc/ssh/sshd_config ]; then
        detected_port=$(grep -iE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | head -n1)
    fi

    SSH_PORT="${detected_port:-22}"
    print_info "Detected SSH port: $SSH_PORT"
}

# --- التحقق من وجود قواعد UFW قديمة وتخيير المستخدم بإلغائها ---
check_old_rules() {
    print_step "Checking existing UFW rules"

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

# --- فحص الخدمات المستمعة التي ستتأثر بتفعيل الجدار الناري ---
check_affected_services() {
    print_step "Checking services that may be affected"

    local affected
    affected=$(sudo ss -tulnpH 2>/dev/null | awk -v ssh="$SSH_PORT" '
        {
            n = split($5, a, ":");
            port = a[n];
            proc = "unknown";
            if (match($0, /users:\(\("[^"]+"/)) {
                proc = substr($0, RSTART + 9, RLENGTH - 9);
            }
            # تجاهل الخدمات المستمعة على loopback فقط لأنها لا تتأثر بالجدار الناري
            if ($5 ~ /^127\./ || $5 ~ /^\[::1\]/) next;
            if (port == ssh) next;
            key = $1 " " port " " proc;
            if (!(key in seen)) {
                seen[key] = 1;
                printf "  - %s port %s (%s)\n", $1, port, proc;
            }
        }
    ')

    if [ -z "$affected" ]; then
        print_info "No public listening services found other than SSH. Safe to enable."
        return 0
    fi

    print_warning "The following listening services will be BLOCKED for incoming connections after enabling UFW:"
    echo
    echo "$affected"
    echo
    print_info "SSH (port $SSH_PORT/tcp) will remain allowed."

    if ! _confirm "Do you want to continue and enable UFW anyway? (y/n): "; then
        print_info "Aborted by user. No changes were made to the firewall."
        exit 0
    fi
}

# --- تفعيل UFW مع السماح لـ SSH ---
enable_ufw() {
    print_step "Enabling UFW"

    sudo ufw default deny incoming >/dev/null
    sudo ufw default allow outgoing >/dev/null
    sudo ufw allow "$SSH_PORT/tcp" >/dev/null
    print_info "Allowed SSH on port $SSH_PORT/tcp."

    sudo ufw --force enable
    print_info "UFW is now active."
    echo
    sudo ufw status verbose
}

# --- كتابة ملف config يوثق الإعدادات المطبقة ---
write_config() {
    print_step "Writing config file"

    sudo mkdir -p "$CONFIG_DIR"

    sudo tee "$CONFIG_FILE" >/dev/null <<EOF
CONFIGURED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
UFW_ENABLED="yes"
SSH_PORT="$SSH_PORT"
DEFAULT_INCOMING="deny"
DEFAULT_OUTGOING="allow"
OLD_RULES_RESET="$OLD_RULES_RESET"
EOF

    print_info "Config saved to $CONFIG_FILE"
}

check_existing_config
_install_dependencies ufw
detect_ssh_port
check_old_rules
check_affected_services
enable_ufw
write_config

print_step "UFW setup completed successfully"
