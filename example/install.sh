#!/bin/sh
# A box's own install script, in the box's config repo (with gittybops as a submodule): whatever the box needs,
# then gittybops for the sites. Run it as yourself after every pull.
set -eu
cd "$(dirname "$0")"
. gittybops/lib.sh

command -v node >/dev/null || root apt-get install -y git nodejs openssh-client
gittybops/setup sites.conf env
