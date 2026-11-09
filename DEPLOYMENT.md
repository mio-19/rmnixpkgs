# Deployment and First-Time Installation Guide

This guide documents the complete end-to-end process for deploying `rmnixpkgs` (declarative system configuration, native Qt applications, and persistent Nix store) to the reMarkable Paper Pro (`ferrari`, `aarch64`).

---

## 1. Prerequisites

1. **Hardware & Cabling:**
   - reMarkable Paper Pro connected via USB-C to the build host.
   - Device accessible over USB network interface at `10.11.99.1`.
2. **Developer Mode Enabled on Device:**
   - On the device, open **Menu (top left) → Settings → General → Software → Developer mode** (or **Settings → Help → About → Copyrights and licenses**).
   - Toggle **Developer mode** to `ON`.
   - Take note of the displayed `root` password.
3. **Build Host Environment:**
   - A native `aarch64-linux` builder running Nix with flakes enabled (e.g. an OrbStack Linux VM `nixos` on Apple Silicon).

---

## 2. Passwordless SSH Setup

From the build host / macOS workstation, install your SSH public key onto the tablet so `nix copy` and remote scripts execute without password prompts:

```sh
# Set tablet IP and developer mode password
DEVICE_IP="10.11.99.1"
PASSWORD="<your-developer-mode-password>"

# Add your host and VM public keys to the tablet
ssh-keygen -R "$DEVICE_IP" 2>/dev/null || true
nix shell nixpkgs#sshpass nixpkgs#openssh --command \
  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "root@$DEVICE_IP" \
  "mkdir -p /home/root/.ssh && cat >> /home/root/.ssh/authorized_keys << 'EOF'
$(cat ~/.ssh/id_ed25519.pub)
EOF
chmod 700 /home/root/.ssh && chmod 600 /home/root/.ssh/authorized_keys"

# Verify passwordless login
ssh root@10.11.99.1 uname -a
```

---

## 3. Persistent Nix Store Installation (`rmpp-nix-setup`)

The Paper Pro boots with `/` read-only. Persistent user data lives on `/home` (surviving OS updates). `nix-setup.sh` sets up an encrypted, persistent store under `/home/root/nix` bind-mounted onto `/nix`:

```sh
# 1. Copy the setup script to the device
scp ./nix-setup.sh root@10.11.99.1:/tmp/rmpp-nix-setup

# 2. Run with --persist to wire the mount and install the systemd nix.mount unit
ssh root@10.11.99.1 'sh /tmp/rmpp-nix-setup --persist'

# 3. Verify the Nix installation and store capacity
ssh root@10.11.99.1 'export PATH=/nix/var/nix/profiles/default/bin:$PATH && nix --version && df -h /nix'
```

---

## 4. Building Packages on the aarch64 Builder

On your `aarch64-linux` builder (e.g. `nixos` OrbStack VM), build the declarative system configuration generation and any desired applications:

```sh
cd /path/to/rmnixpkgs

# Build the declarative system configuration generation
nix --extra-experimental-features "nix-command flakes" build .#packages.aarch64-linux.rmpp_config -o rmpp-config

# Build the native offline Wikipedia reader (pure Qt Quick + libzim C++ backend)
nix --extra-experimental-features "nix-command flakes" build .#packages.aarch64-linux.rmpp_wikipedia -o rmpp-wikipedia

# (Optional) Build other applications or tools:
# nix build .#packages.aarch64-linux.rmpp_rmweb
# nix build .#packages.aarch64-linux.rmpp_android
# nix build .#packages.aarch64-linux.rmpp_tools
```

---

## 5. Copying Closures to the Device

Copy the immutable store paths to the tablet using `nix copy`:

```sh
nix --extra-experimental-features "nix-command flakes" copy \
  --to "ssh://root@10.11.99.1?remote-program=/nix/var/nix/profiles/default/bin/nix-store" \
  ./rmpp-config ./rmpp-wikipedia
```

---

## 6. Activation & Installing the Boot Service

Run the generation's activation script on the tablet. Using `--install-boot-unit` installs `rmpp-config.service` into the real rootfs, ensuring the declarative configuration is re-applied automatically after every reboot:

```sh
# 1. Query the target generation path from the built symlink
GEN_PATH=$(readlink -f ./rmpp-config)

# 2. Execute activation on the device
ssh root@10.11.99.1 "$GEN_PATH/activate --install-boot-unit"
```

### What Activation Does:
- **Zero Boot Blocking:** `rmpp-config.service` runs decoupled from `xochitl.service` (`Before=xochitl.service` is eliminated), and `apply_vellum` is skipped during early boot. The boot sequence finishes in `< 0.2` seconds without waiting on offline network timeouts.
- **XOVI / AppLoad Integration:** Registers external app tiles under `/home/root/xovi/exthome/appload/` for:
  - `Wikipedia` (native e-ink reader with `libzim`)
  - `Kiwix` (Kiwix Desktop with high-DPI scaling)
  - `rmweb` (WPE WebKit browser)
  - `rmpp-android` (Waydroid container session)
- **Host Key Protection:** Ensures `/etc/dropbear` bind-mounts remain intact during rootfs remounts so SSH sessions never disconnect.

---

## 7. Knowledge Base (ZIM) Setup

Place any offline `.zim` archives (Wikipedia, StackOverflow, Wikivoyage, Alpine Wiki, etc.) directly into `/home/root/zim/`:

```sh
# Example: Copy a ZIM file to the device
scp /path/to/my_archive.zim root@10.11.99.1:/home/root/zim/
```

Both the **Wikipedia** app and the **Kiwix** app automatically detect and index files located in `/home/root/zim/*.zim`.

---

## 8. Verifying Live Operation

Verify that the system units and launcher entries are running as expected:

```sh
# Check that nix.mount and rmpp-config services are active
ssh root@10.11.99.1 'systemctl is-active nix.mount rmpp-config.service'

# Verify installed AppLoad entries
ssh root@10.11.99.1 'ls -la /home/root/xovi/exthome/appload/'
```

---

## 9. Re-Enabling After a Firmware Update

When reMarkable releases an official OS update, the active rootfs partition is replaced while `/home` remains untouched. To restore functionality:
1. Re-enable Developer Mode if needed in Settings.
2. Re-wire the boot mount and unit:
   ```sh
   ssh root@10.11.99.1 'sh /tmp/rmpp-nix-setup --persist'
   ssh root@10.11.99.1 '/home/root/.rmpp/current/activate --install-boot-unit'
   ```
