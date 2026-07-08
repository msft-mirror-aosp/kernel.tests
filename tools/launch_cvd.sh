#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

# A handy tool to launch CVD with local build or remote build.

# --- Configuration Constants ---
readonly ACLOUD_PREBUILT="prebuilts/asuite/acloud/linux-x86/acloud"
readonly OPT_SKIP_PRERUNCHECK='--skip-pre-run-check'
PRODUCT='aosp_cf_x86_64_only_phone'
readonly DEFAULT_GSI_PRODUCT='gsi_x86_64' # Assuming this for GSI builds
SKIP_BUILD=false
USE_RBE=false
GCOV=false
DEBUG=false
KASAN=false
EXTRA_OPTIONS=()
CF_KERNEL_REPO_ROOT=""
CF_KERNEL_VERSION=""
PLATFORM_REPO_ROOT=""
PLATFORM_VERSION=""

readonly REQUIRED_COMMANDS=("adb" "grep" "basename" "dirname" "read" "realpath" "nproc" "bc")

# --- Library Import ---
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$( cd "$( dirname "${SCRIPT_PATH}" )" &> /dev/null && pwd -P)"
LIB_PATH="${SCRIPT_DIR}/common_lib.sh"

if [[ ! -f "$LIB_PATH" ]]; then
    # Cannot use log_error yet as library isn't sourced
    echo "FATAL ERROR: Cannot find required library '$LIB_PATH'" >&2
    exit 1
fi

# Source the library. Check return code in case sourcing fails (e.g., missing dependency in lib)
if ! . "$LIB_PATH"; then
    echo "FATAL ERROR: Failed to source library '$LIB_PATH'. Check common_lib.sh dependencies." >&2
    exit 1
fi

# --- Functions ---
function print_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "This script will build images and launch a Cuttlefish device."
    echo ""
    echo "Available options:"
    echo "  --use-rbe             Enable Remote Build Execution to speed up large, non-google3 builds."
    echo "                        Requires RBE service access; See go/build-fast for details."
    echo "  --skip-build          Skip the image build step. Will build by default if in repo."
    echo "  --gcov                Launch CVD with gcov enabled kernel"
    echo "  --debug               Launch CVD with debug enabled kernel"
    echo "  --kasan               Launch CVD with kasan enabled kernel"
    echo "  -pb <platform_build>, --platform-build=<platform_build>"
    echo "                        The platform build path. Can be a local path or a remote build"
    echo "                        as ab://<branch>/<build_target>/<build_id>."
    echo "                        If not specified, it will use the platform build in the local"
    echo "                        repo, or the default compatible platform build for the kernel."
    echo "  -gsi <gsi_build>, --gsi-build=<gsi_build>"
    echo "                        The GSI build path for GSI testing. Can be a local path or"
    echo "                        remote build as ab://<branch>/<build_target>/<build_id>."
    echo "                        If not specified, no system build will be used."
    echo "  -kb <kernel_build>, --kernel-build=<kernel_build>, -gki <gki_build>, --gki-build=<gki_build>"
    echo "                        The kernel build path. Can be a local path or a remote build"
    echo "                        as ab://<branch>/<build_target>/<build_id>."
    echo "                        If not specified, it will use the kernel in the local repo."
    echo "  --acloud-bin=<acloud_bin>"
    echo "                        The alternative alcoud binary path."
    echo "  --cf-product=<product_type>"
    echo "                        The alternative cuttlefish product type for local build."
    echo "                        Will use default ${PRODUCT} if not specified."
    echo "  --acloud-arg=<acloud_arg>"
    echo "                        Additional acloud command arg. Can be repeated."
    echo "                        For example --acloud-arg=--local-instance to launch a local cvd."
    echo "  -h, --help            Display this help message and exit"
    echo ""
    echo "Examples:"
    echo "$0"
    echo "$0 --acloud-arg=--local-instance"
    echo "$0 -pb ab://git_main/${PRODUCT}-trunk_staging-userdebug/latest"
    echo "$0 -pb ~/main/out/target/product/vsoc_x86_64/"
    echo "$0 -kb ~/android-mainline/out/virtual_device_x86_64/"
    echo ""
    exit 0
}

