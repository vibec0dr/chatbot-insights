#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$HOME/.local/bin"
mkdir -p "$INSTALL_DIR"

detect_asset() {
    local os arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)

    case "$os" in
        linux)
            [[ "$arch" == "x86_64" ]] && echo "tailwindcss-linux-x64" && return
            [[ "$arch" == "arm64" || "$arch" == "aarch64" ]] && echo "tailwindcss-linux-arm64" && return
            ;;
        darwin)
            [[ "$arch" == "x86_64" ]] && echo "tailwindcss-macos-x64" && return
            [[ "$arch" == "arm64" ]] && echo "tailwindcss-macos-arm64" && return
            ;;
    esac

    echo "Unsupported OS/architecture: $os $arch" >&2
    exit 1
}

get_latest_version() {
    curl -fsSL https://api.github.com/repos/tailwindlabs/tailwindcss/releases/latest \
        | grep '"tag_name":' \
        | head -n1 \
        | cut -d '"' -f4
}

install_tailwind() {
    local version="$1"
    local asset="$2"
    local base="https://github.com/tailwindlabs/tailwindcss/releases/download/$version"
    local binary_url="$base/$asset"
    local sha_url="$base/sha256sums.txt"

    echo "Downloading TailwindCSS $version ($asset)..."
    curl -fsSL -o "$INSTALL_DIR/tailwindcss" "$binary_url"

    echo "Downloading sha256sums.txt..."
    curl -fsSL -o "$INSTALL_DIR/sha256sums.txt" "$sha_url"

    echo "Verifying checksum..."
    local expected actual
    expected=$(grep "$asset" "$INSTALL_DIR/sha256sums.txt" | head -n1 | tr -d '\r' | cut -d ' ' -f1)
    actual=$(sha256sum "$INSTALL_DIR/tailwindcss" | cut -d ' ' -f1)

    if [[ "$expected" != "$actual" ]]; then
        echo "Checksum mismatch! Aborting."
        exit 1
    fi
    echo "Checksum verified."

    chmod +x "$INSTALL_DIR/tailwindcss"
    rm -f "$INSTALL_DIR/sha256sums.txt"

    echo "TailwindCSS $version installed successfully to $INSTALL_DIR/tailwindcss"
    echo 'Make sure $INSTALL_DIR is in your PATH:'
    echo 'export PATH="$HOME/.local/bin:$PATH"'
}

echo "Installing Tailwind CSS..."
version=$(get_latest_version)
asset=$(detect_asset)
install_tailwind "$version" "$asset"
