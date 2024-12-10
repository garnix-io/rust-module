{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  inputs.crane.url = "github:ipetkov/crane";
  outputs = { self, nixpkgs, crane }:
  let
    lib = nixpkgs.lib;

    rustSubmodule.options = {
      src = lib.mkOption {
        type = lib.types.path;
        description = "A path to the directory containing Cargo.lock, Cargo.toml, and src";
        example = ./.;
      };

      devShellPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        description = "A list of packages to add to this project's devshell (also is added to the `default` devshell)";
        default = [];
      };

      serverCommand = lib.mkOption {
        type = lib.types.str;
        description = "The command to run to start the server in production";
        example = "server --port 7000";
      };
    };
  in {
    garnixModules.default = { pkgs, config, ... }: let
      craneLib = crane.mkLib pkgs;
      craneArgsByProject = builtins.mapAttrs (name: projectConfig: rec {
        src = craneLib.cleanCargoSource projectConfig.src;
        cargoArtifacts = craneLib.buildDepsOnly { inherit src; };
      }) config.rust;
    in {
      options = {
        rust = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule rustSubmodule);
          description = "An attrset of rust projects to generate";
        };
      };

      config = {
        packages = builtins.mapAttrs (name: projectConfig:
          craneLib.buildPackage {
            inherit (craneArgsByProject.${name}) src cargoArtifacts;
          }
        ) config.rust;

        checks = lib.foldlAttrs (acc: name: projectConfig: acc // {
          "${name}-cargo-clippy" = craneLib.cargoClippy {
            inherit (craneArgsByProject.${name}) src cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          };
          "${name}-cargo-fmt" = craneLib.cargoFmt { inherit (craneArgsByProject.${name}) src; };
          "${name}-cargo-doc" = craneLib.cargoDoc { inherit (craneArgsByProject.${name}) src cargoArtifacts; };
        }) {} config.rust;

        devShells = builtins.mapAttrs (name: projectConfig:
          craneLib.devShell {
            packages = projectConfig.devShellPackages;
          }
        ) config.rust;

        nixosConfigurations = builtins.mapAttrs (name: projectConfig: {
          systemd.services.${name} = {
            description = "${name} rust garnix module";
            wantedBy = [ "multi-user.target" ];
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            serviceConfig = {
              Type = "simple";
              DynamicUser = true;
              ExecStart = lib.getExe (pkgs.writeShellApplication {
                name = "start-${name}";
                runtimeInputs = [ config.packages.${name} ];
                text = projectConfig.serverCommand;
              });
            };
          };
        }) config.rust;
      };
    };
  };
}
