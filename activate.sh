#!/bin/sh
# rmpp-config activation: make the device match a configuration generation.
#
# Runs ON the tablet as root. Two entry points:
#   activate [GENERATION]        apply now (default: the generation this script
#                                lives in)
#   activate --install-boot-unit apply, and install rmpp-config.service into the
#                                real rootfs so every boot re-applies it. That is
#                                the only step that needs a writable /, and it is
#                                what has to be re-run after a reMarkable OS
#                                update (the equivalent of `vellum reenable` for
#                                packages vellum owns).
#   activate --boot              what the boot unit runs (no unit install).
#
# Design, inherited from https://github.com/numtide/system-manager: the
# generation is an immutable store path and activation is the only thing that
# writes outside it.
#
# Adaptation for this device: / is read-only and /etc is an overlay on tmpfs, so
# /etc writes are re-applied at boot instead of being persisted into the rootfs;
# the remount/collapse sequence is the same one nix-setup.sh and the XOVI
# community use (see remarkable-paper-pro.md), and vellum's own `mount-utils`
# helpers are preferred when present because vellum already owns that dance.
#
# COEXISTENCE: this script only creates and deletes paths listed in the
# generation's `manifest`. It never touches /home/root/.vellum (vellum's apk
# database, repositories and licences), never writes XOVI extensions
# (/home/root/xovi/extensions.d), never replaces an AppLoad entry it did not
# create (see https://github.com/asivery/rm-appload, app dir
# /home/root/xovi/exthome/appload/<name>/), and never installs a unit that does
# not start with rmpp-.
set -eu

STATE="${RMPP_STATE:-/home/root/.rmpp}"
PROFILE="$STATE/current"
GCROOT=/nix/var/nix/gcroots/rmpp
APPDIR=/home/root/xovi/exthome/appload
VELLUM=/home/root/.vellum/bin/vellum
VELLUM_MOUNT_RW=/home/root/.vellum/bin/mount-rw
VELLUM_MOUNT_RESTORE=/home/root/.vellum/bin/mount-restore
VELLUM_STATE=$STATE/vellum-managed
# vellum's apk database: the truth about what is installed (vellum layout, see
# TODO.md — /home/root/.vellum/lib/apk/db holds apk's `installed` file).
VELLUM_DB=${VELLUM_DB:-/home/root/.vellum/lib/apk/db/installed}
# Where the OS reports its own release. Overridable so the check can be exercised
# off-device (see the checks in remarkable-paper-pro.md).
OS_VERSION_FILE=${OS_VERSION_FILE:-/etc/version}
MARKER=.rmpp-config
BOOT_UNIT=rmpp-config.service

log() { printf 'rmpp-config: %s\n' "$*"; }
warn() { printf 'rmpp-config: warn: %s\n' "$*" >&2; }
die() {
	printf 'rmpp-config: error: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
usage: activate [GENERATION] [--boot | --install-boot-unit]

  GENERATION           generation to apply (default: the one holding this script)
  --boot               apply only; used by rmpp-config.service at boot
  --install-boot-unit  apply, then install rmpp-config.service into the rootfs
  -h, --help           this text

Everything is re-applied from the store; nothing is stored in the rootfs except
the boot unit, which an OS update removes (run --install-boot-unit again).
EOF
}

mode=apply
gen=
for arg in "$@"; do
	case "$arg" in
	--boot) mode=boot ;;
	--install-boot-unit) mode=install-unit ;;
	-h | --help)
		usage
		exit 0
		;;
	-*) die "unknown option: $arg" ;;
	*) gen="$arg" ;;
	esac
done

if [ -z "$gen" ]; then
	gen=$(cd "$(dirname "$0")" && pwd -P)
fi
[ -f "$gen/manifest" ] || die "$gen is not an rmpp-config generation (no manifest)"

[ "$(id -u)" -eq 0 ] || die "run this as root on the tablet"

# --- checks ----------------------------------------------------------------

# What the device actually runs vs what this generation was built for. The
# installed release is /etc/version, the file the OS itself (and vellum's
# generated `remarkable-os` package) uses. A mismatch is reported, not fatal: a
# boot must still finish, but it means the kernel pin, glibc and Qt ABI declared
# in os.nix describe a different release than the one running.
os_short() { printf '%s' "${1#v}" | cut -d. -f1,2; }

