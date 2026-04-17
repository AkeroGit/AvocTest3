#!/usr/bin/env bash

# AVoc Installer - Portable, Self-Contained
# Design goals:
# 1. Everything inside $PREFIX (truly portable)
# 2. No system modifications (except optional desktop file)
# 3. Uninstaller removes everything cleanly

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
REQUIRED_PYTHON_VERSION="3.12.3"
VENV_DIR_NAME=".venv"
UV_DIR_NAME=".uv"
PYTHON_DIR_NAME=".python"
CACHE_DIR_NAME=".cache"
APP_DIR_NAME="app"

# =============================================================================
# PATH RESOLUTION
# =============================================================================
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
PREFIX=""
NO_SHORTCUTS=0
SKIP_VERIFY=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --prefix)
            PREFIX="${2:-}"
            shift 2
            ;;
        --prefix=*)
            PREFIX="${1#*=}"
            shift
            ;;
        --no-shortcuts)
            NO_SHORTCUTS=1
            shift
            ;;
        --skip-verify)
            SKIP_VERIFY=1
            shift
            ;;
        --help|-h)
            cat << EOF
AVoc Portable Installer

Usage: $0 [OPTIONS]

Options:
    --prefix PATH       Install to specific directory
    --no-shortcuts      Don't create desktop/menu shortcuts
    --skip-verify       Skip Python version verification
    --help             Show this help

Examples:
    $0 --prefix \$HOME/.local/opt/avoc
    $0 --prefix /opt/avoc --no-shortcuts
EOF
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

# =============================================================================
# INTERACTIVE MODE
# =============================================================================
if [[ -z "$PREFIX" ]]; then
    echo "AVoc Installer"
    echo "=============="
    echo ""
    echo "Where would you like to install AVoc?"
    echo ""
    echo "1) User directory:  $HOME/.local/opt/avoc"
    echo "2) Current dir:     $(pwd)/avoc-install"
    echo "3) Custom path"
    echo ""
    read -p "Select [1-3, default=1]: " choice
    
    case "${choice:-1}" in
        1|"")
            PREFIX="$HOME/.local/opt/avoc"
            ;;
        2)
            PREFIX="$(pwd)/avoc-install"
            ;;
        3)
            read -p "Enter path: " custom_path
            PREFIX="${custom_path:-$HOME/.local/opt/avoc}"
            ;;
        *)
            echo "Invalid choice" >&2
            exit 1
            ;;
    esac
fi

# =============================================================================
# VALIDATE PREFIX
# =============================================================================
# Prevent dangerous paths
case "$PREFIX" in
    "/"|"/usr"|"/usr/local"|"/opt"|"/home"|"$HOME")
        echo "ERROR: Refusing to install directly to $PREFIX" >&2
        echo "Please use a subdirectory like $PREFIX/avoc" >&2
        exit 1
        ;;
esac

# Create and canonicalize prefix
mkdir -p "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"

echo "Installing AVoc to: $PREFIX"
echo ""

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================
echo "[0/6] Preflight checks..."

# Check if destination is writable
if [[ ! -w "$PREFIX" ]]; then
    echo "ERROR: Cannot write to $PREFIX" >&2
    exit 1
fi

# Check required files exist in source
if [[ ! -f "$SCRIPT_DIR/pyproject.toml" ]]; then
    echo "ERROR: pyproject.toml not found in $SCRIPT_DIR" >&2
    exit 1
fi

if [[ ! -f "$SCRIPT_DIR/uv.lock" ]]; then
    echo "WARNING: uv.lock not found - install may not be reproducible" >&2
    echo "Press Ctrl+C to cancel, or Enter to continue anyway..."
    read
fi

# Check if target already has an installation
if [[ -d "$PREFIX/$VENV_DIR_NAME" ]] || [[ -d "$PREFIX/$APP_DIR_NAME" ]]; then
    echo "WARNING: Existing installation detected at $PREFIX"
    read -p "Remove existing installation? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$PREFIX/$VENV_DIR_NAME" "$PREFIX/$APP_DIR_NAME" "$PREFIX/$UV_DIR_NAME" "$PREFIX/bin"
    else
        echo "Aborted."
        exit 1
    fi
fi

# =============================================================================
# SETUP ISOLATED ENVIRONMENT
# =============================================================================
# CRITICAL: All UV/Python environments isolated to $PREFIX

export UV_DIR="$PREFIX/$UV_DIR_NAME"
export UV_CACHE_DIR="$PREFIX/$CACHE_DIR_NAME"
export UV_PYTHON_INSTALL_DIR="$PREFIX/$PYTHON_DIR_NAME"
export UV_PYTHON="$UV_PYTHON_INSTALL_DIR/cpython-$REQUIRED_PYTHON_VERSION-linux-x86_64-gnu/bin/python3"

