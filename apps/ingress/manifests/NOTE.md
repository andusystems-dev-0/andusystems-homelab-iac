# Verify the `services[].name`/`port` against `kubectl get svc -A` after first sync —
# Helm release names make a few service names (grafana, nexus, vaultwarden, uptime-kuma,
# jellyfin) version/release-dependent. Hostnames + cert-manager wiring are final.
