#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

# A handy tool to flash device with local build or remote build.

# Constants
FETCH_SCRIPT="fetch_artifact.sh"
# Please see go/cl_flashstation
CL_FLASH_CLI=/google/bin/releases/android/flashstation/cl_flashstation
LOCAL_FLASH_CLI=/google/bin/releases/android/flashstation/local_flashstation
MIX_SCRIPT_NAME="build_mixed_kernels_ramdisk"
FETCH_SCRIPT="kernel/tests/tools/fetch_artifact.sh"
DOWNLOAD_PATH="/tmp/downloaded_images"
KERNEL_TF_PREBUILT=prebuilts/tradefed/filegroups/tradefed/tradefed.sh
PLATFORM_TF_PREBUILT=tools/tradefederation/prebuilts/filegroups/tradefed/tradefed.sh
KERNEL_JDK_PATH=prebuilts/jdk/jdk11/linux-x86
PLATFORM_JDK_PATH=prebuilts/jdk/jdk21/linux-x86
LOCAL_JDK_PATH=/usr/local/buildtools/java/jdk11
LOG_DIR=$PWD/out/test_logs/$(date +%Y%m%d_%H%M%S)
# Color constants
BOLD="$(tput bold)"
END="$(tput sgr0)"
GREEN="$(tput setaf 2)"
RED="$(tput setaf 198)"
YELLOW="$(tput setaf 3)"
ORANGE="$(tput setaf 208)"
BLUE=$(tput setaf 4)

SKIP_BUILD=false
GCOV=false
DEBUG=false
KASAN=false
EXTRA_OPTIONS=()
LOCAL_REPO=
DEVICE_VARIANT="userdebug"

BOARD=
ABI=
PRODUCT=
BUILD_TYPE=
DEVICE_KERNEL_STRING=
DEVICE_KERNEL_VERSION=
SYSTEM_DLKM_INFO=

function print_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "This script will build images and flash a physical device."
    echo ""
    echo "Available options:"
    echo "  -s <serial_number>, --serial=<serial_number>"
    echo "                        [Mandatory] The serial number for device to be flashed with."
    echo "  --skip-build          [Optional] Skip the image build step. Will build by default if in repo."
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
    echo "  -vkb <vendor_kernel_build>, --vendor-kernel-build=<vendor_kernel_build>"
    echo "                        [Optional] The vendor kernel build path. Can be a local path or a remote build"
    echo "                        as ab://<branch>/<build_target>/<build_id>."
    echo "                        If not specified, and the script is running from a vendor kernel repo, "
    echo "                        it will use the kernel in the local repo."
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
                    print_error "device serial is not specified"
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
                    print_error "platform build is not specified"
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
                    print_error "system build is not specified"
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
                    print_error "kernel build path is not specified"
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
                    print_error "vendor kernel build path is not specified"
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
                    print_error "vendor kernel build target is not specified"
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
                print_error "Unsupported flag: $1" >&2
                shift
                ;;
        esac
    done
}

function adb_checker() {
    if ! which adb &> /dev/null; then
        print_error "adb not found!"
    fi
}

function go_to_repo_root() {
    current_dir="$1"
    while [ ! -d ".repo" ] && [ "$current_dir" != "/" ]; do
        current_dir=$(dirname "$current_dir")  # Go up one directory
        cd "$current_dir"
    done
}

function print_info() {
    local log_prompt=$MY_NAME
    if [ ! -z "$2" ]; then
        log_prompt+=" line $2"
    fi
    echo "[$log_prompt]: ${GREEN}$1${END}"
}

function print_warn() {
    local log_prompt=$MY_NAME
    if [ ! -z "$2" ]; then
        log_prompt+=" line $2"
    fi
    echo "[$log_prompt]: ${ORANGE}$1${END}"
}

function print_error() {
    local log_prompt=$MY_NAME
    if [ ! -z "$2" ]; then
        log_prompt+=" line $2"
    fi
    echo -e "[$log_prompt]: ${RED}$1${END}"
    cd $OLD_PWD
    exit 1
}

function set_platform_repo () {
    print_warn "Build environment target product '${TARGET_PRODUCT}' does not match expected $1. \
    Reset build environment" "$LINENO"
    local lunch_cli="source build/envsetup.sh && lunch $1"
    if [ -f "build/release/release_configs/trunk_staging.textproto" ]; then
        lunch_cli+="-trunk_staging-$DEVICE_VARIANT"
    else
        lunch_cli+="-$DEVICE_VARIANT"
    fi
    print_info "Setup build environment with: $lunch_cli" "$LINENO"
    eval "$lunch_cli"
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
        print_info "$lunch_cli succeeded" "$LINENO"
    else
        print_error "$lunch_cli failed" "$LINENO"
    fi
}

function find_repo () {
    manifest_output=$(grep -e "superproject" -e "gs-pixel" -e "kernel/private/devices/google/common" \
     -e "private/google-modules/soc/gs" -e "kernel/common" -e "common-modules/virtual-device" \
     .repo/manifests/default.xml)
    case "$manifest_output" in
        *platform/superproject*)
            PLATFORM_REPO_ROOT="$PWD"
            PLATFORM_VERSION=$(grep -e "platform/superproject" .repo/manifests/default.xml | \
            grep -oP 'revision="\K[^"]*')
            print_info "PLATFORM_REPO_ROOT=$PLATFORM_REPO_ROOT, PLATFORM_VERSION=$PLATFORM_VERSION" "$LINENO"
            if [ -z "$PLATFORM_BUILD" ]; then
                PLATFORM_BUILD="$PLATFORM_REPO_ROOT"
            elif [[ "$PLATFORM_BUILD" == "None" ]]; then
                PLATFORM_BUILD=
            fi
            ;;
        *kernel/private/devices/google/common*|*private/google-modules/soc/gs*)
            VENDOR_KERNEL_REPO_ROOT="$PWD"
            VENDOR_KERNEL_VERSION=$(grep -e "default revision" .repo/manifests/default.xml | \
            grep -oP 'revision="\K[^"]*')
            print_info "VENDOR_KERNEL_REPO_ROOT=$VENDOR_KERNEL_REPO_ROOT" "$LINENO"
            print_info "VENDOR_KERNEL_VERSION=$VENDOR_KERNEL_VERSION" "$LINENO"
            if [ -z "$VENDOR_KERNEL_BUILD" ]; then
                VENDOR_KERNEL_BUILD="$VENDOR_KERNEL_REPO_ROOT"
            fi
            ;;
        *common-modules/virtual-device*)
            KERNEL_REPO_ROOT="$PWD"
            KERNEL_VERSION=$(grep -e "kernel/superproject" \
            .repo/manifests/default.xml | grep -oP 'revision="common-\K[^"]*')
            print_info "KERNEL_REPO_ROOT=$KERNEL_REPO_ROOT, KERNEL_VERSION=$KERNEL_VERSION" "$LINENO"
            if [ -z "$KERNEL_BUILD" ]; then
                KERNEL_BUILD="$KERNEL_REPO_ROOT"
            fi
            ;;
        *)
            print_warn "Unknown manifest output. Could not determine repository type." "$LINENO"
            ;;
    esac
}

