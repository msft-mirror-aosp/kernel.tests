#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

# A handy tool to flash device with local build or remote build.

# Constants
# Please see go/cl_flashstation

set -euo pipefail

MIX_SCRIPT_NAME="build_mixed_kernels_ramdisk"
MIN_FASTBOOT_VERSION="35.0.2-12583183"
VENDOR_KERNEL_IMGS=("boot.img" "initramfs.img" "dtb.img" "dtbo.img" "vendor_dlkm.img")
# For Pixel kernel branches like kernel-pixel-android*-gs-pixel*
VENDOR_KERNEL_IMGS_PIXEL_BRANCH=("boot.img" "vendor_kernel_boot.img" "dtbo.img" "vendor_dlkm.img" "system_dlkm.img")
SKIP_UPDATE_BOOTLOADER=false
SKIP_BUILD=false
GCOV=false
DEBUG=false
KASAN=false
DISABLE_VERIFICATION=true
EXTRA_OPTIONS=()
DEVICE_VARIANT="userdebug"
DEVICE_LUNCH_TARGET=
FLASH_LOGICAL_PARTITION_FIRST=false

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
USE_DSU=false
FORCE_DEBUGGABLE=true

SERIAL_NUMBER=
FASTBOOT_SERIAL_NUMBER=
ADB_SERIAL_NUMBER=
DEVICE_SERIAL_NUMBER=

