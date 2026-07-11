---
sidebar_position: 6
title: Security
---

# Security model

The container starts as root for ownership setup and to run WeTTY, then every interactive or wrapped headless agent process drops to the `agent` user through `gosu`. WeTTY v3 needs the initial privilege level for local command mode; the agent itself does not.

## Controls and rationale

- **Digest-pinned base image:** the Dockerfile identifies Ubuntu by SHA-256, preventing a mutable tag from silently changing the base layer.
- **`no-new-privileges`:** a process cannot gain privileges through setuid binaries or file capabilities after the user transition.
- **Drop all capabilities:** Docker's normal root capability subset is removed.
- **Minimal added capabilities:** `CHOWN`, `SETUID`, `SETGID`, and `DAC_OVERRIDE` are restored only for entrypoint setup and ownership repair.
- **Validated PUID/PGID:** the entrypoint rejects invalid values and aligns the container user with host-mounted file ownership.
- **Restrictive umask:** entrypoint-created files are not world-readable by default.
- **Read-only configuration mounts:** tools can consume global configuration without rewriting most source-controlled files.
- **Bridge networking:** the stack does not use host networking, though explicitly published ports remain reachable according to Docker's host firewall behavior.
- **Safe headless wrapper:** `agent-task` drops privileges before starting Claude Code. A direct `docker exec ... claude` would inherit root from the container entrypoint and must not be used.

The writable host surface is primarily `workspace/` and `data/`. This limits accidental edits outside projects and persistent agent state, but it does not make untrusted autonomous code harmless: an agent can still modify or delete anything writable and can reach allowed network destinations.

Several tools are downloaded during image builds. Review dependency and image updates before deploying them, even when the base operating-system image is pinned.

:::warning Trusted network required
The upload service on port 1112 has no authentication and permits listing, uploading, and deleting uploads. SearXNG is also currently published on port 8080. Restrict network access or put authenticated reverse proxies in front of exposed services before using the stack beyond a trusted development network.
:::

The self-signed TLS certificate encrypts browser traffic but does not establish public identity. Install or trust the certificate only on systems where you intend to use this service. The model stays on the configured local endpoint, but agent tools, web search, package managers, and browser automation may still make other outbound requests when used.