function build_platform () {
    if [[ "$SKIP_BUILD" = true ]]; then
        print_warn "--skip-build is set. Do not rebuild platform build" "$LINENO"
        return
    fi
    build_cmd="m -j12 ; make otatools -j12 ; make dist -j12"
    print_warn "Flag --skip-build is not set. Rebuilt images at $PWD with: $build_cmd" "$LINENO"
    eval $build_cmd
    exit_code=$?
    if [ $exit_code -eq 1 ]; then
        print_warn "$build_cmd returned exit_code $exit_code" "$LINENO"
        print_error "$build_cmd failed" "$LINENO"
    else
        if [ -f "${ANDROID_PRODUCT_OUT}/system.img" ]; then
            print_info "${ANDROID_PRODUCT_OUT}/system.img exist" "$LINENO"
        else
            print_error "${ANDROID_PRODUCT_OUT}/system.img doesn't exist" "$LINENO"
        fi
    fi
}

function build_ack () {
    if [[ "$SKIP_BUILD" = true ]]; then
        print_warn "--skip-build is set. Do not rebuild kernel" "$LINENO"
        return
    fi
    build_cmd="tools/bazel run --config=fast"
    if [ "$GCOV" = true ]; then
        build_cmd+=" --gcov"
    fi
    if [ "$DEBUG" = true ]; then
        build_cmd+=" --debug"
    fi
    if [ "$KASAN" = true ]; then
        build_cmd+=" --kasan"
    fi
    build_cmd+=" //common:kernel_aarch64_dist"
    print_warn "Flag --skip-build is not set. Rebuild the kernel with: $build_cmd." "$LINENO"
    eval $build_cmd
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
        print_info "$build_cmd succeeded" "$LINENO"
    else
        print_error "$build_cmd failed" "$LINENO"
    fi
}

function download_platform_build() {
    print_info "Downloading $1 to $PWD" "$LINENO"
    local build_info="$1"
    local file_patterns=("*$PRODUCT-img-*.zip" "bootloader.img" "radio.img" "misc_info.txt" "otatools.zip")
    if [[ "$1" == *"user/"* ]]; then
        file_patterns+=("vendor_ramdisk-debug.img")
    else
        file_patterns+=("vendor_ramdisk.img")
    fi

    echo "Downloading ${file_patterns[@]} from $build_info"
    for pattern in "${file_patterns[@]}"; do
        download_file_name="$build_info/$pattern"
        eval "$FETCH_SCRIPT $download_file_name"
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            print_info "Download $download_file_name succeeded" "$LINENO"
        else
            print_error "Download $download_file_name failed" "$LINENO"
        fi
        if [[ "$pattern" == "vendor_ramdisk-debug.img" ]]; then
            cp vendor_ramdisk-debug.img vendor_ramdisk.img
        fi
    done
    echo ""
}

function download_gki_build() {
    print_info "Downloading $1 to $PWD" "$LINENO"
    local build_info="$1"
    local _file_patterns=("Image.lz4" "boot-lz4.img" "system_dlkm_staging_archive.tar.gz" "system_dlkm.flatten.ext4.img" "system_dlkm.flatten.erofs.img")

    echo "Downloading ${_file_patterns[@]} from $build_info"
    for pattern in "${_file_patterns[@]}"; do
        download_file_name="$build_info/$pattern"
        eval "$FETCH_SCRIPT $download_file_name"
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            print_info "Download $download_file_name succeeded" "$LINENO"
        else
            print_error "Download $download_file_name failed" "$LINENO"
        fi
    done
    echo ""
}

function download_vendor_kernel_build() {
    print_info "Downloading $1 to $PWD" "$LINENO"
    local build_info="$1"
    local file_patterns=("vendor_dlkm_staging_archive.tar.gz" "Image.lz4" "dtbo.img" \
    "initramfs.img" "vendor_dlkm.img" "boot.img" "vendor_dlkm.modules.blocklist" "vendor_dlkm.modules.load" )

    if [[ "$VENDOR_KERNEL_VERSION" == *"6.6" ]]; then
        file_patterns+=("*vendor_dev_nodes_fragment.img")
    fi

    case "$PRODUCT" in
        oriole | raven | bluejay)
            file_patterns+=( "gs101-a0.dtb" "gs101-b0.dtb")
            ;;
        *)
            ;;
    esac

    echo "Downloading ${file_patterns[@]} from $build_info"
    for pattern in "${file_patterns[@]}"; do
        download_file_name="$build_info/$pattern"
        eval "$FETCH_SCRIPT $download_file_name"
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            print_info "Download $download_file_name succeeded" "$LINENO"
        else
            print_error "Download $download_file_name failed" "$LINENO"
        fi
    done
    echo ""
}

