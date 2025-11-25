#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

# A handy tool to flash device with local build or remote build.

# Constants
# Please see go/cl_flashstation

set -euo pipefail

MIX_SCRIPT_NAME="build_mixed_kernels_ramdisk"
DOWNLOAD_PATH="/tmp/downloaded_images"
KERNEL_TF_PREBUILT=prebuilts/tradefed/filegroups/tradefed/tradefed.sh
PLATFORM_TF_PREBUILT=tools/tradefederation/prebuilts/filegroups/tradefed/tradefed.sh
KERNEL_JDK_PATH=prebuilts/jdk/jdk11/linux-x86
PLATFORM_JDK_PATH=prebuilts/jdk/jdk21/linux-x86
LOCAL_JDK_PATH=/usr/local/buildtools/java/jdk11
LOG_DIR=$PWD/out/test_logs/$(date +%Y%m%d_%H%M%S)
MIN_FASTBOOT_VERSION="35.0.2-12583183"
VENDOR_KERNEL_IMGS=("boot.img" "initramfs.img" "dtb.img" "dtbo.img" "vendor_dlkm.img")
SKIP_UPDATE_BOOTLOADER=false
SKIP_BUILD=false
GCOV=false
DEBUG=false
KASAN=false
EXTRA_OPTIONS=()
DEVICE_VARIANT="userdebug"

ABI=
PRODUCT=
BUILD_TYPE=
DEVICE_KERNEL_STRING=
DEVICE_KERNEL_VERSION=
LOCAL_FLASH_CLI=
CL_FLASH_CLI=
SYSTEM_DLKM_INFO=
readonly REQUIRED_COMMANDS=("adb" "dirname" "fastboot")
THROUGH_PONTIS=false

SERIAL_NUMBER=
FASTBOOT_SERIAL_NUMBER=
ADB_SERIAL_NUMBER=
DEVICE_SERIAL_NUMBER=
VENDOR_KERNEL_BUILD=

SYSTEM_BUILD=
PLATFORM_BUILD=
KERNEL_BUILD=
VENDOR_KERNEL_BUILD=

function print_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "This script will build images and flash a physical device."
    echo ""
    echo "Available options:"
    echo "  -s <serial_number>, --serial=<serial_number>"
    echo "                        [Mandatory] The serial number for device to be flashed with."
    echo "  --skip-build          [Optional] Skip the image build step. Will build by default if in repo."
    echo "  --skip-update-bootloader"
    echo "                        [Optional] Skip update bootloader for Anti-Rollback device."
    echo "  --gcov                [Optional] Build gcov enabled kernel"
    echo "  --debug               [Optional] Build debug enabled kernel"
    echo "  --kasan               [Optional] Build kasan enabled kernel"
    echo "  -pb <platform_build>, --platform-build=<platform_build>"
    echo "                        [Optional] The platform build path. Can be a local path or a remote build"
    echo "                        as ab://<branch>/<build_target>/<build_id>."
    echo "                        If not specified and the script is running from a platform repo,"
    echo "                        it will use the platform build in the local repo."
    echo "                        If string 'None' is set, no platform build will be flashed,"
    echo "  -sb <system_build>, --system-build=<system_build>"
    echo "                        [Optional] The system build path for GSI testing. Can be a local path or"
    echo "                        remote build as ab://<branch>/<build_target>/<build_id>."
    echo "                        If not specified, no system build will be used."
    echo "  -kb <kernel_build>, --kernel-build=<kernel_build>"
    echo "                        [Optional] The kernel build path. Can be a local path or a remote build"
    echo "                        as ab://<branch>/<build_target>/<build_id>."
    echo "                        If not specified and the script is running from an Android common kernel repo,"
    echo "                        it will use the kernel in the local repo."
    echo "                        If string 'None' is set, no kernel build will be flashed,"
    echo "  -vkb <vendor_kernel_build>, --vendor-kernel-build=<vendor_kernel_build>"
    echo "                        [Optional] The vendor kernel build path. Can be a local path or a remote build"
    echo "                        as ab://<branch>/<build_target>/<build_id>."
    echo "                        If not specified, and the script is running from a vendor kernel repo, "
    echo "                        it will use the kernel in the local repo."
    echo "                        If string 'None' is set, no vendor kernel build will be flashed,"
    echo "  -vkbt <vendor_kernel_build_target>, --vendor-kernel-build-target=<vendor_kernel_build_target>"
    echo "                        [Optional] The vendor kernel build target to be used to build vendor kernel."
    echo "                        If not specified, and the script is running from a vendor kernel repo, "
    echo "                        it will try to find a local build target in the local repo."
    echo "  --device-variant=<device_variant>"
    echo "                        [Optional] Device variant such as userdebug, user, or eng."
    echo "                        If not specified, will be userdebug by default."
    echo "  -h, --help            Display this help message and exit"
    echo ""
    echo "Examples:"
    echo "$0"
    echo "$0 -s 1C141FDEE003FH"
    echo "$0 -s 1C141FDEE003FH -pb ab://git_main/raven-userdebug/latest"
    echo "$0 -s 1C141FDEE003FH -pb ~/aosp-main"
    echo "$0 -s 1C141FDEE003FH -vkb ~/pixel-mainline -pb ab://git_main/raven-trunk_staging-userdebug/latest"
    echo "$0 -s 1C141FDEE003FH -vkb ab://kernel-android-gs-pixel-mainline/kernel_raviole_kleaf/latest \
-pb ab://git_trunk_pixel_kernel_61-release/raven-userdebug/latest \
-kb ab://aosp_kernel-common-android-mainline/kernel_aarch64/latest"
    echo ""
    exit 0
}

function parse_arg() {
    while test $# -gt 0; do
        case "$1" in
            -h|--help)
                print_help
                ;;
            -s)
                shift
                if test $# -gt 0; then
                    SERIAL_NUMBER=$1
                else
                    log_error "device serial is not specified"
                    exit 1
                fi
                shift
                ;;
            --serial*)
                SERIAL_NUMBER=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            -pb)
                shift
                if test $# -gt 0; then
                    PLATFORM_BUILD=$1
                else
                    log_error "platform build is not specified"
                    exit 1
                fi
                shift
                ;;
            --platform-build=*)
                PLATFORM_BUILD=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            -sb)
                shift
                if test $# -gt 0; then
                    SYSTEM_BUILD=$1
                else
                    log_error "system build is not specified"
                    exit 1
                fi
                shift
                ;;
            --system-build=*)
                SYSTEM_BUILD=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            -kb)
                shift
                if test $# -gt 0; then
                    KERNEL_BUILD=$1
                else
                    log_error "kernel build path is not specified"
                    exit 1
                fi
                shift
                ;;
            --kernel-build=*)
                KERNEL_BUILD=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            -vkb)
                shift
                if test $# -gt 0; then
                    VENDOR_KERNEL_BUILD=$1
                else
                    log_error "vendor kernel build path is not specified"
                    exit 1
                fi
                shift
                ;;
            --vendor-kernel-build=*)
                VENDOR_KERNEL_BUILD=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            -vkbt)
                shift
                if test $# -gt 0; then
                    VENDOR_KERNEL_BUILD_TARGET=$1
                else
                    log_error "vendor kernel build target is not specified"
                    exit 1
                fi
                shift
                ;;
            --vendor-kernel-build-target=*)
                VENDOR_KERNEL_BUILD_TARGET=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            --device-variant=*)
                DEVICE_VARIANT=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            --skip-update-bootloader)
                SKIP_UPDATE_BOOTLOADER=true
                shift
                ;;
            --gcov)
                GCOV=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --kasan)
                KASAN=true
                shift
                ;;
            *)
                log_error "Unsupported flag: $1" >&2
                exit 1
                ;;
        esac
    done
}

function set_platform_repo() {
    log_warn "Build environment target product '${TARGET_PRODUCT}' does not match expected $1. \
    Reset build environment"
    local lunch_cli="source build/envsetup.sh && lunch $1"
    if [ -f "build/release/release_configs/trunk_staging.textproto" ]; then
        lunch_cli+="-trunk_staging-$DEVICE_VARIANT"
    else
        lunch_cli+="-$DEVICE_VARIANT"
    fi
    log_info "Setup build environment with: $lunch_cli"
    eval "$lunch_cli"
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
        log_info "$lunch_cli succeeded"
    else
        log_error "$lunch_cli failed"
        exit 1
    fi
}

function find_repo() {
    manifest_output=$(grep -e "superproject" -e "gs-pixel" -e "kernel/private/devices/google/common" \
     -e "private/google-modules/soc/gs" -e "kernel/common" -e "common-modules/virtual-device" \
     .repo/manifests/default.xml)
    case "$manifest_output" in
        *platform/superproject*)
            PLATFORM_REPO_ROOT="$PWD"
            if [ -z "$PLATFORM_BUILD" ]; then
                PLATFORM_VERSION=$(grep -e "platform/superproject" .repo/manifests/default.xml | \
                grep -oP 'revision="\K[^"]*')
                log_info "PLATFORM_REPO_ROOT=$PLATFORM_REPO_ROOT, PLATFORM_VERSION=$PLATFORM_VERSION"
                PLATFORM_BUILD="$PLATFORM_REPO_ROOT"
            fi
            ;;
        *kernel/private/devices/google/common*|*private/google-modules/soc/gs*)
            VENDOR_KERNEL_REPO_ROOT="$PWD"
            if [ -z "$VENDOR_KERNEL_BUILD" ]; then
                VENDOR_KERNEL_VERSION=$(grep -e "default revision" .repo/manifests/default.xml | \
                grep -oP 'revision="\K[^"]*')
                log_info "VENDOR_KERNEL_REPO_ROOT=$VENDOR_KERNEL_REPO_ROOT"
                log_info "VENDOR_KERNEL_VERSION=$VENDOR_KERNEL_VERSION"
                VENDOR_KERNEL_BUILD="$VENDOR_KERNEL_REPO_ROOT"
            fi
            ;;
        *common-modules/virtual-device*)
            KERNEL_REPO_ROOT="$PWD"
            if [ -z "$KERNEL_BUILD" ]; then
                KERNEL_VERSION=$(grep -e "kernel/superproject" \
                .repo/manifests/default.xml | grep -oP 'revision="common-\K[^"]*')
                log_info "KERNEL_REPO_ROOT=$KERNEL_REPO_ROOT, KERNEL_VERSION=$KERNEL_VERSION"
                KERNEL_BUILD="$KERNEL_REPO_ROOT"
            fi
            ;;
        *)
            log_warn "Unknown manifest output. Could not determine repository type."
            ;;
    esac
}

