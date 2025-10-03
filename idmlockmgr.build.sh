#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# Copyright (C) 2021 Seagate Technology LLC and/or its Affiliates.
#

set -e

PROPELLER_DIR="${PROPELLER_DIR:-$(pwd)}"
LVM_DIR="${LVM_DIR:-$HOME/repos/lvm2-idm}"
LVM_BRANCH="${LVM_BRANCH:-centos7_lvm2}"
LVM_REPO="${LVM_REPO:-https://github.com/Seagate/lvm2-idm}"

ENABLE_DLM="${ENABLE_DLM:-no}"
ENABLE_SANLOCK="${ENABLE_SANLOCK:-no}"
ENABLE_IDM="${ENABLE_IDM:-yes}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is not installed. Please install it first."
        return 1
    fi
    return 0
}

log_info "Performing pre-flight checks..."

for cmd in gcc make git ldconfig; do
    check_command "$cmd" || exit 1
done

if ! check_command pkg-config; then
    log_error "pkg-config is not installed but is required for LVM configure to detect IDM support."
    log_error "Install with: sudo apt-get install pkg-config (Ubuntu/Debian) or sudo yum install pkgconfig (RHEL/CentOS)"
    exit 1
fi

log_info "Checking for required development libraries..."
if ! ldconfig -p | grep -q libuuid; then
    log_error "libuuid not found. Install with: sudo apt-get install uuid-dev or sudo yum install libuuid-devel"
    exit 1
fi

if ! ldconfig -p | grep -q libblkid; then
    log_error "libblkid not found. Install with: sudo apt-get install libblkid-dev or sudo yum install libblkid-devel"
    exit 1
fi

log_info "Checking for LVM build dependencies..."
MISSING_DEPS=""

if [ ! -f /usr/include/libaio.h ]; then
    MISSING_DEPS="${MISSING_DEPS}libaio-dev (Ubuntu/Debian) or libaio-devel (RHEL/CentOS)\n"
fi

if ! ldconfig -p | grep -q libudev; then
    MISSING_DEPS="${MISSING_DEPS}libudev-dev (Ubuntu/Debian) or systemd-devel (RHEL/CentOS)\n"
fi

if [ ! -f /usr/include/readline/readline.h ]; then
    MISSING_DEPS="${MISSING_DEPS}libreadline-dev (Ubuntu/Debian) or readline-devel (RHEL/CentOS)\n"
fi

if [ -n "$MISSING_DEPS" ]; then
    log_error "Missing LVM build dependencies:"
    echo -e "$MISSING_DEPS"
    log_error "Please install the missing dependencies before running this script"
    exit 1
fi

log_info "Building Propeller IDM Lock Manager..."
cd "$PROPELLER_DIR"

if [ ! -f "Makefile" ]; then
    log_error "Propeller Makefile not found. Are you in the correct directory?"
    exit 1
fi

make clean
make

if [ $? -ne 0 ]; then
    log_error "Propeller build failed"
    exit 1
fi

log_info "Propeller build completed successfully"

log_info "Installing Propeller IDM Lock Manager (requires sudo)..."
sudo make install

if [ $? -ne 0 ]; then
    log_error "Propeller installation failed"
    exit 1
fi

log_info "Propeller installation completed"

log_info "Updating library cache with ldconfig..."
sudo ldconfig

log_info "Verifying library registration..."

if ! ldconfig -p | grep -q libseagate_ilm; then
    log_warn "libseagate_ilm not found in library cache after initial ldconfig"
    log_info "Checking if /usr/lib64 is in ldconfig search path..."
    
    if ! grep -r "^/usr/lib64$" /etc/ld.so.conf /etc/ld.so.conf.d/ 2>/dev/null | grep -q .; then
        log_info "/usr/lib64 not in ldconfig path, adding it..."
        echo "/usr/lib64" | sudo tee /etc/ld.so.conf.d/seagate_ilm-x86_64.conf > /dev/null
        sudo ldconfig
        
        if ! ldconfig -p | grep -q libseagate_ilm; then
            log_error "libseagate_ilm still not found in library cache after adding /usr/lib64"
            log_error "Check that library was installed correctly"
            exit 1
        fi
        
        log_info "✓ libseagate_ilm found in library cache after adding /usr/lib64 to ldconfig path"
    else
        log_error "libseagate_ilm not found in library cache, but /usr/lib64 is already in ldconfig path"
        log_error "Check that library was installed correctly"
        exit 1
    fi
