sudo bash <<'EOF'
#!/bin/bash
# --------------------------------------------------------------------------
# Linux Update – Full System Upgrader & Driver Installer
# For Debian-based systems (Kali, Ubuntu, etc.) – October 17, 2026
# With performance tuning for 60 FPS desktop experience.
# Shows full progress and asks for reboot at the end.
# --------------------------------------------------------------------------

set -euo pipefail

# --- Colours -------------------------------------------------------------
R="\e[0m"; B="\e[1m"; C="\e[36m"; G="\e[32m"; Y="\e[33m"; M="\e[35m"

# --- Banner --------------------------------------------------------------
echo -e "${C}"
echo '  ██╗     ██╗███╗   ██╗██╗   ██╗██╗  ██╗'
echo '  ██║     ██║████╗  ██║██║   ██║╚██╗██╔╝'
echo '  ██║     ██║██╔██╗ ██║██║   ██║ ╚███╔╝ '
echo '  ██║     ██║██║╚██╗██║██║   ██║ ██╔██╗ '
echo '  ███████╗██║██║ ╚████║╚██████╔╝██╔╝ ██╗'
echo '  ╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝'
echo -e "${R}${B}       Debian / Kali Full Update – October 17, 2026${R}"
echo

# --- Hardware detection ---------------------------------------------------
echo -e "${C}🔌 Scanning hardware...${R}"

# Virtualisation
if command -v systemd-detect-virt &>/dev/null && systemd-detect-virt --vm &>/dev/null; then
    VIRT=$(systemd-detect-virt)
    echo -e "  ${G}✔ Virtualisation:${R} $VIRT"
else
    VIRT="none"
    echo -e "  ${G}✔ Virtualisation:${R} bare metal"
fi

# GPU
GPU=$(lspci | grep -i "VGA\|Display" | head -n1)
if echo "$GPU" | grep -qi nvidia; then
    GPU_TYPE="nvidia"
elif echo "$GPU" | grep -qi amd; then
    GPU_TYPE="amd"
elif echo "$GPU" | grep -qi intel; then
    GPU_TYPE="intel"
else
    GPU_TYPE="unknown"
fi
echo -e "  ${G}✔ Graphics:${R} $GPU_TYPE (${GPU:-none})"
echo

# --- Non-interactive apt (to avoid prompts) -------------------------------
export DEBIAN_FRONTEND=noninteractive

# --- Repository sanitisation (Oct 2026) -----------------------------------
# The third-party prism-launcher-for-debian.github.io repo is dead (HTTP 404,
# no Release file) and makes `apt update` return non-zero, which would abort
# this script under `set -euo pipefail`. Disable it automatically. Also
# restrict the antigravity repo (amd64 only) so its i386 notice disappears.
echo -e "${C}🧹 Sanitising APT repositories...${R}"

DEAD_REPOS=(
    "prism-launcher-for-debian.github.io"
)

disable_repo() {
    local repo="$1"
    local f
    # sources.list.d fragments – safe to rename (apt ignores *.disabled)
    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        if grep -q "$repo" "$f" 2>/dev/null; then
            echo -e "  ${Y}⚠  Disabling dead repo in $f${R}"
            mv "$f" "${f}.disabled"
        fi
    done
    # main sources.list – comment out matching lines instead of moving
    if [[ -f /etc/apt/sources.list ]] && grep -q "$repo" /etc/apt/sources.list 2>/dev/null; then
        echo -e "  ${Y}⚠  Commenting out dead repo in /etc/apt/sources.list${R}"
        sed -i "s|^[^#]*${repo}.*|# [disabled $(date +%F)] &|" /etc/apt/sources.list
    fi
}

for repo in "${DEAD_REPOS[@]}"; do
    disable_repo "$repo"
done

# Restrict third-party repos that don't publish i386 to amd64 only
for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    if grep -q "antigravity-auto-updater-dev" "$f" 2>/dev/null && \
       ! grep -q "^Architectures:" "$f"; then
        echo -e "  ${G}✔ Restricting antigravity repo to amd64${R}"
        sed -i '/^Types:/a Architectures: amd64' "$f"
    fi
