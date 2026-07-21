#!/bin/bash

# ==============================================================================
# Scripts Launcher - تشغيل عدة سكربتات معاً بالترتيب الذي يختاره المستخدم
# يجلب قائمة السكربتات مباشرة من GitHub (لا حاجة لتحديثها يدوياً عند إضافة سكربت جديد)
# يستثني utils.sh وأي سكربت اسمه يبدأ بـ utils، وهذا السكربت نفسه
# كل سكربت يُشغَّل مباشرة من GitHub عبر bash <(curl -fsSL ...)
# آمن للتشغيل المنفرد عبر:
#   bash <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/run_scripts.sh)
# أي أعلام تُمرَّر لهذا السكربت (مثل -y/-n) تُمرَّر بدورها لكل سكربت يتم تشغيله
# ==============================================================================

set -e

sudo apt-get update -y && sudo apt-get install -y curl && source <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/utils.sh)



SCRIPTS_REPO_OWNER="eeeob"
SCRIPTS_REPO_NAME="scripts"
SCRIPTS_REPO_BRANCH="main"

SELF_SCRIPT_NAME="run_scripts.sh"

API_URL="https://api.github.com/repos/${SCRIPTS_REPO_OWNER}/${SCRIPTS_REPO_NAME}/contents/?ref=${SCRIPTS_REPO_BRANCH}&per_page=100"
RAW_BASE="https://raw.githubusercontent.com/${SCRIPTS_REPO_OWNER}/${SCRIPTS_REPO_NAME}/${SCRIPTS_REPO_BRANCH}"

AVAILABLE_SCRIPTS=()
SELECTED_SCRIPTS=()


_parse_common_flags "$@"


fetch_available_scripts() {
    print_step "Fetching available scripts from GitHub"

    local raw_names
    raw_names=$(curl -fsSL "$API_URL" | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p')

    if [ -z "$raw_names" ]; then
        print_error "Failed to fetch the scripts list from GitHub."
        exit 1
    fi

    local name
    while IFS= read -r name; do
        [[ "$name" == *.sh ]] || continue
        [[ "$name" == utils* ]] && continue
        [ "$name" = "$SELF_SCRIPT_NAME" ] && continue
        AVAILABLE_SCRIPTS+=("$name")
    done <<< "$raw_names"

    if [ ${#AVAILABLE_SCRIPTS[@]} -eq 0 ]; then
        print_error "No runnable scripts were found in the repository."
        exit 1
    fi
}

print_scripts_menu() {
    print_step "Available scripts"

    local i
    for i in "${!AVAILABLE_SCRIPTS[@]}"; do
        printf "  %2d) %s\n" "$((i + 1))" "${AVAILABLE_SCRIPTS[$i]}"
    done
    echo
}


prompt_selection() {
    local input token valid

    while true; do
        read -p "Enter script numbers to run, in the desired order (space-separated, e.g. 2 1 3): " input </dev/tty

        if [ -z "$input" ]; then
            print_error "You must select at least one script."
            continue
        fi

        SELECTED_SCRIPTS=()
        valid="yes"

        for token in $input; do
            if ! [[ "$token" =~ ^[0-9]+$ ]] || [ "$token" -lt 1 ] || [ "$token" -gt "${#AVAILABLE_SCRIPTS[@]}" ]; then
                print_error "Invalid selection: '$token'"
                valid="no"
                break
            fi
            SELECTED_SCRIPTS+=("${AVAILABLE_SCRIPTS[$((token - 1))]}")
        done

        [ "$valid" = "yes" ] && break
    done
}


run_selected_scripts() {
    print_step "Execution plan"

    local i
    for i in "${!SELECTED_SCRIPTS[@]}"; do
        printf "  %d) %s\n" "$((i + 1))" "${SELECTED_SCRIPTS[$i]}"
    done
    echo

    if ! _confirm "Run these scripts now in this order? (y/n): "; then
        print_info "Aborted by user. Nothing was run."
        exit 0
    fi

    local name
    for name in "${SELECTED_SCRIPTS[@]}"; do
        print_step "Running: $name"

        if bash <(curl -fsSL "$RAW_BASE/$name") "$@"; then
            print_info "'$name' finished successfully."
        else
            print_warning "'$name' exited with an error."
            if ! _confirm "Continue with the remaining scripts anyway? (y/n): "; then
                print_info "Stopped by user."
                exit 1
            fi
        fi
    done

    print_step "All selected scripts finished"
}


fetch_available_scripts
print_scripts_menu
prompt_selection
run_selected_scripts "$@"
