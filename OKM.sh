#!/bin/bash
set -Euo pipefail

# =============================================================================
# OKM - OMARCHY KERNEL MANAGER
# Manage and switch between different Linux kernels on Omarchy (Arch-based)
# =============================================================================

STATE_DIR="$HOME/.local/share/okm"
STATE_FILE="$STATE_DIR/kernel-state"
BINDINGS_CONFIG=""

# Adaptive box widths — set by compute_widths() based on terminal size.
# OKM_W   = inner content width for `gum style --width`
# OKM_BOX_W = outer width including double border (1 col each side) +
#             horizontal padding "1 2" (2 cols each side) = OKM_W + 6.
# Used by center_output as the target width to centre the box around.
# Defaults are the historical hardcoded values; compute_widths shrinks
# them if the terminal is too narrow, preventing the menu heading from
# wrapping on small floating windows.
OKM_W=70
OKM_BOX_W=76

compute_widths() {
  local cols
  cols=$(tput cols 2>/dev/null || echo 80)
  # Cap inner width at 70; otherwise leave 6 cols for border/padding.
  local w=$(( cols - 6 ))
  (( w > 70 )) && w=70
  (( w < 30 )) && w=30   # absolute minimum so we still render *something*
  OKM_W=$w
  OKM_BOX_W=$(( w + 6 ))
}

# Wait for the terminal's reported width to stop changing (foot/Hyprland
# resize the floating window in two steps after spawn). We poll every
# ~25 ms for up to 250 ms, returning as soon as we see the same width
# twice in a row.
poll_terminal_size() {
  local prev curr
  prev=$(tput cols 2>/dev/null || echo 80)
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.025
    curr=$(tput cols 2>/dev/null || echo 80)
    if [[ "$curr" == "$prev" && $i -ge 2 ]]; then
      return 0
    fi
    prev=$curr
  done
}

# Kernel descriptions (for known kernels).
# CachyOS dropped the standalone `-lto` variants - the base packages
# (linux-cachyos, linux-cachyos-bore, etc.) are themselves Clang+ThinLTO
# builds, so a separate -lto package would now duplicate them.
declare -A KERNEL_DESCRIPTIONS=(
  ["linux"]="Stock Arch kernel - stable and well-tested"
  ["linux-lts"]="Long Term Support - stable for production"
  ["linux-hardened"]="Security-focused with hardening patches"
  ["linux-zen"]="Low latency for desktop/gaming"
  ["linux-cachyos"]="CachyOS default - 1000Hz, Clang+ThinLTO"
  ["linux-cachyos-bore"]="BORE scheduler for gaming (Clang+ThinLTO)"
  ["linux-cachyos-bmq"]="BMQ scheduler (Project C)"
  ["linux-cachyos-deckify"]="For handhelds (Steam Deck, etc.)"
  ["linux-cachyos-eevdf"]="Tweaked EEVDF for responsiveness"
  ["linux-cachyos-lts"]="LTS with BORE scheduler"
  ["linux-cachyos-hardened"]="Hardened with BORE scheduler"
  ["linux-cachyos-rc"]="Mainline RC with latest features"
  ["linux-cachyos-server"]="Tuned for server workloads (300Hz)"
  ["linux-cachyos-rt-bore"]="Real-time preemption with BORE"
)

# Kernel availability: pacman (official repos), cachyos, or aur
declare -A KERNEL_SOURCE=(
  ["linux"]="pacman"
  ["linux-lts"]="pacman"
  ["linux-hardened"]="pacman"
  ["linux-zen"]="pacman"
  ["linux-cachyos"]="cachyos"
  ["linux-cachyos-bore"]="cachyos"
  ["linux-cachyos-bmq"]="cachyos"
  ["linux-cachyos-deckify"]="cachyos"
  ["linux-cachyos-eevdf"]="cachyos"
  ["linux-cachyos-lts"]="cachyos"
  ["linux-cachyos-hardened"]="cachyos"
  ["linux-cachyos-rc"]="cachyos"
  ["linux-cachyos-server"]="cachyos"
  ["linux-cachyos-rt-bore"]="cachyos"
)

# Preferred display order for known kernels
KNOWN_KERNEL_ORDER=(
  "linux"
  "linux-lts"
  "linux-hardened"
  "linux-zen"
  "linux-cachyos"
  "linux-cachyos-bore"
  "linux-cachyos-eevdf"
  "linux-cachyos-bmq"
  "linux-cachyos-lts"
  "linux-cachyos-hardened"
  "linux-cachyos-server"
  "linux-cachyos-rt-bore"
  "linux-cachyos-deckify"
  "linux-cachyos-rc"
)

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

info() { echo "[*] $*"; }
err() { echo "[!] $*" >&2; }

die() {
  local msg="$1"; local code="${2:-1}"
  echo "FATAL: $msg" >&2
  exit "$code"
}

# Center output in terminal (matching WOPR_muilti_mon.sh style)
center_output() {
  local width=${1:-70}
  local term_width=$(tput cols)
  local padding=$(( (term_width - width) / 2 ))
  [[ $padding -lt 0 ]] && padding=0
  while IFS= read -r line; do
    printf "%${padding}s%s\n" "" "$line"
  done
}

check_package() {
  pacman -Qi "$1" &>/dev/null
}

check_dependencies() {
  command -v gum >/dev/null || die "gum is required. Install it with: sudo pacman -S gum"
  command -v pacman >/dev/null || die "pacman is required (are you on Arch?)"
  command -v curl >/dev/null || die "curl is required. Install it with: sudo pacman -S curl"
  command -v xdg-terminal-exec >/dev/null || die "xdg-terminal-exec is required (ships with Omarchy). This script is Omarchy-only."
  [[ -d "$HOME/.config/hypr" ]] || die "Hyprland config not found at ~/.config/hypr — Omarchy required."
}

check_aur_helper() {
  if command -v yay >/dev/null 2>&1; then
    echo "yay"
    return 0
  elif command -v paru >/dev/null 2>&1; then
    echo "paru"
    return 0
  else
    return 1
  fi
}

# =============================================================================
# THEME DETECTION (matching WOPR_muilti_mon.sh)
# =============================================================================

