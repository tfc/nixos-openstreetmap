{ config, modulesPath, ... }:

{
  imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ];

  virtualisation.forwardPorts = [
    { from = "host"; host.port = 8080; guest.port = 80; }
    { from = "host"; host.port = 2222; guest.port = 22; }
  ];

  virtualisation.memorySize = 4096;
  virtualisation.diskSize = 100000;

  networking.firewall.enable = false;

  users.users.root.initialPassword = "";

  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";

  system.stateVersion = "23.05";
}
