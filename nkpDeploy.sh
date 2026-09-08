#!/bin/bash

# --- ANSI Color Codes ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- Dependency Check ---
echo -e "${CYAN}Verifying required dependencies...${NC}"
REQUIRED_COMMANDS=("curl" "jq" "tar")
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}ERROR: Required command '$cmd' is not installed.${NC}"
        echo -e "${YELLOW}Install on Rocky Linux with: ${CYAN}sudo yum install -y $cmd${NC}"
        exit 1
    fi
done
echo -e "${GREEN}--> All required dependencies verified.${NC}"

# whiptail is preferred for the TUI.  dialog is also supported, and the
# built-in bash select menu is used as a dependency-free fallback.
TUI_BIN=""
if command -v whiptail &> /dev/null; then
    TUI_BIN="whiptail"
elif command -v dialog &> /dev/null; then
    TUI_BIN="dialog"
fi

if [[ -n "$TUI_BIN" ]]; then
    echo -e "${GREEN}--> TUI detected: ${TUI_BIN}.${NC}"
else
    echo -e "${YELLOW}--> whiptail/dialog not found; using the built-in selectable menus.${NC}"
fi

# --- Defaults file sits next to the script ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS_FILE="${SCRIPT_DIR}/nkpDeploy_defaults.json"

# ============================================================
# HELPER: Inline v4 API call
# Requires PCIPADDRESS, PCADMIN, PCPASSWD to be set before calling.
# ============================================================
call_curl_v4() {
    local REQUEST="$1"   # GET or POST
    local APIURL="$2"    # e.g. /clustermgmt/v4.0/config/clusters
    local CALLDATA="$3"  # JSON body (POST only)
    local URL="https://${PCIPADDRESS}:9440/api"

    case "$REQUEST" in
        GET)
            RESPONSE=$(curl -s -k -w '####%{response_code}' \
                -u "$PCADMIN:$PCPASSWD" \
                --header 'accept: application/json' \
                -H 'X-Nutanix-Client-Type: ui' \
                --request GET \
                --url "${URL}${APIURL}")
            ;;
        POST)
            RESPONSE=$(curl -s -k -w '####%{response_code}' \
                -u "$PCADMIN:$PCPASSWD" \
                --header 'accept: application/json' \
                -H 'X-Nutanix-Client-Type: ui' \
                --request POST \
                --header 'content-type: application/json' \
                --data "${CALLDATA}" \
                --url "${URL}${APIURL}")
            ;;
    esac

    local HTTPSTATUS
    HTTPSTATUS=$(echo "${RESPONSE}" | awk -F '####' '{print $2}' | xargs)
    case "$HTTPSTATUS" in
        2[0-9][0-9])
            echo "${RESPONSE}" | awk -F '####' '{print $1}'
            ;;
        *)
            local ERROR_BODY
            ERROR_BODY=$(echo "${RESPONSE}" | awk -F '####' '{print $1}')
            jq -n \
                --arg httpStatus "${HTTPSTATUS:-000}" \
                --arg apiPath "$APIURL" \
                --arg response "$ERROR_BODY" \
                '{httpStatus: $httpStatus, apiPath: $apiPath, response: $response}'
            ;;
    esac
}

# ============================================================
# HELPER: Load defaults from JSON (returns empty string if key missing)
# ============================================================
get_default() {
    local KEY="$1"
    if [[ -f "$DEFAULTS_FILE" ]]; then
        jq -r --arg k "$KEY" '.[$k] // empty' "$DEFAULTS_FILE" 2>/dev/null
    fi
}

# ============================================================
# HELPER: Save all current inputs to defaults JSON (no password)
# ============================================================
save_defaults() {
    jq -n \
        --arg pc_endpoint     "$PC_ENDPOINT" \
        --arg nutanix_user    "$NUTANIX_USER" \
        --arg cluster_name    "$CLUSTER_NAME" \
        --arg vip             "$VIP" \
        --arg vm_image        "$VM_IMAGE" \
        --arg ahv_cluster     "$AHV_CLUSTER" \
        --arg network         "$NETWORK" \
        --arg storage         "$STORAGE" \
        --arg lb_range        "$LB_RANGE" \
        --arg cp_replicas     "$CP_REPLICAS" \
        --arg worker_replicas "$WORKER_REPLICAS" \
        '{
            pc_endpoint:     $pc_endpoint,
            nutanix_user:    $nutanix_user,
            cluster_name:    $cluster_name,
            vip:             $vip,
            vm_image:        $vm_image,
            ahv_cluster:     $ahv_cluster,
            network:         $network,
            storage:         $storage,
            lb_range:        $lb_range,
            cp_replicas:     $cp_replicas,
            worker_replicas: $worker_replicas
        }' > "$DEFAULTS_FILE"
}

