# The declarative configuration of this device, evaluated by ./system.nix.
# `nix build .#rmpp_config` turns this into a generation; ./activate.sh applies it.
#
# Coexistence is the constraint: everything below either lives in the store or
# under /home/root, and nothing claims a path that vellum, XOVI or AppLoad own.
# See remarkable-paper-pro.md for the ecosystem map.
# The reMarkable OS release this configuration is for is selected by
# `rmpp.os.version` ("3.27" or "3.28", default "3.28"): the kernel source pin,
# device trees, and userland ABI derive from os.nix for the chosen release.
{ pkgs, ... }:
{
  rmpp = {
    # Target reMarkable OS firmware release ("3.27" or "3.28").
    os.version = "3.28";

    # Installs a manual rmpp-android service and our own AppLoad entry. It does
    # not download Android images, flash a kernel, or start Android at boot.
    android.enable = true;
    # PATH for the generation's bin/ (rmpp.packages), also for the OS-update-safe
    # login shell.
    files."profile.d/rmpp-path.sh".text = ''
      case ":$PATH:" in
        *":/home/root/.rmpp/current/bin:"*) ;;
        *) PATH="/home/root/.rmpp/current/bin:$PATH"; export PATH ;;
      esac
    '';

    # Re-apply this generation at every boot: /etc is a tmpfs overlay and the
    # rootfs is read-only, so nothing written by activation survives a reboot on
    # its own. Installed into the rootfs by `activate --install-boot-unit`.
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

    # rmweb under XOVI/AppLoad: an external app entry, so it appears as a tile
    # next to everything vellum installs. The tree is the writable copy under
    # /home/root/rmweb (see remarkable-paper-pro.md), not the store path, because
    # the launcher writes its log and lock next to itself.
    #
    # qtfb stays false until rmweb speaks QTFB; with it true, AppLoad allocates a
    # shared-memory framebuffer (https://github.com/asivery/rm-appload) and hands
    # the ID to the app as QTFB_KEY, which replaces the closed epaper QPA.
    appload.apps.rmweb = {
      name = "rmweb";
      application = "/home/root/rmweb/appload-entry.sh";
      environment = {
        RMWEB_ROOT = "/home/root/rmweb";
      };
      disablesWindowedMode = true;
      qtfb = false;
    };

    # Kiwix desktop Qt reader (https://github.com/kiwix/kiwix-desktop) under
    # AppLoad via QTFB: runs directly on the device with offline ZIM content.
    kiwix.enable = true;

    # Packages exposed on the generation's PATH. CallPackage'd from the flake's
    # aarch64 set, e.g. `pkgs.tmux`, so they are the same cached derivations the
    # other packages here use.
    packages = [ ];

    # Vellum packages, declared the way nix-darwin declares Homebrew ones
    # (https://github.com/nix-darwin/nix-darwin/blob/master/modules/homebrew.nix).
    # Activation runs `vellum add` for each entry; vellum keeps owning its apk
    # database under /home/root/.vellum, this file only records intent.
    #
    # Leave cleanup off unless you mean it: it removes packages this layer added
    # earlier and that are no longer listed here.
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
        cleanup = false;
      };
    };

    # Kernel security updates. reMarkable freezes its kernel at one stable level
    # (os.nix `kernel.version`), so rmpp_kernel can apply the upstream stable
    # chain pinned in os.nix (`kernel.stable`) on top of it.
    #
    # On: the built kernel is 6.12.115-waydroid and activation compares
    # `uname -r` against it; the tree is the build-time chain application
    # (eight committed ports plus the derived syscore revert in the derivation,
    # never a committed reversed artifact).
    #
    # Off: the vendor tree as reMarkable published it (6.12.49-waydroid), with
    # no security fixes on top. Default is off until the rest of the stack is
    # settled and there is a verified kernel line on device.
    kernel.securityPatches.enable = false;

    # Mask reMarkable's OTA updater. An unattended update replaces the rootfs
    # (rmpp-config.service included) and boots the stock kernel again, undoing
    # both rmpp_kernel and this layer. To take an update on purpose: set
    # `disable = false`, activate, run the OTA, then edit os.nix for the new
    # release, rebuild, and `activate --install-boot-unit` again.
    osUpdates.disable = true;
  };
}
