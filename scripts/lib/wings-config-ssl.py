#!/usr/bin/env python3
# Reads a wings config.yml on stdin (as emitted by `php artisan p:node:configuration <id>`)
# and normalizes the api block for our deployment, writing it back on stdout.
# Regenerating from the Panel (rather than restoring a saved secret) keeps the node's daemon
# token in sync with the Panel after any node edit/token reset.
#
#   WINGS_SSL=0    -> BEHIND-PROXY mode: wings serves plain HTTP on :8443 and an HTTP reverse
#                     proxy (e.g. a Pangolin HTTP resource) terminates TLS (node.behind_proxy=1).
#   default        -> wings terminates TLS itself on :8443 with the mounted cert-manager cert
#                     (CN=nodeN.andusystems.com). Works for LAN-direct AND for a Pangolin
#                     raw-TCP / TLS-passthrough resource (edge forwards the TLS unchanged, so
#                     the browser/panel get wings' valid cert — no edge cert required).
import os, sys, yaml

c = yaml.safe_load(sys.stdin.read())
c["debug"] = os.environ.get("WINGS_DEBUG", "false").lower() in ("1", "true", "yes")
api = c.setdefault("api", {})
api["host"] = "0.0.0.0"
# Daemon listens on 443 so it can share the edge's only working entrypoint via a Pangolin
# TLS-passthrough (SNI) resource, while the panel still reaches it LAN-direct on the same port.
api["port"] = int(os.environ.get("WINGS_PORT", "443"))
ssl = api.setdefault("ssl", {})
if os.environ.get("WINGS_SSL", "1").lower() in ("0", "false", "no"):
    ssl["enabled"] = False   # edge terminates TLS; wings speaks plain HTTP
else:
    ssl["enabled"] = True
    ssl["cert"] = "/etc/wings-tls/tls.crt"
    ssl["key"] = "/etc/wings-tls/tls.key"
yaml.safe_dump(c, sys.stdout, default_flow_style=False, sort_keys=False)