# Ensure these directories exist
mkdir -p "$UV_CACHE_DIR"
mkdir -p "$UV_PYTHON_INSTALL_DIR"

# =============================================================================
# INSTALL UV (Self-Contained)
# =============================================================================
echo "[1/6] Installing uv (package manager)..."

if [[ ! -f "$UV_DIR/uv" ]]; then
    # Download uv to temp first (atomic move)
    UV_TEMP="$(mktemp -d)"
    trap "rm -rf '$UV_TEMP'" EXIT
    
    curl -LsSf https://astral.sh/uv/install.sh | \
        UV_UNMANAGED_INSTALL="$UV_TEMP" sh
    
    # Atomic move to final location
    mv "$UV_TEMP" "$UV_DIR"
fi

export PATH="$UV_DIR:$PATH"

# Verify uv works
if ! "$UV_DIR/uv" --version >/dev/null 2>&1; then
    echo "ERROR: uv installation failed" >&2
    exit 1
fi

# =============================================================================
# INSTALL PYTHON (Managed, Self-Contained)
# =============================================================================
echo "[2/6] Installing Python $REQUIRED_PYTHON_VERSION..."

# Install Python only if not already present
if [[ ! -f "$UV_PYTHON" ]]; then
    "$UV_DIR/uv" python install "$REQUIRED_PYTHON_VERSION" \
        --python-preference only-managed \
        --install-dir "$UV_PYTHON_INSTALL_DIR"
fi

# Verify Python version (optional)
if [[ $SKIP_VERIFY -eq 0 ]]; then
    INSTALLED_VERSION=$("$UV_PYTHON" --version 2>&1 | cut -d' ' -f2)
    if [[ "$INSTALLED_VERSION" != "$REQUIRED_PYTHON_VERSION" ]]; then
        echo "WARNING: Python version mismatch (got $INSTALLED_VERSION, expected $REQUIRED_PYTHON_VERSION)" >&2
    fi
fi

# =============================================================================
# CREATE VIRTUAL ENVIRONMENT
# =============================================================================
echo "[3/6] Creating virtual environment..."

VENV_DIR="$PREFIX/$VENV_DIR_NAME"

# Use the managed Python to create venv
"$UV_PYTHON" -m venv "$VENV_DIR"

# Verify venv was created
if [[ ! -f "$VENV_DIR/bin/python" ]]; then
    echo "ERROR: Failed to create virtual environment" >&2
    exit 1
fi

# =============================================================================
# COPY APPLICATION FILES
# =============================================================================
echo "[4/6] Copying application files..."

APP_DIR="$PREFIX/$APP_DIR_NAME"
mkdir -p "$APP_DIR"

# Copy only necessary files
cp "$SCRIPT_DIR/pyproject.toml" "$APP_DIR/"
[[ -f "$SCRIPT_DIR/uv.lock" ]] && cp "$SCRIPT_DIR/uv.lock" "$APP_DIR/"
[[ -f "$SCRIPT_DIR/README.md" ]] && cp "$SCRIPT_DIR/README.md" "$APP_DIR/"

# Copy source code
if [[ -d "$SCRIPT_DIR/src" ]]; then
    cp -r "$SCRIPT_DIR/src" "$APP_DIR/"
else
    echo "ERROR: src/ directory not found" >&2
    exit 1
fi

# =============================================================================
# INSTALL DEPENDENCIES (Using Lock File)
# =============================================================================
echo "[5/6] Installing dependencies..."

cd "$APP_DIR"

# CRITICAL: Use uv sync with frozen lock for reproducibility
if [[ -f "uv.lock" ]]; then
    # --frozen ensures exact versions from lock file
    "$UV_DIR/uv" sync --frozen --python "$VENV_DIR/bin/python"
else
    echo "ERROR: uv.lock required for reproducible install" >&2
    exit 1
fi

# Verify voiceconversion is installed
if ! "$VENV_DIR/bin/python" -c "import voiceconversion" 2>/dev/null; then
    echo "ERROR: voiceconversion package not installed correctly" >&2
    exit 1
fi

# =============================================================================
# CREATE LAUNCHER
# =============================================================================
echo "[6/6] Creating launcher..."

mkdir -p "$PREFIX/bin"

cat > "$PREFIX/bin/avoc" << 'LAUNCHER_EOF'
#!/bin/bash
# AVoc Launcher - Auto-generated
set -e

