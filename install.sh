#!/data/data/com.termux/files/usr/bin/env bash
#
# install.sh - Install postmarketOS (Phosh) inside Termux via proot-distro.
#
# Based on: https://ivonblog.com/en-us/posts/postmarketos-in-termux-proot/
#
# Run inside Termux:
#   bash install.sh [options]
#
# Options:
#   --ui <phosh|plasma-mobile|sxmo>  Mobile UI to install (default: phosh)
#   --alias <name>                   proot-distro alias (default: pmos)
#   --user <name>                    Username created in the guest (default: user)
#   --timezone <Region/City>         Guest timezone (default: UTC)
#   --alpine-version <ver>           Alpine branch to pin (default: v3.20)
#   --pmos-version <ver>             postmarketOS release (default: v24.06)
#   --no-firefox                     Skip Firefox + fonts
#   -h, --help                       Show this help
#
set -euo pipefail

UI="phosh"
ALIAS="pmos"
GUEST_USER="user"
TIMEZONE="UTC"
ALPINE_VERSION="v3.20"
PMOS_VERSION="v24.06"
INSTALL_EXTRAS=1

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
	case "$1" in
		--ui)              UI="${2:?}"; shift 2 ;;
		--alias)           ALIAS="${2:?}"; shift 2 ;;
		--user)            GUEST_USER="${2:?}"; shift 2 ;;
		--timezone)        TIMEZONE="${2:?}"; shift 2 ;;
		--alpine-version)  ALPINE_VERSION="${2:?}"; shift 2 ;;
		--pmos-version)    PMOS_VERSION="${2:?}"; shift 2 ;;
		--no-firefox)      INSTALL_EXTRAS=0; shift ;;
		-h|--help)         usage ;;
		*)                 die "Unknown option: $1 (try --help)" ;;
	esac
done

case "$UI" in
	phosh|plasma-mobile|sxmo) ;;
	*) die "--ui must be one of: phosh, plasma-mobile, sxmo" ;;
esac

# ---------------------------------------------------------------------------
# 1. Sanity checks
# ---------------------------------------------------------------------------
[ -n "${PREFIX:-}" ] && [ -d "$PREFIX" ] || die "This script must be run inside Termux."
case "$PREFIX" in
	*com.termux*) ;;
	*) warn "PREFIX does not look like Termux ($PREFIX); continuing anyway." ;;
esac
command -v pkg >/dev/null 2>&1 || die "'pkg' not found - are you running Termux?"

log "Installing postmarketOS $PMOS_VERSION ($UI) as proot-distro alias '$ALIAS'"

# ---------------------------------------------------------------------------
# 2. Termux side packages
# ---------------------------------------------------------------------------
log "Updating Termux packages"
pkg update -y || true
pkg install -y proot-distro pulseaudio x11-repo
# termux-x11-nightly and virglrenderer-android live in x11-repo; virgl is optional.
pkg install -y termux-x11-nightly || warn "termux-x11-nightly not installed - install the Termux:X11 app + package manually."
pkg install -y virglrenderer-android || warn "virglrenderer-android unavailable - hardware acceleration will be off."

# ---------------------------------------------------------------------------
# 3. Alpine rootfs
# ---------------------------------------------------------------------------
ROOTFS="$PREFIX/var/lib/proot-distro/installed-rootfs/$ALIAS"
if [ -d "$ROOTFS" ]; then
	log "proot-distro alias '$ALIAS' already installed - reusing it"
else
	log "Installing Alpine rootfs as '$ALIAS'"
	proot-distro install alpine --override-alias "$ALIAS"
fi

# ---------------------------------------------------------------------------
# 4. Guest setup script (runs as root inside the rootfs)
# ---------------------------------------------------------------------------
log "Writing guest setup script"
cat > "$ROOTFS/root/pmos-setup.sh" <<GUEST_EOF
#!/bin/sh
set -eu

ALPINE_VERSION="$ALPINE_VERSION"
PMOS_VERSION="$PMOS_VERSION"
GUEST_USER="$GUEST_USER"
TIMEZONE="$TIMEZONE"
UI="$UI"
INSTALL_EXTRAS="$INSTALL_EXTRAS"
GUEST_EOF

cat >> "$ROOTFS/root/pmos-setup.sh" <<'GUEST_EOF'

log() { printf '\033[1;36m  ->\033[0m %s\n' "$*"; }

# --- 4a. Pin Alpine to a stable branch (edge breaks pmOS packages) ----------
log "Pinning Alpine repositories to $ALPINE_VERSION"
sed -i "s|/edge/|/$ALPINE_VERSION/|g" /etc/apk/repositories
# Make sure both main and community are present and enabled.
grep -q "$ALPINE_VERSION/community" /etc/apk/repositories || \
	printf 'https://dl-cdn.alpinelinux.org/alpine/%s/community\n' "$ALPINE_VERSION" >> /etc/apk/repositories
sed -i 's|^#\(https://dl-cdn.alpinelinux.org/alpine/.*\)|\1|' /etc/apk/repositories

apk update
apk upgrade --available

# --- 4b. Base tooling, user, sudo ------------------------------------------
log "Installing base tooling"
apk add sudo shadow tzdata dbus dbus-x11 openssh vim

log "Creating user '$GUEST_USER'"
addgroup -S storage 2>/dev/null || true
if ! id "$GUEST_USER" >/dev/null 2>&1; then
	adduser -D -s /bin/sh "$GUEST_USER"
	passwd -u "$GUEST_USER" >/dev/null 2>&1 || true
