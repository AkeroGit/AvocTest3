#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Check for --no-shortcuts flag
NO_SHORTCUTS=false
if [[ "${1:-}" == "--no-shortcuts" ]]; then
    NO_SHORTCUTS=true
    shift
elif [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    echo "Usage: $0 [--no-shortcuts] [PREFIX]"
    echo ""
    echo "Options:"
    echo "  --no-shortcuts    Skip system integration"
    echo "  PREFIX            Installation directory"
    exit 0
fi

# Interactive prompt
if [[ $# -eq 0 ]]; then
    echo "AVoc Installer"
    echo "=============="
    echo ""
    read -p "Use current directory (0) or custom path (1)? [0/1]: " choice

    if [[ "$choice" == "0" ]]; then
        PREFIX="$(pwd)/avoc-install"
    else
        read -p "Enter installation directory [$HOME/.local/opt/avoc]: " custom_path
        PREFIX="${custom_path:-$HOME/.local/opt/avoc}"
    fi
else
    PREFIX="$1"
fi

# Ask about shortcuts
if [[ "$NO_SHORTCUTS" == false ]]; then
    echo ""
    read -p "Create system shortcuts? [y/N]: " shortcut_choice
    [[ "$shortcut_choice" =~ ^[Yy]$ ]] || NO_SHORTCUTS=true
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

# Install Python
echo "Installing Python 3.12.3..."
mkdir -p "$UV_PYTHON_INSTALL_DIR"
uv python install 3.12.3 2>/dev/null || true

# Find Python
PYTHON_EXE=""
for py_path in "$UV_PYTHON_INSTALL_DIR/bin/python3.12" "$UV_PYTHON_INSTALL_DIR/python3.12" "$HOME/.local/bin/python3.12"; do
    if [ -x "$py_path" ]; then
        PYTHON_EXE="$py_path"
        break
    fi
done

if [ -z "$PYTHON_EXE" ]; then
    echo "Error: Python 3.12 not found"
    exit 1
fi

echo "Using Python: $PYTHON_EXE"

# Create venv
VENV_DIR="$PREFIX/.venv"
echo "Creating virtual environment..."
uv venv --python "$PYTHON_EXE" "$VENV_DIR"

# ============================================
# KEY CHANGE: Install with pinned requirements
# ============================================
echo "Installing exact dependency versions from requirements-3.12.3.txt..."
uv pip install -r "$SCRIPT_DIR/requirements-3.12.3.txt" --python "$VENV_DIR/bin/python"

# Install avoc package itself (no deps, already installed from requirements)
uv pip install --no-deps --python "$VENV_DIR/bin/python" "$SCRIPT_DIR"

# Create launcher
mkdir -p "$PREFIX/bin"
cat > "$PREFIX/bin/avoc.sh" << 'EOF'
#!/bin/bash
AVOC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AVOC_HOME="$AVOC_ROOT"
export AVOC_DATA_DIR="$AVOC_ROOT/data"
exec "$AVOC_ROOT/.venv/bin/avoc" "$@"
EOF

chmod +x "$PREFIX/bin/avoc.sh"
ln -sf "$PREFIX/bin/avoc.sh" "$PREFIX/bin/avoc" 2>/dev/null || true

# Create data directory
mkdir -p "$PREFIX/data"

# Create uninstaller
#!/bin/bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "AVoc Uninstaller"
echo "================"
echo "Location: $ROOT"
echo ""

found=0

# Qt settings
for check_path in "$HOME/.local/share/AVocOrg" "$HOME/.config/AVocOrg"; do
    if [ -e "$check_path" ]; then
        echo "Found: $check_path"
        found=1
    fi
done

# Python symlinks (all variants)
for pylink in "$HOME/.local/bin/python3.12" "$HOME/.local/bin/python3" "$HOME/.local/bin/python"; do
    if [ -L "$pylink" ]; then
        target=$(readlink -f "$pylink" 2>/dev/null)
        if [[ "$target" == "$ROOT"* ]]; then
            rm -f "$pylink" && echo "Removed: $pylink"
        fi
    fi
done

# System shortcuts
if [ -f "$ROOT/install-manifest.txt" ]; then
    while IFS= read -r line; do
        rm -rf "$line" 2>/dev/null && echo "Removed: $line"
    done < "$ROOT/install-manifest.txt"
    rm -f "$ROOT/install-manifest.txt"
fi

read -p "Remove AVoc from $ROOT? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "$ROOT" && echo "AVoc removed."
    [ $found -eq 1 ] && echo "Note: config files remain in ~/.config/AVocOrg"
fi

echo ""
echo "=============================================="
echo "Installation Complete!"
echo "=============================================="
echo "Run: $PREFIX/bin/avoc.sh"
echo "=============================================="