# ============================================================
# HELPER: Prompt with optional default value shown inline
#   get_input "Prompt: " VAR_NAME [mode]
#   mode: "lowercase", "range", or omit for plain text
# ============================================================
get_input() {
    local PROMPT="$1"
    local VAR_NAME="$2"
    local MODE="$3"
    local DEFAULT
    DEFAULT=$(get_default "${VAR_NAME,,}")

    local DISPLAY_PROMPT
    if [[ -n "$DEFAULT" ]]; then
        DISPLAY_PROMPT="${PROMPT%:*} [${DEFAULT}]: "
    else
        DISPLAY_PROMPT="$PROMPT"
    fi

    local TEMP_VAL=""

    while true; do
        read -p "$DISPLAY_PROMPT" TEMP_VAL

        # Accept default if Enter pressed on empty input
        if [[ -z "$TEMP_VAL" && -n "$DEFAULT" ]]; then
            TEMP_VAL="$DEFAULT"
        fi

        if [[ -z "$TEMP_VAL" ]]; then
            echo -e "${RED}Error: This field cannot be empty.${NC}"
            continue
        fi

        if [[ "$MODE" == "lowercase" && "$TEMP_VAL" =~ [A-Z] ]]; then
            echo -e "${RED}Error: Cluster Name must be lowercase only.${NC}"
            continue
        fi

        if [[ "$MODE" == "ip" ]]; then
            if ! validate_ipv4 "$TEMP_VAL"; then
                echo -e "${RED}Error: Enter a valid IPv4 address.${NC}"
                continue
            fi
            if [[ -n "${SUBNET_NETWORK_IP:-}" ]] && ! is_in_same_subnet "$TEMP_VAL" "$SUBNET_NETWORK_IP" "${SUBNET_PREFIX_LENGTH:-24}"; then
                echo -e "${RED}Error: Address must be in the selected network (${SUBNET_NETWORK_IP}/${SUBNET_PREFIX_LENGTH}).${NC}"
                continue
            fi
        fi

        if [[ "$MODE" == "range" ]]; then
            if [[ ! "$TEMP_VAL" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                echo -e "${RED}Error: Format must be x.x.x.x-y.y.y.y${NC}"
                continue
            fi
            local RANGE_START
            RANGE_START=$(echo "$TEMP_VAL" | cut -d'-' -f1)
            if ! validate_ipv4 "$RANGE_START" || ! validate_ipv4 "${TEMP_VAL##*-}"; then
                echo -e "${RED}Error: Enter valid IPv4 addresses in the range.${NC}"
                continue
            fi
            if ! is_in_same_subnet "$VIP" "$RANGE_START" "${SUBNET_PREFIX_LENGTH:-24}"; then
                echo -e "${RED}Error: LB Range must be in the same subnet as VIP ($VIP).${NC}"
                continue
            fi
        fi

        eval "$VAR_NAME=\"$TEMP_VAL\""
        break
    done
}

# ============================================================
# TUI HELPERS
# ============================================================
# These helpers keep the script usable over SSH and on hosts without
# whiptail/dialog.  REPLY is intentionally global so callers can use the
# same helper for both TUI and plain terminal input.
prompt_text() {
    local LABEL="$1"
    local DEFAULT_VALUE="$2"
    local VAR_NAME="$3"
    local MODE="$4"

    if [[ -n "$TUI_BIN" ]]; then
        if [[ "$TUI_BIN" == "whiptail" ]]; then
            REPLY=$(whiptail --title "NKP Deployment" --inputbox "$LABEL" 10 78 "$DEFAULT_VALUE" 3>&1 1>&2 2>&3) || exit 0
        else
            REPLY=$(dialog --stdout --title "NKP Deployment" --inputbox "$LABEL" 10 78 "$DEFAULT_VALUE") || exit 0
        fi
    else
        get_input "${LABEL}: " "$VAR_NAME" "$MODE"
        REPLY="${!VAR_NAME}"
    fi
}

prompt_password() {
    local LABEL="$1"
    if [[ -n "$TUI_BIN" ]]; then
        if [[ "$TUI_BIN" == "whiptail" ]]; then
            REPLY=$(whiptail --title "NKP Deployment" --passwordbox "$LABEL" 10 78 3>&1 1>&2 2>&3) || exit 0
        else
            REPLY=$(dialog --stdout --title "NKP Deployment" --passwordbox "$LABEL" 10 78) || exit 0
        fi
    else
        while [[ -z "$REPLY" ]]; do
            echo -ne "${YELLOW}${LABEL}: ${NC}"
            read -rs REPLY
            echo ""
        done
    fi
}

modern_select() {
    local LABEL="$1"
    shift
    local OPTIONS=("$@")
    local CURRENT=0 OFFSET=0 KEY KEY2
    local VISIBLE=12
    local OLD_STTY

    [[ ${#OPTIONS[@]} -gt 0 ]] || return 1
    [[ -c /dev/tty ]] || return 1

    OLD_STTY=$(stty -g < /dev/tty) || return 1
    stty -echo -icanon min 1 time 0 < /dev/tty || return 1

    while true; do
        printf '\033[2J\033[H' >&2
        printf '\033[1;35m  NKP DEPLOYMENT\033[0m\n' >&2
        printf '\033[38;5;141m  %s\033[0m\n\n' "$LABEL" >&2

        (( CURRENT < OFFSET )) && OFFSET=$CURRENT
        (( CURRENT >= OFFSET + VISIBLE )) && OFFSET=$((CURRENT - VISIBLE + 1))
        local END=$((OFFSET + VISIBLE))
        (( END > ${#OPTIONS[@]} )) && END=${#OPTIONS[@]}

        local INDEX
        for ((INDEX=OFFSET; INDEX<END; INDEX++)); do
            if (( INDEX == CURRENT )); then
                printf '\033[48;5;99m\033[97m  > %-96s\033[0m\n' "${OPTIONS[$INDEX]}" >&2
            else
                printf '    %s\n' "${OPTIONS[$INDEX]}" >&2
            fi
        done
        printf '\n\033[38;5;141m  %d/%d\033[0m   ↑/↓ navigate   Enter select   q quit\n' \
            "$((CURRENT + 1))" "${#OPTIONS[@]}" >&2

        IFS= read -r -s -n 1 -u 3 KEY < /dev/tty
        case "$KEY" in
            $'\x1b')
                IFS= read -r -s -n 2 -u 3 -t 0.1 KEY2 < /dev/tty || true
                case "${KEY}${KEY2}" in
                    $'\x1b[A') (( CURRENT > 0 )) && CURRENT=$((CURRENT - 1)) ;;
                    $'\x1b[B') (( CURRENT < ${#OPTIONS[@]} - 1 )) && CURRENT=$((CURRENT + 1)) ;;
                esac
                ;;
            $'\n'|$'\r')
                stty "$OLD_STTY" < /dev/tty
                printf '%s' "$((CURRENT + 1))"
                return 0
                ;;
            q|Q)
                stty "$OLD_STTY" < /dev/tty
                return 1
                ;;
        esac
    done
}

select_option() {
    local LABEL="$1"
    shift
    local OPTIONS=("$@")

    if [[ ${#OPTIONS[@]} -eq 0 ]]; then
        echo -e "${RED}ERROR: No options were returned for ${LABEL}.${NC}" >&2
        return 1
    fi

    # The modern picker is dependency-free and works well over SSH.  The
    # input/password helpers still use whiptail when available.
    exec 3<> /dev/tty
    modern_select "$LABEL" "${OPTIONS[@]}"
    local RESULT=$?
    exec 3>&-
    return "$RESULT"
}

show_message() {
    local MESSAGE="$1"
    if [[ -n "$TUI_BIN" ]]; then
        if [[ "$TUI_BIN" == "whiptail" ]]; then
            whiptail --title "NKP Deployment" --msgbox "$MESSAGE" 12 90
        else
            dialog --title "NKP Deployment" --msgbox "$MESSAGE" 12 90
        fi
    else
        echo -e "${MESSAGE}"
        read -r -p "Press Enter to continue..." _
    fi
}

# ============================================================
# HELPER: subnet check
# ============================================================
is_in_same_subnet() {
    local ip1=$1
    local ip2=$2
    local prefix="${3:-${SUBNET_PREFIX_LENGTH:-24}}"

    if ! validate_ipv4 "$ip1" || ! validate_ipv4 "$ip2"; then
        return 1
    fi

    local value1 value2 mask
    value1=$(ip2int "$ip1")
    value2=$(ip2int "$ip2")
    if (( prefix == 0 )); then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
    (( (value1 & mask) == (value2 & mask) ))
}

validate_ipv4() {
    local IP="$1"
    local OCTET
    local COUNT=0
    IFS='.' read -r -a OCTETS <<< "$IP"
    [[ ${#OCTETS[@]} -eq 4 ]] || return 1
    for OCTET in "${OCTETS[@]}"; do
        [[ "$OCTET" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$OCTET <= 255 )) || return 1
        COUNT=$((COUNT + 1))
    done
    (( COUNT == 4 ))
}

# ============================================================
# HELPER: version comparison
# ============================================================
version_gt() { test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"; }

# ============================================================
# HELPER: ip2int (kept for potential future use)
# ============================================================
ip2int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    echo "$(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))"
}

# Return a usable input prefix for the selected network.  For a /24 this is
# the requested first-three-octets UX; for other masks the network address is
# used as a safe starting point and the full CIDR is shown to the user.
network_input_prefix() {
    local IP="$1"
    local PREFIX="$2"
    local A B C D
    IFS=. read -r A B C D <<< "$IP"
    if (( PREFIX >= 24 )); then
        echo "${A}.${B}.${C}."
    else
        echo "${IP}"
    fi
}

api_failed() {
    local BODY="$1"
    local STATUS
    STATUS=$(echo "$BODY" | jq -r '.httpStatus // empty' 2>/dev/null)
    [[ -n "$STATUS" && "$STATUS" != "null" ]]
}

api_error_message() {
    local BODY="$1"
    local STATUS API_PATH DETAIL
    STATUS=$(echo "$BODY" | jq -r '.httpStatus // "unknown"' 2>/dev/null)
    API_PATH=$(echo "$BODY" | jq -r '.apiPath // empty' 2>/dev/null)
    DETAIL=$(echo "$BODY" | jq -r '
        (.message // .error // .response // (.metadata.messages[0].message // empty))
        | if type == "string" then . else tostring end
    ' 2>/dev/null | tr '\n' ' ' | cut -c1-360)
    [[ -z "$DETAIL" ]] && DETAIL="No response body was returned."
    printf 'Prism Central API request failed (HTTP %s).\n\nEndpoint: %s\n\n%s' "$STATUS" "${API_PATH:-unknown}" "$DETAIL"
}

# ============================================================
# HELPER: Validate VM image against PC — called from summary loop
# Sets VM_IMAGE_VALID=true/false
# ============================================================
validate_vm_image() {
    local IMAGE_NAME="$1"
    local RESULTS
    RESULTS=$(call_curl_v4 "GET" "/vmm/v4.0/content/images?\$filter=contains(name,'${IMAGE_NAME}')")
    local EXACT_MATCH
    EXACT_MATCH=$(echo "$RESULTS" | jq -r --arg NAME "$IMAGE_NAME" '.data[]? | select(.name == $NAME) | .name' 2>/dev/null)

    if [[ -n "$EXACT_MATCH" ]]; then
        VM_IMAGE_VALID=true
        return
    fi

    VM_IMAGE_VALID=false
    local FUZZY_LIST
    FUZZY_LIST=$(echo "$RESULTS" | jq -r '.data[]?.name' 2>/dev/null)

    echo ""
    echo -e "${RED}  Image '${IMAGE_NAME}' not found on Prism Central.${NC}"

    if [[ -n "$FUZZY_LIST" ]]; then
        echo -e "${YELLOW}  Similar images found:${NC}"
        while IFS= read -r IMG; do
            echo -e "    ${CYAN}${IMG}${NC}"
        done <<< "$FUZZY_LIST"
    else
        echo -e "${YELLOW}  No similar images found. Fetching full image list...${NC}"
        local ALL_RESULTS
        ALL_RESULTS=$(call_curl_v4 "GET" "/vmm/v4.0/content/images")
        local ALL_IMAGES
        ALL_IMAGES=$(echo "$ALL_RESULTS" | jq -r '.data[]?.name' 2>/dev/null)
        if [[ -n "$ALL_IMAGES" ]]; then
            while IFS= read -r IMG; do
                echo -e "    ${CYAN}${IMG}${NC}"
            done <<< "$ALL_IMAGES"
        else
            echo -e "${RED}  Could not retrieve image list from Prism Central.${NC}"
        fi
    fi
    echo ""
}

# ============================================================
# PREFLIGHT 1: CONTAINER RUNTIME & CGROUP DELEGATION
# ============================================================
echo -e "${CYAN}Performing Pre-flight checks...${NC}"
echo -e "${CYAN}Checking container runtime and cgroup configuration...${NC}"

CONTAINER_RUNTIME="unknown"
if command -v podman &> /dev/null; then
    CONTAINER_RUNTIME="podman"
    echo -e "${GREEN}--> Podman detected.${NC}"
elif command -v docker &> /dev/null; then
    CONTAINER_RUNTIME="docker"
    echo -e "${GREEN}--> Docker detected (no cgroup delegation needed for Docker daemon).${NC}"
else
    echo -e "${YELLOW}WARNING: No container runtime (podman or docker) detected.${NC}"
    echo -e "${YELLOW}NKP requires podman or docker to be installed.${NC}"
fi

# Cgroup delegation is only needed for podman
if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    GLOBAL_DELEGATE_DIR="/etc/systemd/system/user@.service.d"
    GLOBAL_DELEGATE_CONF="$GLOBAL_DELEGATE_DIR/delegate.conf"

    if [[ ! -f "$GLOBAL_DELEGATE_CONF" ]]; then
        echo -e "${YELLOW}--> Podman detected: cgroup v2 delegation missing. Applying fix...${NC}"
        sudo mkdir -p "$GLOBAL_DELEGATE_DIR"
        echo -e "[Service]\nDelegate=yes" | sudo tee "$GLOBAL_DELEGATE_CONF" > /dev/null
        sudo systemctl daemon-reload
        echo -e "${RED}=======================================================${NC}"
        echo -e "${RED}SYSTEM CHANGE APPLIED: REBOOT REQUIRED${NC}"
        echo -e "${YELLOW}The kernel requires a reboot to delegate cgroup control.${NC}"
        echo -e "Please run: ${CYAN}sudo reboot${NC}"
        echo -e "${RED}=======================================================${NC}"
        exit 1
    fi

    if ! systemctl show "user@$(id -u).service" --property=Delegate | grep -q "Delegate=yes"; then
        echo -e "${RED}=======================================================${NC}"
        echo -e "${RED}ERROR: Cgroup delegation is configured but NOT ACTIVE.${NC}"
        echo -e "${YELLOW}A reboot is required to activate these kernel permissions.${NC}"
        echo -e "Please run: ${CYAN}sudo reboot${NC}"
        echo -e "${RED}=======================================================${NC}"
        exit 1
    fi
    echo -e "${GREEN}--> Podman cgroup delegation verified and ACTIVE.${NC}"
elif [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
    echo -e "${GREEN}--> Docker daemon detected (cgroup delegation not required).${NC}"
fi

# ============================================================
# PREFLIGHT 2: NETWORK CONNECTIVITY CHECK
# ============================================================
echo -e "${YELLOW}Checking outbound connectivity to Nutanix portal...${NC}"
if ! curl -s --connect-timeout 5 --max-time 10 https://portal.nutanix.com >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot reach Nutanix portal (https://portal.nutanix.com).${NC}"
    echo -e "${YELLOW}Troubleshooting steps:${NC}"
    echo -e "  1. Verify your internet connection"
    echo -e "  2. Check if a proxy is required: ${CYAN}curl -v https://portal.nutanix.com${NC}"
    echo -e "  3. Verify firewall rules allow HTTPS traffic"
    echo -e "  4. Test DNS resolution: ${CYAN}nslookup portal.nutanix.com${NC}"
    exit 1
fi
echo -e "${GREEN}--> Outbound connectivity verified.${NC}"

# ============================================================
# PREFLIGHT 3: FIND OR DOWNLOAD BUNDLE
# ============================================================
# Check for airgap bundle mistakenly placed in the directory
if ls nkp-air-gapped-bundle_v*.tar.gz &>/dev/null; then
    echo -e "${RED}ERROR: Found an NKP Air-Gapped Bundle in the current directory.${NC}"
    echo -e "${YELLOW}This script requires the standard NKP Bundle, not the Air-Gapped Bundle.${NC}"
    echo -e "  ${RED}Wrong:${NC}  nkp-air-gapped-bundle_v*.tar.gz"
    echo -e "  ${GREEN}Correct:${NC} nkp-bundle_v*.tar.gz"
    echo -e "${YELLOW}Please download the correct bundle from:${NC}"
    echo -e "  https://portal.nutanix.com/page/downloads?product=nkp"
    exit 1
fi

# Try to find extracted directory first (populated on rerun)
BUNDLE_DIR=$(ls -d nkp-bundle_v*/ 2>/dev/null | head -n1 | tr -d '/')
if [[ -n "$BUNDLE_DIR" ]]; then
    BUNDLE_FILE="${BUNDLE_DIR}.tar.gz"
else
    # Fall back to looking for tarball
    BUNDLE_FILE=$(ls nkp-bundle_v*.tar.gz 2>/dev/null | head -n1)
fi

if [[ -z "$BUNDLE_FILE" ]]; then
    echo -e "${YELLOW}NKP Bundle not found in current directory.${NC}"
    echo -e "${YELLOW}Open browser to: ${NC}"
    echo -e "${YELLOW}https://portal.nutanix.com/page/downloads?product=nkp${NC}"
    echo -e "${YELLOW}Find and download the standard ${GREEN}NKP Bundle${YELLOW} (NOT the Air-Gapped Bundle).${NC}"
    while true; do
        echo -ne "${CYAN}Please paste the full Nutanix Download URL: ${NC}"
        read -r RAW_URL
        [[ -z "$RAW_URL" ]] && exit 1
        BUNDLE_FILE=$(basename "${RAW_URL%%\?*}")
        if [[ "$BUNDLE_FILE" == *"air-gapped"* ]]; then
            echo -e "${RED}ERROR: That URL points to the Air-Gapped Bundle.${NC}"
            echo -e "${YELLOW}Please go back to the portal and copy the URL for the standard NKP Bundle.${NC}"
            echo -e "  ${RED}Wrong:${NC}  nkp-air-gapped-bundle_v*.tar.gz"
            echo -e "  ${GREEN}Correct:${NC} nkp-bundle_v*.tar.gz"
            BUNDLE_FILE=""
            continue
        fi
        curl -kL -o "$BUNDLE_FILE" "$RAW_URL"
        break
    done
fi

# ============================================================
# PREFLIGHT 4: VERSION & EXTRACTION
# ============================================================
VERSION_WITH_V=$(echo "$BUNDLE_FILE" | sed -E 's/.*bundle_(v[0-9]+\.[0-9]+\.[0-9]+).*/\1/')
TARGET_DIR="${BUNDLE_FILE%.tar.gz}"

if [[ ! -d "$TARGET_DIR" ]]; then
    echo -e "${CYAN}Extracting $BUNDLE_FILE into ./$TARGET_DIR...${NC}"
    mkdir -p "$TARGET_DIR"
    tar -xzvpf "$BUNDLE_FILE" -C "$TARGET_DIR" --strip-components=1

    # Validate expected structure exists
    if [[ ! -f "$TARGET_DIR/cli/nkp" ]] || [[ ! -f "$TARGET_DIR/kubectl" ]]; then
        echo -e "${RED}ERROR: Expected binaries not found in extracted bundle.${NC}"
        echo -e "${YELLOW}Bundle structure may be different than expected.${NC}"
        echo -e "Contents of extracted directory:${NC}"
        find "$TARGET_DIR" -type f \( -name "nkp" -o -name "kubectl" \) 2>/dev/null | sed 's/^/  /' || echo "  (no matching files found)"
        exit 1
    fi
    echo -e "${CYAN}Removing tarball $BUNDLE_FILE...${NC}"
    rm -f "$BUNDLE_FILE"
fi

# ============================================================
# PREFLIGHT 5: INSTALL BINARIES TO /usr/local/bin
# ============================================================
echo -e "${CYAN}Installing nkp and kubectl to /usr/local/bin...${NC}"

if sudo cp "./$TARGET_DIR/cli/nkp" /usr/local/bin/nkp && \
   sudo cp "./$TARGET_DIR/kubectl" /usr/local/bin/kubectl && \
   sudo chmod 755 /usr/local/bin/nkp /usr/local/bin/kubectl; then
    if [[ -x "/usr/local/bin/nkp" ]] && [[ -x "/usr/local/bin/kubectl" ]]; then
        echo -e "${GREEN}--> Binaries installed successfully.${NC}"
    else
        echo -e "${RED}Error: Files copied but permission check failed.${NC}"
        exit 1
    fi
else
    echo -e "${RED}Error: Failed to install binaries. Check sudo permissions or source paths.${NC}"
    exit 1
fi

# Define Bundle Paths
KOMMANDER_BUNDLE="./$TARGET_DIR/container-images/kommander-image-bundle-${VERSION_WITH_V}.tar"
KONVOY_BUNDLE="./$TARGET_DIR/container-images/konvoy-image-bundle-${VERSION_WITH_V}.tar"
BUNDLE_FLAGS="--bundle ${KOMMANDER_BUNDLE},${KONVOY_BUNDLE}"

# Resolve bootstrap image path using the same VERSION_WITH_V regex-derived value
BOOTSTRAP_IMAGE="./$TARGET_DIR/konvoy-bootstrap-image-${VERSION_WITH_V}.tar"

# ============================================================
# USER INPUTS
# ============================================================
echo -e "${YELLOW}=======================================================${NC}"
echo -e "${CYAN}      NKP Version Detected: ${GREEN}${VERSION_WITH_V}${NC}"
if [[ -f "$DEFAULTS_FILE" ]]; then
    echo -e "${CYAN}      Defaults loaded from: ${GREEN}${DEFAULTS_FILE}${NC}"
fi
echo -e "${YELLOW}=======================================================${NC}"

PC_ENDPOINT_DEFAULT=$(get_default "pc_endpoint")
while true; do
    prompt_text "Prism Central Endpoint (IPv4 address)" "$PC_ENDPOINT_DEFAULT" PC_ENDPOINT ip
    PC_ENDPOINT="$REPLY"
    if validate_ipv4 "$PC_ENDPOINT"; then
        break
    fi
    show_message "Enter a valid Prism Central IPv4 address."
    PC_ENDPOINT_DEFAULT=""
done

NUTANIX_USER_DEFAULT=$(get_default "nutanix_user")
while true; do
    prompt_text "Prism Username" "$NUTANIX_USER_DEFAULT" NUTANIX_USER
    NUTANIX_USER="$REPLY"
    if [[ -n "$NUTANIX_USER" ]]; then
        break
    fi
    show_message "Prism username cannot be empty."
    NUTANIX_USER_DEFAULT=""
done

# Password — never stored, no default shown.
NUTANIX_PASSWORD=""
prompt_password "Prism Password"
NUTANIX_PASSWORD="$REPLY"

# Set v4 API credentials immediately so the remaining fields can be selected
# from Prism Central rather than typed by hand.
PCIPADDRESS="$PC_ENDPOINT"
PCADMIN="$NUTANIX_USER"
PCPASSWD="$NUTANIX_PASSWORD"

echo -e "${CYAN}Loading AHV clusters from Prism Central...${NC}"
AHV_CLUSTER_RESPONSE=$(call_curl_v4 "GET" "/clustermgmt/v4.0/config/clusters?\$limit=100")
if api_failed "$AHV_CLUSTER_RESPONSE"; then
    show_message "$(api_error_message "$AHV_CLUSTER_RESPONSE")"
    exit 1
fi

CLUSTER_NAMES=()
CLUSTER_IDS=()
while IFS=$'\t' read -r CLUSTER_NAME_ITEM CLUSTER_ID_ITEM; do
    [[ -z "$CLUSTER_NAME_ITEM" ]] && continue
    CLUSTER_NAMES+=("$CLUSTER_NAME_ITEM")
    CLUSTER_IDS+=("$CLUSTER_ID_ITEM")
done < <(echo "$AHV_CLUSTER_RESPONSE" | jq -r '
    .data[]?
    | select(((.config.clusterFunction // []) | index("PRISM_CENTRAL")) == null)
    | [(.name // ""), (.extId // "")]
    | @tsv' 2>/dev/null)

if [[ ${#CLUSTER_NAMES[@]} -eq 0 ]]; then
    show_message "No AHV clusters were returned by Prism Central.\n\nConfirm that the target AHV cluster is registered with this Prism Central and that the account can view it."
    exit 1
fi

SELECTED_INDEX=$(select_option "Select the AHV Cluster for the NKP nodes" "${CLUSTER_NAMES[@]}") || exit 1
AHV_CLUSTER="${CLUSTER_NAMES[$((SELECTED_INDEX - 1))]}"
AHV_CLUSTER_EXT_ID="${CLUSTER_IDS[$((SELECTED_INDEX - 1))]}"

echo -e "${CYAN}Loading networks for ${AHV_CLUSTER}...${NC}"
NETWORK_RESPONSE=$(call_curl_v4 "GET" "/networking/v4.0.a1/config/subnets?\$limit=100")
if api_failed "$NETWORK_RESPONSE"; then
    # A few PC releases expose the same collection under the stable v4
    # namespace instead of the v4.0.a1 preview namespace.
    NETWORK_RESPONSE=$(call_curl_v4 "GET" "/networking/v4.0/config/subnets?\$limit=100")
fi
if api_failed "$NETWORK_RESPONSE"; then
    show_message "$(api_error_message "$NETWORK_RESPONSE")"
    exit 1
fi

NETWORK_NAMES_ALL=()
NETWORK_CIDRS_ALL=()
NETWORK_NAMES_MATCHED=()
NETWORK_CIDRS_MATCHED=()
while IFS=$'\t' read -r NETWORK_NAME_ITEM NETWORK_CLUSTER_ID_ITEM NETWORK_IP_ITEM NETWORK_PREFIX_ITEM NETWORK_TYPE_ITEM; do
    [[ -z "$NETWORK_NAME_ITEM" || -z "$NETWORK_IP_ITEM" || -z "$NETWORK_PREFIX_ITEM" ]] && continue
    [[ ! "$NETWORK_PREFIX_ITEM" =~ ^[0-9]+$ || "$NETWORK_PREFIX_ITEM" -gt 32 ]] && continue
    NETWORK_NAMES_ALL+=("$NETWORK_NAME_ITEM")
    NETWORK_CIDRS_ALL+=("${NETWORK_IP_ITEM}/${NETWORK_PREFIX_ITEM}")
    if [[ -n "$AHV_CLUSTER_EXT_ID" && "$NETWORK_CLUSTER_ID_ITEM" == "$AHV_CLUSTER_EXT_ID" ]]; then
        NETWORK_NAMES_MATCHED+=("$NETWORK_NAME_ITEM")
        NETWORK_CIDRS_MATCHED+=("${NETWORK_IP_ITEM}/${NETWORK_PREFIX_ITEM}")
    fi
done < <(echo "$NETWORK_RESPONSE" | jq -r '
    .data[]?
    | [
        (.name // ""),
        (if (.clusterReference | type) == "object" then (.clusterReference.extId // "") else (.clusterReference // "") end),
        (.ipConfig[0].ipv4.ipSubnet.ip.value // ""),
        (.ipConfig[0].ipv4.ipSubnet.prefixLength // ""),
        (.subnetType // "")
      ]
    | @tsv' 2>/dev/null)

# Some PC versions omit clusterReference from the list response. If there
# were no exact matches, retain all usable subnets and let the user choose.
if [[ ${#NETWORK_NAMES_MATCHED[@]} -gt 0 ]]; then
    NETWORK_NAMES=("${NETWORK_NAMES_MATCHED[@]}")
    NETWORK_CIDRS=("${NETWORK_CIDRS_MATCHED[@]}")
else
    NETWORK_NAMES=("${NETWORK_NAMES_ALL[@]}")
    NETWORK_CIDRS=("${NETWORK_CIDRS_ALL[@]}")
fi

if [[ ${#NETWORK_NAMES[@]} -eq 0 ]]; then
    show_message "No usable IPv4 AHV networks were returned by Prism Central.\n\nThe selected network must expose an IPv4 subnet and prefix length through the Networking v4 API."
    exit 1
fi

NETWORK_LABELS=()
for ((INDEX=0; INDEX<${#NETWORK_NAMES[@]}; INDEX++)); do
    NETWORK_LABELS+=("${NETWORK_NAMES[$INDEX]} [${NETWORK_CIDRS[$INDEX]}]")
done
SELECTED_INDEX=$(select_option "Select the AHV Network / subnet" "${NETWORK_LABELS[@]}") || exit 1
NETWORK_INDEX=$((SELECTED_INDEX - 1))
NETWORK="${NETWORK_NAMES[$NETWORK_INDEX]}"
SUBNET_CIDR="${NETWORK_CIDRS[$NETWORK_INDEX]}"
SUBNET_NETWORK_IP="${SUBNET_CIDR%/*}"
SUBNET_PREFIX_LENGTH="${SUBNET_CIDR##*/}"
SUBNET_INPUT_PREFIX=$(network_input_prefix "$SUBNET_NETWORK_IP" "$SUBNET_PREFIX_LENGTH")

echo -e "${CYAN}Loading storage containers from Prism Central...${NC}"
STORAGE_RESPONSE=$(call_curl_v4 "GET" "/clustermgmt/v4.0/config/storage-containers?\$limit=100")
if api_failed "$STORAGE_RESPONSE"; then
    STORAGE_RESPONSE=$(call_curl_v4 "GET" "/clustermgmt/v4.2/config/storage-containers?\$limit=100")
fi
if api_failed "$STORAGE_RESPONSE"; then
    show_message "$(api_error_message "$STORAGE_RESPONSE")"
    exit 1
fi

STORAGE_NAMES=()
while IFS= read -r STORAGE_NAME_ITEM; do
    [[ -z "$STORAGE_NAME_ITEM" ]] && continue
    STORAGE_NAMES+=("$STORAGE_NAME_ITEM")
done < <(echo "$STORAGE_RESPONSE" | jq -r '.data[]?.name // empty' 2>/dev/null | sort -fu)
if [[ ${#STORAGE_NAMES[@]} -eq 0 ]]; then
    show_message "No storage containers were returned by Prism Central."
    exit 1
fi
SELECTED_INDEX=$(select_option "Select the storage container for persistent volumes" "${STORAGE_NAMES[@]}") || exit 1
STORAGE="${STORAGE_NAMES[$((SELECTED_INDEX - 1))]}"

echo -e "${CYAN}Loading VM images from Prism Central...${NC}"
IMAGE_RESPONSE=$(call_curl_v4 "GET" "/vmm/v4.0/content/images?\$limit=100")
if api_failed "$IMAGE_RESPONSE"; then
    show_message "$(api_error_message "$IMAGE_RESPONSE")"
    exit 1
fi

IMAGE_NAMES=()
while IFS= read -r IMAGE_NAME_ITEM; do
    [[ -z "$IMAGE_NAME_ITEM" ]] && continue
    IMAGE_NAMES+=("$IMAGE_NAME_ITEM")
done < <(echo "$IMAGE_RESPONSE" | jq -r '.data[]?.name // empty' 2>/dev/null | sort -fu)
if [[ ${#IMAGE_NAMES[@]} -eq 0 ]]; then
    show_message "No VM images were returned by Prism Central.\n\nUpload the NKP node image to Prism Central before starting the deployment."
    exit 1
fi
SELECTED_INDEX=$(select_option "Select the VM image for NKP nodes" "${IMAGE_NAMES[@]}") || exit 1
VM_IMAGE="${IMAGE_NAMES[$((SELECTED_INDEX - 1))]}"

CLUSTER_NAME_DEFAULT=$(get_default "cluster_name")
while true; do
    prompt_text "NKP Cluster Name (lowercase only)" "$CLUSTER_NAME_DEFAULT" CLUSTER_NAME lowercase
    CLUSTER_NAME="$REPLY"
    if [[ -n "$CLUSTER_NAME" && ! "$CLUSTER_NAME" =~ [A-Z] ]]; then
        break
    fi
    show_message "Cluster name cannot be empty and must contain lowercase characters only."
    CLUSTER_NAME_DEFAULT=""
done

VIP_DEFAULT=$(get_default "vip")
if [[ -z "$VIP_DEFAULT" ]] || ! validate_ipv4 "$VIP_DEFAULT" || ! is_in_same_subnet "$VIP_DEFAULT" "$SUBNET_NETWORK_IP" "$SUBNET_PREFIX_LENGTH"; then
    VIP_DEFAULT="$SUBNET_INPUT_PREFIX"
fi
while true; do
    prompt_text "Control Plane VIP (network ${SUBNET_CIDR})" "$VIP_DEFAULT" VIP ip
    VIP="$REPLY"
    if validate_ipv4 "$VIP" && is_in_same_subnet "$VIP" "$SUBNET_NETWORK_IP" "$SUBNET_PREFIX_LENGTH"; then
        break
    fi
    show_message "The Control Plane VIP must be a valid address inside ${SUBNET_CIDR}."
    VIP_DEFAULT="$SUBNET_INPUT_PREFIX"
done

LB_SAVED=$(get_default "lb_range")
LB_START_DEFAULT="${LB_SAVED%%-*}"
LB_END_DEFAULT="${LB_SAVED##*-}"
if [[ -z "$LB_SAVED" || "$LB_SAVED" == "$LB_START_DEFAULT" ]]; then
    LB_START_DEFAULT="${SUBNET_INPUT_PREFIX}100"
    LB_END_DEFAULT="${SUBNET_INPUT_PREFIX}110"
fi
while true; do
    prompt_text "Load Balancer range start IP (network ${SUBNET_CIDR})" "$LB_START_DEFAULT" LB_START ip
    LB_START="$REPLY"
    prompt_text "Load Balancer range end IP (network ${SUBNET_CIDR})" "$LB_END_DEFAULT" LB_END ip
    LB_END="$REPLY"
    if validate_ipv4 "$LB_START" && validate_ipv4 "$LB_END" && \
       is_in_same_subnet "$LB_START" "$SUBNET_NETWORK_IP" "$SUBNET_PREFIX_LENGTH" && \
       is_in_same_subnet "$LB_END" "$SUBNET_NETWORK_IP" "$SUBNET_PREFIX_LENGTH" && \
       (( $(ip2int "$LB_START") <= $(ip2int "$LB_END") )); then
        LB_RANGE="${LB_START}-${LB_END}"
        break
    fi
    show_message "The Load Balancer range must contain valid, ordered IP addresses inside ${SUBNET_CIDR}."
    LB_START_DEFAULT="${SUBNET_INPUT_PREFIX}100"
    LB_END_DEFAULT="${SUBNET_INPUT_PREFIX}110"
done

# OPTIONAL: DEPLOYMENT SIZING
echo -e "${YELLOW}=======================================================${NC}"
echo -e "${CYAN}      OPTIONAL: Deployment Sizing${NC}"
echo -e "${YELLOW}(Press Enter to use defaults)${NC}"
echo -e "${YELLOW}=======================================================${NC}"

# License tier — affects default worker count
if [[ -n "$TUI_BIN" ]]; then
    LICENSE_SELECTION=$(select_option "Do you plan to license NKP Pro/Ultimate?" "No" "Yes") || exit 1
    [[ "$LICENSE_SELECTION" == "2" ]] && NKP_LICENSED="y" || NKP_LICENSED="n"
else
    read -p "Do you plan to license NKP Pro/Ultimate? (y/N): " NKP_LICENSED
fi
if [[ "$NKP_LICENSED" =~ ^[Yy]$ ]]; then
    LICENSE_DEFAULT=4
else
    LICENSE_DEFAULT=2
fi

# Control plane replicas — default from saved or fall back to 1
CP_REPLICAS_DEFAULT=$(get_default "cp_replicas")
CP_REPLICAS_DEFAULT=${CP_REPLICAS_DEFAULT:-1}
while true; do
    if [[ -n "$TUI_BIN" ]]; then
        prompt_text "Control Plane Replicas (1, 3, or 5)" "$CP_REPLICAS_DEFAULT" CP_REPLICAS
        CP_REPLICAS="$REPLY"
    else
        read -p "Control Plane Replicas (1, 3, or 5 - default: ${CP_REPLICAS_DEFAULT}): " CP_REPLICAS
        CP_REPLICAS=${CP_REPLICAS:-$CP_REPLICAS_DEFAULT}
    fi
    if [[ "$CP_REPLICAS" =~ ^[135]$ ]]; then
        break
    fi
    echo -e "${RED}Error: Control plane replicas must be an odd number (1, 3, or 5) for proper quorum.${NC}"
done

# Worker replicas — default from saved, else from licensing answer
WORKER_REPLICAS_DEFAULT=$(get_default "worker_replicas")
WORKER_REPLICAS_DEFAULT=${WORKER_REPLICAS_DEFAULT:-$LICENSE_DEFAULT}
while true; do
    if [[ -n "$TUI_BIN" ]]; then
        prompt_text "Worker Replicas (1-10)" "$WORKER_REPLICAS_DEFAULT" WORKER_REPLICAS
        WORKER_REPLICAS="$REPLY"
    else
        read -p "Worker Replicas (1-10, default: ${WORKER_REPLICAS_DEFAULT}): " WORKER_REPLICAS
        WORKER_REPLICAS=${WORKER_REPLICAS:-$WORKER_REPLICAS_DEFAULT}
    fi
    if [[ "$WORKER_REPLICAS" =~ ^([1-9]|10)$ ]]; then
        break
    fi
    echo -e "${RED}Error: Must be a number between 1 and 10.${NC}"
done

# ============================================================
# SAVE DEFAULTS — written immediately after inputs
# ============================================================
save_defaults
echo -e "${GREEN}--> Inputs saved to ${DEFAULTS_FILE}${NC}"

# ============================================================
# VERSION VALIDATION (v4 API)
# ============================================================
echo -e "${YELLOW}Validating Prism Central and AOS versions...${NC}"

# A. PC version — select the PRISM_CENTRAL entity from cluster list
PC_V4_RESPONSE=$(call_curl_v4 "GET" "/clustermgmt/v4.0/config/clusters")
# Extract short version (e.g. "7.5") for comparison
PC_VERSION=$(echo "$PC_V4_RESPONSE" | jq -r '
    .data[]?
    | select(.config.clusterFunction != null)
    | select(.config.clusterFunction[] == "PRISM_CENTRAL")
    | .config.buildInfo.version
    // empty' 2>/dev/null | head -n1)
PC_RAW=$(echo "$PC_V4_RESPONSE" | jq -r '
    .data[]?
    | select(.config.clusterFunction != null)
    | select(.config.clusterFunction[] == "PRISM_CENTRAL")
    | .config.buildInfo.version
    // empty' 2>/dev/null | head -n1)

if [[ -z "$PC_VERSION" ]]; then
    echo -e "${RED}ERROR: Failed to retrieve Prism Central version.${NC}"
    echo -e "${YELLOW}Possible causes:${NC}"
    echo -e "  1. Invalid Prism Central endpoint: $PC_ENDPOINT"
    echo -e "  2. Invalid credentials (check username/password)"
    echo -e "  3. Network connectivity to Prism Central (port 9440)"
    echo -e "  4. Prism Central is not responding"
    echo -e "${YELLOW}To debug, test connectivity: ${CYAN}curl -k https://${PC_ENDPOINT}:9440/api/clustermgmt/v4.0/config/clusters${NC}"
    exit 1
fi

# B. Find the AHV cluster by name and get its AOS version
AHV_CLUSTER_RESPONSE=$(call_curl_v4 "GET" "/clustermgmt/v4.0/config/clusters?\$filter=contains(name,'${AHV_CLUSTER}')")
AOS_VERSION=$(echo "$AHV_CLUSTER_RESPONSE" | jq -r \
    --arg NAME "$AHV_CLUSTER" \
    '.data[]? | select(.name == $NAME) | .config.buildInfo.version // empty' \
    2>/dev/null | head -n1)

if [[ -z "$AOS_VERSION" ]]; then
    echo -e "${RED}ERROR: Could not find AHV Cluster named: ${CYAN}${AHV_CLUSTER}${NC}"
    echo -e "${YELLOW}Available clusters in Prism Central:${NC}"
    echo "$AHV_CLUSTER_RESPONSE" | jq -r '.data[]?.name // empty' 2>/dev/null | sed 's/^/  - /' || echo "  (unable to list clusters)"
    exit 1
fi

if ! version_gt "$PC_VERSION" "7.3" || ! version_gt "$AOS_VERSION" "7.3"; then
    echo -e "${RED}ERROR: Installation halted. Incompatible versions detected.${NC}"
    echo -e "${YELLOW}Required: Prism Central > 7.3, AOS > 7.3${NC}"
    echo -e "${CYAN}Detected:${NC}"
    echo -e "  Prism Central: $PC_RAW"
    echo -e "  AOS: $AOS_VERSION"
    exit 1
fi

echo -e "${GREEN}--> Version validation passed.${NC}"

# ============================================================
# SUMMARY LOOP — includes image validation
# ============================================================
VM_IMAGE_VALID=false

while true; do
    clear
    echo -e "${YELLOW}=======================================================${NC}"
    echo -e "${YELLOW}           FINAL DEPLOYMENT SUMMARY                    ${NC}"
    echo -e "${YELLOW}=======================================================${NC}"
    printf "${CYAN}%-25s${NC} : %s\n" "NKP Version"           "$VERSION_WITH_V"
    printf "${CYAN}%-25s${NC} : %s\n" "Prism Central Version"  "$PC_RAW"
    printf "${CYAN}%-25s${NC} : %s\n" "AOS Version"            "$AOS_VERSION"
    printf "${CYAN}%-25s${NC} : %s\n" "Cluster Name"           "$CLUSTER_NAME"
    printf "${CYAN}%-25s${NC} : %s\n" "PC Endpoint"            "$PC_ENDPOINT"
    printf "${CYAN}%-25s${NC} : %s\n" "Control Plane VIP"      "$VIP"
    printf "${CYAN}%-25s${NC} : %s\n" "VM Image Name"          "$VM_IMAGE"
    printf "${CYAN}%-25s${NC} : %s\n" "AHV Cluster Name"       "$AHV_CLUSTER"
    printf "${CYAN}%-25s${NC} : %s\n" "AHV Network Name"       "$NETWORK"
    printf "${CYAN}%-25s${NC} : %s\n" "AHV Network CIDR"       "$SUBNET_CIDR"
    printf "${CYAN}%-25s${NC} : %s\n" "Storage Container"      "$STORAGE"
    printf "${CYAN}%-25s${NC} : %s\n" "Load Balancer Range"    "$LB_RANGE"
    printf "${CYAN}%-25s${NC} : %s\n" "Pod CIDR"               "100.64.0.0/14"
    printf "${CYAN}%-25s${NC} : %s\n" "Service CIDR"           "100.68.0.0/16"
    printf "${CYAN}%-25s${NC} : %s\n" "Control Plane Replicas" "$CP_REPLICAS"
    printf "${CYAN}%-25s${NC} : %s\n" "Worker Replicas"        "$WORKER_REPLICAS"
    echo -e "${YELLOW}=======================================================${NC}"

    # Validate image — show result inline in summary
    echo -ne "${CYAN}Validating VM image against Prism Central...${NC} "
    validate_vm_image "$VM_IMAGE"

    if [[ "$VM_IMAGE_VALID" == true ]]; then
        echo -e "${GREEN}  ✔  Image '${VM_IMAGE}' found on Prism Central.${NC}"
        echo ""
        if [[ -n "$TUI_BIN" ]]; then
            if [[ "$TUI_BIN" == "whiptail" ]]; then
                whiptail --title "NKP Deployment" --yesno "Proceed with deployment using the values shown above?" 10 78 || exit 0
            else
                dialog --title "NKP Deployment" --yesno "Proceed with deployment using the values shown above?" 10 78 || exit 0
            fi
        else
            read -p "Proceed with deployment? (Y/n) > " CONFIRM
            [[ "$CONFIRM" =~ ^[Nn]$ ]] && exit 0
        fi
        break
    else
        # validate_vm_image already printed the candidate list
        if [[ -n "$TUI_BIN" ]]; then
            prompt_text "Enter the correct VM Image Name" "$VM_IMAGE" NEW_IMAGE
            NEW_IMAGE="$REPLY"
        else
            read -p "Enter correct VM Image Name: " NEW_IMAGE
        fi
        if [[ -n "$NEW_IMAGE" ]]; then
            VM_IMAGE="$NEW_IMAGE"
            save_defaults
        fi
    fi
done

# ============================================================
# SSH KEY SETUP
# ============================================================
echo -e "${CYAN}Setting up SSH key...${NC}"
if [[ ! -f ~/.ssh/id_rsa ]]; then
    echo -e "${YELLOW}--> No SSH key found. Generating RSA 4096 key...${NC}"
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q
    echo -e "${GREEN}--> SSH key generated: ~/.ssh/id_rsa${NC}"
fi
export SSH_PUBLIC_KEY_FILE=~/.ssh/id_rsa.pub
echo -e "${GREEN}--> SSH_PUBLIC_KEY_FILE set to: ${SSH_PUBLIC_KEY_FILE}${NC}"

# ============================================================
# PREFLIGHT 6: LOAD KONVOY BOOTSTRAP IMAGE
# ============================================================
echo -e "${CYAN}Loading Konvoy bootstrap image...${NC}"

if [[ ! -f "$BOOTSTRAP_IMAGE" ]]; then
    echo -e "${RED}ERROR: Bootstrap image not found: ${BOOTSTRAP_IMAGE}${NC}"
    echo -e "${YELLOW}Expected path: ${BOOTSTRAP_IMAGE}${NC}"
    echo -e "${YELLOW}Available .tar files in bundle directory:${NC}"
    ls "./$TARGET_DIR"/*.tar 2>/dev/null | sed 's/^/  /' || echo "  (no .tar files found)"
    exit 1
fi

echo -e "${CYAN}--> Loading: $(basename "$BOOTSTRAP_IMAGE")${NC}"
if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    podman load -i "$BOOTSTRAP_IMAGE"
    LOAD_EXIT=$?
    if [[ $LOAD_EXIT -ne 0 ]]; then
        echo -e "${RED}ERROR: Failed to load bootstrap image (exit code ${LOAD_EXIT}).${NC}"
        echo -e "${YELLOW}Verify the .tar file is not corrupted and that ${CONTAINER_RUNTIME} is functioning correctly.${NC}"
        exit 1
    fi
    # Podman does not automatically resolve the docker.io registry prefix;
    # nkp references the image as docker.io/mesosphere/konvoy-bootstrap:vVERSION
    BOOTSTRAP_TAG="docker.io/mesosphere/konvoy-bootstrap:${VERSION_WITH_V}"
    echo -e "${CYAN}--> Tagging bootstrap image for Podman: ${BOOTSTRAP_TAG}${NC}"
    podman image tag "konvoy-bootstrap:${VERSION_WITH_V}" "$BOOTSTRAP_TAG"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}ERROR: Failed to tag bootstrap image as ${BOOTSTRAP_TAG}.${NC}"
        echo -e "${YELLOW}Verify the image loaded correctly with: podman images | grep konvoy-bootstrap${NC}"
        exit 1
    fi
    echo -e "${GREEN}--> Bootstrap image tagged successfully.${NC}"
elif [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
    docker load -i "$BOOTSTRAP_IMAGE"
    LOAD_EXIT=$?
else
    echo -e "${RED}ERROR: No container runtime available to load bootstrap image.${NC}"
    echo -e "${YELLOW}Install podman or docker before running this script.${NC}"
    exit 1
fi

if [[ $LOAD_EXIT -ne 0 ]]; then
    echo -e "${RED}ERROR: Failed to load bootstrap image (exit code ${LOAD_EXIT}).${NC}"
    echo -e "${YELLOW}Verify the .tar file is not corrupted and that ${CONTAINER_RUNTIME} is functioning correctly.${NC}"
    exit 1
fi
echo -e "${GREEN}--> Konvoy bootstrap image loaded successfully.${NC}"

# ============================================================
# DEPLOYMENT
# ============================================================
export NUTANIX_USER
export NUTANIX_PASSWORD
export NUTANIX_ENDPOINT="https://${PC_ENDPOINT}:9440"
export KUBECONFIG="${SCRIPT_DIR}/${CLUSTER_NAME}.conf"

echo -e "${YELLOW}=======================================================${NC}"
echo -e "${YELLOW}           KUBECONFIG LOCATION                          ${NC}"
echo -e "${YELLOW}=======================================================${NC}"
echo -e "${CYAN}Your kubeconfig will be saved in:${NC}"
echo -e "  ${GREEN}${KUBECONFIG}${NC}"
echo -e "${YELLOW}This file is required to access the cluster.${NC}"
echo -e "${YELLOW}Ensure this location is persistent and backed up.${NC}"
echo -e "${YELLOW}=======================================================${NC}"

echo -e "${GREEN}Starting Deployment...${NC}"
nkp create cluster nutanix \
  $BUNDLE_FLAGS \
  --cluster-name                              "${CLUSTER_NAME}" \
  --endpoint                                  "${NUTANIX_ENDPOINT}" \
  --insecure \
  --control-plane-prism-element-cluster       "${AHV_CLUSTER}" \
  --worker-prism-element-cluster              "${AHV_CLUSTER}" \
  --control-plane-subnets                     "${NETWORK}" \
  --worker-subnets                            "${NETWORK}" \
  --vm-image                                  "${VM_IMAGE}" \
  --control-plane-endpoint-ip                 "${VIP}" \
  --csi-storage-container                     "${STORAGE}" \
  --kubernetes-service-load-balancer-ip-range "${LB_RANGE}" \
  --kubernetes-pod-network-cidr               "100.64.0.0/14" \
  --kubernetes-service-cidr                   "100.68.0.0/16" \
  --control-plane-replicas                    "$CP_REPLICAS" \
  --worker-replicas                           "$WORKER_REPLICAS" \
  --ssh-username                              "nutanix" \
  --ssh-public-key-file                       "${SSH_PUBLIC_KEY_FILE}" \
  --timeout                                          "60m0s" \
  --self-managed
NKP_EXIT=$?

if [[ $NKP_EXIT -eq 0 ]]; then
    echo -e "${GREEN}Deployment finished successfully.${NC}"
    echo -e "${CYAN}Access your cluster with:${NC}"
    echo -e "  export KUBECONFIG=${KUBECONFIG}"
else
    echo -e "${RED}=======================================================${NC}"
    echo -e "${RED}ERROR: Deployment failed (exit code ${NKP_EXIT}).${NC}"
    echo -e "${YELLOW}Your inputs have been saved to: ${DEFAULTS_FILE}${NC}"
    echo -e "${YELLOW}Re-run nkpDeploy.sh to retry with the same defaults.${NC}"
    echo -e "${RED}=======================================================${NC}"
    exit 1
fi
