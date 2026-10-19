#!/bin/sh
# Node 24 in /opt/node (always installed: the webhook listener runs on it). Run by install.sh as root.
set -eu
case $(uname -m) in x86_64) arch=x64 ;; aarch64) arch=arm64 ;; esac
[ "$(/opt/node/bin/node -p 'process.versions.node.split(".")[0]' 2>/dev/null)" != 24 ] || exit 0
base=https://nodejs.org/dist/latest-v24.x
sums=$(curl -fsSL "$base/SHASUMS256.txt")
file=$(echo "$sums" | awk -v f="linux-$arch.tar.xz" '$2 ~ f"$" {print $2}')
curl -fsSL -o "/tmp/$file" "$base/$file"
(cd /tmp && echo "$sums" | grep " $file\$" | sha256sum -c -)
rm -rf /opt/node && mkdir -p /opt/node
tar -xJf "/tmp/$file" -C /opt/node --strip-components 1 && rm "/tmp/$file"
