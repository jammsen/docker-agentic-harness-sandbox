---
sidebar_position: 6
title: Security
---

# Security model

The container starts as root for ownership setup and to run WeTTY, then every interactive or wrapped headless agent process drops to the `agent` user through `gosu`.

Compose applies `no-new-privileges`, drops all capabilities, and adds back only the setup capabilities required by the entrypoint. Configuration mounts are generally read-only; projects and state are writable through `workspace/` and `data/`.

The base image is digest-pinned, but several tools are downloaded during image builds. Review dependency and image updates before deploying them.

:::warning Trusted network required
The upload service on port 1112 has no authentication and permits listing, uploading, and deleting uploads. SearXNG is also currently published on port 8080. Restrict network access or put authenticated reverse proxies in front of exposed services before using the stack beyond a trusted development network.
:::

The self-signed TLS certificate encrypts browser traffic but does not establish public identity. Install or trust the certificate only on systems where you intend to use this service.
