"""Paper Pro Waydroid runtime. Device wrapper keeps its /bin/sh shebang.

Namespace/session design adapted from (scripts are not installed verbatim):
https://github.com/MaximeRivest/android-on-remarkable-paper-pro/blob/65b5bf34fb3ef160e3d483a14484b46304ecbc7c/device/enter.sh
https://github.com/MaximeRivest/android-on-remarkable-paper-pro/blob/65b5bf34fb3ef160e3d483a14484b46304ecbc7c/device/session.sh
https://github.com/MaximeRivest/android-on-remarkable-paper-pro/blob/65b5bf34fb3ef160e3d483a14484b46304ecbc7c/device/android-takeover.sh
No global pgrep/kill, Debian paths, foreign AppLoad entries or QML edits.
"""
import argparse
import configparser
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import uuid

STATE = Path(os.environ.get("RMPP_ANDROID_STATE", "/home/root/.rmpp/android"))
ROOT = STATE / "rootfs"
META = json.loads(Path(os.environ["RMPP_ANDROID_META"]).read_text())
STOP = False
RESOLV_CONF = Path("/etc/resolv.conf")


def stop_signal(signum, frame):
    global STOP
    STOP = True


def run(*args, check=True, timeout=60, **kw):
    return subprocess.run([str(x) for x in args], check=check, timeout=timeout, **kw)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def own_state():
    if not STATE.is_absolute() or STATE == Path("/") or STATE.is_symlink():
        raise RuntimeError("invalid runtime state path")
    if STATE.exists() and not (STATE / ".rmpp-owned").is_file():
        raise RuntimeError(f"refusing to adopt foreign directory {STATE}")
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(STATE, 0o700)
    (STATE / ".rmpp-owned").touch()


def prepare():
    own_state()
    # This root contains only our files and writable Android state; /nix is
    # bound in at runtime. Nothing is written to the stock /var, /usr or /etc.
    paths = ["usr", "etc/labwc", "etc/ssl/certs", "etc/gbinder.d", "etc/lxc", "root", "var/lib/misc",
             "var/lib/waydroid", "var/log", "run/user/0", "run/udev", "tmp", "proc",
             "sys", "dev", "nix", "lib/modules", ".old-root"]
    files = ["bin", "sbin", "usr/bin", "usr/sbin", "etc/passwd", "etc/group",
             "etc/machine-id", "etc/resolv.conf", "etc/dbus-system.conf",
             "etc/gbinder.d/waydroid.conf", "etc/ssl/certs/ca-certificates.crt"]
    owned = {ROOT}
    for relative in paths + files:
        path = ROOT / relative
        while path != ROOT:
            owned.add(path)
            path = path.parent
    owned.update(STATE / p for p in (".rmpp-owned", "manifest", "session.lock", "session.log", "restore-xochitl"))
    write(STATE / "manifest", "\n".join(sorted(str(path) for path in owned)) + "\n")
    for p in paths:
        (ROOT / p).mkdir(parents=True, exist_ok=True)
    for name, target in {"bin": META["tools"] + "/bin", "usr/bin": "/bin", "usr/sbin": "/bin", "sbin": "/bin"}.items():
        path = ROOT / name
        if path.is_symlink():
            if os.readlink(path) == target:
                continue
            path.unlink()
        elif path.exists():
            raise RuntimeError(f"unexpected path in owned root: {path}")
        path.symlink_to(target)
    write(ROOT / "etc/passwd", "root:x:0:0:root:/root:/bin/bash\nnobody:x:65534:65534:nobody:/:/bin/false\n")
    write(ROOT / "etc/group", "root:x:0:\nnogroup:x:65534:\n")
    if not (ROOT / "etc/machine-id").exists():
        write(ROOT / "etc/machine-id", uuid.uuid4().hex + "\n")
    # https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/virtualisation/waydroid.nix
    write(ROOT / "etc/gbinder.d/waydroid.conf", "[Protocol]\n/dev/binder = aidl2\n/dev/vndbinder = aidl2\n/dev/hwbinder = hidl\n[ServiceManager]\n/dev/binder = aidl2\n/dev/vndbinder = aidl2\n/dev/hwbinder = hidl\n")
    write(ROOT / "etc/dbus-system.conf", '''<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>system</type><user>root</user>
<listen>unix:path=/run/dbus/system_bus_socket</listen><auth>EXTERNAL</auth>
<policy context="default"><deny own="*"/><deny send_destination="*"/></policy>
<policy user="root"><allow own="*"/><allow send_destination="*"/><allow receive_sender="*"/></policy>
</busconfig>\n''')
    shutil.copyfile(RESOLV_CONF, ROOT / "etc/resolv.conf")
    cert = ROOT / "etc/ssl/certs/ca-certificates.crt"
    if not cert.is_symlink():
        cert.symlink_to(META["caBundle"])
    os.chmod(ROOT / "tmp", 0o1777)
    os.chmod(ROOT / "run/user/0", 0o700)


