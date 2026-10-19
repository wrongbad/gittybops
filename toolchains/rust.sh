#!/bin/sh
# Rust (stable, wasm32 target) in /www/tools/rustup + /www/tools/cargo, when box.conf lists it. Run by
# install.sh, as you. Each site's own ~/.cargo keeps its registry cache; the toolchain is shared, read-only.
set -eu
# shellcheck source=lib.sh
. "$(dirname "$0")/../lib.sh"
[ ! -x /www/tools/cargo/bin/rustup ] || exit 0
if [ -n "${DRY_RUN:-}" ]; then echo "  install Rust into /www/tools/rustup and /www/tools/cargo" >&2; exit 0; fi
tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT
url=https://static.rust-lang.org/rustup/dist/$(uname -m)-unknown-linux-gnu/rustup-init
curl -fsSL -o "$tmp/rustup-init" "$url"
echo "$(curl -fsSL "$url.sha256" | awk '{print $1}')  $tmp/rustup-init" | sha256sum -c --quiet -
chmod +x "$tmp/rustup-init"
rm -rf /www/tools/rustup.new /www/tools/cargo.new
RUSTUP_HOME=/www/tools/rustup.new CARGO_HOME=/www/tools/cargo.new "$tmp/rustup-init" -y -q --no-modify-path \
	--profile minimal --default-toolchain stable --target wasm32-unknown-unknown >/dev/null
swap /www/tools/rustup.new /www/tools/rustup
swap /www/tools/cargo.new /www/tools/cargo
