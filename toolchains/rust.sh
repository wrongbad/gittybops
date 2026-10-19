#!/bin/sh
# Rust (stable, wasm32 target) in /opt/rustup + /opt/cargo, when box.conf lists it. Run by install.sh as you:
# rustup-init is checksummed and run as you into a temp dir; only moving the result into /opt runs as root.
# Each site's own ~/.cargo keeps its registry cache; the toolchain itself is shared and read-only.
set -eu
# shellcheck source=lib.sh
. "$(dirname "$0")/../lib.sh"
if [ -x /opt/cargo/bin/rustup ]; then
	root_owned /opt/rustup /opt/cargo
	exit 0
fi
tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT
if [ -z "${DRY_RUN:-}" ]; then
	url=https://static.rust-lang.org/rustup/dist/$(uname -m)-unknown-linux-gnu/rustup-init
	curl -fsSL -o "$tmp/rustup-init" "$url"
	echo "$(curl -fsSL "$url.sha256" | awk '{print $1}')  $tmp/rustup-init" | sha256sum -c --quiet -
	chmod +x "$tmp/rustup-init"
	RUSTUP_HOME=$tmp/rustup CARGO_HOME=$tmp/cargo "$tmp/rustup-init" -y -q --no-modify-path \
		--profile minimal --default-toolchain stable --target wasm32-unknown-unknown
fi
put_dir "$tmp/rustup" /opt/rustup
put_dir "$tmp/cargo" /opt/cargo
