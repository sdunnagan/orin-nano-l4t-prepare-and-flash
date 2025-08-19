#!/bin/bash
#------------------------------------------------------------------------------
# orin-nano-l4t-prepare-and-flash.sh  (v1.6)
#
# Prepare and flash Jetson Linux (L4T) to NVMe on Jetson Orin Nano from a
# Fedora 40 host.
#
# Example:
#   sudo ./orin-nano-l4t-prepare-and-flash.sh -g -v 36.4.4
#   sudo ./orin-nano-l4t-prepare-and-flash.sh -f
#
# Notes:
# - "Super" on Orin Nano means higher clocks/bandwidth within Orin Nano’s
#   15 W envelope on JetPack 6.
# - Rootfs flashed to NVMe using NVIDIA's initrd-based external storage
#   workflow; QSPI boot firmware updated on-module; no SD card required.
# - If native apply_binaries fails, use an Ubuntu 22.04 container.
# - Ensure kernel modules exist; if not, extract NVIDIA kernel packages.
# - Install a boot service that selects the highest available nvpmodel
#   (15 W on Orin Nano) and runs jetson_clocks each boot.
# - Use USB gadget NIC name "usb0".
#------------------------------------------------------------------------------

set -euo pipefail

version=1.6

L4T_DOWNLOADS_URL="https://developer.nvidia.com/downloads/embedded/l4t"
L4T_DIR="${PWD}/Linux_for_Tegra"

get_l4t=false
overlay_tarball_path=""
flash_l4t=false
l4t_version=""
force_container=false

# Colors (best-effort)
RED=$(tput setaf 1 || true)
GREEN=$(tput setaf 2 || true)
YELLOW=$(tput setaf 3 || true)
WHITE=$(tput setaf 7 || true)
BOLD=$(tput bold || true)
NORMAL=$(tput sgr0 || true)

main () {
    require_root
    require_tools
    parse_args ${1+"$@"}

    if [ "$get_l4t" = false ] && [ "$flash_l4t" = false ]; then
        echo "Please specify whether to get and/or flash L4T.${NORMAL}"
        exit 1
    fi

    if [ "$get_l4t" = true ] && [ -z "${l4t_version}" ]; then
        echo "No L4T release version supplied."
        exit 1
    fi

    if [ "$get_l4t" = true ]; then
        validate_version "$l4t_version"
        set_environment_variables
        get_l4t_release_and_rootfs
        setup_rootfs
        install_rpm_packages_for_flashing
        apply_binaries_portable              # native first; container fallback
        ensure_kernel_modules_present        # force-extract kernel debs if needed
        install_super_boot_unit              # highest nvpmodel + jetson_clocks each boot
    fi

    if [ "$flash_l4t" = true ]; then
        check_forced_recovery_mode
        ensure_firewalld_off_hint
        flash_nvme_ssd
        cleanup
    fi
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "${RED}Please run as root (sudo).${NORMAL}"
        exit 1
    fi
}

require_tools() {
    for t in wget tar lsusb ip awk sed grep find; do
        if ! command -v "$t" >/dev/null 2>&1; then
            echo "${RED}Missing required tool: $t${NORMAL}"
            echo "Install it and re-run."
            exit 1
        fi
    done
}

validate_version () {
    local v="$1"
    local nodots="${v//.}"
    if [[ $nodots =~ [^[:digit:]] ]]; then
        echo "L4T release version should contain digits only (e.g., 36.4.4)."
        exit 1
    fi
    IFS="." read -r l4t_version_1 l4t_version_2 l4t_version_3 <<< "$v"
    export l4t_version_1 l4t_version_2 l4t_version_3
    echo ""
    echo "${BOLD}Jetson release version: ${YELLOW}${l4t_version_1}.${l4t_version_2}.${l4t_version_3}${NORMAL}"
}

show_usage () {
    echo ""
    echo "Usage: sudo $(basename "$0") -v <L4T_version> [Options]"
    echo "  Options:"
    echo "  -f        Flash the prepared L4T release to NVMe."
    echo "  -g        Get the L4T release and prepare for flashing."
    echo "  -h        Show help."
    echo "  -o PATH   Overlay L4T dir with a specified tarball."
    echo "  -C        Force container for apply_binaries (skip native attempt)."
    echo ""
}

show_help () {
    echo "Prepare & flash a specified Jetson Linux (L4T) release on Orin Nano (Fedora host)."
    show_usage
}

