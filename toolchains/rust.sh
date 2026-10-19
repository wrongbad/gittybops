#!/bin/sh
# Rust (stable, wasm32 target) in /opt/rustup + /opt/cargo. Run by install.sh as root when box.conf lists it.
# Each site's own ~/.cargo keeps its registry cache; the toolchain itself is shared and read-only.
set -eu
[ ! -x /opt/cargo/bin/rustup ] || exit 0
curl -fsSL -o /tmp/rustup-init "https://static.rust-lang.org/rustup/dist/$(uname -m)-unknown-linux-gnu/rustup-init"
chmod +x /tmp/rustup-init
RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo /tmp/rustup-init -y -q --no-modify-path \
	--profile minimal --default-toolchain stable --target wasm32-unknown-unknown
rm /tmp/rustup-init
chmod -R a+rX /opt/rustup /opt/cargo