detect_system_theme() {
  # Omarchy 4 moved the current theme to ~/.local/state; Omarchy 3 keeps it
  # under ~/.config. Same ghostty.conf format in both.
  local omarchy_theme_dir="$HOME/.local/state/omarchy/current/theme"
  [[ -d "$omarchy_theme_dir" ]] || omarchy_theme_dir="$HOME/.config/omarchy/current/theme"
  local ghostty_conf="$omarchy_theme_dir/ghostty.conf"

  # Default colors (fallback)
  local accent_color="6"      # Cyan (ANSI color 6)
  local border_color="7"      # White/light gray
  local cursor_color="6"      # Cyan

  # Read colors from Omarchy ghostty theme if available
  if [[ -f "$ghostty_conf" ]]; then
    # Extract accent color (use palette 6 or 2 as accent - typically cyan/green)
    local palette_6=$(grep "^palette = 6=" "$ghostty_conf" 2>/dev/null | cut -d'=' -f3 | tr -d ' #')
    local palette_2=$(grep "^palette = 2=" "$ghostty_conf" 2>/dev/null | cut -d'=' -f3 | tr -d ' #')

    if [[ -n "$palette_6" ]]; then
      # Convert hex to gum color (use the hex directly)
      accent_color="#$palette_6"
      cursor_color="#$palette_6"
    elif [[ -n "$palette_2" ]]; then
      accent_color="#$palette_2"
      cursor_color="#$palette_2"
    fi

    # Get foreground color for borders
    local fg_color=$(grep "^foreground = " "$ghostty_conf" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
    if [[ -n "$fg_color" ]]; then
      border_color="$fg_color"
    fi
  fi

  # Set gum environment variables to match theme
  export GUM_CHOOSE_CURSOR_FOREGROUND="$cursor_color"
  export GUM_CHOOSE_SELECTED_FOREGROUND="$accent_color"
  export GUM_STYLE_BORDER_FOREGROUND="$border_color"
  export GUM_SPIN_SPINNER_FOREGROUND="$accent_color"
}

detect_bindings_config() {
  # Omarchy 4 (Quattro) moved Hyprland's user config from the old INI-style
  # bindings.conf to a Lua DSL, bindings.lua (o.bind(...) instead of
  # bindd/bind lines). Check for the Lua file first since it's what current
  # Omarchy ships; fall back to bindings.conf for Omarchy 3 systems that
  # haven't updated.
  local lua_config="$HOME/.config/hypr/bindings.lua"
  local conf_config="$HOME/.config/hypr/bindings.conf"

  if [[ -f "$lua_config" ]]; then
    BINDINGS_CONFIG="$lua_config"
    return 0
  fi
  if [[ -f "$conf_config" ]]; then
    BINDINGS_CONFIG="$conf_config"
    return 0
  fi

  err "Expected Hyprland config at $lua_config or $conf_config but neither was found."
  die "Is this an Omarchy system? Could not find bindings.lua or bindings.conf"
}

# =============================================================================
# KERNEL DETECTION (IMPROVED - NO HARDCODED FALLBACK)
# =============================================================================

# Get all installed kernel packages from pacman
get_all_installed_kernel_packages() {
  # Query pacman for all packages matching linux kernel patterns
  # This catches: linux, linux-lts, linux-hardened, linux-zen, linux-cachyos-*, etc.
  # Filter out -headers packages (they're not kernels)
  pacman -Qq 2>/dev/null | grep -E '^linux(-lts|-hardened|-zen|-cachyos.*|-liquorix|-xanmod.*)?$' | grep -v -- '-headers$' || true
}

# Find which package owns the currently running kernel.
# Canonical Arch mechanism: every kernel package writes a `pkgbase` file
# at /usr/lib/modules/<kernelrelease>/pkgbase containing its package name.
# That's the *only* reliable way to map `uname -r` back to a package
# (walking /boot/vmlinuz-* just finds *some* installed kernel, not the
# one currently running).
find_running_kernel_package() {
  local kernel_release
  kernel_release=$(uname -r)
  local pkgbase_file="/usr/lib/modules/$kernel_release/pkgbase"

  if [[ -r "$pkgbase_file" ]]; then
    # Trim whitespace
    local pkg
    pkg=$(tr -d '[:space:]' < "$pkgbase_file")
    if [[ -n "$pkg" ]]; then
      echo "$pkg"
      return 0
    fi
  fi

  # Fallback: ask pacman who owns the modules dir for this kernel release.
  # This handles the unusual case of a missing/empty pkgbase file but a
  # still-installed kernel package.
  local modules_dir="/usr/lib/modules/$kernel_release"
  if [[ -d "$modules_dir" ]]; then
    local owner
    owner=$(LC_ALL=C pacman -Qo "$modules_dir" 2>/dev/null | awk '{print $5}' || echo "")
    if [[ -n "$owner" ]]; then
      echo "$owner"
      return 0
    fi
  fi

  # If all else fails, return empty string (caller will handle)
  echo ""
}

detect_current_kernel() {
  # Authoritative path: read pkgbase from the running kernel's modules dir.
  # This is the canonical Arch mechanism and unambiguous - prefer it over
  # any pattern matching on uname -r (which can collide between e.g.
  # `linux-cachyos-bore` and `linux-cachyos-bore-lto`).
  local pkg
  pkg=$(find_running_kernel_package)
  if [[ -n "$pkg" ]]; then
    echo "$pkg"
    return 0
  fi

  local current_kernel_release
  current_kernel_release=$(uname -r)

  # Fallback: pattern-match on uname -r. Used only when /usr/lib/modules
  # is missing or unreadable for the running kernel (very unusual).
  # Check CachyOS variants (most specific first, check LTO variants too)
  if [[ "$current_kernel_release" == *"cachyos"*"rt-bore"*"lto"* ]]; then
    echo "linux-cachyos-rt-bore-lto"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"rt-bore"* ]]; then
    echo "linux-cachyos-rt-bore"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"deckify"*"lto"* ]]; then
    echo "linux-cachyos-deckify-lto"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"deckify"* ]]; then
    echo "linux-cachyos-deckify"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"hardened"*"lto"* ]]; then
    echo "linux-cachyos-hardened-lto"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"hardened"* ]]; then
    echo "linux-cachyos-hardened"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"server"*"lto"* ]]; then
    echo "linux-cachyos-server-lto"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"server"* ]]; then
    echo "linux-cachyos-server"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"bore"*"lto"* ]]; then
    echo "linux-cachyos-bore-lto"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"bore"* ]]; then
    echo "linux-cachyos-bore"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"bmq"*"lto"* ]]; then
    echo "linux-cachyos-bmq-lto"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"bmq"* ]]; then
    echo "linux-cachyos-bmq"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"eevdf"*"lto"* ]]; then
    echo "linux-cachyos-eevdf-lto"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"eevdf"* ]]; then
    echo "linux-cachyos-eevdf"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"lts"*"lto"* ]]; then
    echo "linux-cachyos-lts-lto"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"lts"* ]]; then
    echo "linux-cachyos-lts"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"rc"*"lto"* ]]; then
    echo "linux-cachyos-rc-lto"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"rc"* ]]; then
    echo "linux-cachyos-rc"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"*"lto"* ]]; then
    echo "linux-cachyos-lto"
    return 0
  elif [[ "$current_kernel_release" == *"cachyos"* ]]; then
    echo "linux-cachyos"
    return 0
  # Check other kernel types
  elif [[ "$current_kernel_release" == *"zen"* ]]; then
    echo "linux-zen"
    return 0
  elif [[ "$current_kernel_release" == *"lts"* ]]; then
    echo "linux-lts"
    return 0
  elif [[ "$current_kernel_release" == *"hardened"* ]]; then
    echo "linux-hardened"
    return 0
  fi

  # Last resort: return first installed kernel package. We've already tried
  # find_running_kernel_package above, so don't call it again here.
  local first_kernel
  first_kernel=$(get_all_installed_kernel_packages | head -n1)
  if [[ -n "$first_kernel" ]]; then
    echo "$first_kernel"
    return 0
  fi

  # Absolute last resort if no kernels detected (shouldn't happen)
  echo "unknown"
}