check_os() {
	[ -f "$gen/os" ] || return 0

	want_os=$(sed -n 's/^version=//p' "$gen/os")
	want_kernel=$(sed -n 's/^kernel-version=//p' "$gen/os")
	have_os=$(head -n1 "$OS_VERSION_FILE" 2>/dev/null | tr -d ' \t\r\n' || true)

	if [ -z "$have_os" ]; then
		warn "cannot read the installed reMarkable OS version from $OS_VERSION_FILE"
		warn "this generation was built for $want_os; expect kernel/ABI mismatches"
	elif [ "$(os_short "$have_os")" = "$(os_short "$want_os")" ]; then
		log "reMarkable OS $have_os matches the generation ($want_os)"
	else
		warn "reMarkable OS mismatch: device runs $have_os, generation built for $want_os"
		warn "edit os.nix (version, kernel source pin, glibc, Qt) and rebuild; a program linked against the system may fail to load"
	fi

	# rmpp_kernel sets CONFIG_LOCALVERSION="-waydroid", so its release is
	# <version>-waydroid while the stock one is bare <version>. Comparing the
	# bare version alone cannot tell them apart.
	have_kernel=$(uname -r)
	case "$have_kernel" in
	"$want_kernel-waydroid") log "kernel $have_kernel (rmpp_kernel)" ;;
	"$want_kernel")
		warn "device runs the stock kernel $have_kernel, not $want_kernel-waydroid (rmpp_kernel is not installed, or an OTA replaced it)"
		;;
	*)
		warn "device runs kernel $have_kernel, generation expects $want_kernel-waydroid"
		;;
	esac
}

# --- ownership -------------------------------------------------------------

# Delete a path this configuration used to own. Anything outside the two
# directories this layer is allowed to manage, or an AppLoad entry that is not
# marked as ours, is left untouched.
remove_owned() {
	path=${1%/}
	case "$path" in
	/etc/* | /home/root/xovi/exthome/appload/*) ;;
	*)
		warn "refusing to remove path outside the managed set: $path"
		return 0
		;;
	esac
	if [ -d "$path" ]; then
		if [ ! -f "$path/$MARKER" ]; then
			warn "leaving $path: not created by rmpp-config"
			return 0
		fi
		rm -rf "$path"
	elif [ -e "$path" ] || [ -L "$path" ]; then
		rm -f "$path"
	fi
}

prune_old() {
	[ -f "$STATE/manifest" ] || return 0
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		if ! grep -qxF "$path" "$gen/manifest"; then
			log "removing $path"
			remove_owned "$path"
		fi
	done <"$STATE/manifest"
}

# --- application ----------------------------------------------------------

apply_etc() {
	[ -f "$gen/etc.modes" ] || return 0
	while read -r file_mode rel; do
		[ -n "$rel" ] || continue
		[ -f "$gen/etc/$rel" ] || continue
		install -D -m "$file_mode" "$gen/etc/$rel" "/etc/$rel"
	done <"$gen/etc.modes"
}

# Declarative OS-update policy (rmpp.osUpdates). `systemctl mask` is nothing but
# a symlink to /dev/null, so it can ship as a file and be re-created at every
# boot; only stopping an already-running updater needs systemctl.
apply_masks() {
	[ -s "$gen/systemd.mask" ] || return 0
	while IFS= read -r unit; do
		[ -n "$unit" ] || continue
		if [ ! -e "/lib/systemd/system/$unit" ] && [ ! -e "/usr/lib/systemd/system/$unit" ]; then
			warn "no $unit exists on this OS; nothing to mask"
			continue
		fi
		ln -sf /dev/null "/etc/systemd/system/$unit"
		if command -v systemctl >/dev/null 2>&1; then
			systemctl is-active --quiet "$unit" && systemctl stop "$unit" || true
		fi
		log "masked $unit (reMarkable OS updates disabled by configuration)"
	done <"$gen/systemd.mask"
	command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
}

apply_units() {
	[ -d "$gen/systemd" ] || return 0
	for unit in "$gen/systemd"/*.service; do
		[ -f "$unit" ] || continue
		install -D -m 644 "$unit" "/etc/systemd/system/$(basename "$unit")"
	done

	if [ -s "$gen/systemd.enable" ]; then
		while read -r wants_dir unit_name; do
			[ -n "$unit_name" ] || continue
			mkdir -p "/etc/systemd/system/$wants_dir"
			ln -sf "/etc/systemd/system/$unit_name" "/etc/systemd/system/$wants_dir/$unit_name"
		done <"$gen/systemd.enable"
	fi

	if command -v systemctl >/dev/null 2>&1; then
		systemctl daemon-reload || warn "systemctl daemon-reload failed"
		if [ -s "$gen/systemd.enable" ]; then
			while read -r _ unit_name; do
				[ -n "$unit_name" ] || continue
				# Starting ourselves from inside ourselves would loop.
				[ "$unit_name" = "$BOOT_UNIT" ] && continue
				systemctl is-active --quiet "$unit_name" ||
					systemctl start "$unit_name" || warn "could not start $unit_name"
			done <"$gen/systemd.enable"
		fi
	else
		warn "systemctl not found; units installed but not enabled"
	fi
}

apply_appload() {
	[ -d "$gen/appload" ] || return 0
	for src in "$gen/appload"/*/; do
		[ -d "$src" ] || continue
		app=$(basename "$src")
		target="$APPDIR/$app"

		if { [ -e "$target" ] || [ -L "$target" ]; } &&
			{ [ -L "$target" ] || [ ! -f "$target/$MARKER" ]; }; then
			warn "skipping AppLoad entry '$app': already exists and was not created by rmpp-config (vellum or a hand install owns it)"
			continue
		fi

		mkdir -p "$APPDIR"
		stage=$(mktemp -d "$APPDIR/.rmpp-stage.XXXXXX")
		cp -a "$src". "$stage/"
		rm -rf "$target"
		mv "$stage" "$target"
		log "installed AppLoad entry $app"
	done
}

