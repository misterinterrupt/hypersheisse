# PowerShell script to manage Multipass VMs using cloud-init configuration

# Accept CLI arguments for VM name, OS image path, and interactive mode
param(
    [string]$vmName = $null,  # Optional VM name
    [string]$osImagePath = $null,  # Optional OS image path
    [switch]$i,  # Flag for interactive mode
    [switch]$includeNixFiles  # Flag to include configuration.nix and flake.nix without prompting
)

# Define the identifier as a variable
$identifier = "hs"

# Interactive mode
if ($i) {
    Write-Host "Welcome to the VM management script!"
    Write-Host "Choose an action:"
    Write-Host "1. Create a new VM"
    Write-Host "2. Destroy an existing VM"
    $actionOption = Read-Host "Select an option (1 or 2)"

    if ($actionOption -eq "1") {
        # Prompt for VM name if not provided via CLI
        if (-not $vmName) {
            $vmName = Read-Host "Enter the VM name"
            if (-not $vmName) {
                Write-Error 'Error: You must provide a VM name.'
                exit 1
            }
        }

        # Prompt for OS image path if not provided via CLI
        if (-not $osImagePath) {
            Write-Host "Do you want to specify an OS image path?"
            Write-Host "1. Yes"
            Write-Host "2. No"
            $imageOption = Read-Host "Select an option (1 or 2)"

            if ($imageOption -eq "1") {
                $osImagePath = Read-Host "Enter the OS image path"
                if (-not $osImagePath) {
                    Write-Error 'Error: You must provide an OS image path.'
                    exit 1
                }
                if (-not (Test-Path $osImagePath)) {
                    Write-Error "Error: The file at path '$osImagePath' does not exist."
                    exit 1
                }
            } else {
                $osImagePath = $null
            }
        }

        # Always prompt for Nix inclusion in interactive mode after the image path is provided
        if (Test-Path "$PSScriptRoot\configuration.nix" -and Test-Path "$PSScriptRoot\flake.nix") {
            $includeNixFilesPrompt = Read-Host "Do you want to include configuration.nix and flake.nix in the VM? (yes/no)"
            if ($includeNixFilesPrompt -eq "yes") {
                Write-Host "Adding configuration.nix and flake.nix to cloud-init file..."
                $cloudInitContent += @"
write_files:
  - path: /etc/nixos/configuration.nix
    content: |
$(Get-Content -Raw -Path "$PSScriptRoot\configuration.nix" | ForEach-Object { "      $_" })
  - path: /etc/nixos/flake.nix
    content: |
$(Get-Content -Raw -Path "$PSScriptRoot\flake.nix" | ForEach-Object { "      $_" })
runcmd:
  - nixos-rebuild switch
"@
            }
        } else {
            Write-Host "configuration.nix or flake.nix not found. Skipping inclusion in the cloud-init file."
        }
    } elseif ($actionOption -eq "2") {
        # List all VMs with the identification scheme
        Write-Host "Fetching VMs with identifier '$identifier'..."
        $vms = multipass list | Select-String -Pattern "^.+-$identifier-[a-f0-9]{8}$" | ForEach-Object { ($_ -split "\s+")[0] }

        if (-not $vms) {
            Write-Host "No VMs found with the identifier '$identifier'."
            exit 0
        }

        Write-Host "Select a VM to destroy:"
        for ($i = 0; $i -lt $vms.Count; $i++) {
            Write-Host "$i. $($vms[$i])"
        }

        $vmIndex = Read-Host "Enter the number of the VM to destroy"
        if (-not ($vmIndex -as [int]) -or $vmIndex -lt 0 -or $vmIndex -ge $vms.Count) {
            Write-Error "Invalid selection."
            exit 1
        }

        $vmToDestroy = $vms[$vmIndex]
        Write-Host "You selected: $vmToDestroy"
        $confirmation = Read-Host "Type 'yes' to confirm deletion"
        if ($confirmation -eq "yes") {
            Write-Host "Destroying VM: $vmToDestroy..."
            multipass delete $vmToDestroy
            multipass purge
            Write-Host "VM $vmToDestroy has been destroyed."
        } else {
            Write-Host "Deletion cancelled."
        }
        exit 0
    } else {
        Write-Error "Invalid option."
        exit 1
    }
}

# Validate VM name
if (-not $vmName) {
    Write-Error 'Error: You must provide a VM name.'
    Write-Host  'Usage: .\create-vm-cloud-init.ps1 -vmName <YourVMName> [-osImagePath <PathToOSImage>] [-includeNixFiles]'
    Write-Host  'Usage (interactive mode): .\create-vm-cloud-init.ps1 -i'
    exit 1
}

