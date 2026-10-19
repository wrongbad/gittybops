#!/bin/sh
# Caddy $CADDY_VERSION (box.conf, default below) in /www/tools/caddy, checked against the release's published
# checksums. Run by install.sh, as you; changing the version upgrades it.
set -eu
# shellcheck source=lib.sh
. "$(dirname "$0")/../lib.sh"
v=${CADDY_VERSION:-2.10.2}
dest=/www/tools/caddy
case $("$dest/caddy" version 2>/dev/null) in "v$v "*) exit 0 ;; esac
if [ -n "${DRY_RUN:-}" ]; then echo "  install Caddy $v into $dest" >&2; exit 0; fi
case $(uname -m) in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT
base=https://github.com/caddyserver/caddy/releases/download/v$v
file=caddy_${v}_linux_$arch.tar.gz
curl -fsSL -o "$tmp/$file" "$base/$file"
curl -fsSL "$base/caddy_${v}_checksums.txt" | grep " $file\$" | (cd "$tmp" && sha512sum -c --quiet -)
rm -rf "$dest.new" && mkdir "$dest.new"
tar -xzf "$tmp/$file" -C "$dest.new" caddy
swap "$dest.new" "$dest"
