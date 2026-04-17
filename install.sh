#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

# Interactive prompt: 1=custom path, 0=current directory
if [[ $# -eq 0 ]]; then
    echo "AVoc Installer"
    echo "=============="
    echo ""
    read -p "Use custom path (1) or current directory (0)? [1/0]: " -n 1 -r
    echo ""

    if [[ "$REPLY" == "0" ]]; then
        PREFIX="$(pwd)/avoc-install"
        echo "Using current directory: $PREFIX"
    else
        # Default to custom path entry
        read -p "Enter installation directory [$HOME/.local/opt/avoc]: " custom_path
        PREFIX="${custom_path:-$HOME/.local/opt/avoc}"
    fi
else
    PREFIX="$1"
fi

mkdir -p "$PREFIX"

# Install Python 3.12.3 specifically (not latest)
echo "Installing Python 3.12.3..."
uv python install 3.12.3

VENV_DIR="$PREFIX/.venv"
uv venv --python 3.12.3 "$VENV_DIR"

# Install avoc
echo "Installing AVoc..."
uv pip install --python "$VENV_DIR/bin/python" "$SCRIPT_DIR"

# Create launcher
mkdir -p "$PREFIX/bin"
cat > "$PREFIX/bin/avoc" << 'EOF'
#!/bin/bash
AVOC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$AVOC_ROOT/.venv/bin/python" -m avoc "$@"
EOF
chmod +x "$PREFIX/bin/avoc"

# Create uninstaller
cat > "$PREFIX/bin/uninstall" << 'EOF'
#!/bin/bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
read -p "Remove AVoc from $ROOT? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "$ROOT" && echo "AVoc removed."
fi
EOF
chmod +x "$PREFIX/bin/uninstall"

echo ""
echo "=============================================="
echo "Installation Complete!"
echo "=============================================="
echo "Location: $PREFIX"
echo "Python: 3.12.3"
echo "Run: $PREFIX/bin/avoc"
