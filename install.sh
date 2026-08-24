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

# proot-distro's normal path pulls the 'alpine' image from Docker Hub. That
# pull has been unreliable (anonymous-pull "Unauthorized ... does not exist
# or is a private image" errors, see termux/proot-distro#692) independent of
# this script. If it fails, fetch Alpine's own minirootfs tarball and hand it
# to proot-distro as a local archive instead - it bypasses Docker Hub entirely.
install_alpine_from_minirootfs() {
	local uname_arch alpine_arch pd_arch base_ver mirror_dir listing latest tarball tmp_tar

	uname_arch="$(uname -m)"
	case "$uname_arch" in
		aarch64) alpine_arch="aarch64"; pd_arch="aarch64" ;;
		armv7l|armv8l) alpine_arch="armv7"; pd_arch="arm" ;;
		x86_64) alpine_arch="x86_64"; pd_arch="x86_64" ;;
		i686|i386) alpine_arch="x86"; pd_arch="i686" ;;
		*) die "Unsupported architecture for minirootfs fallback: $uname_arch" ;;
	esac

	base_ver="${ALPINE_VERSION#v}"
	mirror_dir="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_VERSION/releases/$alpine_arch"

	log "Looking up latest Alpine $base_ver minirootfs for $alpine_arch"
	listing="$(curl -fsSL "$mirror_dir/" || true)"
	[ -n "$listing" ] || die "Could not reach $mirror_dir - check your network."

	latest="$(printf '%s\n' "$listing" \
		| grep -oE "alpine-minirootfs-${base_ver}\.[0-9]+-${alpine_arch}\.tar\.gz" \
		| sort -t. -k3 -n | tail -n1)"
	[ -n "$latest" ] || die "No minirootfs found for Alpine $base_ver/$alpine_arch at $mirror_dir"

	tarball="$mirror_dir/$latest"
	tmp_tar="$PREFIX/tmp/$latest"
	mkdir -p "$PREFIX/tmp"

	log "Downloading $tarball"
	curl -fL --progress-bar -o "$tmp_tar" "$tarball" || die "Download failed: $tarball"

	log "Installing minirootfs as '$ALIAS' (arch: $pd_arch)"
	proot-distro install "$tmp_tar" --name "$ALIAS" --architecture "$pd_arch"
	rm -f "$tmp_tar"
}

# Never assume proot-distro's internal storage layout (it has changed across
# versions) - ask it directly by trying to log in, and drive every guest file
# operation below through 'proot-distro login' too instead of a host path.
pmos_exists() {
	proot-distro login "$ALIAS" --shared-tmp -- true >/dev/null 2>&1
}

if pmos_exists; then
	log "proot-distro alias '$ALIAS' already installed - reusing it"
else
	proot-distro remove "$ALIAS" >/dev/null 2>&1 || true
	log "Installing Alpine rootfs as '$ALIAS'"
	if ! proot-distro install alpine --override-alias "$ALIAS"; then
		warn "Docker Hub pull failed (this is a known proot-distro/Docker Hub issue," \
		     "not specific to this script) - falling back to a direct minirootfs download."
		proot-distro remove "$ALIAS" >/dev/null 2>&1 || true
		install_alpine_from_minirootfs
	fi
	pmos_exists || die "Rootfs install for '$ALIAS' did not complete. Run 'proot-distro remove $ALIAS' and re-run this script."
fi

# ---------------------------------------------------------------------------
# 4. Guest setup script (runs as root inside the rootfs)
# ---------------------------------------------------------------------------
log "Writing guest setup script"
proot-distro login "$ALIAS" --shared-tmp -- sh -c 'cat > /root/pmos-setup.sh' <<GUEST_EOF
#!/bin/sh
set -eu

ALPINE_VERSION="$ALPINE_VERSION"
PMOS_VERSION="$PMOS_VERSION"
GUEST_USER="$GUEST_USER"
TIMEZONE="$TIMEZONE"
UI="$UI"
INSTALL_EXTRAS="$INSTALL_EXTRAS"
GUEST_EOF

proot-distro login "$ALIAS" --shared-tmp -- sh -c 'cat >> /root/pmos-setup.sh' <<'GUEST_EOF'

log() { printf '\033[1;36m  ->\033[0m %s\n' "$*"; }

# --- 4a. Pin Alpine to a stable branch (edge/wrong branch breaks pmOS packages) ---
log "Pinning Alpine repositories to $ALPINE_VERSION"
# The base image's repositories may already point at 'edge' OR at some other
# release branch (e.g. v3.24) rather than 'edge' - rewrite either form so
# main and community always end up on the SAME branch. Leaving them mismatched
# (e.g. main on v3.24, community on v3.20) causes file-ownership conflicts
# between packages built for different Alpine releases.
sed -i -E "s#(https?://dl-cdn\.alpinelinux\.org/alpine/)(edge|v[0-9]+\.[0-9]+)(/(main|community))#\1${ALPINE_VERSION}\3#g" /etc/apk/repositories
# Uncomment a disabled community line, if present.
sed -i -E "s|^#\s*(https?://dl-cdn\.alpinelinux\.org/alpine/${ALPINE_VERSION}/community)|\1|" /etc/apk/repositories
# Make sure both main and community are present and enabled.
grep -q "${ALPINE_VERSION}/main" /etc/apk/repositories || \
	printf 'https://dl-cdn.alpinelinux.org/alpine/%s/main\n' "$ALPINE_VERSION" >> /etc/apk/repositories