fi
for grp in wheel storage video audio input; do
	addgroup -S "$grp" 2>/dev/null || true
	adduser "$GUEST_USER" "$grp" 2>/dev/null || true
done

# Passwordless sudo for wheel - there is no password on the proot account.
mkdir -p /etc/sudoers.d
printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

log "Setting timezone to $TIMEZONE"
if [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
	ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
	printf '%s\n' "$TIMEZONE" > /etc/timezone
fi

# --- 4c. SSH on 8023 (port 22 is not usable on Android) ---------------------
if [ -f /etc/ssh/sshd_config ]; then
	sed -i 's/^#\?Port .*/Port 8023/' /etc/ssh/sshd_config
	ssh-keygen -A >/dev/null 2>&1 || true
fi

# --- 4d. Convert Alpine -> postmarketOS ------------------------------------
log "Adding postmarketOS $PMOS_VERSION repository"
PMOS_REPO="https://mirror.postmarketos.org/postmarketos/$PMOS_VERSION"
grep -qxF "$PMOS_REPO" /etc/apk/repositories || printf '%s\n' "$PMOS_REPO" >> /etc/apk/repositories

log "Importing postmarketOS signing keys"
apk add -u --allow-untrusted postmarketos-keys
apk update
apk upgrade --available

log "Writing /etc/os-release"
cat > /etc/os-release <<OSRELEASE
PRETTY_NAME="postmarketOS $PMOS_VERSION"
NAME="postmarketOS"
VERSION_ID="$PMOS_VERSION"
VERSION="$PMOS_VERSION"
ID="postmarketos"
ID_LIKE="alpine"
HOME_URL="https://www.postmarketos.org/"
SUPPORT_URL="https://gitlab.com/postmarketOS"
BUG_REPORT_URL="https://gitlab.com/postmarketOS/pmaports/issues"
LOGO="postmarketos-logo"
OSRELEASE

# --- 4e. Desktop / mobile shell --------------------------------------------
log "Installing compositor base (openbox, cage)"
apk add openbox cage

case "$UI" in
	phosh)
		log "Installing Phosh"
		apk add postmarketos-ui-phosh postmarketos-tweaks
		;;
	plasma-mobile)
		log "Installing Plasma Mobile"
		apk add postmarketos-ui-plasma-mobile postmarketos-tweaks
		;;
	sxmo)
		log "Installing SXMO"
		apk add postmarketos-ui-sxmo-de-dwm postmarketos-tweaks-sxmo-x11 \
			feh dwm svkbd conky clickclack
		;;
esac

if [ "$INSTALL_EXTRAS" = "1" ]; then
	log "Installing Firefox and Noto fonts"
	apk add firefox mobile-config-firefox font-noto font-noto-cjk \
		font-noto-cjk-extra font-noto-emoji || \
		printf '  [!] Some extras failed to install; continuing.\n'
fi

log "Guest setup complete."
GUEST_EOF

chmod +x "$ROOTFS/root/pmos-setup.sh"

log "Running guest setup (this downloads a few hundred MB and takes a while)"
proot-distro login "$ALIAS" --shared-tmp -- /bin/sh /root/pmos-setup.sh

# ---------------------------------------------------------------------------
# 5. Launcher
# ---------------------------------------------------------------------------
LAUNCHER="$PREFIX/bin/pmos-$UI"
log "Writing launcher: $LAUNCHER"

case "$UI" in
	phosh)
		START_CMD="openbox & sleep 1; exec cage phoc -E /usr/libexec/phosh -U"
		;;
	plasma-mobile)
		START_CMD="openbox & sleep 1; exec dbus-launch --exit-with-session startplasma-x11"
		;;
	sxmo)
		START_CMD="exec dbus-launch --exit-with-session /usr/bin/sxmo_xinit.sh"
		;;
esac

cat > "$LAUNCHER" <<LAUNCH_EOF
#!/data/data/com.termux/files/usr/bin/env bash
# Start postmarketOS ($UI) in Termux:X11. Generated by install.sh.
set -u

ALIAS="$ALIAS"
GUEST_USER="$GUEST_USER"

# Audio: expose PulseAudio over loopback TCP so the guest can reach it.
pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
pacmd load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 >/dev/null 2>&1 || true

export DISPLAY=:0

# X server. Open the Termux:X11 app after this starts.
pkill -f 'termux-x11 :0' >/dev/null 2>&1 || true
termux-x11 :0 >/dev/null 2>&1 &
sleep 3

# Optional GPU acceleration.
if command -v virgl_test_server_android >/dev/null 2>&1; then
	pkill -f virgl_test_server_android >/dev/null 2>&1 || true
	virgl_test_server_android >/dev/null 2>&1 &
	sleep 1
fi

echo "Switch to the Termux:X11 app now."

proot-distro login "\$ALIAS" --user "\$GUEST_USER" --shared-tmp -- /bin/sh -c '
	export DISPLAY=:0
	export XDG_RUNTIME_DIR=/tmp
	export PULSE_SERVER=127.0.0.1
	export GALLIUM_DRIVER=virpipe
	$START_CMD
'
LAUNCH_EOF

chmod +x "$LAUNCHER"

log "Done."
cat <<EOM

Next steps:
  1. Install the Termux:X11 app (github.com/termux/termux-x11 releases) if you
     have not already.
  2. Start the desktop with:

         pmos-$UI

  3. Switch to the Termux:X11 app once the launcher tells you to.

  Shell into the guest without a GUI:

         proot-distro login $ALIAS --user $GUEST_USER --shared-tmp

EOM
