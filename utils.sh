#!/usr/bin/env bash


print_step() {
    echo
    echo "=================================================="
    echo " $1"
    echo "=================================================="
}

print_info() {
    echo "[INFO] $1"
}

print_warning() {
    echo "[WARNING] $1"
}

print_error() {
    echo -e "\e[31m[ERROR] $1\e[0m"
}

_prompt_required() {
    local prompt_text="$1"
    local out_var_name="$2"
    local regex_pattern="${3:-}"
    local secret_flag="${4:-}"

    local input=""
    local -a read_opts=()
    [ "$secret_flag" = "--secret" ] && read_opts+=(-s)

    while true; do
        read "${read_opts[@]}" -p "$prompt_text" input </dev/tty
        [ "$secret_flag" = "--secret" ] && echo ""

        if [ -z "$input" ]; then
            print_error "This value cannot be empty!"
            continue
        fi

        if [ -n "$regex_pattern" ] && [[ ! "$input" =~ $regex_pattern ]]; then
            print_error "Invalid value!"
            continue
        fi

        break
    done

    printf -v "$out_var_name" '%s' "$input"
}

_confirm() {
    local prompt_text="$1"

    # عند تمرير -y للسكربت يتم تفعيل ASSUME_YES فتتم الموافقة على كل التحققات تلقائياً
    if [ "${ASSUME_YES:-no}" = "yes" ]; then
        echo "${prompt_text}y (auto-approved by -y)"
        return 0
    fi

    local response=""

    read -p "$prompt_text" response </dev/tty
    response=$(echo "$response" | tr '[:upper:]' '[:lower:]')
    [[ "$response" =~ ^(y|yes)$ ]]
}

_check_variable_required() {
    local var_name="$1"
    local var_value="$2"
    local regex_pattern="$3"

    if [ -z "$var_value" ]; then
        print_error "Validation Failed: Required variable '$var_name' is missing or empty!"
        exit 1
    fi

    if [ -n "$regex_pattern" ] && [[ ! "$var_value" =~ $regex_pattern ]]; then
        print_error "Validation Failed: Variable '$var_name' ('$var_value') does not match the required format!"
        exit 1
    fi
}

