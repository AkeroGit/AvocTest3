#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

# Interactive prompt: 1=custom path, 0=current directory
if [[ $# -eq 0 ]]; then
    echo "AVoc Installer"
    echo "=============="
    echo ""
    echo " Press 0 to use current directory"
    echo " Press 1 to enter custom path"
    read -p "[0/1]: " choice

    if [[ "$choice" == "0" ]]; then
        PREFIX="$(pwd)/avoc-install"
        echo "Using current directory: $PREFIX"
    else
        read -p "Enter installation directory [$HOME/.local/opt/avoc]: " custom_path
        PREFIX="${custom_path:-$HOME/.local/opt/avoc}"
    fi
else
    PREFIX="$1"
fi

# Resolve absolute path
mkdir -p "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"
echo "Installing AVoc to: $PREFIX"

# Bootstrap uv
UV_DIR="$PREFIX/.uv"
export UV_CACHE_DIR="$PREFIX/cache"
export UV_PYTHON_INSTALL_DIR="$PREFIX/python"

if [[ ! -f "$UV_DIR/uv" ]]; then
    echo "Downloading uv..."
    mkdir -p "$UV_DIR"
    curl -LsSf https://astral.sh/uv/install.sh | UV_UNMANAGED_INSTALL="$UV_DIR" sh
fi

export PATH="$UV_DIR:$PATH"

# Install Python 3.12.3
echo "Installing Python 3.12.3..."
uv python install 3.12.3

# Create venv
VENV_DIR="$PREFIX/.venv"
uv venv --python 3.12.3 "$VENV_DIR"

# Install avoc (voiceconversion from PyPI automatically, uses uv.lock)
echo "Installing AVoc..."
uv pip install --python "$VENV_DIR/bin/python" "$SCRIPT_DIR"

# Create launcher
mkdir -p "$PREFIX/bin"
cat > "$PREFIX/bin/avoc" << 'EOF'
#!/bin/bash
AVOC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AVOC_HOME="$AVOC_ROOT"
export AVOC_DATA_DIR="$AVOC_ROOT/data"
exec "$AVOC_ROOT/.venv/bin/python" -m avoc "$@"
EOF
chmod +x "$PREFIX/bin/avoc"

# Create data directory
mkdir -p "$PREFIX/data"

# Create uninstaller
cat > "$PREFIX/bin/uninstall" << 'EOF'
#!/bin/bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "AVoc Uninstaller"
echo "================"
echo ""

# Check for leaks BEFORE removal
echo "Checking for configuration files that will remain..."
found=0

for check_path in "$HOME/.local/share/AVocOrg" "$HOME/.config/AVocOrg" "$HOME/.config/AVoc.ini" "$HOME/.config/AVoc.conf"; do
    if [ -e "$check_path" ]; then
        echo "  Found: $check_path"
        found=1
    fi
done

if [ $found -eq 1 ]; then
    echo ""
    echo "WARNING: Some files exist outside the install folder."
    echo "Consider removing them manually after uninstall:"
    echo "  rm -rf ~/.local/share/AVocOrg ~/.config/AVocOrg ~/.config/AVoc*"
    echo ""
fi

read -p "Remove AVoc from $ROOT? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "$ROOT" 
    echo "AVoc removed."
    
    if [ $found -eq 1 ]; then
        echo ""
        echo "Remember to clean up remaining files (see warning above)."
    fi
fi
EOF
chmod +x "$PREFIX/bin/uninstall"

echo ""
echo "=============================================="
echo "Installation Complete!"
echo "=============================================="
echo "Location: $PREFIX"
echo "Run: $PREFIX/bin/avoc"
echo "Uninstall: $PREFIX/bin/uninstall"
echo "=============================================="
