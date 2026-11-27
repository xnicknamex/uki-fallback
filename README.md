# uki-fallback

Fallback for Arch Linux booting unified kernel images (UKIs) with systemd-boot, as set up
by archinstall: every new UKI gets 3 boot tries, then the previous one boots on its own,
with the kernel modules it needs. No boot menu, no input needed.

## How it works

- mkinitcpio builds the UKI into `/var/lib/uki-fallback/` (`default_uki` in the presets).
  Its post hook (`/usr/lib/initcpio/post/uki-fallback`) moves it to the ESP as
  `arch-linux+3.efi`. The current UKI becomes `arch-linux-prev.efi` if it booted fine;
  one that never booted fine is dropped and the prev stays.
- systemd-boot counts the tries down on every boot (`+2-1`, `+1-2`, `+0-3`),
  systemd-bless-boot removes the counter after a successful boot (`boot-complete.target`).
  At 0 the UKI is bad and systemd-boot boots the prev. `panic=10` makes a kernel panic
  reboot after 10s, so it counts as a failed try; a hang needs the reset button.
- Rebuilds happen after every update mkinitcpio's pacman hook reacts to (kernel,
  firmware, microcode, systemd, mkinitcpio, ...) and after a manual `mkinitcpio -P`.
- A rebuild while running from the prev (booted once, fallback, rollback) drops the
  current UKI, so the prev stays.
- The boot menu is hidden (`timeout 0`): hold **Space** while booting to show it.

It only helps with problems inside the UKI: kernel, initramfs, kernel command line.
A rebuild always uses the installed kernel package, so a broken kernel stays broken in
new UKIs until a fixed kernel arrives or you downgrade.

## Pacman hooks

Both run `uki-fallback` on kernel updates and removals only.

- `uki-fallback-save.hook` (before the update): keeps the module folders of the kernels the
  UKIs on the ESP were built for (hard links), before pacman deletes them.
- `uki-fallback-restore.hook` (after the update): puts back the module folders a UKI still
  needs (so the prev keeps Wi-Fi, sound, ...) and removes the ones no UKI needs anymore.
  Put back folders contain a `.uki-fallback` file; only those get removed.

## Install

```sh
makepkg -si          # in this folder; builds the package from the checkout
uki-fallback setup   # uses the existing UKI, never creates one
```

Commit before building: the version comes from git (`r<commits>.<hash>`), the files from
the folder as they are.

`setup` checks for systemd-boot, an existing UKI on the ESP and free space, sets
`timeout 0` and `panic=10`, points the presets to the staging folder and rebuilds. Safe to
run again.

## Rollback

- `uki-fallback rollback`: from the next boot on, the prev boots (marks the current UKI
  bad). The next rebuild ends it: the new UKI gets 3 tries again, roll back again if needed.
- `uki-fallback undo`: gives a bad UKI (rolled back or 3 failed boots) 3 new tries.
- Boot the prev once: `systemctl reboot --boot-loader-entry=arch-linux-prev.efi`.
- State (tries left, kernel version, default and booted entry): `bootctl list`.

With more than one kernel, add the name: `uki-fallback rollback arch-linux-lts`.

## Remove

`pacman -R uki-fallback` runs `uki-fallback teardown` first: presets build to the ESP
again, one UKI per kernel without counter stays, prev UKIs and kept module folders are
removed, rebuild. `timeout 0` and `panic=10` stay.

## Limits

- Downgrading to exactly the prev's kernel version conflicts with its put back module
  folder: `pacman -U ... --overwrite '/usr/lib/modules/<version>/*'`.
- UKIs of a removed kernel package stay on the ESP.
- Problems outside the UKI (packages, `/etc`, desktop) are not covered.

## Tests

`./test.sh` simulates everything in a temp folder (fake ESP, presets, modules, EFI
variable; needs objcopy), the system is not touched.