parse_args () {
    while getopts "v:o:gfhC" opt; do
        case "$opt" in
            f) flash_l4t=true ;;
            g) get_l4t=true ;;
            o) overlay_tarball_path="${OPTARG}" ;;
            v) l4t_version="${OPTARG}" ;;
            C) force_container=true ;;
            h|*) show_help; exit 1 ;;
        esac
    done
}

set_environment_variables () {
    echo ""
    echo "${BOLD}Setting environment variables...${NORMAL}"
    export L4T_RELEASE_VERSION="R${l4t_version}"
    export L4T_RELEASE_PACKAGE="Jetson_Linux_${L4T_RELEASE_VERSION}_aarch64.tbz2"
    export SAMPLE_FS_PACKAGE="Tegra_Linux_Sample-Root-Filesystem_${L4T_RELEASE_VERSION}_aarch64.tbz2"
    export BOARD="jetson-orin-nano-devkit"   # box not labeled “Super”
    export LDK_ROOTFS_DIR="${L4T_DIR}/rootfs"
}

get_l4t_release_and_rootfs () {
    echo ""
    echo "${BOLD}Removing old L4T files...${NORMAL}"
    rm -rf "${L4T_DIR}"

    echo ""
    echo "${BOLD}Downloading L4T release tarballs...${NORMAL}"
    wget -N "${L4T_DOWNLOADS_URL}/r${l4t_version_1}_release_v${l4t_version_2}.${l4t_version_3}/release/jetson_linux_r${l4t_version}_aarch64.tbz2"
    wget -N "${L4T_DOWNLOADS_URL}/r${l4t_version_1}_release_v${l4t_version_2}.${l4t_version_3}/release/tegra_linux_sample-root-filesystem_r${l4t_version}_aarch64.tbz2"

    echo ""
    echo "${BOLD}Extracting L4T release tarball...${NORMAL}"
    tar -xpvf "jetson_linux_r${l4t_version}_aarch64.tbz2"
}

setup_rootfs () {
    echo ""
    echo "${BOLD}Extracting sample rootfs...${NORMAL}"
    mkdir -p "${LDK_ROOTFS_DIR}"
    tar -xpvf "tegra_linux_sample-root-filesystem_r${l4t_version}_aarch64.tbz2" -C "${LDK_ROOTFS_DIR}"

    if [ -n "${overlay_tarball_path}" ]; then
        echo "${BOLD}Overlaying L4T directory with: ${overlay_tarball_path}${NORMAL}"
        tar -xpvf "${overlay_tarball_path}" -C "${PWD}"
    fi
}

install_rpm_packages_for_flashing () {
    echo ""
    echo "${BOLD}Installing RPM packages for flashing...${NORMAL}"
    dnf groupinstall -y "Development Tools"
    dnf group install --with-optional -y virtualization || true

    dnf install -y qemu qemu-user qemu-user-static \
                   abootimg qemu-user-binfmt dtc dosfstools lbzip2 libxml2 \
                   nfs-utils libnfsidmap sssd-nfs-idmap python3-yaml sshpass udev \
                   util-linux whois openssl cpio lz4 \
                   bzip2 xz unzip parted gdisk pv dpkg

    # Fedora uses nfs-server; create alias for nfs-kernel-server
    ln -sf /usr/lib/systemd/system/nfs-server.service /usr/lib/systemd/system/nfs-kernel-server.service
}

apply_binaries_portable () {
    echo ""
    echo "${BOLD}Applying NVIDIA binaries...${NORMAL}"

    if $force_container; then
        echo "${YELLOW}(Forced container mode)${NORMAL}"
        run_apply_binaries_in_container
        return
    fi

    # Try native first; if it fails, fall back to container.
    set +e
    pushd "${L4T_DIR}" >/dev/null
    systemctl restart systemd-binfmt || true
    ./apply_binaries.sh
    rc=$?
    popd >/dev/null
    set -e

    if [ $rc -eq 0 ]; then
        echo "${GREEN}apply_binaries.sh completed natively.${NORMAL}"
    else
        echo "${YELLOW}Native apply_binaries failed (rc=$rc). Falling back to Ubuntu 22.04 container...${NORMAL}"
        run_apply_binaries_in_container
    fi
}

pick_container_runtime () {
    if command -v podman >/dev/null 2>&1; then
        echo "podman"
        return
    fi
    if command -v docker >/dev/null 2>&1; then
        echo "docker"
        return
    fi
    echo ""
}

