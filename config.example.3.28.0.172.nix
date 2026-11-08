# Example declarative configuration for reMarkable OS 3.28 (e.g. 3.28.0.172).
# Evaluated by ./system.nix as part of `rmpp_config`.
#
# To use this configuration:
#   cp config.example.3.28.0.172.nix config.nix
#   nix build .#rmpp_config -o rmpp-config
#
# Target firmware:
#   reMarkable OS 3.28.0.172 (Paper Pro "ferrari", aarch64)
#   Kernel: 6.12.49 (reMarkable GPL branch rmpp_6.12.49_v3.27.x)
#   Userland: Yocto scarthgap (glibc 2.39, Qt 6.10.3, GCC 13)
#
# Ecosystem and coexistence:
#   Everything here lands in /nix/store or under /home/root (the only writable
#   partition that survives an OTA). Managed paths are tracked in an immutable
#   manifest; unowned vellum packages, AppLoad apps, and XOVI files are never
#   touched or removed.

{
  rmpp = {
    # Target reMarkable OS firmware release ("3.27" or "3.28").
    os.version = "3.28";

    # -------------------------------------------------------------------------
    # Waydroid / Android takeover
    # -------------------------------------------------------------------------
    # Installs the manual rmpp-android takeover service and AppLoad tile.
    # Runs containerized LineageOS 20 (Android 13) inside a private mount namespace
    # with persistent state in /home/root/.rmpp/android.
    #
    # NOTE: Does NOT start at boot or download images automatically.
    # Prerequisite: Boot rmpp_kernel (etnaviv GPU + binder drivers enabled).
    # Runtime setup: Run `rmpp-android init -s VANILLA` once on the tablet.
    android.enable = true;

    # -------------------------------------------------------------------------
    # Chromium on e-ink
    # -------------------------------------------------------------------------
    # Installs the manual rmpp-chromium browser takeover service and AppLoad tile.
    # Runs native aarch64 Chromium (from cache.nixos.org) headless with DevTools
    # protocol, driven by source-built chromium-cdp and painted to e-paper via Quill.
    # State lives in /home/root/.rmpp/chromium.
    chromium.enable = false;

    # -------------------------------------------------------------------------
    # Environment & PATH
    # -------------------------------------------------------------------------
    # Exposes the active generation's bin directory on the device PATH so tools
    # added below or by rmpp.packages are accessible in interactive shells.
    files."profile.d/rmpp-path.sh".text = ''
      case ":$PATH:" in
        *":/home/root/.rmpp/current/bin:"*) ;;
        *) PATH="/home/root/.rmpp/current/bin:$PATH"; export PATH ;;
      esac
    '';

    # -------------------------------------------------------------------------
    # Declarative activation service (boot re-apply)
    # -------------------------------------------------------------------------
    # /etc is a tmpfs overlay on the Paper Pro and the rootfs is read-only.
    # Activation scripts write to /etc at activation time.
    # This systemd service re-applies the generation at boot so declarative
    # configuration persists across reboots.
    # Install into the persistent rootfs with: `activate --install-boot-unit`.
    systemd.services.rmpp-config = {
      description = "Apply the declarative reMarkable configuration (rmpp-config)";
      execStart = "/home/root/.rmpp/current/activate --boot";
      after = [
        "home.mount"
        "nix.mount"
      ];
      wants = [
        "home.mount"
        "nix.mount"
      ];
      wantedBy = "multi-user.target";
    };

    # -------------------------------------------------------------------------
    # AppLoad apps
    # -------------------------------------------------------------------------
    # Declares tiles in the XOVI AppLoad launcher (/home/root/xovi/exthome/appload/).
    # App entries created here are marked with a .rmpp-config marker and tracked
    # in the activation manifest. Foreign or hand-installed tiles are never overwritten.
    appload.apps.rmweb = {
      name = "rmweb";
      application = "/home/root/rmweb/rmweb";
      environment = {
        RMWEB_ROOT = "/home/root/rmweb";
      };
      qtfb = false;
    };

    # -------------------------------------------------------------------------
    # Device packages (aarch64-linux closures from cache.nixos.org)
    # -------------------------------------------------------------------------
    # CLI utilities available on the tablet. These substitute directly from the
    # nixpkgs binary cache into the tablet's Nix store:
    packages = [
      # pkgs.htop
      # pkgs.tmux
      # pkgs.rsync
      # pkgs.strace
    ];

    # -------------------------------------------------------------------------
    # Vellum package management
    # -------------------------------------------------------------------------
    # Declarative intent for Vellum packages (managed under /home/root/.vellum).
    # Activation runs `vellum add <pkg>`. Only packages newly added by this layer
    # are recorded in the ownership ledger; existing or hand-installed packages
    # are never claimed.
    vellum = {
      enable = true;
      packages = [
        "appload"
        "ghostbuster"
        "hide-dev-mode-icon"
        "koreader"
        "librarian"
        "mount-utils"
        "netsurf"
        "qt-resource-rebuilder"
        "tripletap"
        "vellum"
        "vellum-bash-completion"
        "xovi"
        "xovi-extensions"
        "xovi-message-broker"
      ];
      onActivation = {
        autoUpdate = false;
        cleanup = false; # Set to true to automatically remove unlisted packages
      };
    };

    # -------------------------------------------------------------------------
    # Kernel security updates (upstream stable chain)
    # -------------------------------------------------------------------------
    # reMarkable's GPL source for 3.28 is based on 6.12.49.
    #
    # false (Default):
    #   Builds 6.12.49-waydroid (vendor tree as published, with Vivante GPU and
    #   Android container options merged). Recommended baseline until verified
    #   on physical tablet hardware.
    #
    # true (Opt-in):
    #   Applies the upstream stable chain up to 6.12.115 along with architectural
    #   semantic backports (producing 6.12.115-waydroid).
    kernel.securityPatches.enable = false;

    # -------------------------------------------------------------------------
    # OS update protection
    # -------------------------------------------------------------------------
    # Masks reMarkable's background OTA update services. An unattended OS update
    # replaces the active rootfs partition, which wipes /etc units and restores
    # the stock kernel.
    # To take an update on purpose: set disable = false, activate, perform the OTA,
    # then update os.nix and re-run activate --install-boot-unit.
    osUpdates.disable = true;
  };
}