# Declarative vellum packages, the way nix-darwin's Homebrew module applies
# `brews` on activation (https://github.com/nix-darwin/nix-darwin/blob/master/modules/homebrew.nix).
# Two deliberate differences, both about this device:
#   * cleanup only removes packages this layer recorded in $VELLUM_STATE, never
#     something vellum, a hand-installed .apk, or another tool's dependency
#     brought in — a typo in config.nix must not uninstall XOVI;
#   * failures warn instead of aborting: activation also runs at boot, and an
#     offline tablet still needs its units and AppLoad entries.
apply_vellum() {
	[ -f "$gen/vellum.packages" ] || return 0
	mkdir -p "$STATE"

	auto_update=0
	cleanup=0
	if [ -f "$gen/vellum.options" ]; then
		while IFS= read -r line; do
			case "$line" in
			auto-update=1) auto_update=1 ;;
			cleanup=1) cleanup=1 ;;
			esac
		done <"$gen/vellum.options"
	fi

	if [ ! -x "$VELLUM" ]; then
		warn "vellum not installed; skipping the declared packages (nothing else is affected)"
		return 0
	fi

	if [ "$auto_update" = 1 ]; then
		"$VELLUM" update || warn "vellum update failed (offline?)"
	fi

	# Keep ownership across activations, including while cleanup is disabled.
	managed=$(cat "$VELLUM_STATE" 2>/dev/null || true)
	while IFS= read -r pkg; do
		[ -n "$pkg" ] || continue
		name=$(printf '%s' "$pkg" | sed 's/[@=<>~].*//')
		# Never claim a pre-existing package, and do not guess if the DB is unreadable.
		was_installed=1
		if [ -r "$VELLUM_DB" ] && ! grep -qxF "P:$name" "$VELLUM_DB"; then
			was_installed=0
		fi
		if "$VELLUM" add "$pkg"; then
			if [ "$was_installed" = 0 ] && grep -qxF "P:$name" "$VELLUM_DB"; then
				managed="$managed $name"
			fi
		else
			warn "vellum add $pkg failed"
		fi
	done <"$gen/vellum.packages"

	retained=""
	for old in $managed; do
		[ -n "$old" ] || continue
		if [ "$cleanup" = 1 ] && ! sed 's/[@=<>~].*//' "$gen/vellum.packages" | grep -qxF "$old"; then
			log "vellum del $old (no longer declared)"
			if "$VELLUM" del "$old"; then
				continue
			fi
			warn "vellum del $old failed"
		fi
		retained="$retained $old"
	done
	managed=$retained

	# Verify what the list claims instead of trusting `vellum add`: it is
	# best-effort above (an offline boot fails it), so an activation that only
	# installed 2 of 5 packages must not look like success.
	if [ -s "$gen/vellum.packages" ]; then
		if [ -r "$VELLUM_DB" ]; then
			missing=0
			while IFS= read -r pkg; do
				[ -n "$pkg" ] || continue
				name=$(printf '%s' "$pkg" | sed 's/[@=<>~].*//')
				if grep -qx "P:$name" "$VELLUM_DB"; then
					log "vellum: $name installed"
				else
					warn "vellum: $pkg is declared but not installed (no $name in the apk database)"
					missing=$((missing + 1))
				fi
			done <"$gen/vellum.packages"
			if [ "$missing" -gt 0 ]; then
				warn "vellum: $missing declared package(s) missing; run 'vellum add <pkg>' once the device is online"
			fi
		else
			warn "vellum: cannot verify the declared packages (no apk database at $VELLUM_DB)"
		fi
	fi

	# Intentional word splitting: $managed is a space-separated list.
	# shellcheck disable=SC2086
	printf '%s\n' $managed | sort -u >"$VELLUM_STATE"
}

