#!/bin/bash

set -e

USERNAME="${USERNAME:-eeeob}"
REPO="${REPO:-}"
SCRIPT_PATH="${SCRIPT_PATH:-}"


if [ -z "$USERNAME" ]; then
    read -p "GitHub Username: " USERNAME
fi

if [ -z "$REPO" ]; then
    read -p "Repository name: " REPO
fi

if [ -z "$SCRIPT_PATH" ]; then
    read -p "Script path: " SCRIPT_PATH
fi


if [ -z "$USERNAME" ] || [ -z "$REPO" ] || [ -z "$SCRIPT_PATH" ]; then
    echo "Required values are missing"
    exit 1
fi

echo "==> Installing dependencies..."
sudo apt-get update
sudo apt-get install -y git curl

echo "==> Enabling Git credential storage..."
git config --global credential.helper store

echo
echo "==> Testing GitHub access..."

if ! git ls-remote "https://github.com/$USERNAME/$REPO.git" >/dev/null; then
    echo "GitHub authentication failed"
    exit 1
fi

echo "GitHub access OK"


if [ ! -f ~/.git-credentials ]; then
    echo "Git credentials not found"
    exit 1
fi


echo "==> Extracting token..."

TOKEN=$(grep "github.com" ~/.git-credentials | tail -n1 | sed -E 's#https://[^:]+:([^@]+)@.*#\1#')


if [ -z "$TOKEN" ]; then
    echo "Could not extract token"
    exit 1
fi


echo "==> Downloading setup script..."

curl -fsSL \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github.raw" \
    "https://api.github.com/repos/$USERNAME/$REPO/contents/$SCRIPT_PATH?ref=main" \
    | bash