#!/bin/bash
#------------------------------------------------------------------------------
# Script for downloading, preparing, and flashing a specified Jetson Linux
# (L4T) release on Nvidia Orin Nano using Fedora for the host system.
#------------------------------------------------------------------------------

version=1.0

L4T_DOWNLOADS_URL="https://developer.nvidia.com/downloads/embedded/l4t"
L4T_DIR="${PWD}/Linux_for_Tegra"

get_l4t=false
overlay_tarball_path=""
flash_l4t=false
l4t_version=""

BLACK=$(tput setaf 0)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
LIME_YELLOW=$(tput setaf 190)
POWDER_BLUE=$(tput setaf 153)
BLUE=$(tput setaf 4)
MAGENTA=$(tput setaf 5)
CYAN=$(tput setaf 6)
WHITE=$(tput setaf 7)
BRIGHT=$(tput bold)
NORMAL=$(tput sgr0)
BOLD=$(tput bold)
BLINK=$(tput blink)
REVERSE=$(tput smso)
UNDERLINE=$(tput smul)

main ()
{
    parse_args ${1+"$@"}

    # Must either get or flash L4T.
    if [ "$get_l4t" = false ] && [ "$flash_l4t" = false ]; then
        echo "Please specify whether to get and/or flash L4T.${NORMAL}"
        exit 1
    fi

    # Check for no L4T version supplied.
    if [ "$get_l4t" = true ] && [ "${l4t_version}" = "" ]; then
        echo "No L4T release version supplied."
        exit 1
    fi

    # Check for alpha characters in the version.
    nodots="${l4t_version//.}"
    if [ "$get_l4t" = true ]; then
        if [[ $nodots =~ [^[:digit:]] ]]; then
            echo "L4T release version should contain no alphas."
            exit 1
        fi

        # Get the dot-separated version numbers.
        IFS="." tokens=( ${l4t_version} )
        l4t_version_1=${tokens[0]}
        l4t_version_2=${tokens[1]}
        l4t_version_3=${tokens[2]}

        echo ""
        echo "${BOLD}Jetson release version: ${YELLOW}${l4t_version_1}.${l4t_version_2}.${l4t_version_3}${NORMAL}"
    fi

    # If we're going to flash, need to have a prepared L4T directory.
    if [ "$flash_l4t" = true ]  && [ ! -d "${L4T_DIR}" ]; then
        echo "L4T release directory not present."
        exit 1
    fi 

    # Get and prepare an L4T directory.
    if [ "$get_l4t" = true ]; then
        set_environment_variables
        get_l4t_release_and_rootfs
        setup_rootfs
        install_rpm_packages_for_flashing
    fi

    # Flash a prepared L4T directory.
    if [ "$flash_l4t" = true ]; then
        check_forced_recovery_mode
        flash_nvme_ssd
        cleanup
    fi

    exit 0
}

show_usage ()
{
    echo ""
    echo "Usage: sudo `basename $0` [-v <L4T_version> [Options}"
    echo "  Options:"
    echo "  -f    Flash the L4T release that was prepared."
    echo "  -g    Get the L4T release, extract it, and prepare for flashing."
    echo "  -h    Show help"
    echo "  -o    Overlay L4T directory with a specified tarball."
    echo ""
}

show_help ()
{
    echo "This script is for preparing and flashing a specified Jetson Linux"
    echo "(L4T) release on Orin Nano using a Fedora 38 host system."
    show_usage
}

parse_args ()
{
    while getopts "v:o:gfh" opt
    do
        case "$opt" in
            f)
                flash_l4t=true
                ;;
            g)
                get_l4t=true
                ;;
            o)
                overlay_tarball_path="${OPTARG}"
                ;;
            v)
                l4t_version="${OPTARG}"
                ;;
            h | *)
                show_help
                exit 1
                ;;
        esac
    done
}

set_environment_variables ()
{
    echo ""
    echo "${BOLD}Setting environment variables...${NORMAL}"
    export L4T_RELEASE_VERSION="R$l4t_version"
    export L4T_RELEASE_PACKAGE="Jetson_Linux_$L4T_RELEASE_VERSION_aarch64.tbz2"
    export SAMPLE_FS_PACKAGE="Tegra_Linux_Sample-Root-Filesystem_$L4T_RELEASE_VERSION_aarch64.tbz2"
    export BOARD="jetson-orin-nano-devkit"
    export LDK_ROOTFS_DIR="${L4T_DIR}/rootfs"
}

