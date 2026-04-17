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
TEMP_DIR_NAME=".install-temp-$$"  # PID-suffixed for uniqueness

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
    
    # >>>>> SHORTCUT QUESTION INSERT
    echo ""
    read -p "Create desktop shortcut? [Y/n] " -n 1 -r
    echo ""
    [[ $REPLY =~ ^[Nn]$ ]] && NO_SHORTCUTS=1 || NO_SHORTCUTS=0
    # <<<<< END SHORTCUT QUESTION
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

# Create prefix early (needed for temp containment)
mkdir -p "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"

# =============================================================================
# CONTAINED TEMPORARY DIRECTORY
# =============================================================================
# CRITICAL: All temp files stay inside $PREFIX for true containment
TEMP_DIR="$PREFIX/$TEMP_DIR_NAME"
mkdir -p "$TEMP_DIR"

# Cleanup function - removes temp dir on exit
cleanup_temp() {
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_temp EXIT

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
export UV_DIR="$PREFIX/$UV_DIR_NAME"
export UV_CACHE_DIR="$PREFIX/$CACHE_DIR_NAME"
export UV_PYTHON_INSTALL_DIR="$PREFIX/$PYTHON_DIR_NAME"
export UV_PYTHON="$UV_PYTHON_INSTALL_DIR/cpython-$REQUIRED_PYTHON_VERSION-linux-x86_64-gnu/bin/python3"

# Create directories
mkdir -p "$UV_CACHE_DIR"
mkdir -p "$UV_PYTHON_INSTALL_DIR"

# =============================================================================
# INSTALL UV (Self-Contained, No External Temp Files)
# =============================================================================
echo "[1/6] Installing uv (package manager)..."

if [[ ! -f "$UV_DIR/uv" ]]; then
    echo "Downloading uv (direct binary, fully contained)..."
    
    # Use contained temp directory
    UV_TEMP="$TEMP_DIR/uv-download"
    mkdir -p "$UV_TEMP"
    
    UV_VERSION="0.6.0"
    UV_ARCH="x86_64-unknown-linux-gnu"
    UV_TARBALL="$UV_TEMP/uv.tar.gz"
    
    # Download to file first (better error handling than pipe)
    if ! curl -fsSL \
        "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_ARCH}.tar.gz" \
        -o "$UV_TARBALL"; then
        echo "ERROR: Failed to download uv" >&2
        exit 1
    fi
    
    # Extract
    if ! tar -xzf "$UV_TARBALL" -C "$UV_TEMP"; then
        echo "ERROR: Failed to extract uv" >&2
        exit 1
    fi
    
    # Debug: Show what we got
    echo "Downloaded files:"
    ls -la "$UV_TEMP/"
    
    # Find the uv binary (might be in subdirectory)
    UV_BINARY=$(find "$UV_TEMP" -name "uv" -type f | head -n1)
    if [[ -z "$UV_BINARY" ]]; then
        echo "ERROR: uv binary not found in archive" >&2
        exit 1
    fi
    
    mkdir -p "$UV_DIR"
    
    # Move binaries to final location
    mv "$UV_BINARY" "$UV_DIR/uv"
    
    # Also try to find uvx
    UVX_BINARY=$(find "$UV_TEMP" -name "uvx" -type f | head -n1)
    if [[ -n "$UVX_BINARY" ]]; then
        mv "$UVX_BINARY" "$UV_DIR/uvx"
    fi
    
    # Cleanup
    rm -rf "$UV_TEMP"
fi

# =============================================================================
# INSTALL PYTHON (Managed, Self-Contained)
# =============================================================================
echo "[2/6] Installing Python $REQUIRED_PYTHON_VERSION..."

if [[ ! -f "$UV_PYTHON" ]]; then
    "$UV_DIR/uv" python install "$REQUIRED_PYTHON_VERSION" \
        --python-preference only-managed \
        --install-dir "$UV_PYTHON_INSTALL_DIR"
fi

# Verify Python version
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
"$UV_PYTHON" -m venv "$VENV_DIR"

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
# INSTALL DEPENDENCIES
# =============================================================================
echo "[5/6] Installing dependencies..."

cd "$APP_DIR"

if [[ -f "uv.lock" ]]; then
    "$UV_DIR/uv" sync --frozen --python "$VENV_DIR/bin/python"
else
    echo "ERROR: uv.lock required for reproducible install" >&2
    exit 1
fi

# Verify voiceconversion
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
set -e

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    [[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
PREFIX="$(cd "$(dirname "$SCRIPT_SOURCE")/.." && pwd)"

export AVOC_HOME="$PREFIX"
export AVOC_DATA_DIR="$PREFIX/data"
export PATH="$PREFIX/.uv:$PATH"

mkdir -p "$AVOC_DATA_DIR"
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
set -euo pipefail

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

if [[ ! -d "$PREFIX/.venv" ]] && [[ ! -d "$PREFIX/app" ]]; then
    echo "ERROR: Does not appear to be an AVoc installation" >&2
    exit 1
fi

if pgrep -f "avoc" >/dev/null 2>&1; then
    echo "WARNING: AVoc appears to be running."
    read -p "Force uninstall? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

read -p "Remove AVoc completely? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo "Removing files..."

# >>>>> SYMLINK CLEANUP INSERT
for link in "$HOME/.local/bin/uv" "$HOME/.local/bin/python3.12" "$HOME/.local/bin/python3"; do
    if [[ -L "$link" ]]; then
        target="$(readlink "$link" 2>/dev/null || true)"
        if [[ "$target" == *"$PREFIX"* ]] || [[ "$target" == *"/.uv/"* ]] || [[ "$target" == *"/.python/"* ]]; then
            printf "  %-40s ... " "global symlink $(basename "$link")"
            rm -f "$link" && echo "removed" || echo "failed"
        fi
    fi
done
echo ""
# <<<<< END SYMLINK CLEANUP

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

DESKTOP_FILE="$HOME/.local/share/applications/avoc.desktop"
if [[ -f "$DESKTOP_FILE" ]]; then
    printf "  %-40s ... " "desktop shortcut"
    if rm "$DESKTOP_FILE" 2>/dev/null; then
        echo "OK"
    else
        echo "FAILED"
    fi
fi

# Clean up temp directory if still present
if [[ -d "$PREFIX/.install-temp-"* ]]; then
    rm -rf "$PREFIX/.install-temp-"* 2>/dev/null || true
fi

if [[ -z "$(ls -A "$PREFIX" 2>/dev/null)" ]]; then
    rmdir "$PREFIX" 2>/dev/null || true
    echo ""
    echo "AVoc uninstalled. $PREFIX removed."
else
    echo ""
    echo "AVoc uninstalled. Some files may remain:"
    ls -la "$PREFIX" 2>/dev/null || true
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
    
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    fi
fi

# =============================================================================
# FINAL CLEANUP
# =============================================================================
# Remove temp directory explicitly (trap will also handle this)
rm -rf "$TEMP_DIR" 2>/dev/null || true

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
