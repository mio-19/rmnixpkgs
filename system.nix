# Declarative, NixOS-shaped configuration for the Paper Pro, in the spirit of
# https://github.com/numtide/system-manager : a module describes files, systemd
# units, packages and (here) AppLoad entries; evaluation produces an immutable
# *generation*; one script activates it.
#
# Adapted for this device, which is why it is not just system-manager:
#   * `/` is read-only and `/etc` is an overlay whose upper layer is tmpfs, so
#     anything written to /etc vanishes at reboot. Generations therefore live in
#     the store and `rmpp-config.service` re-applies the current one every boot.
#   * The store itself lives on /home (see nix-setup.sh), so generations survive
#     OS updates; only the boot unit has to be reinstalled.
#   * The device already runs vellum + XOVI + AppLoad (see
#     remarkable-paper-pro.md), so activation only ever touches paths it recorded
#     in its own manifest and refuses to replace AppLoad entries it did not
#     create. That bookkeeping is the whole coexistence story.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.rmpp;

  fileModule = lib.types.submodule {
    options = {
      text = lib.mkOption {
        type = lib.types.nullOr lib.types.lines;
        default = null;
        description = "File contents.";
      };
      source = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "File to copy instead of `text`.";
      };
      mode = lib.mkOption {
        type = lib.types.str;
        default = "0644";
        description = "Octal mode for the installed file.";
      };
    };
  };

  serviceModule = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        default = "";
      };
      execStart = lib.mkOption { type = lib.types.str; };
      type = lib.mkOption {
        type = lib.types.str;
        default = "oneshot";
      };
      after = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "home.mount" ];
      };
      wants = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "home.mount" ];
      };
      wantedBy = lib.mkOption {
        type = lib.types.str;
        default = "multi-user.target";
      };
      serviceConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Extra [Service] lines.";
      };
    };
  };

  appModule = lib.types.submodule {
    options = {
      name = lib.mkOption { type = lib.types.str; };
      application = lib.mkOption {
        type = lib.types.str;
        description = "Executable, absolute or relative to the AppLoad app dir.";
      };
      args = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
      };
      workingDirectory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      # AppLoad allocates a QTFB shared-memory framebuffer for the app and hands
      # it the ID as QTFB_KEY; see
      # https://github.com/asivery/rm-appload (README, "External applications").
      qtfb = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      disablesWindowedMode = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      icon = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "icon.png; AppLoad shows a blank tile without one.";
      };
    };
  };

  # Vellum (https://github.com/vellum-dev/vellum) is the apk-based package
  # ecosystem on this device. This option is deliberately shaped like
  # nix-darwin's Homebrew module
  # (https://github.com/nix-darwin/nix-darwin/blob/master/modules/homebrew.nix):
  # a declarative list, applied on activation, with opt-in auto-update and
  # cleanup.
  vellumModule = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Manage vellum packages from this configuration.";
      };
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = lib.literalExpression ''[ "koreader" "appload" ]'';
        description = ''
          Packages to install with `vellum add`: `name`, `name@testing`, or any
          apk-style constraint vellum accepts.
        '';
      };
      onActivation = {
        autoUpdate = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Run `vellum update` before adding packages. Off by default: activation also runs at boot, when the tablet may be offline.";
        };
        cleanup = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Remove packages this layer installed that are no longer listed.
            Narrower than `brew bundle cleanup`: only packages recorded in
            /home/root/.rmpp/vellum-managed are ever removed.
          '';
        };
      };
    };
  };

  etcSource =
    name: value:
    if value.source != null then
      value.source
    else
      pkgs.writeText name (
        if value.text != null then value.text else throw "rmpp.files.${name}: set either `text` or `source`"
      );

  unitText =
    name: value:
    let
      description = if value.description != "" then value.description else "rmpp ${name}";
    in
    ''
      [Unit]
      Description=${description}
      ${lib.concatMapStringsSep "\n" (x: "After=${x}") value.after}
      ${lib.concatMapStringsSep "\n" (x: "Wants=${x}") value.wants}

      [Service]
      Type=${value.type}
      ExecStart=${value.execStart}
      ${value.serviceConfig}

      [Install]
      WantedBy=${value.wantedBy}
    '';

  appManifest =
    _name: value:
    builtins.toJSON (
      {
        inherit (value)
          name
          application
          args
          environment
          qtfb
          disablesWindowedMode
          ;
      }
      // lib.optionalAttrs (value.workingDirectory != null) {
        workingDirectory = value.workingDirectory;
      }
    );

  # Everything activation is allowed to create or delete. Written next to the
  # generation so the next activation can remove what it no longer declares.
  ownedPaths =
    lib.mapAttrsToList (n: _: "/etc/${n}") cfg.files
    ++ lib.mapAttrsToList (n: _: "/etc/systemd/system/${n}.service") cfg.systemd.services
    ++ lib.mapAttrsToList (
      n: v: "/etc/systemd/system/${v.wantedBy}.wants/${n}.service"
    ) cfg.systemd.services
    ++ lib.mapAttrsToList (n: _: "/home/root/xovi/exthome/appload/${n}/") cfg.appload.apps;

  safeName = n: builtins.match "[A-Za-z0-9._-]+" n != null;

  # `assertions` is a NixOS module convention; evalModules has no such option,
  # so it is declared below and enforced at evaluation time.
  failedAssertions = map (a: a.message) (builtins.filter (a: !a.assertion) config.assertions);

  # Small helper: emit one line per item into a file, without heredocs (an
  # indented heredoc inside a Nix indented string loses its terminator, which
  # silently swallows the rest of the install phase).
  writeLines = file: items: ''
    : > ${file}
    ${lib.optionalString (items != [ ]) ''printf '%s\n' ${lib.escapeShellArgs items} >> ${file}''}
  '';
