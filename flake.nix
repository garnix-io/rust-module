{
  description = ''A garnix module for projects using Rust.

  See the [module documentation](https://garnix.io/docs/modules/rust) or the [module repo](https://github.com/garnix-io/rust-module) additional info.
  '';
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  inputs.crane.url = "github:ipetkov/crane";
  outputs = { self, nixpkgs, crane }:
    let
      lib = nixpkgs.lib;

      webServerSubmodule.options = {
        command = lib.mkOption
          {
            type = lib.types.nonEmptyStr;
            description = "The command to run to start the server in production.";
            example = "server --port 8000";
          } // { name = "server command"; };

        port = lib.mkOption {
          type = lib.types.port;
          description = "Port to forward incoming http requests to. The server command has to listen on this port.";
          example = 8000;
          default = 8000;
        };

        path = lib.mkOption
          {
            type = lib.types.nonEmptyStr;
            description = "Path your Rust server will be hosted on.";
            default = "/";
          } // { name = "API path"; };
      };

      rustSubmodule.options = {
        src = lib.mkOption
          {
            type = lib.types.path;
            description = "A path to the directory containing Cargo.lock, Cargo.toml, and src.";
            example = "./.";
          } // { name = "source directory"; };

        webServer = lib.mkOption {
          type = lib.types.nullOr (lib.types.submodule webServerSubmodule);
          description = "Whether to create an HTTP server based on this Rust project.";
          default = null;
        };

        devTools = lib.mkOption
          {
            type = lib.types.listOf lib.types.package;
            description = "A list of packages make available in the devshell for this project (and `default` devshell). This is useful for things like LSPs, formatters, etc.";
            default = [ ];
          } // { name = "development tools"; };

        buildDependencies = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          description = "A list of dependencies required to build this package. They are made available in the devshell, and at build time.";
          default = [ ];
        };

        runtimeDependencies = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          description = "A list of dependencies required at runtime. They are made available in the devshell, at build time, and are available on the server at runtime.";
          default = [ ];
        };
      };
    in
    {
      garnixModules.default = { pkgs, config, ... }:
        let
          craneLib = crane.mkLib pkgs;
          craneArgsByProject = builtins.mapAttrs
            (name: projectConfig: rec {
              src = craneLib.cleanCargoSource projectConfig.src;
              cargoArtifacts = craneLib.buildDepsOnly { inherit src buildInputs; };
              buildInputs = projectConfig.buildDependencies ++ projectConfig.runtimeDependencies;
            })
            config.rust;
        in
        {
          options = {
            rust = lib.mkOption {
              type = lib.types.attrsOf (lib.types.submodule rustSubmodule);
              description = "An attrset of rust projects to generate.";
            };
          };

          config = {
            packages = builtins.mapAttrs
              (name: projectConfig:
                craneLib.buildPackage {
                  inherit (craneArgsByProject.${name}) src cargoArtifacts buildInputs;
                }
              )
              config.rust;

            checks = lib.foldlAttrs
              (acc: name: projectConfig: acc // {
                "${name}-cargo-clippy" = craneLib.cargoClippy {
                  inherit (craneArgsByProject.${name}) src cargoArtifacts buildInputs;
                  cargoClippyExtraArgs = "--all-targets -- --deny warnings";
                };
                "${name}-cargo-fmt" = craneLib.cargoFmt { inherit (craneArgsByProject.${name}) src; };
                "${name}-cargo-doc" = craneLib.cargoDoc { inherit (craneArgsByProject.${name}) src cargoArtifacts buildInputs; };
              })
              { }
              config.rust;

            devShells = builtins.mapAttrs
              (name: projectConfig:
                craneLib.devShell {
                  packages =
                    projectConfig.devTools ++
                    projectConfig.buildDependencies ++
                    projectConfig.runtimeDependencies;
                }
              )
              config.rust;

            nixosConfigurations =
              let
                hasAnyWebServer =
                  builtins.any (projectConfig: projectConfig.webServer != null)
                    (builtins.attrValues config.rust);
              in
              lib.mkIf hasAnyWebServer {
                default =
                  # Global nixos configuration
                  [{
                    services.nginx = {
                      enable = true;
                      recommendedProxySettings = true;
                      recommendedOptimisation = true;
                      virtualHosts.default = {
                        default = true;
                      };
                    };

                    networking.firewall.allowedTCPPorts = [ 80 ];
                  }]
                  ++
                  # Per project nixos configuration
                  (builtins.attrValues (builtins.mapAttrs
                    (name: projectConfig: lib.mkIf (projectConfig.webServer != null) {
                      environment.systemPackages = projectConfig.runtimeDependencies;

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
                            runtimeInputs = [ config.packages.${name} ] ++ projectConfig.runtimeDependencies;
                            text = projectConfig.webServer.command;
                          });
                        };
                      };

                      services.nginx.virtualHosts.default.locations.${projectConfig.webServer.path}.proxyPass = "http://localhost:${toString projectConfig.webServer.port}";
                    })
                    config.rust));
              };
          };
        };
    };
}
