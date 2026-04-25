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
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      zig = zig-overlay.packages.${system}."0.15.2";
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          zig
          pkgs.sqlite
          pkgs.liburing
          pkgs.pkg-config
          pkgs.git
        ];

        shellHook = ''
          echo "varuna devshell — zig $(zig version)"
        '';
      };
    };
}
