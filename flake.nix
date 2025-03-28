{
  description = ''
    A garnix module for projects using Rust.

    Add build and runtime dependencies and optionally deploy a web server.

    [Documentation](https://garnix.io/docs/modules/rust) - [Source](https://github.com/garnix-io/rust-module).
  '';
  inputs.crane.url = "github:ipetkov/crane";
  outputs =
    { self, crane }:
    {
      garnixModules.default =
        {
          pkgs,
          lib,
          config,
          ...
        }:
        let
          webServerSubmodule.options = {
            command =
              lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "The command to run to start the server in production.";
                example = "server --port \"$PORT\"";
              }
              // {
                name = "server command";
              };

            port = lib.mkOption {
              type = lib.types.port;
              description = "Port to forward incoming HTTP requests to. The server command has to listen on this port. This also sets the PORT environment variable for the server command.";
              example = 8000;
              default = 8000;
            };

            path =
              lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "Path your Rust server will be hosted on.";
                default = "/";
              }
              // {
                name = "API path";
              };
          };

          rustSubmodule.options = {
            src =
              lib.mkOption {
                type = lib.types.path;
                description = "A path to the directory containing `Cargo.lock`, `Cargo.toml`, and `src`.";
                example = "./.";
              }
              // {
                name = "source directory";
              };

            webServer = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule webServerSubmodule);
              description = "Whether to build a server configuration based on this project and deploy it to the garnix cloud.";
              default = null;
            };

            devTools =
              lib.mkOption {
                type = lib.types.listOf lib.types.package;
                description = "A list of packages make available in the devshell for this project (and `default` devshell). This is useful for things like LSPs, formatters, etc.";
                default = [ ];
              }
              // {
                name = "development tools";
              };

            buildDependencies = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              description = ''
              A list of additional dependencies required to build this package. They are made available in the devshell, and at build time.

              (It's not necessary to include library dependencies manually, these will be included automatically.)
              '';
              default = [ ];
            };

            runtimeDependencies = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              description = "A list of dependencies required at runtime. They are made available in the devshell, at build time, and are available on the server at runtime.";
              default = [ ];
            };
          };

          craneLib = crane.mkLib pkgs;
          craneArgsByProject = builtins.mapAttrs (name: projectConfig: rec {
            src = projectConfig.src;
            cargoArtifacts = craneLib.buildDepsOnly { inherit src buildInputs; };
            buildInputs = projectConfig.buildDependencies ++ projectConfig.runtimeDependencies;
          }) config.rust;
        in
        {
          options = {
            rust = lib.mkOption {
              type = lib.types.attrsOf (lib.types.submodule rustSubmodule);
              description = "An attrset of Rust projects to generate.";
            };
          };

          config = {
            packages = builtins.mapAttrs (
              name: projectConfig:
              craneLib.buildPackage {
                inherit (craneArgsByProject.${name}) src cargoArtifacts buildInputs;
              }
            ) config.rust;

            checks = lib.foldlAttrs (
              acc: name: projectConfig:
              acc
              // {
                "${name}-cargo-clippy" = craneLib.cargoClippy {
                  inherit (craneArgsByProject.${name}) src cargoArtifacts buildInputs;
                  cargoClippyExtraArgs = "--all-targets -- --deny warnings";
                };
                "${name}-cargo-fmt" = craneLib.cargoFmt { inherit (craneArgsByProject.${name}) src; };
                "${name}-cargo-doc" = craneLib.cargoDoc {
                  inherit (craneArgsByProject.${name}) src cargoArtifacts buildInputs;
                };
              }
            ) { } config.rust;

            devShells = builtins.mapAttrs (
              name: projectConfig:
              craneLib.devShell {
                packages =
                  projectConfig.devTools ++ projectConfig.buildDependencies ++ projectConfig.runtimeDependencies;
              }
            ) config.rust;

            nixosConfigurations =
              let
                hasAnyWebServer = builtins.any (projectConfig: projectConfig.webServer != null) (
                  builtins.attrValues config.rust
                );
              in
              lib.mkIf hasAnyWebServer {
                default =
                  # Global NixOS configuration
                  [
                    {
                      services.nginx = {
                        enable = true;
                        recommendedProxySettings = true;
                        recommendedOptimisation = true;
                        virtualHosts.default = {
                          default = true;
                        };
                      };

                      networking.firewall.allowedTCPPorts = [ 80 ];
                    }
                  ]
                  ++
                  # Per project NixOS configuration
                  (builtins.attrValues (
                    builtins.mapAttrs (
                      name: projectConfig:
                      lib.mkIf (projectConfig.webServer != null) {
                        environment.systemPackages = projectConfig.runtimeDependencies;

                        systemd.services.${name} = {
                          description = "${name} Rust garnix module";
                          wantedBy = [ "multi-user.target" ];
                          after = [ "network-online.target" ];
                          wants = [ "network-online.target" ];
                          environment.PORT = toString projectConfig.webServer.port;
                          serviceConfig = {
                            Type = "simple";
                            DynamicUser = true;
                            ExecStart = lib.getExe (
                              pkgs.writeShellApplication {
                                name = "start-${name}";
                                runtimeInputs = [ config.packages.${name} ] ++ projectConfig.runtimeDependencies;
                                text = projectConfig.webServer.command;
                              }
                            );
                          };
                        };

                        services.nginx.virtualHosts.default.locations.${projectConfig.webServer.path}.proxyPass =
                          "http://localhost:${toString projectConfig.webServer.port}";
                      }
                    ) config.rust
                  ));
              };
          };
        };
    };
}
