# gittybops

Push-to-deploy for one Linux box: a push to a site's branch rebuilds that site within seconds, with atomic
a/b swaps, warm caches, nightly backups and Caddy in front. Everything is plain shell, systemd units and a
small webhook listener, and it uses root as little as it can: you run `install.sh` as yourself, it asks sudo
only for packages, users, systemd units and the like, and deploys, restarts, rollbacks and updates run
without it.

Your box is described by a **config repo** that you own, with gittybops as a submodule:

```
your-config/
  gittybops/      this repo (git submodule)
  sites.conf      which repo and branch backs each site
  Caddyfile       domains and routes
  env/<site>.env  plain (non-secret) config per site
  box.conf        optional: extra toolchains, admins, Caddy version
  www/...         optional: anything else, e.g. static pages Caddy serves straight from the checkout
```

See `example/` for a starting point.

## New box
Debian, Ubuntu or Amazon Linux 2023 (anything with systemd 247+ and dnf or apt), x86_64 or arm64, ports
80 and 443 open.
```sh
sudo install -d -o "$USER" /www/box
git clone --recurse-submodules <your config repo> /www/box
/www/box/gittybops/install.sh
```
Run `install.sh` as yourself, not with sudo. Each step that needs root is printed (`# useradd ...`) and run
through sudo, and only when it has something to change, so an update that changes nothing asks for no
password. `DRY_RUN=1 gittybops/install.sh` prints what it would change, as root and as you, and changes
nothing. Log in again afterwards to pick up the `www` and `systemd-journal` groups.

Then:
- Point DNS at the box (Caddy gets certificates on its own once it does).
- On each repo in `sites.conf`: Settings > Webhooks > Add webhook, payload URL `https://<domain>/_hook`
  (wherever your Caddyfile has `import /www/live/engine/caddy/hook.caddy`), content type
  `application/json`, secret from `cat /etc/www/hook-secret`, "Just the push event". Private repos (ssh
  URLs) also need the read-only deploy key the site makes on its first deploy: `install.sh` prints it, or
  `cat /www/sites/<name>/deploy-key.pub`; then `www deploy <name>`.

## What lives where
| Path | Owner | What |
| --- | --- | --- |
| `/www/box` | you | your config checkout |
| `/www/live` | you, group `www` | what the units use: the engine and your config, as `install.sh` last applied them (an a/b symlink swap) |
| `/www/tools` | you, group `www` | Node 24, Caddy, and the toolchains `box.conf` lists (`rust`: stable + wasm32) |
| `/www/trigger` | you, group `www` | files `www` and `install.sh` touch to make path units act |
| `/www/sites/<site>` | the site's user `www-<site>` | its a/b builds, `current`, `data/`, caches, `.env` secrets, deploy key |
| `/etc/www/hook-secret` | root, group `www` | the webhook secret; root reads it to hand to the listener |
| `/etc/systemd/system/www*`, `caddy.service` | root | the units |

Root is needed for: packages; group `www` and adding admins to it; `/www` itself; each site's user and home
directory; the units (and enabling them); the webhook secret. Each happens once, or when that thing
changes. Downloads (Node, rustup, Caddy) are checksummed and unpacked by you, straight into `/www/tools`.

Nothing root runs or reads can be changed by you or a site: root runs only the units, the units run only
as a site's user, Caddy's user or the listener's dynamic user, and the files each of those reads are read
by that user (`bin/site-env` loads a site's env files as the site, not systemd as root). Group `www` can
therefore change what every site, Caddy and the listener run, and so act as any of them, but never as root.
Site users are never in group `www`.

## A site's side of the contract
- `deploy/build` (executable, optional): run in the checkout on every push, as the site's user; build in place.
- `deploy/start` (executable, optional): exec the server. It gets `SITE`, `PORT` and `DATA_DIR`, plus
  `env/<site>.env` and `/www/sites/<site>/.env` (secrets: owned by `www-<site>`, mode 600, never committed),
  as `KEY=value` lines.
- `deploy/backup` (executable, optional): run nightly by `www-backup@<site>.timer`, as the site's user, with
  the server's env; the site decides where the backup goes.

Builds and servers see the filesystem read-only except `/www/sites/<site>` and a private `/tmp`. Keep
anything that must survive deploys in `$DATA_DIR`, not the checkout. Point Caddy at
`/www/sites/<name>/current/...` for static output. A second line in `sites.conf` with the same repo, another
branch and another name gives a separate staging copy.

## Changing the box
Edit the config repo, push, then on the box:
```sh
cd /www/box && git pull && git submodule update --init
gittybops/install.sh
```
A pull changes nothing the units use; `install.sh` applies it: it checks the Caddyfile, swaps `/www/live`,
and touches `/www/trigger/apply` (the listener restarts, Caddy reloads), plus `deploy-<site>` for sites
whose line changed and `restart-<site>` for those whose line or env changed. Files Caddy serves straight out
of `/www/box` go live with the `git pull` alone.

## Day to day (no sudo; members of group `www`)
```sh
www deploy <name>                       # redeploy now, and follow it
www backup <name>                       # back up now
www rollback <name>                     # previous build (again: roll forward)
www restart <name>                      # restart the server
www status                              # units, and each site's deployed commit and slot
www log <name>                          # follow everything for one site
journalctl -u 'www-deploy@*' -f         # all deploys
```
`www <action> <site>` touches `/www/trigger/<action>-<site>`, a path unit runs `www-<action>@<site>`, and
`www` follows that run's log and exits with its result. `install.sh` links it as `~/.local/bin/www`.
Stopping a site is the one thing left to `sudo systemctl stop www@<name>`.
A rollback lasts until the next deploy, which also reuses the rolled-back-from slot.

## How it works
- `www-hook` (`hook/hook.mjs`, `DynamicUser`) checks GitHub's signature and touches `/run/www-hook/<site>`.
  It reads only the repo name and branch from the payload.
- `www-deploy@<site>.path` sees that (or `/www/trigger/deploy-<site>`) and starts `www-deploy@<site>`
  (`bin/build`), as the site's user, sandboxed to `/www/sites/<site>`. It fetches the branch into whichever
  of `a` and `b` is not live, runs `deploy/build` there, and only if that succeeds swaps the `current`
  symlink to it (an atomic rename) and touches `/www/sites/<site>/restart`. It repeats until the branch
  stops moving. For private repos it first makes the site's deploy key and pins GitHub's host key.
- `www-restart@<site>.path` sees that (or `/www/trigger/restart-<site>`) and runs `www-restart@<site>`:
  `systemctl restart www@<site>`, as root, taking no input. `www-apply` does the same for the listener and
  Caddy.
- `www-deploy@<site>.timer` runs the same deploy 30 s after boot and every 10 min, for missed webhooks.
- Caddy's admin API is on a socket only Caddy can reach (`/run/caddy/admin.sock`), not `localhost:2019`.
- Each site's caches (`~/.npm`, `~/.cargo`, its `node_modules` and `target/`) live in `/www/sites/<site>` and
  stay warm between deploys (each slot's are one build behind).

Whoever can push to a branch in `sites.conf` can run code on the box as that site's user, nothing more.
Whoever can push to the config repo or this one can, once you pull and run `install.sh`, act as any site,
Caddy or the listener; units they change only take effect through the sudo step `install.sh` prints.

## Sharp edges
- A build that succeeds but whose server then fails to start is still swapped in; there is no health
  check. Roll back.
- Removing a site from `sites.conf` stops its units but keeps `/www/sites/<name>` and its user.

## License
Apache 2.0, see `LICENSE`.
