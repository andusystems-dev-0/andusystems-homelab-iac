#!/usr/bin/env python3
# Reads a wings config.yml on stdin (as emitted by `php artisan p:node:configuration <id>`)
# and writes it back with TLS pointed at the cert-manager mount, so the k3s wings pod serves
# https directly. Regenerating from the Panel (rather than restoring a saved secret) keeps the
# node's daemon token in sync with the Panel after any node edit/token reset.
#   WINGS_DEBUG=1  → enable wings debug logging (default off)
import os, sys, yaml

c = yaml.safe_load(sys.stdin.read())
c["debug"] = os.environ.get("WINGS_DEBUG", "false").lower() in ("1", "true", "yes")
api = c.setdefault("api", {})
api["host"] = "0.0.0.0"
api["port"] = 8443
ssl = api.setdefault("ssl", {})
ssl["enabled"] = True
ssl["cert"] = "/etc/wings-tls/tls.crt"
ssl["key"] = "/etc/wings-tls/tls.key"
yaml.safe_dump(c, sys.stdout, default_flow_style=False, sort_keys=False)
