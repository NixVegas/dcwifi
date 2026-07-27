{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs =
    { nixpkgs, ... }@inputs:
    let
      # The dcwifi module is arch-agnostic, but the VM test can only *run* where
      # the NixOS test driver does (KVM-backed qemu): x86_64 and aarch64.
      testSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forTestSystems = f: nixpkgs.lib.genAttrs testSystems f;
    in
    {
      checks = forTestSystems (system: {
        default = nixpkgs.legacyPackages.${system}.callPackage ./nixos/tests inputs;
      });
      nixosModules.default = import ./nixos/modules;
    };
}
