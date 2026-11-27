#!/usr/bin/env bash
# Simulates uki-fallback without touching the system: fake ESP, presets, kernel modules,
# kernel cmdline and EFI variable in a temp folder; bootctl and mkinitcpio are stand-ins.
# Fake UKIs are small files with a .uname section (needs objcopy). Run: ./test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT

export UKI_FALLBACK_TEST=1
export UKI_FALLBACK_ESP="$t/esp"
export UKI_FALLBACK_STAGING="$t/staging"
export UKI_FALLBACK_MODULES="$t/modules"
export UKI_FALLBACK_BACKUP="$t/modules-uki"
export UKI_FALLBACK_PRESETS="$t/presets"
export UKI_FALLBACK_CMDLINE="$t/cmdline"
export UKI_FALLBACK_EFIVAR="$t/efivar"
export PATH="$t/bin:$PATH"
uf="$here/uki-fallback"
linux="$t/esp/EFI/Linux"

mkdir -p "$t/bin" "$linux" "$t/esp/loader" "$t/modules" "$t/presets"

# Fake UKI with a kernel version
mkuki() {
    printf %s "$2" >"$t/uname"
    objcopy --add-section .uname="$t/uname" /bin/true "$1"
}

# bootctl: systemd-boot is installed
cat >"$t/bin/bootctl" <<'EOF'
#!/bin/sh
exit 0
EOF

