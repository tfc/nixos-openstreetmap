{
  description = "NixOS OpenStreetMap Instances";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
  };

  outputs = { self, nixpkgs }: {
    packages.x86_64-linux.default = self.nixosConfigurations.osm.config.system.build.vm;

    nixosModules.openstreetmap = import ./openstreetmap.nix;
    nixosModule = import ./openstreetmap.nix;

    nixosConfigurations.osm = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./openstreetmap.nix
        ./qemu-vm.nix
        ./config.nix
      ];
    };
  };
}