# Logs an error message and exits with the specified code (default 1).
function fail_error() {
    local message="$1"
    local exit_code="${2:-1}"
    # Pass frame offset 2 to log_error to point to the caller of fail_error
    log_error "$message" "$exit_code" 2
    exit "$exit_code"
}

function parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                print_help
                ;;
            --use-rbe)
                USE_RBE=true
                shift
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            -pb)
                shift
                if (( $# > 0 )); then
                    PLATFORM_BUILD="$1"
                else
                    fail_error "platform build is not specified"
                fi
                shift
                ;;
            --platform-build=*)
                PLATFORM_BUILD="$(echo "$1" | sed -e "s/^[^=]*=//g")"
                shift
                ;;
            -gsi)
                shift
                if (( $# > 0 )); then
                    GSI_BUILD="$1"
                else
                    fail_error "system build is not specified"
                fi
                shift
                ;;
            --gsi-build=*)
                GSI_BUILD="$(echo "$1" | sed -e "s/^[^=]*=//g")"
                shift
                ;;
            -sb)
                shift
                if (( $# > 0 )); then
                    GSI_BUILD="$1"
                else
                    fail_error "system build is not specified"
                fi
                shift
                ;;
            --system-build=*)
                GSI_BUILD="$(echo "$1" | sed -e "s/^[^=]*=//g")"
                shift
                ;;
            -gki)
                shift
                if (( $# > 0 )); then
                    KERNEL_BUILD="$1"
                else
                    fail_error "GKI build path is not specified"
                fi
                shift
                ;;
            --gki-build=*)
                KERNEL_BUILD="$(echo "$1" | sed -e "s/^[^=]*=//g")"
                shift
                ;;
            -kb)
                shift
               if (( $# > 0 )); then
                    KERNEL_BUILD="$1"
                else
                    fail_error "kernel build path is not specified"
                fi
                shift
                ;;
            --kernel-build=*)
                KERNEL_BUILD="$(echo "$1" | sed -e "s/^[^=]*=//g")"
                shift
                ;;
            --acloud-arg=*)
                EXTRA_OPTIONS+=("$(echo "$1" | sed -e "s/^[^=]*=//g")") # Use array append syntax
                shift
                ;;
            --acloud-bin=*)
                ACLOUD_BIN="$(echo "$1" | sed -e "s/^[^=]*=//g")"
                shift
                ;;
            --cf-product=*)
                PRODUCT="$(echo "$1" | sed -e "s/^[^=]*=//g")"
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
                fail_error "Unsupported flag: $1" >&2
                ;;
        esac
    done
}

function create_kernel_build_cmd() {
    local cf_kernel_repo_root=$1
    local cf_kernel_version=$2

    local regex="((?<=android-)mainline|(\K\d+\.\d+(?=-stable)))|((?:android)\K\d+)"
    local android_version
    android_version=$(grep -oP "$regex" <(echo "$cf_kernel_version"))
    local build_cmd=""
    if [[ -f "$cf_kernel_repo_root/common-modules/virtual-device/BUILD.bazel" ]]; then
        # support android-mainline, android16, android15, android14, android13
        build_cmd+="tools/bazel run"
        if [[ "$GCOV" == true ]]; then
            build_cmd+=" --gcov"
        fi
        if [[ "$DEBUG" == true ]]; then
            build_cmd+=" --debug"
        fi
        if [[ "$KASAN" == true ]]; then
            build_cmd+=" --kasan"
        fi
        build_cmd+=" //common-modules/virtual-device:virtual_device_x86_64_dist"
    elif [[ -f "$cf_kernel_repo_root/build/build.sh" ]]; then
        if [[ "$android_version" == "12" ]]; then
            build_cmd+="BUILD_CONFIG=common/build.config.gki.x86_64 build/build.sh"
            build_cmd+=" && "
            build_cmd+="BUILD_CONFIG=common-modules/virtual-device/build.config.virtual_device.x86_64 build/build.sh"
        elif [[ "$android_version" == "11" ]] || [[ "$android_version" == "4.19" ]]; then
            build_cmd+="BUILD_CONFIG=common/build.config.gki.x86_64 build/build.sh"
            build_cmd+=" && "
            build_cmd+="BUILD_CONFIG=common-modules/virtual-device/build.config.cuttlefish.x86_64 build/build.sh"
        else
            echo "The Kernel build $cf_kernel_version is not yet supported" >&2
            return 1
        fi
    else
        echo "The Kernel build $cf_kernel_version is not yet supported" >&2
        return 1
    fi

    echo "$build_cmd"
}

