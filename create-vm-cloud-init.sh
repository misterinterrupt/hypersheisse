#!/bin/bash

# Bash script to manage Multipass VMs using cloud-init configuration

# Function to display usage
usage() {
    echo "Usage: $0 -n <vmName> [-o <osImagePath>] [-i] [-x]"
    echo "  -n <vmName>       : Name of the VM"
    echo "  -o <osImagePath>  : Path to the OS image (optional)"
    echo "  -i                : Interactive mode"
    echo "  -x                : Include configuration.nix and flake.nix"
    exit 1
}

# Parse CLI arguments
while getopts "n:o:ix" opt; do
    case $opt in
        n) vmName="$OPTARG" ;;
        o) osImagePath="$OPTARG" ;;
        i) interactive=true ;;
        x) includeNixFiles=true ;;
        *) usage ;;
    esac
done

# Interactive mode
if [ "$interactive" = true ]; then
    echo "Welcome to the VM management script!"
    echo "Choose an action:"
    echo "1. Create a new VM"
    echo "2. Destroy an existing VM"
    read -p "Select an option (1 or 2): " actionOption

    if [ "$actionOption" = "1" ]; then
        # Prompt for VM name if not provided via CLI
        if [ -z "$vmName" ]; then
            read -p "Enter the VM name: " vmName
            if [ -z "$vmName" ]; then
                echo "Error: You must provide a VM name."
                exit 1
            fi
        fi

        # Prompt for OS image path if not provided via CLI
        if [ -z "$osImagePath" ]; then
            echo "Do you want to specify an OS image path?"
            echo "1. Yes"
            echo "2. No"
            read -p "Select an option (1 or 2): " imageOption

            if [ "$imageOption" = "1" ]; then
                read -p "Enter the OS image path: " osImagePath
                if [ -z "$osImagePath" ]; then
                    echo "Error: You must provide an OS image path."
                    exit 1
                fi
                if [ ! -f "$osImagePath" ]; then
                    echo "Error: The file at path '$osImagePath' does not exist."
                    exit 1
                fi
            else
                osImagePath=""
            fi
        fi

        # Always prompt for Nix inclusion in interactive mode after the image path is provided
        if [ -f "configuration.nix" ] && [ -f "flake.nix" ]; then
            read -p "Do you want to include configuration.nix and flake.nix in the VM? (yes/no): " includeNixFilesPrompt
            if [ "$includeNixFilesPrompt" = "yes" ]; then
                includeNixFiles=true
            fi
        else
            echo "configuration.nix or flake.nix not found. Skipping inclusion in the cloud-init file."
        fi
    elif [ "$actionOption" = "2" ]; then
        echo "Fetching VMs with identifier '-hs-'..."

        # Debugging: Output the raw list of VMs
        rawVms=$(multipass list | tail -n +2 | awk '{$1=$1; print}')
        echo -e "Debug: Raw VM list:\n$rawVms"

        # Extract only the VM names (first column)
        vmNames=$(echo "$rawVms" | awk '{print $1}')
        echo -e "Debug: Extracted VM names:\n$vmNames"

        # Use Bash-only regex matching for VM names
        vms=$(echo "$vmNames" | while read -r line; do
            if [[ $line =~ -hs-[A-Za-z0-9]{8}$ ]]; then
                echo "$line"
            fi
        done)

        echo -e "Debug: Matched VMs:\n$vms"

        if [ -z "$vms" ]; then
            echo "No VMs found with the identifier '-hs-'."
            exit 0
        fi

        echo "Select a VM to destroy:"
        select vmToDestroy in $vms; do
            if [ -n "$vmToDestroy" ]; then
                echo "You selected: $vmToDestroy"
                read -p "Type 'yes' to confirm deletion: " confirmation
                if [ "$confirmation" = "yes" ]; then
                    echo "Destroying VM: $vmToDestroy..."
                    multipass delete "$vmToDestroy"
                    multipass purge
                    echo "VM $vmToDestroy has been destroyed."
                else
                    echo "Deletion cancelled."
                fi
                break
            else
                echo "Invalid selection."
            fi
        done
        exit 0
    else
        echo "Invalid option."
        exit 1
    fi
fi

# Validate VM name
if [ -z "$vmName" ]; then
    echo "Error: You must provide a VM name."
    usage
fi

