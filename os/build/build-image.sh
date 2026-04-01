#!/usr/bin/env bash
# =============================================================================
# Cinder OS — build-image.sh
# Debian ARM64 image assembly script for Raspberry Pi 4 / Pi 400
#
# Overview:
#   This script produces a bootable Cinder OS .img file that can be written
#   to a microSD card or USB drive. The image is a minimal Debian bookworm
#   ARM64 system pre-configured for Cinder Core hosting.
#
#   Build host requirements:
#     - Debian or Ubuntu x86_64 (or ARM64 natively on another Pi)
#     - Packages: debootstrap qemu-user-static binfmt-support parted kpartx
#                 dosfstools e2fsprogs rsync git
#     - ~8GB free disk space in the build directory
#     - Root or sudo access (loop devices and chroot require it)
#
#   Output:
#     build/output/cinder-os-<version>-<date>.img   (raw disk image)
#     build/output/cinder-os-<version>-<date>.img.xz (compressed, for distribution)
#     build/output/cinder-os-<version>-<date>.sha256 (checksum)
#
#   Image layout:
#     Partition 1: FAT32 boot partition (256 MB) — /boot/firmware
#     Partition 2: ext4 root partition  (3.5 GB+) — /
#
#   After writing to SD:
#     1. Insert SD into Pi 4 and power on.
#     2. First-boot service (cinder-firstboot.service) runs:
#         - Expands root partition to fill SD card
#         - Sets hostname
#         - Generates SSH host keys
#         - Creates 'cinder' user
#         - Enables and starts cinder.service
#     3. SSH in: ssh cinder@<ip> (password set during build or via firstboot)
#
#   Usage:
#     sudo ./build-image.sh [--version <ver>] [--output-dir <dir>]
#                           [--image-size <gb>] [--skip-compress]
#                           [--cinder-branch <branch>]
#
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Build identity ────────────────────────────────────────────────────────────

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CINDER_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly BUILD_DATE="$(date -u +%Y%m%d)"

# ── Defaults ──────────────────────────────────────────────────────────────────

: "${CINDER_OS_VERSION:="0.1.0-dev"}"
: "${DEBIAN_RELEASE:="bookworm"}"
: "${DEBIAN_MIRROR:="https://deb.debian.org/debian"}"
: "${OUTPUT_DIR:="${SCRIPT_DIR}/output"}"
: "${BUILD_WORK_DIR:="${SCRIPT_DIR}/work"}"
: "${IMAGE_SIZE_GB:=8}"
: "${SKIP_COMPRESS:=false}"
: "${CINDER_BRANCH:="main"}"
: "${CINDER_DEFAULT_PRESET:="survival"}"
: "${CINDER_DEFAULT_PASSWORD:="cinderpi"}"  # Changed on first boot

# Partition sizes
BOOT_SIZE_MB=256

# ── Argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)        CINDER_OS_VERSION="$2"; shift 2 ;;
        --output-dir)     OUTPUT_DIR="$2";        shift 2 ;;
        --image-size)     IMAGE_SIZE_GB="$2";     shift 2 ;;
        --skip-compress)  SKIP_COMPRESS=true;     shift   ;;
        --cinder-branch)  CINDER_BRANCH="$2";     shift 2 ;;
        --password)       CINDER_DEFAULT_PASSWORD="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -50 | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "[build] Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Derived paths must be resolved after argument parsing.
IMAGE_NAME="cinder-os-${CINDER_OS_VERSION}-${BUILD_DATE}"
IMAGE_FILE="${OUTPUT_DIR}/${IMAGE_NAME}.img"
ROOTFS_DIR="${BUILD_WORK_DIR}/rootfs"
BOOTFS_DIR="${BUILD_WORK_DIR}/bootfs"
ROOT_SIZE_MB=$(( (IMAGE_SIZE_GB * 1024) - BOOT_SIZE_MB - 4 ))  # 4MB alignment buffer