else
    log_info "✓ libseagate_ilm found in library cache"
fi

if command -v pkg-config &> /dev/null; then
    log_info "Verifying pkg-config can find libseagate_ilm..."
    
    if pkg-config --exists libseagate_ilm; then
        log_info "✓ pkg-config can find libseagate_ilm"
        log_info "  Version: $(pkg-config --modversion libseagate_ilm)"
        log_info "  Cflags: $(pkg-config --cflags libseagate_ilm)"
        log_info "  Libs: $(pkg-config --libs libseagate_ilm)"
    else
        log_warn "pkg-config cannot find libseagate_ilm"
        log_warn "This may cause LVM configure to fail"
        
        if [ -f "/usr/lib64/pkgconfig/libseagate_ilm.pc" ]; then
            log_info "Found .pc file at /usr/lib64/pkgconfig/libseagate_ilm.pc"
            log_info "You may need to set: export PKG_CONFIG_PATH=/usr/lib64/pkgconfig"
            export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:$PKG_CONFIG_PATH"
            
            if pkg-config --exists libseagate_ilm; then
                log_info "✓ pkg-config can now find libseagate_ilm after setting PKG_CONFIG_PATH"
            fi
        fi
    fi
fi

log_info "Setting up LVM repository..."

if [ ! -d "$LVM_DIR" ]; then
    log_info "Cloning LVM repository to $LVM_DIR..."
    mkdir -p "$(dirname "$LVM_DIR")"
    git clone "$LVM_REPO" "$LVM_DIR"
    cd "$LVM_DIR"
    git checkout -b "$LVM_BRANCH" "origin/$LVM_BRANCH" 2>/dev/null || git checkout "$LVM_BRANCH"
else
    log_info "LVM repository already exists at $LVM_DIR"
    cd "$LVM_DIR"
    log_info "Updating repository..."
    git fetch
    git checkout "$LVM_BRANCH" || log_warn "Branch $LVM_BRANCH not found, using current branch"
fi

log_info "Configuring LVM with IDM support..."

LVMLOCKD_OPTIONS=""
if [ "$ENABLE_DLM" = "yes" ]; then
    log_info "DLM lock manager enabled"
    LVMLOCKD_OPTIONS="$LVMLOCKD_OPTIONS --enable-lvmlockd-dlm"
else
    log_info "DLM lock manager explicitly disabled"
    LVMLOCKD_OPTIONS="$LVMLOCKD_OPTIONS --disable-lvmlockd-dlm"
fi

if [ "$ENABLE_SANLOCK" = "yes" ]; then
    log_info "Sanlock lock manager enabled"
    LVMLOCKD_OPTIONS="$LVMLOCKD_OPTIONS --enable-lvmlockd-sanlock"
else
    log_info "Sanlock lock manager explicitly disabled"
    LVMLOCKD_OPTIONS="$LVMLOCKD_OPTIONS --disable-lvmlockd-sanlock"
fi

if [ "$ENABLE_IDM" = "yes" ]; then
    log_info "IDM lock manager enabled"
    LVMLOCKD_OPTIONS="$LVMLOCKD_OPTIONS --enable-lvmlockd-idm"
else
    log_info "IDM lock manager explicitly disabled"
    LVMLOCKD_OPTIONS="$LVMLOCKD_OPTIONS --disable-lvmlockd-idm"
fi

if [ "$ENABLE_DLM" != "yes" ] && [ "$ENABLE_SANLOCK" != "yes" ] && [ "$ENABLE_IDM" != "yes" ]; then
    log_error "No lock managers enabled. At least one of ENABLE_DLM, ENABLE_SANLOCK, or ENABLE_IDM must be 'yes'"
    exit 1