function create_kernel_build_path() {
    local cf_kernel_version=$1

    local regex="((?<=android-)mainline|(\K\d+\.\d+(?=-stable)))|((?:android)\K\d+)"
    local android_version
    android_version=$(grep -oP "$regex" <(echo "$cf_kernel_version"))
    if [[ "$android_version" == "mainline" ]] || greater_than_or_equal_to "$android_version" "14"; then
        # support android-mainline, android16, android15, android14
        echo "out/virtual_device_x86_64/dist"
    elif greater_than_or_equal_to "$android_version" "11" || [[ "$android_version" == "4.19" ]]; then
        # support android13, android12, android11, android-4.19-stable
        echo "out/$cf_kernel_version/dist"
    else
        echo "The version of this kernel build $cf_kernel_version is not supported yet" >&2
        return 1
    fi
}

function greater_than_or_equal_to() {
    local num1="$1"
    local num2="$2"

    # This regex matches strings formatted as floating-point or integer numbers
    local num_regex="^[0]([\.][0-9]+)?$|^[1-9][0-9]*([\.][0-9]+)?$"
    if [[ ! "$num1" =~ $num_regex || ! "$num2" =~ $num_regex ]]; then
        log_warn "Invalid numeric input for comparison: '$num1', '$num2'"
        return 1
    fi

    # Use bc for comparison
    if (( $(echo "$num1 >= $num2" | bc -l) == 1 )); then
        return 0
    else
        return 1
    fi
}

function parse_kernel_version() {
    local manifest_output="$1"
    local version=""
    version=$(grep -oP 'common-modules/virtual-device.*revision="\K[^"]*' <(echo "$manifest_output") | head -n 1)

    if [[ "$version" =~ ^[0-9a-f]{40}$ ]]; then
        local fallback_version=$(grep -oP 'kernel/superproject.*revision="\K[^"]*' <(echo "$manifest_output") | head -n 1)
        if [[ -z "$fallback_version" ]]; then
            fallback_version=$(grep -oP 'default revision="(refs/tags/)?\K[^"]*' <(echo "$manifest_output") | head -n 1)
        fi

        if [[ -n "$fallback_version" ]]; then
            version="$fallback_version"
        fi
    fi
    echo "$version"
}