GSI_BUILD=
PLATFORM_BUILD=
KERNEL_BUILD=
VENDOR_KERNEL_BUILD=
FASTBOOT_FLASH_OPTION=

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
    echo "  --use-dsu             [Optional] Whether to use DSU to install GSI image"
    echo "  --no-disable-verification"
    echo "                        [Optional] Do not disable verification"
    echo "  --no-force-debuggable"
    echo "                        [Optional] Do not force debuggable on user build"
    echo "  -pb <platform_build>, --platform-build=<platform_build>"
    echo "                        [Optional] The platform build path. Can be a local path or a remote build"
    echo "                        as ab://<branch>/<build_target>/<build_id>."
    echo "                        If not specified and the script is running from a platform repo,"
    echo "                        it will use the platform build in the local repo."
    echo "                        If string 'none' is set, no platform build will be flashed,"
    echo "  -gsi <gsi_build>, --gsi-build=<GSI_build>"
    echo "                        [Optional] The GSI build path for GSI testing. Can be a local path or"
    echo "                        remote build as ab://<branch>/<build_target>/<build_id>."
    echo "                        If not specified, no GSI build will be used."
    echo "  -kb <kernel_build>, --kernel-build=<kernel_build>, -gki <gki_build>, --gki-build=<gki_build>"
    echo "                        [Optional] The kernel build path. Can be a local path or a remote build"
    echo "                        as ab://<branch>/<build_target>/<build_id>."
    echo "                        If not specified and the script is running from an Android common kernel repo,"
    echo "                        it will use the kernel in the local repo."
    echo "                        If string 'none' is set, no kernel build will be flashed,"
    echo "  -vkb <vendor_kernel_build>, --vendor-kernel-build=<vendor_kernel_build>"
    echo "                        [Optional] The vendor kernel build path. Can be a local path or a remote build"
    echo "                        as ab://<branch>/<build_target>/<build_id>."
    echo "                        If not specified, and the script is running from a vendor kernel repo, "
    echo "                        it will use the kernel in the local repo."
    echo "                        If string 'none' is set, no vendor kernel build will be flashed,"
    echo "  -vkbt <vendor_kernel_build_target>, --vendor-kernel-build-target=<vendor_kernel_build_target>"
    echo "                        [Optional] The vendor kernel build target to be used to build vendor kernel."
    echo "                        If not specified, and the script is running from a vendor kernel repo, "
    echo "                        it will try to find a local build target in the local repo."
    echo "  --device-variant=<device_variant>"
    echo "                        [Optional] Device variant such as userdebug, user, or eng."
    echo "                        If not specified, will be userdebug by default."
    echo "  --device-lunch-target=<device_lunch_target>"
    echo "                        [Optional] Device lunch target such as frankel_16k-trunk_pixel_kernel_6_12-userdebug."
    echo "                        If not specified, will use default."
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
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                print_help
                ;;
            -s)
                shift
                if (( $# > 0 )); then
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
                if (( $# > 0 )); then
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
            -gsi)
                shift
                if (( $# > 0 )); then
                    GSI_BUILD=$1
                else
                    log_error "GSI build is not specified"
                    exit 1
                fi
                shift
                ;;
            --gsi-build=*)
                GSI_BUILD=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            -sb)
                shift
                if (( $# > 0 )); then
                    GSI_BUILD=$1
                else
                    log_error "GSI build is not specified"
                    exit 1
                fi
                shift
                ;;
            --system-build=*)
                GSI_BUILD=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            -kb)
                shift
                if (( $# > 0 )); then
                    KERNEL_BUILD=$1
                else
                    log_error "gki kernel build path is not specified"
                    exit 1
                fi
                shift
                ;;
            --kernel-build=*)
                KERNEL_BUILD=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            -gki)
                shift
                if (( $# > 0 )); then
                    KERNEL_BUILD=$1
                else
                    log_error "GKI kernel build is not specified"
                    exit 1
                fi
                shift
                ;;
            --gki-build=*)
                KERNEL_BUILD=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            -vkb)
                shift
                if (( $# > 0 )); then
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
                if (( $# > 0 )); then
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
            --device-lunch-target=*)
                DEVICE_LUNCH_TARGET=$(echo $1 | sed -e "s/^[^=]*=//g")
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
            --dsu)
                USE_DSU=true
                shift
                ;;
            --no-disable-verification)
                DISABLE_VERIFICATION=false
                shift
                ;;
            --no-force-debuggable)
                FORCE_DEBUGGABLE=false
                shift
                ;;
            *)
                log_error "Unsupported flag: $1" >&2
                exit 1
                ;;
        esac
    done
}

function find_repo() {
    manifest_output=$(grep -e "platform/system/core" -e "gs-pixel" -e "kernel/common" \
     -e "common-modules/virtual-device" -e "private/google-modules/soc/gs" .repo/manifests/default.xml)
    if [[ -d "system/core" && "$manifest_output" == *platform/system/core* ]]; then
        log_info "I am in an Android platform tree"
        PLATFORM_REPO_ROOT="$PWD"
        if [[ -z "$PLATFORM_BUILD" || "$PLATFORM_REPO_ROOT" == "$PLATFORM_BUILD" ]]; then
            PLATFORM_VERSION=$(sed -n 's/^BUILD_ID=\(.*\)/\1/p' build/make/core/build_id.mk)
            log_info "PLATFORM_REPO_ROOT=$PLATFORM_REPO_ROOT, PLATFORM_VERSION=$PLATFORM_VERSION"
            PLATFORM_BUILD="$PLATFORM_REPO_ROOT"
        fi
    elif [[ -d "private/google-modules/soc" && "$manifest_output" == *private/google-modules/soc* ]]; then
        VENDOR_KERNEL_REPO_ROOT="$PWD"
        log_info "I am in an Android vendor kernel tree"
        if [[ -z "$VENDOR_KERNEL_BUILD" ]]; then
            VENDOR_KERNEL_VERSION=$(grep -e "default revision" .repo/manifests/default.xml | \
            grep -oP 'revision="\K[^"]*')
            log_info "VENDOR_KERNEL_REPO_ROOT=$VENDOR_KERNEL_REPO_ROOT"
            log_info "VENDOR_KERNEL_VERSION=$VENDOR_KERNEL_VERSION"
            VENDOR_KERNEL_BUILD="$VENDOR_KERNEL_REPO_ROOT"
        fi
    elif [[ -d "common/kernel/" ]] && [[ -d "common-modules/virtual-device" ]] && \
    [[ "$manifest_output" == *kernel/common* ]] && [[ "$manifest_output" == *common-modules/virtual-device* ]]; then
        log_info "I am in an Android Common Kernel tree"
        KERNEL_REPO_ROOT="$PWD"
        if [[ -z "$KERNEL_BUILD" ]]; then
            KERNEL_VERSION=$(grep -e "kernel/superproject" \
            .repo/manifests/default.xml | grep -oP 'revision="common-\K[^"]*')
            log_info "KERNEL_REPO_ROOT=$KERNEL_REPO_ROOT, KERNEL_VERSION=$KERNEL_VERSION"
            KERNEL_BUILD="$KERNEL_REPO_ROOT"
        fi
    else
        log_warn "Unknown manifest output. Could not determine repository type."
    fi
}

function build_platform() {
    if [[ "$SKIP_BUILD" == "true" ]]; then
        log_warn "--skip-build is set. Do not rebuild platform build"
        return
    fi
    build_cmd="m -j18"
    if [[ "${TARGET_PRODUCT:-}" != "gsi_arm64" && -n "$VENDOR_KERNEL_BUILD" ]]; then
        build_cmd+=" droid otatools-package dist DIST_DIR=out/dist/$PRODUCT"
    fi
    log_warn "Flag --skip-build is not set. Rebuilt images at $PWD with: $build_cmd"
    eval $build_cmd
    exit_code=$?
    if (( exit_code == 1 )); then
        log_warn "$build_cmd returned exit_code $exit_code"
        log_error "$build_cmd failed"
        exit 1
    fi
}

function build_ack() {
    if [[ "$SKIP_BUILD" == "true" ]]; then
        log_warn "--skip-build is set. Do not rebuild kernel"
        return
    fi
    build_cmd="tools/bazel run --config=fast"
    if [[ "$GCOV" == "true" ]]; then
        build_cmd+=" --gcov"
    fi
    if [[ "$DEBUG" == "true" ]]; then
        build_cmd+=" --debug"
    fi
    if [[ "$KASAN" == "true" ]]; then
        build_cmd+=" --kasan"
    fi
    build_cmd+=" //common:kernel_aarch64_dist"
    log_warn "Flag --skip-build is not set. Rebuild the kernel with: $build_cmd."
    eval $build_cmd
    exit_code=$?
    if (( exit_code == 0 )); then
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
    if [[ "$PLATFORM_BUILD" == ab:// ]]; then
        if [[ -n "$PRODUCT" ]]; then
            PLATFORM_BUILD+="git_main/$PRODUCT-trunk_staging-userdebug/latest"
            log_info "No explicit platform_build info is provided. Use $PLATFORM_BUILD by default"
        else
            log_error "Can not derive derive default platform build through device info. Please \
            provide platform build in the form of ab://<branch>/<build_target> or \
            ab://<branch>/<build_target>/<build_id>"
            exit 1
        fi
    else
        local path_string="${PLATFORM_BUILD#ab://}"
        IFS='/' read -ra array <<< "$path_string"
        local array_len="${#array[@]}"
        if (( array_len == 1 )); then
            if [[ -n "$PRODUCT" ]]; then
                if [[ ${array[0]} == git_main* ]]; then
                    PLATFORM_BUILD+="$PRODUCT-trunk_staging-userdebug/latest"
                    log_info "No explicit build target is provided in platform_build string. Use $PLATFORM_BUILD by default"
                else
                    PLATFORM_BUILD+="$PRODUCT-userdebug/latest"
                    log_info "No explicit build target is provided in platform_build string. Use $PLATFORM_BUILD by default"
                fi
           else
                log_error "Can not derive derive default platform build through device info. Please \
                provide platform build in the form of ab://<branch>/<build_target> or \
                ab://<branch>/<build_target>/<build_id>"
                exit 1
            fi
        elif (( array_len == 2 )); then
            PLATFORM_BUILD+="/latest"
        fi
    fi
    local updated_ab_string=""
    if ! convert_ab_string "$PLATFORM_BUILD" updated_ab_string; then
        log_error "Invalid Android Build string $PLATFORM_BUILD."
        exit 1
    fi
    PLATFORM_BUILD="$updated_ab_string"
    log_info "Platform build to be used is $PLATFORM_BUILD"
}

function format_ab_gsi_build_string() {
    if [[ "$GSI_BUILD" != ab://* ]]; then
        log_error "Please provide the GSI build in the form of ab:// with flag -gsi"
        exit 1
    fi
    if [[ "$GSI_BUILD" == ab:// ]]; then
        log_info "No explicit GSI build info is provided. Use git_main GSI build by default"
        GSI_BUILD+="git_main/gsi_arm64-trunk_staging-userdebug/latest"
    else
        local path_string="${GSI_BUILD#ab://}"
        IFS='/' read -ra array <<< "$path_string"
        local array_len="${#array[@]}"
        if (( array_len == 1 )); then
            if [[ "${array[0]}" == git_main* ]]; then
                GSI_BUILD+="/gsi_arm64-trunk_staging-userdebug/latest"
            else
                GSI_BUILD+="/gsi_arm64-userdebug/latest"
            fi
        elif (( array_len == 2 )) && [[ -z "${array[1]}" ]]; then
            if [[ "${array[0]}" == git_main* ]]; then
                GSI_BUILD+="gsi_arm64-trunk_staging-userdebug/latest"
            else
                GSI_BUILD+="gsi_arm64-userdebug/latest"
            fi
        elif (( array_len == 2 )); then
            GSI_BUILD+="/latest"
        fi
    fi
    updated_ab_string=""
    if ! convert_ab_string "$GSI_BUILD" updated_ab_string; then
        log_error "Invalid Android Build string $GSI_BUILD."
        exit 1
    fi
    GSI_BUILD="$updated_ab_string"
    log_info "GSI build to be used is $GSI_BUILD"
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
    if [[ -z "$_branch" ]]; then
        log_info "$KERNEL_BUILD provided in -kb doesn't have branch info. Will use the kernel version from device"
        if [[ -z "$DEVICE_KERNEL_VERSION" ]]; then
            log_error "The kernel version can not be retrieved from device to decide kernel build"
            exit 1
        fi
        log_info "Branch is not specified in kernel build as ab://<branch>. Using device's existing kernel version $DEVICE_KERNEL_VERSION."
        _branch="$DEVICE_KERNEL_VERSION"
        KERNEL_VERSION="$DEVICE_KERNEL_VERSION"
    else
        if [[ "$_branch" == *mainline* ]]; then
            KERNEL_VERSION="android-mainline"
        elif [[ "$KERNEL_BUILD" == ab://git_sc-gsi-release/gsi_arm64-user* ]]; then
            KERNEL_VERSION="android12-5.10"
        else
            local _android_version=$(echo "$_branch" | grep -oE 'android[0-9]+')
            local _kernel_version=$(echo "$_branch" | grep -oE '[0-9]+\.[0-9]+')
            if [[ -z "$_android_version" || -z "$_kernel_version" ]]; then
                log_warn "Unable to get kernel version from $KERNEL_BUILD"
            else
                KERNEL_VERSION="$_android_version-$_kernel_version"
            fi
        fi
    fi
    if [[ "$_branch" == android* ]]; then
        _branch="aosp_kernel-common-$_branch"
    fi
    if [[ -z "$_build_target" ]]; then
        _build_target="kernel_aarch64"
    fi
    if [[ "$_build_target" != kernel_aarch* ]]; then
        log_error "The provided kernel build $KERNEL_BUILD is not an Android Common Kernel build target like kernel_aarch*"
        exit 1
    fi
    if [[ -z "$_build_id" ]]; then
        _build_id="latest"
    fi
    updated_ab_string=""
    if ! convert_ab_string "ab://$_branch/$_build_target/$_build_id" updated_ab_string; then
        log_error "Invalid Android Build string ab://$_branch/$_build_target/$_build_id."
        exit 1
    fi
    KERNEL_BUILD="$updated_ab_string"
    log_info "Kernel build to be used is $KERNEL_BUILD"
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
    if [[ -z "$_branch" ]]; then
        if [[ -z "$DEVICE_KERNEL_VERSION" ]]; then
            log_error "Branch is not provided in vendor kernel build $VENDOR_KERNEL_BUILD. \
            The kernel version can not be retrieved from device to decide vendor kernel build"
            exit 1
        fi
        log_info "Branch is not specified in kernel build as ab://<branch>. Using $DEVICE_KERNEL_VERSION vendor kernel branch."
        _branch="$DEVICE_KERNEL_VERSION"
    fi
    case "$_branch" in
        android-mainline )
            if [[ "$PRODUCT" == "raven" || "$PRODUCT" == "oriole" ]]; then
                _branch="kernel-android-gs-pixel-mainline"
                if [[ -z "$_build_target" ]]; then
                    _build_target="kernel_raviole_kleaf"
                fi
            else
                log_error "There is no vendor kernel branch $_branch for $PRODUCT device"
                exit 1
            fi
            ;;
        android16-6.12 )
            if [[ "$PRODUCT" == "raven" || "$PRODUCT" == "oriole" ]]; then
                _branch="kernel-android16-6.12-gs101"
                if [[ -z "$_build_target" ]]; then
                    _build_target="kernel_raviole"
                fi
            else
                log_error "There is no vendor kernel branch $_branch for $PRODUCT device"
                exit 1
            fi
            ;;
        android15-6.6 )
            if [[ "$PRODUCT" == "raven" || "$PRODUCT" == "oriole" ]]; then
                _branch="kernel-android15-gs-pixel-6.6"
                if [[ -z "$_build_target" ]]; then
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
            if [[ "$PRODUCT" == "husky" || "$PRODUCT" == "shiba" ]]; then
                _branch="kernel-android14-gs-pixel-5.15"
                if [[ -z "$_build_target" ]]; then
                    _build_target="shusky"
                fi
            elif [[ "$PRODUCT" == "akita" ]]; then
                _branch="kernel-android14-gs-pixel-5.15"
                if [[ -z "$_build_target" ]]; then
                    _build_target="akita"
                fi
            else
                log_error "There is no vendor kernel branch $_branch for $PRODUCT device"
                exit 1
            fi
            ;;
        android13-5.15 )
            if [[ "$PRODUCT" == "raven" || "$PRODUCT" == "oriole" ]]; then
                _branch="kernel-android13-gs-pixel-5.15-gs101"
                if [[ -z "$_build_target" ]]; then
                    _build_target="kernel_raviole_kleaf"
                fi
                if [[ "$DISABLE_VERIFICATION" == "false" ]]; then
                    log_info "Disable verification as android13-5.15 can only be integrated with older platform branch."
                    DISABLE_VERIFICATION=true
                fi
            else
                log_error "There is no vendor kernel branch $_branch for $PRODUCT device"
                exit 1
            fi
            ;;
        android13-5.10 )
            if [[ "$PRODUCT" == "raven" || "$PRODUCT" == "oriole" ]]; then
                _branch="kernel-android13-gs-pixel-5.10"
                if [[ -z "$_build_target" ]]; then
                    _build_target="slider_gki"
                fi
                if [[ "$DISABLE_VERIFICATION" == "false" ]]; then
                    log_info "Disable verification as android13-5.10 can only be integrated with older platform branch."
                    DISABLE_VERIFICATION=true
                fi
            elif [[ "$PRODUCT" == "felix" || "$PRODUCT" == "lynx" || "$PRODUCT" == "tangorpro" ]]; then
                _branch="kernel-android13-gs-pixel-5.10"
                if [[ -z "$_build_target" ]]; then
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
    if [[ -z "$_build_target" ]]; then
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
    if [[ -z "$_build_id" ]]; then
        _build_id="latest"
    fi
    updated_ab_string=""
    if ! convert_ab_string "ab://$_branch/$_build_target/$_build_id" updated_ab_string; then
        log_error "Invalid Android Build string ab://$_branch/$_build_target/$_build_id."
        exit 1
    fi
    VENDOR_KERNEL_BUILD="$updated_ab_string"
    log_info "Vendor kernel build to be used is $VENDOR_KERNEL_BUILD"
}

function download_platform_build() {
    log_info "Downloading $PLATFORM_BUILD"
    local _device_dir="$DEVICE_DIR/$DEVICE_SERIAL_NUMBER"
    # Clean up pre-existing device directory
    if [[ -d "$_device_dir" ]]; then
        rm -rf "$_device_dir" || { log_error "Failed to clean up $_device_dir" && exit 1; }
    fi
    mkdir -p "$_device_dir" || { log_error "Failed to create $_device_dir folder" && exit 1; }
    local _build_info="$PLATFORM_BUILD"
    local _file_patterns=( "*$PRODUCT-img-*.zip" "radio.img" )
    if [[ "$SKIP_UPDATE_BOOTLOADER" == "false" || -n "$VENDOR_KERNEL_BUILD" ]]; then
        _file_patterns+=("bootloader.img")
    fi
    if [[ -n "$VENDOR_KERNEL_BUILD" ]]; then
        _file_patterns+=( "misc_info.txt" "otatools.zip" )
        if [[ "$_build_info" == *git_sc* ]]; then
            _file_patterns+=( "ramdisk.img" )
        elif [[ "$_build_info" == *user/* && "$FORCE_DEBUGGABLE" == "true" ]]; then
            _file_patterns+=( "vendor_ramdisk-debug.img" )
        fi
    fi
    if [[ -n "$KERNEL_BUILD" && "$_build_info" == *git_sc* ]]; then
        _file_patterns+=( "ramdisk.img" )
    fi

    local _file_path="${PLATFORM_BUILD/ab:\/\//}"
    local _full_file_path="$DOWNLOAD_PATH/$_file_path"
    for _pattern in "${_file_patterns[@]}"; do
        log_info "Downloading $_build_info/$_pattern"
        eval "$FETCH_SCRIPT $_build_info/$_pattern"
        exit_code=$?
        if (( exit_code == 0 )); then
            log_info "Downloaded $_build_info/$_pattern"
        else
            log_error "Fail to download $_build_info/$_pattern"
            exit 1
        fi
        local _full_file_name=$(find "$_full_file_path" -maxdepth 1 -type f -name "$_pattern")
        local _file_name="${_full_file_name##*/}"
        local _new_file_name="$_file_name"
        if [[ "$_file_name" == "vendor_ramdisk-debug.img" ]]; then
            _new_file_name="vendor_ramdisk.img"
        fi
        if ! create_soft_link "$_full_file_name" "$_device_dir/$_new_file_name"; then
            exit 1
        fi
    done
    PLATFORM_BUILD="$_device_dir"
    echo ""
}

function download_gsi_build() {
    log_info "Downloading $GSI_BUILD"
    local _build_info="$GSI_BUILD"
    local _file_pattern="*_arm64-img-*.zip"
    local _file_path="${_build_info/ab:\/\//}"
    local _full_file_path="$DOWNLOAD_PATH/$_file_path"
    local _gsi_dir="$GSI_DIR/$DEVICE_SERIAL_NUMBER"
    # Clean up gsi directory
    if [[ -d "$_gsi_dir" ]]; then
        rm -rf "$_gsi_dir" || { log_error "Failed to clean up $_gsi_dir" && exit 1; }
    fi
    mkdir -p "$_gsi_dir" || { log_error "Failed to create $_gsi_dir folder" && exit 1; }

    if [[ ! -d "$_full_file_path" ]]; then
        mkdir -p "$_full_file_path" || { log_error "Failed to create folder $_full_file_path" && exit 1; }
    fi
    log_info "Downloading $_build_info/$_file_pattern"
    eval "$FETCH_SCRIPT $_build_info/$_file_pattern"
    exit_code=$?
    if (( exit_code == 0 )); then
        log_info "Downloading $_build_info/$_file_pattern succeeded"
    else
        log_error "Downloading $_build_info/$_file_pattern failed"
        exit 1
    fi
    local _gsi_image=$(find "$_full_file_path" -maxdepth 1 -type f -name "$_file_pattern")
    if [[ -f "$_gsi_image" ]]; then
        unzip -j "$_gsi_image" -d "$_gsi_dir"
        if [[ ! -f "$_gsi_dir/system.img" ]]; then
            log_error "There is no system.img in $_gsi_image"
            exit 1
        fi
    else
        log_error "$GSI_BUILD doesn't have a valid GSI system image"
        exit 1
    fi
    GSI_BUILD="$_gsi_dir"
    echo ""
}

function download_kernel_build() {
    log_info "Download GKI artifacts from $KERNEL_BUILD"
    local _kernel_dir="$KERNEL_DIR/$DEVICE_SERIAL_NUMBER"

    # Clean up the pre-existing directory
    if [[ -d "$_kernel_dir" ]]; then
        rm -rf "$_kernel_dir" || { log_error "Failed to clean up $_kernel_dir" && exit 1; }
    fi
    mkdir -p "$_kernel_dir" || { log_error "Failed to create $_kernel_dir folder" && exit 1; }

    log_info "Downloading kernel build $KERNEL_BUILD"

    local _build_info="$KERNEL_BUILD"
    local _file_patterns
    case "$PRODUCT" in
        oriole | raven | bluejay)
            _file_patterns=( "boot-lz4.img" )
            if [[ "$KERNEL_BUILD" == *android12-5.10* ]]; then
                _file_patterns=( "Image.lz4" )
            elif [[ "$KERNEL_BUILD" == *git_sc-gsi-release/gsi_arm64-user* ]]; then
                _file_patterns=( "gsi_arm64-img-*.zip" )
            fi
            if [[ -n "$VENDOR_KERNEL_BUILD" && "$_build_info" != *android13* ]]; then
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

    local _file_path="${KERNEL_BUILD/ab:\/\//}"
    local _full_file_path="$DOWNLOAD_PATH/$_file_path"

    for _pattern in "${_file_patterns[@]}"; do
        log_info "Downloading $_build_info/$_pattern"
        eval "$FETCH_SCRIPT $_build_info/$_pattern"
        exit_code=$?
        if (( exit_code == 0 )); then
            log_info "Downloaded $_build_info/$_pattern"
        else
            log_error "Failed to download $_build_info/$_pattern"
            exit 1
        fi
        local _full_file_name="$_full_file_path/$_pattern"
        local _new_file_name="$_pattern"
        if [[ "$_pattern" == "boot-lz4.img" ]]; then
            _new_file_name="boot.img"
        elif [[ "$_pattern" == system_dlkm* ]]; then
            _new_file_name="system_dlkm.img"
        fi
        if [[ "$_pattern" == "gsi_arm64-img-*.zip" ]]; then
            eval "unzip -j $_full_file_path/gsi_arm64-img-*.zip boot-5.10-lz4.img" -d "$_kernel_dir/boot.img"
        else
            if ! create_soft_link "$_full_file_name" "$_kernel_dir/$_new_file_name"; then
                log_error "Failed to create soft link for $_full_file_name"
                exit 1
            fi
        fi
    done
    echo ""
    KERNEL_BUILD="$_kernel_dir"
}

function download_vendor_kernel_build() {
    log_info "Downloading vendor kernel artifacts from $VENDOR_KERNEL_BUILD"
    local _build_info="$VENDOR_KERNEL_BUILD"
    local _file_patterns=("Image.lz4" "dtbo.img" "initramfs.img")
    local _vendor_kernel_dir="$VENDOR_KERNEL_DIR/$DEVICE_SERIAL_NUMBER"

    # Clean up vendor kernel directory
    if [[ -d "$_vendor_kernel_dir" ]]; then
        rm -rf "$_vendor_kernel_dir" || { log_error "Failed to clean up $_vendor_kernel_dir" && exit 1; }
    fi
    mkdir -p "$_vendor_kernel_dir" || { log_error "Failed to create $_vendor_kernel_dir folder" && exit 1; }

    if [[ "$_build_info" == *6.6* ]]; then
        _file_patterns+=("*vendor_dev_nodes_fragment.img")
    fi

    case "$PRODUCT" in
        oriole | raven | bluejay)
            _file_patterns+=( "gs101-a0.dtb" "gs101-b0.dtb" )
            if [[ "$_build_info" == *android13* || -z "$KERNEL_BUILD" ]]; then
                _file_patterns+=("vendor_dlkm.img")
            else
                _file_patterns+=("vendor_dlkm_staging_archive.tar.gz" "vendor_dlkm.props" "vendor_dlkm_file_contexts" \
                "kernel_aarch64_Module.symvers" "abi_gki_aarch64_pixel")
                if [[ "$_build_info" == *android15* && "$_build_info" == *6.6* ]]; then
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

    local _file_path="${_build_info/ab:\/\//}"
    local _full_file_path="$DOWNLOAD_PATH/$_file_path"
    for _pattern in "${_file_patterns[@]}"; do
        log_info "Downloading $_build_info/$_pattern"
        eval "$FETCH_SCRIPT $_build_info/$_pattern"
        exit_code=$?
        if (( exit_code == 0 )); then
            log_info "Downloaded $_build_info/$_pattern"
        else
            log_error "Failed to download $_build_info/$_pattern"
            exit 1
        fi
        local _full_file_name="$_full_file_path/$_pattern"
        local _new_file_name="$_pattern"
        if [[ "$_pattern" == "vendor_dev_nodes_fragment.img" ]]; then
            _new_file_name="vendor_ramdisk_fragment_extra.img"
        elif [[ "$_pattern" == "abi_gki_aarch64_pixel" ]]; then
            _new_file_name="abi_gki_aarch64_pixel extracted_symbols"
        fi
        create_soft_link "$_full_file_name" "$_vendor_kernel_dir/$_new_file_name"
    done
    VENDOR_KERNEL_BUILD=$_vendor_kernel_dir
    echo ""
}

function download_vendor_kernel_for_direct_flash() {
    local _build_info="$VENDOR_KERNEL_BUILD"
    local _vendor_kernel_dir="$VENDOR_KERNEL_DIR/$DEVICE_SERIAL_NUMBER"
    local _image_patterns=("${VENDOR_KERNEL_IMGS[@]}")

    if [[ "$_build_info" == *kernel-pixel-android*-gs-pixel* ]]; then
        _image_patterns=("${VENDOR_KERNEL_IMGS_PIXEL_BRANCH[@]}")
    fi

    log_info "Downloading vendor kernel artifacts ${_image_patterns[*]} from $VENDOR_KERNEL_BUILD"

    # Clean up vendor kernel directory
    if [[ -d "$_vendor_kernel_dir" ]]; then
        rm -rf "$_vendor_kernel_dir" || { log_error "Failed to clean up $_vendor_kernel_dir" && exit 1; }
    fi
    mkdir -p "$_vendor_kernel_dir" || { log_error "Failed to create $_vendor_kernel_dir folder" && exit 1; }

    local _file_path="${_build_info/ab:\/\//}"
    local _full_file_path="$DOWNLOAD_PATH/$_file_path"
    for _pattern in "${_image_patterns[@]}"; do
        log_info "Downloading $_build_info/$_pattern"
        eval "$FETCH_SCRIPT $_build_info/$_pattern"
        exit_code=$?
        if (( exit_code == 0 )); then
            log_info "Downloaded $_build_info/$_pattern succeeded"
        else
            log_error "Failed to download $_build_info/$_pattern"
            exit 1
        fi
        local _full_file_name="$_full_file_path/$_pattern"
        create_soft_link "$_full_file_name" "$_vendor_kernel_dir/$_pattern"
    done
    VENDOR_KERNEL_BUILD="$_vendor_kernel_dir"
    echo ""

}

function reboot_device_into_bootloader() {
    if [[ -n "$ADB_SERIAL_NUMBER" ]] && (( $(adb devices | grep "$ADB_SERIAL_NUMBER" | wc -l) > 0 )); then
        if [[ "$DISABLE_VERIFICATION" == "true" ]]; then
            eval "adb -s $ADB_SERIAL_NUMBER root && adb -s $ADB_SERIAL_NUMBER disable-verity"
        fi
        log_info "Reboot $ADB_SERIAL_NUMBER into bootloader"
        adb -s "$ADB_SERIAL_NUMBER" reboot bootloader
        FLASH_LOGICAL_PARTITION_FIRST=true
    elif [[ -n "$FASTBOOT_SERIAL_NUMBER" ]] && (( $(fastboot devices | grep "$FASTBOOT_SERIAL_NUMBER" | wc -l) > 0 )); then
        log_info "Reboot $FASTBOOT_SERIAL_NUMBER into bootloader"
        fastboot -s "$FASTBOOT_SERIAL_NUMBER" reboot bootloader
    fi
    wait_for_device_in_fastboot
    if [[ "$DISABLE_VERIFICATION" == "true" ]]; then
        log_info "Running fastboot oem disable-verity and disable-verification commands"
        eval "fastboot -s $FASTBOOT_SERIAL_NUMBER oem disable-verity && fastboot -s $FASTBOOT_SERIAL_NUMBER oem disable-verification"
        exit_code=$?
        if (( exit_code == 0 )); then
            log_info "oem disable-verity and disable-verification commands succeeded"
        else
            log_info "Adding --disable-verification option in fastboot flash command"
            FASTBOOT_FLASH_OPTION=" --disable-verification"
        fi
    fi
}

function flash_kernel_build() {
    log_info "The boot image in $KERNEL_BUILD has kernel verson: $KERNEL_VERSION"
    if [[ -n "$DEVICE_KERNEL_VERSION" && "$KERNEL_VERSION" != "$DEVICE_KERNEL_VERSION"* ]]; then
        log_warn "Device $PRODUCT $SERIAL_NUMBER comes with $DEVICE_KERNEL_VERSION kernel. \
Can't flash $KERNEL_VERSION GKI kernel directly. Please use a platform build with the $KERNEL_VERSION kernel \
or use a vendor kernel build by flag -vkb, such as ab://kernel-android*-gs-pixel-*.*"
        log_error "Cannot flash $KERNEL_VERSION GKI kernel to device $SERIAL_NUMBER directly."
        exit 1
    fi

    reboot_device_into_bootloader
    log_info "Flash GKI kernel from $KERNEL_BUILD"

    local _bootloader_flash_cmd="fastboot -s $FASTBOOT_SERIAL_NUMBER -w && sleep 2"
    _bootloader_flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER flash $FASTBOOT_FLASH_OPTION boot "
    if [[ -f "$KERNEL_BUILD/boot-lz4.img" ]]; then
        _bootloader_flash_cmd+="$KERNEL_BUILD/boot-lz4.img && sleep 2"
    elif [[ -f "$KERNEL_BUILD/boot-gz.img" ]]; then
        _bootloader_flash_cmd+="$KERNEL_BUILD/boot-gz.img && sleep 2"
    elif [[ -f "$KERNEL_BUILD/boot.img" ]]; then
        _bootloader_flash_cmd+="$KERNEL_BUILD/boot.img && sleep 2"
    else
        log_error "There is no boot image in $KERNEL_BUILD"
        exit 1
    fi

    local _fastbootd_flash_cmd="fastboot -s $FASTBOOT_SERIAL_NUMBER reboot fastboot && sleep 5"
    _fastbootd_flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER flash $FASTBOOT_FLASH_OPTION system_dlkm "
    if [[ -f "$KERNEL_BUILD/system_dlkm.img" ]] && [[ "$PRODUCT" != "raven" && "$PRODUCT" != "oriole" ]]; then
        _fastbootd_flash_cmd+="$KERNEL_BUILD/system_dlkm.img && sleep 2"
    elif [[ -f "$KERNEL_BUILD/system_dlkm.flatten.ext4.img" ]] && [[ "$PRODUCT" != "raven" && "$PRODUCT" != "oriole" ]]; then
        _fastbootd_flash_cmd+="$KERNEL_BUILD/system_dlkm.flatten.ext4.img && sleep 2"
    elif [[ -f "$KERNEL_BUILD/system_dlkm.flatten.erofs.img" ]]; then
        _fastbootd_flash_cmd+="$KERNEL_BUILD/system_dlkm.flatten.erofs.img && sleep 2"
    else
        _fastbootd_flash_cmd=
    fi

    if [[ -z "$_fastbootd_flash_cmd" ]]; then
        _flash_cmd="$_bootloader_flash_cmd && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot"
    elif [[ "$FLASH_LOGICAL_PARTITION_FIRST" == "true" ]]; then
        _flash_cmd="$_fastbootd_flash_cmd && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot bootloader && sleep 2"
        _flash_cmd+=" && $_bootloader_flash_cmd && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot"
    else
        _flash_cmd="$_bootloader_flash_cmd && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot fastboot"
        _flash_cmd+=" && sleep 5 && $_fastbootd_flash_cmd && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot"
    fi

    log_info "Flashing GKI kernel with: $_flash_cmd"
    eval "$_flash_cmd"
    exit_code=$?
    if (( exit_code == 0 )); then
        echo "Flash GKI kernel succeeded"
        wait_for_device_in_adb
        return
    else
        echo "Flash GKI kernel failed with exit code $exit_code"
        exit 1
    fi
}

function check_fastboot_version() {
    local _fastboot_version=$(fastboot --version | awk 'NR=1 {print $3}')

    # Check if _fastboot_version is less than MIN_FASTBOOT_VERSION
    if [[ "$_fastboot_version" < "$MIN_FASTBOOT_VERSION" ]]; then
        log_info "The existing fastboot version $_fastboot_version doesn't meet minimum requirement $MIN_FASTBOOT_VERSION. Download the latest fastboot"

        local _download_file_name="ab://aosp-sdk-release/sdk/latest/fastboot"
        mkdir -p "/tmp/fastboot" || { log_error "Fail to mkdir /tmp/fastboot" && exit 1; }
        cd /tmp/fastboot || { log_error "Fail to go to /tmp/fastboot" && exit 1; }

        # Use $FETCH_SCRIPT and $_download_file_name correctly
        eval "$FETCH_SCRIPT $_download_file_name"
        exit_code=$?
        if (( exit_code == 0 )); then
            log_info "Downloading $_download_file_name succeeded"
        else
            log_error "Downloading $_download_file_name failed"
            exit 1
        fi

        chmod +x /tmp/fastboot/fastboot
        export PATH="/tmp/fastboot:$PATH"

        _fastboot_version=$(fastboot --version | awk 'NR=1 {print $3}')
        log_info "The fastboot is updated to version $_fastboot_version"
    fi
}

function flash_vendor_kernel_build() {
    check_fastboot_version

    log_info "Flashing vendor kernel from $VENDOR_KERNEL_BUILD"
    reboot_device_into_bootloader

    local _bootloader_flash_cmd="fastboot -s $FASTBOOT_SERIAL_NUMBER -w && sleep 2"
    _bootloader_flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER flash $FASTBOOT_FLASH_OPTION boot $VENDOR_KERNEL_BUILD/boot.img"
    if [[ -f "$VENDOR_KERNEL_BUILD/dtb.img" && -f "$VENDOR_KERNEL_BUILD/initramfs.img" ]]; then
        _bootloader_flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER flash $FASTBOOT_FLASH_OPTION "
        _bootloader_flash_cmd+="--dtb $VENDOR_KERNEL_BUILD/dtb.img vendor_boot:dlkm $VENDOR_KERNEL_BUILD/initramfs.img"
    fi
    if [[ -f "$VENDOR_KERNEL_BUILD/vendor_kernel_boot.img" ]]; then
        _bootloader_flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER flash $FASTBOOT_FLASH_OPTION "
        _bootloader_flash_cmd+="vendor_kernel_boot $VENDOR_KERNEL_BUILD/vendor_kernel_boot.img"
    fi
    _bootloader_flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER flash $FASTBOOT_FLASH_OPTION dtbo $VENDOR_KERNEL_BUILD/dtbo.img && sleep 2"

    _fastbootd_flash_cmd+="fastboot -s $FASTBOOT_SERIAL_NUMBER reboot fastboot && sleep 2"
    if [[ -f "$VENDOR_KERNEL_BUILD/system_dlkm.img" ]]; then
        _fastbootd_flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER flash $FASTBOOT_FLASH_OPTION system_dlkm $VENDOR_KERNEL_BUILD/system_dlkm.img"
    fi
    _fastbootd_flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER flash $FASTBOOT_FLASH_OPTION vendor_dlkm $VENDOR_KERNEL_BUILD/vendor_dlkm.img"
    _fastbootd_flash_cmd+=" && sleep 2"

    if [[ "$FLASH_LOGICAL_PARTITION_FIRST" == "true" ]]; then
        _flash_cmd="$_fastbootd_flash_cmd && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot bootloader && sleep 2"
        _flash_cmd+=" && $_bootloader_flash_cmd && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot"
    else
        _flash_cmd="$_bootloader_flash_cmd && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot fastboot"
        _flash_cmd+=" && sleep 5 && $_fastbootd_flash_cmd && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot"
    fi

    log_info "Executing vendor kernel flash command: $_flash_cmd"
    eval "$_flash_cmd"
    exit_code=$?
    if (( exit_code == 0 )); then
        echo "Finished flashing vendor kernel images. Rebooting device"
    else
        echo "Flashing vendor kernel failed with exit code $exit_code"
        exit 1
    fi

    wait_for_device_in_adb
}

function is_device_in_adb() {
    local adb_serials
    adb_serials=($(adb devices | grep -v -w "offline" | tail -n +2 | awk '{print $1}'))

    if (( ${#adb_serials[@]} == 0 )); then
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
        if [[ -z "$ADB_SERIAL_NUMBER" ]]; then
            local hw_serial
            hw_serial=$(adb -s "$adb_serial" shell getprop ro.serialno | tr -d '[:space:]')
            if [[ -n "$hw_serial" && "$hw_serial" == "$target_serial" ]]; then
                DEVICE_SERIAL_NUMBER="$hw_serial"
                ADB_SERIAL_NUMBER="$adb_serial"
                log_info "Success: Device '$target_serial' found in adb as '$adb_serial'."
                return 0 # Succeed. Device is in adb
            fi
            if [[ -n "$hw_serial" && "$hw_serial" == "$DEVICE_SERIAL_NUMBER" ]]; then
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

    if (( ${#fastboot_serials[@]} == 0 )); then
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
        if [[ -z "$FASTBOOT_SERIAL_NUMBER" ]]; then
            local hw_serial
            hw_serial=$(_parse_fastboot_var "$(fastboot -s "$fastboot_serial" getvar serialno 2>&1)")
            if [[ -n "$hw_serial" && "$hw_serial" == "$target_serial" ]]; then
                DEVICE_SERIAL_NUMBER="$hw_serial"
                FASTBOOT_SERIAL_NUMBER="$fastboot_serial"
                log_info "Success: Device '$target_serial' found in fastboot as '$fastboot_serial'."
                return 0 # Succeed. Device is in fastboot
            fi
            if [[ -n "$hw_serial" && "$hw_serial" == "$DEVICE_SERIAL_NUMBER" ]]; then
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
        if (( log_level > 0 )); then
            log_warn "Device '$device_target' not found in adb. Waiting for it to connect..."
            if [[ "$THROUGH_PONTIS" == "true" ]] && ! pontis devices | grep -q "$DEVICE_SERIAL_NUMBER.*ADB"; then
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
        log_warn "Device '$device_target' is not autheroized"
        return 1 # Failed
    fi
    if ! is_device_ready_for_adb_command; then
        log_warn "Device '$device_target' is not ready for adb command"
        return 1 # Failed
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
        if [[ "$THROUGH_PONTIS" == "true" ]]; then
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
    if [[ "$SKIP_UPDATE_BOOTLOADER" == "true" ]] && [[ "$PLATFORM_BUILD" == ab://* ]] || [[ -z "$CL_FLASH_CLI" ]]; then
        download_platform_build
    fi

    local _flash_cmd
    if [[ "$PLATFORM_BUILD" == ab://* ]]; then
        _flash_cmd="$CL_FLASH_CLI --nointeractive --force_flash_partitions -w -s $DEVICE_SERIAL_NUMBER "

        if [[ "$DISABLE_VERIFICATION" == "true" ]]; then
            _flash_cmd+=" --disable_verity --disable_verification"
        fi

        local _branch
        local _build_target
        local _build_id
        if ! parse_ab_url "$PLATFORM_BUILD" _branch _build_target _build_id &> /dev/null; then
            log_error "Invalid Android Build url string. PLATFORM_BUILD=${PLATFORM_BUILD}"
            exit 1
        fi

        if [[ -n "${_build_target}" ]]; then
            _flash_cmd+=" -t $_build_target"
            if [[ "$_build_target" == *user ]]; then
                if [[ "$FORCE_DEBUGGABLE" == "true" ]]; then
                    log_info "Flashing user build with --force_debuggable option"
                    _flash_cmd+=" --force_debuggable"
                else
                    log_info "--no-force-debuggable option is enabled. \
                    Need to enable ADB Debug manually in development mode for adb access"
                fi
            fi
        fi
        log_info "Flashing $SERIAL_NUMBER by flash station with platform build $PLATFORM_BUILD..."
        if [[ -n "${_build_id}" && "${_build_id}" != latest* ]]; then
            _flash_cmd+=" --bid ${_build_id}"
        else
            _flash_cmd+=" -l ${_branch}"
        fi
    elif [[ -n "$PLATFORM_REPO_ROOT" && "$PLATFORM_BUILD" == "$PLATFORM_REPO_ROOT/out/target/product/$PRODUCT" ]] && \
    [[ -x "$PLATFORM_REPO_ROOT/vendor/google/tools/flashall" ]]; then
        cd "$PLATFORM_REPO_ROOT" || { log_error "Fail to go to $PLATFORM_REPO_ROOT" && exit 1; }
        log_info "Flashing device by vendor/google/tools/flashall with platform build from ${PLATFORM_BUILD}"
        if [[ -z "${TARGET_PRODUCT:-}" || "${TARGET_PRODUCT:-}" != *"$PRODUCT"* ]]; then
            if [[ "${PLATFORM_VERSION:-}" == aosp-* || "${PLATFORM_VERSION:-}" == AOSP* ]]; then
                set_platform_repo "aosp_$PRODUCT" "userdebug" "$PLATFORM_REPO_ROOT" "$DEVICE_LUNCH_TARGET"
            else
                set_platform_repo "$PRODUCT" "userdebug" "$PLATFORM_REPO_ROOT" "$DEVICE_LUNCH_TARGET"
            fi
        fi
        _flash_cmd="vendor/google/tools/flashall  --nointeractive -w -s $DEVICE_SERIAL_NUMBER"
    else
        log_info "Flashing device by local flash station with platform build from ${PLATFORM_BUILD}"
        prepare_to_flash_platform_build_from_local_directory

        _flash_cmd="$LOCAL_FLASH_CLI --nointeractive --force_flash_partitions -w -s $DEVICE_SERIAL_NUMBER"
        # A workaround when the local flash CLI in Android kernel tree doesn't work
        #_flash_cmd="$COMMON_LIB_LOCAL_FLASH_CLI --nointeractive --force_flash_partitions -w -s $DEVICE_SERIAL_NUMBER"
        if [[ "$DISABLE_VERIFICATION" == "true" ]]; then
            _flash_cmd+=" --disable_verity --disable_verification"
        fi
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

function flash_gsi_build() {
    if [[ "$GSI_BUILD" == ab://* ]]; then
        # Flashstation doesn't support flashing pvmfw.img yet. Use flashstation on Pixel6 only
        if [[ -z "$CL_FLASH_CLI" ]] || [[ "$PRODUCT" != "raven" && "$PRODUCT" != "oriole" ]]; then
            download_gsi_build
        fi
    fi

    local _flash_cmd=""
    # Flashstation doesn't support flashing pvmfw.img yet. Use flashstation on Pixel6 only
    if [[ "$GSI_BUILD" == ab://* ]] && [[ "$PRODUCT" == "raven" || "$PRODUCT" == "oriole" ]]; then
        log_info "Flashing GSI build $GSI_BUILD with $CL_FLASH_CLI"
        _flash_cmd="$CL_FLASH_CLI --nointeractive -s $DEVICE_SERIAL_NUMBER"

        if [[ "$USE_DSU" == "true" ]]; then
            _flash_cmd+=" --dsu"
        else
            _flash_cmd+=" -w"
            if [[ "$DISABLE_VERIFICATION" == "true" ]]; then
                _flash_cmd+=" --disable_verity --disable_verification"
            fi
        fi

        local _branch
        local _build_target
        local _build_id
        if ! parse_ab_url "$GSI_BUILD" _branch _build_target _build_id &> /dev/null; then
            log_error "Invalid Android Build url string. GSI_BUILD=${GSI_BUILD}"
            exit 1
        fi

        if [[ -n "${_build_target}" ]]; then
            _flash_cmd+=" -t $_build_target"
        fi
        log_info "Flashing $SERIAL_NUMBER by flash station with gsi build $GSI_BUILD..."
        if [[ -n "${_build_id}" && "${_build_id}" != latest* ]]; then
            _flash_cmd+=" --bid ${_build_id}"
        else
            _flash_cmd+=" -l ${_branch}"
        fi
    else
        log_info "Flashing GSI build $GSI_BUILD with fastboot"
        reboot_device_into_bootloader
        local _output=$(fastboot -s "$FASTBOOT_SERIAL_NUMBER" getvar current-slot 2>&1)
        local _current_slot=$(echo "$_output" | grep "^current-slot:" | awk '{print $2}')
        local _pvmfw_partition_output=$(fastboot -s "$FASTBOOT_SERIAL_NUMBER" getvar has-slot:pvmfw 2>&1)
        _flash_cmd="fastboot -s $FASTBOOT_SERIAL_NUMBER -w"
        _flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot-fastboot && sleep 3"
        _flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER delete-logical-partition product_$_current_slot"
        _flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER erase system_$_current_slot"
        if [[ -f "$GSI_BUILD/system.img" ]]; then
            _flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER flash  $FASTBOOT_FLASH_OPTION system $GSI_BUILD/system.img"
        else
            log_error "There is no system.img in $GSI_BUILD"
            exit 1
        fi
        if [[ -f "$GSI_BUILD/pvmfw.img" && "$_pvmfw_partition_output" == *yes* \
        && "$PRODUCT" != "raven" && "$PRODUCT" != "oriole" ]]; then
            _flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot bootloader && sleep 3"
            _flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER flash  $FASTBOOT_FLASH_OPTION pvmfw $GSI_BUILD/pvmfw.img"
        fi
        _flash_cmd+=" && fastboot -s $FASTBOOT_SERIAL_NUMBER reboot"
    fi
    log_info "Flashing GSI with: $_flash_cmd"
    eval "$_flash_cmd"
    exit_code=$?
    if (( exit_code == 0 )); then
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
    if [[ ! -f "$PLATFORM_BUILD/android-info.txt" || ! -f "$PLATFORM_BUILD/boot.img" ]]; then
        local device_image=$(find "$PLATFORM_BUILD" -maxdepth 1 -name *-img*.zip)
        if [[ -f "$device_image" ]]; then
            unzip -j "$device_image" -d "$PLATFORM_BUILD"
            if [[ ! -f "$PLATFORM_BUILD/android-info.txt" || ! -f "$PLATFORM_BUILD/boot.img" ]]; then
                log_error "There is no android-info.txt in $device_image"
                exit 1
            fi
        else
            log_error "$PLATFORM_BUILD doesn't have valid device image to be flashed with"
            exit 1
        fi
    fi
    if [[ -z "${TARGET_PRODUCT:-}" || "${TARGET_PRODUCT:-}" != "$PRODUCT" ]]; then
        log_info "Set env var TARGET_PRODUCT to $PRODUCT"
        export TARGET_PRODUCT="$PRODUCT"
    fi
    if [[ -z "${TARGET_BUILD_VARIANT:-}" || "${TARGET_BUILD_VARIANT}" != "$DEVICE_VARIANT" ]]; then
        log_info "Set env var TARGET_BUILD_VARIANT to $DEVICE_VARIANT"
        export TARGET_BUILD_VARIANT="$DEVICE_VARIANT"
    fi
    if [[ -z "${ANDROID_PRODUCT_OUT:-}" || "${ANDROID_PRODUCT_OUT}" != "$PLATFORM_BUILD" ]]; then
        log_info "Set env var ANDROID_PRODUCT_OUT to $PLATFORM_BUILD"
        export ANDROID_PRODUCT_OUT="$PLATFORM_BUILD"
    fi
    if [[ -z "${ANDROID_HOST_OUT:-}" || "${ANDROID_HOST_OUT}" != "$PLATFORM_BUILD" ]]; then
        log_info "Set env var ANDROID_HOST_OUT to $PLATFORM_BUILD"
        export ANDROID_HOST_OUT="$PLATFORM_BUILD"
    fi

    if [[ "$SKIP_UPDATE_BOOTLOADER" == "true" ]]; then
        awk '! /bootloader/' "$PLATFORM_BUILD"/android-info.txt > temp && mv temp "$PLATFORM_BUILD"/android-info.txt
    fi
    # skip update radio.img
    #awk '! /baseband/' "$PLATFORM_BUILD"/android-info.txt > temp && mv temp "$PLATFORM_BUILD"/android-info.txt

}

function mixing_build() {
    local _device_dir="$DEVICE_DIR/$DEVICE_SERIAL_NUMBER"
    if [[ "$PLATFORM_BUILD" == ab://* ]]; then
        download_platform_build
    elif [[ -n "$PLATFORM_REPO_ROOT" && "$PLATFORM_BUILD" == "$PLATFORM_REPO_ROOT"* ]]; then
        # Clean up device directory
        if [[ -d "$_device_dir" ]]; then
            rm -rf "$_device_dir" || { log_error "Failed to clean up $_device_dir" && exit 1; }
        fi
        mkdir -p "$_device_dir" || { log_error "Failed to create $_device_dir folder" && exit 1; }

        local device_image=$(find "$PLATFORM_BUILD" -maxdepth 1 -type f -name *-img.zip)
        if [[ -n "$device_image" ]]; then
            if ! create_soft_link "$device_image" "$_device_dir/$PRODUCT-img-0.zip"; then
                log_error "Failed to create soft link $device_image"
                exit 1
            fi
        else
            device_image=$(find "$PLATFORM_BUILD" -maxdepth 1 -type f -name *-img-*.zip)
            if [[ -n "$device_image" ]]; then
                if ! create_soft_link "$device_image" "$_device_dir/$PRODUCT-img-0.zip"; then
                    log_error "Failed to create link $device_image"
                    exit 1
                fi
            else
                log_error "Can't find $PRODUCT-img-*.zip in $PLATFORM_BUILD"
                exit 1
            fi
        fi

        local file_patterns=("bootloader.img" "radio.img" "vendor_ramdisk.img" "misc_info.txt", "otatools.zip")
        for pattern in "${file_patterns[@]}"; do
            if ! create_soft_link "$PLATFORM_BUILD/$pattern" "$_device_dir/$pattern"; then
                log_error "Failed to create soft link for $PLATFORM_BUILD/$pattern"
                exit 1
            else
                log_info "Created soft link for $PLATFORM_BUILD/$pattern"
            fi
        done
        PLATFORM_BUILD="$_device_dir"
    fi

    if [[ -n "${PLATFORM_REPO_ROOT}" && -f "${PLATFORM_REPO_ROOT}/vendor/google/tools/$MIX_SCRIPT_NAME" ]]; then
        mix_kernel_cmd="${PLATFORM_REPO_ROOT}/vendor/google/tools/${MIX_SCRIPT_NAME}"
    elif [[ -f "${DOWNLOAD_PATH}/${MIX_SCRIPT_NAME}" ]]; then
        mix_kernel_cmd="$DOWNLOAD_PATH/$MIX_SCRIPT_NAME"
    elif [[ -f "${PLATFORM_BUILD}/otatools.zip" ]]; then
        eval "unzip -j ${PLATFORM_BUILD}/otatools.zip bin/${MIX_SCRIPT_NAME}" -d "${DOWNLOAD_PATH}"
        mix_kernel_cmd="${DOWNLOAD_PATH}/${MIX_SCRIPT_NAME}"
    fi
    if [[ ! -f "$mix_kernel_cmd" ]]; then
        log_error "$mix_kernel_cmd doesn't exist or is not executable"
        exit 1
    elif [[ ! -x "$mix_kernel_cmd" ]]; then
        log_error "$mix_kernel_cmd is not executable"
        exit 1
    fi

    local new_device_dir="$DOWNLOAD_PATH/new_device_dir/$DEVICE_SERIAL_NUMBER"
    if [[ -d "$new_device_dir" ]]; then
        rm -rf "$new_device_dir" || { log_error "Failed to clean up $new_device_dir" && exit 1; }
    fi
    mkdir -p "$new_device_dir" || { log_error "Failed to create $new_device_dir folder" && exit 1; }
    local mixed_build_cmd="$mix_kernel_cmd"
    if [[ -d "${KERNEL_BUILD}" ]]; then
        mixed_build_cmd+=" --gki_dir $KERNEL_BUILD"
    fi
    mixed_build_cmd+=" $PLATFORM_BUILD $VENDOR_KERNEL_BUILD $new_device_dir"
    log_info "Run: $mixed_build_cmd"
    eval $mixed_build_cmd
    device_image=$(ls $new_device_dir/*$PRODUCT-img*.zip)
    if [[ ! -f "$device_image" ]]; then
        log_error "New device image is not created in $new_device_dir"
        exit 1
    fi
    cp "$PLATFORM_BUILD/bootloader.img" "$new_device_dir/."
    cp "$PLATFORM_BUILD/radio.img" "$new_device_dir/."
    PLATFORM_BUILD="$new_device_dir"
}

function create_gki_boot_image() {
    local _device_dir="$DEVICE_DIR/$DEVICE_SERIAL_NUMBER"
    if [[ "$PLATFORM_BUILD" == ab://* ]]; then
        download_platform_build
    elif [[ -n "$PLATFORM_REPO_ROOT" && "$PLATFORM_BUILD" == "$PLATFORM_REPO_ROOT"* ]]; then
        # Clean up device directory
        if [[ -d "$_device_dir" ]]; then
            rm -rf "$_device_dir" || { log_error "Failed to clean up $_device_dir" && exit 1; }
        fi
        mkdir -p "$_device_dir" || { log_error "Failed to create $_device_dir folder" && exit 1; }
        log_info "Link platform build $PLATFORM_BUILD to $DOWNLOAD_PATH/device_dir"
        local device_image=$(find "$PLATFORM_BUILD" -maxdepth 1 -type f -name *-img.zip)
        if [[ -n "$device_image" ]]; then
            if ! create_soft_link "$device_image" "$_device_dir/$PRODUCT-img-0.zip"; then
                log_error "Failed to create soft link $device_image"
                exit 1
            fi
        else
            device_image=$(find "$PLATFORM_BUILD" -maxdepth 1 -type f -name *-img-*.zip)
            if [[ -n "$device_image" ]]; then
                if ! create_soft_link "$device_image" "$_device_dir/$PRODUCT-img-0.zip"; then
                    log_error "Failed to create link $device_image"
                    exit 1
                fi
            else
                log_error "Can't find $PRODUCT-img-*.zip in $PLATFORM_BUILD"
                exit 1
            fi
        fi
        local file_patterns=("bootloader.img" "radio.img" "vendor_ramdisk.img" "misc_info.txt" "otatools.zip")
        for pattern in "${file_patterns[@]}"; do
            if ! create_soft_link "$PLATFORM_BUILD/$pattern" "$_device_dir/$pattern"; then
                log_error "Failed to create soft link $$PLATFORM_BUILD/$pattern"
                exit 1
            fi
        done
        PLATFORM_BUILD="$_device_dir"
    fi

    if [[ -n "${PLATFORM_REPO_ROOT}" && -f "${PLATFORM_REPO_ROOT}/system/tools/mkbootimg/mkbootimg.py" ]]; then
        mk_boot_cmd="${PLATFORM_REPO_ROOT}/system/tools/mkbootimg/mkbootimg.py"
    elif [[ -n "${PLATFORM_REPO_ROOT}/out/host/linux-x86/bin" && -f "${PLATFORM_REPO_ROOT}/out/host/linux-x86/bin/mkbootimg.py" ]]; then
        mk_boot_cmd="${PLATFORM_REPO_ROOT}/out/host/linux-x86/bin"
    elif [[ -f "${DOWNLOAD_PATH}/mkbootimg" ]]; then
        mk_boot_cmd="$DOWNLOAD_PATH/mkbootimg"
    elif [[ -f "${PLATFORM_BUILD}/otatools.zip" ]]; then
        eval "unzip -j ${PLATFORM_BUILD}/otatools.zip bin/mkbootimg" -d "mkbootimg"
        mk_boot_cmd="${DOWNLOAD_PATH}/mkbootimg"
    fi
    if [[ ! -f "$mk_boot_cmd" ]]; then
        log_error "$mk_boot_cmd doesn't exist or is not executable"
        exit 1
    elif [[ ! -x "$mk_boot_cmd" ]]; then
        log_error "$mk_boot_cmd is not executable"
        exit 1
    fi

    local gki_dir="$KERNEL_DIR/$DEVICE_SERIAL_NUMBER"
    mk_boot_cmd+=" --kernel $KERNEL_BUILD/Image.lz4 --header_version 4 --base 0x00000000 "
    if [[ "${PLATFORM_BUILD}" == *16k* ]]; then
        mk_boot_cmd+="--pagesize 16384 "
    else
        mk_boot_cmd+="--pagesize 4096 "
    fi
    mk_boot_cmd+="--ramdisk $PLATFORM_BUILD/ramdisk.img -o $gki_dir/boot.img"
    log_info "Run: $mk_boot_cmd"
    eval $mk_boot_cmd
    if [[ -f "$gki_dir/boot.img" ]]; then
        log_info "The boot.img is created in $gki_dir"
    else
        log_error "New boot image is not created in $gki_dir"
        exit 1
    fi
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
    if [[ -z "$DEVICE_SERIAL_NUMBER" ]]; then
        DEVICE_SERIAL_NUMBER=$(adb -s "$ADB_SERIAL_NUMBER" shell getprop ro.serialno)
    fi

    if [[ -z "$PRODUCT" || "$PRODUCT" == generic_arm64 ]]; then
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
    if [[ -z "$PRODUCT" || "$PRODUCT" == generic_arm64 ]]; then
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
    echo "$raw_output" | awk 'NR=1{print; exit}' | cut -d ':' -f 2 | tr -d '[:space:]'
}

function get_device_info_from_fastboot() {
    # Only get DEVICE_SERIAL_NUMBER if it's not already set
    if [[ -z "$DEVICE_SERIAL_NUMBER" ]]; then
        log_info "Attempting to get serial number from $FASTBOOT_SERIAL_NUMBER..."

        # Use a loop to handle the retry logic cleanly
        for attempt in 1 2; do
            local _output
            _output=$(fastboot -s "$FASTBOOT_SERIAL_NUMBER" getvar serialno 2>&1)
            DEVICE_SERIAL_NUMBER=$(_parse_fastboot_var "$_output")

            # If we got a serial number, break the loop
            if [[ -n "$DEVICE_SERIAL_NUMBER" ]]; then
                log_info "Retrieved serial: $DEVICE_SERIAL_NUMBER"
                break
            fi

            # If it's the first failed attempt, reboot and retry
            if (( attempt == 1 )); then
                log_warn "Command returned nothing. Rebooting into bootloader and retrying..."
                reboot_device_into_bootloader
            fi
        done

        # If after all attempts the serial is still missing, this is a fatal error
        if [[ -z "$DEVICE_SERIAL_NUMBER" ]]; then
            log_error "Could not get device serial for $FASTBOOT_SERIAL_NUMBER after retry."
            exit 1
        fi
    fi

    # Only get PRODUCT if it's not already set
    if [[ -z "$PRODUCT" ]]; then
        log_info "Attempting to get product name from $FASTBOOT_SERIAL_NUMBER..."
        local _output
        _output=$(fastboot -s "$FASTBOOT_SERIAL_NUMBER" getvar product 2>&1)
        PRODUCT=$(_parse_fastboot_var "$_output")

        if [[ -z "$PRODUCT" ]]; then
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

if [[ -z "$SERIAL_NUMBER" ]]; then
    log_error "Device serial is not provided with flag -s <serial_number>."
    exit 1
fi

if [[ ! -d "$DOWNLOAD_PATH" ]]; then
    mkdir -p "$DOWNLOAD_PATH" || { log_error "Fail to create directory $DOWNLOAD_PATH" && exit 1; }
fi

get_device_info

if is_in_repo_workspace; then
    log_info "Current path is in a repo workspace. Continuing the job at the root of the tree."
    go_to_repo_root "$PWD"
else
    log_warn "Current path $PWD is not in an Android repo. Change path to repo root."
    go_to_repo_root "$SCRIPT_DIR"
fi

readonly REPO_ROOT_PATH="$PWD"
readonly FETCH_SCRIPT="$REPO_ROOT_PATH/$FETCH_SCRIPT_PATH_IN_REPO"

find_repo

log_info "PLATFORM_BUILD=$PLATFORM_BUILD, KERNEL_BUILD=$KERNEL_BUILD, VENDOR_KERNEL_BUILD=$VENDOR_KERNEL_BUILD"

[[ "${PLATFORM_BUILD,,}" == "none" ]] && PLATFORM_BUILD=""
[[ "${KERNEL_BUILD,,}" == "none" ]] && KERNEL_BUILD=""
[[ "${VENDOR_KERNEL_BUILD,,}" == "none" ]] && VENDOR_KERNEL_BUILD=""

# --- Platform Build Processing ---
if [[ "$PLATFORM_BUILD" == ab:://* ]]; then
    log_warn "The platform ab build string should start with 'ab://', not 'ab:://'. Remove the redundant ':'"
    PLATFORM_BUILD="${PLATFORM_BUILD/::\/\//:\/\/}"
fi
if [[ "$PLATFORM_BUILD" == ab://* ]]; then
    format_ab_platform_build_string
elif [[ -n "$PLATFORM_BUILD" && -d "$PLATFORM_BUILD" ]]; then
    if [[ "$PWD" != "$PLATFORM_BUILD" ]]; then
        log_info "The provided PLATFORM_BUILD '$PLATFORM_BUILD' is not in the current directory"
        # Check if PLATFORM_BUILD is an Android platform repo
        cd "$PLATFORM_BUILD"  || { log_error "Fail to go to $PLATFORM_BUILD" && exit 1; }
        PLATFORM_REPO_LIST_OUT=$(repo list 2>&1)
        if [[ "$PLATFORM_REPO_LIST_OUT" != "error"* ]]; then
            go_to_repo_root "$PWD"
            if [[ "$PWD" != "$REPO_ROOT_PATH" ]]; then
                find_repo
            fi
        fi
    fi
    if [[ "$PLATFORM_REPO_ROOT" == "$PLATFORM_BUILD" ]]; then
        if [[ "$SKIP_BUILD" == "false" ]]; then
            if [[ -n "$DEVICE_LUNCH_TARGET" ]]; then
                set_platform_repo  "$PRODUCT" "userdebug" "$PLATFORM_REPO_ROOT" "$DEVICE_LUNCH_TARGET"
            elif [[ -z "${TARGET_PRODUCT:-}" || "${TARGET_PRODUCT:-}" != *"$PRODUCT"* ]]; then
                if [[ "${PLATFORM_VERSION:-}" == aosp-* || "${PLATFORM_VERSION:-}" == AOSP* ]]; then
                    set_platform_repo "aosp_$PRODUCT" "userdebug" "$PLATFORM_REPO_ROOT" "$DEVICE_LUNCH_TARGET"
                else
                    set_platform_repo "$PRODUCT" "userdebug" "$PLATFORM_REPO_ROOT" "$DEVICE_LUNCH_TARGET"
                fi
            elif [[ "${TARGET_PRODUCT:-}" == *"$PRODUCT" ]]; then
                echo "TARGET_PRODUCT=${TARGET_PRODUCT}, ANDROID_PRODUCT_OUT=${ANDROID_PRODUCT_OUT}"
            fi
            if [[ "${TARGET_PRODUCT:-}" == *"$PRODUCT"* ]]; then
                build_platform
            else
                log_error "Can not build platform build due to lunch build target failure"
                exit 1
            fi
            if [[ ! -d "${ANDROID_PRODUCT_OUT:-}" || ! -f "${ANDROID_PRODUCT_OUT}/system.img" ]]; then
                log_error "Can't find a valid system.img in ${ANDROID_PRODUCT_OUT}"
                exit 1
            fi
            if [[ -n "$VENDOR_KERNEL_BUILD" ]]; then
                PLATFORM_BUILD="$PLATFORM_REPO_ROOT/out/dist/$PRODUCT"
            else
                PLATFORM_BUILD="${ANDROID_PRODUCT_OUT:-}"
            fi
        elif [[ -n "$VENDOR_KERNEL_BUILD" ]]; then
            log_info "Set PLATFORM BUILD to $PLATFORM_REPO_ROOT/out/dist/$PRODUCT"
            PLATFORM_BUILD="$PLATFORM_REPO_ROOT/out/dist/$PRODUCT"
        else
            PLATFORM_BUILD="$PLATFORM_REPO_ROOT/out/target/product/$PRODUCT"
        fi
        log_info "PLATFORM_BUILD=$PLATFORM_BUILD"
        if [[ -d "$PLATFORM_BUILD" ]] && [[ -f "$PLATFORM_BUILD/system.img" || -f "$PLATFORM_BUILD/otatools.zip" ]]; then
            log_info "Use platform build from $PLATFORM_BUILD"
        else
            log_error "Can't find valid image in $PLATFORM_BUILD"
            exit 1
        fi
    fi
fi

log_info "PLATFORM_BUILD=$PLATFORM_BUILD, KERNEL_BUILD=$KERNEL_BUILD, VENDOR_KERNEL_BUILD=$VENDOR_KERNEL_BUILD"

find_flashstation_binary

# --- Android Common Kernel Build (GKI) processing ---
if [[ "$KERNEL_BUILD" == ab:://* ]]; then
    log_warn "The kernel ab build string should start with 'ab://', not 'ab:://'. Remove the redundant ':'"
    KERNEL_BUILD="${KERNEL_BUILD/::\/\//:\/\/}"
fi

if [[ "$KERNEL_BUILD" == ab://* ]]; then
    if [[ "$KERNEL_BUILD" == *raviole* ]]; then
        log_error "$KERNEL_BUILD is a vendor kernel build. Please use -vkb flag to specify a vendor kernel build"
        exit 1
    fi
    format_ab_kernel_build_string
    download_kernel_build
elif [[ -n "$KERNEL_BUILD" && -d "$KERNEL_BUILD" ]]; then
    # Check if kernel repo is provided
    cd "$KERNEL_BUILD" || { log_error "Fail to go to $KERNEL_BUILD" && exit 1; }
    KERNEL_REPO_LIST_OUT=$(repo list 2>&1)
    if [[ "$KERNEL_REPO_LIST_OUT" != "error"* ]]; then
        log_info "$KERNEL_BUILD is in a kernel tree repo"
        go_to_repo_root "$PWD"
        if [[ "$PWD" != "$REPO_ROOT_PATH" ]]; then
            find_repo
        fi
        if [[ "$SKIP_BUILD" == "false" ]] ; then
            if [[ ! -f "common/BUILD.bazel" ]]; then
                # TODO: Add build support to android12 and earlier kernels
                log_error "bazel build is not supported in $PWD"
                exit 1
            else
                build_ack
            fi
        fi
        KERNEL_BUILD="$PWD/out/kernel_aarch64/dist"
    elif [[ -f "$KERNEL_BUILD/boot.img" ]]; then
        get_kernel_version_from_boot_image "$KERNEL_BUILD/boot.img"
    elif [[ -f "$KERNEL_BUILD/boot-lz4.img" ]]; then
        get_kernel_version_from_boot_image "$KERNEL_BUILD/boot-lz4.img"
    elif [[ -f "$KERNEL_BUILD/boot-gz.img" ]]; then
        get_kernel_version_from_boot_image "$KERNEL_BUILD/boot-gz.img"
    fi
fi

log_info "PLATFORM_BUILD=$PLATFORM_BUILD, KERNEL_BUILD=$KERNEL_BUILD, VENDOR_KERNEL_BUILD=$VENDOR_KERNEL_BUILD"

# --- Vendor Kernel Build (processing ---
if [[ "$VENDOR_KERNEL_BUILD" == ab:://* ]]; then
    log_warn "The vendor kernel ab build string should start with 'ab://', not 'ab:://'. Remove the redundant ':'"
    VENDOR_KERNEL_BUILD="${VENDOR_KERNEL_BUILD/::\/\//:\/\/}"
fi
if [[ "$VENDOR_KERNEL_BUILD" == ab://* ]]; then
    format_ab_vendor_kernel_build_string
    log_info "Downloading vendor kernel build $VENDOR_KERNEL_BUILD"
    if [[ -n "$PLATFORM_BUILD" ]] && [[ "$VENDOR_KERNEL_BUILD" == *raviole* ]]; then
        download_vendor_kernel_build
    else
        download_vendor_kernel_for_direct_flash
    fi
elif [[ -n "$VENDOR_KERNEL_BUILD" && -d "$VENDOR_KERNEL_BUILD" ]]; then
    # Check if vendor kernel repo is provided
    cd "$VENDOR_KERNEL_BUILD"  || { log_error "Fail to go to $VENDOR_KERNEL_BUILD" && exit 1; }
    VENDOR_KERNEL_REPO_LIST_OUT=$(repo list 2>&1)
    if [[ "$VENDOR_KERNEL_REPO_LIST_OUT" != "error"* ]]; then
        go_to_repo_root "$PWD"
        if [[ "$PWD" != "$REPO_ROOT_PATH" ]]; then
            find_repo
        fi
        if [[ -z "$VENDOR_KERNEL_BUILD_TARGET" ]]; then
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
        if [[ "$SKIP_BUILD" == "false" ]] ; then
            build_cmd="./build_$VENDOR_KERNEL_BUILD_TARGET.sh"
            if [[ "$GCOV" == "true" ]]; then
                build_cmd+=" --gcov"
            fi
            if [[ "$DEBUG" == "true" ]]; then
                build_cmd+=" --debug"
            fi
            if [[ "$KASAN" == "true" ]]; then
                build_cmd+=" --kasan"
            fi
            log_info "Build vendor kernel with $build_cmd"
            eval "$build_cmd"
            exit_code=$?
            if (( exit_code == 0 )); then
                log_info "Build vendor kernel succeeded"
            else
                log_error "Build vendor kernel failed with exit code $exit_code"
                exit 1
            fi
        fi
        VENDOR_KERNEL_BUILD="$PWD/out/$VENDOR_KERNEL_BUILD_TARGET/dist"
    fi
fi

if [[ -z "$PLATFORM_BUILD" ]]; then  # No platform build provided
    if [[ -z "$KERNEL_BUILD" && -z "$VENDOR_KERNEL_BUILD" && -z "$GSI_BUILD" ]]; then
        log_info "KERNEL_BUILD=$KERNEL_BUILD VENDOR_KERNEL_BUILD=$VENDOR_KERNEL_BUILD"
        log_error "Nothing to flash"
        exit 1
    fi
    if [[ -n "$VENDOR_KERNEL_BUILD" ]]; then
        log_info "Flash kernel from $VENDOR_KERNEL_BUILD"
        flash_vendor_kernel_build
    fi
    if [[ -n "$KERNEL_BUILD" ]]; then
        flash_kernel_build
    fi
else  # Platform build provided
    if [[ -z "$KERNEL_BUILD" && -z "$VENDOR_KERNEL_BUILD" ]]; then  # No kernel or vendor kernel build
        log_info "Flash platform build from $PLATFORM_BUILD"
        flash_platform_build
    elif [[ -z "$KERNEL_BUILD" && -n "$VENDOR_KERNEL_BUILD" ]]; then  # Vendor kernel build and platform build
        if [[ "$PRODUCT" == "oriole" || "$PRODUCT" == "raven" ]]; then
            log_info "Mix vendor kernel and platform build"
            mixing_build
            flash_platform_build
        else
            log_info "Flashing platform build, then vendor kernel build in squence"
            flash_platform_build
            flash_vendor_kernel_build
        fi
    elif [[ -n "$KERNEL_BUILD" && -z "$VENDOR_KERNEL_BUILD" ]]; then # Kernel build and platform build
        if [[ -f "$KERNEL_BUILD/Image.lz4" ]]  && (( $(ls -1 "$KERNEL_BUILD" | wc -l) == 1 )) \
        && [[ "$PRODUCT" == "oriole" || "$PRODUCT" == "raven" ]]; then
            create_gki_boot_image
        fi
        flash_platform_build
        flash_kernel_build
    elif [[ -n "$KERNEL_BUILD" && -n "$VENDOR_KERNEL_BUILD" ]]; then  # All three builds provided
        if [[ "$PRODUCT" == "oriole" || "$PRODUCT" == "raven" ]]; then
            log_info "Mix common kernel, vendor kernel and platform build"
            mixing_build
            flash_platform_build
        else
            log_info "Flashing platform build, vendor kernel build, then kernel build in squence"
            flash_platform_build
            flash_vendor_kernel_build
            flash_kernel_build
        fi
    fi
fi

if [[ "$GSI_BUILD" == ab://* ]]; then
    format_ab_gsi_build_string
elif [[ -n "$GSI_BUILD" && -d "$GSI_BUILD" ]]; then
    if [[ "$REPO_ROOT_PATH" == "$GSI_BUILD" && "$PLATFORM_REPO_ROOT" == "$GSI_BUILD" ]]; then
        if [[ "$SKIP_BUILD" == "false" ]]; then
            set_platform_repo "gsi_arm64" "userdebug" "$REPO_ROOT_PATH"
            build_platform
            GSI_BUILD="${ANDROID_PRODUCT_OUT:-}"
        elif [[ -d $REPO_ROOT_PATH/out/target/product/generic_arm64 ]]; then
            log_info "Set GSI_BUILD to $REPO_ROOT_PATH/out/target/product/generic_arm64"
            GSI_BUILD="$REPO_ROOT_PATH/out/target/product/generic_arm64"
        fi
        if [[ ! -f "${GSI_BUILD}/system.img" ]]; then
            log_error "Can't find valid image in ${GSI_BUILD}"
            exit 1
        fi
    else
        gsi_image=$(find "$GSI_BUILD" -maxdepth 1 -type f -name "*_arm64-img-*.zip")
        gsi_dir="$GSI_DIR/$DEVICE_SERIAL_NUMBER"
        if [[ -f "$gsi_image" ]]; then
            # GSI image was given as a zip file
            if [[ -d "$gsi_dir" ]]; then
                rm -rf "$gsi_dir" || { log_error "Failed to clean up $gsi_dir" && exit 1; }
            fi
            mkdir -p "$gsi_dir" || { log_error "Failed to create $gsi_dir folder" && exit 1; }
            unzip -j "$gsi_image" -d "$gsi_dir"
            if [[ ! -f "$gsi_dir/system.img" ]]; then
                log_error "There is no system.img in $gsi_image"
                exit 1
            fi
            GSI_BUILD="$gsi_dir"
        elif [[ -f "$GSI_BUILD/system.img" ]]; then
            log_info "There is system.img in GSI build folder $GSI_BUILD"
        else
            log_error "$GSI_BUILD doesn't have a valid GSI system image"
            exit 1
        fi
    fi
fi

if [[ -n "$GSI_BUILD" ]]; then
    flash_gsi_build
fi
