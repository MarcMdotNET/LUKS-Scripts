#!/bin/bash

# Function to display usage information and detailed description
usage() {
    echo "Usage: $0 -v <luks_volume_name> ..."
    echo "  -v <luks_volume_name>        Specify the LUKS volume name (e.g., luks-aa909243-8b84-4459-934b-0569fba01b84)"
    echo "  -h                           Display this help message and exit"
    echo
    echo "Description:"
    echo "  This script sets up automatic boot for multiple existing LUKS2-encrypted volumes without requiring a password at boot."
    echo "  It performs the following steps for each volume:"
    echo "  1. Identifies the device corresponding to the LUKS volume."
    echo "  2. Creates a key file with random data."
    echo "  3. Adds the key file to the existing LUKS2-encrypted volume."
    echo "  4. Moves the key file to the /boot partition and sets appropriate permissions."
    echo "  5. Updates dracut configuration to include the key files in initramfs."
    echo "  6. Rebuilds the initramfs to include the new key configuration."
    echo "  7. Updates the GRUB configuration to apply changes."
    echo
    echo "Requirements:"
    echo "  - The script must be run as root."
    echo "  - The /boot partition must be unencrypted and writable."
    echo
    echo "Example:"
    echo "  sudo $0 -v luks-aa909243-8b84-4459-934b-0569fba01b84 -v luks-7c4658d5-14fe-4ea5-9393-219966dc7f24"
    exit 1
}

# Initialize arrays to hold volume names and devices
declare -a VOLUME_NAMES
declare -a DEVICES
declare -a KEYFILES

# Parse command-line arguments
while getopts "v:h" opt; do
    case ${opt} in
        v )
            VOLUME_NAME="$OPTARG"
            if [ -z "$VOLUME_NAME" ]; then
                usage
            fi
            VOLUME_NAMES+=("$VOLUME_NAME")
            KEYFILES+=("/boot/crypto_keyfile_${VOLUME_NAME}.bin")
            ;;
        h )
            usage
            ;;
        * )
            usage
            ;;
    esac
done

# Check if at least one volume name is provided
if [ ${#VOLUME_NAMES[@]} -eq 0 ]; then
    usage
fi

KEYFILE_DIR="/boot"
CRYPTTAB="/etc/crypttab"
BACKUP_CRYPTTAB="/etc/crypttab.backup.$(date +%F-%T)"
DRACUT_CONF="/etc/dracut.conf.d/10-crypt.conf"

# Function to display error and exit
error_exit() {
    echo "$1" 1>&2
    exit 1
}

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root"
fi

# Check if cryptsetup is installed
if ! command -v cryptsetup &> /dev/null; then
    error_exit "cryptsetup could not be found. Please install cryptsetup and try again."
fi

# Identify devices corresponding to the specified LUKS volume names
for VOLUME_NAME in "${VOLUME_NAMES[@]}"; do
    echo "Identifying device for $VOLUME_NAME..."
    DEVICE=$(blkid -t UUID="${VOLUME_NAME#luks-}" -o device)
    if [ -z "$DEVICE" ]; then
        error_exit "Device for LUKS volume $VOLUME_NAME not found."
    fi
    DEVICES+=("$DEVICE")
done

# Validate all identified devices and volumes
for i in "${!DEVICES[@]}"; do
    DEVICE="${DEVICES[$i]}"
    VOLUME_NAME="${VOLUME_NAMES[$i]}"

    echo "Validating $DEVICE ($VOLUME_NAME)..."

    # Check if the device exists
    if [ ! -b "$DEVICE" ]; then
        error_exit "Device $DEVICE does not exist."
    fi

    # Check if the LUKS volume is valid
    if ! cryptsetup isLuks "$DEVICE"; then
        error_exit "Device $DEVICE is not a valid LUKS volume."
    fi

    # Check if the volume name matches the LUKS volume UUID
    VOLUME_UUID=$(cryptsetup luksUUID "$DEVICE")
    if [ "$VOLUME_UUID" != "${VOLUME_NAME#luks-}" ]; then
        error_exit "LUKS volume name $VOLUME_NAME does not match the UUID $VOLUME_UUID for device $DEVICE."
    fi
done

# Backup the current /etc/crypttab
cp "$CRYPTTAB" "$BACKUP_CRYPTTAB" || error_exit "Failed to backup /etc/crypttab"

# Remove existing incorrect entries in /etc/crypttab
for VOLUME_NAME in "${VOLUME_NAMES[@]}"; do
    sed -i "/${VOLUME_NAME}/d" "$CRYPTTAB"
done

# Proceed with configuration after validation
for i in "${!DEVICES[@]}"; do
    DEVICE="${DEVICES[$i]}"
    VOLUME_NAME="${VOLUME_NAMES[$i]}"
    KEYFILE="${KEYFILES[$i]}"

    echo "Processing $DEVICE ($VOLUME_NAME)..."

    # Create a key file with random data
    if ! dd if=/dev/urandom of="$KEYFILE" bs=512 count=4; then
        error_exit "Failed to create key file for $VOLUME_NAME. Restoring original /etc/crypttab..."
        mv "$BACKUP_CRYPTTAB" "$CRYPTTAB"
        exit 1
    fi

    # Set the key file permissions
    chmod 0400 "$KEYFILE" || error_exit "Failed to set permissions for $KEYFILE"

    # Add the key file to the LUKS volume
    if ! cryptsetup luksAddKey "$DEVICE" "$KEYFILE"; then
        error_exit "Failed to add key file to LUKS volume $VOLUME_NAME. Restoring original /etc/crypttab..."
        mv "$BACKUP_CRYPTTAB" "$CRYPTTAB"
        exit 1
    fi

    # Get the UUID of the LUKS device
    UUID=$(blkid -s UUID -o value "$DEVICE") || error_exit "Failed to get UUID of the device $DEVICE"

    # Add entry to /etc/crypttab
    echo "$VOLUME_NAME UUID=$UUID $KEYFILE luks,discard" >> "$CRYPTTAB" || error_exit "Failed to update /etc/crypttab for $VOLUME_NAME"

    echo "Finished processing $DEVICE ($VOLUME_NAME)"
done

# Update dracut configuration for LUKS support
{
    echo 'add_dracutmodules+=" crypt "'
    echo -n 'install_items+=" '
    for KEYFILE in "${KEYFILES[@]}"; do
        echo -n "$KEYFILE "
    done
    echo '"'
} > "$DRACUT_CONF" || error_exit "Failed to create dracut configuration $DRACUT_CONF"

# Recreate the initramfs
dracut --force || error_exit "Failed to update initramfs"

# Verify that key files are included in the initramfs
for KEYFILE in "${KEYFILES[@]}"; do
    if ! lsinitrd | grep -q "$(basename "$KEYFILE")"; then
        error_exit "Key file $KEYFILE is not included in the initramfs"
    fi
done

# Update GRUB configuration
grub2-mkconfig -o /boot/grub2/grub.cfg || error_exit "Failed to update GRUB configuration"

echo "Configuration completed successfully. Please reboot to verify the changes."