run_apply_binaries_in_container () {
    local runtime
    runtime="$(pick_container_runtime)"
    if [ -z "$runtime" ]; then
        echo "${RED}No container runtime found (podman/docker). Install one or rerun with -C after installing.${NORMAL}"
        exit 1
    fi

    echo "${BOLD}Running apply_binaries.sh inside Ubuntu 22.04 container (${runtime})...${NORMAL}"
    if [ "$runtime" = "podman" ]; then
        podman run --rm -it --privileged \
            -v "$PWD":/work -w /work/Linux_for_Tegra \
            ubuntu:22.04 bash -lc '
                set -e
                export DEBIAN_FRONTEND=noninteractive
                apt update
                apt install -y qemu-user-static binfmt-support bzip2 xz-utils ca-certificates sudo
                update-binfmts --enable qemu-aarch64 || true
                ./apply_binaries.sh
            '
    else
        docker run --rm -it --privileged \
            -v "$PWD":/work -w /work/Linux_for_Tegra \
            ubuntu:22.04 bash -lc '
                set -e
                export DEBIAN_FRONTEND=noninteractive
                apt update
                apt install -y qemu-user-static binfmt-support bzip2 xz-utils ca-certificates sudo
                update-binfmts --enable qemu-aarch64 || true
                ./apply_binaries.sh
            '
    fi
    echo "${GREEN}apply_binaries.sh completed in container.${NORMAL}"
}

ensure_kernel_modules_present () {
    echo ""
    echo "${BOLD}Verifying kernel modules in rootfs...${NORMAL}"
    if [ -d "${LDK_ROOTFS_DIR}/lib/modules" ] && [ -n "$(ls -A "${LDK_ROOTFS_DIR}/lib/modules" 2>/dev/null)" ]; then
        echo "${GREEN}Kernel modules present.${NORMAL}"
        return
    fi

    echo "${YELLOW}Kernel modules missing. Extracting kernel debs directly into rootfs...${NORMAL}"
    rm -rf "${LDK_ROOTFS_DIR}/lib/modules" || true

    local extracted=0
    while IFS= read -r -d '' deb; do
        echo "Extracting $(basename "$deb")"
        dpkg-deb -x "$deb" "${LDK_ROOTFS_DIR}/"
        extracted=$((extracted+1))
    done < <(find "${L4T_DIR}/nv_tegra" -type f -print0 | \
             grep -zE 'nvidia-l4t-(kernel(-image|-dtbs)?|initrd).*_arm64\.deb$' || true)

    if [ "$extracted" -eq 0 ]; then
        echo "${RED}Could not locate kernel debs under nv_tegra/.${NORMAL}"
        exit 1
    fi

    if [ ! -d "${LDK_ROOTFS_DIR}/lib/modules" ] || [ -z "$(ls -A "${LDK_ROOTFS_DIR}/lib/modules")" ]; then
        echo "${RED}Kernel modules still not present after extraction.${NORMAL}"
        exit 1
    fi

    echo "${GREEN}Kernel modules extracted.${NORMAL}"
}

install_super_boot_unit () {
    echo ""
    echo "${BOLD}Installing performance boot service (highest nvpmodel + jetson_clocks) into rootfs...${NORMAL}"

    # Helper script that runs on the Jetson at boot
    cat > "${LDK_ROOTFS_DIR}/usr/local/sbin/jetson-super-setup.sh" << 'EOS'
#!/bin/bash
set -euo pipefail
log=/var/log/jetson-super-setup.log
exec >>"$log" 2>&1
echo "[jetson-super-setup] $(date -Is)"

export DEBIAN_FRONTEND=noninteractive

# Ensure required tools are present
if ! command -v nvpmodel >/dev/null 2>&1; then
    apt-get update || true
    apt-get install -y nvidia-l4t-nvpmodel nvidia-l4t-nvfancontrol || true
fi
if ! command -v jetson_clocks >/dev/null 2>&1; then
    apt-get update || true
    apt-get install -y nvidia-l4t-utils || true
fi

# Pick the highest available nvpmodel (by W), fallback to highest Mode ID
pick_highest_mode() {
    local line lastID="" bestID="" bestW=0 w id
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*Mode[[:space:]]+([0-9]+) ]]; then
            id="${BASH_REMATCH[1]}"; lastID="$id"
            if [[ "$line" =~ ([0-9]+)W ]]; then
                w="${BASH_REMATCH[1]}"
                if (( w >= bestW )); then bestW="$w"; bestID="$id"; fi
            fi
        elif [[ -n "$lastID" && "$line" =~ ([0-9]+)W ]]; then
            w="${BASH_REMATCH[1]}"
            if (( w >= bestW )); then bestW="$w"; bestID="$lastID"; fi
        fi
    done < <(nvpmodel -q 2>/dev/null || true)

    if [[ -z "$bestID" ]]; then
        bestID="$(nvpmodel -q --verbose 2>/dev/null | awk "/Mode [0-9]+/ {print \$2}" | tail -n1 || true)"
    fi
    echo "$bestID"
}

