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
          defaultPackages = [
            zig
            pkgs.sqlite
            pkgs.c-ares
            pkgs.boringssl
            pkgs.liburing
            pkgs.opentracker
            pkgs.python3
            pkgs.curl
            pkgs.diffutils
            pkgs.pkg-config
            pkgs.git
          ];
        in
        {
          default = pkgs.mkShell {
            packages = defaultPackages;

            shellHook = ''
              echo "varuna devshell — zig $(zig version)"
            '';
          };

          performance-tools = pkgs.mkShell {
            packages = defaultPackages ++ [
              pkgs.strace
              pkgs.perf
              pkgs.qbittorrent-nox
            ];

            shellHook = ''
              echo "varuna performance devshell — zig $(zig version)"
            '';
          };
        });
    };
}
