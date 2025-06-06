# PowerShell script to set up a Multipass VM with key-based authentication

# Accept VM name as a command-line argument
param(
    [string]$vmName = "new-vm"  # Default value if no argument is provided
)

# Retrieve user's email from Git config
$gitEmail = git config --get user.email
if (-not $gitEmail) {
    Write-Host "Git email not found. Please configure your Git email using 'git config --global user.email'."
    exit 1
}

# Variables
$sshKeyPath = "$HOME\.ssh\id_rsa_$vmName.pub"
$sshPrivateKeyPath = "$HOME\.ssh\id_rsa_$vmName"
$sshConfigPath = "$HOME\.ssh\config"

# Check if the VM already exists
Write-Host "Checking if VM '$vmName' already exists..."
$existingVMs = multipass list | Select-String -Pattern "^$vmName\s"
if ($existingVMs) {
    Write-Host "VM '$vmName' already exists. Aborting setup."
    exit 1
}

# Check if the SSH key already exists
Write-Host "Checking if SSH key for VM '$vmName' already exists..."
if ((Test-Path $sshPrivateKeyPath) -and (Test-Path $sshKeyPath)) {
    Write-Host "SSH key for VM '$vmName' already exists. Aborting setup."
    exit 1
}

# Create a new Multipass VM
Write-Host "Creating Multipass VM: $vmName"
multipass launch --name $vmName

# Get the IP address of the VM
Write-Host "Fetching IP address of the VM..."
$vmIP = multipass info $vmName | Select-String -Pattern "IPv4" | ForEach-Object { ($_ -split ":")[1].Trim() }
Write-Host "VM IP Address: $vmIP"

# Ensure SSH key exists and is correctly placed
if (!(Test-Path $sshPrivateKeyPath)) {
    Write-Host "Generating a new SSH key for VM: $vmName..."
    ssh-keygen -t rsa -b 4096 -C $gitEmail -f $sshPrivateKeyPath -N ""
} else {
    Write-Host "SSH key already exists for VM: $vmName. Using existing key."
}

# Transfer the public key to the VM
Write-Host "Transferring SSH public key to the VM..."
try {
    multipass exec $vmName -- mkdir -p /home/ubuntu/.ssh
    multipass exec $vmName -- chmod 700 /home/ubuntu/.ssh
    multipass transfer $sshKeyPath ${vmName}:/home/ubuntu/.ssh/authorized_keys
    multipass exec $vmName -- chmod 600 /home/ubuntu/.ssh/authorized_keys
    multipass exec $vmName -- chown ubuntu:ubuntu /home/ubuntu/.ssh
    multipass exec $vmName -- chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys

    # Debug permissions
    Write-Host "Checking permissions of .ssh directory and authorized_keys file..."
    multipass exec $vmName -- ls -ld /home/ubuntu/.ssh
    multipass exec $vmName -- ls -l /home/ubuntu/.ssh/authorized_keys

    # Validate authorized_keys file
    Write-Host "Validating authorized_keys file on the VM..."
    $authorizedKeysContent = multipass exec $vmName -- cat /home/ubuntu/.ssh/authorized_keys
    if ($authorizedKeysContent -match (Get-Content $sshKeyPath)) {
        Write-Host "Public key successfully transferred and validated."
    } else {
        Write-Host "Error: Public key validation failed. Check the authorized_keys file."
        exit 1
    }
} catch {
    Write-Host "Error during SSH key transfer or permissions setup: $_"
    exit 1
}

# Verify SSH configuration
Write-Host "Adding VM to SSH config..."
$sshConfigEntry = @"
Host $vmName
    HostName $vmIP
    User ubuntu
    IdentityFile $sshPrivateKeyPath
    PubkeyAuthentication yes
"@
Add-Content -Path $sshConfigPath -Value $sshConfigEntry

# Output SSH command
Write-Host "Setup complete. Use the following command to access the VM:"
Write-Host "ssh $vmName"