target_id="$(pick_highest_mode)"
echo "target_id=${target_id}"

if [[ -n "${target_id}" ]]; then
    echo "Setting nvpmodel to mode ${target_id}"
    nvpmodel -m "${target_id}" || true
else
    echo "Could not determine nvpmodel mode automatically."
fi

# Pin clocks each boot
if command -v jetson_clocks >/dev/null 2>&1; then
    echo "Running jetson_clocks"
    jetson_clocks || true
fi

echo "[jetson-super-setup] done."
EOS
    chmod 755 "${LDK_ROOTFS_DIR}/usr/local/sbin/jetson-super-setup.sh"

    # Systemd unit to run it on boot
    mkdir -p "${LDK_ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants"
    cat > "${LDK_ROOTFS_DIR}/etc/systemd/system/jetson-super-setup.service" << 'EOF'
[Unit]
Description=Enable Jetson Super (highest nvpmodel + performance tuning) at boot
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/jetson-super-setup.sh

[Install]
WantedBy=multi-user.target
EOF
    ln -sf /etc/systemd/system/jetson-super-setup.service \
           "${LDK_ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/jetson-super-setup.service"
}

check_forced_recovery_mode () {
    echo "${BOLD}Checking if board is in Forced Recovery Mode...${NORMAL}"
    local out
    out="$("${L4T_DIR}/nvautoflash.sh" --print_boardid || true)"
    local last_line
    last_line=$(echo "$out" | tail -n 1 || true)
    local board_id="${last_line::-7}"

    if [[ "$board_id" == "jetson-orin-nano-devkit" || "$board_id" == "jetson-orin-nano-devkit-super" ]]; then
        echo "${BOLD}${GREEN}${board_id}${NORMAL}"
    else
        echo "${BOLD}${RED}Board not detected or not in recovery. Check USB-C cable/port and FC REC jumper.${NORMAL}"
        exit 1
    fi
    echo ""
}

ensure_firewalld_off_hint () {
    if systemctl is-active --quiet firewalld; then
        echo "${YELLOW}WARNING:${NORMAL} firewalld is active. NVIDIA initrd flashing uses NFS, which may be blocked."
        echo "         Consider:  sudo systemctl stop firewalld && sudo systemctl disable firewalld && sudo reboot"
        echo "         (Re-enable the firewall after flashing if you like.)"
    fi
}

flash_nvme_ssd () {
    echo ""
    echo "${BOLD}Preparing NFS exports...${NORMAL}"
    systemctl stop udisks2.service || true

    # Ensure images dir exists to avoid exportfs failure
    mkdir -p "${L4T_DIR}/tools/kernel_flash/images"

    printf "%s\n" \
        "${L4T_DIR}/rootfs *(rw,sync,insecure,no_root_squash)" \
        "${L4T_DIR}/tools/kernel_flash/images *(rw,sync,insecure,no_root_squash)" \
        | tee /etc/exports >/dev/null

    exportfs -avr
    systemctl enable --now nfs-server

    # Fixed interface name for the USB gadget NIC
    local HOST_USB_IFACE="usb0"

    echo ""
    echo "${BOLD}Flashing NVMe SSD via interface ${YELLOW}${HOST_USB_IFACE}${NORMAL} ..."
    cd "${L4T_DIR}"

    ./tools/kernel_flash/l4t_initrd_flash.sh \
        --external-device nvme0n1p1 \
        -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
        -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
        --showlogs --network "${HOST_USB_IFACE}" \
        jetson-orin-nano-devkit internal

    echo ""
    echo "${GREEN}${BOLD}Flash complete. On first boot from NVMe:${NORMAL}"
    echo "    sudo apt update && sudo apt full-upgrade -y"
    echo "    # The jetson-super-setup.service will select the highest nvpmodel (15 W on Orin Nano)"
    echo "    # and run jetson_clocks. Logs: /var/log/jetson-super-setup.log"
    echo "    # Verify:"
    echo "    which nvpmodel && sudo nvpmodel -q"
    echo "    sudo tegrastats   # optional: watch clocks/power"
}

cleanup () {
    systemctl start udisks2.service || true
}

# Invoke main
main ${1+"$@"}