get_l4t_release_and_rootfs ()
{
    # Remove the prior extracted L4T release tarball.
    echo ""
    echo "${BOLD}Removing old L4T files...${NORMAL}"
    rm -rf "${L4T_DIR}"

    # Download the L4T release tarball.
    echo ""
    echo "${BOLD}Downloading L4T release tarball...${NORMAL}"
    wget -N https://developer.nvidia.com/downloads/embedded/l4t/r"${l4t_version_1}"_release_v"${l4t_version_2}"."${l4t_version_3}"/release/jetson_linux_r"${l4t_version}"_aarch64.tbz2
    wget -N "${L4T_DOWNLOADS_URL}"/r"${l4t_version_1}"_release_v"${l4t_version_2}"."${l4t_version_3}"/release/jetson_linux_r"${l4t_version}"_aarch64.tbz2

    # Download L4T sample rootfs tarball.
    echo ""
    echo "${BOLD}Downloading L4T example rootfs tarball...${NORMAL}"
    wget -N "${L4T_DOWNLOADS_URL}"/r"${l4t_version_1}"_release_v"${l4t_version_2}"."${l4t_version_3}"/release/tegra_linux_sample-root-filesystem_r"${l4t_version}"_aarch64.tbz2

    # Extract the L4T release tarball.
    echo ""
    echo "${BOLD}Extracting L4T release tarball...${NORMAL}"
    tar -xpvf jetson_linux_r"${l4t_version}"_aarch64.tbz2
}

setup_rootfs ()
{
    # Extract the L4T sample rootfs tarball.
    echo ""
    echo "${BOLD}Extracting L4T example rootfs tarball...${NORMAL}"
    tar -xpvf tegra_linux_sample-root-filesystem_r"${l4t_version}"_aarch64.tbz2 -C ${LDK_ROOTFS_DIR}

    # Run NVIDIA's script for copying binaries to the rootfs.
    echo ""
    echo "${BOLD}Copying binaries to rootfs...${NORMAL}"
    ${L4T_DIR}/apply_binaries.sh

    # Overlay rootfs with files from a specified directory.
    if [ ! "${overlay_tarball_path}" = "" ]; then
        echo "${BOLD}Overlaying rootfs with tarball: ${overlay_tarball_path}${NORMAL}"
        tar -xpvf "${overlay_tarball_path}" -C ${PWD}
        if [ $? -ne 0 ]; then
            echo "${RED}Failed to extract overlay tarball.${NORMAL}"
            exit 1
        fi
    fi
}

install_rpm_packages_for_flashing ()
{
    echo ""
    echo "${BOLD}Installing RPM packages for flashing...${NORMAL}"
    dnf groupinstall -y "Development Tools"
    dnf group install --with-optional -y virtualization
    dnf install -y qemu qemu-user qemu-user-static
    dnf install -y abootimg \
                        qemu-user-binfmt \
                        dtc \
                        dosfstools \
                        lbzip2 \
                        libxml2 \
                        nfs-utils \
                        libnfsidmap \
                        sssd-nfs-idmap \
                        python3-yaml \
                        sshpass \
                        udev \
                        util-linux \
                        whois \
                        openssl \
                        cpio \
                        python2 \
                        lz4

    # Create a symbolic link so that NVIDIA's scripts can refer to
    # nfs-kernel-server, though Fedora has nfs-server.
    ln -sf /usr/lib/systemd/system/nfs-server.service /usr/lib/systemd/system/nfs-kernel-server.service
}

check_forced_recovery_mode ()
{
    echo "${BOLD}Checking if board is in Forced Recovery Mode...${NORMAL}"
    board_id=$($L4T_DIR/nvautoflash.sh --print_boardid)
    last_line=$(echo "$board_id" | tail -n 1)
    board_id=${last_line::-7}
    if [[ "$board_id" == "jetson-orin-nano-devkit" ]]; then
        echo "${BOLD}${GREEN}$board_id${NORMAL}"
    else
        echo "${BOLD}${RED}The board is not connected or not in Forced Recovery Mode.${NORMAL}"
        exit 1
    fi
    echo ""
}

flash_nvme_ssd ()
{
    # Turn off USB mass storage during flashing
    sudo systemctl stop udisks2.service

    echo "${L4T_DIR}/rootfs *(rw,sync,insecure,no_root_squash)" > /etc/exports
    echo "${L4T_DIR}/tools/kernel_flash/images *(rw,sync,insecure,no_root_squash)" >> /etc/exports 
    /usr/sbin/exportfs -avr
    systemctl enable --now nfs-server

    echo "${BOLD}Flashing NVMe SSD...${NORMAL}"
    cd $L4T_DIR
    ./tools/kernel_flash/l4t_initrd_flash.sh \
        --external-device nvme0n1p1 \
        -c tools/kernel_flash/flash_l4t_external.xml \
        -p "-c bootloader/t186ref/cfg/flash_t234_qspi.xml" \
        --showlogs --network usb0 jetson-orin-nano-devkit internal
}

cleanup ()
{
    sudo systemctl start udisks2.service
}

# Invoke main
main ${1+"$@"}
