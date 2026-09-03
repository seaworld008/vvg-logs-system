# VictoriaLogs MCP

This directory deploys the official VictoriaLogs MCP server behind the official
`vmauth` proxy. It is a read-only, separately deployable addition to the VVG
stack and does not require rebuilding Grafana, VictoriaLogs, or Vector.

## Security model

- Deploy one instance per environment. Do not route test and production through
  a client-controlled header or tool argument.
- Expose only `vmauth`; the MCP container remains on an internal Docker network.
- Require a distinct random bearer token for every environment.
- `vmauth` fixes the VictoriaLogs tenant, allows only approved `/select/logsql`
  paths, clamps log responses to 500 rows, limits field discovery to 100 values,
  applies backend timeouts, and permits one MCP query at a time.
- The client bearer token and the MCP-to-vmauth token must be different.
- Keep `.env`, `vmauth/auth.yml`, access tokens, server addresses, and runtime
  data out of Git. Both deployed files must be mode `0600`; the mounted auth
  file may be changed to `0640` with group `65534` for the non-root proxy.
- Leave `MCP_PASSTHROUGH_HEADERS` unset. In particular, do not forward the
  caller's `Authorization` header to VictoriaLogs.

## Host layout

```text
/data/vvg-mcp/
  docker-compose.yml
  .env
  vmauth/
    auth.yml
  secrets/
    client-bearer-token
  backups/
```

The services are stateless. No application data volume is required. Runtime
logs use bounded Docker `json-file` rotation. The `secrets/` and `backups/`
directories remain under the deployment directory so the whole service has a
single ownership boundary.

## Deployment

1. Resolve the current approved upstream release and mirror its exact
   architecture digest into the private registry.
2. Copy `env.example` to `.env`, use private-registry image references including
   digest, and generate two independent random bearer tokens.
3. Render `vmauth/auth.yml` from `vmauth/auth.example.yml` with the fixed
   environment-specific VictoriaLogs URL and tenant.
4. Validate with the target host's actual Compose binary:

   ```bash
   docker run --rm \
     -v "$PWD/vmauth/auth.yml:/etc/vmauth/auth.yml:ro" \
     "$VMAUTH_IMAGE" \
     -auth.config=/etc/vmauth/auth.yml -dryRun

   docker-compose --env-file .env config -q
   ```

5. Start only this project, then verify both containers, unauthenticated
   rejection, authenticated MCP initialization, tool listing, a 15-minute real
   query, backend concurrency, restart count, OOM state, and existing Grafana
   and VictoriaLogs health.

When replacing `vmauth/auth.yml` atomically on the host, recreate only the
`vmauth` service. A bind-mounted file remains attached to the old inode, so a
HUP reload alone may continue reading the previous file. An in-place update can
use HUP, but atomic replacement plus a targeted recreate is the safer rollout.

Use `http://HOST:MCP_PORT/mcp` as the temporary private-network endpoint. A
later HTTPS reverse proxy must preserve streamable HTTP request headers and
timeouts, authenticate callers, and keep the direct host port private.
