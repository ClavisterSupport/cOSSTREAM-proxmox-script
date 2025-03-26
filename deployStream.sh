#!/bin/bash
# Ensure dependencies are installed
if ! command -v whiptail &>/dev/null; then
    echo "Installing whiptail..."
    apt-get update && apt-get install -y whiptail
fi

# ----------------------------
# Cleanup function
# ----------------------------
TEMP_FILE=""
OVA_EXTRACT_DIR="/tmp/ova_extract"

cleanup() {
    [[ -f "$TEMP_FILE" ]] && rm -f "$TEMP_FILE"
    [[ -d "$OVA_EXTRACT_DIR" ]] && rm -rf "$OVA_EXTRACT_DIR"
}
trap cleanup EXIT

# ----------------------------
# Get User Input via Whiptail
# ----------------------------
whiptail --title "Clavister Firewall VM" --yesno "This will create a new Clavister Firewall VM. Proceed?" 10 50 || exit 1
 
# Get login details
USERNAME=$(whiptail --title "https://my.clavister.com" --inputbox "Enter Clavister Username:" 10 50 "" 3>&1 1>&2 2>&3) || exit 1
PASSWORD=$(whiptail --title "https://my.clavister.com" --passwordbox "Enter Clavister Password:" 10 50 3>&1 1>&2 2>&3) || exit 1
 
# ----------------------------
# Deployment Mode: Single or HA
# ----------------------------
DEPLOY_MODE=$(whiptail --title "Deployment Mode" --menu "Choose deployment mode:" 15 50 2 \
"1" "Single" \
"2" "High Availability (HA)" 3>&1 1>&2 2>&3) || exit 1
 
if [[ "$DEPLOY_MODE" == "2" ]]; then
    VM_ID_MASTER=$(whiptail --inputbox "Enter Master VM ID (e.g., 9000):" 10 50 "9000" 3>&1 1>&2 2>&3) || exit 1
    VM_ID_SLAVE=$(whiptail --inputbox "Enter Slave VM ID (e.g., 9001):" 10 50 "9001" 3>&1 1>&2 2>&3) || exit 1
    if [[ "$VM_ID_MASTER" == "$VM_ID_SLAVE" ]]; then
        echo "❌ Master and Slave VM IDs must be different."
        exit 1
    fi
 
    VM_NAME_MASTER="clavister-firewall-master"
    VM_NAME_SLAVE="clavister-firewall-slave"
 
    # Minimum 2 interfaces for HA
    INTERFACE_COUNT=$(whiptail --inputbox "Enter Number of Network Interfaces (min 2 for HA):" 10 50 "2" 3>&1 1>&2 2>&3) || exit 1
    if [[ "$INTERFACE_COUNT" -lt 2 ]]; then
        echo "❌ HA requires at least 2 network interfaces."
        exit 1
    fi
 
    # Create sync bridge (with promiscuous mode)
    SYNC_BRIDGE="Sync${VM_ID_MASTER}${VM_ID_SLAVE}"
    echo "Creating sync bridge: $SYNC_BRIDGE..."
    if ! ip link show "$SYNC_BRIDGE" &>/dev/null; then
        ip link add name "$SYNC_BRIDGE" type bridge || { echo "❌ Failed to create sync bridge"; exit 1; }
        ip link set "$SYNC_BRIDGE" up
        ip link set "$SYNC_BRIDGE" promisc on  # Enable promiscuous mode
    fi
 
else
    VM_ID=$(whiptail --inputbox "Enter VM ID (e.g., 9000):" 10 50 "9000" 3>&1 1>&2 2>&3) || exit 1
    VM_NAME=$(whiptail --inputbox "Enter VM Name:" 10 50 "clavister-firewall" 3>&1 1>&2 2>&3) || exit 1
    INTERFACE_COUNT=$(whiptail --inputbox "Enter Number of Network Interfaces:" 10 50 "1" 3>&1 1>&2 2>&3) || exit 1
fi
 
# Get remaining VM details
STORAGE=$(whiptail --inputbox "Enter Storage Location:" 10 50 "local-lvm" 3>&1 1>&2 2>&3) || exit 1
BRIDGE=$(whiptail --inputbox "Enter Network Bridge:" 10 50 "vmbr0" 3>&1 1>&2 2>&3) || exit 1
RAM_SIZE=$(whiptail --inputbox "Enter RAM Size (MB):" 10 50 "4096" 3>&1 1>&2 2>&3) || exit 1
CPU_CORES=$(whiptail --inputbox "Enter Number of CPU Cores:" 10 50 "4" 3>&1 1>&2 2>&3) || exit 1
 
