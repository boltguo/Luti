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

## Authorization behavior

- All MCP tools require approval on this Mac. The browser can only wait and receive
  the result; there is no web approval endpoint. The granted scope is `mcp`, covering
  the current project's existing file, command, browser and artifact capabilities.
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