# Validate that osImagePath is provided if includeNixFiles is set
if ($includeNixFiles -and -not $osImagePath) {
    Write-Error 'Error: The -includeNixFiles option requires the -osImagePath option to be set.'
    Write-Host 'Usage: .\create-vm-cloud-init.ps1 -vmName <YourVMName> -osImagePath <PathToOSImage> -includeNixFiles'
    exit 1
}

# Generate a unique identifier for the VM
$randomKey = [guid]::NewGuid().ToString().Split('-')[0]  # Use the first segment of the UUID
$vmName = "$vmName-$identifier-$randomKey"

# Output the modified VM name
Write-Host "VM Name: $vmName"

# Variables
$sshKeyPath = "$HOME\.ssh\multipass-ssh-key.pub"
$sshPrivateKeyPath = "$HOME\.ssh\multipass-ssh-key"
$sshConfigPath = "$HOME\.ssh\config"

# Generate SSH key if it doesn't exist
Write-Host "Checking if SSH key exists in $HOME\.ssh\..."
if (!(Test-Path $sshPrivateKeyPath)) {
    Write-Host "Generating SSH key for VM user in $HOME\.ssh\..."
    ssh-keygen -C "vmuser" -f $sshPrivateKeyPath -N ""
} else {
    Write-Host "SSH key already exists in $HOME\.ssh\. Using existing key."
}

# Create cloud-init configuration file
Write-Host "Creating cloud-init configuration file..."
$publicKeyContent = Get-Content $sshKeyPath

# Remove the --image option and handle the OS image path via cloud-init
if ($osImagePath) {
    Write-Host "Adding OS image configuration to cloud-init file..."
    $cloudInitContent = @"
users:
  - default
  - name: vmuser
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
    - $publicKeyContent
system:
  image: $osImagePath
"@
} else {
    $cloudInitContent = @"
users:
  - default
  - name: vmuser
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
    - $publicKeyContent
"@
}

# Include configuration.nix and flake.nix if the flag is set
if ($includeNixFiles) {
    if (Test-Path "$PSScriptRoot\configuration.nix" -and Test-Path "$PSScriptRoot\flake.nix") {
        Write-Host "Including configuration.nix and flake.nix in the VM..."
        $cloudInitContent += @"
write_files:
  - path: /etc/nixos/configuration.nix
    content: |
$(Get-Content -Raw -Path "$PSScriptRoot\configuration.nix" | ForEach-Object { "      $_" })
  - path: /etc/nixos/flake.nix
    content: |
$(Get-Content -Raw -Path "$PSScriptRoot\flake.nix" | ForEach-Object { "      $_" })
runcmd:
  - nixos-rebuild switch
"@
    } else {
        Write-Error "configuration.nix or flake.nix not found. Cannot include them in the VM."
        exit 1
    }
}

# Save the cloud-init file with the full VM name and confirm overwrite
$cloudInitPath = "$PWD\$vmName-cloud-init.yaml"
if (Test-Path $cloudInitPath) {
    $overwrite = Read-Host "Cloud-init file already exists at $cloudInitPath. Overwrite? (yes/no)"
    if ($overwrite -ne "yes") {
        Write-Host "Aborting operation."
        exit 1
    }
}
Write-Host "Saving cloud-init configuration to: $cloudInitPath"
Set-Content -Path $cloudInitPath -Value $cloudInitContent

# Launch the VM with the updated cloud-init configuration
Write-Host "Launching Multipass VM: $vmName with cloud-init configuration..."
multipass launch -n $vmName --cloud-init $cloudInitPath

# Get the IP address of the VM
Write-Host "Fetching IP address of the VM..."
$vmIP = multipass info $vmName | Select-String -Pattern "IPv4" | ForEach-Object { ($_ -split ":")[1].Trim() }
if (-not $vmIP) {
    Write-Error "Failed to fetch the IP address of the VM."
    exit 1
}
Write-Host "VM IP Address: $vmIP"

# Add VM to SSH config
Write-Host "Adding VM to SSH config..."
if ((Test-Path $sshConfigPath) -and ((Get-Content $sshConfigPath).Length -gt 0)) {
    $lastChar = (Get-Content $sshConfigPath -Raw).TrimEnd()
    if ($lastChar -ne "") {
        Add-Content -Path $sshConfigPath -Value "`n"
    }
}

$sshConfigEntry = @"
Host $vmName
    HostName $vmIP
    User vmuser
    IdentityFile $sshPrivateKeyPath
    PubkeyAuthentication yes
"@
Add-Content -Path $sshConfigPath -Value $sshConfigEntry
Add-Content -Path $sshConfigPath -Value "`n"

# Output SSH command
Write-Host "Setup complete. Use the following command to access the VM:"
Write-Host "ssh $vmName"