def mount(source, target, *options):
    run("mount", *options, source, target)


def enter_root():
    if os.readlink("/proc/self/ns/mnt") == os.readlink("/proc/1/ns/mnt"):
        raise RuntimeError("internal namespace command requires a separate mount namespace")
    run("mount", "--make-rprivate", "/")
    # Executed only after unshare --mount --propagation private. Use a real
    # pivot_root rather than chroot: LXC needs to pivot its own Android root.
    mount(ROOT, ROOT, "--bind")
    mount("/nix", ROOT / "nix", "--rbind")
    mount("/proc", ROOT / "proc", "--bind")
    mount("/sys", ROOT / "sys", "--rbind")
    mount("/run/udev", ROOT / "run/udev", "--bind")
    if Path("/lib/modules").exists():
        mount("/lib/modules", ROOT / "lib/modules", "--bind")
    # Private /dev prevents binder creation and symlinks leaking onto the host.
    mount("tmpfs", ROOT / "dev", "-t", "tmpfs", "-o", "mode=755")
    for path in Path("/dev").iterdir():
        if path.name in ("binderfs", "fd", "stdin", "stdout", "stderr", "ptmx"):
            continue
        target = ROOT / "dev" / path.name
        if path.is_symlink():
            target.symlink_to(os.readlink(path))
        elif path.is_dir():
            target.mkdir()
            mount(path, target, "--rbind")
        else:
            target.touch()
            mount(path, target, "--bind")
    for name, target in {"fd": "/proc/self/fd", "stdin": "/proc/self/fd/0", "stdout": "/proc/self/fd/1", "stderr": "/proc/self/fd/2", "ptmx": "pts/ptmx"}.items():
        (ROOT / "dev" / name).symlink_to(target)
    os.chdir(ROOT)
    run("pivot_root", ".", ".old-root")
    os.chdir("/")
    run("umount", "-l", "/.old-root")
    os.environ.update(HOME="/root", XDG_RUNTIME_DIR="/run/user/0", WAYLAND_DISPLAY="wayland-0",
                      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/0/bus", SSL_CERT_FILE=META["caBundle"])


def namespace_command(command, *arguments):
    return ["unshare", "--mount", "--propagation", "private", "--", sys.executable,
            str(Path(__file__).resolve()), "_namespace", command, *arguments]


def configure_gpu(config_file):
    # Runtime image properties from upstream README (GBM/etnaviv):
    # https://github.com/MaximeRivest/android-on-remarkable-paper-pro/blob/65b5bf34fb3ef160e3d483a14484b46304ecbc7c/README.md
    config = configparser.ConfigParser()
    config.read(config_file)
    if not config.has_section("properties"):
        config.add_section("properties")
    config["properties"].update({"ro.hardware.gralloc": "gbm", "ro.hardware.egl": "mesa",
                                  "gralloc.gbm.device": "/dev/dri/renderD128"})
    with config_file.open("w") as handle:
        config.write(handle)


def spawn(argv, children, env=None):
    process = subprocess.Popen(argv, env=env, start_new_session=True)
    children.append(process)
    return process


def terminate(process, timeout=30):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"process group {process.pid} did not exit; refusing forced teardown")