# Validate osImagePath if includeNixFiles is set
if [ "$includeNixFiles" = true ] && [ -z "$osImagePath" ]; then
    echo "Error: The -x option requires the -o option to be set."
    usage
fi

# Generate a unique identifier for the VM
randomKey=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)
vmName="$vmName-hs-$randomKey"

# Validate VM name to ensure it doesn't end with a hyphen
if [[ "$vmName" =~ -$ ]]; then
    echo "Error: Invalid VM name generated: $vmName"
    exit 1
fi

echo "VM Name: $vmName"

# Debugging: Output the VM name
echo "Debug: VM Name is $vmName"

# Variables
sshKeyPath="$HOME/.ssh/multipass-ssh-key.pub"
sshPrivateKeyPath="$HOME/.ssh/multipass-ssh-key"
sshConfigPath="$HOME/.ssh/config"

# Generate SSH key if it doesn't exist
echo "Checking if SSH key exists in $HOME/.ssh/..."
if [ ! -f "$sshPrivateKeyPath" ]; then
    echo "Generating SSH key for VM user in $HOME/.ssh/..."
    ssh-keygen -C "vmuser" -f "$sshPrivateKeyPath" -N ""
else
    echo "SSH key already exists in $HOME/.ssh/. Using existing key."
fi

# Create cloud-init configuration file
echo "Creating cloud-init configuration file..."
publicKeyContent=$(cat "$sshKeyPath")

if [ -n "$osImagePath" ]; then
    echo "Adding OS image configuration to cloud-init file..."
    cloudInitContent="""
users:
  - default
  - name: vmuser
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
    - $publicKeyContent
system:
  image: $osImagePath
"""
else
    cloudInitContent="""
users:
  - default
  - name: vmuser
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
    - $publicKeyContent
"""
fi

if [ "$includeNixFiles" = true ]; then
    if [ -f "configuration.nix" ] && [ -f "flake.nix" ]; then
        echo "Including configuration.nix and flake.nix in the VM..."
        cloudInitContent+="""
write_files:
  - path: /etc/nixos/configuration.nix
    content: |
$(sed 's/^/      /' configuration.nix)
  - path: /etc/nixos/flake.nix
    content: |
$(sed 's/^/      /' flake.nix)
runcmd:
  - nixos-rebuild switch
"""
    else
        echo "Error: configuration.nix or flake.nix not found. Cannot include them in the VM."
        exit 1
    fi
fi

# Save the cloud-init file with the full VM name and confirm overwrite
cloudInitPath="$(pwd)/$vmName-cloud-init.yaml"
if [ -f "$cloudInitPath" ]; then
    read -p "Cloud-init file already exists at $cloudInitPath. Overwrite? (yes/no): " overwrite
    if [ "$overwrite" != "yes" ]; then
        echo "Aborting operation."
        exit 1
    fi
fi

# Debugging: Output the cloud-init path
echo "Debug: Cloud-init file will be saved to $cloudInitPath"

echo "Saving cloud-init configuration to: $cloudInitPath"
echo "$cloudInitContent" > "$cloudInitPath"

# Launch the VM with the updated cloud-init configuration
echo "Launching Multipass VM: $vmName with cloud-init configuration..."
multipass launch -n "$vmName" --cloud-init "$cloudInitPath"

# Get the IP address of the VM
echo "Fetching IP address of the VM..."
vmIP=$(multipass info "$vmName" | grep "IPv4" | awk -F: '{print $2}' | xargs)
if [ -z "$vmIP" ]; then
    echo "Error: Failed to fetch the IP address of the VM."
    exit 1
fi
echo "VM IP Address: $vmIP"

# Add VM to SSH config
echo "Adding VM to SSH config..."
if [ -f "$sshConfigPath" ] && [ -s "$sshConfigPath" ]; then
    lastChar=$(tail -c 1 "$sshConfigPath")
    if [ "$lastChar" != "" ]; then
        echo >> "$sshConfigPath"
    fi
fi

sshConfigEntry="""
Host $vmName
    HostName $vmIP
    User vmuser
    IdentityFile $sshPrivateKeyPath
    PubkeyAuthentication yes
"""
echo "$sshConfigEntry" >> "$sshConfigPath"
echo >> "$sshConfigPath"

# Output SSH command
echo "Setup complete. Use the following command to access the VM:"
echo "ssh $vmName"
