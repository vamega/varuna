{
  description = "varuna BitTorrent daemon";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zig-overlay }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          zig = zig-overlay.packages.${system}."0.15.2";
        in
        {
          default = pkgs.mkShell {
            packages = [
              zig
              pkgs.sqlite
              pkgs.c-ares
              pkgs.boringssl
              pkgs.liburing
              pkgs.opentracker
              pkgs.python3
              pkgs.pkg-config
              pkgs.git
            ];

            shellHook = ''
              echo "varuna devshell — zig $(zig version)"
            '';
          };
        });
    };
}