# Resolve script location (handle symlinks)
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    [[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
PREFIX="$(cd "$(dirname "$SCRIPT_SOURCE")/.." && pwd)"

# Set environment
export AVOC_HOME="$PREFIX"
export AVOC_DATA_DIR="$PREFIX/data"
export PATH="$PREFIX/.uv:$PATH"

# Ensure data directory exists
mkdir -p "$AVOC_DATA_DIR"

# Launch application
exec "$PREFIX/.venv/bin/python" -m avoc "$@"
LAUNCHER_EOF

chmod +x "$PREFIX/bin/avoc"

# =============================================================================
# CREATE DATA DIRECTORY
# =============================================================================
mkdir -p "$PREFIX/data"

# =============================================================================
# CREATE UNINSTALLER
# =============================================================================
cat > "$PREFIX/bin/uninstall" << 'UNINSTALL_EOF'
#!/bin/bash
# AVoc Uninstaller

set -euo pipefail

# Resolve PREFIX from script location
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    [[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
PREFIX="$(cd "$(dirname "$SCRIPT_SOURCE")/.." && pwd)"

echo ""
echo "AVoc Uninstaller"
echo "================"
echo ""
echo "Target: $PREFIX"
echo ""

# Safety checks
if [[ ! -d "$PREFIX/.venv" ]] && [[ ! -d "$PREFIX/app" ]]; then
    echo "ERROR: Does not appear to be an AVoc installation" >&2
    exit 1
fi

# Check if running
if pgrep -f "avoc" >/dev/null 2>&1; then
    echo "WARNING: AVoc appears to be running."
    read -p "Force uninstall? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Confirmation
read -p "Remove AVoc completely? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo "Removing files..."

# Remove known directories (safer than rm -rf $PREFIX)
declare -a REMOVE_DIRS=(
    "$PREFIX/.venv"
    "$PREFIX/.uv"
    "$PREFIX/.python"
    "$PREFIX/.cache"
    "$PREFIX/app"
    "$PREFIX/bin"
    "$PREFIX/data"
)

for dir in "${REMOVE_DIRS[@]}"; do
    if [[ -e "$dir" ]]; then
        printf "  %-40s ... " "$(basename "$dir")"
        if rm -rf "$dir" 2>/dev/null; then
            echo "OK"
        else
            echo "FAILED (permission denied or in use)"
        fi
    fi
done

# Remove desktop shortcut if exists
DESKTOP_FILE="$HOME/.local/share/applications/avoc.desktop"
if [[ -f "$DESKTOP_FILE" ]]; then
    printf "  %-40s ... " "desktop shortcut"
    if rm "$DESKTOP_FILE" 2>/dev/null; then
        echo "OK"
    else
        echo "FAILED"
    fi
fi

# Try to remove prefix directory if empty
if [[ -z "$(ls -A "$PREFIX" 2>/dev/null)" ]]; then
    rmdir "$PREFIX" 2>/dev/null || true
    echo ""
    echo "AVoc uninstalled. $PREFIX removed."
else
    echo ""
    echo "AVoc uninstalled. Some files remain in $PREFIX:"
    ls -la "$PREFIX"
fi
UNINSTALL_EOF

chmod +x "$PREFIX/bin/uninstall"

# =============================================================================
# OPTIONAL: DESKTOP SHORTCUT
# =============================================================================
if [[ $NO_SHORTCUTS -eq 0 ]]; then
    DESKTOP_DIR="$HOME/.local/share/applications"
    DESKTOP_FILE="$DESKTOP_DIR/avoc.desktop"
    
    mkdir -p "$DESKTOP_DIR"
    
    cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Name=AVoc
Comment=Real-time Voice Changer
Exec=$PREFIX/bin/avoc
Terminal=false
Type=Application
Categories=AudioVideo;Audio;
StartupNotify=true
EOF
    
    echo "Created desktop shortcut: $DESKTOP_FILE"
    
    # Update desktop database (optional, best effort)
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    fi
fi

# =============================================================================
# COMPLETION
# =============================================================================
echo ""
echo "=============================================="
echo "Installation Complete!"
echo "=============================================="
echo "Location:  $PREFIX"
echo "Run:       $PREFIX/bin/avoc"
echo "Uninstall: $PREFIX/bin/uninstall"
[[ $NO_SHORTCUTS -eq 0 ]] && echo "Desktop:   $HOME/.local/share/applications/avoc.desktop"
echo "=============================================="
echo ""
echo "To add to PATH, run:"
echo "  export PATH=\"$PREFIX/bin:\$PATH\""
