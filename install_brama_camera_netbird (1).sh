#!/usr/bin/env bash
#
# BRAMA Camera / NetBird installer for Raspberry Pi 5 and Compute Module 5.
#
# First enrollment:
#   sudo ./install_brama_camera_netbird.sh \
#     --management-url https://netbird.example.com \
#     --setup-key 'AAAA-BBBB-CCCC-DDDD'
#
# If neither --setup-key nor --setup-key-file is supplied, the script asks for
# the key without echoing it.
# On an already enrolled peer, the script reuses the existing NetBird identity.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly PROGRAM_NAME="${0##*/}"
readonly DEVICE_PREFIX="camer"
readonly IDENTITY_VERSION="1"
readonly IDENTITY_DIR="/etc/brama-camera"
readonly DEVICE_NAME_FILE="${IDENTITY_DIR}/device-name"
readonly DEVICE_ID_FILE="${IDENTITY_DIR}/device-id"
readonly FINGERPRINT_FILE="${IDENTITY_DIR}/hardware-fingerprint.sha256"
readonly IDENTITY_SOURCE_FILE="${IDENTITY_DIR}/hardware-id-source"
readonly NETBIRD_KEYRING="/usr/share/keyrings/netbird-archive-keyring.gpg"
readonly NETBIRD_REPOSITORY_FILE="/etc/apt/sources.list.d/netbird.list"

MANAGEMENT_URL="${NETBIRD_MANAGEMENT_URL:-}"
SETUP_KEY=""
SETUP_KEY_FILE="${NETBIRD_SETUP_KEY_FILE:-}"
PRINT_NAME_ONLY=0
TEMP_DIR=""

log() {
    printf '[BRAMA Camera] %s\n' "$*"
}

warn() {
    printf '[BRAMA Camera] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[BRAMA Camera] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage:
  sudo ./${PROGRAM_NAME} --management-url URL [--setup-key KEY]
  sudo ./${PROGRAM_NAME} --management-url URL [--setup-key-file FILE]
  ./${PROGRAM_NAME} --print-name

Options:
  --management-url URL  HTTPS URL of your NetBird Management service.
  --setup-key KEY       NetBird setup key passed directly as an argument.
                        Warning: a literal key can remain in shell history.
  --setup-key-file FILE File containing a one-off or reusable NetBird setup key.
                        If both key options are omitted during first enrollment,
                        the key is requested interactively and is never echoed.
  --print-name          Print the generated camera name without changing anything.
  -h, --help            Show this help.

Environment equivalents:
  NETBIRD_MANAGEMENT_URL
  NETBIRD_SETUP_KEY_FILE

Generated name example:
  camer-0ae3bc-d25aa0-0f70ed-bf37bb
EOF
}

cleanup() {
    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        rm -rf -- "${TEMP_DIR}"
    fi
}

trap cleanup EXIT
trap 'die "Failure on line ${LINENO}."' ERR

