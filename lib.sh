# shellcheck shell=sh
# Sourced by install.sh and toolchains/*.sh, which run as you. Only root() runs anything as root, and it prints
# each command first, so a run shows exactly what it does as root (and asks for sudo only when there is
# something to do). DRY_RUN=1 prints the root steps and the changes you would make, and changes nothing.

if [ -t 2 ]; then bold=$(printf '\033[1m') plain=$(printf '\033[0m'); else bold='' plain=''; fi

# root CMD...: run CMD as root.
root() {
	printf '%s# %s%s\n' "$bold" "$*" "$plain" >&2
	[ -z "${DRY_RUN:-}" ] || return 0
	if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi || { echo "failed: $*" >&2; exit 1; }
}

# mine CMD...: run CMD as you; under DRY_RUN, only print it. For the steps that change the box.
mine() {
	if [ -n "${DRY_RUN:-}" ]; then echo "  $*" >&2; else "$@"; fi
}

# swap NEW DEST: replace directory DEST with NEW (next to it), which group www may change and others may not.
swap() {
	mine chmod -R g+w,o-w "$1"
	if [ -e "$2" ]; then mine rm -rf "$2.old" && mine mv -T "$2" "$2.old"; fi
	mine mv -T "$1" "$2"
	mine rm -rf "$2.old"
	[ -n "${DRY_RUN:-}" ] || echo "updated $2" >&2
}
