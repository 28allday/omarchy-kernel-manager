# OKM — Omarchy Kernel Manager

A friendly TUI for installing, switching, and removing Linux kernels on
[Omarchy](https://omarchy.org/). One keybind opens a floating window
where you can drop in CachyOS, linux-zen, hardened, and friends — and
remove them safely later, without ever clobbering your stock kernel or
the one you're currently booted into.

```
  ╔══════════════════════════════════════════════════════════════════╗
  ║                                                                  ║
  ║                   OKM - OMARCHY KERNEL MANAGER                   ║
  ║                                                                  ║
  ║                    Shall we tweak the kernel?                    ║
  ║                                                                  ║
  ╚══════════════════════════════════════════════════════════════════╝

  Choose:
  >  View current kernel status      │  Show current kernel info
     Install or manage kernels        │  Add linux-zen, linux-cachyos, etc
     Revert to stock / clean up       │  Remove extra kernels
     Exit                             │  Quit the Kernel Manager
```

## Features

- **One-keybind launch.** `Super+Shift+K` opens OKM in a floating
  window via Omarchy's stock `TUI.float` rule — no custom windowrules
  to maintain.
- **14 known kernels out of the box** — covering the four official
  Arch kernels (`linux`, `linux-lts`, `linux-hardened`, `linux-zen`)
  and ten CachyOS variants (default, BORE, EEVDF, BMQ, LTS, hardened,
  server, RT-BORE, deckify, RC).
- **CachyOS repo bootstrap.** First time you pick a CachyOS kernel,
  OKM signs the keyring, fetches the latest `cachyos-keyring` /
  `cachyos-mirrorlist` versions live (no stale URLs), and adds the
  repo to `/etc/pacman.conf` — running a full `pacman -Syu` first to
  avoid partial-upgrade trouble.
- **AUR support.** If you've added a custom kernel to the
  `KERNEL_SOURCE` table with `source=aur`, OKM dispatches to `yay` or
  `paru` automatically.
- **Bootloader-aware.** After install or removal it runs
  `mkinitcpio -P` and updates whichever bootloader you have:
  GRUB, systemd-boot (with a `bootctl list` summary), Limine, or
  rEFInd. Misses none of the common Arch setups.
- **Safe removal.** Two kernels are *always* protected:
    1. Your **stock kernel** — recorded the first time OKM runs.
    2. The **currently running kernel** — pacman would refuse anyway,
       and a successful removal mid-session means a broken next boot.
  Both appear in the removal screen with a clear reason, so you're
  never staring at a confusingly empty list.
- **Adapts to terminal size.** Boxes auto-shrink for narrow
  terminals; the title polls `tput cols` until the floating window
  has settled (foot resizes ~40 ms after spawn) so the header never
  renders at the wrong width.

## Requirements

- **Omarchy** (Arch Linux + Hyprland). The script bails out if it
  can't find `~/.config/hypr` or `xdg-terminal-exec`.
- `gum` (`pacman -S gum`)
- `curl`
- `pacman` (you're on Arch — you have it)
- For CachyOS kernels: an internet connection on first install
- For AUR kernels: `yay` or `paru`

## Install

```bash
# Clone, then run (the script self-installs to /usr/local/bin/okm
# and adds a Super+Shift+K binding to ~/.config/hypr/bindings.conf).
git clone https://github.com/28allday/omarchy-kernel-manager.git
cd omarchy-kernel-manager
./OKM.sh
```

Pick **Install OKM to system** when prompted. After that you can
launch it any time with **Super+Shift+K** or by running `okm`.

## Usage

### Install a kernel

`Super+Shift+K` → **Install or manage kernels** → pick from the list.
OKM tells you whether each kernel comes from pacman, CachyOS, or AUR,
sets up the repo if needed, installs `<kernel>` and `<kernel>-headers`,
and refreshes the bootloader. Reboot and select the new kernel from
your boot menu.

### Switch back to stock

`Super+Shift+K` → **View current kernel status** to confirm what
you're on, reboot via the boot menu into your stock kernel, then
launch OKM again to remove the others (see below).

### Remove a kernel

`Super+Shift+K` → **Revert to stock / clean up**. You'll see every
installed kernel except stock + currently running. Multi-select with
**Space**, confirm with **Enter**, OKM strips the package(s) plus
matching `-headers`, then refreshes the bootloader.

If the kernel you want to remove *is* the running one, OKM tells you
to reboot into another kernel first — it won't pull the rug out.

## How it identifies the running kernel

OKM uses Arch's canonical mechanism: every kernel package writes a
`pkgbase` file at `/usr/lib/modules/<kernelrelease>/pkgbase`
containing its package name. Reading that file is the only reliable
way to map `uname -r` back to a package — walking `/boot/vmlinuz-*`
just finds *some* installed kernel, not necessarily the one you're
booted into.

## Files OKM touches

| Path | What it does |
|---|---|
| `/usr/local/bin/okm` | The installed script |
| `~/.config/hypr/bindings.conf` | Adds a single `bindd` line in a marked block — the floating-window rule comes from Omarchy's stock `TUI.float` regex, no custom windowrules written |
| `~/.local/share/okm/kernel-state` | Records your stock kernel so it can never be accidentally removed |
| `/etc/pacman.conf` | First time you install a CachyOS kernel, adds the `[cachyos]` section + Include line |

To uninstall: `sudo rm /usr/local/bin/okm` and remove the
`# OKM bindings - added by OKM installer` block from
`~/.config/hypr/bindings.conf`.

## Repository

Mirrored on:

- **GitHub:** https://github.com/28allday/omarchy-kernel-manager
- **Forgejo:** https://git.no-signal.uk/nosignal/omarchy-kernel-manager

## License

MIT — see [LICENSE](LICENSE).