function flash_gki_build() {
    local _flash_cmd
    if [[ "$KERNEL_BUILD" == ab://* ]]; then
        _flash_cmd="$CL_FLASH_CLI --nointeractive -w -s $DEVICE_SERIAL_NUMBER "
        IFS='/' read -ra array <<< "$KERNEL_BUILD"
        if [ ! -z "${array[3]}" ]; then
            _flash_cmd+=" -t ${array[3]}"
        else
            _flash_cmd+=" -t kernel_aarch64"
        fi
        if [ ! -z "${array[4]}" ] && [[ "${array[4]}" != latest* ]]; then
            _flash_cmd+=" --bid ${array[4]}"
        else
            _flash_cmd+=" -l ${array[2]}"
        fi
    elif [ -d "$KERNEL_BUILD" ]; then
        _flash_cmd="$LOCAL_FLASH_CLI --nointeractive -w --kernel_dist_dir=$KERNEL_BUILD -s $DEVICE_SERIAL_NUMBER"
    else
        print_error "Can not flash GKI kernel from $KERNEL_BUILD" "$LINENO"
    fi

    print_info "Flashing GKI kernel with: $_flash_cmd" "$LINENO"
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

function flash_vendor_kernel_build() {
    if [ -z "$TRADEFED" ]; then
        find_tradefed_bin
    fi
    local tf_cli="$TRADEFED run commandAndExit template/local_min --log-level-display VERBOSE \
    --log-file-path=$LOG_DIR -s $SERIAL_NUMBER --disable-verity \
    --template:map test=example/reboot --num-of-reboots 1 \
    --template:map preparers=template/preparers/gki-device-flash-preparer"

    if [ -d "$DOWNLOAD_PATH/tf_vendor_kernel_dir" ]; then
        rm -rf "$DOWNLOAD_PATH/tf_vendor_kernel_dir"
    fi
    local vendor_kernel_dir="$DOWNLOAD_PATH/tf_vendor_kernel_dir"
    mkdir -p "$vendor_kernel_dir"
    local file_patterns=("boot.img" "initramfs.img" "dtbo.img" "vendor_dlkm.img")
    for pattern in "${file_patterns[@]}"; do
        if [ ! -f "$VENDOR_KERNEL_BUILD/$pattern" ]; then
            print_error "$VENDOR_KERNEL_BUILD/$pattern doesn't exist" "$LINENO"
        fi
        cp "$VENDOR_KERNEL_BUILD/$pattern" "$vendor_kernel_dir"
        if [[ "$pattern" == "boot.img" ]]; then
            tf_cli+=" --extra-file gki_boot.img=$vendor_kernel_dir/boot.img"
        else
            tf_cli+=" --extra-file $pattern=$vendor_kernel_dir/$pattern"
        fi
    done
    print_info "Run $tf_cli" "$LINENO"
    eval $tf_cli
}

# Function to check and wait for an ADB device
function wait_for_device_in_adb() {
    local timeout_seconds="${2:-300}"  # Timeout in seconds (default 5 minutes)

    local start_time=$(date +%s)
    local end_time=$((start_time + timeout_seconds))

    while (( $(date +%s) < end_time )); do
        if [ -z "$ADB_SERIAL_NUMBER" ]; then
            local _pontis_device=$(pontis devices | grep "$DEVICE_SERIAL_NUMBER")
            if [[ "$_pontis_device" == *ADB* ]]; then
                print_info "Device $DEVICE_SERIAL_NUMBER is connected through pontis in adb" "$LINENO"
                find_adb_serial_number
                get_device_info_from_adb
                return 0  # Success
            else
                sleep 5
            fi
        else
            devices=$(adb devices | grep "$ADB_SERIAL_NUMBER" | wc -l)

            if (( devices > 0 )); then
                print_info "Device $ADB_SERIAL_NUMBER is connected with adb" "$LINENO"
                return 0  # Success
            fi
            print_info "Waiting for device $ADB_SERIAL_NUMBER in adb devices" "$LINENO"
            sleep 5
        fi
    done

    print_error "Timeout waiting for $ADB_SERIAL_NUMBER in adb devices" "$LINENO"
}

function find_flashstation_binary() {
    if [ -x "${ANDROID_HOST_OUT}/bin/local_flashstation" ]; then
        $LOCAL_FLASH_CLI="${ANDROID_HOST_OUT}/bin/local_flashstation"
    elif [ ! -x "$LOCAL_FLASH_CLI" ]; then
        if ! which local_flashstation &> /dev/null; then
            print_error "Can not find local_flashstation binary. \
            Please see go/web-flashstation-command-line to download it" "$LINENO"
        else
            LOCAL_FLASH_CLI="local_flashstation"
        fi
    fi
    if [ -x "${ANDROID_HOST_OUT}/bin/cl_flashstation" ]; then
        $CL_FLASH_CLI="${ANDROID_HOST_OUT}/bin/cl_flashstation"
    elif [ ! -x "$CL_FLASH_CLI" ]; then
        if ! which cl_flashstation &> /dev/null; then
            print_error "Can not find cl_flashstation binary. \
            Please see go/web-flashstation-command-line to download it" "$LINENO"
        else
            CL_FLASH_CLI="cl_flashstation"
        fi
    fi
}

function flash_platform_build() {
    local _flash_cmd
    if [[ "$PLATFORM_BUILD" == ab://* ]]; then
        _flash_cmd="$CL_FLASH_CLI --nointeractive --force_flash_partitions --disable_verity -w -s $DEVICE_SERIAL_NUMBER "
        IFS='/' read -ra array <<< "$PLATFORM_BUILD"
        if [ ! -z "${array[3]}" ]; then
            local _build_type="${array[3]#*-}"
            if [[ "${array[2]}" == git_main* ]] && [[ "$_build_type" == user* ]]; then
                print_info "Build variant is not provided, using trunk_staging build" "$LINENO"
                _build_type="trunk_staging-$_build_type"
            fi
            _flash_cmd+=" -t $_build_type"
            if [[ "$_build_type" == *user ]] && [ ! -z "$KERNEL_BUILD" ] && [ -z "$VENDOR_KERNEL_BUILD" ]; then
                print_info "Need to flash GKI after flashing platform build, hence enabling --force_debuggable in user build flashing" "$LINENO"
                _flash_cmd+=" --force_debuggable"
            fi
        fi
        if [ ! -z "${array[4]}" ] && [[ "${array[4]}" != latest* ]]; then
            echo "Flash $SERIAL_NUMBER with platform build from branch $PLATFORM_BUILD..."
            _flash_cmd+=" --bid ${array[4]}"
        else
            echo "Flash $SERIAL_NUMBER with platform build $PLATFORM_BUILD..."
            _flash_cmd+=" -l ${array[2]}"
        fi
    elif [ ! -z "$PLATFORM_REPO_ROOT" ] && [[ "$PLATFORM_BUILD" == "$PLATFORM_REPO_ROOT/out/target/product/$PRODUCT" ]] && \
    [ -x "$PLATFORM_REPO_ROOT/vendor/google/tools/flashall" ]; then
        cd "$PLATFORM_REPO_ROOT"
        print_info "Flashing device with vendor/google/tools/flashall" "$LINENO"
        if [ -z "${TARGET_PRODUCT}" ] || [[ "${TARGET_PRODUCT}" != *"$PRODUCT" ]]; then
            if [[ "$PLATFORM_VERSION" == aosp-* ]]; then
                set_platform_repo "aosp_$PRODUCT"
            else
                set_platform_repo "$PRODUCT"
            fi
        fi
        _flash_cmd="vendor/google/tools/flashall  --nointeractive -w -s $DEVICE_SERIAL_NUMBER"
    else
        if [ -z "${TARGET_PRODUCT}" ]; then
            export TARGET_PRODUCT="$PRODUCT"
        fi
        if [ -z "${TARGET_BUILD_VARIANT}" ]; then
            export TARGET_BUILD_VARIANT="$DEVICE_VARIANT"
        fi
        if [ -z "${ANDROID_PRODUCT_OUT}" ] || [[ "${ANDROID_PRODUCT_OUT}" != "$PLATFORM_BUILD" ]] ; then
            export ANDROID_PRODUCT_OUT="$PLATFORM_BUILD"
        fi
        if [ -z "${ANDROID_HOST_OUT}" ]; then
            export ANDROID_HOST_OUT="$PLATFORM_BUILD"
        fi
        if [ ! -f "$PLATFORM_BUILD/system.img" ]; then
            local device_image=$(find "$PLATFORM_BUILD" -maxdepth 1 -type f -name *-img*.zip)
            unzip -j "$device_image" -d "$PLATFORM_BUILD"
        fi

        awk '! /baseband/' "$PLATFORM_BUILD"/android-info.txt > temp && mv temp "$PLATFORM_BUILD"/android-info.txt
        awk '! /bootloader/' "$PLATFORM_BUILD"/android-info.txt > temp && mv temp "$PLATFORM_BUILD"/android-info.txt

        _flash_cmd="$LOCAL_FLASH_CLI --nointeractive --force_flash_partitions --disable_verity --disable_verification  -w -s $DEVICE_SERIAL_NUMBER"
    fi
    print_info "Flashing device with: $_flash_cmd" "$LINENO"
    eval "$_flash_cmd"
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo "Flash platform succeeded"
        wait_for_device_in_adb
        return
    else
        echo "Flash platform build failed with exit code $exit_code"
        exit 1
    fi

}

function get_mix_ramdisk_script() {
    download_file_name="ab://git_main/aosp_cf_x86_64_only_phone-trunk_staging-userdebug/latest/otatools.zip"
    eval "$FETCH_SCRIPT $download_file_name"
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
        print_info "Download $download_file_name succeeded" "$LINENO"
    else
        print_error "Download $download_file_name failed" "$LINENO" "$LINENO"
    fi
    eval "unzip -j otatools.zip bin/$MIX_SCRIPT_NAME"
    echo ""
}

function mixing_build() {
    if [ ! -z ${PLATFORM_REPO_ROOT_PATH} ] && [ -f "$PLATFORM_REPO_ROOT_PATH/vendor/google/tools/$MIX_SCRIPT_NAME"]; then
        mix_kernel_cmd="$PLATFORM_REPO_ROOT_PATH/vendor/google/tools/$MIX_SCRIPT_NAME"
    elif [ -f "$DOWNLOAD_PATH/$MIX_SCRIPT_NAME" ]; then
        mix_kernel_cmd="$DOWNLOAD_PATH/$MIX_SCRIPT_NAME"
    else
        cd "$DOWNLOAD_PATH"
        get_mix_ramdisk_script
        mix_kernel_cmd="$PWD/$MIX_SCRIPT_NAME"
    fi
    if [ ! -f "$mix_kernel_cmd" ]; then
        print_error "$mix_kernel_cmd doesn't exist or is not executable" "$LINENO"
    elif [ ! -x "$mix_kernel_cmd" ]; then
        print_error "$mix_kernel_cmd is not executable" "$LINENO"
    fi
    if [[ "$PLATFORM_BUILD" == ab://* ]]; then
        print_info "Download platform build $PLATFORM_BUILD" "$LINENO"
        if [ -d "$DOWNLOAD_PATH/device_dir" ]; then
            rm -rf "$DOWNLOAD_PATH/device_dir"
        fi
        PLATFORM_DIR="$DOWNLOAD_PATH/device_dir"
        mkdir -p "$PLATFORM_DIR"
        cd "$PLATFORM_DIR" || $(print_error "Fail to go to $PLATFORM_DIR" "$LINENO")
        download_platform_build "$PLATFORM_BUILD"
        PLATFORM_BUILD="$PLATFORM_DIR"
    elif [ ! -z "$PLATFORM_REPO_ROOT" ] && [[ "$PLATFORM_BUILD" == "$PLATFORM_REPO_ROOT"* ]]; then
        print_info "Copy platform build $PLATFORM_BUILD to $DOWNLOAD_PATH/device_dir" "$LINENO"
        PLATFORM_DIR="$DOWNLOAD_PATH/device_dir"
        mkdir -p "$PLATFORM_DIR"
        cd "$PLATFORM_DIR" || $(print_error "Fail to go to $PLATFORM_DIR" "$LINENO")
        local device_image=$(find "$PLATFORM_BUILD" -maxdepth 1 -type f -name *-img.zip)
        if [ ! -z "device_image" ]; then
            cp "$device_image $PLATFORM_DIR/$PRODUCT-img-0.zip" "$PLATFORM_DIR"
        else
            device_image=$(find "$PLATFORM_BUILD" -maxdepth 1 -type f -name *-img-*.zip)
            if [ ! -z "device_image" ]; then
                cp "$device_image $PLATFORM_DIR/$PRODUCT-img-0.zip" "$PLATFORM_DIR"
            else
                print_error "Can't find $RPODUCT-img-*.zip in $PLATFORM_BUILD"
            fi
        fi
        local file_patterns=("bootloader.img" "radio.img" "vendor_ramdisk.img" "misc_info.txt" "otatools.zip")
        for pattern in "${file_patterns[@]}"; do
            cp "$PLATFORM_BUILD/$pattern" "$PLATFORM_DIR/$pattern"
            exit_code=$?
            if [ $exit_code -eq 0 ]; then
                print_info "Copied $PLATFORM_BUILD/$pattern to $PLATFORM_DIR" "$LINENO"
            else
                print_error "Failed to copy $PLATFORM_BUILD/$pattern to $PLATFORM_DIR" "$LINENO"
            fi
        done
        PLATFORM_BUILD="$PLATFORM_DIR"
    fi

    if [[ "$KERNEL_BUILD" == ab://* ]]; then
        print_info "Download kernel build $KERNEL_BUILD" "$LINENO"
        if [ -d "$DOWNLOAD_PATH/gki_dir" ]; then
            rm -rf "$DOWNLOAD_PATH/gki_dir"
        fi
        GKI_DIR="$DOWNLOAD_PATH/gki_dir"
        mkdir -p "$GKI_DIR"
        cd "$GKI_DIR" || $(print_error "Fail to go to $GKI_DIR" "$LINENO")
        download_gki_build $KERNEL_BUILD
        KERNEL_BUILD="$GKI_DIR"
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
    print_info "Run: $mixed_build_cmd" "$LINENO"
    eval $mixed_build_cmd
    device_image=$(ls $new_device_dir/*$PRODUCT-img*.zip)
    if [ ! -f "$device_image" ]; then
        print_error "New device image is not created in $new_device_dir" "$LINENO"
    fi
    cp "$PLATFORM_BUILD"/bootloader.img $new_device_dir/.
    cp "$PLATFORM_BUILD"/radio.img $new_device_dir/.
    PLATFORM_BUILD="$new_device_dir"
}

get_kernel_version_from_boot_image() {
    local boot_image_path="$1"
    local version_output

    # Check for mainline kernel
    version_output=$(strings "$boot_image_path" | grep mainline)
    if [ ! -z "$version_output" ]; then
        KERNEL_VERSION="android-mainline"
        return  # Exit the function early if a match is found
    fi

    # Check for Android 15 6.6 kernel
    version_output=$(strings "$boot_image_path" | grep "android15" | grep "6.6")
    if [ ! -z "$version_output" ]; then
        KERNEL_VERSION="android15-6.6"
        return
    fi

    # Check for Android 14 6.1 kernel
    version_output=$(strings "$boot_image_path" | grep "android14" | grep "6.1")
    if [ ! -z "$version_output" ]; then
        KERNEL_VERSION="android14-6.1"
        return
    fi

    # Check for Android 14 5.15 kernel
    version_output=$(strings "$boot_image_path" | grep "android14" | grep "5.15")
    if [ ! -z "$version_output" ]; then
        KERNEL_VERSION="android14-5.15"
        return
    fi

    # Check for Android 13 5.15 kernel
    version_output=$(strings "$boot_image_path" | grep "android13" | grep "5.15")
    if [ ! -z "$version_output" ]; then
        KERNEL_VERSION="android13-5.15"
        return
    fi

    # Check for Android 13 5.10 kernel
    version_output=$(strings "$boot_image_path" | grep "android13" | grep "5.10")
    if [ ! -z "$version_output" ]; then
        KERNEL_VERSION="android13-5.10"
        return
    fi

    # Check for Android 12 5.10 kernel
    version_output=$(strings "$boot_image_path" | grep "android12" | grep "5.10")
    if [ ! -z "$version_output" ]; then
        KERNEL_VERSION="android12-5.10"
        return
    fi
}

function gki_build_only_operation {
    IFS='-' read -ra array <<< "$KERNEL_VERSION"
    case "$KERNEL_VERSION" in
        android-mainline | android15-6.6* | android14-6.1* | android14-5.15* )
            if [[ "$KERNEL_VERSION" == "$DEVICE_KERNEL_VERSION"* ]] && [ ! -z "$SYSTEM_DLKM_INFO" ]; then
                print_info "Device $SERIAL_NUMBER is with $KERNEL_VERSION kernel. Flash GKI directly" "$LINENO"
                flash_gki_build
            elif [ -z "$SYSTEM_DLKM_INFO" ]; then
                print_warn "Device $SERIAL_NUMBER is $PRODUCT that doesn't have system_dlkm partition. Can't flash GKI directly. \
Please add vendor kernel build for example by flag -vkb ab://kernel-${array[0]}-gs-pixel-${array[1]}/<kernel_target>/latest" "$LINENO"
                print_error "Can not flash GKI to SERIAL_NUMBER without -vkb <vendor_kernel_build> been specified." "$LINENO"
            elif [[ "$KERNEL_VERSION" != "$DEVICE_KERNEL_VERSION"* ]]; then
                print_warn "Device $PRODUCT $SERIAL_NUMBER comes with $DEVICE_KERNEL_STRING kernel. Can't flash GKI directly. \
Please add a platform build with $KERNEL_VERSION kernel or add vendor kernel build for example by flag \
-vkb ab://kernel-${array[0]}-gs-pixel-${array[1]}/<kernel_target>/latest" "$LINENO"
                print_error "Cannot flash $KERNEL_VERSION GKI to device directly $SERIAL_NUMBER." "$LINENO"
            fi
            ;;
        android13-5.15* | android13-5.10* | android12-5.10* | android12-5.4* )
            if [[ "$KERNEL_VERSION" == "$EVICE_KERNEL_VERSION"* ]]; then
                print_info "Device $SERIAL_NUMBER is with android13-5.15 kernel. Flash GKI directly." "$LINENO"
                flash_gki_build
            else
                print_warn "Device $SERIAL_NUMBER is $PRODUCT comes with $DEVICE_KERNEL_STRING kernel. Can't flash GKI directly. \
Please add a platform build with $KERNEL_VERSION kernel or add vendor kernel build for example by flag \
-vkb ab://kernel-${array[0]}-gs-pixel-${array[1]}/<kernel_target>/latest" "$LINENO"
                print_error "Cannot flash $KERNEL_VERSION GKI to device directly $SERIAL_NUMBER." "$LINENO"
            fi
            ;;
        *)
            print_error "Unsupported KERNEL_VERSION: $KERNEL_VERSION" "$LINENO" "$LINENO"
            ;;
    esac
}

function extract_device_kernel_version() {
    local kernel_string="$1"
    # Check if the string contains '-android'
    if [[ "$kernel_string" == *"-mainline"* ]]; then
        DEVICE_KERNEL_VERSION="android-mainline"
    elif [[ "$kernel_string" == *"-android"* ]]; then
        # Extract the substring between the first hyphen and the second hyphen
        DEVICE_KERNEL_VERSION=$(echo "$kernel_string" | awk -F '-' '{print $2"-"$1}' | cut -d '.' -f -2)
    else
       print_warn "Can not parse $kernel_string into kernel version" "$LINENO"
    fi
    print_info "Device kernel version is $DEVICE_KERNEL_VERSION" "$LINENO"
}

function find_adb_serial_number() {
    print_info "Try to find device $DEVICE_SERIAL_NUMBER serial id in adb devices" "$LINENO"
    local _device_ids=$(adb devices | awk '$2 == "device" {print $1}')
    devices=()
    while IFS= read -r device_id; do
        devices+=("$device_id")
    done <<< "$_device_ids"

    for device_id in "${devices[@]}"; do
        local _device_serial_number=$(adb -s "$device_id" shell getprop ro.serialno)
        #echo "DEVICE $device_id has serialno $_device_serial_number"
        if [[ "$_device_serial_number" == "$DEVICE_SERIAL_NUMBER" ]]; then
            ADB_SERIAL_NUMBER="$device_id"
            print_info "Device $DEVICE_SERIAL_NUMBER shows up as $ADB_SERIAL_NUMBER in adb" "$LINENO"
            return 0
        fi
    done
    print_error "Can not find device in adb has device serial number $DEVICE_SERIAL_NUMBER. \
    Check if the device is connected with adb authentication" "$LINENO"
}

function find_fastboot_serial_number() {
    print_info "Try to find device $DEVICE_SERIAL_NUMBER serial id in fastboot devices" "$LINENO"
    local _output=$(fastboot devices | awk '{print $1}')
    while IFS= read -r device_id; do
        # Use fastboot getvar to retrieve serial number
        local _output=$(fastboot -s "$device_id" getvar serialno 2>&1)
        local _device_serial_number=$(echo "$_output" | grep -Po "serialno: [A-Z0-9]+" | cut -c 11-)
        #echo "Device $device has serial number $_device_serial_number"
        if [[ "$_device_serial_number" == "$DEVICE_SERIAL_NUMBER" ]]; then
            FASTBOOT_SERIAL_NUMBER="$device_id"
            print_info "Device $DEVICE_SERIAL_NUMBER shows up as $FASTBOOT_SERIAL_NUMBER in fastboot" "$LINENO"
            return 0
        fi
    done <<< "$_output"
    print_error "Can not find device in fastboot has device serial number $DEVICE_SERIAL_NUMBER" "$LINENO"
}

function get_device_info_from_adb {
    if [ -z "$DEVICE_SERIAL_NUMBER" ]; then
        DEVICE_SERIAL_NUMBER=$(adb -s "$ADB_SERIAL_NUMBER" shell getprop ro.serialno)
        if [ -z "$DEVICE_SERIAL_NUMBER" ]; then
            print_error "Can not get device serial adb -s $ADB_SERIAL_NUMBER" "$LINENO"
        fi
    fi
    BOARD=$(adb -s "$ADB_SERIAL_NUMBER" shell getprop ro.product.board)
    ABI=$(adb -s "$ADB_SERIAL_NUMBER" shell getprop ro.product.cpu.abi)

    # Only get PRODUCT if it's not already set
    if [ -z "$PRODUCT" ]; then
        PRODUCT=$(adb -s "$ADB_SERIAL_NUMBER" shell getprop ro.build.product)
        # Check if PRODUCT is valid after attempting to retrieve it
        if [ -z "$PRODUCT" ]; then
            print_error "$ADB_SERIAL_NUMBER does not have a valid product value" "$LINENO"
        fi
    fi

    BUILD_TYPE=$(adb -s "$ADB_SERIAL_NUMBER" shell getprop ro.build.type)
    DEVICE_KERNEL_STRING=$(adb -s "$ADB_SERIAL_NUMBER" shell uname -r)
    extract_device_kernel_version "$DEVICE_KERNEL_STRING"
    SYSTEM_DLKM_INFO=$(adb -s "$ADB_SERIAL_NUMBER" shell getprop dev.mnt.blk.system_dlkm)
    if [[ "$SERIAL_NUMBER" != "$DEVICE_SERIAL_NUMBER" ]]; then
        print_info "Device $SERIAL_NUMBER has DEVICE_SERIAL_NUMBER=$DEVICE_SERIAL_NUMBER, ADB_SERIAL_NUMBER=$ADB_SERIAL_NUMBER" "$LINENO"
    fi
    print_info "Device $SERIAL_NUMBER info: BOARD=$BOARD, ABI=$ABI, PRODUCT=$PRODUCT, BUILD_TYPE=$BUILD_TYPE \
    SYSTEM_DLKM_INFO=$SYSTEM_DLKM_INFO, DEVICE_KERNEL_STRING=$DEVICE_KERNEL_STRING" "$LINENO"
}

function get_device_info_from_fastboot {
    # try get product by fastboot command
    if [ -z "$DEVICE_SERIAL_NUMBER" ]; then
        local _output=$(fastboot -s "$FASTBOOT_SERIAL_NUMBER" getvar serialno 2>&1)
        DEVICE_SERIAL_NUMBER=$(echo "$_output" | grep -Po "serialno: [A-Z0-9]+" | cut -c 11-)
        if [ -z "$DEVICE_SERIAL_NUMBER" ]; then
            print_error "Can not get device serial from $SERIAL_NUMBER" "$LINENO"
        fi
    fi

    # Only get PRODUCT if it's not already set
    if [ -z "$PRODUCT" ]; then
        _output=$(fastboot -s "$FASTBOOT_SERIAL_NUMBER" getvar product 2>&1)
        PRODUCT=$(echo "$_output" | grep -oP '^product:\s*\K.*' | cut -d' ' -f1)
        # Check if PRODUCT is valid after attempting to retrieve it
        if [ -z "$PRODUCT" ]; then
            print_error "$FASTBOOT_SERIAL_NUMBER does not have a valid product value" "$LINENO"
        fi
    fi

    if [[ "$SERIAL_NUMBER" != "$DEVICE_SERIAL_NUMBER" ]]; then
        print_info "Device $SERIAL_NUMBER has DEVICE_SERIAL_NUMBER=$DEVICE_SERIAL_NUMBER, FASTBOOT_SERIAL_NUMBER=$FASTBOOT_SERIAL_NUMBER" "$LINENO"
    fi
    print_info "Device $SERIAL_NUMBER is in fastboot with device info: PRODUCT=$PRODUCT" "$LINENO"
}

function get_device_info() {
    local _adb_count=$(adb devices | grep "$SERIAL_NUMBER" | wc -l)
    if (( _adb_count > 0 )); then
        print_info "$SERIAL_NUMBER is connected through adb" "$LINENO"
        ADB_SERIAL_NUMBER="$SERIAL_NUMBER"
        get_device_info_from_adb
        if [[ "$SERIAL_NUMBER" == "$DEVICE_SERIAL_NUMBER" ]]; then
            FASTBOOT_SERIAL_NUMBER="$SERIAL_NUMBER"
        fi
        return 0
    fi

    local _fastboot_count=$(fastboot devices | grep "$SERIAL_NUMBER" | wc -l)
    if (( _fastboot_count > 0 )); then
        print_info "$SERIAL_NUMBER is connected through fastboot" "$LINENO"
        FASTBOOT_SERIAL_NUMBER="$SERIAL_NUMBER"
        get_device_info_from_fastboot
        return 0
    fi

    local _pontis_device=$(pontis devices | grep "$SERIAL_NUMBER")
    if [[ "$_pontis_device" == *Fastboot* ]]; then
        DEVICE_SERIAL_NUMBER="$SERIAL_NUMBER"
        print_info "Device $SERIAL_NUMBER is connected through pontis in fastboot" "$LINENO"
        find_fastboot_serial_number
        get_device_info_from_fastboot
        return 0
    elif [[ "$_pontis_device" == *ADB* ]]; then
        DEVICE_SERIAL_NUMBER="$SERIAL_NUMBER"
        print_info "Device $SERIAL_NUMBER is connected through pontis in adb" "$LINENO"
        find_adb_serial_number
        get_device_info_from_adb
        return 0
    fi

    print_error "$SERIAL_NUMBER is not connected with adb or fastboot" "$LINENO"
}

function find_tradefed_bin {
    cd "$REPO_ROOT_PATH"
    if [ -f "${ANDROID_HOST_OUT}/bin/tradefed.sh" ] ; then
        TRADEFED="${ANDROID_HOST_OUT}/bin/tradefed.sh"
        print_info "Use the tradefed from the local built path $TRADEFED" "$LINENO"
        return
    elif [ -f "$PLATFORM_TF_PREBUILT" ]; then
        TF_BIN="$PLATFORM_TF_PREBUILT"
        print_info "Local Tradefed is not built yet. Use the prebuilt from $PLATFORM_TF_PREBUILT" "$LINENO"
    elif [ -f "$KERNEL_TF_PREBUILT" ]; then
        TF_BIN="$KERNEL_TF_PREBUILT"
    elif [ -f "/tmp/tradefed/tradefed.sh" ]; then
        TF_BIN=/tmp/tradefed/tradefed.sh
    # No Tradefed found
    else
        mkdir -p "/tmp/tradefed"
        cd /tmp/tradefed
        eval "$FETCH_SCRIPT ab://tradefed/tradefed/latest/google-tradefed.zip"
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            print_info "Download tradefed succeeded" "$LINENO"
        else
            print_error "Download tradefed failed" "$LINENO"
        fi
        echo ""
        eval "unzip -oq google-tradefed.zip"
        TF_BIN=/tmp/tradefed/tradefed.sh
        cd "$REPO_ROOT_PATH"
    fi
    if [ -d "${ANDROID_JAVA_HOME}" ] ; then
        JDK_PATH="${ANDROID_JAVA_HOME}"
    elif [ -d "$PLATFORM_JDK_PATH" ] ; then
        JDK_PATH="$PLATFORM_JDK_PATH"
    elif [ -d "$KERNEL_JDK_PATH" ] ; then
        JDK_PATH="$KERNEL_JDK_PATH"
    elif [ -d "$LOCAL_JDK_PATH" ] ; then
        JDK_PATH="$LOCAL_JDK_PATH"
    else
        print_error "Can't find JAVA JDK path" "$LINENO"
    fi
    TRADEFED="JAVA_HOME=$JDK_PATH PATH=$JDK_PATH/bin:$PATH $TF_BIN"
}

adb_checker

LOCAL_REPO=

OLD_PWD=$PWD
MY_NAME=$0

parse_arg "$@"

if [ -z "$SERIAL_NUMBER" ]; then
    print_error "Device serial is not provided with flag -s <serial_number>." "$LINENO"
    exit 1
fi

get_device_info

FULL_COMMAND_PATH=$(dirname "$PWD/$0")
REPO_LIST_OUT=$(repo list 2>&1)
if [[ "$REPO_LIST_OUT" == "error"* ]]; then
    print_error "Current path $PWD is not in an Android repo. Change path to repo root." "$LINENO"
    go_to_repo_root "$FULL_COMMAND_PATH"
    print_info "Changed path to $PWD" "$LINENO"
else
    go_to_repo_root "$PWD"
fi

REPO_ROOT_PATH="$PWD"
FETCH_SCRIPT="$REPO_ROOT_PATH/$FETCH_SCRIPT"

find_repo

if [ ! -d "$DOWNLOAD_PATH" ]; then
    mkdir -p "$DOWNLOAD_PATH" || $(print_error "Fail to create directory $DOWNLOAD_PATH" "$LINENO")
fi

if [ ! -z "$PLATFORM_BUILD" ] && [[ "$PLATFORM_BUILD" != ab://* ]] && [ -d "$PLATFORM_BUILD" ]; then
    # Check if PLATFORM_BUILD is an Android platform repo
    cd "$PLATFORM_BUILD"
    PLATFORM_REPO_LIST_OUT=$(repo list 2>&1)
    if [[ "$PLATFORM_REPO_LIST_OUT" != "error"* ]]; then
        go_to_repo_root "$PWD"
        if [[ "$PWD" != "$REPO_ROOT_PATH" ]]; then
            find_repo
        fi
        if [ "$SKIP_BUILD" = false ] && [[ "$PLATFORM_BUILD" != "ab://"* ]] && [[ ! -z "$PLATFORM_BUILD" ]]; then
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
                print_error "Can not build platform build due to lunch build target failure" "$LINENO"
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

if [[ "$SYSTEM_BUILD" == ab://* ]]; then
    print_warn "System build is not supoort yet" "$LINENO"
elif [ ! -z "$SYSTEM_BUILD" ] && [ -d "$SYSTEM_BUILD" ]; then
    print_warn "System build is not supoort yet" "$LINENO"
    # Get GSI build
    cd "$SYSTEM_BUILD"
    SYSTEM_REPO_LIST_OUT=$(repo list 2>&1)
    if [[ "$SYSTEM_REPO_LIST_OUT" != "error"* ]]; then
        go_to_repo_root "$PWD"
        if [[ "$PWD" != "$REPO_ROOT_PATH" ]]; then
            find_repo
        fi
        if [ -z "${TARGET_PRODUCT}" ] || [[ "${TARGET_PRODUCT}" != "_arm64" ]]; then
            set_platform_repo "aosp_arm64"
            if [ "$SKIP_BUILD" = false ] ; then
                build_platform
            fi
            SYSTEM_BUILD="${ANDROID_PRODUCT_OUT}/system.img"
        fi
    fi
fi

find_flashstation_binary

if [[ "$KERNEL_BUILD" == ab://* ]]; then
    IFS='/' read -ra array <<< "$KERNEL_BUILD"
    KERNEL_VERSION=$(echo "${array[2]}" | sed "s/aosp_kernel-common-//g")
    IFS='-' read -ra array <<< "$KERNEL_VERSION"
    KERNEL_VERSION="${array[0]}-${array[1]}"
    print_info "$KERNEL_BUILD is KERNEL_VERSION $KERNEL_VERSION" "$LINENO"
    if [[ "$KERNEL_VERSION" != "$DEVICE_KERNEL_VERSION"* ]] && [ -z "$PLATFORM_BUILD" ] && [ -z "$VENDOR_KERNEL_BUILD" ]; then
        print_warn "Device $PRODUCT $SERIAL_NUMBER comes with $DEVICE_KERNEL_STRING $DEVICE_KERNEL_VERSION kernel. \
Can't flash $KERNEL_VERSION GKI directly. Please use a platform build with the $KERNEL_VERSION kernel \
or use a vendor kernel build by flag -vkb, for example -vkb -vkb ab://kernel-${array[0]}-gs-pixel-${array[1]}/<kernel_target>/latest" "$LINENO"
        print_error "Cannot flash $KERNEL_VERSION GKI to device $SERIAL_NUMBER directly." "$LINENO"
    fi
elif [ ! -z "$KERNEL_BUILD" ] && [ -d "$KERNEL_BUILD" ]; then
    # Check if kernel repo is provided
    cd "$KERNEL_BUILD"
    KERNEL_REPO_LIST_OUT=$(repo list 2>&1)
    if [[ "$KERNEL_REPO_LIST_OUT" != "error"* ]]; then
        go_to_repo_root "$PWD"
        if [[ "$PWD" != "$REPO_ROOT_PATH" ]]; then
            find_repo
        fi
        if [ "$SKIP_BUILD" = false ] ; then
            if [ ! -f "common/BUILD.bazel" ]; then
                # TODO: Add build support to android12 and earlier kernels
                print_error "bazel build is not supported in $PWD" "$LINENO"
            else
                build_ack
            fi
        fi
        KERNEL_BUILD="$PWD/out/kernel_aarch64/dist"
    elif [ -f "$KERNEL_BUILD/boot*.img" ]; then
        get_kernel_version_from_boot_image "$KERNEL_BUILD/boot*.img"
    fi
fi

if [[ "$VENDOR_KERNEL_BUILD" == ab://* ]]; then
    print_info "Download vendor kernel build $VENDOR_KERNEL_BUILD" "$LINENO"
    if [ -d "$DOWNLOAD_PATH/vendor_kernel_dir" ]; then
        rm -rf "$DOWNLOAD_PATH/vendor_kernel_dir"
    fi
    VENDOR_KERNEL_DIR="$DOWNLOAD_PATH/vendor_kernel_dir"
    mkdir -p "$VENDOR_KERNEL_DIR"
    cd "$VENDOR_KERNEL_DIR" || $(print_error "Fail to go to $VENDOR_KERNEL_DIR" "$LINENO")
    download_vendor_kernel_build $VENDOR_KERNEL_BUILD
    VENDOR_KERNEL_BUILD="$VENDOR_KERNEL_DIR"
elif [ ! -z "$VENDOR_KERNEL_BUILD" ] && [ -d "$VENDOR_KERNEL_BUILD" ]; then
    # Check if vendor kernel repo is provided
    cd "$VENDOR_KERNEL_BUILD"
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
                print_warn "There are multiple build_*.sh scripts in $PWD, Can't decide vendor kernel build target" "$LINENO"
                print_error "Please use -vkbt <value> or --vendor-kernel-build-target=<value> to specify a kernel build target" "$LINENO"
            else
                # TODO: Add build support to android12 and earlier kernels
                print_error "There is no build_*.sh script in $PWD" "$LINENO"
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
            print_info "Build vendor kernel with $build_cmd"
            eval "$build_cmd"
            exit_code=$?
            if [ $exit_code -eq 0 ]; then
                print_info "Build vendor kernel succeeded"
            else
                print_error "Build vendor kernel failed with exit code $exit_code"
                exit 1
            fi
        fi
        VENDOR_KERNEL_BUILD="$PWD/out/$VENDOR_KERNEL_BUILD_TARGET/dist"
    fi
fi

if [ -z "$PLATFORM_BUILD" ]; then  # No platform build provided
    if [ -z "$KERNEL_BUILD" ] && [ -z "$VENDOR_KERNEL_BUILD" ]; then  # No kernel or vendor kernel build
        print_info "KERNEL_BUILD=$KERNEL_BUILD VENDOR_KERNEL_BUILD=$VENDOR_KERNEL_BUILD" "$LINENO"
        print_error "Nothing to flash" "$LINENO"
    elif [ -z "$KERNEL_BUILD" ] && [ ! -z "$VENDOR_KERNEL_BUILD" ]; then  # Only vendor kernel build
        print_info "Flash kernel from $VENDOR_KERNEL_BUILD" "$LINENO"
        flash_vendor_kernel_build
    elif [ ! -z "$KERNEL_BUILD" ] && [ ! -z "$VENDOR_KERNEL_BUILD" ]; then  # Both kernel and vendor kernel builds
        print_error "Mixing only GKI build & vendor kernel build is not supported. \
Please add platform build for example -pb ab://git_main/$PRODUCT-trunk_staging-userdebug/latest." "$LINENO"
    elif [ ! -z "$KERNEL_BUILD" ] && [ -z "$VENDOR_KERNEL_BUILD" ]; then  # Only GKI build
        gki_build_only_operation
    fi
else  # Platform build provided
    if [ -z "$KERNEL_BUILD" ] && [ -z "$VENDOR_KERNEL_BUILD" ]; then  # No kernel or vendor kernel build
        print_info "Flash platform build only"
        flash_platform_build
    elif [ -z "$KERNEL_BUILD" ] && [ ! -z "$VENDOR_KERNEL_BUILD" ]; then  # Vendor kernel build and platform build
        print_info "Mix vendor kernel and platform build"
        mixing_build
        flash_platform_build
    elif [ ! -z "$KERNEL_BUILD" ] && [ -z "$VENDOR_KERNEL_BUILD" ]; then # GKI build and platform build
        flash_platform_build
        get_device_info
        gki_build_only_operation
    elif [ ! -z "$KERNEL_BUILD" ] && [ ! -z "$VENDOR_KERNEL_BUILD" ]; then  # All three builds provided
        print_info "Mix GKI kernel, vendor kernel and platform build" "$LINENO"
        mixing_build
        flash_platform_build
    fi
fi
