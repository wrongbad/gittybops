#!/bin/sh
# Sets up (or updates) the box from a config directory: toolchains, Caddy, the webhook listener and one
# deploy pipeline per site in its sites.conf. Idempotent: after changing the config, run it again.
#   gittybops/install.sh [config-dir]     (default: the directory this checkout sits in)
#   DRY_RUN=1 gittybops/install.sh        (print what it would change, change nothing)
# Run it as yourself. Everything gittybops keeps is under /www and belongs to you, group www: toolchains in
# /www/tools, the engine and config in /www/live (which is what the units use, so a git pull changes nothing
# until this applies it), triggers in /www/trigger. Root is needed only for packages, users, systemd units,
# /www itself and the webhook secret; each such step is printed, and runs through sudo only when it has
# something to change.
set -eu
umask 002
engine=$(cd "$(dirname "$0")" && pwd -P)
config=$(cd "${1:-$engine/..}" && pwd -P)
. "$engine/lib.sh"
export DRY_RUN
cd "$config"
[ -f sites.conf ] && [ -f Caddyfile ] || { echo "$config has no sites.conf and Caddyfile" >&2; exit 1; }
tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT
me=$(id -un)
[ "$me" != root ] || me=${SUDO_USER:-root}

# box.conf (optional, shell): TOOLCHAINS (extra ones from toolchains/, e.g. "rust"), ADMINS (users in group
# www, who run the box without sudo; default: you), CADDY_VERSION, HOOK_URL (only for the message at the end).
ADMINS=$me TOOLCHAINS='' HOOK_URL='https://<your domain>/_hook' CADDY_VERSION=''
[ "$ADMINS" != root ] || ADMINS=''
# shellcheck source=/dev/null
[ ! -f box.conf ] || . ./box.conf
export CADDY_VERSION

sites=$(sed 's/#.*//' sites.conf | awk NF)
while read -r name _; do
	[ -n "$name" ] || continue
	case $name in *[!a-z0-9-]*) echo "bad site name '$name' in sites.conf (a-z, 0-9, -)" >&2; exit 1 ;; esac
done <<EOF
$sites
EOF

# --- root: packages, group www, /www ---
if ! command -v git >/dev/null || ! command -v make >/dev/null || ! command -v g++ >/dev/null \
	|| ! command -v curl >/dev/null || ! command -v ssh-keygen >/dev/null; then
	if command -v dnf >/dev/null; then root dnf install -y git gcc gcc-c++ make tar xz curl openssh-clients
	else root apt-get update && root apt-get install -y git build-essential curl xz-utils openssh-client
	fi
fi
# Group www may change everything under /www except the sites' own directories: what the sites, Caddy and the
# webhook listener run, and so act as any of them. Never as root. Site users are never in it.
getent group www >/dev/null || root groupadd --system www
regroup=''
for u in $ADMINS; do
	missing=$(for g in www systemd-journal; do id -nG "$u" | tr ' ' '\n' | grep -qx "$g" || echo "$g"; done)
	[ -n "$missing" ] || continue
	root usermod -aG "$(echo "$missing" | paste -sd, -)" "$u"
	regroup="$regroup $u"
done
if [ ! -d /www ]; then root install -d -o "$me" -g www -m 2775 /www
elif [ "$(stat -c %G:%a /www)" != www:2775 ] || [ ! -w /www ]; then
	root chown "$me:www" /www
	root chmod 2775 /www
fi
[ -d /www/sites ] || root install -d -m 755 /www/sites
[ -d /www/tools ] || mine mkdir /www/tools
[ -d /www/trigger ] || mine mkdir -m 2770 /www/trigger

# --- you: toolchains, then the engine and config into /www/live ---
for t in node caddy $TOOLCHAINS; do
	[ -f "$engine/toolchains/$t.sh" ] || { echo "no toolchain $t in $engine/toolchains" >&2; exit 1; }
	sh "$engine/toolchains/$t.sh"
done

stage=$tmp/live
mkdir -p "$stage/engine" "$stage/env"
cp -R "$engine/bin" "$engine/hook" "$engine/caddy" "$stage/engine/"
cp sites.conf Caddyfile "$stage/"
[ ! -d env ] || find env -maxdepth 1 -name '*.env' -exec cp {} "$stage/env/" \;
if [ -x /www/tools/caddy/caddy ]; then
	sed "s#/www/live/#$stage/#g" Caddyfile > "$tmp/Caddyfile"  # check it against the staged engine
	XDG_DATA_HOME=$tmp XDG_CONFIG_HOME=$tmp /www/tools/caddy/caddy validate --config "$tmp/Caddyfile" \
		--adapter caddyfile >/dev/null 2>"$tmp/caddy.log" || { cat "$tmp/caddy.log" >&2; exit 1; }
fi

# Sites whose line or env file changed get a deploy and a restart once the new config is live.
fields() { sed 's/#.*//' "$1" 2>/dev/null | awk -v n="$2" '$1 == n {print $1, $2, $3, $4}'; }
deploy='' restart=''
while read -r name _; do
	[ -n "$name" ] || continue
	if [ "$(fields sites.conf "$name")" != "$(fields /www/live/sites.conf "$name")" ]; then
		deploy="$deploy $name" restart="$restart $name"
	elif [ -f "env/$name.env" ] || [ -f "/www/live/env/$name.env" ]; then
		cmp -s "env/$name.env" "/www/live/env/$name.env" || restart="$restart $name"
	fi
done <<EOF
$sites
EOF

