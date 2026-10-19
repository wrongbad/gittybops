# Helpers for setup, and for a box's own install script.

# root CMD...: print CMD, then run it as root. Only for what really needs root.
root() {
	echo "# $*" >&2
	if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}

# put SRC DEST: copy SRC to DEST, replacing it in one step, unless it's already the same.
put() {
	cmp -s "$1" "$2" && return
	cp "$1" "$2.new" && mv "$2.new" "$2" && echo "updated $2" >&2
}
