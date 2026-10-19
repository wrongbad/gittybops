#!/bin/sh
# Sets up (or updates) the box from a config directory: toolchains, Caddy, the webhook listener and one
# deploy pipeline per site in its sites.conf. Idempotent: after changing the config, run it again.
#   gittybops/install.sh [config-dir]     (default: the directory this checkout sits in)
#   DRY_RUN=1 gittybops/install.sh        (print what it would do as root, do nothing)
# Run it as yourself: each step that needs root goes through sudo and is printed first, and only when
# something has to change. What root runs later is copied out of your checkout into root-owned places
# (/opt/gittybops, /etc/www, /etc/systemd/system), so nothing you pull runs until you run this again.
set -eu
engine=$(cd "$(dirname "$0")" && pwd -P)
config=$(cd "${1:-$engine/..}" && pwd -P)
. "$engine/lib.sh"
export DRY_RUN
cd "$config"
[ -f sites.conf ] && [ -f Caddyfile ] || { echo "$config has no sites.conf and Caddyfile" >&2; exit 1; }
tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT

# box.conf (optional, shell): TOOLCHAINS (extra ones from toolchains/, e.g. "rust"), ADMINS (users who run
# the box day to day without sudo; default: you), HOOK_URL (only for the message at the end).
if [ "$(id -u)" = 0 ]; then ADMINS=${SUDO_USER:-}; else ADMINS=$(id -un); fi
TOOLCHAINS='' HOOK_URL='https://<your domain>/_hook'
# shellcheck source=/dev/null
[ ! -f box.conf ] || . ./box.conf

case $(uname -m) in
	x86_64) go_arch=amd64 ;;
	aarch64) go_arch=arm64 ;;
	*) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

# --- packages and toolchains (shared by every site's build) ---
if ! command -v git >/dev/null || ! command -v make >/dev/null || ! command -v g++ >/dev/null \
	|| ! command -v curl >/dev/null || ! command -v ssh-keygen >/dev/null; then
	if command -v dnf >/dev/null; then root dnf install -y git gcc gcc-c++ make tar xz curl openssh-clients
	else root apt-get update && root apt-get install -y git build-essential curl xz-utils openssh-client
	fi
fi
for t in node $TOOLCHAINS; do
	[ -f "$engine/toolchains/$t.sh" ] || { echo "no toolchain $t in $engine/toolchains" >&2; exit 1; }
	sh "$engine/toolchains/$t.sh"
done

if [ ! -x /usr/local/bin/caddy ]; then
	[ -n "${DRY_RUN:-}" ] || curl -fsSL -o "$tmp/caddy" "https://caddyserver.com/api/download?os=linux&arch=$go_arch"
	root install -m 755 "$tmp/caddy" /usr/local/bin/caddy
fi
root_owned /usr/local/bin/caddy
id caddy >/dev/null 2>&1 || root useradd --system --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy

# --- admins: group www may trigger the per-site units (bin/www); systemd-journal reads their logs ---
getent group www >/dev/null || root groupadd --system www
regroup=''
for u in $ADMINS; do
	missing=$(for g in www systemd-journal; do id -nG "$u" | tr ' ' '\n' | grep -qx "$g" || echo "$g"; done)
	[ -n "$missing" ] || continue
	root usermod -aG "$(echo "$missing" | paste -sd, -)" "$u"
	regroup="$regroup $u"
done
changed=''
put "$engine/tmpfiles/gittybops.conf" /etc/tmpfiles.d/gittybops.conf
if [ -n "$changed" ] || [ ! -d /run/www ]; then root systemd-tmpfiles --create /etc/tmpfiles.d/gittybops.conf; fi

# --- the engine, copied where only root can change it ---
mkdir "$tmp/engine" && cp -R "$engine/bin" "$engine/hook" "$engine/caddy" "$tmp/engine/"
changed=''
put_dir "$tmp/engine" /opt/gittybops
engine_changed=$changed
[ "$(readlink /usr/local/bin/www)" = /opt/gittybops/bin/www ] || root ln -sfn /opt/gittybops/bin/www /usr/local/bin/www
if [ -x /usr/local/bin/caddy ] && [ -f /opt/gittybops/caddy/hook.caddy ]; then
	XDG_DATA_HOME=$tmp XDG_CONFIG_HOME=$tmp \
		/usr/local/bin/caddy validate --config Caddyfile --adapter caddyfile >/dev/null 2>"$tmp/caddy.log" \
		|| { cat "$tmp/caddy.log" >&2; exit 1; }
fi

# --- config: sites.conf, Caddyfile, env/, one env file per site, the webhook secret ---
sites=$(sed 's/#.*//' sites.conf | awk NF)
mkdir "$tmp/site" "$tmp/env"
kick='' restart=''
while read -r name repo branch port; do
	[ -n "$name" ] || continue
	case $name in *[!a-z0-9-]*) echo "bad site name $name (a-z, 0-9, -)" >&2; exit 1 ;; esac
	{
		echo "SITE=$name"; echo "REPO=$repo"; echo "BRANCH=$branch"; echo "DATA_DIR=/www/sites/$name/data"
		[ "$port" = - ] || echo "PORT=$port"
	} > "$tmp/site/$name.env"
	cmp -s "$tmp/site/$name.env" "/etc/www/site/$name.env" || kick="$kick $name" restart="$restart $name"
	[ ! -f "env/$name.env" ] || cmp -s "env/$name.env" "/etc/www/env/$name.env" || restart="$restart $name"
