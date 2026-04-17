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
    echo "  --no-shortcuts    Skip system integration (fully portable)"
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
    echo "y = Yes - Creates shortcuts (you'll need to run the uninstaller later)"
    echo "N = No  - Keep fully portable (recommended, everything stays in one folder)"
    echo ""
    read -p "Create shortcuts? [y/N]: " shortcut_choice
    
    if [[ "$shortcut_choice" =~ ^[Yy]$ ]]; then
        NO_SHORTCUTS=false
        echo "Shortcuts will be created. Remember to run the uninstaller for complete removal."
    else
        NO_SHORTCUTS=true
        echo "Portable mode selected. No system integration."
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

# Install Python 3.12.3 to portable location
echo "Installing Python 3.12.3..."
mkdir -p "$UV_PYTHON_INSTALL_DIR"

# Try to install to portable location
uv python install 3.12.3 2>/dev/null || true

# Find where Python was actually installed
PYTHON_EXE=""
PYTHON_IS_PORTABLE=false

if [ -x "$UV_PYTHON_INSTALL_DIR/bin/python3.12" ]; then
    PYTHON_EXE="$UV_PYTHON_INSTALL_DIR/bin/python3.12"
    PYTHON_IS_PORTABLE=true
    echo "✓ Python installed to portable location: $PYTHON_EXE"
elif [ -x "$UV_PYTHON_INSTALL_DIR/python3.12" ]; then
    PYTHON_EXE="$UV_PYTHON_INSTALL_DIR/python3.12"
    PYTHON_IS_PORTABLE=true
    echo "✓ Python installed to portable location: $PYTHON_EXE"
elif [ -x "$HOME/.local/bin/python3.12" ]; then
    PYTHON_EXE="$HOME/.local/bin/python3.12"
    PYTHON_IS_PORTABLE=false
fi

# If Python went to system location, ask user what to do
if [[ "$PYTHON_IS_PORTABLE" == false ]]; then
    echo ""
    echo "⚠ WARNING: Python Installation Location"
    echo "========================================"
    echo ""
    echo "Python 3.12.3 was installed to: $PYTHON_EXE"
    echo ""
    echo "For FULL portability, Python should be in: $UV_PYTHON_INSTALL_DIR"
    echo ""
    echo "Options:"
    echo "  1) Abort - Stop installation and fix manually (recommended)"
    echo "  2) Continue - Install anyway (Python will be outside portable folder)"
    echo ""
    read -p "Your choice [1/2]: " location_choice
    
    if [[ "$location_choice" == "1" ]]; then
        echo ""
        echo "Installation aborted."
        echo ""
        echo "To fix this, you can:"
        echo "  - Add ~/.local/bin to your PATH: export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo "  - Then re-run this installer"
        echo "  - Or use: uv python install 3.12.3 --install-dir $UV_PYTHON_INSTALL_DIR"
        echo ""
        exit 1
    else
        echo ""
        echo "Continuing with system Python location."
        echo "Note: Python will remain in ~/.local/bin after uninstall."
        echo ""
        read -p "Press Enter to continue..."
    fi
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

# Create launcher with portable environment variables
mkdir -p "$PREFIX/bin"
cat > "$PREFIX/bin/avoc" << 'EOF'
#!/bin/bash
AVOC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AVOC_HOME="$AVOC_ROOT"
export AVOC_DATA_DIR="$AVOC_ROOT/data"
exec "$AVOC_ROOT/.venv/bin/python" -m avoc "$@"
EOF
chmod +x "$PREFIX/bin/avoc"

# Create uninstaller
cat > "$PREFIX/bin/uninstall" << 'EOF'
#!/bin/bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "AVoc Uninstaller"
echo "================"
echo "Location: $ROOT"

# Check for leaks BEFORE removal
echo ""
echo "Checking for configuration files..."
found=0

for check_path in "$HOME/.local/share/AVocOrg" "$HOME/.config/AVocOrg" "$HOME/.config/AVoc.ini" "$HOME/.config/AVoc.conf"; do
    if [ -e "$check_path" ]; then
        echo "  Found: $check_path"
        found=1
    fi
done

if [ -f "$ROOT/install-manifest.txt" ]; then
    echo "Removing system shortcuts from install-manifest.txt..."
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
    
    if [ $found -eq 1 ]; then
        echo ""
        echo "Note: Some files remain outside the install folder:"
        echo "  ~/.local/share/AVocOrg"
        echo "  ~/.config/AVocOrg"
        echo "Remove with: rm -rf ~/.local/share/AVocOrg ~/.config/AVocOrg"
    fi
fi
EOF
chmod +x "$PREFIX/bin/uninstall"

# Create install manifest for tracking shortcuts
MANIFEST_FILE="$PREFIX/install-manifest.txt"
> "$MANIFEST_FILE"

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
    
    # Update desktop database
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

if [[ "$NO_SHORTCUTS" == true ]]; then
    echo "Mode: Portable (no system integration)"
    echo "Uninstall: Simply delete $PREFIX"
else
    echo "Mode: With system shortcuts"
    echo "Uninstall: $PREFIX/bin/uninstall"
fi

echo "=============================================="
