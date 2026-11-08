# rmpp_android: the device-side Waydroid session (android.py) on top of the
# rmpp_android_tools closure, the einkbridge capture/worker pair (einkbridge.nix)
# and Quill (quill.nix). Design adapted from
# https://github.com/MaximeRivest/android-on-remarkable-paper-pro (see the
# pinned links in android.py); none of upstream's installers are used.
{
  lib,
  buildEnv,
  writeText,
  writeTextFile,
  python3,
  cacert,
  tools,
  bridge,
  quill,
  os,
  kernelVersion,
}:
let
  metadata = writeText "rmpp-android-runtime.json" (
    builtins.toJSON {
      tools = toString tools;
      bridge = toString bridge;
      quill = toString quill;
      caBundle = "${cacert}/etc/ssl/certs/ca-bundle.crt";
      kernelRelease = "${kernelVersion}-waydroid";
      osVersion = os.version;
    }
  );
  controller = writeTextFile {
    name = "rmpp-android-controller";
    destination = "/bin/rmpp-android";
    executable = true;
    # Device entry point: BusyBox sh dispatches into the shipped Nix closure.
    text = ''
      #!/bin/sh
      export PATH=${tools}/bin:$PATH
      export RMPP_ANDROID_META=${metadata}
      exec ${python3}/bin/python3 ${./android.py} "$@"
    '';
  };
in
buildEnv {
  name = "rmpp-android";
  paths = [
    tools
    bridge
    quill
    controller
  ];
  pathsToLink = [
    "/bin"
    "/lib"
    "/libexec"
    "/share"
  ];
  passthru = {
    inherit
      metadata
      tools
      bridge
      quill
      ;
  };
  meta = {
    description = "Paper Pro Waydroid session and source-built display bridge";
    license = lib.licenses.mit;
    platforms = [ "aarch64-linux" ];
    mainProgram = "rmpp-android";
  };
}