function build_platform() {
    if [[ "$SKIP_BUILD" = "true" ]]; then
        log_warn "--skip-build is set. Do not rebuild platform build"
        return
    fi
    build_cmd="m -j12 ; make otatools -j12 ; make dist -j12"
    log_warn "Flag --skip-build is not set. Rebuilt images at $PWD with: $build_cmd"
    eval $build_cmd
    exit_code=$?
    if [ $exit_code -eq 1 ]; then
        log_warn "$build_cmd returned exit_code $exit_code"
        log_error "$build_cmd failed"
        exit 1
    else
        if [ -f "${ANDROID_PRODUCT_OUT}/system.img" ]; then
            log_info "${ANDROID_PRODUCT_OUT}/system.img exist"
        else
            log_error "${ANDROID_PRODUCT_OUT}/system.img doesn't exist"
        fi
    fi
}

function build_ack() {
    if [[ "$SKIP_BUILD" = "true" ]]; then
        log_warn "--skip-build is set. Do not rebuild kernel"
        return
    fi
    build_cmd="tools/bazel run --config=fast"
    if [ "$GCOV" = "true" ]; then
        build_cmd+=" --gcov"
    fi
    if [ "$DEBUG" = "true" ]; then
        build_cmd+=" --debug"
    fi
    if [ "$KASAN" = "true" ]; then
        build_cmd+=" --kasan"
    fi
    build_cmd+=" //common:kernel_aarch64_dist"
    log_warn "Flag --skip-build is not set. Rebuild the kernel with: $build_cmd."
    eval $build_cmd
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
        log_info "$build_cmd succeeded"
    else
        log_error "$build_cmd failed"
        exit 1
    fi
}

function format_ab_platform_build_string() {
    if [[ "$PLATFORM_BUILD" != ab://* ]]; then
        log_error "Please provide the platform build in the form of ab:// with flag -pb"
        exit 1
    fi
    IFS='/' read -ra array <<< "$PLATFORM_BUILD"
    local _branch="${array[2]}"
    local _build_target="${array[3]}"
    local _build_id="${array[4]}"
    if [ -z "$_branch" ]; then
        log_info "Branch is not specified in platform build as ab://<branch>. Using git_main branch"
        _branch="git_main"
    fi
    if [ -z "$_build_target" ]; then
        if [ -n "$PRODUCT" ]; then
            _build_target="$PRODUCT-userdebug"
        else
            log_error "Can not find platform build target through device info. Please \
            provide platform build in the form of ab://<branch>/<build_target> or \
            ab://<branch>/<build_target>/<build_id>"
            exit 1
        fi
    fi
    if [[ "$_branch" == aosp-main* ]] || [[ "$_branch" == git_main* ]]; then
        if [[ "$_build_target" != *-trunk_staging-* ]] && [[ "$_build_target" != *-next-* ]] \
        && [[ "$_build_target" != *-trunk_food-* ]]; then
            _build_target="${_build_target/-user/-trunk_staging-user}"
        fi
    fi
    if [ -z "$_build_id" ]; then
        _build_id="latest"
    fi
    PLATFORM_BUILD="ab://$_branch/$_build_target/$_build_id"
    log_info "Platform build to be used is $PLATFORM_BUILD"
}

function format_ab_system_build_string() {
    if [[ "$SYSTEM_BUILD" != ab://* ]]; then
        log_error "Please provide the system build in the form of ab:// with flag -sb"
        exit 1
    fi
    IFS='/' read -ra array <<< "$SYSTEM_BUILD"
    local _branch="${array[2]}"
    local _build_target="${array[3]}"
    local _build_id="${array[4]}"
    if [ -z "$_branch" ]; then
        log_info "Branch is not specified in system build as ab://<branch>. Using git_main branch"
        _branch="git_main"
    fi
    if [ -z "$_build_target" ]; then
        _build_target="gsi_arm64-userdebug"
    fi
    if [[ "$_branch" == aosp-main* ]] || [[ "$_branch" == git_main* ]]; then
        if [[ "$_build_target" != *-trunk_staging-* ]] && [[ "$_build_target" != *-next-* ]]  && \
        [[ "$_build_target" != *-trunk_food-* ]]; then
            _build_target="${_build_target/-user/-trunk_staging-user}"
        fi
    fi
    if [ -z "$_build_id" ]; then
        _build_id="latest"
    fi
    SYSTEM_BUILD="ab://$_branch/$_build_target/$_build_id"
    log_info "System build to be used is $SYSTEM_BUILD"
}

function format_ab_kernel_build_string() {
    if [[ "$KERNEL_BUILD" != ab://* ]]; then
        log_error "Please provide the kernel build in the form of ab:// with flag -kb"
        exit 1
    fi
    IFS='/' read -ra array <<< "$KERNEL_BUILD"
    local _branch="${array[2]}"
    local _build_target="${array[3]}"
    local _build_id="${array[4]}"
    if [ -z "$_branch" ]; then
        log_info "$KERNEL_BUILD provided in -kb doesn't have branch info. Will use the kernel version from device"
        if [ -z "$DEVICE_KERNEL_VERSION" ]; then
            log_error "The kernel version can not be retrieved from device to decide GKI kernel build"
            exit 1
        fi
        log_info "Branch is not specified in kernel build as ab://<branch>. Using device's existing kernel version $DEVICE_KERNEL_VERSION."
        _branch="$DEVICE_KERNEL_VERSION"
        KERNEL_VERSION="$DEVICE_KERNEL_VERSION"
    else
        if [[ "$_branch" == *mainline* ]]; then
            KERNEL_VERSION="android-mainline"
        else
            local _android_version=$(echo "$_branch" | grep -oE 'android[0-9]+')
            local _kernel_version=$(echo "$_branch" | grep -oE '[0-9]+\.[0-9]+')
            if [ -z "$_android_version" ] || [ -z "$_kernel_version" ]; then
                log_warn "Unable to get kernel version from $KERNEL_BUILD"
            else
                KERNEL_VERSION="$_android_version-$_kernel_version"
            fi
        fi
    fi
    if [[ "$_branch" == "android"* ]]; then
        _branch="aosp_kernel-common-$_branch"
    fi
    if [ -z "$_build_target" ]; then
        _build_target="kernel_aarch64"
    fi
    if [ -z "$_build_id" ]; then
        _build_id="latest"
    fi
    KERNEL_BUILD="ab://$_branch/$_build_target/$_build_id"
    log_info "GKI kernel build to be used is $KERNEL_BUILD"
}

function format_ab_vendor_kernel_build_string() {
    if [[ "$VENDOR_KERNEL_BUILD" != ab://* ]]; then
        log_error "Please provide the vendor kernel build in the form of ab:// with flag -vkb"
        exit 1
    fi
    IFS='/' read -ra array <<< "$VENDOR_KERNEL_BUILD"
    local _branch="${array[2]}"
    local _build_target="${array[3]}"
    local _build_id="${array[4]}"
    if [ -z "$_branch" ]; then
        if [ -z "$DEVICE_KERNEL_VERSION" ]; then
            log_error "Branch is not provided in vendor kernel build $VENDOR_KERNEL_BUILD. \
            The kernel version can not be retrieved from device to decide vendor kernel build"
            exit 1
        fi
        log_info "Branch is not specified in kernel build as ab://<branch>. Using $DEVICE_KERNEL_VERSION vendor kernel branch."
        _branch="$DEVICE_KERNEL_VERSION"
    fi
    case "$_branch" in
        android-mainline )
            if [[ "$PRODUCT" == "raven" ]] || [[ "$PRODUCT" == "oriole" ]]; then
                _branch="kernel-android-gs-pixel-mainline"
                if [ -z "$_build_target" ]; then
                    _build_target="kernel_raviole_kleaf"
                fi
            else
                log_error "There is no vendor kernel branch $_branch for $PRODUCT device"
                exit 1
            fi
            ;;
        android16-6.12 )
            if [[ "$PRODUCT" == "raven" ]] || [[ "$PRODUCT" == "oriole" ]]; then
                _branch="kernel-android16-6.12-gs101"
                if [ -z "$_build_target" ]; then
                    _build_target="kernel_raviole"
                fi
            else
                log_error "There is no vendor kernel branch $_branch for $PRODUCT device"
                exit 1
            fi
            ;;
        android15-6.6 )
            if [[ "$PRODUCT" == "raven" ]] || [[ "$PRODUCT" == "oriole" ]]; then
                _branch="kernel-android15-gs-pixel-6.6"
                if [ -z "$_build_target" ]; then
                    _build_target="kernel_raviole"
                fi
            else
                _branch="kernel-pixel-android15-gs-pixel-6.6"
            fi
            ;;
        android14-6.1 )
            _branch="kernel-android14-gs-pixel-6.1"
            ;;
        android14-5.15 )
            if [[ "$PRODUCT" == "husky" ]] || [[ "$PRODUCT" == "shiba" ]]; then
                _branch="kernel-android14-gs-pixel-5.15"
                if [ -z "$_build_target" ]; then
                    _build_target="shusky"
                fi
            elif [[ "$PRODUCT" == "akita" ]]; then
                _branch="kernel-android14-gs-pixel-5.15"
                if [ -z "$_build_target" ]; then
                    _build_target="akita"
                fi
            else
                log_error "There is no vendor kernel branch $_branch for $PRODUCT device"
                exit 1
            fi
            ;;
        android13-5.15 )
            if [[ "$PRODUCT" == "raven" ]] || [[ "$PRODUCT" == "oriole" ]]; then
                _branch="kernel-android13-gs-pixel-5.15-gs101"
                if [ -z "$_build_target" ]; then
                    _build_target="kernel_raviole_kleaf"
                fi
            else
                log_error "There is no vendor kernel branch $_branch for $PRODUCT device"
                exit 1
            fi
            ;;
        android13-5.10 )
            if [[ "$PRODUCT" == "raven" ]] || [[ "$PRODUCT" == "oriole" ]]; then
                _branch="kernel-android13-gs-pixel-5.10"
                if [ -z "$_build_target" ]; then
                    _build_target="slider_gki"
                fi
            elif [[ "$PRODUCT" == "felix" ]] || [[ "$PRODUCT" == "lynx" ]] || [[ "$PRODUCT" == "tangorpro" ]]; then
                _branch="kernel-android13-gs-pixel-5.10"
                if [ -z "$_build_target" ]; then
                    _build_target="$PRODUCT"
                fi
            else
                log_error "There is no vendor kernel branch $_branch for $PRODUCT device"
                exit 1
            fi
            ;;
        android12-5.10 )
            log_error "There is no vendor kernel branch $_branch for $PRODUCT device"
            exit 1
            ;;
    esac
    if [ -z "$_build_target" ]; then
        case "$PRODUCT" in
            caiman | komodo | tokay )
                _build_target="caimito"
                ;;
            husky | shiba )
                _build_target="shusky"
                ;;
            panther | cheetah )
                _build_target="pantah"
                ;;
            raven | oriole )
                _build_target="raviole"
                ;;
            * )
                _build_target="$PRODUCT"
                ;;
        esac
    fi
    if [ -z "$_build_id" ]; then
        _build_id="latest"
    fi
    VENDOR_KERNEL_BUILD="ab://$_branch/$_build_target/$_build_id"
    log_info "Vendor kernel build to be used is $VENDOR_KERNEL_BUILD"
}

