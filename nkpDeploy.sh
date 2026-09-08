#!/bin/bash

# --- ANSI Color Codes ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
PURPLE='\033[38;5;141m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
TUI_ALT_SCREEN_ACTIVE=0

tui_enter_screen() {
    if [[ "$TUI_ALT_SCREEN_ACTIVE" != 1 ]]; then
        printf '\033[?1049h' >&2
        TUI_ALT_SCREEN_ACTIVE=1
    fi
}

tui_restore_terminal() {
    if [[ -c /dev/tty ]]; then
        stty echo icanon < /dev/tty 2>/dev/null || true
    fi
    if [[ "$TUI_ALT_SCREEN_ACTIVE" == 1 ]]; then
        printf '\033[?7h\033[?25h\033[0m\033[?1049l' >&2
        TUI_ALT_SCREEN_ACTIVE=0
    else
        printf '\033[?7h\033[?25h\033[0m' >&2
    fi
}

trap tui_restore_terminal EXIT

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
            RESPONSE=$(curl -s -k --connect-timeout 10 --max-time 60 -w '####%{response_code}' \
                -u "$PCADMIN:$PCPASSWD" \
                --header 'accept: application/json' \
                -H 'X-Nutanix-Client-Type: ui' \
                --request GET \
                --url "${URL}${APIURL}")
            ;;
        POST)
            RESPONSE=$(curl -s -k --connect-timeout 10 --max-time 60 -w '####%{response_code}' \
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
# These helpers keep the script usable over SSH. REPLY is intentionally
# global so callers can use the same helper for both prompts and menus.
prompt_text() {
    local LABEL="$1"
    local DEFAULT_VALUE="$2"
    local VAR_NAME="$3"
    local MODE="$4"

    if [[ -c /dev/tty ]]; then
        REPLY=$(modern_prompt "$LABEL" "$DEFAULT_VALUE" false) || exit 0
    else
        get_input "${LABEL}: " "$VAR_NAME" "$MODE"
        REPLY="${!VAR_NAME}"
    fi
}

prompt_password() {
    local LABEL="$1"
    if [[ -c /dev/tty ]]; then
        REPLY=$(modern_prompt "$LABEL" "" true) || exit 0
    else
        while [[ -z "$REPLY" ]]; do
            echo -ne "${YELLOW}${LABEL}: ${NC}"
            read -rs REPLY
            echo ""
        done
    fi
}

frame_setup() {
    SCREEN_COLS=$(tput cols 2>/dev/null || echo 80)
    SCREEN_ROWS=$(tput lines 2>/dev/null || echo 24)
    [[ "$SCREEN_COLS" =~ ^[0-9]+$ ]] || SCREEN_COLS=80
    [[ "$SCREEN_ROWS" =~ ^[0-9]+$ ]] || SCREEN_ROWS=24
    (( SCREEN_COLS < 60 )) && SCREEN_COLS=60
    (( SCREEN_ROWS < 16 )) && SCREEN_ROWS=16
    SCREEN_INNER=$((SCREEN_COLS - 2))
    printf -v FRAME_LINE '%*s' "$SCREEN_INNER" ''
    FRAME_LINE="${FRAME_LINE// /─}"
}

frame_row() {
    local TEXT="$1"
    local PURPLE='\033[38;5;141m'
    local RESET='\033[0m'
    (( ${#TEXT} > SCREEN_INNER )) && TEXT="${TEXT:0:SCREEN_INNER-3}..."
    printf '%b│%b%-*s%b│%b\n' "$PURPLE" "$RESET" "$SCREEN_INNER" "$TEXT" "$PURPLE" "$RESET" >&2
}

frame_row_color() {
    local COLOR="$1"
    local TEXT="$2"
    local PURPLE='\033[38;5;141m'
    local RESET='\033[0m'
    (( ${#TEXT} > SCREEN_INNER )) && TEXT="${TEXT:0:SCREEN_INNER-3}..."
    printf '%b│%b%b%-*s%b%b│%b\n' \
        "$PURPLE" "$RESET" "$COLOR" "$SCREEN_INNER" "$TEXT" "$RESET" "$PURPLE" "$RESET" >&2
}

frame_header() {
    local LABEL="$1"
    local PURPLE='\033[38;5;141m'
    local RESET='\033[0m'
    # 3J clears terminal scrollback so each screen starts as a clean app view.
    tui_enter_screen
    printf '\033[?7l\033[3J\033[2J\033[H' >&2
    printf '%b╭%s╮%b\n' "$PURPLE" "$FRAME_LINE" "$RESET" >&2
    frame_row_color "$PURPLE" "  NKP DEPLOYMENT"
    frame_row "  $LABEL"
    printf '%b├%s┤%b\n' "$PURPLE" "$FRAME_LINE" "$RESET" >&2
}

frame_prompt_header() {
    local PURPLE='\033[38;5;141m'
    local RESET='\033[0m'
    tui_enter_screen
    printf '\033[?7l\033[3J\033[2J\033[H' >&2
    printf '%b╭%s╮%b\n' "$PURPLE" "$FRAME_LINE" "$RESET" >&2
    frame_row_color "$PURPLE" "  NKP DEPLOYMENT"
    printf '%b├%s┤%b\n' "$PURPLE" "$FRAME_LINE" "$RESET" >&2
}

frame_footer() {
    local CONTROLS="$1"
    local PURPLE='\033[38;5;141m'
    local RESET='\033[0m'
    printf '%b├%s┤%b\n' "$PURPLE" "$FRAME_LINE" "$RESET" >&2
    frame_row "  Controls: $CONTROLS"
    printf '%b╰%s╯%b\033[?7h\n' "$PURPLE" "$FRAME_LINE" "$RESET" >&2
}

show_progress() {
    local MESSAGE="$1"
    frame_setup
    frame_header "$MESSAGE"
    local CONTENT_ROWS=$((SCREEN_ROWS - 7))
    local INDEX
    for ((INDEX=0; INDEX<CONTENT_ROWS; INDEX++)); do
        frame_row ""
    done
    frame_footer "Please wait...   Ctrl-C exit"
}

modern_prompt() {
    local LABEL="$1"
    local DEFAULT_VALUE="$2"
    local MASKED="$3"
    local VALUE=""

    frame_setup
    frame_prompt_header
    local INPUT_TEXT="  ${LABEL}: "
    local INPUT_COLUMN=$((2 + ${#INPUT_TEXT}))
    [[ "$MASKED" == true ]] && INPUT_TEXT="  Password: " && INPUT_COLUMN=$((2 + ${#INPUT_TEXT}))
    frame_row "$INPUT_TEXT"
    # Save the cursor on the actual input row instead of relying on a
    # terminal-specific absolute row calculation.
    printf '\033[1A\033[%dG\033[s' "$INPUT_COLUMN" >&2
    printf '\033[1B\033[1G' >&2
    local CONTENT_ROWS=$((SCREEN_ROWS - 7))
    local INDEX
    for ((INDEX=0; INDEX<CONTENT_ROWS; INDEX++)); do
        frame_row ""
    done
    frame_footer "Enter submit   Ctrl-C exit"
    printf '\033[u' >&2
    if [[ "$MASKED" == true ]]; then
        IFS= read -r -s VALUE < /dev/tty
        printf '\n' >&2
    else
        IFS= read -r VALUE < /dev/tty
    fi

    if [[ -z "$VALUE" && -n "$DEFAULT_VALUE" ]]; then
        VALUE="$DEFAULT_VALUE"
    fi
    printf '%s' "$VALUE"
}

modern_select() {
    local LABEL="$1"
    shift
    local OPTIONS=("$@")
    local CURRENT=0 OFFSET=0 KEY KEY2
    local OLD_STTY
    local VISIBLE

    [[ ${#OPTIONS[@]} -gt 0 ]] || return 1
    [[ -c /dev/tty ]] || return 1

    OLD_STTY=$(stty -g < /dev/tty) || return 1
    stty -echo -icanon min 1 time 0 < /dev/tty || return 1
    frame_setup
    VISIBLE=$((SCREEN_ROWS - 8))
    (( VISIBLE < 3 )) && VISIBLE=3

    while true; do
        frame_header "$LABEL"

        (( CURRENT < OFFSET )) && OFFSET=$CURRENT
        (( CURRENT >= OFFSET + VISIBLE )) && OFFSET=$((CURRENT - VISIBLE + 1))
        local END=$((OFFSET + VISIBLE))
        (( END > ${#OPTIONS[@]} )) && END=${#OPTIONS[@]}

        local INDEX
        for ((INDEX=OFFSET; INDEX<END; INDEX++)); do
            local DISPLAY_VALUE="${OPTIONS[$INDEX]}"
            (( ${#DISPLAY_VALUE} > SCREEN_INNER - 6 )) && DISPLAY_VALUE="${DISPLAY_VALUE:0:SCREEN_INNER-9}..."
            if (( INDEX == CURRENT )); then
                printf '\033[48;5;99m\033[97m│%-*s│\033[0m\n' \
                    "$SCREEN_INNER" "  > $DISPLAY_VALUE" >&2
            else
                frame_row "    $DISPLAY_VALUE"
            fi
        done
        for ((INDEX=END; INDEX<OFFSET+VISIBLE; INDEX++)); do
            frame_row ""
        done
        frame_footer "$((CURRENT + 1))/${#OPTIONS[@]}   ↑/↓ navigate   Enter select   q exit"

        IFS= read -r -s -n 1 -u 3 KEY < /dev/tty
        # Bash may return an empty variable for Enter when read is operating
        # in non-canonical mode. Treat that the same as a newline.
        if [[ -z "$KEY" ]]; then
            stty "$OLD_STTY" < /dev/tty
            printf '%s' "$((CURRENT + 1))"
            return 0
        fi
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

    # The modern picker is dependency-free and works well over SSH.
    exec 3<> /dev/tty
    modern_select "$LABEL" "${OPTIONS[@]}"
    local RESULT=$?
    exec 3>&-
    return "$RESULT"
}

show_message() {
    local MESSAGE="$1"
    if [[ -c /dev/tty ]]; then
        frame_setup
        frame_header "Message"
        local MESSAGE_LINES=0
        local MESSAGE_LINE
        while IFS= read -r MESSAGE_LINE; do
            frame_row "  $MESSAGE_LINE"
            MESSAGE_LINES=$((MESSAGE_LINES + 1))
        done <<< "$(printf '%b' "$MESSAGE")"
        local CONTENT_ROWS=$((SCREEN_ROWS - 7))
        local INDEX
        for ((INDEX=MESSAGE_LINES; INDEX<CONTENT_ROWS; INDEX++)); do
            frame_row ""
        done
        frame_footer "Enter continue   Ctrl-C exit"
        IFS= read -r _ < /dev/tty
    else
        echo -e "${MESSAGE}"
        read -r -p "Press Enter to continue..." _
    fi
}

status_render() {
    local CONTROLS="${1:-Please wait...   Ctrl-C exit}"
    frame_setup
    frame_header "${TUI_STATUS_TITLE:-NKP startup}"

    local CONTENT_ROWS=$((SCREEN_ROWS - 7))
    local START=0
    local TOTAL=${#TUI_STATUS_LINES[@]}
    (( TOTAL > CONTENT_ROWS )) && START=$((TOTAL - CONTENT_ROWS))

    local INDEX COLOR MESSAGE
    for ((INDEX=START; INDEX<TOTAL; INDEX++)); do
        COLOR="${TUI_STATUS_COLORS[$INDEX]}"
        MESSAGE="${TUI_STATUS_LINES[$INDEX]}"
        frame_row_color "$COLOR" "  $MESSAGE"
    done
    for ((INDEX=TOTAL-START; INDEX<CONTENT_ROWS; INDEX++)); do
        frame_row ""
    done
    frame_footer "$CONTROLS"
}

status_begin() {
    TUI_STATUS_TITLE="$1"
    TUI_STATUS_LINES=()
    TUI_STATUS_COLORS=()
    status_render
}

status_add() {
    local COLOR="$1"
    shift
    TUI_STATUS_COLORS+=("$COLOR")
    TUI_STATUS_LINES+=("$*")
    status_render
}

status_pause() {
    status_render "Enter continue   Ctrl-C exit"
    IFS= read -r _ < /dev/tty
}

# ============================================================
# DEPENDENCY CHECK
# ============================================================
status_begin "Checking local prerequisites"
status_add "$CYAN" "Verifying required dependencies..."
REQUIRED_COMMANDS=("curl" "jq" "tar")
MISSING_COMMANDS=()
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if command -v "$cmd" &> /dev/null; then
        status_add "$GREEN" "${cmd} is available."
    else
        MISSING_COMMANDS+=("$cmd")
        status_add "$RED" "${cmd} is not installed."
    fi
done
if [[ ${#MISSING_COMMANDS[@]} -gt 0 ]]; then
    status_add "$YELLOW" "Install missing tools with: sudo yum install -y ${MISSING_COMMANDS[*]}"
    status_pause
    exit 1
fi
status_add "$GREEN" "All required dependencies verified."

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

# Return the fixed network portion of an address. The editable portion is
# entered separately so users cannot accidentally change the network prefix.
network_input_prefix() {
    local IP="$1"
    local PREFIX="$2"
    local A B C D FULL_OCTETS
    IFS=. read -r A B C D <<< "$IP"
    FULL_OCTETS=$((PREFIX / 8))
    case "$FULL_OCTETS" in
        0) echo "" ;;
        1) echo "${A}." ;;
        2) echo "${A}.${B}." ;;
        3) echo "${A}.${B}.${C}." ;;
        *) echo "${A}.${B}.${C}.${D}" ;;
    esac
}

host_octet_count() {
    local PREFIX="$1"
    local COUNT=$((4 - PREFIX / 8))
    (( COUNT < 1 )) && COUNT=1
    echo "$COUNT"
}

suffix_from_ip() {
    local IP="$1"
    local PREFIX="$2"
    local FIXED_PREFIX
    FIXED_PREFIX=$(network_input_prefix "$SUBNET_NETWORK_IP" "$PREFIX")
    if [[ "$IP" == "$FIXED_PREFIX"* ]]; then
        echo "${IP#"$FIXED_PREFIX"}"
    else
        echo ""
    fi
}

int2ip() {
    local VALUE="$1"
    echo "$(( (VALUE >> 24) & 255 )).$(( (VALUE >> 16) & 255 )).$(( (VALUE >> 8) & 255 )).$(( VALUE & 255 ))"
}

modern_host_prompt() {
    local LABEL="$1"
    local FIXED_PREFIX="$2"
    local DEFAULT_SUFFIX="$3"
    local HOST_OCTETS="$4"
    local VALUE="" OCTET_WORD="octet"
    (( HOST_OCTETS != 1 )) && OCTET_WORD="octets"

    frame_setup
    frame_prompt_header
    local INPUT_TEXT="  ${LABEL}: ${FIXED_PREFIX}"
    local INPUT_COLUMN=$((2 + ${#INPUT_TEXT}))
    frame_row "$INPUT_TEXT"
    # Save the cursor on the actual input row instead of relying on a
    # terminal-specific absolute row calculation.
    printf '\033[1A\033[%dG\033[s' "$INPUT_COLUMN" >&2
    printf '\033[1B\033[1G' >&2
    local CONTENT_ROWS=$((SCREEN_ROWS - 7))
    local INDEX
    for ((INDEX=0; INDEX<CONTENT_ROWS; INDEX++)); do
        frame_row ""
    done
    frame_footer "Type ${HOST_OCTETS} host ${OCTET_WORD}   Enter submit   Ctrl-C exit"
    printf '\033[u' >&2
    IFS= read -r VALUE < /dev/tty
    [[ -z "$VALUE" && -n "$DEFAULT_SUFFIX" ]] && VALUE="$DEFAULT_SUFFIX"
    printf '%s' "$VALUE"
}

prompt_host_suffix() {
    local LABEL="$1"
    local DEFAULT_SUFFIX="$2"
    REPLY=$(modern_host_prompt "$LABEL" "$SUBNET_INPUT_PREFIX" "$DEFAULT_SUFFIX" "$SUBNET_HOST_OCTETS") || exit 0
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
    local IMAGE_MESSAGE="Image '${IMAGE_NAME}' was not found on Prism Central."
    if [[ -n "$FUZZY_LIST" ]]; then
        IMAGE_MESSAGE+=$'\n\nSimilar images found:'
        while IFS= read -r IMG; do
            IMAGE_MESSAGE+=$'\n  '
            IMAGE_MESSAGE+="$IMG"
        done <<< "$FUZZY_LIST"
    else
        IMAGE_MESSAGE+=$'\n\nNo similar images found. Fetching the full image list...'
        local ALL_RESULTS
        ALL_RESULTS=$(call_curl_v4 "GET" "/vmm/v4.0/content/images")
        local ALL_IMAGES
        ALL_IMAGES=$(echo "$ALL_RESULTS" | jq -r '.data[]?.name' 2>/dev/null)
        if [[ -n "$ALL_IMAGES" ]]; then
            IMAGE_MESSAGE+=$'\n\nAvailable images:'
            while IFS= read -r IMG; do
                IMAGE_MESSAGE+=$'\n  '
                IMAGE_MESSAGE+="$IMG"
            done <<< "$ALL_IMAGES"
        else
            IMAGE_MESSAGE+=$'\n\nCould not retrieve the image list from Prism Central.'
        fi
    fi
    show_message "$IMAGE_MESSAGE"
}

summary_row() {
    local LABEL="$1"
    local VALUE="$2"
    local PURPLE='\033[38;5;141m'
    local DIM='\033[38;5;245m'
    local RESET='\033[0m'
    local LABEL_WIDTH="${SUMMARY_LABEL_WIDTH:-26}"
    local VALUE_WIDTH="${SUMMARY_VALUE_WIDTH:-41}"
    VALUE="${VALUE//$'\n'/ }"
    (( ${#VALUE} > VALUE_WIDTH )) && VALUE="${VALUE:0:VALUE_WIDTH-3}..."
    printf '%b│%b %b%-*s%b │ %-*s %b│%b\n' \
        "$PURPLE" "$RESET" "$DIM" "$LABEL_WIDTH" "$LABEL" "$RESET" "$VALUE_WIDTH" "$VALUE" "$PURPLE" "$RESET"
}

render_final_summary() {
    frame_setup
    SUMMARY_LABEL_WIDTH=26
    SUMMARY_VALUE_WIDTH=$((SCREEN_INNER - SUMMARY_LABEL_WIDTH - 5))
    frame_header "Final deployment summary"
    summary_row "NKP Version" "$VERSION_WITH_V"
    summary_row "Prism Central" "$PC_ENDPOINT"
    summary_row "Prism Central Version" "$PC_RAW"
    summary_row "AOS Version" "$AOS_VERSION"
    summary_row "Cluster Name" "$CLUSTER_NAME"
    summary_row "AHV Cluster" "$AHV_CLUSTER"
    summary_row "AHV Network" "$NETWORK"
    summary_row "Network CIDR" "$SUBNET_CIDR"
    summary_row "Control Plane VIP" "$VIP"
    summary_row "Load Balancer Range" "$LB_RANGE"
    summary_row "VM Image" "$VM_IMAGE"
    summary_row "Storage Container" "$STORAGE"
    summary_row "Control Plane Nodes" "$CP_REPLICAS"
    summary_row "Worker Nodes" "$WORKER_REPLICAS"
    summary_row "Kubeconfig" "$KUBECONFIG"
    local SUMMARY_ROWS=15
    local CONTENT_ROWS=$((SCREEN_ROWS - 7))
    local INDEX
    for ((INDEX=SUMMARY_ROWS; INDEX<CONTENT_ROWS; INDEX++)); do
        frame_row ""
    done
    frame_footer "Y deploy   N exit"
}

final_summary_confirmation() {
    local CONFIRM=""
    IFS= read -r -s -n 1 CONFIRM < /dev/tty
    [[ -z "$CONFIRM" ]] && CONFIRM="Y"
    [[ "$CONFIRM" =~ ^[Nn]$ ]] && return 1
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || return 2
    return 0
}

# ============================================================
# PREFLIGHT 1: CONTAINER RUNTIME & CGROUP DELEGATION
# ============================================================
status_begin "Preflight checks"
status_add "$CYAN" "Checking container runtime and cgroup configuration..."

CONTAINER_RUNTIME="unknown"
if command -v podman &> /dev/null; then
    CONTAINER_RUNTIME="podman"
    status_add "$GREEN" "Podman detected."
elif command -v docker &> /dev/null; then
    CONTAINER_RUNTIME="docker"
    status_add "$GREEN" "Docker detected; cgroup delegation is not required."
else
    status_add "$YELLOW" "Warning: no podman or docker runtime detected."
    status_add "$YELLOW" "NKP requires podman or docker to be installed."
fi

# Cgroup delegation is only needed for podman
if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    GLOBAL_DELEGATE_DIR="/etc/systemd/system/user@.service.d"
    GLOBAL_DELEGATE_CONF="$GLOBAL_DELEGATE_DIR/delegate.conf"

    if [[ ! -f "$GLOBAL_DELEGATE_CONF" ]]; then
        status_add "$YELLOW" "Podman cgroup v2 delegation is missing; applying the fix..."
        sudo mkdir -p "$GLOBAL_DELEGATE_DIR" >/dev/null 2>&1
        printf '[Service]\nDelegate=yes\n' | sudo tee "$GLOBAL_DELEGATE_CONF" >/dev/null
        sudo systemctl daemon-reload >/dev/null 2>&1
        status_add "$RED" "System change applied: reboot required."
        status_add "$YELLOW" "Run: sudo reboot"
        status_pause
        exit 1
    fi

    if ! systemctl show "user@$(id -u).service" --property=Delegate | grep -q "Delegate=yes"; then
        status_add "$RED" "Error: cgroup delegation is configured but not active."
        status_add "$YELLOW" "A reboot is required; run: sudo reboot"
        status_pause
        exit 1
    fi
    status_add "$GREEN" "Podman cgroup delegation verified and active."
elif [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
    status_add "$GREEN" "Docker daemon is ready."
fi

# ============================================================
# PREFLIGHT 2: NETWORK CONNECTIVITY CHECK
# ============================================================
status_add "$YELLOW" "Checking outbound connectivity to Nutanix portal..."
if ! curl -s --connect-timeout 5 --max-time 10 https://portal.nutanix.com >/dev/null 2>&1; then
    status_add "$RED" "Error: cannot reach https://portal.nutanix.com."
    status_add "$YELLOW" "Verify internet access, proxy settings, firewall, and DNS."
    status_add "$CYAN" "Diagnostic: curl -v https://portal.nutanix.com"
    status_pause
    exit 1
fi
status_add "$GREEN" "Outbound connectivity verified."

# ============================================================
# PREFLIGHT 3: FIND OR DOWNLOAD BUNDLE
# ============================================================
status_begin "NKP bundle"
status_add "$CYAN" "Looking for an existing NKP bundle or extracted bundle..."

# Check for airgap bundle mistakenly placed in the directory
if ls nkp-air-gapped-bundle_v*.tar.gz &>/dev/null; then
    status_add "$RED" "Error: an NKP air-gapped bundle was found here."
    status_add "$YELLOW" "This script requires the standard NKP Bundle."
    status_add "$GREEN" "Correct filename: nkp-bundle_v*.tar.gz"
    status_add "$CYAN" "Download: https://portal.nutanix.com/page/downloads?product=nkp"
    status_pause
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
    status_add "$YELLOW" "NKP Bundle not found locally."
    status_add "$CYAN" "Download the standard bundle from the Nutanix portal."
    while true; do
        prompt_text "Paste the full Nutanix Bundle download URL" "" RAW_URL
        RAW_URL="$REPLY"
        [[ -z "$RAW_URL" ]] && exit 1
        BUNDLE_FILE=$(basename "${RAW_URL%%\?*}")
        if [[ "$BUNDLE_FILE" == *"air-gapped"* ]]; then
            show_message "That URL points to the Air-Gapped Bundle.\n\nPlease copy the URL for the standard NKP Bundle."
            BUNDLE_FILE=""
            continue
        fi
        status_add "$CYAN" "Downloading $(basename "$BUNDLE_FILE")..."
        if curl -kL -sS -o "$BUNDLE_FILE" "$RAW_URL" >/dev/null 2>&1; then
            status_add "$GREEN" "Bundle download completed."
            break
        fi
        rm -f "$BUNDLE_FILE"
        show_message "The bundle download failed.\n\nCheck the URL and network connectivity, then try again."
    done
else
    status_add "$GREEN" "Using bundle: $BUNDLE_FILE"
fi

# ============================================================
# PREFLIGHT 4: VERSION & EXTRACTION
# ============================================================
VERSION_WITH_V=$(echo "$BUNDLE_FILE" | sed -E 's/.*bundle_(v[0-9]+\.[0-9]+\.[0-9]+).*/\1/')
TARGET_DIR="${BUNDLE_FILE%.tar.gz}"

if [[ ! -d "$TARGET_DIR" ]]; then
    status_add "$CYAN" "Extracting $BUNDLE_FILE..."
    mkdir -p "$TARGET_DIR"
    if ! tar -xzpf "$BUNDLE_FILE" -C "$TARGET_DIR" --strip-components=1 >/dev/null 2>&1; then
        status_add "$RED" "Error: bundle extraction failed."
        status_pause
        exit 1
    fi

    # Validate expected structure exists
    if [[ ! -f "$TARGET_DIR/cli/nkp" ]] || [[ ! -f "$TARGET_DIR/kubectl" ]]; then
        status_add "$RED" "Error: expected nkp and kubectl binaries were not found."
        status_add "$YELLOW" "The bundle structure may be different than expected."
        status_pause
        exit 1
    fi
    status_add "$GREEN" "Bundle contents validated."
    status_add "$CYAN" "Removing downloaded tarball..."
    rm -f "$BUNDLE_FILE"
else
    status_add "$GREEN" "Using existing extracted bundle: $TARGET_DIR"
fi

# ============================================================
# PREFLIGHT 5: INSTALL BINARIES TO /usr/local/bin
# ============================================================
status_add "$CYAN" "Installing nkp and kubectl to /usr/local/bin..."

if sudo cp "./$TARGET_DIR/cli/nkp" /usr/local/bin/nkp && \
   sudo cp "./$TARGET_DIR/kubectl" /usr/local/bin/kubectl && \
   sudo chmod 755 /usr/local/bin/nkp /usr/local/bin/kubectl; then
    if [[ -x "/usr/local/bin/nkp" ]] && [[ -x "/usr/local/bin/kubectl" ]]; then
        status_add "$GREEN" "NKP tools installed successfully."
    else
        status_add "$RED" "Error: files copied but permission check failed."
        status_pause
        exit 1
    fi
else
    status_add "$RED" "Error: failed to install binaries. Check sudo permissions."
    status_pause
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
status_add "$PURPLE" "NKP Version Detected: ${VERSION_WITH_V}"
if [[ -f "$DEFAULTS_FILE" ]]; then
    status_add "$CYAN" "Defaults loaded from: ${DEFAULTS_FILE}"
fi

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

show_progress "Loading AHV clusters from Prism Central"
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

show_progress "Loading networks for ${AHV_CLUSTER}"
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

show_progress "Loading storage containers from Prism Central"
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

show_progress "Loading VM images from Prism Central"
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

validate_host_suffix() {
    local SUFFIX="$1"
    local PARTS
    local CANDIDATE="${SUBNET_INPUT_PREFIX}${SUFFIX}"
    IFS='.' read -r -a PARTS <<< "$SUFFIX"
    [[ ${#PARTS[@]} -eq "$SUBNET_HOST_OCTETS" ]] || return 1
    validate_ipv4 "$CANDIDATE"
}

default_host_suffix() {
    local A B C D
    IFS=. read -r A B C D <<< "$SUBNET_NETWORK_IP"
    case "$SUBNET_HOST_OCTETS" in
        1) echo "100" ;;
        2) echo "${C}.100" ;;
        3) echo "${B}.${C}.100" ;;
        *) echo "${A}.${B}.${C}.100" ;;
    esac
}

SUBNET_HOST_OCTETS=$(host_octet_count "$SUBNET_PREFIX_LENGTH")
VIP_SAVED=$(get_default "vip")
VIP_SUFFIX_DEFAULT=$(suffix_from_ip "$VIP_SAVED" "$SUBNET_PREFIX_LENGTH")
while true; do
    prompt_host_suffix "Control Plane VIP (${SUBNET_CIDR})" "$VIP_SUFFIX_DEFAULT"
    VIP_SUFFIX="$REPLY"
    VIP="${SUBNET_INPUT_PREFIX}${VIP_SUFFIX}"
    if validate_host_suffix "$VIP_SUFFIX" && is_in_same_subnet "$VIP" "$SUBNET_NETWORK_IP" "$SUBNET_PREFIX_LENGTH"; then
        break
    fi
    show_message "The Control Plane VIP must be a valid address inside ${SUBNET_CIDR}."
    VIP_SUFFIX_DEFAULT=""
done

LB_SAVED=$(get_default "lb_range")
LB_START_SAVED="${LB_SAVED%%-*}"
LB_END_SAVED="${LB_SAVED##*-}"
LB_START_SUFFIX_DEFAULT=$(suffix_from_ip "$LB_START_SAVED" "$SUBNET_PREFIX_LENGTH")
[[ -z "$LB_START_SUFFIX_DEFAULT" ]] && LB_START_SUFFIX_DEFAULT=$(default_host_suffix)
LB_COUNT_DEFAULT=10
if validate_ipv4 "$LB_START_SAVED" && validate_ipv4 "$LB_END_SAVED" && \
   (( $(ip2int "$LB_END_SAVED") >= $(ip2int "$LB_START_SAVED") )); then
    LB_COUNT_DEFAULT=$(( $(ip2int "$LB_END_SAVED") - $(ip2int "$LB_START_SAVED") + 1 ))
fi
(( LB_COUNT_DEFAULT < 1 || LB_COUNT_DEFAULT > 254 )) && LB_COUNT_DEFAULT=10

while true; do
    prompt_host_suffix "Load Balancer range start (${SUBNET_CIDR})" "$LB_START_SUFFIX_DEFAULT"
    LB_START_SUFFIX="$REPLY"
    LB_START="${SUBNET_INPUT_PREFIX}${LB_START_SUFFIX}"
    if ! validate_host_suffix "$LB_START_SUFFIX" || ! is_in_same_subnet "$LB_START" "$SUBNET_NETWORK_IP" "$SUBNET_PREFIX_LENGTH"; then
        show_message "The Load Balancer start must be inside ${SUBNET_CIDR}."
        LB_START_SUFFIX_DEFAULT=""
        continue
    fi

    LB_COUNT_OPTIONS=("$LB_COUNT_DEFAULT")
    for ((COUNT=1; COUNT<=254; COUNT++)); do
        [[ "$COUNT" == "$LB_COUNT_DEFAULT" ]] || LB_COUNT_OPTIONS+=("$COUNT")
    done
    SELECTED_INDEX=$(select_option "How many Load Balancer IPs should be reserved?" "${LB_COUNT_OPTIONS[@]}") || exit 1
    LB_COUNT="${LB_COUNT_OPTIONS[$((SELECTED_INDEX - 1))]}"
    LB_END_VALUE=$(( $(ip2int "$LB_START") + LB_COUNT - 1 ))
    if (( LB_END_VALUE <= 4294967295 )); then
        LB_END=$(int2ip "$LB_END_VALUE")
    else
        LB_END=""
    fi

    if validate_ipv4 "$LB_END" && is_in_same_subnet "$LB_END" "$SUBNET_NETWORK_IP" "$SUBNET_PREFIX_LENGTH"; then
        LB_RANGE="${LB_START}-${LB_END}"
        break
    fi
    show_message "That range does not fit inside ${SUBNET_CIDR}; choose a lower start or a smaller count."
done

# OPTIONAL: DEPLOYMENT SIZING
# License tier — affects default worker count
LICENSE_SELECTION=$(select_option "Do you plan to license NKP Pro/Ultimate?" "No" "Yes") || exit 1
[[ "$LICENSE_SELECTION" == "2" ]] && NKP_LICENSED="y" || NKP_LICENSED="n"
if [[ "$NKP_LICENSED" =~ ^[Yy]$ ]]; then
    LICENSE_DEFAULT=4
else
    LICENSE_DEFAULT=2
fi

# Control plane replicas — selectable, default from saved or fall back to 1
CP_REPLICAS_DEFAULT=$(get_default "cp_replicas")
CP_REPLICAS_DEFAULT=${CP_REPLICAS_DEFAULT:-1}
CP_OPTIONS=()
[[ "$CP_REPLICAS_DEFAULT" =~ ^[135]$ ]] && CP_OPTIONS+=("$CP_REPLICAS_DEFAULT")
for REPLICA_OPTION in 1 3 5; do
    [[ "$REPLICA_OPTION" == "$CP_REPLICAS_DEFAULT" ]] || CP_OPTIONS+=("$REPLICA_OPTION")
done
SELECTED_INDEX=$(select_option "Select the Control Plane node count" "${CP_OPTIONS[@]}") || exit 1
CP_REPLICAS="${CP_OPTIONS[$((SELECTED_INDEX - 1))]}"

# Worker replicas — selectable, default from saved, else from licensing answer
WORKER_REPLICAS_DEFAULT=$(get_default "worker_replicas")
WORKER_REPLICAS_DEFAULT=${WORKER_REPLICAS_DEFAULT:-$LICENSE_DEFAULT}
WORKER_OPTIONS=()
[[ "$WORKER_REPLICAS_DEFAULT" =~ ^([1-9]|10)$ ]] && WORKER_OPTIONS+=("$WORKER_REPLICAS_DEFAULT")
for REPLICA_OPTION in {1..10}; do
    [[ "$REPLICA_OPTION" == "$WORKER_REPLICAS_DEFAULT" ]] || WORKER_OPTIONS+=("$REPLICA_OPTION")
done
SELECTED_INDEX=$(select_option "Select the Worker node count" "${WORKER_OPTIONS[@]}") || exit 1
WORKER_REPLICAS="${WORKER_OPTIONS[$((SELECTED_INDEX - 1))]}"

# ============================================================
# SAVE DEFAULTS — written immediately after inputs
# ============================================================
save_defaults

# ============================================================
# VERSION VALIDATION (v4 API)
# ============================================================
status_begin "Final environment checks"
status_add "$GREEN" "Inputs saved to ${DEFAULTS_FILE}"
status_add "$YELLOW" "Validating Prism Central and AOS versions..."

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
    status_add "$RED" "Error: failed to retrieve the Prism Central version."
    status_add "$YELLOW" "Check endpoint, credentials, port 9440, and Prism Central availability."
    status_add "$CYAN" "Diagnostic: curl -k https://${PC_ENDPOINT}:9440/api/clustermgmt/v4.0/config/clusters"
    status_pause
    exit 1
fi

# B. Find the AHV cluster by name and get its AOS version
AHV_CLUSTER_RESPONSE=$(call_curl_v4 "GET" "/clustermgmt/v4.0/config/clusters?\$filter=contains(name,'${AHV_CLUSTER}')")
AOS_VERSION=$(echo "$AHV_CLUSTER_RESPONSE" | jq -r \
    --arg NAME "$AHV_CLUSTER" \
    '.data[]? | select(.name == $NAME) | .config.buildInfo.version // empty' \
    2>/dev/null | head -n1)

if [[ -z "$AOS_VERSION" ]]; then
    status_add "$RED" "Error: could not find AHV cluster ${AHV_CLUSTER}."
    status_add "$YELLOW" "The selected cluster may no longer be available."
    status_pause
    exit 1
fi

if ! version_gt "$PC_VERSION" "7.3" || ! version_gt "$AOS_VERSION" "7.3"; then
    status_add "$RED" "Error: installation halted; incompatible versions detected."
    status_add "$YELLOW" "Required: Prism Central > 7.3 and AOS > 7.3"
    status_add "$CYAN" "Detected: PC ${PC_RAW}; AOS ${AOS_VERSION}"
    status_pause
    exit 1
fi

status_add "$GREEN" "Version validation passed."

# ============================================================
# SSH KEY SETUP
# ============================================================
status_add "$CYAN" "Setting up SSH key..."
if [[ ! -f ~/.ssh/id_rsa ]]; then
    status_add "$YELLOW" "No SSH key found; generating an RSA 4096 key..."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q
    status_add "$GREEN" "SSH key generated: ~/.ssh/id_rsa"
fi
export SSH_PUBLIC_KEY_FILE=~/.ssh/id_rsa.pub
status_add "$GREEN" "SSH public key ready."

# ============================================================
# PREFLIGHT 6: LOAD KONVOY BOOTSTRAP IMAGE
# ============================================================
status_add "$CYAN" "Loading Konvoy bootstrap image..."

if [[ ! -f "$BOOTSTRAP_IMAGE" ]]; then
    status_add "$RED" "Error: bootstrap image not found."
    status_add "$YELLOW" "Expected: ${BOOTSTRAP_IMAGE}"
    status_pause
    exit 1
fi

status_add "$CYAN" "Loading: $(basename "$BOOTSTRAP_IMAGE")"
if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    podman load -i "$BOOTSTRAP_IMAGE" >/dev/null 2>&1
    LOAD_EXIT=$?
    if [[ $LOAD_EXIT -ne 0 ]]; then
        status_add "$RED" "Error: failed to load bootstrap image (exit ${LOAD_EXIT})."
        status_add "$YELLOW" "Verify the .tar file and ${CONTAINER_RUNTIME} runtime."
        status_pause
        exit 1
    fi
    # Podman does not automatically resolve the docker.io registry prefix;
    # nkp references the image as docker.io/mesosphere/konvoy-bootstrap:vVERSION
    BOOTSTRAP_TAG="docker.io/mesosphere/konvoy-bootstrap:${VERSION_WITH_V}"
    status_add "$CYAN" "Tagging bootstrap image for Podman..."
    podman image tag "konvoy-bootstrap:${VERSION_WITH_V}" "$BOOTSTRAP_TAG" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        status_add "$RED" "Error: failed to tag bootstrap image."
        status_add "$YELLOW" "Verify with: podman images | grep konvoy-bootstrap"
        status_pause
        exit 1
    fi
    status_add "$GREEN" "Bootstrap image tagged successfully."
elif [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
    docker load -i "$BOOTSTRAP_IMAGE" >/dev/null 2>&1
    LOAD_EXIT=$?
else
    status_add "$RED" "Error: no container runtime is available."
    status_add "$YELLOW" "Install podman or docker before continuing."
    status_pause
    exit 1
fi

if [[ $LOAD_EXIT -ne 0 ]]; then
    status_add "$RED" "Error: failed to load bootstrap image (exit ${LOAD_EXIT})."
    status_add "$YELLOW" "Verify the .tar file and ${CONTAINER_RUNTIME} runtime."
    status_pause
    exit 1
fi
status_add "$GREEN" "Konvoy bootstrap image loaded successfully."

# Prepare the kubeconfig location before rendering the final screen so the
# summary really is the last review surface before deployment.
export NUTANIX_USER
export NUTANIX_PASSWORD
export NUTANIX_ENDPOINT="https://${PC_ENDPOINT}:9440"
export KUBECONFIG="${SCRIPT_DIR}/${CLUSTER_NAME}.conf"

# ============================================================
# FINAL SUMMARY — the last screen before deployment
# ============================================================
VM_IMAGE_VALID=false
while true; do
    validate_vm_image "$VM_IMAGE"

    if [[ "$VM_IMAGE_VALID" == true ]]; then
        render_final_summary
        if final_summary_confirmation; then
            break
        elif [[ $? -eq 1 ]]; then
            exit 0
        fi
        continue
    fi

    prompt_text "Enter the correct VM Image Name" "$VM_IMAGE" NEW_IMAGE
    NEW_IMAGE="$REPLY"
    if [[ -n "$NEW_IMAGE" ]]; then
        VM_IMAGE="$NEW_IMAGE"
        save_defaults
    fi
done

# ============================================================
# DEPLOYMENT
# ============================================================
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
