# shellcheck shell=sh disable=SC2034  # changed is read by the scripts that source this
# Sourced by install.sh and toolchains/*.sh, which run as you. Only the commands passed to root() run as root,
# and each one is printed first, so a run shows exactly what it does as root, and a run with nothing to do
# asks for no password. DRY_RUN=1 prints those commands without running anything as root.

if [ -t 2 ]; then bold=$(printf '\033[1m') plain=$(printf '\033[0m'); else bold='' plain=''; fi

root() {
	printf '%s# %s%s\n' "$bold" "$*" "$plain" >&2
	[ -z "${DRY_RUN:-}" ] || return 0
	if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi || { echo "failed: $*" >&2; exit 1; }
}

# put FILE DEST [MODE]: install FILE as DEST, owned by root, unless DEST already has the same content.
# put_dir DIR DEST: the same for a whole directory, swapped in with a rename.
# Both set changed=1 when they change something.
put() {
	cmp -s "$1" "$2" 2>/dev/null && return
	root install -m "${3:-644}" "$1" "$2"
	changed=1
}
put_dir() {
	diff -r "$1" "$2" >/dev/null 2>&1 && return
	root rm -rf "$2.new" "$2.old"
	root cp -a "$1" "$2.new"
	root chown -R root:root "$2.new"
	root chmod -R a+rX,go-w "$2.new"
	if [ -e "$2" ]; then root mv "$2" "$2.old"; fi
	root mv "$2.new" "$2"
	root rm -rf "$2.old"
	changed=1
}

# root_owned DIR...: make sure only root can change DIR (older installs unpacked tarballs as root, which kept
# the archive's owners, so another user could replace binaries every site runs).
root_owned() {
	for d; do
		[ -n "$(find "$d" ! -type l \( ! -user root -o -perm /022 \) -print -quit 2>/dev/null)" ] || continue
		root chown -R root:root "$d"
		root chmod -R go-w "$d"
	done
}
