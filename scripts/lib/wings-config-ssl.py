#!/usr/bin/env python3
# Reads a wings config.yml on stdin (as emitted by `php artisan p:node:configuration <id>`)
# and normalizes the api block for our deployment, writing it back on stdout.
# Regenerating from the Panel (rather than restoring a saved secret) keeps the node's daemon
# token in sync with the Panel after any node edit/token reset.
#
#   WINGS_DEBUG=1  -> enable wings debug logging (default off)
#   WINGS_SSL=1    -> wings terminates TLS itself with the mounted cert-manager cert
#                     (direct/LAN mode). Default (unset/0) = BEHIND-PROXY: wings serves plain
#                     HTTP on :8443 and the Pangolin edge terminates TLS (node.behind_proxy=1).
import os, sys, yaml

c = yaml.safe_load(sys.stdin.read())
c["debug"] = os.environ.get("WINGS_DEBUG", "false").lower() in ("1", "true", "yes")
api = c.setdefault("api", {})
api["host"] = "0.0.0.0"
api["port"] = 8443
ssl = api.setdefault("ssl", {})
if os.environ.get("WINGS_SSL", "0").lower() in ("1", "true", "yes"):
    ssl["enabled"] = True
    ssl["cert"] = "/etc/wings-tls/tls.crt"
    ssl["key"] = "/etc/wings-tls/tls.key"
else:
    ssl["enabled"] = False   # edge (Pangolin) terminates TLS; wings speaks plain HTTP
yaml.safe_dump(c, sys.stdout, default_flow_style=False, sort_keys=False)