applied=''
if ! diff -r "$stage" /www/live/ >/dev/null 2>&1; then
	[ "$(readlink /www/live 2>/dev/null)" = live.a ] && slot=live.b || slot=live.a
	mine rm -rf "/www/$slot"
	mine cp -R "$stage" "/www/$slot"
	mine chmod -R g+w,o-w "/www/$slot"
	mine ln -sfn "$slot" /www/live.new
	mine mv -T /www/live.new /www/live
	[ -n "${DRY_RUN:-}" ] || echo "updated /www/live ($slot)" >&2
	applied=1
fi

# --- root: the webhook secret (root reads it to hand to the listener, so only root may write it) ---
if [ ! -e /etc/www/hook-secret ]; then
	[ -d /etc/www ] || root install -d -m 755 /etc/www
	root install -m 640 -g www /dev/null /etc/www/hook-secret
	od -An -tx1 -N32 /dev/urandom | tr -d ' \n' | root tee /etc/www/hook-secret >/dev/null
elif [ "$(stat -c %U:%G:%a /etc/www/hook-secret)" != root:www:640 ]; then
	root chown root:www /etc/www/hook-secret
	root chmod 640 /etc/www/hook-secret
fi

# --- root: systemd units, when they changed ---
changed=''
for f in "$engine"/systemd/*; do
	cmp -s "$f" "/etc/systemd/system/${f##*/}" && continue
	root install -m 644 "$f" "/etc/systemd/system/${f##*/}"
	changed=1
done
[ -z "$changed" ] || root systemctl daemon-reload

# --- root: a user, a home and its units for each new site ---
site_units() {
	echo "www-deploy@$1.path www-deploy@$1.timer www-restart@$1.path www-backup@$1.timer" \
		"www-backup@$1.path www-rollback@$1.path"
}
keys=''
while read -r name repo _; do
	[ -n "$name" ] || continue
	user=www-$name dir=/www/sites/$name
	id "$user" >/dev/null 2>&1 \
		|| root useradd --system --user-group --no-create-home --home-dir "$dir" --shell /usr/sbin/nologin "$user"
	group=$(id -gn "$user" 2>/dev/null || echo "$user")
	[ -d "$dir" ] || root install -d -o "$user" -g "$group" -m 755 "$dir"
	# data copied in from an old box is usually someone else's: hand it to the site
	if [ -d "$dir/data" ] && [ "$(stat -c %U "$dir/data")" != "$user" ]; then root chown -R "$user:$group" "$dir/data"; fi
	off=$(for u in $(site_units "$name"); do systemctl is-enabled -q "$u" 2>/dev/null || echo "$u"; done)
	# shellcheck disable=SC2086
	[ -z "$off" ] || root systemctl enable --now $off
	# starts at boot once there is a build with a deploy/start
	systemctl is-enabled -q "www@$name" 2>/dev/null || root systemctl enable "www@$name"
	case $repo in git@*|ssh://*) keys="$keys $name" ;; esac
done <<EOF
$sites
EOF

# Sites removed from sites.conf: stop them, keep their files and user.
for dir in /www/sites/*/; do
	[ -d "$dir" ] || continue
	name=$(basename "$dir")
	echo "$sites" | awk -v n="$name" '$1 == n {f=1} END {exit !f}' && continue
	on=$(for u in $(site_units "$name") "www@$name"; do
		systemctl is-enabled -q "$u" 2>/dev/null && echo "$u"; done || true)
	# shellcheck disable=SC2086
	[ -z "$on" ] || root systemctl disable --now $on
done

for u in www-apply.path www-hook caddy; do
	systemctl is-enabled -q "$u" 2>/dev/null || root systemctl enable --now "$u"
done

# --- you: tell the units what changed (path units do the restarts, as root) ---
[ -z "$applied" ] || mine touch /www/trigger/apply  # restarts the webhook listener, reloads Caddy
for name in $deploy; do mine touch "/www/trigger/deploy-$name"; done
for name in $restart; do mine touch "/www/trigger/restart-$name"; done

# `www` on your PATH, for day-to-day use
if [ "$me" != root ] && [ "$(readlink "$HOME/.local/bin/www" 2>/dev/null)" != /www/live/engine/bin/www ]; then
	mine mkdir -p "$HOME/.local/bin"
	mine ln -sfn /www/live/engine/bin/www "$HOME/.local/bin/www"
fi

echo "ok. webhook: $HOOK_URL, content type application/json, secret: cat /etc/www/hook-secret"
[ -z "$regroup" ] || echo "added$regroup to groups www and systemd-journal: log in again to use them"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "add ~/.local/bin to your PATH for the www command" ;; esac
for name in $keys; do
	f=/www/sites/$name/deploy-key.pub
	for _ in 1 2 3 4 5; do [ -r "$f" ] || [ -n "${DRY_RUN:-}" ] || sleep 1; done
	echo "deploy key for $name (add read-only in its repo's Settings > Deploy keys):"
	cat "$f" 2>/dev/null || echo "  made on its first deploy: cat $f"
done
old=''
for p in /opt/node /opt/rustup /opt/cargo /opt/gittybops /usr/local/bin/caddy /usr/local/bin/www \
	/etc/www/sites.conf /etc/www/Caddyfile /etc/www/env /etc/www/site /etc/tmpfiles.d/gittybops.conf \
	/www/sites/*/site.env; do
	[ ! -e "$p" ] && [ ! -L "$p" ] || old="$old $p"
done
[ -z "$old" ] || echo "left over from an older install, unused now (check nothing else uses them): sudo rm -rf$old"