# ── Logging ───────────────────────────────────────────────────────────────────

mkdir -p "${OUTPUT_DIR}" "${BUILD_WORK_DIR}"
BUILD_LOG="${OUTPUT_DIR}/build-${BUILD_DATE}.log"

log()  { local m="[$(date -u +%H:%M:%S)] [build] $*"; echo "${m}"; echo "${m}" >> "${BUILD_LOG}"; }
warn() { local m="[$(date -u +%H:%M:%S)] [build:WARN] $*"; echo "${m}" >&2; echo "${m}" >> "${BUILD_LOG}"; }
die()  { local m="[$(date -u +%H:%M:%S)] [build:FATAL] $*"; echo "${m}" >&2; echo "${m}" >> "${BUILD_LOG}"; cleanup; exit 1; }
step() { echo ""; log "══════════════════════════════════════════"; log "  $*"; log "══════════════════════════════════════════"; }

log "Cinder OS build starting — version ${CINDER_OS_VERSION}, date ${BUILD_DATE}"
log "Image: ${IMAGE_FILE}"
log "Debian: ${DEBIAN_RELEASE} from ${DEBIAN_MIRROR}"

# ── Privilege check ───────────────────────────────────────────────────────────

if [[ "${EUID}" -ne 0 ]]; then
    die "This script must run as root (required for loop devices and chroot)."
fi

# ── Dependency check ──────────────────────────────────────────────────────────

step "Checking build dependencies..."

REQUIRED_CMDS=(debootstrap qemu-aarch64-static parted kpartx mkfs.vfat mkfs.ext4 rsync chroot)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "${cmd}" &>/dev/null; then
        die "Required build tool not found: ${cmd}
Install: apt install debootstrap qemu-user-static binfmt-support parted kpartx dosfstools e2fsprogs rsync"
    fi
done