function find_repo() {
    local active_manifest=$(common_lib::get_active_manifest_name "$PWD")
    local manifest_path=".repo/manifests/$active_manifest"
    log_info "Using active manifest: $active_manifest"

    manifest_output=$(grep -e "superproject" -e "common-modules/virtual-device" -e "default revision" \
        "$manifest_path" 2>/dev/null || true)
    case "$manifest_output" in
        *platform/superproject*)
            PLATFORM_REPO_ROOT="$PWD"
            PLATFORM_VERSION=$(grep -oP 'platform/superproject.*revision="\K[^"]*' <(echo "$manifest_output"))
            if [[ -z "$PLATFORM_VERSION" ]]; then
                # on main branch, <superproject> tag doesn't have a 'revision' attribute
                # try to extract the information from <default> tag
                PLATFORM_VERSION=$(grep -oP 'default revision="(refs/tags/)?\K[^"]*' <(echo "$manifest_output"))
            fi
            if [[ -z "$PLATFORM_VERSION" ]]; then
                fail_error "Could not find platform version information."
            fi
            log_info "PLATFORM_REPO_ROOT=$PLATFORM_REPO_ROOT, PLATFORM_VERSION=$PLATFORM_VERSION"
            ;;
        *kernel/superproject*)
            if [[ "$manifest_output" == *common-modules/virtual-device* ]]; then
                CF_KERNEL_REPO_ROOT="$PWD"
                CF_KERNEL_VERSION=$(parse_kernel_version "$manifest_output")
                log_info "CF_KERNEL_REPO_ROOT=$CF_KERNEL_REPO_ROOT, CF_KERNEL_VERSION=$CF_KERNEL_VERSION"
            fi
            ;;
        *)
            log_warn "Unexpected manifest output. Could not determine repository type."
            ;;
    esac
}

# Rebuilds the platform images using 'm'. Assumes environment is already set (lunch).
# WARNING: Uses 'eval'. Consider refactoring if build command becomes complex.
function rebuild_platform() {
    # Conditionally add USE_RBE=false if not enabled via flag
    $USE_RBE || set_env_var "USE_RBE" false
    local build_cmd_parts=("m" "-j$(nproc)") # Use nproc for parallelism
    log_warn "Flag --skip-build is not set. Rebuilding platform images at $PWD"
    log_info "Executing build command: ${BOLD}${build_cmd_parts[*]}${END}"

    # Execute the build command
    run_command "${build_cmd_parts[@]}"
    build_status=$?
    if (( build_status == 0 )); then
        if [[ -f "${ANDROID_PRODUCT_OUT}/system.img" ]]; then
            log_info "Platform build command succeeded."
            return 0
        else
            fail_error "Platform build command succeeded, but required output '${ANDROID_PRODUCT_OUT}/system.img' not found." 1
        fi
    else
        fail_error "Platform build command failed." "$build_status"
    fi
}

# Rebuilds the kernel images. Assumes running in the kernel repo root.
# WARNING: Uses 'eval'. Consider refactoring.
function rebuild_kernel() {
    local kernel_repo_root="$1"
    local kernel_version="$2"

    log_warn "Flag --skip-build is not set. Rebuilding kernel images at $PWD"

    local build_cmd build_status

    # Get the build command string
    if ! build_cmd=$(create_kernel_build_cmd "$kernel_repo_root" "$kernel_version"); then
        fail_error "Failed to determine kernel build command." 1
    fi

    log_info "Executing kernel build command: ${BOLD}${build_cmd}${END}"

    # Execute the build command
    # Using eval here is risky. Refactor if build_cmd structure allows.
    eval "$build_cmd"
    build_status=$?
    if (( build_status == 0 )); then
        log_info "Kernel build command succeeded."
    else
        fail_error "Kernel build command failed" "$build_status"
    fi
}

# --- Main Script Logic ---

# 1. Check Core Dependencies
log_info "Checking required commands..."
if ! check_commands_available "${REQUIRED_COMMANDS[@]}"; then
    fail_error "One or more required commands are missing. Please install them and retry." 1
fi

# 2. Parse Arguments
log_info "Parsing command line arguments..."
parse_args "$@"

# 3. Determine Repo Root and Type
log_info "Determining repository context..."
repository_path="$PWD"
if ! is_in_repo_workspace; then
    log_warn "Current directory '$PWD' is not within an Android repo workspace."
    repository_path="$SCRIPT_DIR"
fi
if ! go_to_repo_root "$repository_path"; then
    fail_error "Failed to navigate to repo root from $PWD." 1
else
    find_repo
fi

