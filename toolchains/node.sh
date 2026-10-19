#!/bin/sh
# Node 24 in /www/tools/node (always installed: the webhook listener runs on it). Run by install.sh, as you.
set -eu
# shellcheck source=lib.sh
. "$(dirname "$0")/../lib.sh"
dest=/www/tools/node
[ "$("$dest/bin/node" -p 'process.versions.node.split(".")[0]' 2>/dev/null)" != 24 ] || exit 0
if [ -n "${DRY_RUN:-}" ]; then echo "  install Node 24 into $dest" >&2; exit 0; fi
case $(uname -m) in x86_64) arch=x64 ;; aarch64) arch=arm64 ;; esac
tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT
base=https://nodejs.org/dist/latest-v24.x
sums=$(curl -fsSL "$base/SHASUMS256.txt")
file=$(echo "$sums" | awk -v f="linux-$arch.tar.xz" '$2 ~ f"$" {print $2}')
curl -fsSL -o "$tmp/$file" "$base/$file"
(cd "$tmp" && echo "$sums" | grep " $file\$" | sha256sum -c --quiet -)
rm -rf "$dest.new" && mkdir "$dest.new"
tar -xJf "$tmp/$file" -C "$dest.new" --strip-components 1
swap "$dest.new" "$dest"