# mkinitcpio -P: builds every preset with the installed kernel ($t/kernel), then runs
# the post hook like mkinitcpio does
cat >"$t/bin/mkinitcpio" <<EOF
#!/usr/bin/env bash
set -e
for preset in "$t"/presets/*.preset; do
    uki="\$(bash -c '. "\$1"; printf %s "\$default_uki"' _ "\$preset")"
    printf %s "\$(cat "$t/kernel")" >"$t/uname"
    objcopy --add-section .uname="$t/uname" /bin/true "\$uki"
    KERNELVERSION="\$(cat "$t/kernel")" "$uf" /boot/vmlinuz-linux /tmp/initramfs "\$uki"
done
EOF
chmod +x "$t/bin/bootctl" "$t/bin/mkinitcpio"

# Kernel package: modules folder with vmlinuz
install_kernel() {
    mkdir -p "$t/modules/$1/kernel"
    echo "$1" >"$t/modules/$1/vmlinuz"
    echo "wifi" >"$t/modules/$1/kernel/wifi.ko"
    echo "$1" >"$t/kernel"
}

# pacman kernel update: pre hook, package swap, mkinitcpio hook and post hook
# (restore_first: our post hook runs before mkinitcpio's)
update_kernel() {
    "$uf" save-modules
    rm -rf "${t:?}/modules/$1"
    install_kernel "$2"
    if [[ ${3:-} == restore_first ]]; then
        "$uf" restore-modules
        mkinitcpio -P >/dev/null
    else
        mkinitcpio -P >/dev/null
        "$uf" restore-modules
    fi
}

# Successful boot: systemd-boot counts down, systemd-bless-boot removes the counter
boot_ok() {
    local f
    for f in "$linux"/arch-linux+*.efi; do
        [[ -e $f ]] && mv "$f" "$linux/arch-linux.efi"
    done
    select_entry arch-linux.efi
}

# LoaderEntrySelected: 4 bytes attributes, UTF-16LE, NUL
select_entry() {
    { printf '\x07\x00\x00\x00'; printf %s "$1" | iconv -f UTF-8 -t UTF-16LE; printf '\x00\x00'; } >"$t/efivar"
}

# "name=kernel" of all UKIs on the ESP
esp_state() {
    local f
    for f in "$linux"/*.efi; do
        [[ -e $f ]] || continue
        printf '%s=%s ' "$(basename "$f")" "$(objcopy --dump-section .uname=/dev/stdout "$f" /dev/null)"
    done | sed 's/ $//'
}

modules_state() {
    ls "$t/modules" | tr '\n' ' ' | sed 's/ $//'
}

fails=0
check() {
    if [[ $2 == "$3" ]]; then
        echo "ok    $1"
    else
        echo "FAIL  $1"
        echo "      expected: $3"
        echo "      got:      $2"
        fails=$((fails + 1))
    fi
}

# --- archinstall state: kernel 6.1, its UKI on the ESP
install_kernel 6.1
mkuki "$linux/arch-linux.efi" 6.1
echo 'default_uki="'"$linux"'/arch-linux.efi"' >"$t/presets/linux.preset"
echo "timeout 15" >"$t/esp/loader/loader.conf"
echo "root=UUID=x rw" >"$t/cmdline"

"$uf" setup >/dev/null
check "setup: archinstall UKI becomes prev, rebuild gets 3 tries" "$(esp_state)" "arch-linux+3.efi=6.1 arch-linux-prev.efi=6.1"
check "setup: no menu" "$(cat "$t/esp/loader/loader.conf")" "timeout 0"
check "setup: panic=10" "$(tr '\n' ' ' <"$t/cmdline")" "root=UUID=x rw panic=10 "
check "setup: preset builds into staging" "$(cat "$t/presets/linux.preset")" "default_uki=\"$t/staging/arch-linux.efi\""
"$uf" setup >/dev/null
check "setup again: changes nothing" "$(esp_state)" "arch-linux+3.efi=6.1 arch-linux-prev.efi=6.1"

boot_ok
update_kernel 6.1 6.2
check "kernel update: current becomes prev" "$(esp_state)" "arch-linux+3.efi=6.2 arch-linux-prev.efi=6.1"
check "kernel update: prev keeps its modules" "$(modules_state)" "6.1 6.2"
check "kernel update: restored modules complete" "$(cat "$t/modules/6.1/kernel/wifi.ko")" "wifi"

update_kernel 6.2 6.3
check "update before a successful boot: prev stays" "$(esp_state)" "arch-linux+3.efi=6.3 arch-linux-prev.efi=6.1"
check "update before a successful boot: unused modules gone" "$(modules_state)" "6.1 6.3"

boot_ok
update_kernel 6.3 6.4 restore_first
check "restore hook before mkinitcpio: same UKIs" "$(esp_state)" "arch-linux+3.efi=6.4 arch-linux-prev.efi=6.3"
check "restore hook before mkinitcpio: old modules still there" "$(modules_state)" "6.1 6.3 6.4"
"$uf" save-modules
"$uf" restore-modules
check "next transaction: old modules removed" "$(modules_state)" "6.3 6.4"

boot_ok
check "rollback" "$("$uf" rollback | head -n 1)" "Rolled back: the next boot uses arch-linux-prev.efi (6.3) instead of 6.4."
check "rollback: current marked bad" "$(esp_state)" "arch-linux+0.efi=6.4 arch-linux-prev.efi=6.3"
check "rollback again" "$("$uf" rollback)" "Already rolled back, arch-linux-prev.efi boots."
check "undo" "$("$uf" undo)" "Undone: the next boot tries arch-linux+3.efi (6.4) again, 3 tries."
check "undo again" "$("$uf" undo)" "Nothing to undo, no bad arch-linux UKI."

boot_ok
select_entry arch-linux-prev.efi
mkinitcpio -P >/dev/null
check "rebuild while running from prev: prev stays" "$(esp_state)" "arch-linux+3.efi=6.4 arch-linux-prev.efi=6.3"

boot_ok
mkinitcpio -P >/dev/null
check "rebuild after a normal boot: current becomes prev" "$(esp_state)" "arch-linux+3.efi=6.4 arch-linux-prev.efi=6.4"

echo 'default_uki="'"$t"'/staging/arch-linux-lts.efi"' >"$t/presets/linux-lts.preset"
check "two kernels: name needed" "$("$uf" undo 2>&1 || true)" "Give the UKI name, one of: arch-linux-lts arch-linux"
rm "$t/presets/linux-lts.preset"

update_kernel 6.4 6.5
"$uf" rollback >/dev/null
"$uf" teardown >/dev/null
check "teardown: one UKI without counter, rebuilt" "$(esp_state)" "arch-linux.efi=6.5"
check "teardown: preset builds to the ESP" "$(cat "$t/presets/linux.preset")" "default_uki=\"$linux/arch-linux.efi\""
check "teardown: kept modules removed" "$(modules_state)" "6.5"
check "teardown: staging removed" "$([[ -e $t/staging ]] && echo exists || echo gone)" "gone"

check "no arguments: usage" "$("$uf" 2>&1 || true)" "Usage: uki-fallback setup|teardown|rollback|undo [name]"
rm -f "$linux/arch-linux.efi"
echo 'default_uki="'"$t"'/staging/arch-linux.efi"' >"$t/presets/linux.preset"
check "rollback without prev" "$("$uf" rollback 2>&1 || true)" "No previous UKI (arch-linux-prev.efi), nothing to roll back to."

echo
if [[ $fails -eq 0 ]]; then
    echo "All tests passed."
else
    echo "$fails test(s) failed."
    exit 1
fi
