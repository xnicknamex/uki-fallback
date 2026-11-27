# Builds the package from this checkout: makepkg -si
pkgname=uki-fallback
pkgver=r0
pkgrel=1
pkgdesc="systemd-boot UKI fallback: boot counting, previous UKI with its kernel modules, rollback"
arch=(any)
depends=(bash systemd mkinitcpio binutils)
install=uki-fallback.install
# Local files of this repo
source=(uki-fallback uki-fallback-save.hook uki-fallback-restore.hook)
sha256sums=(SKIP SKIP SKIP)

pkgver() {
    printf 'r%s.%s' "$(git -C "$startdir" rev-list --count HEAD)" "$(git -C "$startdir" rev-parse --short HEAD)"
}

package() {
    install -Dm755 uki-fallback "$pkgdir/usr/bin/uki-fallback"
    install -dm755 "$pkgdir/usr/lib/initcpio/post"
    ln -s /usr/bin/uki-fallback "$pkgdir/usr/lib/initcpio/post/uki-fallback"
    install -Dm644 -t "$pkgdir/usr/share/libalpm/hooks" uki-fallback-save.hook uki-fallback-restore.hook
}
