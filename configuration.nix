{
  imports = [
    ./hardware-configuration.nix
  ];

  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  boot.loader.grub.device = "/dev/sda"; # Adjust as needed

  networking.hostName = "kvm-hypervisor";
  networking.networkmanager.enable = true;

  services.libvirtd.enable = true;
  virtualisation.qemu.package = pkgs.qemu_kvm;

  users.users.root.initialPassword = "root"; # Change this for security

  system.stateVersion = "23.05"; # Adjust to your NixOS version
}