apply_profile() {
	mkdir -p "$STATE"
	ln -sfn "$gen" "$PROFILE"
	mkdir -p "$GCROOT"
	ln -sfn "$gen" "$GCROOT/current"

	profile=/home/root/.profile
	if ! grep -q 'rmpp-config' "$profile" 2>/dev/null; then
		{
			printf '\n# added by rmpp-config\n'
			printf 'case ":$PATH:" in *":%s/bin:"*) ;; *) PATH="%s/bin:$PATH" ;; esac\n' "$PROFILE" "$PROFILE"
			printf 'export PATH\n'
		} >>"$profile"
	fi
}

# --- boot unit ------------------------------------------------------------

# Make / writable (and get /etc onto the real rootfs), install the unit, then
# restore the stock mounts. vellum's helpers do exactly this and are preferred
# when mount-utils is installed; the fallback is the sequence documented in
# remarkable-paper-pro.md (same as nix-setup.sh).
install_boot_unit() {
	[ -f "$gen/systemd/$BOOT_UNIT" ] || die "generation has no $BOOT_UNIT; declare it in rmpp.systemd.services"

	restore() { :; }
	if [ -x "$VELLUM_MOUNT_RW" ]; then
		log "using vellum's mount-rw (mount-utils)"
		"$VELLUM_MOUNT_RW" || die "vellum mount-rw failed"
		restore() {
			if [ -x "$VELLUM_MOUNT_RESTORE" ]; then
				"$VELLUM_MOUNT_RESTORE" || warn "vellum mount-restore failed"
			else
				warn "vellum mount-restore missing; leaving mounts as they are"
			fi
		}
	else
		mount -o remount,rw / || die "could not remount / read-write (is developer mode enabled?)"
		if awk '$2 == "/etc" && $3 == "overlay" { found = 1 } END { exit !found }' /proc/mounts; then
			log "collapsing the /etc tmpfs overlay so the unit reaches the real rootfs"
			umount -R /etc || die "could not unmount the /etc overlay (a process may be holding it)"
			if [ -d /home/root/.dropbear ]; then
				mkdir -p /etc/dropbear
				mount --bind /home/root/.dropbear /etc/dropbear || warn "could not re-bind /etc/dropbear"
			fi
		fi
		restore() { mount -o remount,ro / || warn "could not remount / read-only"; }
	fi
	trap 'restore' EXIT HUP INT TERM

	install -D -m 644 "$gen/systemd/$BOOT_UNIT" "/etc/systemd/system/$BOOT_UNIT"
	mkdir -p /etc/systemd/system/multi-user.target.wants
	ln -sf "../$BOOT_UNIT" "/etc/systemd/system/multi-user.target.wants/$BOOT_UNIT"
	command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
	log "installed /etc/systemd/system/$BOOT_UNIT"
	restore
	trap - EXIT HUP INT TERM
}

# --- main -----------------------------------------------------------------

log "applying generation $gen"
check_os
prune_old
apply_etc
apply_masks
apply_units
apply_appload
apply_vellum
apply_profile
cp "$gen/manifest" "$STATE/manifest"
log "done (state: $STATE, profile: $PROFILE)"

[ "$mode" = install-unit ] && install_boot_unit
if [ "$mode" = apply ]; then
	log "this generation is live until the next reboot or activation"
	log "run 'activate --install-boot-unit' to have it re-applied at every boot"
fi
exit 0
