# Cloudflare Tunnel and local authorization

Cloudflare is an optional connection below OpenAI Tunnel. It uses a stable domain
and a remotely managed named tunnel. No Cloudflare API key or DNS-management
permission is requested by Luti. OpenAI and Cloudflare can run together.

## Setup

1. In Cloudflare's dashboard, create a remotely managed Cloudflare Tunnel.
2. Add a published hostname on a domain in your Cloudflare account. Route **all
   paths** to the local HTTP service shown in Luti: `http://127.0.0.1:39393` in
   Release, `http://127.0.0.1:39395` in development. OAuth discovery and callbacks
   need the same origin as `/mcp`. Keep the default Host header.
3. Save that HTTPS origin and the Tunnel Token in Luti's Cloudflare section.
   Use the token from the same tunnel that owns the hostname's DNS record and
   published route. Recreating a tunnel requires saving its new token in Luti.
   Luti downloads and verifies the pinned official `cloudflared`; the token is
   stored in Keychain and supplied only to the child process's environment.
4. Select your project and start Luti. Copy the MCP URL into ChatGPT or another
   remote MCP client, choose OAuth and dynamic client registration (DCR).
5. In the browser, note the verification code. In Luti, match the code and callback
   domain, then allow or deny. Client names are self-reported, not verified brands.

Do not place a separate interactive Cloudflare Access login in front of these
routes: MCP clients need to reach OAuth discovery and token endpoints. Luti itself
requires authorization for every MCP request. To protect public OAuth endpoints
from automated traffic at the edge, configure a Cloudflare WAF rate-limiting rule
on `/oauth/register` and `/oauth/authorize` (or restrict source IPs in WAF).
Tunnel readiness reports an edge connection, not proof that the hostname route or
an AI client has been tested.

Connections start with `auto` (QUIC first). If the running connector exposes its
metrics endpoint but is still not ready after 45 seconds, Luti replaces only that
connector with one forced to HTTP/2. A live HTTP/2 connector keeps retrying and
reports reconnecting, even if its first 45 seconds also expire. The listener,
OAuth requests and project jobs stay in place during fallback. A new runtime
starts with `auto` again; an exited connector uses the existing retry backoff.

QUIC uses UDP port 7844; HTTP/2 uses TCP port 7844. A proxy path with working TCP
but no UDP can use the HTTP/2 fallback. If TCP 7844 is also blocked, fallback
cannot establish the tunnel. HY2 or VLESS by itself does not establish which
traffic a particular proxy node forwards; check its routing and UDP support.
Use the local service URL displayed by the current Luti build when configuring
Cloudflare's hostname route. The in-app guide uses that same URL automatically;
the Cloudflare settings page provides a one-click copy action, available while
the Runtime is running.

See [Cloudflare connectivity pre-checks](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/troubleshoot-tunnels/connectivity-prechecks/).

## Troubleshooting

- **Connected, but the domain returns 1033:** check that the hostname's CNAME
  points to the tunnel whose token is saved in Luti. A connector can be healthy
  while the domain points to a different, inactive or deleted tunnel. Keep the
  domain, published route and token on the same tunnel.
- **502 Bad Gateway:** check the published route's local service against the URL
  shown in Luti. Release uses port `39393`; development uses `39395`.
- Verify `https://<your-domain>/.well-known/oauth-authorization-server` returns
  JSON with the configured domain as its issuer. Without credentials, `/mcp`
  should return `401`; then authorize an AI client and test a tool call.

See [Cloudflare error 1033](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1033/).

## Local listener ports

| Connection | Release on the Mac | Development on the Mac |
|---|---|---|
| Cloudflare | `127.0.0.1:39393` | `127.0.0.1:39395` |
| Self-hosted VPS | `127.0.0.1:39394` | `127.0.0.1:39396` |
| OpenAI | Automatically assigned loopback port | Automatically assigned loopback port |

Only configured, enabled connections start their MCP listeners. The project
runtime adds no separate MCP listener. Transport helpers may also use loopback
health/metrics ports; no manual configuration is needed for those. The VPS's
`127.0.0.1:39393` belongs to the remote server and forwards through SSH to the
Mac's VPS listener. Public VPS clients use HTTPS port 443.

## Authorization behavior

- All MCP tools require approval on this Mac. The browser can only wait and receive
  the result; there is no web approval endpoint. The granted scope is `mcp`, covering
  file, command, browser and artifact capabilities in locally added projects,
  including selection of the shared current project through `project_select`.
  Commands run with the current user's privileges, as with the OpenAI connection.
- Remote OAuth clients (such as ChatGPT, Claude, and Grok web connectors) must use
  public `https://` callback URLs. Loopback (`http://127.0.0.1`) and custom-scheme
  redirects are rejected on the remote tunnel. Each registered `client_id` may hold
  at most one pending approval request at a time, and `/oauth/token` uses a dedicated
  rate-limit bucket so registration traffic cannot starve token refreshes.
- Grants are bound to the exact domain and persist across project changes. An
  approved app reaches whichever project is currently selected. Existing retired
  1.0 data is never imported.
- Access tokens last one hour. Refresh tokens rotate on every use; reuse revokes
  the family. A grant expires after 30 days, even when refreshed. Each grant retains
  at most 1,024 consumed refresh hashes; reaching that limit requires new approval.
- Revoke an app below the Cloudflare configuration to invalidate its access and
  refresh tokens. Already running work is not undone; Stop ends the entire runtime.
- Approved apps persist across restarts and can be revoked while stopped. Pending
  requests and codes never survive a disconnect. Clearing the connection settings
  removes the domain and Tunnel Token, not the domain's authorization records.

## Implementation and verification

The previous release's OAuth store, migration logic, and tunnel monitor are not
restored. The only reused Cloudflare implementation is the pinned executable's
digest/signature verification. Connection ownership uses the current
`ConnectionManager`, `ProviderProcess`, `OwnedProcess`, and bounded HTTP server.

The OAuth actor has no timer or strong-reference monitoring loop. It stores at
most 64 temporary registrations, 16 pending requests, 32 authorization codes,
64 durable client records and 32 grants. Expiration is pruned on requests and the
existing UI poll. Request sizes, rate and concurrent HTTP connections remain
bounded. Disk reads occur on load, writes only on grant changes; MCP authentication
performs an in-memory hash lookup. Only random-token hashes are stored in a private,
atomic JSON file; no raw OAuth bearer or client secret is persisted there. Storage
corruption fails closed. Browser responses prohibit framing and referrer leakage.

The tests cover native approval/denial, state round-tripping, PKCE, code expiry and
reuse, token resource binding, refresh replay, persistent revocation, domain
isolation, request bounds, Host/Origin checks, and shutdown. A real Cloudflare
hostname and a real client authorization still need an end-to-end account test.

Protocol references:

- [MCP authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
- [OpenAI MCP authentication](https://developers.openai.com/plugins/build/auth)
- [Cloudflare tunnel parameters](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/)