_ask_to_save_permanently() {
    local var_name="$1"
    local var_value="$2"

    if ! _confirm "$(echo -e "\e[33m[?]\e[0m Do you want to save $var_name permanently to the server? (y/n): ")"; then
        print_info "$var_name will be temporary for this script run only."
        return 0
    fi

    local shell_profile=""
    
    if [ -f "/root/.bashrc" ]; then
        shell_profile="/root/.bashrc"
    elif [ -f "/root/.profile" ]; then
        shell_profile="/root/.profile"
    fi

    if [ -z "$shell_profile" ]; then
        print_warning "Could not find .bashrc or .profile to save $var_name permanently."
        return 0
    fi

    sed -i "/export $var_name=/d" "$shell_profile"
    echo "export $var_name=\"$var_value\"" >> "$shell_profile"
    print_info "Saved $var_name permanently to $shell_profile"
}

_prompt_paste_file() {
    local prompt_text="$1"
    local target_file="$2"

    echo
    echo "================================================================="
    echo " $prompt_text"
    echo "================================================================="
    echo "File to edit:"
    echo " $target_file"
    echo

    read -p "Press ENTER to open the file..." </dev/tty
    nano "$target_file" </dev/tty
}

_install_dependencies() {
    if [ "$#" -eq 0 ]; then
        print_error "No dependencies specified to install."
        return 1
    fi

    print_step "Update system and install dependencies"
    sudo apt-get update 
    sudo apt-get install -y "$@"
}

_install_docker() {
    print_step "Install Docker"

    if command -v docker >/dev/null 2>&1; then
        print_info "Docker is already installed."
    else
        print_info "Installing Docker from official repository..."

        sudo install -m 0755 -d /etc/apt/keyrings

        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes

        sudo chmod a+r /etc/apt/keyrings/docker.gpg

        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

        _install_dependencies docker-ce \
            docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
    fi

    print_info "Checking Docker service status..."

    if ! sudo systemctl is-active --quiet docker; then
        print_warning "Docker service is not running. Starting it..."
        sudo systemctl start docker
    fi

    if ! sudo systemctl is-enabled --quiet docker; then
        print_warning "Docker service is not enabled. Enabling it..."
        sudo systemctl enable docker >/dev/null 2>&1
    else
        print_info "Docker service already enabled."
    fi

    print_info "Docker service is running."

    if ! groups "$USER" | grep -q docker; then
        print_info "Adding user to docker group..."
        sudo usermod -aG docker "$USER"
    else
        print_info "User already in docker group."
    fi

    print_info "Docker setup completed."
}

_clone_or_update_project() {
    local repo_url="$1"
    local project_dir="$2"
    local branch="${3:-main}"

    print_step "Clone or update project"

    if [ -d "$project_dir/.git" ]; then
        print_info "Project already exists. Pulling latest changes..."
        cd "$project_dir"
        git fetch --all
        git reset --hard "origin/$branch"
        return
    fi

    print_info "Cloning project..."
    git clone "$repo_url" "$project_dir"
}

_render_template_file() {
    local template_file="$1"
    local output_file="$2"
    shift 2
    local -a template_vars=("$@")

    local vars_list=""
    local -a env_assignments=()
    local arg var_name

    for arg in "${template_vars[@]}"; do
        if [[ "$arg" == *=* ]]; then
            var_name="${arg%%=*}"
            env_assignments+=("$arg")
        else
            var_name="$arg"
        fi
        vars_list+="\${$var_name} "
    done

    env "${env_assignments[@]}" envsubst "$vars_list" \
        < "$template_file" \
        | sudo tee "$output_file" > /dev/null
}

_create_systemd_service() {
    local service_name="$1"
    local template_file="$2"
    shift 2
    local -a template_vars=("$@")

    print_step "Creating Systemd Service: ${service_name}"

    local service_file="/etc/systemd/system/${service_name}.service"

    if systemctl list-unit-files | grep -q "${service_name}.service" || [ -f "$service_file" ]; then
        print_info "Existing service '${service_name}' detected. Stopping and removing it first..."

        sudo systemctl stop "${service_name}.service" >/dev/null 2>&1 || true
        sudo systemctl disable "${service_name}.service" >/dev/null 2>&1 || true
        sudo rm -f "$service_file"
        sudo systemctl daemon-reload
        print_info "Old service successfully cleaned up."
    fi

    print_info "Configuring systemd service file at ${service_file}..."

    _render_template_file "$template_file" "$service_file" "${template_vars[@]}"

    sudo systemctl daemon-reload
    sudo systemctl enable "${service_name}.service" >/dev/null 2>&1
    print_info "✅ Systemd service ${service_name}.service successfully created and enabled."
    print_info "for show logs run   sudo journalctl -u $service_name -e"
}

_ensure_git_compatible() {
    local min_version="${1:-2.25.0}"
    local current_version

    if ! command -v git >/dev/null 2>&1; then
        print_warning "Git is not installed. Installing it..."
        _install_dependencies git
    fi

    current_version=$(git --version | grep -oP '\d+\.\d+\.\d+')

    if [ "$(printf '%s\n%s\n' "$min_version" "$current_version" | sort -V | head -n1)" != "$min_version" ]; then
        print_warning "Git $current_version is too old (requires >= $min_version). Updating..."
        _install_dependencies --only-upgrade git
        current_version=$(git --version | grep -oP '\d+\.\d+\.\d+')
    fi

    if [ "$(printf '%s\n%s\n' "$min_version" "$current_version" | sort -V | head -n1)" != "$min_version" ]; then
        print_error "Git $current_version still does not meet the minimum required version ($min_version). Please update Git manually."
        return 1
    fi

    print_info "Git $current_version is compatible (minimum required: $min_version)."
}

_detect_ssh_port() {
    local detected_port=""

    detected_port=$(sudo ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]; exit}')

    if [ -z "$detected_port" ] && [ -f /etc/ssh/sshd_config ]; then
        detected_port=$(grep -iE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | head -n1)
    fi

    echo "${detected_port:-22}"
}

_download_github_path() {
    local repo_url="$1"
    local repo_path="$2"
    local destination="$3"
    local branch="${4:-main}"
    local min_git_version="${5:-2.25.0}"

    if [ -z "$repo_url" ] || [ -z "$repo_path" ] || [ -z "$destination" ]; then
        print_error "Usage: _download_github_path <repo_url> <path_in_repo> <destination> [branch] [min_git_version]"
        return 1
    fi

    _ensure_git_compatible "$min_git_version" || return 1

    print_step "Download '$repo_path' from $repo_url"

    local tmp_dir
    tmp_dir=$(mktemp -d)

    print_info "Fetching repository metadata (sparse checkout)..."
    if ! git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$branch" "$repo_url" "$tmp_dir"; then
        print_error "Failed to clone repository '$repo_url' (branch: $branch)."
        rm -rf "$tmp_dir"
        return 1
    fi

    (
        cd "$tmp_dir" || exit 1
        git sparse-checkout set "$repo_path"
    )

    local source_path="$tmp_dir/$repo_path"

    if [ ! -e "$source_path" ]; then
        print_error "Path '$repo_path' was not found in the repository."
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$destination"

    if [ -d "$source_path" ]; then
        mkdir -p "$destination"
        cp -r "$source_path/." "$destination/"
    else
        mkdir -p "$(dirname "$destination")"
        cp "$source_path" "$destination"
    fi

    rm -rf "$tmp_dir"

    print_info "Downloaded '$repo_path' to '$destination'."
}






