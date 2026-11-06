# The declarative configuration of this device, evaluated by ./system.nix.
# `nix build .#rmpp_config` turns this into a generation; ./activate.sh applies it.
#
# Coexistence is the constraint: everything below either lives in the store or
# under /home/root, and nothing claims a path that vellum, XOVI or AppLoad own.
# See remarkable-paper-pro.md for the ecosystem map.
# The reMarkable OS release this configuration is for is declared once, in
# os.nix: `rmpp.os.*` below is read-only and simply reports it (the kernel source
# pin and the userland ABI both derive from that file, so a second copy here
# could disagree with the packages that were actually built).
{
  rmpp = {
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
      wants = [ "home.mount" ];
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
      application = "/home/root/rmweb/rmweb";
      environment = {
        RMWEB_ROOT = "/home/root/rmweb";
      };
      qtfb = false;
    };

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
        # "koreader"
        # "appload"
        # "xovi-tripletap"
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
    # Off, because that chain does not produce a compiling tree on this vendor
    # base: of its 100 hunks that find no context in reMarkable's NXP tree, the
    # ones that *do* apply change core APIs (syscore, of_reset_control_array_get,
    # cfg80211, pmdomain) while the rejected NXP drivers still call them the old
    # way. kernel.nix backports what can be backported, but the remaining set is
    # a port of those drivers, not a patch. Measured on aarch64, see TODO.md.
    #
    # Set to true to build 6.12.115-waydroid, with the report and the backports;
    # expect the build to stop in drivers/gpio, drivers/gpu/imx, drivers/pmdomain
    # or the 3rdparty iw61x wireless driver.
    kernel.securityPatches.enable = false;

    # Mask reMarkable's OTA updater. An unattended update replaces the rootfs
    # (rmpp-config.service included) and boots the stock kernel again, undoing
    # both rmpp_kernel and this layer. To take an update on purpose: set
    # `disable = false`, activate, run the OTA, then edit os.nix for the new
    # release, rebuild, and `activate --install-boot-unit` again.
    osUpdates.disable = true;
  };
}
