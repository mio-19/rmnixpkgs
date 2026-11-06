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

# --- ownership -------------------------------------------------------------

# Delete a path this configuration used to own. Anything outside the two
# directories this layer is allowed to manage, or an AppLoad entry that is not
# marked as ours, is left untouched.
remove_owned() {
	path=$1
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

		if [ -e "$target" ] && [ ! -f "$target/$MARKER" ]; then
			warn "skipping AppLoad entry '$app': already exists and was not created by rmpp-config (vellum or a hand install owns it)"
			continue
		fi

		mkdir -p "$APPDIR"
		rm -rf "$target.tmp"
		cp -a "$src" "$target.tmp"
		rm -rf "$target"
		mv "$target.tmp" "$target"
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

	managed=""
	while IFS= read -r pkg; do
		[ -n "$pkg" ] || continue
		"$VELLUM" add "$pkg" || warn "vellum add $pkg failed"
		managed="$managed $pkg"
	done <"$gen/vellum.packages"

	if [ "$cleanup" = 1 ] && [ -f "$VELLUM_STATE" ]; then
		while IFS= read -r old; do
			[ -n "$old" ] || continue
			case " $managed " in
			*" $old "*) continue ;;
			esac
			log "vellum del $old (no longer declared)"
			"$VELLUM" del "$old" || warn "vellum del $old failed"
		done <"$VELLUM_STATE"
	fi

	# Intentional word splitting: $managed is a space-separated list.
	# shellcheck disable=SC2086
	printf '%s\n' $managed >"$VELLUM_STATE"
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
prune_old
apply_etc
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