get_installed_kernels() {
  get_all_installed_kernel_packages
}

is_kernel_installed() {
  check_package "$1"
}

get_kernel_description() {
  local kernel="$1"
  if [[ -n "${KERNEL_DESCRIPTIONS[$kernel]:-}" ]]; then
    echo "${KERNEL_DESCRIPTIONS[$kernel]}"
  else
    echo "Custom or third-party kernel"
  fi
}

get_kernel_source() {
  local kernel="$1"
  echo "${KERNEL_SOURCE[$kernel]:-unknown}"
}

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

init_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    local current_kernel
    current_kernel=$(detect_current_kernel)

    # Verify the detected kernel is actually installed
    if [[ "$current_kernel" == "unknown" ]] || ! check_package "$current_kernel"; then
      err "Warning: Could not reliably detect current kernel package"
      # Try to find ANY installed kernel
      local any_kernel
      any_kernel=$(get_all_installed_kernel_packages | head -n1)
      if [[ -n "$any_kernel" ]]; then
        current_kernel="$any_kernel"
        info "Using '$current_kernel' as original kernel"
      else
        die "No kernel packages found on system - cannot initialize state"
      fi
    fi

    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<STATE
ORIGINAL_KERNEL=$current_kernel
INITIALIZED_DATE=$(date +%Y-%m-%d)
STATE

    info "Initialized kernel state - original kernel: $current_kernel"
  fi
}

get_original_kernel() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
    echo "${ORIGINAL_KERNEL:-}"
  else
    echo ""
  fi
}

# =============================================================================
# CACHYOS REPOSITORY SETUP
# =============================================================================

# Fetch the latest package filename from CachyOS repository
fetch_latest_cachyos_package() {
  local package_prefix="$1"
  local repo_url="https://mirror.cachyos.org/repo/x86_64/cachyos/"

  # Fetch the repo index and find the latest package
  local latest_pkg
  latest_pkg=$(curl -s "$repo_url" | grep -oP "${package_prefix}-[0-9]+-[0-9]+-any\.pkg\.tar\.zst" | sort -V | tail -n1)

  if [[ -z "$latest_pkg" ]]; then
    # Fallback: try harder with a more flexible pattern
    latest_pkg=$(curl -s "$repo_url" | grep -oP "${package_prefix}[^\"]*\.pkg\.tar\.zst" | head -n1)
  fi

  echo "$latest_pkg"
}

