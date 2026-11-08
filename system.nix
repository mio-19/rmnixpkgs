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
  os,
  rmppAndroid ? null,
  rmppAndroidIcon ? null,
  rmppChromium ? null,
  rmppChromiumIcon ? null,
  rmppKernel ? null,
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
        type = lib.types.nullOr lib.types.str;
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

      ${lib.optionalString (value.wantedBy != null) ''
        [Install]
        WantedBy=${value.wantedBy}
      ''}
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
    ++ lib.mapAttrsToList (n: v: "/etc/systemd/system/${v.wantedBy}.wants/${n}.service") (
      lib.filterAttrs (_: v: v.wantedBy != null) cfg.systemd.services
    )
    ++ lib.mapAttrsToList (n: _: "/home/root/xovi/exthome/appload/${n}/") cfg.appload.apps
    ++ lib.optionals cfg.osUpdates.disable (map (u: "/etc/systemd/system/${u}") cfg.osUpdates.units);

  safeName = n: builtins.match "[A-Za-z0-9._-]+" n != null && n != "." && n != "..";
  safeRelativePath = n: lib.all safeName (lib.splitString "/" n);

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
    android.enable = lib.mkEnableOption "the manual rmpp-android takeover service and AppLoad entry";
    chromium.enable = lib.mkEnableOption "the manual rmpp-chromium browser takeover service and AppLoad entry";
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

    kernel.install = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install rmpp_kernel (fitImage and kernel modules) by default onto the tablet
        during activation, taking a backup of the stock fitImage first.
      '';
    };

    # What rmpp_kernel carries on top of reMarkable's published tree. Their
    # kernel is frozen at one stable level, so every upstream fix after it — the
    # security fixes included — is missing. The chain itself is pinned in os.nix
    # (`kernel.stable`); this is only the switch, because whether to run a
    # patched kernel is a property of this device's build.
    kernel.securityPatches = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Apply the upstream stable chain pinned in os.nix (`kernel.stable`) to
          rmpp_kernel. Off builds reMarkable's tree exactly as published.
          Either way the generation records the kernel release it expects, and
          activation checks `uname -r` against it.
        '';
      };
    };

    # What this generation was built for. `version` selects the supported
    # reMarkable OS firmware release ("3.27" or "3.28") and picks the matching
    # kernel source and device trees.
    os = {
      version = lib.mkOption {
        type = lib.types.enum [
          "3.27"
          "3.28"
        ];
        default = os.version;
        description = "reMarkable OS release this configuration targets (3.27 or 3.28).";
      };
      glibc = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = os.glibc;
        description = "Userland glibc of that release (os.nix): what links against the system must match it.";
      };
      qt = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = os.qt;
        description = "Qt that xochitl ships on that release (os.nix).";
      };
      kernelVersion = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = os.kernel.version;
        description = "Kernel version that release ships, i.e. what rmpp_kernel builds.";
      };
    };

    # reMarkable OTA updates. With a rebuilt kernel and a store that lives on
    # /home, an unattended OTA is hostile: it replaces the rootfs (the boot unit
    # with it) and boots the stock kernel again, silently undoing this layer.
    # Masking is `systemctl mask`'s /dev/null symlink, i.e. a file, so it can be
    # applied without systemctl and re-created at every boot.
    osUpdates = {
      disable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "
          Mask the stock reMarkable OTA updater. Take updates deliberately
          instead: re-enable, apply, let the OTA run, then rebuild against the
          new release and reinstall the boot unit.
        ";
      };
      units = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "update-engine.service"
          "updatedb.service"
        ];
        description = "Units implementing reMarkable's OTA updates; masked when `disable` is set.";
      };
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
    rmpp.packages =
      lib.optionals cfg.android.enable [ rmppAndroid ]
      ++ lib.optionals cfg.chromium.enable [ rmppChromium ];
    rmpp.systemd.services =
      (lib.mkIf cfg.android.enable {
        rmpp-android = {
          description = "Waydroid e-paper takeover";
          type = "simple";
          execStart = "${rmppAndroid}/bin/rmpp-android run";
          wantedBy = null; # Manual/AppLoad launch only, never take over at boot.
          serviceConfig = ''
            ExecStopPost=${rmppAndroid}/bin/rmpp-android recover
            KillMode=mixed
            SendSIGKILL=no
            TimeoutStopSec=240
            Delegate=yes
          '';
        };
      })
      // (lib.mkIf cfg.chromium.enable {
        rmpp-chromium = {
          description = "Chromium e-paper browser takeover";
          type = "simple";
          execStart = "${rmppChromium}/bin/rmpp-chromium run";
          wantedBy = null; # Manual/AppLoad launch only, never take over at boot.
          serviceConfig = ''
            ExecStopPost=${rmppChromium}/bin/rmpp-chromium recover
            KillMode=mixed
            SendSIGKILL=no
            TimeoutStopSec=60
            Delegate=yes
          '';
        };
      });
    rmpp.appload.apps =
      (lib.mkIf cfg.android.enable {
        rmpp-android = {
          name = "Android";
          application = "${rmppAndroid}/bin/rmpp-android";
          args = [ "start" ];
          icon = rmppAndroidIcon;
          qtfb = false;
        };
      })
      // (lib.mkIf cfg.chromium.enable {
        rmpp-chromium = {
          name = "Chromium";
          application = "${rmppChromium}/bin/rmpp-chromium";
          args = [ "start" ];
          icon = rmppChromiumIcon;
          qtfb = false;
        };
      });
    assertions = [
      {
        assertion = !cfg.android.enable || rmppAndroid != null;
        message = "rmpp.android.enable requires the runtime package";
      }
      {
        assertion = !cfg.chromium.enable || rmppChromium != null;
        message = "rmpp.chromium.enable requires the runtime package";
      }
      {
        assertion = lib.all safeRelativePath (lib.attrNames cfg.files);
        message = "rmpp.files: expected relative paths without empty, dot or parent components";
      }
      {
        assertion = lib.all (v: builtins.match "[0-7]{3,4}" v.mode != null) (lib.attrValues cfg.files);
        message = "rmpp.files: modes must be three or four octal digits";
      }
      {
        assertion = lib.all (v: v.wantedBy == null || safeName v.wantedBy) (
          lib.attrValues cfg.systemd.services
        );
        message = "rmpp.systemd.services: wantedBy must be a unit name without path components";
      }
      {
        assertion = lib.all (n: safeName n && lib.hasPrefix "rmpp-" n) (lib.attrNames cfg.systemd.services);
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
      {
        assertion = lib.all (u: builtins.match "[A-Za-z0-9._@-]+\\.service" u != null) cfg.osUpdates.units;
        message = "rmpp.osUpdates.units: expected systemd unit names like update-engine.service";
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
          dontPatchShebangs = true;

          installPhase = ''
            runHook preInstall
            mkdir -p $out/etc $out/systemd $out/appload $out/bin

            substitute ${./activate.sh} $out/activate \
              --subst-var-by extraPath "${
                lib.makeBinPath [
                  pkgs.coreutils
                  pkgs.gnused
                  pkgs.gnugrep
                  pkgs.gawk
                  pkgs.diffutils
                ]
              }"
            chmod 755 $out/activate

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
              lib.mapAttrsToList (n: v: "${v.wantedBy}.wants ${n}.service") (
                lib.filterAttrs (_: v: v.wantedBy != null) cfg.systemd.services
              )
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

            # OS-update policy: units to mask, one per line.
            ${lib.optionalString cfg.osUpdates.disable (writeLines "$out/systemd.mask" cfg.osUpdates.units)}

            # Kernel build (fitImage and modules) when install is enabled.
            ${lib.optionalString (cfg.kernel.install && rmppKernel != null) ''
              ln -s ${rmppKernel} $out/kernel
            ''}

            # What this generation was built for, readable on the device:
            #   cat /home/root/.rmpp/current/os
            ${writeLines "$out/os" [
              "version=${cfg.os.version}"
              "glibc=${cfg.os.glibc}"
              "qt=${cfg.os.qt}"
              "kernel-version=${cfg.os.kernelVersion}"
              "kernel-patches=${
                if cfg.kernel.securityPatches.enable then
                  "${toString os.kernel.stable.first}..${toString os.kernel.stable.last}"
                else
                  "none"
              }"
            ]}

            runHook postInstall
          '';

          meta = {
            description = "Declarative reMarkable Paper Pro configuration generation";
            platforms = lib.platforms.all;
          };
        };
  };
}