function download_platform_build() {
    log_info "Downloading $PLATFORM_BUILD to $PWD"
    local _build_info="$PLATFORM_BUILD"
    local _file_patterns=("*$PRODUCT-img-*.zip" "radio.img")
    if [ "$SKIP_UPDATE_BOOTLOADER" = false ] || [ -n "$VENDOR_KERNEL_BUILD" ]; then
        _file_patterns+=("bootloader.img")
    fi
    if [ -n "$VENDOR_KERNEL_BUILD" ]; then
        _file_patterns+=("misc_info.txt" "otatools.zip")
        if [[ "$_build_info" == *git_sc* ]]; then
            _file_patterns+=("ramdisk.img")
        elif [[ "$_build_info" == *user/* ]]; then
            _file_patterns+=("vendor_ramdisk-debug.img")
        fi
    fi

    for _pattern in "${_file_patterns[@]}"; do
        log_info "Downloading $_build_info/$_pattern"
        eval "$FETCH_SCRIPT $_build_info/$_pattern"
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            log_info "Downloading $_build_info/$_pattern succeeded"
        else
            log_error "Downloading $_build_info/$_pattern failed"
            exit 1
        fi
        if [[ "$_pattern" == "vendor_ramdisk-debug.img" ]]; then
            cp vendor_ramdisk-debug.img vendor_ramdisk.img
        fi
    done
    echo ""
}

function download_system_build() {
    log_info "Downloading $SYSTEM_BUILD to $PWD"
    local _build_info="$SYSTEM_BUILD"
    local _file_patterns=("*_arm64-img-*.zip")
    for _pattern in "${_file_patterns[@]}"; do
        log_info "Downloading $_build_info/$_pattern"
        eval "$FETCH_SCRIPT $_build_info/$_pattern"
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            log_info "Downloading $_build_info/$_pattern succeeded"
        else
            log_error "Downloading $_build_info/$_pattern failed"
            exit 1
        fi
    done
    echo ""
}

function download_gki_build() {
    log_info "Downloading GKI kernel build $KERNEL_BUILD"
    if [ -d "$DOWNLOAD_PATH/gki_dir" ]; then
        rm -rf "$DOWNLOAD_PATH/gki_dir"
    fi
    local _gki_dir="$DOWNLOAD_PATH/gki_dir"
    mkdir -p "$_gki_dir"
    cd "$_gki_dir" || { log_error "Fail to go to $_gki_dir" && exit 1; }
    log_info "Downloading $KERNEL_BUILD to $PWD"

    local _build_info="$KERNEL_BUILD"
    local _file_patterns
    case "$PRODUCT" in
        oriole | raven | bluejay)
            _file_patterns=( "boot-lz4.img" )
            if [ -n "$VENDOR_KERNEL_BUILD" ] && [[ "$_build_info" != *android13* ]]; then
                _file_patterns+=( "system_dlkm_staging_archive.tar.gz" "kernel_aarch64_Module.symvers" )
            fi
            ;;
        kirkwood)
            _file_patterns=( "boot.img" "system_dlkm.flatten.erofs.img" )
            ;;
        eos | aurora)
            _file_patterns=( "boot.img" "system_dlkm.flatten.ext4.img" )
            ;;
        slsi | qcom )
            _file_patterns=( "boot-gz.img" )
            if [[ "$KERNEL_BUILD" == *android13-5* ]]; then
                _file_patterns+=( "system_dlkm.img" )
            else
                _file_patterns+=( "system_dlkm.flatten.ext4.img" )
            fi
            ;;
        mtk )
            _file_patterns=( "boot.img" )
            if [[ "$KERNEL_BUILD" == *android13-5* ]]; then
                _file_patterns+=( "system_dlkm.img" )
            else
                _file_patterns+=( "system_dlkm.flatten.ext4.img" )
            fi
            ;;
        *)
            _file_patterns=( "boot-lz4.img" )
            if [[ "$KERNEL_BUILD" == *android13-5* ]]; then
                _file_patterns+=( "system_dlkm.img" )
            else
                _file_patterns+=( "system_dlkm.flatten.ext4.img" )
            fi
            ;;
    esac

    for _pattern in "${_file_patterns[@]}"; do
        log_info "Downloading $_build_info/$_pattern"
        eval "$FETCH_SCRIPT $_build_info/$_pattern"
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            log_info "Downloading $_build_info/$_pattern succeeded"
        else
            log_error "Downloading $_build_info/$_pattern failed"
            exit 1
        fi
        if [[ "$_pattern" == "boot-lz4.img" ]]; then
            cp boot-lz4.img boot.img
        fi
    done
    echo ""
    KERNEL_BUILD="$_gki_dir"
}

function download_vendor_kernel_build() {
    log_info "Downloading $1 to $PWD"
    local _build_info="$1"
    local _file_patterns=("Image.lz4" "dtbo.img" "initramfs.img")

    if [[ "$_build_info" == *6.6* ]] || [[ "$_build_info" == *6.12* ]]; then
        _file_patterns+=("*vendor_dev_nodes_fragment.img")
    fi

    case "$PRODUCT" in
        oriole | raven | bluejay)
            _file_patterns+=( "gs101-a0.dtb" "gs101-b0.dtb" )
            if [[ "$_build_info" == *android13* ]] || [ -z "$KERNEL_BUILD" ]; then
                _file_patterns+=("vendor_dlkm.img")
            else
                _file_patterns+=("vendor_dlkm_staging_archive.tar.gz" "vendor_dlkm.props" "vendor_dlkm_file_contexts" \
                "kernel_aarch64_Module.symvers" "abi_gki_aarch64_pixel")
                if [[ "$_build_info" == *android15* ]] && [[ "$_build_info" == *6.6* ]]; then
                    _file_patterns+=("vendor_dev_nodes_fragment.img" 'vendor-bootconfig.img')
                elif [[ "$_build_info" == *pixel-mainline* ]]; then
                    _file_patterns+=("vendor-bootconfig.img")
                fi
            fi
            ;;
        felix | lynx | cheetah | tangorpro)
            _file_patterns+=("vendor_dlkm.img" "system_dlkm.img" "gs201-a0.dtb" "gs201-a0.dtb" )
            ;;
        shiba | husky | akita)
            _file_patterns+=("vendor_dlkm.img" "system_dlkm.img" "zuma-a0-foplp.dtb" "zuma-a0-ipop.dtb" "zuma-b0-foplp.dtb" "zuma-b0-ipop.dtb" )
            ;;
        caiman | komodo | tokay | comet)
            _file_patterns+=("vendor_dlkm.img" "system_dlkm.img" "zuma-a0-foplp.dtb" "zuma-a0-ipop.dtb" "zuma-b0-foplp.dtb" "zuma-b0-ipop.dtb" \
            "zumapro-a0-foplp.dtb" "zumapro-a0-ipop.dtb" "zumapro-a1-foplp.dtb" "zumapro-a1-ipop.dtb" )
            ;;
        *)
            _file_pattern+=("vendor_dlkm.img" "system_dlkm.img" "*-a0-foplp.dtb" "*-a0-ipop.dtb" "*-a1-foplp.dtb" \
            "*-a1-ipop.dtb" "*-a0.dtb" "*-b0.dtb")
            ;;
    esac

    for _pattern in "${_file_patterns[@]}"; do
        log_info "Downloading $_build_info/$_pattern"
        eval "$FETCH_SCRIPT $_build_info/$_pattern"
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            log_info "Downloading $_build_info/$_pattern succeeded"
            if [[ "$_pattern" == "vendor_dev_nodes_fragment.img" ]]; then
                cp vendor_dev_nodes_fragment.img vendor_ramdisk_fragment_extra.img
            fi
            if [[ "$_pattern" == "abi_gki_aarch64_pixel" ]]; then
                cp abi_gki_aarch64_pixel extracted_symbols
            fi
        else
            log_warn "Downloading $_build_info/$_pattern failed"
        fi
    done
    echo ""
}

function download_vendor_kernel_for_direct_flash() {
    log_info "Downloading $1 to $PWD"
    local build_info="$1"

    for pattern in "${VENDOR_KERNEL_IMGS[@]}"; do
        log_info "Downloading $_build_info/$_pattern"
        eval "$FETCH_SCRIPT $build_info/$pattern"
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            log_info "Downloading $build_info/$pattern succeeded"
        else
            log_error "Downloading $build_info/$pattern failed"
            exit 1
        fi
    done
    echo ""

}

function reboot_device_into_bootloader() {
    if [ -n "$ADB_SERIAL_NUMBER" ] && (( $(adb devices | grep "$ADB_SERIAL_NUMBER" | wc -l) > 0 )); then
        log_info "Reboot $ADB_SERIAL_NUMBER into bootloader"
        adb -s "$ADB_SERIAL_NUMBER" reboot bootloader
    elif [ -n "$FASTBOOT_SERIAL_NUMBER" ] && (( $(fastboot devices | grep "$FASTBOOT_SERIAL_NUMBER" | wc -l) > 0 )); then
        log_info "Reboot $FASTBOOT_SERIAL_NUMBER into bootloader"
        fastboot -s "$FASTBOOT_SERIAL_NUMBER" reboot bootloader
    fi
    wait_for_device_in_fastboot
}

function flash_gki_build() {
    log_info "The boot image in $KERNEL_BUILD has kernel verson: $KERNEL_VERSION"
    if [ -n "$DEVICE_KERNEL_VERSION" ] && [[ "$KERNEL_VERSION" != "$DEVICE_KERNEL_VERSION"* ]]; then
        log_warn "Device $PRODUCT $SERIAL_NUMBER comes with $DEVICE_KERNEL_VERSION kernel. \
Can't flash $KERNEL_VERSION GKI directly. Please use a platform build with the $KERNEL_VERSION kernel \
or use a vendor kernel build by flag -vkb, such as ab://kernel-android*-gs-pixel-*.*"
        log_error "Cannot flash $KERNEL_VERSION GKI to device $SERIAL_NUMBER directly."
        exit 1
    fi

    reboot_device_into_bootloader
    log_info "Flash GKI kernel from $KERNEL_BUILD"
    log_info "Wiping the device"
    fastboot -s "$FASTBOOT_SERIAL_NUMBER" -w
    log_info "Disabling oem verification"
    fastboot -s "$FASTBOOT_SERIAL_NUMBER" oem disable-verification
    local _flash_cmd
    if [ -f "$KERNEL_BUILD/boot-lz4.img" ]; then
        _flash_cmd="fastboot -s $FASTBOOT_SERIAL_NUMBER flash boot $KERNEL_BUILD/boot-lz4.img"
    elif [ -f "$KERNEL_BUILD/boot-gz.img" ]; then
        _flash_cmd="fastboot -s $FASTBOOT_SERIAL_NUMBER flash boot $KERNEL_BUILD/boot-gz.img"
    elif [ -f "$KERNEL_BUILD/boot.img" ]; then
        _flash_cmd="fastboot -s $FASTBOOT_SERIAL_NUMBER flash boot $KERNEL_BUILD/boot.img"
    fi
    if [ -f "$KERNEL_BUILD/system_dlkm.img" ]; then
        _flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot fastboot && fastboot -s $FASTBOOT_SERIAL_NUMBER flash system_dlkm $KERNEL_BUILD/system_dlkm.img"
    elif [ -f "$KERNEL_BUILD/system_dlkm.flatten.ext4.img" ]; then
        _flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot fastboot && fastboot -s $FASTBOOT_SERIAL_NUMBER flash system_dlkm $KERNEL_BUILD/system_dlkm.flatten.ext4.img"
    elif [ -f "$KERNEL_BUILD/system_dlkm.flatten.erofs.img" ]; then
        _flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot fastboot && fastboot -s $FASTBOOT_SERIAL_NUMBER flash system_dlkm $KERNEL_BUILD/system_dlkm.flatten.erofs.img"
    fi
    _flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot"

    log_info "Flashing GKI kernel with: $_flash_cmd"
    eval "$_flash_cmd"
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo "Flash GKI kernel succeeded"
        wait_for_device_in_adb
        return
    else
        echo "Flash GKI kernel failed with exit code $exit_code"
        exit 1
    fi
}

function check_fastboot_version() {
    local _fastboot_version=$(fastboot --version | awk 'NR==1 {print $3}')

    # Check if _fastboot_version is less than MIN_FASTBOOT_VERSION
    if [[ "$_fastboot_version" < "$MIN_FASTBOOT_VERSION" ]]; then
        log_info "The existing fastboot version $_fastboot_version doesn't meet minimum requirement $MIN_FASTBOOT_VERSION. Download the latest fastboot"

        local _download_file_name="ab://aosp-sdk-release/sdk/latest/fastboot"
        mkdir -p "/tmp/fastboot" || { log_error "Fail to mkdir /tmp/fastboot" && exit 1; }
        cd /tmp/fastboot || { log_error "Fail to go to /tmp/fastboot" && exit 1; }

        # Use $FETCH_SCRIPT and $_download_file_name correctly
        eval "$FETCH_SCRIPT $_download_file_name"
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            log_info "Downloading $_download_file_name succeeded"
        else
            log_error "Downloading $_download_file_name failed"
            exit 1
        fi

        chmod +x /tmp/fastboot/fastboot
        export PATH="/tmp/fastboot:$PATH"

        _fastboot_version=$(fastboot --version | awk 'NR==1 {print $3}')
        log_info "The fastboot is updated to version $_fastboot_version"
    fi
}

function flash_vendor_kernel_build() {
    check_fastboot_version

    for pattern in "${VENDOR_KERNEL_IMGS[@]}"; do
        if [ ! -f "$VENDOR_KERNEL_BUILD/$pattern" ]; then
            log_error "$VENDOR_KERNEL_BUILD/$pattern doesn't exist"
            exit 1
        fi
    done

    cd $VENDOR_KERNEL_BUILD

    log_info "Flash vendor kernel from $VENDOR_KERNEL_BUILD"
    reboot_device_into_bootloader
    log_info "Wiping the device"
    fastboot -s "$FASTBOOT_SERIAL_NUMBER" -w
    log_info "Disabling oem verification"
    fastboot -s "$FASTBOOT_SERIAL_NUMBER" oem disable-verification
    log_info "Flashing boot image"
    fastboot -s "$FASTBOOT_SERIAL_NUMBER" flash boot "$VENDOR_KERNEL_BUILD"/boot.img
    log_info "Flashing dtb.img & initramfs.img"
    fastboot -s "$FASTBOOT_SERIAL_NUMBER" flash --dtb "$VENDOR_KERNEL_BUILD"/dtb.img vendor_boot:dlkm "$VENDOR_KERNEL_BUILD"/initramfs.img
    log_info "Flashing dtbo.img"
    fastboot -s "$FASTBOOT_SERIAL_NUMBER" flash dtbo "$VENDOR_KERNEL_BUILD"/dtbo.img
    log_info "Reboot into fastbootd"
    fastboot -s "$FASTBOOT_SERIAL_NUMBER" reboot fastboot
    sleep 10
    log_info "Flashing vendor_dlkm.img"
    fastboot -s "$FASTBOOT_SERIAL_NUMBER" flash vendor_dlkm "$VENDOR_KERNEL_BUILD"/vendor_dlkm.img
    log_info "Reboot the device"
    fastboot -s "$FASTBOOT_SERIAL_NUMBER" reboot
    wait_for_device_in_adb
}

function is_device_in_adb() {
    local adb_serials
    adb_serials=($(adb devices | grep -v -w "offline" | tail -n +2 | awk '{print $1}'))

    if [ ${#adb_serials[@]} -eq 0 ]; then
        log_info "No devices found in adb mode."
        return 1
    fi

    local target_serial="${ADB_SERIAL_NUMBER:-${DEVICE_SERIAL_NUMBER:-$SERIAL_NUMBER}}"
    for adb_serial in "${adb_serials[@]}"; do
        if [[ "$adb_serial" == "$target_serial" ]]; then
            ADB_SERIAL_NUMBER="${ADB_SERIAL_NUMBER:-$adb_serial}"
            log_info "Success: Device '$target_serial' is connected in adb."
            return 0 # Succeed. Device is in adb
        fi
        if [ -z "$ADB_SERIAL_NUMBER" ]; then
            local hw_serial
            hw_serial=$(adb -s "$adb_serial" shell getprop ro.serialno | tr -d '[:space:]')
            if [[ -n "$hw_serial" && "$hw_serial" == "$target_serial" ]]; then
                DEVICE_SERIAL_NUMBER="$hw_serial"
                ADB_SERIAL_NUMBER="$adb_serial"
                log_info "Success: Device '$target_serial' found in adb as '$adb_serial'."
                return 0 # Succeed. Device is in adb
            fi
            if [[ -n "$hw_serial" ]] && [[ "$hw_serial" == "$DEVICE_SERIAL_NUMBER" ]]; then
                ADB_SERIAL_NUMBER="$adb_serial"
                log_info "Success: Device '$target_serial' found in adb as '$adb_serial'."
                return 0 # Succeed. Device is in fastboot
            fi
        fi
    done
    return 1 # fail
}

function is_device_in_fastboot() {
    local fastboot_serials
    fastboot_serials=($(fastboot devices | awk '{print $1}'))

    if [ ${#fastboot_serials[@]} -eq 0 ]; then
        log_info "No devices found in fastboot mode."
        return 1
    fi

    local target_serial="${FASTBOOT_SERIAL_NUMBER:-${DEVICE_SERIAL_NUMBER:-$SERIAL_NUMBER}}"

    for fastboot_serial in "${fastboot_serials[@]}"; do
        if [[ "$fastboot_serial" == "$target_serial" ]]; then
            FASTBOOT_SERIAL_NUMBER="$fastboot_serial"
            log_info "Success: Device '$target_serial' found in fastboot mode."
            return 0 # Succeed. Device is in fastboot
        fi
        if [ -z "$FASTBOOT_SERIAL_NUMBER" ]; then
            local hw_serial
            hw_serial=$(_parse_fastboot_var "$(fastboot -s "$fastboot_serial" getvar serialno 2>&1)")
            if [[ -n "$hw_serial" ]] && [[ "$hw_serial" == "$target_serial" ]]; then
                DEVICE_SERIAL_NUMBER="$hw_serial"
                FASTBOOT_SERIAL_NUMBER="$fastboot_serial"
                log_info "Success: Device '$target_serial' found in fastboot as '$fastboot_serial'."
                return 0 # Succeed. Device is in fastboot
            fi
            if [[ -n "$hw_serial" ]] && [[ "$hw_serial" == "$DEVICE_SERIAL_NUMBER" ]]; then
                FASTBOOT_SERIAL_NUMBER="$fastboot_serial"
                log_info "Success: Device '$target_serial' found in fastboot as '$fastboot_serial'."
                return 0 # Succeed. Device is in fastboot
            fi
        fi
    done
    return 1 # fail
}

function check_adb_status() {
    local log_level
    log_level="${1:-0}"
    local device_target
    device_target="${ADB_SERIAL_NUMBER:-${DEVICE_SERIAL_NUMBER:-$SERIAL_NUMBER}}"
    if ! is_device_in_adb; then
        if [[ "$log_level" -gt 0 ]]; then
            log_warn "Device '$device_target' not found in adb. Waiting for it to connect..."
            if [[ "$THROUGH_PONTIS" = "true" ]] && ! pontis devices | grep -q "$DEVICE_SERIAL_NUMBER.*ADB"; then
                log_warn "Device $DEVICE_SERIAL_NUMBER is not connected in adb through \
pontis yet. If device booted up already, please visit https://pontis.corp.google.com/ on the host \
where the device is attached to physically and make sure adb through pontis is connected. Please \
enforce connection in the WebUI if the device shows up but is not yet connected. When adb server \
on the host where the device is attached to physically is still running, the adb through pontis \
will fail to connect autimatically, please try killing adb server (adb kill-server) on the host." 
            fi
        fi
        return 1 # Failure
    fi
    if ! is_device_adb_authorized; then
        return 0 # Failed
    fi
    if is_device_ready_for_adb_command; then
        return 0 # Failed
    fi
    log_info "Device '$device_target' is connected, authorized, and ready."
    get_device_info_from_adb
    return 0 # Success
}

# Function to check and wait for a device showing up in adb devices
# shellcheck disable=SC2120
function wait_for_device_in_adb() {
    local timeout_seconds="${1:-300}"  # Timeout in seconds (equal to  5 minutes)
    local warning_seconds=$(( timeout_seconds / 3 ))  # Start warning in seconds

    local start_time
    local end_time
    start_time=$(date +%s)
    end_time=$((start_time + timeout_seconds))
    warning_time=$((start_time + warning_seconds))

    while (( $(date +%s) < end_time )); do
        local log_level=0
        if (( $(date +%s) > warning_time )); then
            log_level=1
        fi
        if check_adb_status "$log_level"; then
            log_info "Device $DEVICE_SERIAL_NUMBER is ready in adb mode" 
            return 0 # Success
        fi
        sleep 10
    done

    log_error "Timed out while waiting for ${ADB_SERIAL_NUMBER:-${DEVICE_SERIAL_NUMBER:-$SERIAL_NUMBER}} \
in adb mode"
    exit 1
}

function wait_for_device_in_fastboot() {
    local timeout_seconds="${1:-120}"  # Timeout in seconds (equal to  2 minutes)
    local warning_seconds=$(( timeout_seconds / 3 )) # Start warning message after half timeout elapsed

    local start_time
    local end_time
    start_time=$(date +%s)
    end_time=$((start_time + timeout_seconds))
    warning_time=$((start_time + warning_seconds))

    local device_target="${FASTBOOT_SERIAL_NUMBER:-${DEVICE_SERIAL_NUMBER:-$SERIAL_NUMBER}}"

    while (( $(date +%s) < end_time )); do
        local message=""
        if is_device_in_fastboot; then
            log_info "Device $device_target is connected in fastboot"
            return 0  # Success
        fi
        message="Device '$device_target' not found in fastboot. Waiting for it to connect..."
        if [ "$THROUGH_PONTIS" == "true" ]; then
            if ! pontis devices | grep -q "$DEVICE_SERIAL_NUMBER.*Fastboot"; then
                message="Device $DEVICE_SERIAL_NUMBER is not connected in fastboot through \
pontis yet. If device is in bootloader already, please visit https://pontis.corp.google.com/ on the host \
where the device is attached to physically and make sure fastboot through pontis is connected. Please \
enforce connection in the WebUI if the device shows up but is not yet connected."
            fi
        fi
        if (( $(date +%s) < warning_time )); then
            log_info "$message"
        else
            log_warn "$message"
        fi
        sleep 10
    done

    log_error "Timed out while waiting for $device_target in fastboot mode"
    exit 1
}

function find_flashstation_binary() {
    # Prefer local build in ANDROID_HOST_OUT if available
    if [[ -n "${ANDROID_HOST_OUT:-}" && -x "${ANDROID_HOST_OUT}/bin/local_flashstation" ]]; then
        LOCAL_FLASH_CLI="${ANDROID_HOST_OUT}/bin/local_flashstation"
    elif ! check_command "local_flashstation"; then
        if [[ -n "$COMMON_LIB_LOCAL_FLASH_CLI" ]] && check_command "$COMMON_LIB_LOCAL_FLASH_CLI"; then
            LOCAL_FLASH_CLI="$COMMON_LIB_LOCAL_FLASH_CLI"
        else
            log_info "Cannot find 'local_flashstation' in PATH. Will use fastboot to flash device.. \
            Please see go/web-flashstation-command-line to download flashstation cli"
            LOCAL_FLASH_CLI=""
        fi
    else
        LOCAL_FLASH_CLI="local_flashstation"
    fi

    if [[ -n "${ANDROID_HOST_OUT:-}" && -x "${ANDROID_HOST_OUT}/bin/cl_flashstation" ]]; then
        CL_FLASH_CLI="${ANDROID_HOST_OUT}/bin/cl_flashstation"
    elif ! check_command "cl_flashstation"; then
        if check_command "$COMMON_LIB_CL_FLASH_CLI"; then
             CL_FLASH_CLI="$COMMON_LIB_CL_FLASH_CLI"
        else
            log_info "Cannot find 'cl_flashstation' in PATH. Will use fastboot to flash device.. \
            Please see go/web-flashstation-command-line to download flashstation cli"
            CL_FLASH_CLI=""
        fi
    else
        CL_FLASH_CLI="cl_flashstation"
    fi

    log_info "Found LOCAL_FLASH_CLI: ${LOCAL_FLASH_CLI:-Not Found}"
    log_info "Found CL_FLASH_CLI: ${CL_FLASH_CLI:-Not Found}"

}

function flash_platform_build() {
    if [ "$SKIP_UPDATE_BOOTLOADER" = "true" ] && [[ "$PLATFORM_BUILD" == ab://* ]] || [ -z "$CL_FLASH_CLI" ]; then
        if [ -d "$DOWNLOAD_PATH/device_dir" ]; then
            rm -rf "$DOWNLOAD_PATH/device_dir"
        fi
        PLATFORM_DIR="$DOWNLOAD_PATH/device_dir"
        mkdir -p "$PLATFORM_DIR"
        cd "$PLATFORM_DIR" || { log_error "Fail to go to $PLATFORM_DIR" && exit 1; }
        download_platform_build
        PLATFORM_BUILD="$PLATFORM_DIR"
    fi

    local _flash_cmd
    if [[ "$PLATFORM_BUILD" == ab://* ]]; then
        _flash_cmd="$CL_FLASH_CLI --nointeractive --force_flash_partitions --disable_verity -w -s $DEVICE_SERIAL_NUMBER "

        local _branch
        local _build_target
        local _build_id
        if ! parse_ab_url "$PLATFORM_BUILD" _branch _build_target _build_id &> /dev/null; then
            log_error "Invalid Android Build url string. PLATFORM_BUILD=${PLATFORM_BUILD}"
            exit 1
        fi

        if [ -n "${_build_target}" ]; then
            _flash_cmd+=" -t $_build_target"
            if [[ "$_build_target" == *user ]] && [ -n "$KERNEL_BUILD" ] && [ -z "$VENDOR_KERNEL_BUILD" ]; then
                log_info "Need to flash GKI after flashing platform build, hence enabling --force_debuggable in user build flashing"
                _flash_cmd+=" --force_debuggable"
            fi
        fi
        log_info "Flashing $SERIAL_NUMBER by flash station with platform build $PLATFORM_BUILD..."
        if [ -n "${_build_id}" ] && [[ "${_build_id}" != latest* ]]; then
            _flash_cmd+=" --bid ${_build_id}"
        else
            _flash_cmd+=" -l ${_branch}"
        fi
    elif [ -n "$PLATFORM_REPO_ROOT" ] && [[ "$PLATFORM_BUILD" == "$PLATFORM_REPO_ROOT/out/target/product/$PRODUCT" ]] && \
    [ -x "$PLATFORM_REPO_ROOT/vendor/google/tools/flashall" ]; then
        cd "$PLATFORM_REPO_ROOT" || { log_error "Fail to go to $PLATFORM_REPO_ROOT" && exit 1; }
        log_info "Flashing device by vendor/google/tools/flashall with platform build from ${PLATFORM_BUILD}"
        if [ -z "${TARGET_PRODUCT}" ] || [[ "${TARGET_PRODUCT}" != *"$PRODUCT" ]]; then
            if [[ "$PLATFORM_VERSION" == aosp-* ]]; then
                set_platform_repo "aosp_$PRODUCT"
            else
                set_platform_repo "$PRODUCT"
            fi
        fi
        _flash_cmd="vendor/google/tools/flashall  --nointeractive -w -s $DEVICE_SERIAL_NUMBER"
    else
        log_info "Flashing device by local flash station with platform build from ${PLATFORM_BUILD}"
        prepare_to_flash_platform_build_from_local_directory

        _flash_cmd="$LOCAL_FLASH_CLI --nointeractive --force_flash_partitions --disable_verity --disable_verification  -w -s $DEVICE_SERIAL_NUMBER"
    fi

    log_info "Flashing device with: $_flash_cmd"
    eval "$_flash_cmd"
    exit_code=$?
    if (( exit_code == 0 )); then
        log_info "Flashing platform build succeeded"
        wait_for_device_in_adb
        return 0
    else
        log_error "Flashing platform build failed with exit code $exit_code"
        exit 1
    fi
}

function flash_system_build() {
    if [[ "$SYSTEM_BUILD" == ab://* ]]; then
        if [ -d "$DOWNLOAD_PATH/system_dir" ]; then
            rm -rf "$DOWNLOAD_PATH/system_dir"
        fi
        SYSTEM_DIR="$DOWNLOAD_PATH/system_dir"
        mkdir -p "$SYSTEM_DIR"
        cd "$SYSTEM_DIR" || { log_error "Fail to go to $SYSTEM_DIR" && exit 1;}
        download_system_build
        SYSTEM_BUILD="$SYSTEM_DIR"
    fi
    if [ ! -f "$SYSTEM_BUILD/system.img" ]; then
        local _device_image=$(find "$SYSTEM_BUILD" -maxdepth 1 -type f -name *-img*.zip)
        if [ -f "$_device_image" ]; then
            unzip -j "$_device_image" -d "$SYSTEM_BUILD"
            if [ ! -f "$SYSTEM_BUILD/system.img" ]; then
                log_error "There is no system.img in $_device_image"
                exit 1
            fi
        else
            log_error "$SYSTEM_BUILD doesn't have valid system image or device image to be flashed with"
            exit 1
        fi
    fi

    local _flash_cmd

    log_info "Flash GSI from $SYSTEM_BUILD"
    reboot_device_into_bootloader
    local _output=$(fastboot -s "$FASTBOOT_SERIAL_NUMBER" getvar current-slot 2>&1)
    local _current_slot=$(echo "$_output" | grep "^current-slot:" | awk '{print $2}')
    log_info "Wiping the device"
    fastboot -s "$FASTBOOT_SERIAL_NUMBER" -w
    log_info "Reboot device into fastbootd"
    fastboot -s "$FASTBOOT_SERIAL_NUMBER" reboot-fastboot
    log_info "Delete logical partition product_$_current_slot"
    fastboot -s "$FASTBOOT_SERIAL_NUMBER" delete-logical-partition product_"$_current_slot"
    log_info "Erase logical partition system_$_current_slot"
    fastboot -s "$FASTBOOT_SERIAL_NUMBER" erase system_"$_current_slot"

    local _flash_cmd
    if [ -f "$SYSTEM_BUILD/system.img" ]; then
        _flash_cmd="fastboot -s $FASTBOOT_SERIAL_NUMBER flash system $SYSTEM_BUILD/system.img"
    fi
    if [ -f "$KERNEL_BUILD/pvmfw.img" ]; then
        _flash_cmd=" && fastboot -s $FASTBOOT_SERIAL_NUMBER flash pvmfw $SYSTEM_BUILD/pvmfw.img"
    fi
    _flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot"

    log_info "Flashing GSI with: $_flash_cmd"
    eval "$_flash_cmd"
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo "Flash GSI succeeded"
        wait_for_device_in_adb
        return
    else
        echo "Flash GSI failed with exit code $exit_code"
        exit 1
    fi

}

function prepare_to_flash_platform_build_from_local_directory () {
    log_info "Setting up local environment to flash platform build from ${PLATFORM_BUILD}"
    if [ ! -f "$PLATFORM_BUILD/android-info.txt" ] || [ ! -f "$PLATFORM_BUILD/boot.img" ]; then
        local device_image=$(find "$PLATFORM_BUILD" -maxdepth 1 -type f -name *-img*.zip)
        if [ -f "$device_image" ]; then
            unzip -j "$device_image" -d "$PLATFORM_BUILD"
            if [ ! -f "$PLATFORM_BUILD/android-info.txt" ] || [ ! -f "$PLATFORM_BUILD/boot.img" ]; then
                log_error "There is no android-info.txt in $device_image"
                exit 1
            fi
        else
            log_error "$PLATFORM_BUILD doesn't have valid device image to be flashed with"
            exit 1
        fi
    fi
    if [ -z "${TARGET_PRODUCT:-}" ] || [[ "${TARGET_PRODUCT}" != "$PRODUCT" ]]; then
        log_info "Set env var TARGET_PRODUCT to $PRODUCT"
        export TARGET_PRODUCT="$PRODUCT"
    fi
    if [ -z "${TARGET_BUILD_VARIANT:-}" ] || [[ "${TARGET_BUILD_VARIANT}" != "$DEVICE_VARIANT" ]]; then
        log_info "Set env var TARGET_BUILD_VARIANT to $DEVICE_VARIANT"
        export TARGET_BUILD_VARIANT="$DEVICE_VARIANT"
    fi
    if [ -z "${ANDROID_PRODUCT_OUT:-}" ] || [[ "${ANDROID_PRODUCT_OUT}" != "$PLATFORM_BUILD" ]]; then
        log_info "Set env var ANDROID_PRODUCT_OUT to $PLATFORM_BUILD"
        export ANDROID_PRODUCT_OUT="$PLATFORM_BUILD"
    fi
    if [ -z "${ANDROID_HOST_OUT:-}" ] || [[ "${ANDROID_HOST_OUT}" != "$PLATFORM_BUILD" ]]; then
        log_info "Set env var ANDROID_HOST_OUT to $PLATFORM_BUILD"
        export ANDROID_HOST_OUT="$PLATFORM_BUILD"
    fi

    if [ "$SKIP_UPDATE_BOOTLOADER" = "true" ]; then
        awk '! /bootloader/' "$PLATFORM_BUILD"/android-info.txt > temp && mv temp "$PLATFORM_BUILD"/android-info.txt
    fi
    # skip update radio.img
    #awk '! /baseband/' "$PLATFORM_BUILD"/android-info.txt > temp && mv temp "$PLATFORM_BUILD"/android-info.txt

}

function get_mix_ramdisk_script() {
    download_file_name="ab://git_main/aosp_cf_x86_64_only_phone-trunk_staging-userdebug/latest/otatools.zip"
    eval "$FETCH_SCRIPT $download_file_name"
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
        log_info "Download $download_file_name succeeded"
    else
        log_error "Download $download_file_name failed"
        exit 1
    fi
    eval "unzip -j otatools.zip bin/$MIX_SCRIPT_NAME"
    echo ""
}

function mixing_build() {
    if [ -n "${PLATFORM_REPO_ROOT}" ] && [ -f "${PLATFORM_REPO_ROOT}/vendor/google/tools/$MIX_SCRIPT_NAME" ]; then
        mix_kernel_cmd="${PLATFORM_REPO_ROOT}/vendor/google/tools/${MIX_SCRIPT_NAME}"
    elif [ -f "$DOWNLOAD_PATH/$MIX_SCRIPT_NAME" ]; then
        mix_kernel_cmd="$DOWNLOAD_PATH/$MIX_SCRIPT_NAME"
    else
        cd "$DOWNLOAD_PATH" || { log_error "Fail to go to $DOWNLOAD_PATH" && exit 1; }
        get_mix_ramdisk_script
        mix_kernel_cmd="$PWD/$MIX_SCRIPT_NAME"
    fi
    if [ ! -f "$mix_kernel_cmd" ]; then
        log_error "$mix_kernel_cmd doesn't exist or is not executable"
        exit 1
    elif [ ! -x "$mix_kernel_cmd" ]; then
        log_error "$mix_kernel_cmd is not executable"
        exit 1
    fi
    if [[ "$PLATFORM_BUILD" == ab://* ]]; then
        if [ -d "$DOWNLOAD_PATH/device_dir" ]; then
            rm -rf "$DOWNLOAD_PATH/device_dir"
        fi
        PLATFORM_DIR="$DOWNLOAD_PATH/device_dir"
        mkdir -p "$PLATFORM_DIR"
        cd "$PLATFORM_DIR" || { log_error "Fail to go to $PLATFORM_DIR" && exit 1; }
        download_platform_build
        PLATFORM_BUILD="$PLATFORM_DIR"
    elif [ -n "$PLATFORM_REPO_ROOT" ] && [[ "$PLATFORM_BUILD" == "$PLATFORM_REPO_ROOT"* ]]; then
        log_info "Copy platform build $PLATFORM_BUILD to $DOWNLOAD_PATH/device_dir"
        PLATFORM_DIR="$DOWNLOAD_PATH/device_dir"
        mkdir -p "$PLATFORM_DIR"
        cd "$PLATFORM_DIR" || { log_error "Fail to go to $PLATFORM_DIR" && exit 1; }
        local device_image=$(find "$PLATFORM_BUILD" -maxdepth 1 -type f -name *-img.zip)
        if [ -n "$device_image" ]; then
            cp "$device_image $PLATFORM_DIR/$PRODUCT-img-0.zip" "$PLATFORM_DIR"
        else
            device_image=$(find "$PLATFORM_BUILD" -maxdepth 1 -type f -name *-img-*.zip)
            if [ -n "$device_image" ]; then
                cp "$device_image $PLATFORM_DIR/$PRODUCT-img-0.zip" "$PLATFORM_DIR"
            else
                log_error "Can't find $RPODUCT-img-*.zip in $PLATFORM_BUILD"
                exit 1
            fi
        fi
        local file_patterns=("bootloader.img" "radio.img" "vendor_ramdisk.img" "misc_info.txt" "otatools.zip")
        for pattern in "${file_patterns[@]}"; do
            cp "$PLATFORM_BUILD/$pattern" "$PLATFORM_DIR/$pattern"
            exit_code=$?
            if [ $exit_code -eq 0 ]; then
                log_info "Copied $PLATFORM_BUILD/$pattern to $PLATFORM_DIR"
            else
                log_error "Failed to copy $PLATFORM_BUILD/$pattern to $PLATFORM_DIR"
                exit 1
            fi
        done
        PLATFORM_BUILD="$PLATFORM_DIR"
    fi

    local new_device_dir="$DOWNLOAD_PATH/new_device_dir"
    if [ -d "$new_device_dir" ]; then
        rm -rf "$new_device_dir"
    fi
    mkdir -p "$new_device_dir"
    local mixed_build_cmd="$mix_kernel_cmd"
    if [ -d "${KERNEL_BUILD}" ]; then
        mixed_build_cmd+=" --gki_dir $KERNEL_BUILD"
    fi
    mixed_build_cmd+=" $PLATFORM_BUILD $VENDOR_KERNEL_BUILD $new_device_dir"
    log_info "Run: $mixed_build_cmd"
    eval $mixed_build_cmd
    device_image=$(ls $new_device_dir/*$PRODUCT-img*.zip)
    if [ ! -f "$device_image" ]; then
        log_error "New device image is not created in $new_device_dir"
        exit 1
    fi
    cp "$PLATFORM_BUILD"/bootloader.img $new_device_dir/.
    cp "$PLATFORM_BUILD"/radio.img $new_device_dir/.
    PLATFORM_BUILD="$new_device_dir"
}

get_kernel_version_from_boot_image() {
    local boot_image_path="$1"
    local version_output

    # Check for mainline kernel
    version_output=$(strings "$boot_image_path" | grep android.*-g.*-ab.* | tail -n 1)
    if [[ "$version_output" == *-mainline* ]]; then
        KERNEL_VERSION="android-mainline"
    elif [[ "$version_output" == *-android* ]]; then
        # Extract the substring between the first hyphen and the second hyphen
        KERNEL_VERSION=$(echo "$version_output" | awk -F '-' '{print $2"-"$1}' | cut -d '.' -f -2)
    else
       log_warn "Can not parse $version_output into kernel version"
       KERNEL_VERSION=
    fi
    log_info "Boot image $boot_image_path has kernel version: $KERNEL_VERSION"
}

function extract_device_kernel_version() {
    local kernel_string="$1"
    # Check if the string contains '-android'
    if [[ "$kernel_string" == *-mainline* ]]; then
        DEVICE_KERNEL_VERSION="android-mainline"
    elif [[ "$kernel_string" == *"-android"* ]]; then
        # Extract the substring between the first hyphen and the second hyphen
        DEVICE_KERNEL_VERSION=$(echo "$kernel_string" | awk -F '-' '{print $2"-"$1}' | cut -d '.' -f -2)
    else
       log_warn "Can not parse $kernel_string into kernel version"
    fi
    log_info "Device $DEVICE_SERIAL_NUMBER kernel version: $DEVICE_KERNEL_VERSION"
}

function is_device_adb_authorized() {
    local output
    output=$(adb devices | grep "$ADB_SERIAL_NUMBER")
    local message
    message="Device $ADB_SERIAL_NUMBER is unauthorized. Please authorize manually in the confirmation \
dialog on your Android device; or (recommended) set ADB_VENDOR_KEYS (go/adb-keys) in your local environment and \
then restart adb server with command (adb kill-server, adb start-server) to allow permanent authorization."

    if [[ "$output" == *unauthorized* ]]; then
        log_warn "$message"
        return 1 # Failed.
    fi
    return 0
}

function is_device_ready_for_adb_command() {
    local _output
    _output=$(adb -s "$ADB_SERIAL_NUMBER" shell getprop ro.serialno)
    if [[ -n "$_output" ]]; then
        log_info "Device $ADB_SERIAL_NUMBER is ready to take adb command"
        return 0 # Succeed. Device is ready for adb command
    fi
    log_warn "Device $ADB_SERIAL_NUMBER is not ready to take adb command yet"
    return 1 # Failed. Device is not ready for adb command
}

function get_device_info_from_adb() {
    log_info "Getting device info from adb device $ADB_SERIAL_NUMBER"

    # Parse values locally from the captured properties ---
    if [ -z "$DEVICE_SERIAL_NUMBER" ]; then
        DEVICE_SERIAL_NUMBER=$(adb -s "$ADB_SERIAL_NUMBER" shell getprop ro.serialno)
    fi

    if [[ -z "$PRODUCT" || "$PRODUCT" == "generic_arm64" ]]; then
        for property in "ro.product.board" "ro.build.product"; do
            local found_product=$(adb -s "$ADB_SERIAL_NUMBER" shell getprop "$property")
            if [[ -n "$found_product" && "$found_product" != "generic_arm64" ]]; then
                PRODUCT="$found_product" # Found a valid product
                log_info "Using $PRODUCT for product name from device property $property"
                break
            fi
        done
    fi

    # Final check: If we still don't have a valid product, it's a fatal error
    if [[ -z "$PRODUCT" || "$PRODUCT" == "generic_arm64" ]]; then
        log_error "Could not determine a valid hardware product for $ADB_SERIAL_NUMBER."
        exit 1
    fi

    # Get remaining info using the same efficient method or separate calls for non-getprop commands
    ABI=$(adb -s "$ADB_SERIAL_NUMBER" shell getprop ro.product.cpu.abi)
    BUILD_TYPE=$(adb -s "$ADB_SERIAL_NUMBER" shell getprop ro.build.type)
    SYSTEM_DLKM_INFO=$(adb -s "$ADB_SERIAL_NUMBER" shell getprop dev.mnt.blk.system_dlkm)
    BUILD_FINGERPRINT=$(adb -s "$ADB_SERIAL_NUMBER" shell getprop ro.build.fingerprint)

    DEVICE_KERNEL_STRING=$(adb -s "$ADB_SERIAL_NUMBER" shell uname -r)

    if [[ "$SERIAL_NUMBER" != "$DEVICE_SERIAL_NUMBER" ]]; then
        log_info "Notice: Provided serial $SERIAL_NUMBER differs from device serial $DEVICE_SERIAL_NUMBER."
    fi

    log_info "Device $SERIAL_NUMBER info: BUILD_FINGERPRINT=$BUILD_FINGERPRINT, ABI=$ABI, PRODUCT=$PRODUCT, \
BUILD_TYPE=$BUILD_TYPE, SYSTEM_DLKM_INFO=$SYSTEM_DLKM_INFO, DEVICE_KERNEL_STRING=$DEVICE_KERNEL_STRING"
    extract_device_kernel_version "$DEVICE_KERNEL_STRING"
}

# Helper function to robustly parse output from 'fastboot getvar'
_parse_fastboot_var() {
    local raw_output="$1"
    # Use awk to find the first line, split by ':', trail whitespance and print the value.
    echo "$raw_output" | awk 'NR==1{print; exit}' | cut -d ':' -f 2 | tr -d '[:space:]'
}

function get_device_info_from_fastboot() {
    # Only get DEVICE_SERIAL_NUMBER if it's not already set
    if [ -z "$DEVICE_SERIAL_NUMBER" ]; then
        log_info "Attempting to get serial number from $FASTBOOT_SERIAL_NUMBER..."

        # Use a loop to handle the retry logic cleanly
        for attempt in 1 2; do
            local _output
            _output=$(fastboot -s "$FASTBOOT_SERIAL_NUMBER" getvar serialno 2>&1)
            DEVICE_SERIAL_NUMBER=$(_parse_fastboot_var "$_output")

            # If we got a serial number, break the loop
            if [ -n "$DEVICE_SERIAL_NUMBER" ]; then
                log_info "Retrieved serial: $DEVICE_SERIAL_NUMBER"
                break
            fi

            # If it's the first failed attempt, reboot and retry
            if [ "$attempt" -eq 1 ]; then
                log_warn "Command returned nothing. Rebooting into bootloader and retrying..."
                reboot_device_into_bootloader
            fi
        done

        # If after all attempts the serial is still missing, this is a fatal error
        if [ -z "$DEVICE_SERIAL_NUMBER" ]; then
            log_error "Could not get device serial for $FASTBOOT_SERIAL_NUMBER after retry."
            exit 1
        fi
    fi

    # Only get PRODUCT if it's not already set
    if [ -z "$PRODUCT" ]; then
        log_info "Attempting to get product name from $FASTBOOT_SERIAL_NUMBER..."
        local _output
        _output=$(fastboot -s "$FASTBOOT_SERIAL_NUMBER" getvar product 2>&1)
        PRODUCT=$(_parse_fastboot_var "$_output")

        if [ -z "$PRODUCT" ]; then
            log_error "Could not get a valid product value for $FASTBOOT_SERIAL_NUMBER."
            exit 1
        fi
        log_info "Retrieved product: $PRODUCT"
    fi
}

function get_device_info() {
    if is_device_in_adb; then
        get_device_info_from_adb
        if [[ -x "$(command -v pontis)" ]] && pontis devices | grep -q "$DEVICE_SERIAL_NUMBER.*ADB"; then
            THROUGH_PONTIS=true
            log_info "$SERIAL_NUMBER: DEVICE_SERIAL_NUMBER=$DEVICE_SERIAL_NUMBER, \
ADB_SERIAL_NUMBER=$ADB_SERIAL_NUMBER"
        fi
        return 0
    fi

    if is_device_in_fastboot; then
        get_device_info_from_fastboot
        if [[ -x "$(command -v pontis)" ]] && pontis devices | grep -q "$DEVICE_SERIAL_NUMBER.*Fastboot"; then
            THROUGH_PONTIS=true
            log_info "$SERIAL_NUMBER: DEVICE_SERIAL_NUMBER=$DEVICE_SERIAL_NUMBER, \
FASTBOOT_SERIAL_NUMBER=$FASTBOOT_SERIAL_NUMBER"
        fi
        return 0
    fi
    log_error "$SERIAL_NUMBER is not connected in adb or fastboot"
    exit 1
}

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$( cd "$( dirname "${SCRIPT_PATH}" )" &> /dev/null && pwd -P)"
LIB_PATH="${SCRIPT_DIR}/common_lib.sh"
if [[ -f "$LIB_PATH" ]]; then
    if ! . "$LIB_PATH"; then
        log_error "Cannot load library $LIB_PATH"
        exit 1
    fi
else
    log_error "Cannot find library $LIB_PATH"
    exit 1
fi

if ! check_commands_available "${REQUIRED_COMMANDS[@]}"; then
    log_error "One or more required commands are missing. Please install them and retry."
    exit 1
fi

OLD_PWD=$PWD
MY_NAME=$0

parse_arg "$@"

if [ -z "$SERIAL_NUMBER" ]; then
    log_error "Device serial is not provided with flag -s <serial_number>."
    exit 1
fi

if [ ! -d "$DOWNLOAD_PATH" ]; then
    mkdir -p "$DOWNLOAD_PATH" || { log_error "Fail to create directory $DOWNLOAD_PATH" && exit 1; }
fi

get_device_info

if is_in_repo_workspace; then
    go_to_repo_root "$PWD"
else
    log_warn "Current path $PWD is not in an Android repo. Change path to repo root."
    go_to_repo_root "$SCRIPT_DIR"
fi

readonly REPO_ROOT_PATH="$PWD"
readonly FETCH_SCRIPT="$REPO_ROOT_PATH/$FETCH_SCRIPT_PATH_IN_REPO"

find_repo

[[ "$PLATFORM_BUILD" == "None" ]] && PLATFORM_BUILD=""
[[ "$KERNEL_BUILD" == "None" ]] && KERNEL_BUILD=""
[[ "$VENDOR_KERNEL_BUILD" == "None" ]] && VENDOR_KERNEL_BUILD=""

# --- Platform Build Processing ---
if [[ "$PLATFORM_BUILD" == ab://* ]]; then
    format_ab_platform_build_string
elif [ -n "$PLATFORM_BUILD" ] && [ -d "$PLATFORM_BUILD" ]; then
    # Check if PLATFORM_BUILD is an Android platform repo
    cd "$PLATFORM_BUILD"  || { log_error "Fail to go to $PLATFORM_BUILD" && exit 1; }
    PLATFORM_REPO_LIST_OUT=$(repo list 2>&1)
    if [[ "$PLATFORM_REPO_LIST_OUT" != "error"* ]]; then
        go_to_repo_root "$PWD"
        if [[ "$PWD" != "$REPO_ROOT_PATH" ]]; then
            find_repo
        fi
        if [ "$SKIP_BUILD" = false ] && [[ "$PLATFORM_BUILD" != "ab://"* ]] && [[ -n "$PLATFORM_BUILD" ]]; then
            if [ -z "${TARGET_PRODUCT}" ] || [[ "${TARGET_PRODUCT}" != *"$PRODUCT" ]]; then
                if [[ "$PLATFORM_VERSION" == aosp-* ]]; then
                    set_platform_repo "aosp_$PRODUCT"
                else
                    set_platform_repo "$PRODUCT"
                fi
            elif [[ "${TARGET_PRODUCT}" == *"$PRODUCT" ]]; then
                echo "TARGET_PRODUCT=${TARGET_PRODUCT}, ANDROID_PRODUCT_OUT=${ANDROID_PRODUCT_OUT}"
            fi
            if [[ "${TARGET_PRODUCT}" == *"$PRODUCT" ]]; then
                build_platform
            else
                log_error "Can not build platform build due to lunch build target failure"
                exit 1
            fi
        fi
        if [ -d "${PLATFORM_REPO_ROOT}" ] && [ -f "$PLATFORM_REPO_ROOT/out/target/product/$PRODUCT/otatools.zip" ]; then
            PLATFORM_BUILD=$PLATFORM_REPO_ROOT/out/target/product/$PRODUCT
        elif [ -d "${ANDROID_PRODUCT_OUT}" ] && [ -f "${ANDROID_PRODUCT_OUT}/otatools.zip" ]; then
            PLATFORM_BUILD="${ANDROID_PRODUCT_OUT}"
        else
            PLATFORM_BUILD=
        fi
    fi
fi

find_flashstation_binary

if [[ "$KERNEL_BUILD" == ab://* ]]; then
    format_ab_kernel_build_string
    download_gki_build
elif [ -n "$KERNEL_BUILD" ] && [ -d "$KERNEL_BUILD" ]; then
    # Check if kernel repo is provided
    cd "$KERNEL_BUILD" || { log_error "Fail to go to $KERNEL_BUILD" && exit 1; }
    KERNEL_REPO_LIST_OUT=$(repo list 2>&1)
    if [[ "$KERNEL_REPO_LIST_OUT" != "error"* ]]; then
        log_info "$KERNEL_BUILD is in a kernel tree repo"
        go_to_repo_root "$PWD"
        if [[ "$PWD" != "$REPO_ROOT_PATH" ]]; then
            find_repo
        fi
        if [ "$SKIP_BUILD" = false ] ; then
            if [ ! -f "common/BUILD.bazel" ]; then
                # TODO: Add build support to android12 and earlier kernels
                log_error "bazel build is not supported in $PWD"
                exit 1
            else
                build_ack
            fi
        fi
        KERNEL_BUILD="$PWD/out/kernel_aarch64/dist"
    elif [ -f "$KERNEL_BUILD/boot.img" ]; then
        get_kernel_version_from_boot_image "$KERNEL_BUILD/boot.img"
    elif [ -f "$KERNEL_BUILD/boot-lz4.img" ]; then
        get_kernel_version_from_boot_image "$KERNEL_BUILD/boot-lz4.img"
    elif [ -f "$KERNEL_BUILD/boot-gz.img" ]; then
        get_kernel_version_from_boot_image "$KERNEL_BUILD/boot-gz.img"
    fi
fi

if [[ "$VENDOR_KERNEL_BUILD" == ab://* ]]; then
    format_ab_vendor_kernel_build_string
    log_info "Download vendor kernel build $VENDOR_KERNEL_BUILD"
    if [ -d "$DOWNLOAD_PATH/vendor_kernel_dir" ]; then
        rm -rf "$DOWNLOAD_PATH/vendor_kernel_dir"
    fi
    VENDOR_KERNEL_DIR="$DOWNLOAD_PATH/vendor_kernel_dir"
    mkdir -p "$VENDOR_KERNEL_DIR"
    cd "$VENDOR_KERNEL_DIR" || { log_error "Fail to go to $VENDOR_KERNEL_DIR" && exit 1; }
    if [ -z "$PLATFORM_BUILD" ]; then
        download_vendor_kernel_for_direct_flash $VENDOR_KERNEL_BUILD
    else
        download_vendor_kernel_build $VENDOR_KERNEL_BUILD
    fi
    VENDOR_KERNEL_BUILD="$VENDOR_KERNEL_DIR"
elif [ -n "$VENDOR_KERNEL_BUILD" ] && [ -d "$VENDOR_KERNEL_BUILD" ]; then
    # Check if vendor kernel repo is provided
    cd "$VENDOR_KERNEL_BUILD"  || { log_error "Fail to go to $VENDOR_KERNEL_BUILD" && exit 1; }
    VENDOR_KERNEL_REPO_LIST_OUT=$(repo list 2>&1)
    if [[ "$VENDOR_KERNEL_REPO_LIST_OUT" != "error"* ]]; then
        go_to_repo_root "$PWD"
        if [[ "$PWD" != "$REPO_ROOT_PATH" ]]; then
            find_repo
        fi
        if [ -z "$VENDOR_KERNEL_BUILD_TARGET" ]; then
            kernel_build_target_count=$(ls build_*.sh | wc -w)
            if (( kernel_build_target_count == 1 )); then
                VENDOR_KERNEL_BUILD_TARGET=$(echo $(ls build_*.sh) | sed 's/build_\(.*\)\.sh/\1/')
            elif (( kernel_build_target_count > 1 )); then
                log_warn "There are multiple build_*.sh scripts in $PWD, Can't decide vendor kernel build target"
                log_error "Please use -vkbt <value> or --vendor-kernel-build-target=<value> to specify a kernel \
build target"
                exit 1
            else
                # TODO: Add build support to android12 and earlier kernels
                log_error "There is no build_*.sh script in $PWD"
                exit 1
            fi
        fi
        if [ "$SKIP_BUILD" = false ] ; then
            build_cmd="./build_$VENDOR_KERNEL_BUILD_TARGET.sh"
            if [ "$GCOV" = true ]; then
                build_cmd+=" --gcov"
            fi
            if [ "$DEBUG" = true ]; then
                build_cmd+=" --debug"
            fi
            if [ "$KASAN" = true ]; then
                build_cmd+=" --kasan"
            fi
            log_info "Build vendor kernel with $build_cmd"
            eval "$build_cmd"
            exit_code=$?
            if [ $exit_code -eq 0 ]; then
                log_info "Build vendor kernel succeeded"
            else
                log_error "Build vendor kernel failed with exit code $exit_code"
                exit 1
            fi
        fi
        VENDOR_KERNEL_BUILD="$PWD/out/$VENDOR_KERNEL_BUILD_TARGET/dist"
    fi
fi

if [ -z "$PLATFORM_BUILD" ]; then  # No platform build provided
    if [ -z "$KERNEL_BUILD" ] && [ -z "$VENDOR_KERNEL_BUILD" ] && [ -z "$SYSTEM_BUILD" ]; then
        log_info "KERNEL_BUILD=$KERNEL_BUILD VENDOR_KERNEL_BUILD=$VENDOR_KERNEL_BUILD"
        log_error "Nothing to flash"
        exit 1
    fi
    if [ -n "$VENDOR_KERNEL_BUILD" ]; then
        log_info "Flash kernel from $VENDOR_KERNEL_BUILD"
        flash_vendor_kernel_build
    fi
    if [ -n "$KERNEL_BUILD" ]; then
        flash_gki_build
    fi
else  # Platform build provided
    if [ -z "$KERNEL_BUILD" ] && [ -z "$VENDOR_KERNEL_BUILD" ]; then  # No kernel or vendor kernel build
        log_info "Flash platform build from $PLATFORM_BUILD"
        flash_platform_build
    elif [ -z "$KERNEL_BUILD" ] && [ -n "$VENDOR_KERNEL_BUILD" ]; then  # Vendor kernel build and platform build
        log_info "Mix vendor kernel and platform build"
        mixing_build
        flash_platform_build
    elif [ -n "$KERNEL_BUILD" ] && [ -z "$VENDOR_KERNEL_BUILD" ]; then # GKI build and platform build
        flash_platform_build
        flash_gki_build
    elif [ -n "$KERNEL_BUILD" ] && [ -n "$VENDOR_KERNEL_BUILD" ]; then  # All three builds provided
        log_info "Mix GKI kernel, vendor kernel and platform build"
        mixing_build
        flash_platform_build
    fi
fi

if [[ "$SYSTEM_BUILD" == ab://* ]]; then
    format_ab_system_build_string
elif [ -n "$SYSTEM_BUILD" ] && [ -d "$SYSTEM_BUILD" ]; then
    cd "$SYSTEM_BUILD"  || { log_error "Fail to go to $SYSTEM_BUILD" && exit 1; }
    SYSTEM_REPO_LIST_OUT=$(repo list 2>&1)
    if [[ "$SYSTEM_REPO_LIST_OUT" != "error"* ]]; then
        go_to_repo_root "$PWD"
        if [[ "$PWD" != "$REPO_ROOT_PATH" ]]; then
            find_repo
        fi
        if [ -z "${TARGET_PRODUCT}" ] || [[ "${TARGET_PRODUCT}" != "gsi_arm64" ]]; then
            set_platform_repo "gsi_arm64"
            if [ "$SKIP_BUILD" = false ] ; then
                build_platform
            fi
            SYSTEM_BUILD="${ANDROID_PRODUCT_OUT}"
        fi
    fi
fi

if [ -n "$SYSTEM_BUILD" ]; then
    flash_system_build
fi
