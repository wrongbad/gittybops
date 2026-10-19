# gittybops

Push-to-deploy for the sites on one Linux box. A push to a site's branch rebuilds it within seconds, in
whichever of two slots isn't live, and swaps it in only if the build succeeds. Plain shell, systemd units and
a small webhook listener, using root only where it has to.

gittybops does one job: the sites. Your box's config repo owns everything else (packages, toolchains, the
proxy) and calls gittybops from its own install script. Add it as a submodule; see `example/`:

```sh
. gittybops/lib.sh                                 # root(): print a command, then sudo it
command -v node >/dev/null || root apt-get install -y git nodejs openssh-client
gittybops/setup sites.conf env                     # [PATH] for node and the builds' tools, if not system ones
```

`setup` is safe to run after every pull: each root step is printed and runs only when something changes.

## Sites
`sites.conf` has one line per site: `name repo branch port` (port `-` if there's no server). In the site's
repo, all optional and executable:
- `deploy/build`: run in the checkout on every push, as the site's user `www-<name>`.
- `deploy/start`: exec the server, with `SITE`, `PORT`, `DATA_DIR`, the box's `env/<name>.env` and the
  site's secrets in `/www/sites/<name>/.env` (`KEY=value` lines; owned by `www-<name>`, mode 600).
- `deploy/backup`: run nightly, with the same environment.

Builds and servers can write only `/www/sites/<name>` and a private `/tmp`. Keep what must survive deploys in
`$DATA_DIR`. Serve static output from `/www/sites/<name>/current/...`.

Webhook: point your proxy's `/_hook` at `127.0.0.1:9000`, then on each repo add a webhook (content type
`application/json`, "Just the push event") with the secret from `sudo cat /etc/www/hook-secret`. Private
repos (ssh URLs) need the deploy key each site makes on its first deploy:
`cat /www/sites/<name>/deploy-key.pub`.

## Day to day (no sudo)
```sh
www status                                   # each site's deployed commit
www deploy|backup|rollback|restart <name>    # now, following the log
www log <name>                               # follow everything about a site
```
`www` is `/www/gittybops/bin/www`. A rollback swaps back to the other slot, until the next deploy.

## How it works
- `www-hook` checks GitHub's signature and touches `/run/www-hook/<name>` for each site on that branch.
- `www-deploy@<name>.path` sees it and runs `bin/build` as the site's user: fetch into the idle slot, build,
  swap the `current` symlink, touch `restart`. A timer runs it too, 30 s after boot and every 10 min.
- `www-restart@<name>.path` sees that and restarts `www@<name>`. That restart is the only part of a deploy
  that runs as root, and it takes no input.
- `www` and `setup` work the same way, by touching files in `/www/gittybops/trigger`.

| Path | Owner | |
| --- | --- | --- |
| `/www/gittybops` | you | the scripts, each site's line and env, the triggers |
| `/www/sites/<name>` | `www-<name>` | its two slots, `current`, `data`, caches, secrets |
| `/etc/www/hook-secret` | root | the webhook secret |
| `/etc/systemd/system/www*` | root | the units |

Root runs nothing you or a site can change, and reads none of their files: units that run as a site start
through `bin/site-env`, which reads its env files as the site. Whoever can push to a site's branch can run
code as that site's user, nothing more.

## License
Apache 2.0, see `LICENSE`.