setup_cachyos_repo() {
  # Check if CachyOS repo already exists
  if grep -q "\[cachyos\]" /etc/pacman.conf 2>/dev/null; then
    info "CachyOS repository already configured"
    return 0
  fi

  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  ⚠  SYSTEM UPDATE REQUIRED"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
  echo "  Adding a new repository requires a full system update to avoid"
  echo "  partial upgrade conflicts (Arch best practice)."
  echo ""
  echo "  This will run: sudo pacman -Syu"
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo ""

  read -p "Proceed with system upgrade before adding CachyOS repo? [Y/n]: " -n 1 -r
  echo

  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    info "Upgrading system..."
    sudo pacman -Syu || die "System upgrade failed"
  else
    err "WARNING: Skipping system upgrade - this may cause package conflicts"
    read -p "Continue anyway? [y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      die "CachyOS repository setup cancelled"
    fi
  fi

  info "Setting up CachyOS repository..."

  # Install cachyos-keyring and add repository
  sudo pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com || die "Failed to receive CachyOS key"
  sudo pacman-key --lsign-key F3B607488DB35A47 || die "Failed to sign CachyOS key"

  # Fetch latest package versions dynamically. We refuse to fall back to a
  # hardcoded version string — stale URLs 404 and pacman -U fails opaquely.
  info "Fetching latest CachyOS package versions..."

  local keyring_pkg
  local mirrorlist_pkg
  keyring_pkg=$(fetch_latest_cachyos_package "cachyos-keyring")
  mirrorlist_pkg=$(fetch_latest_cachyos_package "cachyos-mirrorlist")

  if [[ -z "$keyring_pkg" ]] || [[ -z "$mirrorlist_pkg" ]]; then
    die "Could not discover current cachyos-keyring/mirrorlist versions from the CachyOS mirror. Check network connectivity to mirror.cachyos.org and try again."
  fi
  info "Found latest versions: $keyring_pkg, $mirrorlist_pkg"

  # Download to a private tmpdir so /tmp doesn't accumulate stale .pkg files
  local tmpdir
  tmpdir=$(mktemp -d -t okm-cachyos.XXXXXX) || die "Failed to create temp dir"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  curl -L --fail --output "$tmpdir/$keyring_pkg"    "https://mirror.cachyos.org/repo/x86_64/cachyos/$keyring_pkg"    || die "Failed to download cachyos-keyring"
  curl -L --fail --output "$tmpdir/$mirrorlist_pkg" "https://mirror.cachyos.org/repo/x86_64/cachyos/$mirrorlist_pkg" || die "Failed to download cachyos-mirrorlist"

  sudo pacman -U --noconfirm "$tmpdir/$keyring_pkg" "$tmpdir/$mirrorlist_pkg" || die "Failed to install CachyOS packages"

  # Add CachyOS repository to pacman.conf
  if ! grep -q "\[cachyos\]" /etc/pacman.conf; then
    info "Adding CachyOS repository to pacman.conf..."
    sudo tee -a /etc/pacman.conf > /dev/null <<'REPO'

# CachyOS repository - added by OKM
[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
REPO
  fi

  # Update package database (safe now since we did -Syu above)
  sudo pacman -Sy || die "Failed to update package database"

  info "CachyOS repository configured successfully"
}

# =============================================================================
# BOOTLOADER MANAGEMENT
# =============================================================================

update_bootloader() {
  info "Updating bootloader configuration..."
  local handled=0

  # mkinitcpio: regenerate initramfs/UKIs for all installed presets.
  # This is what actually puts the new kernel image in place; pacman's
  # mkinitcpio hook runs it on install/remove, but a manual -P after
  # bootloader rewires won't hurt and surfaces preset errors.
  if command -v mkinitcpio >/dev/null 2>&1; then
    info "Regenerating initramfs (mkinitcpio -P)..."
    sudo mkinitcpio -P || err "mkinitcpio -P reported errors"
    handled=1
  fi

  # GRUB
  if command -v grub-mkconfig >/dev/null 2>&1 && [[ -f /boot/grub/grub.cfg ]]; then
    info "Detected GRUB - regenerating config..."
    sudo grub-mkconfig -o /boot/grub/grub.cfg || err "GRUB update may have failed"
    handled=1
  fi

  # systemd-boot: entries are written by kernel-install hooks (or by
  # mkinitcpio's hook for UKI presets). Surface bootctl status so the
  # user can see the new entries actually appeared.
  if [[ -d /boot/loader ]] || [[ -d /efi/loader ]]; then
    info "Detected systemd-boot - new entries should appear via kernel-install / mkinitcpio hooks."
    if command -v bootctl >/dev/null 2>&1; then
      sudo bootctl --no-pager list 2>/dev/null | head -40 || true
    fi
    handled=1
  fi

  # Limine - increasingly common on Arch
  if command -v limine-update >/dev/null 2>&1; then
    info "Detected Limine - running limine-update..."
    sudo limine-update || err "limine-update reported errors"
    handled=1
  elif command -v limine-mkinitcpio-update >/dev/null 2>&1; then
    info "Detected Limine (mkinitcpio variant) - updating..."
    sudo limine-mkinitcpio-update || err "limine-mkinitcpio-update reported errors"
    handled=1
  fi

  # rEFInd
  if command -v refind-install >/dev/null 2>&1 && [[ -d /boot/EFI/refind ]]; then
    info "Detected rEFInd - it auto-detects new kernels at boot; no action needed."
    handled=1
  fi

  if [[ $handled -eq 0 ]]; then
    err "Could not detect a bootloader - update your bootloader configuration manually before rebooting."
  fi
}

# =============================================================================
# KERNEL INSTALLATION
# =============================================================================

install_kernel() {
  local kernel="$1"
  local original_kernel
  original_kernel=$(get_original_kernel)

  # Check if already installed
  if is_kernel_installed "$kernel"; then
    clear
    echo ""
    gum style --align center --width "$OKM_W" --border normal --padding "1 2" "Kernel Already Installed" | center_output "$OKM_BOX_W"
    echo ""
    gum style --align center --width "$OKM_W" "$kernel is already installed and available in your bootloader." | center_output "$OKM_W"
    echo ""
    gum style --align center --width "$OKM_W" --faint "To use it, reboot and select it from the boot menu." | center_output "$OKM_W"
    echo ""
    read -p "Press Enter to continue..."
    return 0
  fi

  # Show installation confirmation
  clear
  echo ""
  gum style --align center --width "$OKM_W" --border double --padding "1 2" $'Kernel Installation\n\n'"$kernel" | center_output "$OKM_BOX_W"
  echo ""

  local description
  description=$(get_kernel_description "$kernel")
  gum style --align center --width "$OKM_W" --bold "$description" | center_output "$OKM_W"
  echo ""
  gum style --align center --width "$OKM_W" "Your stock kernel ($original_kernel) will be kept as a safe fallback." | center_output "$OKM_W"
  echo ""
  gum style --align center --width "$OKM_W" --faint "After installation, reboot and select the new kernel from boot menu." | center_output "$OKM_W"
  echo ""

  # Calculate padding for confirm
  local term_width=$(tput cols)
  local confirm_width=40
  local confirm_pad=$(( (term_width - confirm_width) / 2 ))
  [[ $confirm_pad -lt 0 ]] && confirm_pad=0
  local confirm_pad_str=$(printf "%${confirm_pad}s" "")

  local choice
  choice=$(gum choose --height 6 \
    "${confirm_pad_str}Yes - Install $kernel" \
    "${confirm_pad_str}No - Cancel") || return 0

  if [[ "$choice" != *"Yes"* ]]; then
    return 0
  fi

  # Determine how to install the kernel
  local source
  source=$(get_kernel_source "$kernel")

  case "$source" in
    "cachyos")
      setup_cachyos_repo
      ;;
    "aur")
      # Check for AUR helper
      local aur_helper
      if ! aur_helper=$(check_aur_helper); then
        clear
        echo ""
        gum style --align center --width "$OKM_W" --border double --padding "1 2" "⚠  AUR Helper Required" | center_output "$OKM_BOX_W"
        echo ""
        gum style --align center --width "$OKM_W" "$kernel is an AUR package and requires an AUR helper." | center_output "$OKM_W"
        echo ""
        gum style --align center --width "$OKM_W" "Please install 'yay' or 'paru' first:" | center_output "$OKM_W"
        gum style --align center --width "$OKM_W" --faint "  sudo pacman -S yay" | center_output "$OKM_W"
        echo ""
        read -p "Press Enter to continue..."
        return 1
      fi
      ;;
    "unknown")
      # Unknown source - try pacman first, may fail
      err "Warning: Unknown package source for $kernel, attempting pacman install..."
      ;;
  esac

  # Install kernel and headers
  clear
  echo ""
  info "Installing $kernel and ${kernel}-headers..."
  echo ""

  case "$source" in
    "aur")
      local aur_helper
      if ! aur_helper=$(check_aur_helper); then
        die "AUR helper (yay/paru) not found - cannot install AUR package $kernel"
      fi
      $aur_helper -S --needed --noconfirm "$kernel" "${kernel}-headers" || die "Failed to install $kernel"
      ;;
    *)
      sudo pacman -S --needed --noconfirm "$kernel" "${kernel}-headers" || die "Failed to install $kernel"
      ;;
  esac

  # Update bootloader
  update_bootloader

  # Show success message
  clear
  echo ""
  gum style --align center --width "$OKM_W" --border double --padding "1 2" "✓ Installation Complete" | center_output "$OKM_BOX_W"
  echo ""
  gum style --align center --width "$OKM_W" "$kernel has been installed successfully!" | center_output "$OKM_W"
  echo ""
  gum style --align center --width "$OKM_W" --bold "IMPORTANT: Reboot to use the new kernel" | center_output "$OKM_W"
  echo ""
  gum style --align center --width "$OKM_W" --faint "Select it from your bootloader menu on next boot." | center_output "$OKM_W"
  echo ""
  read -p "Press Enter to continue..."
}

# =============================================================================
# KERNEL REMOVAL
# =============================================================================

