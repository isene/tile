# Maintainer: Geir Isene <g@isene.com>
pkgname=tile
pkgver=0.1.44
pkgrel=1
pkgdesc="Tiling window manager in x86_64 assembly. No libc, pure syscalls. Ships the strip status bar as tile-strip."
arch=('x86_64')
url="https://github.com/isene/tile"
license=('Unlicense')
makedepends=('binutils' 'nasm')
source=("$pkgname-$pkgver.tar.gz::https://github.com/isene/tile/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('SKIP')

build() {
    cd "tile-$pkgver"
    make
    strip tile strip
}

package() {
    cd "tile-$pkgver"
    # strip installs as tile-strip: /usr/bin/strip belongs to binutils.
    install -Dm755 tile "$pkgdir/usr/bin/tile"
    install -Dm755 strip "$pkgdir/usr/bin/tile-strip"
    install -Dm644 tilerc.example "$pkgdir/usr/share/doc/tile/tilerc.example"
    install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