while (($# > 0)); do
    case "$1" in
        --management-url)
            (($# >= 2)) || die "--management-url requires a value."
            MANAGEMENT_URL="$2"
            shift 2
            ;;
        --setup-key-file)
            (($# >= 2)) || die "--setup-key-file requires a path."
            SETUP_KEY_FILE="$2"
            shift 2
            ;;
        --setup-key)
            (($# >= 2)) || die "--setup-key requires a value."
            SETUP_KEY="$2"
            shift 2
            ;;
        --print-name)
            PRINT_NAME_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1. Use --help."
            ;;
    esac
done

if [[ -n "${SETUP_KEY}" && -n "${SETUP_KEY_FILE}" ]]; then
    die "Use either --setup-key or --setup-key-file, not both."
fi

normalize_hex_id() {
    local value="$1"
    value="${value,,}"
    value="${value//[[:space:]]/}"
    value="${value#0x}"

    if [[ "${value}" =~ ^[0-9a-f]{8,32}$ ]] &&
       [[ ! "${value}" =~ ^0+$ ]] &&
       [[ ! "${value}" =~ ^f+$ ]]; then
        printf '%s' "${value}"
        return 0
    fi

    return 1
}

normalize_decimal_id() {
    local value="$1"
    value="${value//[[:space:]]/}"

    if [[ "${value}" =~ ^[0-9]{8,32}$ ]] && [[ ! "${value}" =~ ^0+$ ]]; then
        printf '%s' "${value}"
        return 0
    fi

    return 1
}

read_device_tree_text() {
    local path="$1"
    [[ -r "${path}" ]] || return 1
    tr -d '\000\r\n[:space:]' < "${path}"
}

get_hardware_identity() {
    local raw=""
    local normalized=""

    # BCM2712 (Raspberry Pi 5 / CM5) exposes its full 64-bit board serial here.
    if raw="$(read_device_tree_text /proc/device-tree/serial-number 2>/dev/null)" &&
       normalized="$(normalize_hex_id "${raw}" 2>/dev/null)"; then
        printf 'rpi-serial:%s\n' "${normalized}"
        return 0
    fi

    # Raspberry Pi OS also exposes the same factory serial in /proc/cpuinfo.
    raw="$(awk -F ':' '/^Serial[[:space:]]*:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    if normalized="$(normalize_hex_id "${raw}" 2>/dev/null)"; then
        printf 'rpi-serial:%s\n' "${normalized}"
        return 0
    fi

    # Pi 5 has a factory DUID matching the barcode on the board.
    if raw="$(read_device_tree_text /proc/device-tree/chosen/rpi-duid 2>/dev/null)" &&
       normalized="$(normalize_decimal_id "${raw}" 2>/dev/null)"; then
        printf 'rpi-duid:%s\n' "${normalized}"
        return 0
    fi

    return 1
}

is_bcm2712_device() {
    local compatible=""
    [[ -r /proc/device-tree/compatible ]] || return 1
    compatible="$(tr '\000' '\n' < /proc/device-tree/compatible 2>/dev/null || true)"
    grep -Fxq 'brcm,bcm2712' <<< "${compatible}"
}

generate_device_identity() {
    local hardware_identity="$1"
    local digest=""
    local compact_id=""
    local device_name=""

    digest="$(printf 'brama-camera|v%s|%s' \
        "${IDENTITY_VERSION}" "${hardware_identity}" | sha256sum | awk '{print $1}')"
    [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || die "Could not calculate SHA-256 fingerprint."

    compact_id="${digest:0:6}-${digest:6:6}-${digest:12:6}-${digest:18:6}"
    device_name="${DEVICE_PREFIX}-${compact_id}"

    printf '%s\n%s\n%s\n' "${device_name}" "${compact_id}" "${digest}"
}

persist_identity() {
    local device_name="$1"
    local compact_id="$2"
    local digest="$3"
    local source_name="${4%%:*}"

    install -d -m 0755 "${IDENTITY_DIR}"
    printf '%s\n' "${device_name}" | install -m 0644 /dev/stdin "${DEVICE_NAME_FILE}"
    printf '%s\n' "${compact_id}" | install -m 0644 /dev/stdin "${DEVICE_ID_FILE}"
    printf '%s\n' "${digest}" | install -m 0644 /dev/stdin "${FINGERPRINT_FILE}"
    printf '%s\n' "${source_name}" | install -m 0644 /dev/stdin "${IDENTITY_SOURCE_FILE}"
}

set_system_hostname() {
    local device_name="$1"
    local hosts_tmp="${TEMP_DIR}/hosts"

    hostnamectl set-hostname "${device_name}"

    if [[ -f /etc/hosts ]]; then
        awk -v hostname="${device_name}" '
            BEGIN { replaced = 0 }
            /^[[:space:]]*127[.]0[.]1[.]1([[:space:]]|$)/ && replaced == 0 {
                print "127.0.1.1\t" hostname
                replaced = 1
                next
            }
            { print }
            END {
                if (replaced == 0) {
                    print "127.0.1.1\t" hostname
                }
            }
        ' /etc/hosts > "${hosts_tmp}"
        chmod --reference=/etc/hosts "${hosts_tmp}" 2>/dev/null || chmod 0644 "${hosts_tmp}"
        chown --reference=/etc/hosts "${hosts_tmp}" 2>/dev/null || chown root:root "${hosts_tmp}"
        cp --preserve=mode,ownership -- "${hosts_tmp}" /etc/hosts
    fi
}

install_netbird() {
    local key_file="${TEMP_DIR}/netbird-public-key"

    if command -v netbird >/dev/null 2>&1; then
        log "NetBird is already installed: $(netbird version 2>/dev/null || printf 'version unknown')"
        return 0
    fi

    log "Installing the NetBird CLI from the official APT repository..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    curl --fail --silent --show-error --location \
        https://pkgs.netbird.io/debian/public.key \
        --output "${key_file}"
    gpg --batch --yes --dearmor --output "${NETBIRD_KEYRING}" "${key_file}"
    chmod 0644 "${NETBIRD_KEYRING}"

    printf '%s\n' \
        'deb [signed-by=/usr/share/keyrings/netbird-archive-keyring.gpg] https://pkgs.netbird.io/debian stable main' \
        > "${NETBIRD_REPOSITORY_FILE}"

    apt-get update
    apt-get install -y netbird
}

netbird_identity_is_usable() {
    command -v netbird >/dev/null 2>&1 || return 1
    systemctl start netbird >/dev/null 2>&1 || return 1
    netbird status --check ready >/dev/null 2>&1
}

make_temporary_setup_key_file() {
    local setup_key=""
    local key_path="${TEMP_DIR}/setup-key"

    if [[ -n "${SETUP_KEY}" ]]; then
        setup_key="${SETUP_KEY}"
    else
        [[ -r /dev/tty && -w /dev/tty ]] ||
            die "First enrollment needs --setup-key or --setup-key-file when no interactive terminal is available."

        printf 'Enter the NetBird setup key (input is hidden): ' > /dev/tty
        IFS= read -r -s setup_key < /dev/tty
        printf '\n' > /dev/tty
    fi

    [[ -n "${setup_key}" ]] || die "The setup key is empty."

    printf '%s\n' "${setup_key}" > "${key_path}"
    chmod 0600 "${key_path}"
    setup_key=""
    SETUP_KEY=""
    SETUP_KEY_FILE="${key_path}"
}

validate_setup_key_file() {
    [[ -f "${SETUP_KEY_FILE}" ]] || die "Setup key file does not exist: ${SETUP_KEY_FILE}"
    [[ -r "${SETUP_KEY_FILE}" ]] || die "Setup key file is not readable: ${SETUP_KEY_FILE}"
    [[ -s "${SETUP_KEY_FILE}" ]] || die "Setup key file is empty: ${SETUP_KEY_FILE}"
}

connect_netbird() {
    local device_name="$1"
    local already_enrolled=0
    local -a command_args=()

    systemctl enable --now netbird

    if netbird_identity_is_usable; then
        already_enrolled=1
        log "An existing NetBird identity was found; no setup key will be reused."
    fi

    command_args=(
        netbird up
        --management-url "${MANAGEMENT_URL}"
        --hostname "${device_name}"
        --no-browser
    )

    if ((already_enrolled == 0)); then
        if [[ -z "${SETUP_KEY_FILE}" ]]; then
            make_temporary_setup_key_file
        fi
        validate_setup_key_file
        command_args+=(--setup-key-file "${SETUP_KEY_FILE}")
    fi

    # NetBird gives NB_* environment variables precedence over CLI flags.
    # Clear only variables that could silently replace this installer's values.
    unset NB_MANAGEMENT_URL NB_HOSTNAME NB_SETUP_KEY NB_SETUP_KEY_FILE

    log "Connecting ${device_name} to NetBird..."
    "${command_args[@]}"

    log "Waiting for NetBird management and signal connectivity..."
    for _ in {1..30}; do
        if netbird status --check startup >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    netbird status >&2 || true
    die "NetBird did not reach startup-ready state within 60 seconds."
}

main() {
    local hardware_identity=""
    local -a identity_fields=()
    local device_name=""
    local compact_id=""
    local digest=""

    command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required."

    if ! hardware_identity="$(get_hardware_identity)"; then
        die "No valid Raspberry Pi factory serial or rpi-duid was found."
    fi

    mapfile -t identity_fields < <(generate_device_identity "${hardware_identity}")
    ((${#identity_fields[@]} == 3)) || die "Internal identity generation error."
    device_name="${identity_fields[0]}"
    compact_id="${identity_fields[1]}"
    digest="${identity_fields[2]}"

    if ((PRINT_NAME_ONLY == 1)); then
        printf '%s\n' "${device_name}"
        exit 0
    fi

    ((EUID == 0)) || die "Run this installer as root: sudo ./${PROGRAM_NAME} ..."

    if ! is_bcm2712_device; then
        die "This installer expects Raspberry Pi 5 or Compute Module 5 (BCM2712)."
    fi

    [[ -r /etc/os-release ]] || die "Could not identify the operating system."
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "debian" && "${ID:-}" != "raspbian" &&
          "${ID:-}" != "ubuntu" && " ${ID_LIKE:-} " != *" debian "* ]]; then
        die "A Debian-based Raspberry Pi OS or Ubuntu installation is required."
    fi

    [[ -n "${MANAGEMENT_URL}" ]] ||
        die "Specify the NetBird Management URL with --management-url."
    MANAGEMENT_URL="${MANAGEMENT_URL%/}"
    [[ "${MANAGEMENT_URL}" =~ ^https://[^[:space:]]+$ ]] ||
        die "The management URL must be a valid HTTPS URL."

    TEMP_DIR="$(mktemp -d /tmp/brama-camera-netbird.XXXXXX)"
    chmod 0700 "${TEMP_DIR}"

    log "Generated device name: ${device_name}"
    persist_identity "${device_name}" "${compact_id}" "${digest}" "${hardware_identity}"
    set_system_hostname "${device_name}"
    install_netbird
    connect_netbird "${device_name}"

    log "Installation completed successfully."
    log "Device name: ${device_name}"
    log "Saved name: ${DEVICE_NAME_FILE}"
    log "NetBird IPv4: $(netbird status --ipv4 2>/dev/null || printf 'not assigned')"
    log "The NetBird service is enabled and will start automatically after reboot."
}

main "$@"
