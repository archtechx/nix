{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.disko.url = "github:nix-community/disko";
  inputs.disko.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, disko, ... }: {
      # See other examples at https://github.com/nix-community/nixos-anywhere-examples/blob/main/flake.nix
      nixosConfigurations.cloud = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          disko.nixosModules.disko
          ./configuration.nix
        ];
      };
    };
}