remove_kernels_interactive() {
  local original_kernel
  original_kernel=$(get_original_kernel)
  local running_kernel
  running_kernel=$(detect_current_kernel)

  # Walk all installed kernels and bucket them:
  #   removable_kernels = anything beyond stock, NOT currently running
  #   protected_kernels = stock and/or running (with reason)
  # We surface the protected list in the UI so the user understands why
  # a kernel they expected to see isn't selectable, instead of getting a
  # silently-empty "No Extra Kernels Found" message.
  local installed_kernels=()
  local protected_kernels=()   # parallel: each entry "<pkg>|<reason>"
  while IFS= read -r kernel; do
    if [[ "$kernel" == "$running_kernel" && "$kernel" == "$original_kernel" ]]; then
      protected_kernels+=("$kernel|stock + currently running")
    elif [[ "$kernel" == "$running_kernel" ]]; then
      protected_kernels+=("$kernel|currently running - reboot into another kernel first")
    elif [[ "$kernel" == "$original_kernel" ]]; then
      protected_kernels+=("$kernel|stock kernel - protected fallback")
    else
      installed_kernels+=("$kernel")
    fi
  done < <(get_installed_kernels)

  if [[ ${#installed_kernels[@]} -eq 0 ]]; then
    clear
    echo ""
    gum style --align center --width "$OKM_W" --border normal --padding "1 2" "No Removable Kernels" | center_output "$OKM_BOX_W"
    echo ""
    gum style --align center --width "$OKM_W" "All installed kernels are currently protected:" | center_output "$OKM_W"
    echo ""
    for entry in "${protected_kernels[@]}"; do
      local pkg="${entry%%|*}"
      local reason="${entry#*|}"
      gum style --align center --width "$OKM_W" "  • $pkg  ($reason)" | center_output "$OKM_W"
    done
    echo ""
    if [[ "$running_kernel" != "$original_kernel" ]]; then
      gum style --align center --width "$OKM_W" --faint "Tip: to remove the running kernel, reboot into your stock kernel ($original_kernel) first via the bootloader, then come back here." | center_output "$OKM_W"
      echo ""
    fi
    read -r -p "Press Enter to continue..."
    return 0
  fi

  # Show removal menu
  clear
  echo ""
  gum style --align center --width "$OKM_W" --border double --padding "1 2" "Remove Extra Kernels" | center_output "$OKM_BOX_W"
  echo ""
  gum style --align center --width "$OKM_W" "Select kernels to remove (Space to select, Enter to confirm):" | center_output "$OKM_W"
  echo ""
  gum style --align center --width "$OKM_W" --faint "Protected: stock ($original_kernel) and running ($running_kernel) kernels are not listed." | center_output "$OKM_W"
  echo ""

  # Build options for gum choose
  local -a options=()
  local term_width=$(tput cols)
  local menu_width=$OKM_W
  local menu_pad=$(( (term_width - menu_width) / 2 ))
  [[ $menu_pad -lt 0 ]] && menu_pad=0
  local pad_str=$(printf "%${menu_pad}s" "")

  for kernel in "${installed_kernels[@]}"; do
    local description
    description=$(get_kernel_description "$kernel")
    local formatted_option=$(printf "%-26s │  %s" "$kernel" "$description")
    options+=("${pad_str}${formatted_option}")
  done

  # Use gum choose with --no-limit for multi-select
  local selected
  selected=$(gum choose --no-limit --height $((${#options[@]} + 4)) "${options[@]}") || return 0

  if [[ -z "$selected" ]]; then
    return 0
  fi

  # Extract kernel names from selections
  local -a kernels_to_remove=()
  while IFS= read -r line; do
    # Remove padding and extract kernel name (before │)
    local kernel_name=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*│.*//' | xargs)
    kernels_to_remove+=("$kernel_name")
  done <<< "$selected"

  if [[ ${#kernels_to_remove[@]} -eq 0 ]]; then
    return 0
  fi

  # Confirm removal
  clear
  echo ""
  gum style --align center --width "$OKM_W" --border double --padding "1 2" "⚠  Confirm Kernel Removal" | center_output "$OKM_BOX_W"
  echo ""
  gum style --align center --width "$OKM_W" --bold "The following kernels will be removed:" | center_output "$OKM_W"
  echo ""
  for kernel in "${kernels_to_remove[@]}"; do
    gum style --align center --width "$OKM_W" "  • $kernel" | center_output "$OKM_W"
  done
  echo ""
  gum style --align center --width "$OKM_W" --faint "Your stock kernel ($original_kernel) will remain installed." | center_output "$OKM_W"
  echo ""

  local confirm_pad=$(( (term_width - 40) / 2 ))
  [[ $confirm_pad -lt 0 ]] && confirm_pad=0
  local confirm_pad_str=$(printf "%${confirm_pad}s" "")

  local choice
  choice=$(gum choose --height 6 \
    "${confirm_pad_str}Yes - Remove selected kernels" \
    "${confirm_pad_str}No - Cancel") || return 0

  if [[ "$choice" != *"Yes"* ]]; then
    return 0
  fi

  # Remove selected kernels
  clear
  echo ""
  info "Removing selected kernels..."
  echo ""

  for kernel in "${kernels_to_remove[@]}"; do
    # Build removal package list dynamically
    local -a pkgs=("$kernel")

    # Only add headers if they're actually installed
    if check_package "${kernel}-headers"; then
      pkgs+=("${kernel}-headers")
      info "Removing $kernel and ${kernel}-headers..."
    else
      info "Removing $kernel (headers not installed)..."
    fi

    # Try -Rns first (removes dependencies). If that fails because of a
    # dependency cycle on -headers, fall back to plain -R. We deliberately
    # let stderr through so pacman's actual error reaches the user
    # (running-kernel refusal, dep cycle, target-not-found, etc.).
    if ! sudo pacman -Rns --noconfirm "${pkgs[@]}"; then
      err "pacman -Rns failed for $kernel; retrying with -R..."
      sudo pacman -R --noconfirm "${pkgs[@]}" || err "Failed to remove $kernel"
    fi
  done

  # Update bootloader
  update_bootloader

  # Show success message
  clear
  echo ""
  gum style --align center --width "$OKM_W" --border double --padding "1 2" "✓ Removal Complete" | center_output "$OKM_BOX_W"
  echo ""
  gum style --align center --width "$OKM_W" "Selected kernels have been removed successfully." | center_output "$OKM_W"
  echo ""
  gum style --align center --width "$OKM_W" "Stock kernel ($original_kernel) remains as your fallback." | center_output "$OKM_W"
  echo ""
  read -p "Press Enter to continue..."
}

# =============================================================================
# STATUS DISPLAY
# =============================================================================

show_kernel_status() {
  local current_kernel
  local original_kernel
  local kernel_version

  current_kernel=$(detect_current_kernel)
  original_kernel=$(get_original_kernel)
  kernel_version=$(uname -r)

  clear
  echo ""
  gum style --align center --width "$OKM_W" --border double --padding "1 2" "Current Kernel Status" | center_output "$OKM_BOX_W"
  echo ""

  # Current running kernel
  gum style --align center --width "$OKM_W" --bold "Currently Running:" | center_output "$OKM_W"
  gum style --align center --width "$OKM_W" "  Package: $current_kernel" | center_output "$OKM_W"
  gum style --align center --width "$OKM_W" "  Version: $kernel_version" | center_output "$OKM_W"
  echo ""

  # Original/stock kernel
  gum style --align center --width "$OKM_W" --bold "Stock Kernel (Protected):" | center_output "$OKM_W"
  gum style --align center --width "$OKM_W" "  $original_kernel" | center_output "$OKM_W"
  echo ""

  # Installed kernels (DYNAMIC - shows ALL installed kernels, not just known ones)
  gum style --align center --width "$OKM_W" --bold "Installed Kernels:" | center_output "$OKM_W"
  local installed_kernels
  installed_kernels=$(get_installed_kernels)

  if [[ -z "$installed_kernels" ]]; then
    gum style --align center --width "$OKM_W" --faint "  (none detected)" | center_output "$OKM_W"
  else
    while IFS= read -r kernel; do
      local marker=""
      [[ "$kernel" == "$current_kernel" ]] && marker="← currently running"
      [[ "$kernel" == "$original_kernel" ]] && marker="$marker [protected]"
      gum style --align center --width "$OKM_W" "  • $kernel $marker" | center_output "$OKM_W"
    done <<< "$installed_kernels"
  fi
  echo ""

  read -p "Press Enter to continue..."
}

# =============================================================================
# KERNEL INSTALLATION MENU
# =============================================================================

show_install_menu() {
  clear
  echo ""
  gum style --align center --width "$OKM_W" --border double --padding "1 2" "Install / Manage Kernels" | center_output "$OKM_BOX_W"
  echo ""
  gum style --align center --width "$OKM_W" "Select a kernel to install:" | center_output "$OKM_W"
  echo ""

  # Build menu options combining known kernels and installed unknowns
  local -a display_kernels=()
  local -a seen_kernels=()

  # First add known kernels in preferred order (only if they're available)
  for kernel in "${KNOWN_KERNEL_ORDER[@]}"; do
    local source
    source=$(get_kernel_source "$kernel")

    # Skip if kernel source is unknown (not configured)
    if [[ "$source" == "unknown" ]]; then
      continue
    fi

    # Check if AUR packages should be shown
    if [[ "$source" == "aur" ]]; then
      # Only show AUR packages if AUR helper is available
      if ! check_aur_helper >/dev/null 2>&1; then
        continue
      fi
    fi

    display_kernels+=("$kernel")
    seen_kernels+=("$kernel")
  done

  # Then add any installed kernels not in the known list (e.g., custom Omarchy kernels)
  while IFS= read -r kernel; do
    local already_seen=false
    for seen in "${seen_kernels[@]}"; do
      if [[ "$kernel" == "$seen" ]]; then
        already_seen=true
        break
      fi
    done
    if [[ "$already_seen" == false ]]; then
      display_kernels+=("$kernel")
    fi
  done < <(get_installed_kernels)

  local -a options=()
  local term_width=$(tput cols)
  local menu_width=$OKM_W
  local menu_pad=$(( (term_width - menu_width) / 2 ))
  [[ $menu_pad -lt 0 ]] && menu_pad=0
  local pad_str=$(printf "%${menu_pad}s" "")

  for kernel in "${display_kernels[@]}"; do
    local status=""
    if is_kernel_installed "$kernel"; then
      status="[INSTALLED]"
    fi
    local description
    description=$(get_kernel_description "$kernel")
    local formatted_option=$(printf "%-26s │  %s %s" "$kernel" "$description" "$status")
    options+=("${pad_str}${formatted_option}")
  done

  # Add back option. Arrow lives in the description column, not the
  # label, so the label's leading char stays aligned with kernel names.
  options+=("${pad_str}$(printf "%-26s │  %s" "Back to Main Menu" "← Return to menu")")

  local choice
  choice=$(gum choose --height $((${#options[@]} + 4)) "${options[@]}") || return 0

  if [[ -z "$choice" ]]; then
    return 0
  fi

  # Extract kernel name (before │)
  local kernel_name=$(echo "$choice" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*│.*//' | xargs)

  if [[ "$kernel_name" == "Back to Main Menu" ]]; then
    return 0
  fi

  install_kernel "$kernel_name"
}

# =============================================================================
# MAIN MENU
# =============================================================================

show_main_menu() {
  clear
  echo ""

  # W.O.P.R style title (matching WOPR_muilti_mon.sh)
  gum style --align center --width "$OKM_W" --border double --padding "1 2" $'OKM - OMARCHY KERNEL MANAGER\n\nShall we tweak the kernel?' | center_output "$OKM_BOX_W"
  echo ""

  # Initialize padding for menu (matching WOPR_muilti_mon.sh)
  local term_width=$(tput cols)
  local menu_width=$OKM_W
  local menu_pad=$(( (term_width - menu_width) / 2 ))
  [[ $menu_pad -lt 0 ]] && menu_pad=0
  local pad_str=$(printf "%${menu_pad}s" "")

  # Main menu options (matching WOPR_muilti_mon.sh format with padded entries and │ separator)
  local choice
  choice=$(gum choose --height 12 \
    "${pad_str}$(printf "%-32s │  %s" "View current kernel status" "Show current kernel info")" \
    "${pad_str}$(printf "%-32s │  %s" "Install or manage kernels" "Add linux-zen, linux-cachyos, etc")" \
    "${pad_str}$(printf "%-32s │  %s" "Revert to stock / clean up" "Remove extra kernels")" \
    "${pad_str}$(printf "%-32s │  %s" "Exit" "Quit the Kernel Manager")") || return 1

  # Extract the menu choice (before │)
  local menu_choice=$(echo "$choice" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*│.*//' | xargs)

  case "$menu_choice" in
    "View current kernel status")
      show_kernel_status
      return 0
      ;;
    "Install or manage kernels")
      show_install_menu
      return 0
      ;;
    "Revert to stock / clean up")
      remove_kernels_interactive
      return 0
      ;;
    "Exit")
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

# =============================================================================
# CLEANUP OLD INSTALLATIONS
# =============================================================================

cleanup_old_installation() {
  local old_installed_path="/usr/local/bin/omarchy-kernel-manager.sh"
  local new_installed_path="/usr/local/bin/okm"
  local old_desktop_file="$HOME/.local/share/applications/omarchy-kernel-manager.desktop"
  local new_desktop_file="$HOME/.local/share/applications/okm.desktop"
  # BINDINGS_CONFIG is normally already set by detect_bindings_config(), but
  # fall back to a fresh lua-first/conf-second probe if this is ever called
  # standalone (e.g. before detection has run).
  local bindings_conf="$BINDINGS_CONFIG"
  if [[ -z "$bindings_conf" ]]; then
    if [[ -f "$HOME/.config/hypr/bindings.lua" ]]; then
      bindings_conf="$HOME/.config/hypr/bindings.lua"
    else
      bindings_conf="$HOME/.config/hypr/bindings.conf"
    fi
  fi
  # hyprland.conf was renamed to hyprland.lua on Omarchy 4 (Quattro); mirror
  # whichever format bindings_conf resolved to.
  local hyprland_conf="$HOME/.config/hypr/hyprland.conf"
  [[ "$bindings_conf" == *.lua ]] && hyprland_conf="$HOME/.config/hypr/hyprland.lua"

  info "Cleaning up any previous installation..."

  # Strip any previous OKM block from bindings.conf/.lua and (defensively)
  # from hyprland.conf/.lua in case an earlier install version wrote there.
  cleanup_hypr_rules "$bindings_conf"
  if [[ "$hyprland_conf" != "$bindings_conf" ]] && grep -q "OKM\|Omarchy Kernel Manager" "$hyprland_conf" 2>/dev/null; then
    cleanup_hypr_rules "$hyprland_conf"
  fi

  # Remove old desktop entries (both old and new names)
  if [[ -f "$old_desktop_file" ]]; then
    info "Removing old omarchy-kernel-manager desktop entry..."
    rm -f "$old_desktop_file"
  fi
  if [[ -f "$new_desktop_file" ]]; then
    info "Removing old OKM desktop entry..."
    rm -f "$new_desktop_file"
  fi

  # Remove old scripts (requires sudo)
  if [[ -f "$old_installed_path" ]]; then
    info "Removing old omarchy-kernel-manager.sh script..."
    sudo rm -f "$old_installed_path" || err "Failed to remove old script (continuing anyway)"
  fi
  if [[ -f "$new_installed_path" ]]; then
    info "Removing old okm script..."
    sudo rm -f "$new_installed_path" || err "Failed to remove old script (continuing anyway)"
  fi

  info "✓ Cleanup complete"
}

# Add Hyprland keybinding for OKM (Super+Shift+K).
# Omarchy-only: launch via xdg-terminal-exec with TUI.float app-id so
# Omarchy's stock `tag +floating-window, match:class TUI.float` rule
# (in ~/.local/share/omarchy/default/hypr/apps/system.conf) handles
# float/center/sizing. We deliberately inject NO windowrules.
configure_okm_binding() {
  local hypr_config="${BINDINGS_CONFIG:-$HOME/.config/hypr/bindings.conf}"
  [[ -f "$hypr_config" ]] || { err "Hyprland bindings config not found at $hypr_config"; return 1; }

  # Avoid duplicate injection (check both the old .conf marker and the
  # Lua-comment marker, since either could already be present)
  if grep -q "# OKM bindings - added by OKM installer" "$hypr_config" 2>/dev/null \
    || grep -q -- "-- OKM bindings - added by OKM installer" "$hypr_config" 2>/dev/null; then
    info "OKM keybinding already present in $hypr_config"
    return 0
  fi

  local launch_cmd="xdg-terminal-exec --app-id=TUI.float -e /usr/local/bin/okm"

  info "Adding OKM keybinding to $hypr_config (Super+Shift+K)"

  if [[ "$hypr_config" == *.lua ]]; then
    # Omarchy 4 (Quattro): Lua DSL - o.bind(keys, description, command)
    {
      echo ""
      echo "-- OKM bindings - added by OKM installer"
      echo "-- (TUI.float app-id triggers Omarchy's stock floating-window rule.)"
      echo "o.bind(\"SUPER + SHIFT + K\", \"OKM\", \"$launch_cmd\")"
      echo "-- End OKM bindings"
    } >> "$hypr_config" || { err "Failed to append OKM bindings to $hypr_config"; return 1; }
  else
    # Omarchy 3: classic INI-style bindd/bind (Omarchy ships bindd for
    # descriptive binds)
    local bind_style="bindd"
    if ! grep -q "^bindd[[:space:]]*=" "$hypr_config" 2>/dev/null; then
      if grep -q "^bind[[:space:]]*=" "$hypr_config" 2>/dev/null; then
        bind_style="bind"
      fi
    fi
    {
      echo ""
      echo "# OKM bindings - added by OKM installer"
      echo "# (TUI.float app-id triggers Omarchy's stock floating-window rule.)"
      if [[ "$bind_style" == "bindd" ]]; then
        echo "bindd = SUPER SHIFT, K, OKM, exec, $launch_cmd"
      else
        echo "bind = SUPER SHIFT, K, exec, $launch_cmd"
      fi
      echo "# End OKM bindings"
    } >> "$hypr_config" || { err "Failed to append OKM bindings to $hypr_config"; return 1; }
  fi

  hyprctl reload >/dev/null 2>&1 || info "Hyprland reload may have failed; relog if binds inactive."
}

# Remove any previously added OKM/Omarchy Kernel Manager Hyprland window rules
cleanup_hypr_rules() {
  local hypr_config="$1"
  [[ -f "$hypr_config" ]] || return 0

  # Create backup before modifying (with timestamp to avoid conflicts)
  local backup_file="${hypr_config}.bak.$(date +%s)"
  cp "$hypr_config" "$backup_file" || {
    err "Warning: Failed to create backup of $hypr_config"
    return 1
  }

  # Remove the block between our markers (handles both old and new names)
  sed -i '/# Omarchy Kernel Manager window rules/,/# End Omarchy Kernel Manager window rules/d' "$hypr_config" || {
    err "Error modifying $hypr_config - restoring backup"
    mv "$backup_file" "$hypr_config"
    return 1
  }
  sed -i '/# OKM window rules/,/# End OKM window rules/d' "$hypr_config" || {
    err "Error modifying $hypr_config - restoring backup"
    mv "$backup_file" "$hypr_config"
    return 1
  }

  # Remove any stray rules that mention "Omarchy Kernel Manager" or "OKM"
  sed -i '/windowrulev2.*Omarchy Kernel Manager/d' "$hypr_config" || {
    err "Error modifying $hypr_config - restoring backup"
    mv "$backup_file" "$hypr_config"
    return 1
  }
  sed -i '/windowrule.*Omarchy Kernel Manager/d' "$hypr_config" || {
    err "Error modifying $hypr_config - restoring backup"
    mv "$backup_file" "$hypr_config"
    return 1
  }
  sed -i '/windowrulev2.*title.*OKM/d' "$hypr_config" || {
    err "Error modifying $hypr_config - restoring backup"
    mv "$backup_file" "$hypr_config"
    return 1
  }
  sed -i '/windowrule.*OKM/d' "$hypr_config" || {
    err "Error modifying $hypr_config - restoring backup"
    mv "$backup_file" "$hypr_config"
    return 1
  }

  # Remove OKM binding block if present (Super+Shift+K) - both the
  # Omarchy 3 (.conf) comment style and the Omarchy 4/Quattro (.lua) style
  sed -i '/# OKM bindings - added by OKM installer/,/# End OKM bindings/d' "$hypr_config" || {
    err "Error modifying $hypr_config - restoring backup"
    mv "$backup_file" "$hypr_config"
    return 1
  }
  sed -i '/-- OKM bindings - added by OKM installer/,/-- End OKM bindings/d' "$hypr_config" || {
    err "Error modifying $hypr_config - restoring backup"
    mv "$backup_file" "$hypr_config"
    return 1
  }

  # Verify the file is still valid (non-empty)
  if [[ ! -s "$hypr_config" ]]; then
    err "Error: $hypr_config became empty - restoring backup"
    mv "$backup_file" "$hypr_config"
    return 1
  fi

  # Keep only the most recent backup (delete older ones to avoid clutter)
  find "$(dirname "$hypr_config")" -name "$(basename "$hypr_config").bak.*" -type f | sort -r | tail -n +6 | xargs rm -f 2>/dev/null || true

  return 0
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
  # Check dependencies
  check_dependencies

  # Foot inside Omarchy's TUI.float floating window starts at the default
  # 80 cols and snaps to its real geometry ~40 ms later (we confirmed this
  # via instrumentation: 80 → 86 → 115 over ~37 ms on an Acer Nitro). If we
  # render the title box during that startup window it lands at the old
  # left position while gum choose redraws on WINCH at the new centre,
  # making the box look fragmented. A short settle pause lets tput cols
  # report the final width before any output happens.
  poll_terminal_size

  # Compute adaptive UI widths for the current terminal, and refresh on resize.
  compute_widths
  trap compute_widths WINCH

  # Locate Hyprland bindings.conf
  detect_bindings_config

  # Auto-install on first run if not already installed
  local installed_path="/usr/local/bin/okm"
  local old_installed_path="/usr/local/bin/omarchy-kernel-manager.sh"
  local current_script
  current_script=$(realpath "$0")

  # Check if we're running from the installed location
  if [[ "$current_script" != "$installed_path" ]]; then
    # Running from a different location (Downloads, etc.) - offer to install/update
    echo ""
    echo "════════════════════════════════════════════════════════════════"

    if [[ -f "$installed_path" ]] || [[ -f "$old_installed_path" ]]; then
      echo "  UPDATE OKM - OMARCHY KERNEL MANAGER"
      echo "════════════════════════════════════════════════════════════════"
      echo ""
      echo "  You're running a different version from your installed copy."
      echo "  This will update your installation."
    else
      echo "  WELCOME TO OKM - OMARCHY KERNEL MANAGER"
      echo "════════════════════════════════════════════════════════════════"
      echo ""
      echo "  This appears to be your first time running OKM."
      echo "  It needs to be installed to your system."
    fi

    echo ""
    echo "  This will:"
    echo "  • Clean up any old installation"
    echo "  • Copy the script to /usr/local/bin/ (requires sudo)"
    echo "  • Add a Hyprland keybind (Super+Shift+K)"
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    if [[ -f "$installed_path" ]] || [[ -f "$old_installed_path" ]]; then
      read -p "Update OKM? [Y/n]: " -n 1 -r
    else
      read -p "Install OKM to system? [Y/n]: " -n 1 -r
    fi
    echo
    echo

    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      # Install/Update to system
      local is_update=false
      if [[ -f "$installed_path" ]]; then
        is_update=true
        info "Updating installation..."
      else
        info "Installing to system..."
      fi
      echo ""

      # Clean up any old installation first
      cleanup_old_installation
      echo ""

      # Copy script with proper permissions in one step
      sudo install -m 755 "$0" "$installed_path" || die "Failed to install script to $installed_path"

      # Verify the installation
      if [[ ! -x "$installed_path" ]]; then
        die "Installation failed: $installed_path is not executable"
      fi

      info "✓ Script installed to $installed_path"

      # Add Hyprland keybinding (Super+Shift+K)
      configure_okm_binding || err "Failed to add OKM keybinding"

      echo ""
      if $is_update; then
        info "✓ Update complete!"
      else
        info "✓ Installation complete!"
      fi
      echo ""
      echo "════════════════════════════════════════════════════════════════"
      echo "  HOW TO USE"
      echo "════════════════════════════════════════════════════════════════"
      echo ""
      echo "  • Press Super+Shift+K to launch OKM in a floating window"
      echo "  • Or run: okm"
      echo ""
      echo "════════════════════════════════════════════════════════════════"
      echo ""
      # Don't auto-launch from the installer's terminal - OKM's TUI is sized
      # for the floating TUI.float window and looks broken in any other
      # terminal. The keybind is now wired up; let the user trigger it.
      exit 0
    else
      info "Skipping installation. You can install later by running this script again."
      echo ""
      read -p "Continue running from current location? [Y/n]: " -n 1 -r
      echo
      echo
      if [[ $REPLY =~ ^[Nn]$ ]]; then
        exit 0
      fi
    fi
  else
    # Already running from installed location: ensure binding exists
    # (cheap idempotent guard - returns immediately if marker is present)
    configure_okm_binding || err "Failed to ensure OKM keybinding in Hyprland config"
  fi

  # Detect and apply system theme
  detect_system_theme

  # Initialize state on first run
  init_state

  # Main menu loop
  while true; do
    if ! show_main_menu; then
      # User selected Exit - show goodbye message and close
      clear
      echo ""
      gum style --align center --width "$OKM_W" --border normal --padding "1 2" $'OKM Closed\n\nClosing terminal...' | center_output "$OKM_BOX_W"
      echo ""
      sleep 1

      # Force terminal close if launched from desktop
      if [[ -n "${DESKTOP_STARTUP_ID:-}" ]] || [[ -n "${XDG_ACTIVATION_TOKEN:-}" ]]; then
        # Launched from app launcher - kill the terminal window
        kill -TERM $PPID 2>/dev/null || true
      fi

      exit 0
    fi
  done
}

main "$@"