grep -q "${ALPINE_VERSION}/community" /etc/apk/repositories || \
	printf 'https://dl-cdn.alpinelinux.org/alpine/%s/community\n' "$ALPINE_VERSION" >> /etc/apk/repositories
sort -u -o /etc/apk/repositories /etc/apk/repositories

apk update
apk upgrade --available || printf '  [!] apk upgrade reported errors; continuing.\n'
# A package left half-installed by an earlier interrupted/killed run (e.g. a
# failed extraction) makes every later apk command report "N error(s)" for
# that same stuck package until it is reconciled - clear it now instead of
# tripping over it repeatedly below.
apk fix || printf '  [!] apk fix reported errors; continuing.\n'

# --- 4b. Base tooling, user, sudo ------------------------------------------
log "Installing base tooling"
apk add sudo shadow tzdata dbus dbus-x11 openssh vim || \
	printf '  [!] apk reported errors installing base tooling; continuing.\n'

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
apk add -u --allow-untrusted postmarketos-keys || \
	printf '  [!] apk reported errors importing postmarketos-keys; continuing.\n'
apk update
apk upgrade --available || printf '  [!] apk upgrade reported errors; continuing.\n'

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
apk add openbox cage || \
	printf '  [!] apk reported errors installing openbox/cage; continuing.\n'

# These pull in 600+ transitive packages. apk exits nonzero if even one of
# them hits a post-install/trigger snag (e.g. a script running before its
# runtime dependency is unpacked) even though the rest installed fine - do
# not let 'set -e' kill the whole setup over that; 'apk fix' below cleans up.
case "$UI" in
	phosh)
		log "Installing Phosh"
		apk add postmarketos-ui-phosh postmarketos-tweaks || \
			printf '  [!] apk reported errors installing Phosh packages; apk fix will retry below.\n'
		;;
	plasma-mobile)
		log "Installing Plasma Mobile"
		apk add postmarketos-ui-plasma-mobile postmarketos-tweaks || \
			printf '  [!] apk reported errors installing Plasma Mobile packages; apk fix will retry below.\n'
		;;
	sxmo)
		log "Installing SXMO"
		apk add postmarketos-ui-sxmo-de-dwm postmarketos-tweaks-sxmo-x11 \
			feh dwm svkbd conky clickclack || \
			printf '  [!] apk reported errors installing SXMO packages; apk fix will retry below.\n'
		;;
esac

if [ "$INSTALL_EXTRAS" = "1" ]; then
	log "Installing Firefox and Noto fonts"
	apk add firefox mobile-config-firefox font-noto font-noto-cjk \
		font-noto-cjk-extra font-noto-emoji || \
		printf '  [!] Some extras failed to install; continuing.\n'
fi

# apk installs packages in dependency order, not the order some post-install
# scripts assume (e.g. postmarketos-tweaks can run before openrc exists, so
# its 'rc-update' calls fail). Re-run any missed/failed post-install steps
# and retry any package that failed to extract now that everything is on disk.
log "Reconciling any packages that failed post-install steps"
apk fix || true

log "Guest setup complete."
GUEST_EOF

proot-distro login "$ALIAS" --shared-tmp -- chmod +x /root/pmos-setup.sh

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

# Order matters here: termux-x11's own X server picks up virgl as its GPU
# backend at ITS startup, so virgl_test_server_android has to already be
# running before 'termux-x11 :0' starts - starting it after (or not at all)
# is why phoc/cage crashed with 'Failed to query DRI3 DRM FD': the X server
# advertises DRI3 but has no real device to hand back without virgl under it.
if command -v virgl_test_server_android >/dev/null 2>&1; then
	pkill -f virgl_test_server_android >/dev/null 2>&1 || true
	virgl_test_server_android >/dev/null 2>&1 &
	sleep 1
else
	echo "  [!] virgl_test_server_android not found - GPU acceleration unavailable," >&2
	echo "      phoc/cage will likely fail to start without it." >&2
fi

# The Termux:X11 app provides the actual display surface and must be running
# before 'termux-x11 :0' has anything to attach to - starting the X server
# first does not launch it for you. Bring it to the foreground here.
echo "Opening the Termux:X11 app..."
am start -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 || \
	echo "  [!] Could not auto-launch it - open the 'Termux:X11' app manually now."
sleep 2

pkill -f 'termux-x11 :0' >/dev/null 2>&1 || true
termux-x11 :0 >/dev/null 2>&1 &

echo "Waiting for the X server..."
x11_socket_up() {
	[ -S "\$PREFIX/tmp/.X11-unix/X0" ] || [ -S "/tmp/.X11-unix/X0" ]
}
for _ in \$(seq 1 30); do
	x11_socket_up && break
	sleep 1
done
if ! x11_socket_up; then
	echo "  [!] X server socket never appeared. Make sure the Termux:X11 app" >&2
	echo "      (github.com/termux/termux-x11/releases) is installed and open, then retry." >&2
fi

proot-distro login "\$ALIAS" --user "\$GUEST_USER" --shared-tmp -- /bin/sh -c '
	export DISPLAY=:0
	export XDG_RUNTIME_DIR=/tmp
	export PULSE_SERVER=127.0.0.1
	export GALLIUM_DRIVER=virpipe
	export MESA_GL_VERSION_OVERRIDE=4.0
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