done
echo

# --- Update system (show progress) ----------------------------------------
echo -e "${C}📦 Updating package lists...${R}"
apt update

echo -e "${C}⬇️  Performing full system upgrade (this may take a while)...${R}"
apt full-upgrade -y

# --- Install essential tools & firmware -----------------------------------
echo -e "${C}🔧 Installing build tools and firmware...${R}"

# Linux headers – try exact version, fallback to generic
if ! apt install -y linux-headers-$(uname -r); then
    echo -e "${Y}⚠️  Could not install exact headers, installing generic headers...${R}"
    apt install -y linux-headers-generic
fi

apt install -y \
    build-essential \
    pciutils usbutils lshw \
    firmware-linux firmware-iwlwifi firmware-realtek \
    initramfs-tools

# --- Virtualisation guest tools -------------------------------------------
if [[ "$VIRT" == "vmware" ]]; then
    echo -e "${C}🖥️  Installing VMware tools...${R}"
    apt install -y open-vm-tools open-vm-tools-desktop
elif [[ "$VIRT" == "oracle" ]]; then
    echo -e "${C}🖥️  Installing VirtualBox guest additions...${R}"
    apt install -y virtualbox-guest-utils virtualbox-guest-x11
fi

# --- GPU drivers ----------------------------------------------------------
case "$GPU_TYPE" in
    nvidia)
        echo -e "${C}🎮 Installing NVIDIA drivers...${R}"
        apt install -y nvidia-driver nvidia-settings nvidia-xconfig
        nvidia-xconfig &>/dev/null || true
        ;;
    amd)
        echo -e "${C}🎮 Installing AMD drivers...${R}"
        apt install -y firmware-amd-graphics xserver-xorg-video-amdgpu mesa-utils libgl1-mesa-dri
        ;;
    intel)
        echo -e "${C}🎮 Installing Intel drivers...${R}"
        # modesetting driver is built-in; install userspace tools only
        apt install -y mesa-utils intel-media-va-driver libgl1-mesa-dri
        ;;
    *)
        echo -e "${Y}⚠️  Unknown GPU – installing generic VESA driver.${R}"
        apt install -y xserver-xorg-video-vesa || true
        ;;
esac

# --- Performance tuning for 60 FPS ----------------------------------------
echo -e "${C}⚡ Applying performance tweaks...${R}"

# Set CPU governor to 'performance' (if available)
if command -v cpupower &>/dev/null; then
    cpupower frequency-set -g performance &>/dev/null || true
elif [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor &>/dev/null || true
fi

# Tune swappiness and cache pressure for desktop responsiveness
cat > /etc/sysctl.d/99-performance.conf <<'SYSCTL'
vm.swappiness=10
vm.vfs_cache_pressure=50
SYSCTL
sysctl -p /etc/sysctl.d/99-performance.conf &>/dev/null || true

# Enable early KMS for faster boot (if not already set)
if ! grep -q "radeon.modeset=1" /etc/default/grub 2>/dev/null && \
   ! grep -q "nouveau.modeset=1" /etc/default/grub 2>/dev/null && \
   ! grep -q "i915.modeset=1" /etc/default/grub 2>/dev/null; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&radeon.modeset=1 nouveau.modeset=1 i915.modeset=1 /' /etc/default/grub
    update-grub &>/dev/null || true
fi

# --- Finalise -------------------------------------------------------------
echo -e "${C}💾 Updating initramfs...${R}"
update-initramfs -u -k all

echo -e "${C}🧹 Cleaning up...${R}"
apt autoremove -y
apt autoclean

# --- Done -----------------------------------------------------------------
echo
echo -e "${G}✔ All updates, drivers, and performance tweaks applied successfully!${R}"
echo -e "${Y}→ A reboot is strongly recommended to activate all changes.${R}"

# --- Ask for reboot -------------------------------------------------------
read -p "$(echo -e ${B}Reboot now? [y/N] ${R})" -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${C}Rebooting...${R}"
    reboot
else
    echo -e "${G}Reboot skipped. You can reboot later with 'sudo reboot'.${R}"
fi
EOF