# ----------------------------
# File Type and Download
# ----------------------------
FIREWALL_TYPE=$(whiptail --title "Select Firewall Type" --menu "Choose an option:" 15 50 2 \
"1" "OVA" \
"2" "QCOW2" 3>&1 1>&2 2>&3) || exit 1
 
if [ "$FIREWALL_TYPE" == "1" ]; then
    FILE_URL="https://my.clavister.com/api/downloads/v1.0/file/68a0f353-31f4-ef11-a436-005056bdfeb0"
    FILE_NAME="clavister.ova"
else
    FILE_URL="https://my.clavister.com/api/downloads/v1.0/file/35fda95c-31f4-ef11-a436-005056bdfeb0"
    FILE_NAME="clavister.qcow2"
fi
 
# ----------------------------
# OAuth Token
# ----------------------------
response=$(wget --quiet --method POST --header 'Content-Type: application/x-www-form-urlencoded' \
--body-data "username=$USERNAME&password=$PASSWORD&grant_type=password" -O - \
'https://my.clavister.com/api/oauth/v1.0/token')
 
bearer_token=$(echo "$response" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)
 
if [ -z "$bearer_token" ]; then
    echo "❌ Failed to retrieve Bearer token."
    exit 1
fi
 
# ----------------------------
# Download file once for HA
# ----------------------------
TEMP_FILE="/tmp/clavister_${FILE_NAME}"
if [[ ! -f "$TEMP_FILE" ]]; then
    echo "Downloading $FILE_URL..."
    wget --header "Authorization: Bearer $bearer_token" -O "$TEMP_FILE" "$FILE_URL" || exit 1
fi
 
# ----------------------------
# Extract and Convert OVA to QCOW2
# ----------------------------
convert_ova() {
    local vm_id=$1
    echo "Extracting OVA..."
    mkdir -p "/tmp/ova_extract"
    tar -xvf "$TEMP_FILE" -C "/tmp/ova_extract"
    VMDK_FILE=$(find /tmp/ova_extract -name '*.vmdk' | head -n 1)
    if [ -z "$VMDK_FILE" ]; then
        echo "❌ No VMDK file found in OVA."
        exit 1
    fi
    echo "Converting VMDK to QCOW2..."
    qm importdisk $vm_id "$VMDK_FILE" "$STORAGE" --format qcow2 || exit 1
}
 
# ----------------------------
# Create VM Function
# ----------------------------
create_vm() {
    local vm_id=$1
    local vm_name=$2
    echo "Creating VM $vm_name with ID $vm_id..."
    qm create $vm_id --name "$vm_name" --memory $RAM_SIZE --cores $CPU_CORES --net0 virtio,bridge=$BRIDGE
    for i in $(seq 1 $((INTERFACE_COUNT - 1))); do
        if [[ "$DEPLOY_MODE" == "2" && "$i" == "1" ]]; then
            qm set "$vm_id" --net$i virtio,bridge="$SYNC_BRIDGE"
        else
            qm set "$vm_id" --net$i virtio,bridge="$BRIDGE"
        fi
    done

    
    if [ "$FIREWALL_TYPE" == "1" ]; then
        convert_ova "$vm_id"
    else
        qm importdisk $vm_id "$TEMP_FILE" "$STORAGE" --format qcow2 || exit 1
    fi
 
    qm set $vm_id --virtio0 "$STORAGE:vm-$vm_id-disk-0"
    qm resize $vm_id virtio0 4G
    qm set $vm_id --bios seabios
    qm set $vm_id --cpu host
    qm set $vm_id --boot order=virtio0
    qm set $vm_id --serial0 socket
}
 
if [[ "$DEPLOY_MODE" == "2" ]]; then
    create_vm "$VM_ID_MASTER" "$VM_NAME_MASTER"
    create_vm "$VM_ID_SLAVE" "$VM_NAME_SLAVE"
else
    create_vm "$VM_ID" "$VM_NAME"
fi
 
echo "✅ Clavister VM(s) successfully created"

# ----------------------------
# Start VM(s)
# ----------------------------
if [[ "$DEPLOY_MODE" == "2" ]]; then
    qm start "$VM_ID_MASTER"
    qm start "$VM_ID_SLAVE"
    echo "✅ Clavister VMs successfully started."
else
    qm start "$VM_ID"
    echo "✅ Clavister VM successfully started."
fi


 
