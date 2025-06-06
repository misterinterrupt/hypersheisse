# PowerShell script to create a Multipass VM using cloud-init configuration

# Accept VM name as a command-line argument
param(
    [string]$vmName  # No default value, VM name is required
)

# Check if VM name is provided
if (-not $vmName) {
    Write-Error 'Error: You must provide a VM name.'
    Write-Host  'Usage: .\create-vm-cloud-init.ps1 -vmName <YourVMName>
'
    exit 1
}

# Variables
$sshKeyPath = "$HOME\multipass-ssh-key.pub"
$sshPrivateKeyPath = "$HOME\multipass-ssh-key"
$cloudInitPath = "$HOME\multipass-cloud-init.yaml"
$sshConfigPath = "$HOME\.ssh\config"

# Generate SSH key if it doesn't exist
Write-Host "Checking if SSH key exists..."
if (!(Test-Path $sshPrivateKeyPath)) {
    Write-Host "Generating SSH key for VM user..."
    ssh-keygen -C "vmuser" -f $sshPrivateKeyPath -N ""
} else {
    Write-Host "SSH key already exists. Using existing key."
}

# Create cloud-init configuration file
Write-Host "Creating cloud-init configuration file..."
$publicKeyContent = Get-Content $sshKeyPath
$cloudInitContent = @"
users:
  - default
  - name: vmuser
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
    - $publicKeyContent
"@
Set-Content -Path $cloudInitPath -Value $cloudInitContent

# Launch the VM with cloud-init configuration
Write-Host "Launching Multipass VM: $vmName with cloud-init configuration..."
multipass launch -n $vmName --cloud-init $cloudInitPath

# Get the IP address of the VM
Write-Host "Fetching IP address of the VM..."
$vmIP = multipass info $vmName | Select-String -Pattern "IPv4" | ForEach-Object { ($_ -split ":")[1].Trim() }
Write-Host "VM IP Address: $vmIP"

# Add VM to SSH config
Write-Host "Adding VM to SSH config..."
# Ensure a newline after existing entries if the file is not empty
if (Test-Path $sshConfigPath -and (Get-Content $sshConfigPath).Length -gt 0) {
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
