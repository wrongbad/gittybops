#!/bin/sh
# Sets up (or updates) the box from a config directory: toolchains, Caddy, the webhook listener and one
# deploy pipeline per site in its sites.conf. Idempotent: after changing the config, run it again.
#   sudo gittybops/install.sh [config-dir]    (default: the directory this checkout sits in)
# This is the only step that needs root. It copies what it runs as root into root-owned places (/opt/gittybops,
# /etc/www, /etc/systemd/system), so the config checkout itself can stay owned by you.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
engine=$(cd "$(dirname "$0")" && pwd -P)
config=$(cd "${1:-$engine/..}" && pwd -P)
cd "$config"
[ -f sites.conf ] && [ -f Caddyfile ] || { echo "$config has no sites.conf and Caddyfile" >&2; exit 1; }

# box.conf (optional, shell): TOOLCHAINS (extra ones from toolchains/, e.g. "rust"), ADMINS (users who run
# the box day to day without sudo; default: whoever ran sudo), HOOK_URL (only for the message at the end).
TOOLCHAINS='' ADMINS=${SUDO_USER:-} HOOK_URL='https://<your domain>/_hook'
# shellcheck source=/dev/null
[ ! -f box.conf ] || . ./box.conf

case $(uname -m) in
	x86_64) go_arch=amd64 ;;
	aarch64) go_arch=arm64 ;;
	*) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

# --- packages and toolchains (shared by every site's build) ---
if ! command -v git >/dev/null || ! command -v make >/dev/null || ! command -v g++ >/dev/null \
	|| ! command -v pkcheck >/dev/null; then
	if command -v dnf >/dev/null; then dnf install -y git gcc gcc-c++ make tar xz polkit
	else apt-get update && apt-get install -y git build-essential curl xz-utils polkitd
	fi
fi
for t in node $TOOLCHAINS; do
	[ -f "$engine/toolchains/$t.sh" ] || { echo "no toolchain $t in $engine/toolchains" >&2; exit 1; }
	sh "$engine/toolchains/$t.sh"
done

if [ ! -x /usr/local/bin/caddy ]; then
	curl -fsSL -o /usr/local/bin/caddy "https://caddyserver.com/api/download?os=linux&arch=$go_arch"
	chmod +x /usr/local/bin/caddy
fi
id caddy >/dev/null 2>&1 || useradd --system --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy

# GitHub's published host key, so ssh clones (private repos) don't prompt.
gh_key='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'
grep -qxF "$gh_key" /etc/ssh/ssh_known_hosts 2>/dev/null || echo "$gh_key" >> /etc/ssh/ssh_known_hosts

# --- admins: members of group www read the journal and start/stop/restart the www units (polkit) ---
getent group www >/dev/null || groupadd --system www
for u in $ADMINS; do usermod -aG www,systemd-journal "$u"; done
install -m 644 "$engine/polkit/gittybops.rules" /etc/polkit-1/rules.d/50-gittybops.rules

# --- the engine and the config, copied where only root can change them ---
rm -rf /opt/gittybops.new && mkdir /opt/gittybops.new
cp -R "$engine/bin" "$engine/hook" "$engine/caddy" /opt/gittybops.new/
chmod -R a+rX,go-w /opt/gittybops.new
rm -rf /opt/gittybops.old
[ ! -d /opt/gittybops ] || mv /opt/gittybops /opt/gittybops.old
mv /opt/gittybops.new /opt/gittybops && rm -rf /opt/gittybops.old

install -d /etc/www
if [ ! -s /etc/www/hook-secret ]; then
	(umask 077 && od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > /etc/www/hook-secret)
fi
chgrp www /etc/www/hook-secret && chmod 640 /etc/www/hook-secret
install -d -o caddy -m 700 /var/lib/caddy
runuser -u caddy -- env XDG_DATA_HOME=/tmp XDG_CONFIG_HOME=/tmp \
	/usr/local/bin/caddy validate --config "$config/Caddyfile" --adapter caddyfile >/dev/null
install -m 644 sites.conf Caddyfile /etc/www/
rm -rf /etc/www/env.new && mkdir /etc/www/env.new
[ ! -d env ] || cp env/*.env /etc/www/env.new/ 2>/dev/null || true
chmod -R a+rX,go-w /etc/www/env.new
rm -rf /etc/www/env && mv /etc/www/env.new /etc/www/env

cp "$engine"/systemd/* /etc/systemd/system/
systemctl daemon-reload

# --- sites ---
sites=$(sed 's/#.*//' sites.conf | awk NF)
echo "$sites" | while read -r name repo branch port; do
	[ -n "$name" ] || continue
	case $name in *[!a-z0-9-]*) echo "bad site name $name (a-z, 0-9, -)" >&2; exit 1 ;; esac
	user=www-$name dir=/www/sites/$name
	id "$user" >/dev/null 2>&1 || useradd --system --home-dir "$dir" --shell /usr/sbin/nologin "$user"
	mkdir -p "$dir/data"
	chown "$user:" "$dir" && chown -R "$user:" "$dir/data"  # -R: data copied in from an old box
	chmod 755 "$dir" && chmod 700 "$dir/data"
	{
		echo "SITE=$name"; echo "REPO=$repo"; echo "BRANCH=$branch"; echo "DATA_DIR=$dir/data"
		[ "$port" = - ] || echo "PORT=$port"
	} > "$dir/site.env"
	case $repo in git@*|ssh://*)
		if [ ! -f "$dir/.ssh/id_ed25519" ]; then
			install -d -m 700 -o "$user" "$dir/.ssh"
			runuser -u "$user" -- ssh-keygen -q -t ed25519 -N '' -C "$user@box" -f "$dir/.ssh/id_ed25519"
		fi
		echo "deploy key for $repo (add read-only in the repo's Settings > Deploy keys):"
		cat "$dir/.ssh/id_ed25519.pub" ;;
	esac
	systemctl enable -q --now "www-deploy@$name.path" "www-deploy@$name.timer" "www-restart@$name.path" \
		"www-backup@$name.timer"
	systemctl enable -q "www@$name"  # starts at boot once there is a build with a deploy/start
	systemctl start --no-block "www-deploy@$name.service"
done

# Sites removed from sites.conf: stop them, keep their files.
for dir in /www/sites/*/; do
	[ -d "$dir" ] || continue
	name=$(basename "$dir")
	echo "$sites" | awk -v n="$name" '$1 == n {f=1} END {exit !f}' && continue
	systemctl disable -q --now "www-deploy@$name.path" "www-deploy@$name.timer" "www-restart@$name.path" \
		"www-backup@$name.timer" "www@$name" 2>/dev/null || true
done

# --- webhook listener, Caddy ---
systemctl enable -q www-hook && systemctl restart www-hook
systemctl enable -q caddy
if systemctl is-active -q caddy; then systemctl reload caddy; else systemctl start caddy; fi

echo "ok. webhook: $HOOK_URL, content type application/json, secret: cat /etc/www/hook-secret"
[ -z "$ADMINS" ] || echo "admins ($ADMINS): log in again to pick up the www and systemd-journal groups"