done <<EOF
$sites
EOF
[ ! -d env ] || find env -maxdepth 1 -name '*.env' -exec cp {} "$tmp/env/" \;

[ -d /etc/www ] || root install -d -m 755 /etc/www
changed=''
put sites.conf /etc/www/sites.conf
hook_changed=$changed$engine_changed
changed=''
put Caddyfile /etc/www/Caddyfile
caddy_changed=$changed$engine_changed
put_dir "$tmp/env" /etc/www/env
put_dir "$tmp/site" /etc/www/site
if [ ! -e /etc/www/hook-secret ]; then
	(umask 077 && od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$tmp/secret")
	root install -m 640 -g www "$tmp/secret" /etc/www/hook-secret
elif [ "$(stat -c %G:%a /etc/www/hook-secret)" != www:640 ]; then
	root chgrp www /etc/www/hook-secret
	root chmod 640 /etc/www/hook-secret
fi

changed=''
for f in "$engine"/systemd/*; do put "$f" "/etc/systemd/system/${f##*/}"; done
[ -z "$changed" ] || root systemctl daemon-reload

# --- sites ---
[ -d /www/sites ] || root install -d -m 755 /www/sites
site_units() {
	echo "www-deploy@$1.path www-deploy@$1.timer www-restart@$1.path www-backup@$1.timer" \
		"www-backup@$1.path www-rollback@$1.path"
}
keys=''
while read -r name repo branch port; do
	[ -n "$name" ] || continue
	user=www-$name dir=/www/sites/$name
	id "$user" >/dev/null 2>&1 \
		|| root useradd --system --user-group --no-create-home --home-dir "$dir" --shell /usr/sbin/nologin "$user"
	group=$(id -gn "$user" 2>/dev/null || echo "$user")
	[ -d "$dir" ] || root install -d -o "$user" -g "$group" -m 755 "$dir"
	# data copied in from an old box is usually someone else's: hand it to the site
	if [ -d "$dir/data" ] && [ "$(stat -c %U "$dir/data")" != "$user" ]; then root chown -R "$user:$group" "$dir/data"; fi
	[ ! -e "$dir/site.env" ] || root rm "$dir/site.env"  # moved to /etc/www/site/<name>.env
	off=$(for u in $(site_units "$name"); do systemctl is-enabled -q "$u" 2>/dev/null || echo "$u"; done)
	if [ -n "$off" ]; then
		# shellcheck disable=SC2086
		root systemctl enable --now $off
		kick="$kick $name"
	fi
	# starts at boot once there is a build with a deploy/start
	systemctl is-enabled -q "www@$name" 2>/dev/null || root systemctl enable "www@$name"
	case " $kick " in *" $name "*) root systemctl start --no-block "www-deploy@$name.service" ;; esac
	# new config for a running server (a deploy only restarts it when the branch moved)
	case " $restart " in *" $name "*)
		! systemctl is-active -q "www@$name" || root systemctl try-restart "www@$name" ;;
	esac
	case $repo in git@*|ssh://*) keys="$keys $name" ;; esac
done <<EOF
$sites
EOF

# Sites removed from sites.conf: stop them, keep their files.
for dir in /www/sites/*/; do
	[ -d "$dir" ] || continue
	name=$(basename "$dir")
	echo "$sites" | awk -v n="$name" '$1 == n {f=1} END {exit !f}' && continue
	on=$(for u in $(site_units "$name") "www@$name"; do
		systemctl is-enabled -q "$u" 2>/dev/null && echo "$u"; done || true)
	# shellcheck disable=SC2086
	[ -z "$on" ] || root systemctl disable --now $on
done

# --- webhook listener, Caddy ---
systemctl is-enabled -q www-hook 2>/dev/null || root systemctl enable www-hook
if [ -n "$hook_changed" ] || ! systemctl is-active -q www-hook; then root systemctl restart www-hook; fi
systemctl is-enabled -q caddy 2>/dev/null || root systemctl enable caddy
if ! systemctl is-active -q caddy; then root systemctl start caddy
elif [ -n "$caddy_changed" ]; then root systemctl reload caddy
fi

echo "ok. webhook: $HOOK_URL, content type application/json, secret: cat /etc/www/hook-secret"
[ -z "$regroup" ] || echo "added$regroup to groups www and systemd-journal: log in again to use them"
for name in $keys; do
	f=/www/sites/$name/deploy-key.pub
	for _ in 1 2 3 4 5; do [ -r "$f" ] || sleep 1; done
	echo "deploy key for $name (add read-only in its repo's Settings > Deploy keys):"
	cat "$f" 2>/dev/null || echo "  made on its first deploy: cat $f"
done