in
{
  options.rmpp = {
    files = lib.mkOption {
      type = lib.types.attrsOf fileModule;
      default = { };
      example = lib.literalExpression ''
        {
          "profile.d/rmpp-path.sh".text = "export PATH=/home/root/.rmpp/current/bin:$PATH";
        }
      '';
      description = "Files under /etc, re-applied at every boot.";
    };

    systemd.services = lib.mkOption {
      type = lib.types.attrsOf serviceModule;
      default = { };
      description = ''
        systemd services to install. Names are asserted to start with `rmpp-`
        so this layer can never shadow xochitl, XOVI or a vellum package's unit.
      '';
    };

    appload.apps = lib.mkOption {
      type = lib.types.attrsOf appModule;
      default = { };
      description = ''
        AppLoad external applications, installed under
        /home/root/xovi/exthome/appload/<name>/. Entries that already exist and
        were not created by rmpp-config (vellum, a hand install) are left alone.
      '';
    };

    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packages whose bin/ is exposed on the generation's PATH.";
    };

    vellum = lib.mkOption {
      type = vellumModule;
      default = { };
      description = "Declarative vellum (apk) package list, Homebrew-module style.";
    };
  };

  options.assertions = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          assertion = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          message = lib.mkOption { type = lib.types.str; };
        };
      }
    );
    default = [ ];
    description = "Conditions that must hold, or evaluation fails.";
  };

  options.system.build.toplevel = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "The generation produced by this configuration.";
  };

  config = {
    assertions = [
      {
        assertion = lib.all (n: lib.hasPrefix "rmpp-" n) (lib.attrNames cfg.systemd.services);
        message = "rmpp.systemd.services: unit names must start with `rmpp-` (that is how this layer avoids fighting XOVI/vellum units)";
      }
      {
        assertion = lib.all safeName (lib.attrNames cfg.appload.apps);
        message = "rmpp.appload.apps: names must match [A-Za-z0-9._-]+";
      }
      {
        assertion = lib.all (p: builtins.match "[A-Za-z0-9._+@:=<>-]+" p != null) cfg.vellum.packages;
        message = "rmpp.vellum.packages: package specs may only contain [A-Za-z0-9._+@:=<>-]";
      }
    ];

    system.build.toplevel =
      if failedAssertions != [ ] then
        throw (lib.concatStringsSep "\n" failedAssertions)
      else
        pkgs.stdenvNoCC.mkDerivation {
          pname = "rmpp-config";
          version = "1";

          dontUnpack = true;

          installPhase = ''
            runHook preInstall
            mkdir -p $out/etc $out/systemd $out/appload $out/bin

            install -m755 ${./activate.sh} $out/activate

            # /etc files (activation installs them with the recorded mode).
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (n: v: "install -Dm${v.mode} ${etcSource n v} $out/etc/${n}") cfg.files
            )}
            ${writeLines "$out/etc.modes" (lib.mapAttrsToList (n: v: "${v.mode} ${n}") cfg.files)}

            # systemd units + the enablement list.
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (
                n: v: "install -Dm644 ${pkgs.writeText "${n}.service" (unitText n v)} $out/systemd/${n}.service"
              ) cfg.systemd.services
            )}
            ${writeLines "$out/systemd.enable" (
              lib.mapAttrsToList (n: v: "${v.wantedBy}.wants ${n}.service") cfg.systemd.services
            )}

            # AppLoad entries, each marked as ours so activation can tell them
            # apart from anything vellum installed.
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (n: v: ''
                install -d $out/appload/${n}
                install -m644 ${pkgs.writeText "${n}-external.manifest.json" (appManifest n v)} $out/appload/${n}/external.manifest.json
                ${lib.optionalString (v.icon != null) "install -m644 ${v.icon} $out/appload/${n}/icon.png"}
                : > $out/appload/${n}/.rmpp-config
              '') cfg.appload.apps
            )}

            # Packages on PATH.
            ${lib.concatMapStringsSep "\n" (p: ''
              if [ -d ${p}/bin ]; then
                for f in ${p}/bin/*; do ln -sf "$f" $out/bin/; done
              fi
            '') cfg.packages}

            # Vellum package intent, consumed by activation.
            ${lib.optionalString cfg.vellum.enable ''
              ${writeLines "$out/vellum.packages" cfg.vellum.packages}
              printf 'auto-update=%s\n' ${
                if cfg.vellum.onActivation.autoUpdate then "1" else "0"
              } > $out/vellum.options
              printf 'cleanup=%s\n' ${if cfg.vellum.onActivation.cleanup then "1" else "0"} >> $out/vellum.options
            ''}

            # Ownership manifest: the only paths activation may create or delete.
            ${writeLines "$out/manifest" ownedPaths}

            runHook postInstall
          '';

          meta = {
            description = "Declarative reMarkable Paper Pro configuration generation";
            platforms = lib.platforms.all;
          };
        };
  };
}
