{
  description = "Elixir Envoy Control Plane";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    { self
    , nixpkgs
    ,
    }:
    let
      forAllSystems = generate: nixpkgs.lib.genAttrs [
        "x86_64-linux"

      ]
        (system: generate ({
          pkgs = import nixpkgs { inherit system; };
        }));
    in
    {
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixpkgs-fmt;
      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell {
          shellHook = ''
            # this allows mix to work on the local directory
            mkdir -p .nix-mix .nix-hex
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-mix
            # make hex from Nixpkgs available
            # `mix local.hex` will install hex into MIX_HOME and should take precedence
            export MIX_PATH="${pkgs.beam.packages.erlang.hex}/lib/erlang/lib/hex/ebin"
            export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
            mix local.hex --force
            mix local.rebar --force
            export LANG=C.UTF-8
            # keep your shell history in iex
            export ERL_AFLAGS="-kernel shell_history enabled"
            export MIX_ENV=dev
          '';
          buildInputs = [
            pkgs.elixir
            pkgs.nixpkgs-fmt
            pkgs.envoy
        
          ];
        };
      });

    };
}
