{
  description = "System configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }@inputs: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        { nix.nixPath = [ "nixpkgs=${inputs.nixpkgs}" ]; }
        ./configuration.nix
      ];
    };
  };
}
