# gittybops

Push-to-deploy for one Linux box: a push to a site's branch rebuilds that site within seconds, with atomic
a/b swaps, warm caches, nightly backups and Caddy in front. Everything is plain shell, systemd units and a
small webhook listener. Root is needed only to run `install.sh`; deploys, restarts, rollbacks and
day-to-day operations run without it.

Your box is described by a **config repo** that you own, with gittybops as a submodule:

```
your-config/
  gittybops/      this repo (git submodule)
  sites.conf      which repo and branch backs each site
  Caddyfile       domains and routes
  env/<site>.env  plain (non-secret) config per site
  box.conf        optional: extra toolchains, admins
  www/...         optional: anything else, e.g. static pages Caddy serves straight from the checkout
```

See `example/` for a starting point.

## New box
Debian, Ubuntu or Amazon Linux 2023 (anything with systemd 247+ and dnf or apt), x86_64 or arm64, ports
80 and 443 open. Running the www units without sudo needs polkit 0.106+ (Debian 12, Ubuntu 24.04, AL2023);
on older systems install.sh skips that and those commands need sudo.
```sh
sudo install -d -o "$USER" /www/box     # the one sudo besides install.sh
git clone --recurse-submodules <your config repo> /www/box
sudo /www/box/gittybops/install.sh
```
`/www/box` stays yours; `install.sh` copies what root runs out of it (the engine to `/opt/gittybops`,
`sites.conf`, `Caddyfile` and `env/` to `/etc/www`), so nothing you or a push change there runs as root
until you run `install.sh` again. Log in again afterwards to pick up the `www` and `systemd-journal` groups.

Then:
- Point DNS at the box (Caddy gets certificates on its own once it does).
- On each repo in `sites.conf`: Settings > Webhooks > Add webhook, payload URL `https://<domain>/_hook`
  (wherever your Caddyfile imports `/opt/gittybops/caddy/hook.caddy`), content type `application/json`,
  secret from `cat /etc/www/hook-secret`, "Just the push event". Private repos (ssh URLs) also need the
  deploy key `install.sh` printed.

## A site's side of the contract
- `deploy/build` (executable, optional): run in the checkout on every push, as the site's user; build in place.
- `deploy/start` (executable, optional): exec the server. It gets `PORT` and `DATA_DIR`, plus `env/<site>.env`
  and `/www/sites/<site>/.env` (secrets: mode 600, owned by `www-<site>`, never committed).
- `deploy/backup` (executable, optional): run nightly by `www-backup@<site>.timer`, as the site's user, with
  the server's env; the site decides where the backup goes.

Keep anything that must survive deploys in `$DATA_DIR`, not the checkout. Point Caddy at
`/www/sites/<name>/current/...` for static output. A second line in `sites.conf` with the same repo,
another branch and another name gives a separate staging copy.

## Changing the box
Edit the config repo, push, then on the box:
```sh
cd /www/box && git pull && git submodule update --init
sudo gittybops/install.sh
```
Read the diff first (`git diff HEAD@{1}`, and the submodule's): `install.sh` runs as root. Files Caddy
serves straight out of `/www/box` go live with the `git pull` alone.

## Day to day (no sudo; members of group `www`)
```sh
journalctl -u 'www-deploy@*' -f         # deploys
journalctl -u 'www@*' -f                # site servers
journalctl -u 'www-backup@*'            # nightly backups
systemctl list-units 'www*'
systemctl start www-deploy@<name>       # redeploy now
systemctl start www-backup@<name>       # back up now
systemctl start www-rollback@<name>     # previous build (again: roll forward)
systemctl restart www@<name>
cat /www/sites/<name>/deployed          # commit of the last successful build
```
A rollback lasts until the next deploy, which also reuses the rolled-back-from slot.

## How it works
- `www-hook` (`hook/hook.mjs`, `DynamicUser`) checks GitHub's signature and touches `/run/www-hook/<site>`.
  It reads only the repo name and branch from the payload.
- `www-deploy@<site>.path` sees that and starts `www-deploy@<site>` (`bin/build`), as the site's own user
  `www-<site>`, sandboxed to `/www/sites/<site>`. It fetches the branch into whichever of `a` and `b` is not
  live, runs `deploy/build` there, and only if that succeeds swaps the `current` symlink to it (an atomic
  rename) and touches `/www/sites/<site>/restart`. It repeats until the branch stops moving.
- `www-restart@<site>.path` sees that and runs `www-restart@<site>`: `systemctl restart www@<site>`, the only
  root step of a deploy, which takes no input.
- `www-deploy@<site>.timer` runs the same deploy 30 s after boot and every 10 min, for missed webhooks.
- Shared toolchains: Node 24 in `/opt/node` (always), others from `toolchains/` as `box.conf` lists them
  (`rust`: stable with the wasm32 target, in `/opt/rustup` + `/opt/cargo`), Caddy in `/usr/local/bin`. Each
  site's caches (`~/.npm`, `~/.cargo`, its `node_modules` and `target/`) live in `/www/sites/<site>` and stay
  warm between deploys (each slot's are one build behind).
- `polkit/gittybops.rules` lets group `www` start, stop and restart `www@`, `www-deploy@`, `www-backup@` and
  `www-rollback@` units, nothing else.

Whoever can push to a branch in `sites.conf` can run code on the box as that site's user, nothing more.
Whoever can push to the config repo or this one can run code as root, but only once you pull and run
`install.sh`.

## Sharp edges
- A build that succeeds but whose server then fails to start is still swapped in; there is no health
  check. Roll back.
- Removing a site from `sites.conf` stops its units but keeps `/www/sites/<name>` and its user.
- Builds see the filesystem read-only except `/www/sites/<site>` and a private `/tmp`.

## License
Apache 2.0, see `LICENSE`.
