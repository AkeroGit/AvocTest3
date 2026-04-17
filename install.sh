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
    echo "  --no-shortcuts    Skip system shortcuts (desktop entry, menu items)"
    echo "  PREFIX            Installation directory (default: ~/avoc-install or ~/.local/opt/avoc)"
    exit 0
fi

# Interactive prompt: 1=custom path, 0=current directory
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

# Ask about shortcuts if not already disabled via flag
if [[ "$NO_SHORTCUTS" == false ]]; then
    echo ""
    echo "System Integration"
    echo "=================="
    echo "Create system shortcuts? (desktop entry, menu items)"
    echo ""
    echo "y = Yes - Creates shortcuts"
    echo "N = No  - Keep self-contained (no system integration)"
    echo ""
    read -p "Create shortcuts? [y/N]: " shortcut_choice
    
    if [[ "$shortcut_choice" =~ ^[Yy]$ ]]; then
        NO_SHORTCUTS=false
        echo "Shortcuts will be created. Run uninstaller to remove them."
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

# Install Python 3.12.3 to self-contained location
echo "Installing Python 3.12.3..."
mkdir -p "$UV_PYTHON_INSTALL_DIR"

# Try to install to self-contained location
uv python install 3.12.3 2>/dev/null || true

# Find where Python was actually installed
PYTHON_EXE=""
PYTHON_SYMLINK=""

if [ -x "$UV_PYTHON_INSTALL_DIR/bin/python3.12" ]; then
    PYTHON_EXE="$UV_PYTHON_INSTALL_DIR/bin/python3.12"
    echo "✓ Python installed to: $PYTHON_EXE"
elif [ -x "$UV_PYTHON_INSTALL_DIR/python3.12" ]; then
    PYTHON_EXE="$UV_PYTHON_INSTALL_DIR/python3.12"
    echo "✓ Python installed to: $PYTHON_EXE"
elif [ -x "$HOME/.local/bin/python3.12" ]; then
    PYTHON_EXE="$HOME/.local/bin/python3.12"
    PYTHON_SYMLINK="$HOME/.local/bin/python3.12"
    echo "✓ Python installed to: $PYTHON_EXE"
    echo "  Note: A symlink was created at ~/.local/bin/python3.12"
    echo "        This will be tracked and can be removed by the uninstaller."
else
    echo "Error: Python installation failed"
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

# Create data directories
mkdir -p "$PREFIX/data"

# Create launcher with environment variables
mkdir -p "$PREFIX/bin"
cat > "$PREFIX/bin/avoc" << 'EOF'
#!/bin/bash
AVOC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AVOC_HOME="$AVOC_ROOT"
export AVOC_DATA_DIR="$AVOC_ROOT/data"
exec "$AVOC_ROOT/.venv/bin/avoc" "$@"
EOF
chmod +x "$PREFIX/bin/avoc"

# Create uninstaller
cat > "$PREFIX/bin/uninstall" << 'EOF'
#!/bin/bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "AVoc Uninstaller"
echo "================"
echo "Location: $ROOT"
echo ""

# Check for files outside install directory
echo "Checking for files to clean up..."
found=0

# System data locations
for check_path in "$HOME/.local/share/AVocOrg" "$HOME/.config/AVocOrg"; do
    if [ -e "$check_path" ]; then
        echo "  Found: $check_path"
        found=1
    fi
done

# Python symlink (created by uv)
PYTHON_SYMLINK="$HOME/.local/bin/python3.12"
if [ -L "$PYTHON_SYMLINK" ]; then
    LINK_TARGET=$(readlink -f "$PYTHON_SYMLINK" 2>/dev/null)
    if [[ "$LINK_TARGET" == "$ROOT"* ]]; then
        echo "  Found uv-created symlink: $PYTHON_SYMLINK"
        found=1
    fi
fi

# Remove tracked shortcuts
if [ -f "$ROOT/install-manifest.txt" ]; then
    echo ""
    echo "Removing system shortcuts..."
    while IFS= read -r line; do
        if [[ -f "$line" ]] || [[ -d "$line" ]]; then
            rm -rf "$line" 2>/dev/null && echo "  Removed: $line"
        fi
    done < "$ROOT/install-manifest.txt"
    rm -f "$ROOT/install-manifest.txt"
fi

# Remove uv-created Python symlink if tracked
if [ -f "$ROOT/.uv-python-symlink" ]; then
    SYMLINK_PATH=$(cat "$ROOT/.uv-python-symlink")
    if [ -L "$SYMLINK_PATH" ]; then
        rm -f "$SYMLINK_PATH" && echo "  Removed: $SYMLINK_PATH"
    fi
    rm -f "$ROOT/.uv-python-symlink"
fi

echo ""
read -p "Remove AVoc from $ROOT? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "$ROOT"
    echo "AVoc removed."
    
    if [ $found -eq 1 ]; then
        echo ""
        echo "Note: Some files remain and can be removed manually:"
        echo "  ~/.local/share/AVocOrg"
        echo "  ~/.config/AVocOrg"
        if [ -L "$HOME/.local/bin/python3.12" ]; then
            echo "  ~/.local/bin/python3.12 (if not already removed)"
        fi
    fi
fi
EOF
chmod +x "$PREFIX/bin/uninstall"

# Create install manifest for tracking
MANIFEST_FILE="$PREFIX/install-manifest.txt"
> "$MANIFEST_FILE"

# Track Python symlink if created by uv
PYTHON_LINK="$HOME/.local/bin/python3.12"
if [ -L "$PYTHON_LINK" ]; then
    LINK_TARGET=$(readlink -f "$PYTHON_LINK" 2>/dev/null)
    if [[ "$LINK_TARGET" == "$PREFIX"* ]]; then
        echo "$PYTHON_LINK" > "$PREFIX/.uv-python-symlink"
        echo "Tracked uv-created symlink for uninstaller"
    fi
fi

# Create system shortcuts (only if requested)
if [[ "$NO_SHORTCUTS" == false ]]; then
    echo "Creating system shortcuts..."
    
    # Desktop entry for Linux
    DESKTOP_FILE="$HOME/.local/share/applications/avoc.desktop"
    mkdir -p "$(dirname "$DESKTOP_FILE")"
    
    cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Name=AVoc
Comment=Local Realtime Voice Changer
Exec=$PREFIX/bin/avoc
Icon=$PREFIX/src/avoc/AVoc.svg
Type=Application
Terminal=false
Categories=Audio;AudioVideo;
EOF
    
    echo "$DESKTOP_FILE" >> "$MANIFEST_FILE"
    echo "  Created: $DESKTOP_FILE"
    
    if command -v update-desktop-database &> /dev/null; then
        update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    fi
fi

echo ""
echo "=============================================="
echo "Installation Complete!"
echo "=============================================="
echo "Location: $PREFIX"
echo "Run: $PREFIX/bin/avoc"
echo ""

if [[ "$NO_SHORTCUTS" == true ]]; then
    echo "Mode: Self-contained"
else
    echo "Mode: With system shortcuts"
fi

echo "Uninstall: $PREFIX/bin/uninstall"
echo ""
echo "Note: This is a self-contained installation. Some components"
echo "      (Python symlink, config files) may remain in standard"
echo "      system locations and can be cleaned up by the uninstaller."
echo "=============================================="