fi

export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:$PKG_CONFIG_PATH"

./configure \
    --build=x86_64-redhat-linux-gnu \
    --host=x86_64-redhat-linux-gnu \
    --program-prefix= \
    --disable-dependency-tracking \
    --prefix=/usr \
    --exec-prefix=/usr \
    --bindir=/usr/bin \
    --sbindir=/usr/sbin \
    --sysconfdir=/etc \
    --datadir=/usr/share \
    --includedir=/usr/include \
    --libdir=/usr/lib64 \
    --libexecdir=/usr/libexec \
    --localstatedir=/var \
    --sharedstatedir=/var/lib \
    --mandir=/usr/share/man \
    --infodir=/usr/share/info \
    --with-default-dm-run-dir=/run \
    --with-default-run-dir=/run/lvm \
    --with-default-pid-dir=/run \
    --with-default-locking-dir=/run/lock/lvm \
    --with-usrlibdir=/usr/lib64 \
    --enable-fsadm \
    --enable-write_install \
    --with-user= \
    --with-group= \
    --with-device-uid=0 \
    --with-device-gid=6 \
    --with-device-mode=0660 \
    --enable-pkgconfig \
    --enable-applib \
    --enable-cmdlib \
    --enable-dmeventd \
    --enable-blkid_wiping \
    --with-cluster=internal \
    --enable-udev_sync \
    --with-thin=internal \
    --enable-lvmpolld \
    $LVMLOCKD_OPTIONS \
    --enable-dmfilemapd

if [ $? -ne 0 ]; then
    log_error "LVM configure failed"
    log_error "Check that all dependencies are installed and that lock manager support was detected"
    exit 1
fi

log_info "✓ LVM configure completed successfully with IDM support enabled"

if [ "$ENABLE_IDM" = "yes" ]; then
    log_info "Applying workaround for LOCKDIDM_SUPPORT macro..."
    
    if ! grep -q "define LOCKDIDM_SUPPORT" include/configure.h; then
        log_warn "LOCKDIDM_SUPPORT not found in include/configure.h, adding it manually"
        
        sed -i '/LOCKDSANLOCK_SUPPORT/a\
\
/* Define to 1 to include code that uses lvmlockd IDM option. */\
#define LOCKDIDM_SUPPORT 1' include/configure.h
        
        if grep -q "define LOCKDIDM_SUPPORT" include/configure.h; then
            log_info "✓ LOCKDIDM_SUPPORT successfully added to include/configure.h"
        else
            log_error "Failed to add LOCKDIDM_SUPPORT to include/configure.h"
            exit 1
        fi
    else
        log_info "✓ LOCKDIDM_SUPPORT already present in include/configure.h"
    fi
fi

log_info "Building LVM..."
make

if [ $? -ne 0 ]; then
    log_error "LVM build failed"
    exit 1
fi

log_info "LVM build completed successfully"

log_info "Installing LVM (requires sudo)..."
log_warn "WARNING: Installing LVM will replace your system LVM installation"
log_warn "This may cause boot issues if your root filesystem is on LVM"

read -p "Do you want to proceed with LVM installation? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    sudo make install
    
    if [ $? -ne 0 ]; then
        log_error "LVM installation failed"
        exit 1
    fi
    
    log_info "LVM installation completed"
else
    log_info "Skipping LVM installation"
fi

echo
log_info "========================================="
log_info "Build completed successfully!"
log_info "========================================="
log_info "Propeller IDM Lock Manager: Installed"
log_info "LVM with IDM support: Built (and optionally installed)"
log_info ""
log_info "Next steps:"
log_info "1. Start the IDM lock manager: sudo systemctl start seagate_ilm"
log_info "2. Configure lvmlockd to use IDM: edit /usr/lib/systemd/system/lvm2-lvmlockd.service"
log_info "3. Start lvmlockd: sudo systemctl start lvm2-lvmlockd"
log_info ""
log_info "For more information, see: $PROPELLER_DIR/doc/lvm_propeller_install.md"
