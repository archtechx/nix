# This config only configures the server, it will not be placed in /etc/nixos
# It should include everything needed to:
# - connect to the server
# - configure the server further

{ modulesPath, lib, pkgs, ... }: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disk-config.nix
  ];

  boot.loader.grub = {
    # no need to set devices, disko will add all devices that have a EF02 partition to the list already
    # devices = [ ];
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  environment.systemPackages = map lib.lowPrio [
    pkgs.vim
    pkgs.curl
    pkgs.git
  ];

  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    # REPLACEME
  ];

  system.stateVersion = "25.05";
}
