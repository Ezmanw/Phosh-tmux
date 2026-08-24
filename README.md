# Phosh-tmux

One-shot installer that sets up **postmarketOS with the Phosh mobile shell** inside
Termux, running in a proot container and displayed through Termux:X11.

Compiled from Ivon Huang's guide:
<https://ivonblog.com/en-us/posts/postmarketos-in-termux-proot/>

## Run this command

In Termux:

```sh
curl -fsSL https://raw.githubusercontent.com/ezmanw/Phosh-tmux/main/install.sh | bash
```

To pass options, download first:

```sh
curl -fsSLO https://raw.githubusercontent.com/ezmanw/Phosh-tmux/main/install.sh
bash install.sh --ui phosh --timezone Asia/Taipei
```

Expect the install to take a while — it pulls a few hundred MB of packages.

## Then start it

```sh
pmos-phosh
```

The launcher starts PulseAudio, `termux-x11 :0`, the virgl server (if available),
and then logs into the container and runs `cage phoc -E /usr/libexec/phosh`.
Switch to the **Termux:X11** app when it tells you to.

Shell into the container without a GUI:

```sh
proot-distro login pmos --user user --shared-tmp
```

## Requirements

- [Termux](https://github.com/termux/termux/releases) (F-Droid or GitHub build — **not** the Play Store one)
- [Termux:X11](https://github.com/termux/termux-x11/releases) app installed
- ~6 GB free storage, arm64 device
- Hacker's Keyboard is handy for the guest shell

## Options

| Flag | Default | Description |
| --- | --- | --- |
| `--ui <phosh\|plasma-mobile\|sxmo>` | `phosh` | Which mobile UI to install |
| `--alias <name>` | `pmos` | proot-distro alias for the rootfs |
| `--user <name>` | `user` | Username created inside the container |
| `--timezone <Region/City>` | `UTC` | Guest timezone |
| `--alpine-version <ver>` | `v3.20` | Alpine branch to pin (edge breaks pmOS packages) |
| `--pmos-version <ver>` | `v24.06` | postmarketOS release repository |
| `--no-firefox` | off | Skip Firefox and the Noto font set |
| `-h`, `--help` | | Show help |

Picking a different `--ui` also names the launcher accordingly
(`pmos-plasma-mobile`, `pmos-sxmo`).

## What the script does

1. Installs the Termux side: `proot-distro`, `pulseaudio`, `x11-repo`,
   `termux-x11-nightly`, `virglrenderer-android`.
2. Installs an Alpine rootfs under the chosen alias.
3. Inside the container: pins repositories to the stable Alpine branch, upgrades,
   creates a `wheel`/`video`/`audio`/`storage` user with passwordless sudo, sets the
   timezone, and moves sshd to port 8023.
4. Adds the postmarketOS repository, imports `postmarketos-keys`, upgrades, and
   rewrites `/etc/os-release` to identify as postmarketOS.
5. Installs `openbox`, `cage`, and the selected `postmarketos-ui-*` packages
   (plus Firefox and Noto fonts unless `--no-firefox`).
6. Writes the `pmos-<ui>` launcher into `$PREFIX/bin`.

Re-running the script against an existing alias reuses the rootfs and just
re-applies the setup, so it is safe to run again after a failure.

## Troubleshooting

**`Failed to install: Unauthorized: 'alpine' does not exist or is a private
image`** — this is a known issue with `proot-distro` pulling images anonymously
from Docker Hub ([termux/proot-distro#692](https://github.com/termux/proot-distro/issues/692)),
not something specific to this script. `install.sh` now detects this and
automatically falls back to downloading Alpine's official minirootfs tarball
directly and installing it as a local archive, which bypasses Docker Hub
entirely. Just re-run the script (or `bash install.sh` again) and it will pick
up the fallback path. If it still fails, check that you can reach
`dl-cdn.alpinelinux.org` (`curl -I https://dl-cdn.alpinelinux.org`), or
authenticate the Docker Hub pull instead with a free Docker Hub account:
`PD_DOCKER_AUTH=user:token bash install.sh`.

## Notes

- Everything runs in proot, so there is no real hardware access — no calls, no
  modem, no SIM. This is the postmarketOS userspace, not a phone OS install.
- GPU acceleration goes through virglrenderer (`GALLIUM_DRIVER=virpipe`) and is
  optional; if `virglrenderer-android` is unavailable the shell still runs on
  software rendering, just slower.
- Audio is forwarded to Termux's PulseAudio over `127.0.0.1` via
  `module-native-protocol-tcp`.