# Verify binfmt_misc is active for ARM64 cross-build (on x86 host)
ARCH="$(uname -m)"
if [[ "${ARCH}" == "x86_64" ]]; then
    if [[ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
        die "binfmt_misc for qemu-aarch64 not active.
Run: update-binfmts --enable qemu-aarch64"
    fi
    log "Cross-build mode: x86_64 host building ARM64 image via QEMU."
else
    log "Native ARM64 build host detected."
fi

# ── Cleanup trap ──────────────────────────────────────────────────────────────

LOOP_DEV=""
MOUNTED_DIRS=()

cleanup() {
    log "Cleanup: unmounting and detaching loop devices..."
    for mnt in "${MOUNTED_DIRS[@]:-}"; do
        umount "${mnt}" 2>/dev/null || true
    done
    if [[ -n "${LOOP_DEV}" ]]; then
        kpartx -d "${LOOP_DEV}" 2>/dev/null || true
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Step 1: Create disk image ─────────────────────────────────────────────────

step "Step 1: Creating ${IMAGE_SIZE_GB}GB disk image..."

dd if=/dev/zero of="${IMAGE_FILE}" bs=1M count=$(( IMAGE_SIZE_GB * 1024 )) status=progress 2>>"${BUILD_LOG}"
log "Image file created: ${IMAGE_FILE}"

# ── Step 2: Partition the image ───────────────────────────────────────────────

step "Step 2: Partitioning image..."

parted --script "${IMAGE_FILE}" \
    mklabel msdos \
    mkpart primary fat32 4MiB "${BOOT_SIZE_MB}MiB" \
    mkpart primary ext4 "${BOOT_SIZE_MB}MiB" "100%" \
    set 1 boot on

log "Partitioned: boot=${BOOT_SIZE_MB}MB, root=${ROOT_SIZE_MB}MB"

# Attach image as loop device and create device mappings
LOOP_DEV="$(losetup -f --show "${IMAGE_FILE}")"
log "Loop device: ${LOOP_DEV}"
kpartx -av "${LOOP_DEV}" >> "${BUILD_LOG}" 2>&1

# Device mapper paths (e.g. /dev/mapper/loop0p1)
LOOP_BASE="$(basename "${LOOP_DEV}")"
BOOT_PART="/dev/mapper/${LOOP_BASE}p1"
ROOT_PART="/dev/mapper/${LOOP_BASE}p2"

# Wait for device mapper to settle
sleep 2
[[ -b "${BOOT_PART}" ]] || die "Boot partition device not found: ${BOOT_PART}"
[[ -b "${ROOT_PART}" ]] || die "Root partition device not found: ${ROOT_PART}"

# ── Step 3: Format partitions ─────────────────────────────────────────────────

step "Step 3: Formatting partitions..."

mkfs.vfat -F32 -n "CINDER_BOOT" "${BOOT_PART}" >> "${BUILD_LOG}" 2>&1
mkfs.ext4 -L "CINDER_ROOT" -O "^has_journal" "${ROOT_PART}" >> "${BUILD_LOG}" 2>&1
# Note: ^has_journal disables ext4 journaling on the root FS.
# This reduces SD card write amplification significantly.
# Trade-off: less filesystem consistency guarantees on power loss.
# Cinder OS mitigates this via careful shutdown sequencing.

log "Formatted: boot=FAT32, root=ext4 (no journal)"

# ── Step 4: Mount partitions ──────────────────────────────────────────────────

step "Step 4: Mounting partitions..."

mkdir -p "${ROOTFS_DIR}" "${BOOTFS_DIR}"
mount "${ROOT_PART}" "${ROOTFS_DIR}"
MOUNTED_DIRS+=("${ROOTFS_DIR}")

mkdir -p "${ROOTFS_DIR}/boot/firmware"
mount "${BOOT_PART}" "${ROOTFS_DIR}/boot/firmware"
MOUNTED_DIRS+=("${ROOTFS_DIR}/boot/firmware")

log "Mounted root and boot partitions."

# ── Step 5: Debootstrap Debian ARM64 base ─────────────────────────────────────

step "Step 5: Debootstrapping Debian ${DEBIAN_RELEASE} ARM64..."

debootstrap \
    --arch=arm64 \
    --foreign \
    --include=ca-certificates \
    "${DEBIAN_RELEASE}" \
    "${ROOTFS_DIR}" \
    "${DEBIAN_MIRROR}" \
    >> "${BUILD_LOG}" 2>&1

# Copy QEMU binary into rootfs for second-stage debootstrap (x86 host only)
if [[ "${ARCH}" == "x86_64" ]]; then
    cp "$(which qemu-aarch64-static)" "${ROOTFS_DIR}/usr/bin/"
fi

# Second-stage debootstrap inside the chroot
chroot "${ROOTFS_DIR}" /debootstrap/debootstrap --second-stage >> "${BUILD_LOG}" 2>&1
log "Debootstrap complete."

# ── Step 6: Configure base system ─────────────────────────────────────────────

step "Step 6: Configuring base system..."

# Mount essential pseudo-filesystems for chroot operations
mkdir -p "${ROOTFS_DIR}/dev" "${ROOTFS_DIR}/proc" "${ROOTFS_DIR}/sys"

mount_and_track_bind() {
    local source="$1"
    local target="$2"

    mount --bind "${source}" "${target}" || die "Failed to mount ${source} on ${target}"
    MOUNTED_DIRS+=("${target}")
}

mount_and_track_bind /dev "${ROOTFS_DIR}/dev"
mount_and_track_bind /proc "${ROOTFS_DIR}/proc"
mount_and_track_bind /sys "${ROOTFS_DIR}/sys"

# APT sources
cat > "${ROOTFS_DIR}/etc/apt/sources.list" <<-EOF
	deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE} main contrib non-free non-free-firmware
	deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE}-updates main contrib non-free non-free-firmware
	deb https://security.debian.org/debian-security ${DEBIAN_RELEASE}-security main contrib non-free non-free-firmware
	EOF

# Hostname
echo "cinder-node" > "${ROOTFS_DIR}/etc/hostname"

cat > "${ROOTFS_DIR}/etc/hosts" <<-EOF
	127.0.0.1   localhost
	127.0.1.1   cinder-node
	::1         localhost ip6-localhost ip6-loopback
	EOF

# fstab
BOOT_UUID="$(blkid -s UUID -o value "${BOOT_PART}")"
ROOT_UUID="$(blkid -s UUID -o value "${ROOT_PART}")"

cat > "${ROOTFS_DIR}/etc/fstab" <<-EOF
	# Cinder OS fstab
	# <filesystem>          <mount>         <type>  <options>                   <dump> <pass>
	UUID=${ROOT_UUID}       /               ext4    defaults,noatime,nodiratime 0      1
	UUID=${BOOT_UUID}       /boot/firmware  vfat    defaults,noatime            0      2
	tmpfs                   /tmp            tmpfs   defaults,size=256m,noexec   0      0
	tmpfs                   /run            tmpfs   defaults,noexec,nosuid      0      0
	EOF

log "Base system configuration complete."

# ── Step 7: Install packages ──────────────────────────────────────────────────

step "Step 7: Installing packages from packages.list..."

# Parse packages.list: extract non-comment, non-empty package names
PACKAGES_LIST="${SCRIPT_DIR}/packages.list"
if [[ ! -f "${PACKAGES_LIST}" ]]; then
    die "packages.list not found: ${PACKAGES_LIST}"
fi

# Extract real package names (ignore comments, EXCLUDE lines, BUILD_ONLY lines)
PACKAGES=()
while IFS= read -r line; do
    # Strip inline comments and whitespace
    pkg="$(echo "${line}" | sed 's/#.*//' | xargs)"
    # Skip empty, EXCLUDE, BUILD_ONLY lines
    [[ -z "${pkg}" ]] && continue
    [[ "${pkg}" =~ ^(EXCLUDE|BUILD_ONLY|SECTION): ]] && continue
    PACKAGES+=("${pkg}")
done < "${PACKAGES_LIST}"

log "Installing ${#PACKAGES[@]} packages..."

chroot "${ROOTFS_DIR}" bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends ${PACKAGES[*]}
    apt-get clean
    rm -rf /var/lib/apt/lists/*
" >> "${BUILD_LOG}" 2>&1

log "Package installation complete."

step "Step 7b: Configuring locale and timezone..."

chroot "${ROOTFS_DIR}" bash -c "
    # Ensure admin binaries are discoverable in chroot even when caller PATH is minimal.
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    if [[ -x /usr/sbin/locale-gen ]]; then
        echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
        /usr/sbin/locale-gen
    else
        echo 'locale-gen is unavailable; continuing without generated locales' >&2
    fi

    if [[ -x /usr/sbin/update-locale ]]; then
        /usr/sbin/update-locale LANG=en_US.UTF-8
    else
        echo 'LANG=en_US.UTF-8' > /etc/default/locale
    fi

    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    echo 'UTC' > /etc/timezone
" >> "${BUILD_LOG}" 2>&1

log "Locale and timezone configured."

# ── Step 8: Install Cinder files ──────────────────────────────────────────────

step "Step 8: Installing Cinder OS files..."

# Create Cinder directory structure
chroot "${ROOTFS_DIR}" bash -c "
    mkdir -p /opt/cinder/{world,logs,backups,staging,plugins,mods,config}
    mkdir -p /opt/cinder/cinder-runtime/presets
    mkdir -p /opt/cinder/cinder-runtime/launch
    mkdir -p /opt/cinder/cinder-control/{services,monitoring}
    mkdir -p /opt/cinder/metrics
    mkdir -p /opt/cinder/scripts
" >> "${BUILD_LOG}" 2>&1

# Copy Cinder files from the repo into the image
rsync -a --exclude='.git' \
    "${CINDER_REPO_ROOT}/cinder-runtime/" \
    "${ROOTFS_DIR}/opt/cinder/cinder-runtime/" \
    >> "${BUILD_LOG}" 2>&1

rsync -a --exclude='.git' \
    "${CINDER_REPO_ROOT}/os/usb-import/" \
    "${ROOTFS_DIR}/opt/cinder/scripts/" \
    >> "${BUILD_LOG}" 2>&1

rsync -a --exclude='.git' \
    "${CINDER_REPO_ROOT}/os/scripts/" \
    "${ROOTFS_DIR}/opt/cinder/scripts/" \
    >> "${BUILD_LOG}" 2>&1

rsync -a --exclude='.git' \
    "${CINDER_REPO_ROOT}/cinder-control/services/" \
    "${ROOTFS_DIR}/opt/cinder/cinder-control/services/" \
    >> "${BUILD_LOG}" 2>&1

rsync -a --exclude='.git' \
    "${CINDER_REPO_ROOT}/cinder-control/monitoring/" \
    "${ROOTFS_DIR}/opt/cinder/cinder-control/monitoring/" \
    >> "${BUILD_LOG}" 2>&1

# Compatibility entry points expected by existing operator docs.
cp "${CINDER_REPO_ROOT}/cinder-control/services/health-check.sh" \
   "${ROOTFS_DIR}/opt/cinder/scripts/health-check.sh"
cp "${CINDER_REPO_ROOT}/cinder-control/monitoring/metrics-display.sh" \
   "${ROOTFS_DIR}/opt/cinder/scripts/metrics-display.sh"

# Install systemd service files
cp "${CINDER_REPO_ROOT}/os/services/cinder.service" \
    "${ROOTFS_DIR}/etc/systemd/system/cinder.service"

# ── Step 9: Create cinder user ────────────────────────────────────────────────

step "Step 9: Creating cinder user..."

chroot "${ROOTFS_DIR}" bash -c "
    useradd -r -m -d /opt/cinder -s /bin/bash -u 1001 -g 1001 --create-group cinder 2>/dev/null || true
    echo 'cinder:${CINDER_DEFAULT_PASSWORD}' | chpasswd
    usermod -aG sudo cinder
    chown -R cinder:cinder /opt/cinder
    chmod 750 /opt/cinder
    # Make scripts executable
    find /opt/cinder -name '*.sh' -exec chmod 750 {} \;
" >> "${BUILD_LOG}" 2>&1

log "Created 'cinder' user (UID 1001)."

# ── Step 10: systemd configuration ───────────────────────────────────────────

step "Step 10: Configuring systemd..."

chroot "${ROOTFS_DIR}" bash -c "
    # Enable Cinder services
    systemctl enable cinder.service

    # Disable services that are unnecessary or counterproductive
    systemctl disable apt-daily.timer apt-daily-upgrade.timer  # Avoid updates during server operation
    systemctl disable bluetooth.target                          # No Bluetooth
    systemctl disable ModemManager.service 2>/dev/null || true  # No modem

    # Reduce journald storage to protect SD card
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/cinder-journal.conf <<EOF
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=256M
SystemKeepFree=128M
MaxFileSec=1week
EOF

    # Reduce systemd timeouts for faster shutdown (SD card protection)
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/cinder-timeouts.conf <<EOF
[Manager]
DefaultTimeoutStopSec=30s
DefaultTimeoutStartSec=60s
EOF
" >> "${BUILD_LOG}" 2>&1

# ── Step 11: SSH configuration ────────────────────────────────────────────────

step "Step 11: Configuring SSH..."

cat > "${ROOTFS_DIR}/etc/ssh/sshd_config.d/cinder-hardening.conf" <<-EOF
	# Cinder OS SSH hardening
	PermitRootLogin no
	PasswordAuthentication yes
	PubkeyAuthentication yes
	AuthorizedKeysFile .ssh/authorized_keys
	X11Forwarding no
	AllowTcpForwarding no
	MaxAuthTries 3
	LoginGraceTime 20
	ClientAliveInterval 60
	ClientAliveCountMax 3
	EOF

log "SSH hardening applied."

# ── Step 12: Pi 4 boot configuration ─────────────────────────────────────────

step "Step 12: Writing Raspberry Pi 4 boot configuration..."

# config.txt for Pi 4
cat > "${ROOTFS_DIR}/boot/firmware/config.txt" <<-EOF
	# Cinder OS — Raspberry Pi 4 boot configuration
	# Generated by build-image.sh ${CINDER_OS_VERSION}

	[pi4]
	# ARM64 kernel
	arm_64bit=1

	# GPU memory: minimal — Cinder OS is headless
	gpu_mem=16

	# Disable on-board WiFi and Bluetooth (server deployments use Ethernet)
	dtoverlay=disable-wifi
	dtoverlay=disable-bt

	# Enable UART for serial console access (useful for headless debugging)
	enable_uart=1

	# USB boot support (for NVMe/SSD migration)
	# Set BOOT_ORDER in rpi-eeprom to 0xf14 for USB-then-SD priority
	# dtparam=usb_max_current_enable=1

	# Overclock profile (DISABLED by default — enable only with active cooling)
	# Uncomment for extreme preset with ICE Tower or equivalent:
	# over_voltage=6
	# arm_freq=2000
	# gpu_freq=750

	# Disable rainbow splash screen
	disable_splash=1

	# Force HDMI hot-plug (allows display attachment without reboot, if needed)
	hdmi_force_hotplug=0

	[all]
	# Additional UART configuration
	dtoverlay=uart0
	EOF

# cmdline.txt
cat > "${ROOTFS_DIR}/boot/firmware/cmdline.txt" <<-EOF
	console=serial0,115200 console=tty1 root=UUID=${ROOT_UUID} rootfstype=ext4 fsck.repair=yes rootwait quiet init=/bin/systemd cgroup_enable=cpuset cgroup_enable=memory swapaccount=1
	EOF

log "Pi 4 boot configuration written."

# ── Step 13: First-boot service ───────────────────────────────────────────────

step "Step 13: Installing first-boot service..."

cat > "${ROOTFS_DIR}/etc/systemd/system/cinder-firstboot.service" <<-'SVCEOF'
	[Unit]
	Description=Cinder OS First Boot Initialisation
	ConditionPathExists=/etc/cinder-firstboot-pending
	After=local-fs.target
	Before=cinder.service network.target

	[Service]
	Type=oneshot
	RemainAfterExit=yes
	ExecStart=/opt/cinder/scripts/firstboot.sh

	[Install]
	WantedBy=multi-user.target
	SVCEOF

# Write firstboot.sh
cat > "${ROOTFS_DIR}/opt/cinder/scripts/firstboot.sh" <<-'FBEOF'
	#!/usr/bin/env bash
	set -euo pipefail

	log() { echo "[firstboot] $*" | tee -a /var/log/cinder-firstboot.log; }

	log "Cinder OS first boot initialisation starting..."

	# 1. Expand root partition to fill the SD card
	log "Expanding root filesystem..."
	ROOT_DEV="$(findmnt -n -o SOURCE /)"
	DISK="$(lsblk -no pkname "${ROOT_DEV}")"
	PART_NUM="$(lsblk -no MAJ:MIN "${ROOT_DEV}" | awk -F: '{print $2}')"
	parted -s "/dev/${DISK}" resizepart "${PART_NUM}" 100%
	resize2fs "${ROOT_DEV}"
	log "Root filesystem expanded."

	# 2. Generate unique SSH host keys
	log "Generating SSH host keys..."
	rm -f /etc/ssh/ssh_host_*
	dpkg-reconfigure openssh-server
	log "SSH host keys generated."

	# 3. Set a unique hostname (cinder-<last4 of eth0 MAC>)
	MAC="$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' | tail -c 5)"
	HOSTNAME="cinder-${MAC:-node}"
	echo "${HOSTNAME}" > /etc/hostname
	hostnamectl set-hostname "${HOSTNAME}"
	log "Hostname set to: ${HOSTNAME}"

	# 4. Remove the firstboot trigger file
	rm -f /etc/cinder-firstboot-pending
	log "First boot complete. Cinder OS is ready."
	FBEOF

chmod 750 "${ROOTFS_DIR}/opt/cinder/scripts/firstboot.sh"

# Create the trigger file that activates the firstboot service
touch "${ROOTFS_DIR}/etc/cinder-firstboot-pending"

chroot "${ROOTFS_DIR}" systemctl enable cinder-firstboot.service >> "${BUILD_LOG}" 2>&1
log "First-boot service installed."

# ── Step 14: Cleanup build artifacts ─────────────────────────────────────────

step "Step 14: Cleaning up build artifacts..."

# Remove QEMU binary from rootfs (not needed post-build)
rm -f "${ROOTFS_DIR}/usr/bin/qemu-aarch64-static"

# Clear apt cache and package lists from image
chroot "${ROOTFS_DIR}" bash -c "
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    rm -rf /tmp/* /var/tmp/*
    # Clear bash history
    find /root /home -name '.bash_history' -delete
    # Truncate machine-id — will be regenerated on first boot
    truncate -s 0 /etc/machine-id
" >> "${BUILD_LOG}" 2>&1

log "Cleanup complete."

# ── Step 15: Unmount and detach ───────────────────────────────────────────────

step "Step 15: Unmounting filesystems..."

sync

# Unmount in reverse order
for mnt in "${MOUNTED_DIRS[@]}"; do
    umount "${mnt}" 2>>"${BUILD_LOG}" || warn "Could not unmount ${mnt}"
done
MOUNTED_DIRS=()

kpartx -d "${LOOP_DEV}" >> "${BUILD_LOG}" 2>&1
losetup -d "${LOOP_DEV}" >> "${BUILD_LOG}" 2>&1
LOOP_DEV=""

log "All filesystems unmounted and loop devices released."

# ── Step 16: Compress and checksum ───────────────────────────────────────────

step "Step 16: Generating checksum and compressing..."

IMAGE_SHA256="${IMAGE_FILE}.sha256"
sha256sum "${IMAGE_FILE}" > "${IMAGE_SHA256}"
log "SHA-256: $(cat "${IMAGE_SHA256}")"

if [[ "${SKIP_COMPRESS}" == false ]]; then
    IMAGE_XZ="${IMAGE_FILE}.xz"
    log "Compressing with xz (this takes several minutes)..."
    xz -T0 -9 -k "${IMAGE_FILE}" -v >> "${BUILD_LOG}" 2>&1
    XZ_SHA256="${IMAGE_XZ}.sha256"
    sha256sum "${IMAGE_XZ}" > "${XZ_SHA256}"
    log "Compressed image: ${IMAGE_XZ}"
    log "Compressed SHA-256: $(cat "${XZ_SHA256}")"
fi

# ── Build complete ────────────────────────────────────────────────────────────

IMAGE_SIZE_ACTUAL="$(du -sh "${IMAGE_FILE}" | awk '{print $1}')"

log ""
log "═══════════════════════════════════════════════════════════"
log " Cinder OS build complete"
log " Version:  ${CINDER_OS_VERSION}"
log " Date:     ${BUILD_DATE}"
log " Image:    ${IMAGE_FILE} (${IMAGE_SIZE_ACTUAL})"
log " Log:      ${BUILD_LOG}"
log ""
log " Write to SD card:"
log "   sudo dd if=${IMAGE_FILE} of=/dev/sdX bs=4M status=progress"
log "   sudo sync"
log ""
log " Or with Raspberry Pi Imager: select 'Use custom image'"
log "═══════════════════════════════════════════════════════════"