def namespace_session():
    children = []
    try:
        Path("/run/dbus").mkdir(exist_ok=True)
        for stale in ("/run/dbus/system_bus_socket", "/run/user/0/bus", "/run/user/0/wayland-0", "/run/user/0/wayland-0.lock", "/run/seatd.sock"):
            Path(stale).unlink(missing_ok=True)
        spawn(["dbus-daemon", "--nofork", "--config-file=/etc/dbus-system.conf"], children)
        spawn(["dbus-daemon", "--session", "--nofork", "--address=unix:path=/run/user/0/bus"], children)
        env = dict(os.environ, SEATD_VTBOUND="0")
        spawn(["seatd", "-l", "info"], children, env=env)
        env.update(WLR_BACKENDS="headless,libinput", WLR_RENDERER="gles2",
                   WLR_RENDER_DRM_DEVICE="/dev/dri/renderD128", LIBSEAT_BACKEND="seatd",
                   LIBGL_DRIVERS_PATH=META["tools"] + "/lib/dri")
        spawn(["labwc", "-C", "/etc/labwc"], children, env=env)
        for _ in range(100):
            if STOP:
                return
            if any(p.poll() is not None for p in children):
                raise RuntimeError("a compositor or D-Bus process exited during startup")
            if Path("/run/user/0/wayland-0").is_socket() and Path("/run/dbus/system_bus_socket").is_socket():
                break
            time.sleep(.1)
        else:
            raise RuntimeError("session sockets did not become ready")
        # Preserve panel aspect ratio: touch and pen stay on labwc's physical
        # libinput seat rather than an invented mouse-only input bridge.
        run("wlr-randr", "--output", "HEADLESS-1", "--custom-mode", "810x1080@30")
        spawn(["waydroid", "container", "start"], children)
        for _ in range(60):
            if run("dbus-send", "--system", "--print-reply", "--dest=org.freedesktop.DBus", "/",
                   "org.freedesktop.DBus.NameHasOwner", "string:id.waydro.Container", check=False,
                   capture_output=True).stdout.find(b"boolean true") >= 0:
                break
            if STOP:
                return
            time.sleep(.5)
        else:
            raise RuntimeError("Waydroid container D-Bus service did not become ready")
        spawn(["waydroid", "session", "start"], children)
        write(Path("/run/rmpp-session-ready"), str(os.getpid()))
        # show-full-ui may wait for Android boot; keep it off the control loop.
        spawn(["waydroid", "show-full-ui"], children)
        while not STOP:
            # show-full-ui is allowed to exit after making its D-Bus request.
            if any(p.poll() is not None for p in children[:6]):
                raise RuntimeError("an essential session process exited")
            time.sleep(.5)
    finally:
        Path("/run/rmpp-session-ready").unlink(missing_ok=True)
        errors = []
        for component in ("session", "container"):
            try:
                run("waydroid", component, "stop", check=False, timeout=40)
            except (OSError, subprocess.SubprocessError) as error:
                errors.append(str(error))
        for process in reversed(children):
            try:
                terminate(process)
            except (OSError, RuntimeError) as error:
                errors.append(str(error))
        if errors:
            raise RuntimeError("; ".join(errors))


def check_device():
    installed = Path("/etc/version").read_text().strip().lstrip("v")
    if ".".join(installed.split(".")[:2]) != META["osVersion"]:
        raise RuntimeError(f"OS {installed} does not match pinned {META['osVersion']}")
    if os.uname().release != META["kernelRelease"]:
        raise RuntimeError(f"boot {META['kernelRelease']} first (running {os.uname().release})")
    if not Path("/proc/pressure/memory").exists():
        raise RuntimeError("PSI is unavailable")
    if not Path("/dev/dri/renderD128").exists():
        raise RuntimeError("etnaviv renderD128 is unavailable")
    driver = Path("/sys/class/drm/renderD128/device/driver").resolve()
    if driver.name != "etnaviv":
        raise RuntimeError(f"renderD128 belongs to {driver.name}, expected etnaviv")
    run(META["bridge"] + "/libexec/rmpp-quill-host", "--probe", "--quill-lib", META["quill"] + "/lib/libquill.so")


def inside(pid, *command, check=True, capture_output=False):
    return run("nsenter", "--mount", "--target", str(pid), "--root", "--wd=/", "--",
               META["tools"] + "/bin/env", "HOME=/root", "XDG_RUNTIME_DIR=/run/user/0",
               "WAYLAND_DISPLAY=wayland-0", "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus",
               *command, check=check, capture_output=capture_output, timeout=45)


def power_lock(held):
    Path("/sys/power/wake_lock" if held else "/sys/power/wake_unlock").write_text("rmpp-android")


def session_processes(token):
    tagged = []
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit() or int(proc.name) == os.getpid():
            continue
        try:
            if f"RMPP_ANDROID_SESSION={token}".encode() in (proc / "environ").read_bytes().split(b"\0"):
                tagged.append(int(proc.name))
        except (OSError, PermissionError):
            pass
    return tagged


def recover():
    flag = STATE / "restore-xochitl"
    if not flag.exists():
        return
    # Only our tagged descendants are considered. Never pgrep/kill another app.
    token = flag.read_text().strip()
    tagged = session_processes(token)
    if tagged:
        raise RuntimeError(f"session processes still exist ({tagged}); refusing to restart xochitl over a live panel owner")
    run("systemctl", "start", "xochitl")
    power_lock(False)
    flag.unlink()


