#!/usr/bin/env python3
"""Check the built Paper Pro kernel, modules and GPU DTBs for Waydroid.

Requirements come from the pinned upstream waydroid.cfg and test-gate.sh:
https://github.com/MaximeRivest/android-on-remarkable-paper-pro/tree/65b5bf34fb3ef160e3d483a14484b46304ecbc7c/kernel
Container prerequisites also follow the NixOS Waydroid module:
https://github.com/NixOS/nixpkgs/blob/6dadaf4375be35033e1c84395adbd53ff5fded96/nixos/modules/virtualisation/waydroid.nix
This checks build artifacts; it does not substitute for booting on hardware.
"""
from pathlib import Path
import re
import subprocess
import sys


def read_config(path):
    values = {}
    for line in path.read_text().splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
        elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
            values[line.split()[1]] = "n"
    return values


def verify(fragment, kernel):
    config = read_config(kernel / "share/rmpp-kernel/config")
    requirements = read_config(fragment)
    # nft_counter.o is unconditional inside nf_tables in Linux 6.12; there is
    # no NFT_COUNTER Kconfig symbol. Keep upstream's fragment unchanged.
    # https://github.com/torvalds/linux/blob/v6.12/net/netfilter/Makefile#L79-L98
    requirements.pop("CONFIG_NFT_COUNTER", None)
    requirements.update({f"CONFIG_{name}": "y" for name in (
        "NAMESPACES", "UTS_NS", "IPC_NS", "PID_NS", "NET_NS", "USER_NS",
        "CGROUPS", "MEMFD_CREATE", "SECCOMP", "SECCOMP_FILTER",
    )})
    failures = []
    for name, want in requirements.items():
        have = config.get(name, "n")
        # Built-in satisfies a module request, but a module cannot satisfy a
        # built-in request (e.g. binder and PSI must exist before userspace).
        if have != want and not (want == "m" and have == "y"):
            failures.append(f"{name}: expected {want}, got {have}")

    release_dirs = list((kernel / "lib/modules").iterdir())
    if len(release_dirs) != 1:
        failures.append("expected exactly one module release")
    else:
        release = release_dirs[0]
        if not release.name.endswith("-waydroid"):
            failures.append(f"unexpected module release {release.name}")
        modules = {p.name.split(".ko", 1)[0].replace("-", "_") for p in release.rglob("*.ko*")}
        # Confirm the configured drivers were actually shipped, not merely
        # enabled in a .config that could belong to a different build.
        for name in ("etnaviv", "gpu_sched", "veth", "bridge", "tun", "iptable_nat"):
            if name not in modules:
                failures.append(f"missing {name}.ko")
        if not (kernel / f"modules-{release.name}.tar.gz").is_file():
            failures.append("missing modules archive")

    for artifact in ("fitImage", "Image"):
        path = kernel / artifact
        if not path.is_file() or path.stat().st_size == 0:
            failures.append(f"missing {artifact}")
    for rev in "cdef":
        path = kernel / f"dtbs/ferrari-rev-{rev}.dtb"
        if not path.is_file():
            failures.append(f"missing {path.name}")
            continue
        dts = subprocess.check_output(["dtc", "-q", "-I", "dtb", "-O", "dts", str(path)], text=True)
        gpu = re.search(r"gpu@38000000\s*\{([^}]+)\}", dts)
        if not gpu or not all(s in gpu[1] for s in ('compatible = "vivante,gc";', 'status = "okay";')):
            failures.append(f"{path.name}: etnaviv GPU node is not enabled")
    if failures:
        raise SystemExit("\n".join(failures))
    print(f"Verified {len(requirements)} kernel settings, module payload, images and four Ferrari GPU DTBs")


if __name__ == "__main__":
    verify(Path(sys.argv[1]), Path(sys.argv[2]))