# 4. Handle Platform Build/Path
log_info "Processing platform build..."
if [[ -z "$PLATFORM_BUILD" && -n "$PLATFORM_REPO_ROOT" ]]; then
    log_info "Platform build not specified, using detected local platform repo: ${platform_repo_root}"
    PLATFORM_BUILD="$PLATFORM_REPO_ROOT"
fi

if [[ -n "$PLATFORM_BUILD" && "$PLATFORM_BUILD" != ab://* ]]; then
    log_info "Local platform build path specified: ${PLATFORM_BUILD}"
    # Resolve the path
    if ! PLATFORM_BUILD=$(realpath -- "$PLATFORM_BUILD" 2>/dev/null); then
        fail_error "Invalid local platform build path: ${PLATFORM_BUILD}" 1
    fi
    if [[ ! -d "$PLATFORM_BUILD" ]]; then
        fail_error "Local platform build path does not exist or is not a directory: ${PLATFORM_BUILD}" 1
    fi

    cd "$PLATFORM_BUILD" || fail_error "Failed to cd to $PLATFORM_BUILD"

    if is_in_repo_workspace; then
        go_to_repo_root "$PWD"

        # Set up build environment (lunch)
        log_info "Setting up platform build environment for product: $PRODUCT"
        if [[ -z "${TARGET_PRODUCT}" || "${TARGET_PRODUCT}" != "$PRODUCT" ]]; then
            log_info "TARGET_PRODUCT ('${TARGET_PRODUCT:-}') is not set or doesn't match '$PRODUCT'. Running lunch..."
            if ! set_platform_repo "$PRODUCT" "userdebug" "$PWD"; then ## Assumes 'userdebug' variant, might need flexibility?
                fail_error "Failed to set platform build environment (lunch)." 1
            fi
        else
            log_info "Build environment already set for TARGET_PRODUCT=${TARGET_PRODUCT}."
        fi

        if [[ "$SKIP_BUILD" == false ]]; then
            rebuild_platform
        else
            log_info "--skip-build specified, skipping platform rebuild."
        fi
        # After potential build, set platform_build to the actual output directory
        if [[ -n "${ANDROID_PRODUCT_OUT:-}" && -d "${ANDROID_PRODUCT_OUT}" ]]; then
            log_info "Setting platform build path to lunch output: ${ANDROID_PRODUCT_OUT}"
            PLATFORM_BUILD="${ANDROID_PRODUCT_OUT}"
        else
            fail_error "ANDROID_PRODUCT_OUT ('${ANDROID_PRODUCT_OUT:-}') is not set or not a directory after lunch/build attempt." 1
        fi
    else
        if [[ "$SKIP_BUILD" == false ]]; then
            log_warn "Local platform build path provided ('${PLATFORM_BUILD}'). --skip-build was not used, but automatic rebuilding is only done when running from within the platform repo source directory."
        else
            log_info "Current path $PWD is not a valid Android platform repo, please ensure it contains the platform image."
        fi
    fi
fi

# 5. Handle System Build/Path
if [[ "$SKIP_BUILD" == false && -n "$GSI_BUILD" && "$GSI_BUILD" != ab://* && -d "$GSI_BUILD" ]]; then
    # Get GSI build
    cd "$GSI_BUILD" || fail_error "Failed to cd to $GSI_BUILD"
    GSI_REPO_LIST_OUT=$(repo list 2>&1)
    if [[ "$GSI_REPO_LIST_OUT" != "error"* ]]; then
        go_to_repo_root "$PWD"
        if [[ -z "${TARGET_PRODUCT}" || "${TARGET_PRODUCT}" != "${DEFAULT_GSI_PRODUCT}" ]]; then
            log_warn "Build target product '${TARGET_PRODUCT}' does not match expected '${DEFAULT_GSI_PRODUCT}'. Reset build environment."
            set_platform_repo "${DEFAULT_GSI_PRODUCT}"
            rebuild_platform
            GSI_BUILD="${ANDROID_PRODUCT_OUT}/system.img"
        fi
    fi
fi

# 6. Handle Kernel Build/Path
if  [[ -n "$KERNEL_BUILD" && "$KERNEL_BUILD" != ab://* ]]; then
    log_info "Local kernel build path specified: ${KERNEL_BUILD}"
    # Resolve the path
    if ! KERNEL_BUILD=$(realpath -- "$KERNEL_BUILD" 2>/dev/null); then
         fail_error "Invalid local kernel build path: ${KERNEL_BUILD}" 1
    fi
    if [[ ! -d "$KERNEL_BUILD" ]]; then
         fail_error "Local kernel build path does not exist or is not a directory: ${KERNEL_BUILD}" 1
    fi

    log_info "Changing directory to kernel build: ${KERNEL_BUILD}"
    cd -- "$KERNEL_BUILD" || fail_error "Failed to cd into kernel build directory: ${KERNEL_BUILD}" 1

    if is_in_repo_workspace; then
        go_to_repo_root "$PWD"
        target_kernel_repo_root="$PWD"
        target_active_manifest=$(common_lib::get_active_manifest_name "$PWD")
        target_manifest_path=".repo/manifests/$target_active_manifest"
        log_info "Using target active manifest: $target_active_manifest"

        target_manifest_output=$(grep -e "superproject" -e "common-modules/virtual-device" -e "default revision" \
        "$target_manifest_path" 2>/dev/null || true)
        target_cf_kernel_version=$(parse_kernel_version "$target_manifest_output")

        log_info "target_kernel_repo_root=$target_kernel_repo_root, target_cf_kernel_version=$target_cf_kernel_version"

        # Rebuild if not skipped
        if [[ "$SKIP_BUILD" == false ]]; then
            rebuild_kernel "$target_kernel_repo_root" "$target_cf_kernel_version" # Assumes PWD is kernel root
        else
            log_info "--skip-build specified, skipping kernel rebuild."
        fi

        # Determine the expected output path after potential build
        kernel_out_path=""
        if ! kernel_out_path=$(create_kernel_build_path "$target_cf_kernel_version"); then
            fail_error "Failed to determine kernel build output path for version ${cf_kernel_version}." 1
        fi
        full_kernel_path="${target_kernel_repo_root}/${kernel_out_path}"

        # Check if the expected output directory exists
        if [[ -d "$full_kernel_path" ]]; then
            log_info "Setting kernel build path to detected output: ${full_kernel_path}"
            KERNEL_BUILD="$full_kernel_path"
        else
            err_msg="Expected kernel build output directory '${full_kernel_path}' not found."
            if [[ "$SKIP_BUILD" == true ]]; then
                err_msg+="Don't skip re-building the kernel image."
            fi
            fail_error "$err_msg" 1
        fi
    else
        if [[ "$SKIP_BUILD" == false ]]; then
            log_warn "Local kernel build path provided ('${KERNEL_BUILD}'). --skip-build was not used, but automatic rebuilding is only done when running from within the kernel repo source directory."
        else
            log_info  "Current path $PWD is not a valid Android repo, please ensure it contains the kernel image."
        fi
    fi
fi

# 7. Find acloud Binary
if [[ -z "$ACLOUD_BIN" || ! -x "$ACLOUD_BIN" ]]; then
    log_info "Acloud binary path not specified or is not executable(--acloud-bin). Searching..."
    if ACLOUD_BIN=$(which acloud 2>&1); then
        log_info "Use acloud binary from: ${ACLOUD_BIN}"
    else
        # Fallback to prebuilt location relative to a detected repo root
        potential_prebuilt_path=""
        if [[ -n "${PLATFORM_REPO_ROOT}" ]]; then
            potential_prebuilt_path="${PLATFORM_REPO_ROOT}/${ACLOUD_PREBUILT}"
        elif  [[ -n "${CF_KERNEL_REPO_ROOT}" ]]; then
            potential_prebuilt_path="${CF_KERNEL_REPO_ROOT}/${ACLOUD_PREBUILT}"
        fi

        if [[ -n "$potential_prebuilt_path" && -x "$potential_prebuilt_path" ]]; then
            log_info "Using prebuilt acloud from repository: ${potential_prebuilt_path}"
            ACLOUD_BIN="$potential_prebuilt_path"
        else
            fail_error "Could not find 'acloud' in PATH and failed to locate a valid prebuilt acloud in detected repo roots (${platform_repo_root:-none}, ${cf_kernel_repo_root:-none}). Specify path using --acloud-bin."
        fi
    fi
fi


# Final check if the determined/specified acloud binary is executable
if [[ ! -x "$ACLOUD_BIN" ]]; then
    fail_error "Acloud binary found or specified is not executable: ${ACLOUD_BIN}"
fi
log_info "Using acloud binary: ${BOLD}${ACLOUD_BIN}${END}"

acloud_cmd_parts=("$ACLOUD_BIN" "create")
EXTRA_OPTIONS+=("$OPT_SKIP_PRERUNCHECK")

# Add in branch if not specified
# 8. Construct acloud Command Arguments
if [[ -z "$PLATFORM_BUILD" ]]; then
    log_warn "Platform build was not specified, and could not be determined from local repo. Will use the latest git_main build."
    acloud_cmd_parts+=("--branch" "git_main")
elif [[ "$PLATFORM_BUILD" = ab://* ]]; then
    ab_branch="" ab_target="" ab_id=""
    parse_ab_url "$PLATFORM_BUILD" ab_branch ab_target ab_id
    if (( $? != 0 )); then
        fail_error "Platform Build URL $PLATFORM_BUILD parsing failed" 1
    fi
    acloud_cmd_parts+=("--branch" "${ab_branch}")
    acloud_cmd_parts+=("--build-target" "${ab_target}")
    if [[ "${ab_id}" != "latest" ]]; then
        acloud_cmd_parts+=("--build-id" "${ab_id}")
    fi
else
    acloud_cmd_parts+=("--local-image" "$PLATFORM_BUILD")
fi

if [[ -z "$KERNEL_BUILD" ]]; then
    log_warn "Flag --kernel-build is not set, will not launch Cuttlefish with different kernel."
elif [[ "$KERNEL_BUILD" == ab://* ]]; then
    ab_branch="" ab_target="" ab_id=""
    parse_ab_url "$KERNEL_BUILD" ab_branch ab_target ab_id
    if (( $? != 0 )); then
        fail_error "Kernel Build URL $KERNEL_BUILD parsing failed" 1
    fi

    acloud_cmd_parts+=("--kernel-branch" "${ab_branch}")
    acloud_cmd_parts+=("--kernel-build-target" "${ab_target}")
    if [[ "${ab_id}" != "latest" ]]; then
        acloud_cmd_parts+=("--kernel-build-id" "${ab_id}")
    fi
else
    acloud_cmd_parts+=("--local-kernel-image" "$KERNEL_BUILD")
fi

if [[ "$GSI_BUILD" == ab://* ]]; then
    ab_branch="" ab_target="" ab_id=""
    parse_ab_url "$GSI_BUILD" ab_branch ab_target ab_id
    if (( $? != 0 )); then
        fail_error "System Build URL $GSI_BUILD parsing failed" 1
    fi
    acloud_cmd_parts+=("--system-branch" "${ab_branch}")
    acloud_cmd_parts+=("--system-build-target" "${ab_target}")
    if [[ "${ab_id}" != "latest" ]]; then
        acloud_cmd_parts+=("--system-build-id" "${ab_id}")
    fi
elif [[ -n "$GSI_BUILD" ]]; then
    acloud_cmd_parts+=("--local-system-image" "$GSI_BUILD")
fi

# 9. Execute acloud Command
acloud_cmd_parts+=("${EXTRA_OPTIONS[@]}")
log_info "Launch CVD with command: ${acloud_cmd_parts[*]}"
run_command "${acloud_cmd_parts[@]}"