def takeover():
    prepare()
    with (STATE / "session.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for module in ("etnaviv", "veth", "bridge", "tun", "iptable_nat", "xt_MASQUERADE"):
            run("modprobe", module)
        check_device()
        if not (ROOT / "var/lib/waydroid/waydroid.cfg").is_file():
            raise RuntimeError("run rmpp-android init first")
        if run("systemctl", "is-active", "--quiet", "xochitl", check=False).returncode:
            raise RuntimeError("xochitl is already stopped; another takeover may own the panel")
        if run("ip", "link", "show", "waydroid0", check=False, capture_output=True).returncode == 0:
            raise RuntimeError("waydroid0 already exists; refusing to interfere with a foreign session")
        token = uuid.uuid4().hex
        write(STATE / "restore-xochitl", token)
        os.environ["RMPP_ANDROID_SESSION"] = token
        power_lock(True)
        session = bridge = None
        try:
            run("systemctl", "stop", "xochitl")
            (ROOT / "run/rmpp-session-ready").unlink(missing_ok=True)
            with (STATE / "session.log").open("a") as log:
                session = subprocess.Popen(namespace_command("run"), stdout=log, stderr=log, start_new_session=True)
            for _ in range(400):
                if STOP:
                    return
                if session.poll() is not None:
                    raise RuntimeError("namespace session failed; see session.log")
                if (ROOT / "run/rmpp-session-ready").exists():
                    break
                time.sleep(.1)
            else:
                raise RuntimeError("namespace startup timed out")
            env = dict(os.environ, XDG_RUNTIME_DIR=str(ROOT / "run/user/0"), WAYLAND_DISPLAY="wayland-0")
            bridge = subprocess.Popen([META["bridge"] + "/bin/rmpp-einkbridge", "--quill-host",
                                       META["bridge"] + "/libexec/rmpp-quill-host", "--quill-lib",
                                       META["quill"] + "/lib/libquill.so"], env=env, start_new_session=True)
            booted = False
            while not STOP:
                if bridge.poll() is not None or session.poll() is not None:
                    raise RuntimeError("display bridge or Waydroid session exited")
                if not booted:
                    result = inside(session.pid, "waydroid", "shell", "--", "getprop", "sys.boot_completed", check=False, capture_output=True)
                    booted = result.returncode == 0 and result.stdout.strip() == b"1"
                    if booted:
                        inside(session.pid, "waydroid", "shell", "-u", "2000", "-g", "2000", "--", "settings", "put", "global", "airplane_mode_on", "0")
                else:
                    result = inside(session.pid, "waydroid", "shell", "-u", "2000", "-g", "2000", "--", "settings", "get", "global", "airplane_mode_on", check=False, capture_output=True)
                    if result.returncode == 0 and result.stdout.strip() == b"1":
                        break
                time.sleep(3)
        finally:
            # The panel must be released before compositor/Android shutdown and
            # before stock xochitl is allowed to open it again.
            if bridge is not None:
                # Signal the capture process only; it closes the worker socket
                # and waits for normal vendor teardown rather than SIGKILL.
                if bridge.poll() is None:
                    bridge.terminate()
                bridge.wait(timeout=90)
            if session is not None:
                terminate(session, timeout=90)
            os.environ.pop("RMPP_ANDROID_SESSION", None)
            recover()


def main():
    parser = argparse.ArgumentParser(description="Paper Pro Waydroid session control")
    parser.add_argument("command", choices=["init", "start", "stop", "status", "doctor", "run", "recover", "_namespace"])
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command in ("start", "stop", "status"):
        action = {"start": "start", "stop": "stop", "status": "status"}[args.command]
        command = ["systemctl", action]
        if action == "start":
            command.append("--no-block")
        raise SystemExit(run(*command, "rmpp-android.service", check=False).returncode)
    if os.geteuid() != 0:
        raise RuntimeError("run this command as root")
    signal.signal(signal.SIGTERM, stop_signal)
    signal.signal(signal.SIGINT, stop_signal)
    if args.command == "_namespace":
        enter_root()
        if args.arguments[0] == "init":
            run("waydroid", "init", *args.arguments[1:], timeout=None)
            configure_gpu(Path("/var/lib/waydroid/waydroid.cfg"))
            run("waydroid", "upgrade", "-o", timeout=None)
        elif args.arguments[0] == "run":
            namespace_session()
        elif args.arguments[0] == "test":
            run("/bin/sh", "-c", "test -x /bin/waydroid && test -d /nix/store && test -f /etc/machine-id && /bin/waydroid --version")
            Path("/run/dbus").mkdir(exist_ok=True)
            bus = subprocess.Popen(["dbus-daemon", "--nofork", "--config-file=/etc/dbus-system.conf"], start_new_session=True)
            try:
                for _ in range(100):
                    if Path("/run/dbus/system_bus_socket").is_socket():
                        break
                    if bus.poll() is not None:
                        raise RuntimeError("private D-Bus failed to start")
                    time.sleep(.05)
                run("dbus-send", "--system", "--print-reply", "--dest=org.freedesktop.DBus", "/", "org.freedesktop.DBus.GetId")
            finally:
                terminate(bus)
        return
    if args.command == "init":
        prepare()
        with (STATE / "session.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            run(*namespace_command("init", *args.arguments), timeout=None)
    elif args.command == "doctor":
        check_device()
    elif args.command == "run":
        takeover()
    else:
        recover()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f"rmpp-android: {error}", file=sys.stderr)
        raise SystemExit(1)
