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
            echo "{\"httpStatus\": \"${HTTPSTATUS}\"}"
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

        if [[ "$MODE" == "range" ]]; then
            if [[ ! "$TEMP_VAL" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                echo -e "${RED}Error: Format must be x.x.x.x-y.y.y.y${NC}"
                continue
            fi
            local RANGE_START
            RANGE_START=$(echo "$TEMP_VAL" | cut -d'-' -f1)
            if ! is_in_same_subnet "$VIP" "$RANGE_START"; then
                echo -e "${RED}Error: LB Range must be in the same subnet as VIP ($VIP).${NC}"
                continue
            fi
        fi

        eval "$VAR_NAME=\"$TEMP_VAL\""
        break
    done
}

# ============================================================
# HELPER: subnet check
# ============================================================
is_in_same_subnet() {
    local ip1=$1
    local ip2=$2
    # Masks to the first 3 octets (255.255.255.0)
    # This is typical for NKP deployments; modify if your network uses different CIDR
    [[ "${ip1%.*}" == "${ip2%.*}" ]]
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
    echo "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
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

BUNDLE_FILE=$(ls nkp-bundle_v*.tar.gz 2>/dev/null | head -n 1)
if [ -z "$BUNDLE_FILE" ]; then
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

get_input "Prism Central Endpoint (IP): "       PC_ENDPOINT
get_input "Prism Username: "                     NUTANIX_USER

# Password — never stored, no default shown
while [[ -z "$NUTANIX_PASSWORD" ]]; do
    echo -ne "${YELLOW}Prism Password: ${NC}"
    read -rs NUTANIX_PASSWORD
    echo ""
done

get_input "NKP Cluster Name (lowercase only): " CLUSTER_NAME "lowercase"
get_input "Control Plane VIP: "                  VIP
get_input "VM Image Name (.qcow2): "             VM_IMAGE
get_input "AHV Cluster Name: "                   AHV_CLUSTER
get_input "Network Name: "                       NETWORK
get_input "Storage Container: "                  STORAGE
get_input "LB IP Range (x.x.x.x-y.y.y.y): "    LB_RANGE "range"

# OPTIONAL: DEPLOYMENT SIZING
echo -e "${YELLOW}=======================================================${NC}"
echo -e "${CYAN}      OPTIONAL: Deployment Sizing${NC}"
echo -e "${YELLOW}(Press Enter to use defaults)${NC}"
echo -e "${YELLOW}=======================================================${NC}"

# Control plane replicas — default from saved or fall back to 1
CP_REPLICAS_DEFAULT=$(get_default "cp_replicas")
CP_REPLICAS_DEFAULT=${CP_REPLICAS_DEFAULT:-1}
while true; do
    read -p "Control Plane Replicas (1, 3, or 5 - default: ${CP_REPLICAS_DEFAULT}): " CP_REPLICAS
    CP_REPLICAS=${CP_REPLICAS:-$CP_REPLICAS_DEFAULT}
    if [[ "$CP_REPLICAS" =~ ^[135]$ ]]; then
        break
    fi
    echo -e "${RED}Error: Control plane replicas must be an odd number (1, 3, or 5) for proper quorum.${NC}"
done

# Worker replicas — default from saved or fall back to 3
WORKER_REPLICAS_DEFAULT=$(get_default "worker_replicas")
WORKER_REPLICAS_DEFAULT=${WORKER_REPLICAS_DEFAULT:-3}
while true; do
    read -p "Worker Replicas (1-10, default: ${WORKER_REPLICAS_DEFAULT}): " WORKER_REPLICAS
    WORKER_REPLICAS=${WORKER_REPLICAS:-$WORKER_REPLICAS_DEFAULT}
    if [[ "$WORKER_REPLICAS" =~ ^([1-9]|10)$ ]]; then
        break
    fi
    echo -e "${RED}Error: Must be a number between 1 and 10.${NC}"
done

# ============================================================
# SAVE DEFAULTS — written immediately after inputs, before any API calls
# ============================================================
save_defaults
echo -e "${GREEN}--> Inputs saved to ${DEFAULTS_FILE}${NC}"

# Set v4 API credentials from collected inputs
PCIPADDRESS="$PC_ENDPOINT"
PCADMIN="$NUTANIX_USER"
PCPASSWD="$NUTANIX_PASSWORD"

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
        read -p "Proceed with deployment? (Y/n) > " CONFIRM
        [[ "$CONFIRM" =~ ^[Nn]$ ]] && exit 0
        break
    else
        # validate_vm_image already printed the candidate list
        read -p "Enter correct VM Image Name: " NEW_IMAGE
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
