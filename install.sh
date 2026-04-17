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
    echo "Press 0 to use current directory"
    echo "Press 1 to enter custom path"
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

# Ask about shortcuts
if [[ "$NO_SHORTCUTS" == false ]]; then
    echo ""
    echo "Create system shortcuts? [y/N]: "
    read -p "" shortcut_choice
    
    if [[ "$shortcut_choice" =~ ^[Yy]$ ]]; then
        NO_SHORTCUTS=false
        echo "Shortcuts will be created."
    else
        NO_SHORTCUTS=true
        echo "Self-contained mode selected."
    fi
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
mkdir -p "$UV_PYTHON_INSTALL_DIR"
uv python install 3.12.3 2>/dev/null || true

# Find Python
PYTHON_EXE=""
if [ -x "$UV_PYTHON_INSTALL_DIR/bin/python3.12" ]; then
    PYTHON_EXE="$UV_PYTHON_INSTALL_DIR/bin/python3.12"
elif [ -x "$HOME/.local/bin/python3.12" ]; then
    PYTHON_EXE="$HOME/.local/bin/python3.12"
else
    echo "Error: Python 3.12 not found"
    exit 1
fi

echo "Using Python: $PYTHON_EXE"

# Create venv
VENV_DIR="$PREFIX/.venv"
echo "Creating virtual environment..."
uv venv --python "$PYTHON_EXE" "$VENV_DIR"

# Install avoc
echo "Installing AVoc..."
uv pip install --python "$VENV_DIR/bin/python" "$SCRIPT_DIR"

# Create data directory
mkdir -p "$PREFIX/data"

# ============================================
# CREATE LAUNCHER (with .sh extension and executable)
# ============================================
mkdir -p "$PREFIX/bin"

cat > "$PREFIX/bin/avoc.sh" << 'EOF'
#!/bin/bash
AVOC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AVOC_HOME="$AVOC_ROOT"
export AVOC_DATA_DIR="$AVOC_ROOT/data"
exec "$AVOC_ROOT/.venv/bin/avoc" "$@"
EOF

# Make it executable (THIS IS THE IMPORTANT PART)
chmod +x "$PREFIX/bin/avoc.sh"

# Also create a symlink without .sh for convenience (optional)
ln -sf "$PREFIX/bin/avoc.sh" "$PREFIX/bin/avoc" 2>/dev/null || true

# ============================================

# Create uninstaller ( tracks leaks )
cat > "$PREFIX/bin/uninstall.sh" << 'EOF'
#!/bin/bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "AVoc Uninstaller"
echo "================"
echo ""

# Check for files outside install directory
found=0
for check_path in "$HOME/.local/share/AVocOrg" "$HOME/.config/AVocOrg"; do
    if [ -e "$check_path" ]; then
        echo "  Found: $check_path"
        found=1
    fi
done

# Python symlink from uv
PYTHON_SYMLINK="$HOME/.local/bin/python3.12"
if [ -L "$PYTHON_SYMLINK" ]; then
    LINK_TARGET=$(readlink -f "$PYTHON_SYMLINK" 2>/dev/null)
    if [[ "$LINK_TARGET" == "$ROOT"* ]]; then
        echo "  Found uv symlink: $PYTHON_SYMLINK"
        rm -f "$PYTHON_SYMLINK" && echo "    Removed"
    fi
fi

# System shortcuts
if [ -f "$ROOT/install-manifest.txt" ]; then
    while IFS= read -r line; do
        if [[ -f "$line" ]] || [[ -d "$line" ]]; then
            rm -rf "$line" 2>/dev/null && echo "  Removed: $line"
        fi
    done < "$ROOT/install-manifest.txt"
    rm -f "$ROOT/install-manifest.txt"
fi

read -p "Remove AVoc from $ROOT? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "$ROOT"
    echo "AVoc removed."
fi
EOF

chmod +x "$PREFIX/bin/uninstall.sh"
ln -sf "$PREFIX/bin/uninstall.sh" "$PREFIX/bin/uninstall" 2>/dev/null || true

# Track shortcuts if any
MANIFEST_FILE="$PREFIX/install-manifest.txt"
> "$MANIFEST_FILE"

if [[ "$NO_SHORTCUTS" == false ]]; then
    echo "Creating system shortcuts..."
    
    DESKTOP_FILE="$HOME/.local/share/applications/avoc.desktop"
    mkdir -p "$(dirname "$DESKTOP_FILE")"
    
    cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Name=AVoc
Exec=$PREFIX/bin/avoc.sh
Icon=$PREFIX/.venv/lib/python3.12/site-packages/avoc/AVoc.svg
Type=Application
Terminal=false
Categories=Audio;AudioVideo;
EOF
    
    echo "$DESKTOP_FILE" >> "$MANIFEST_FILE"
    
    if command -v update-desktop-database &> /dev/null; then
        update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    fi
fi

echo ""
echo "=============================================="
echo "Installation Complete!"
echo "=============================================="
echo "Location: $PREFIX"
echo "Run: $PREFIX/bin/avoc.sh  (or $PREFIX/bin/avoc)"
echo "Uninstall: $PREFIX/bin/uninstall.sh"
echo "=============================================="
