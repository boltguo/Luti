# Self-hosted VPS connection

Open **Connections** to see three rows: OpenAI, Cloudflare and Self-hosted VPS.
Each row has its own enable switch. Click the row to edit its settings. All three
can run together; give the two public connections different HTTPS domains.

The VPS connection replaces `cloudflared` with an encrypted SSH reverse forward.
MCP, local OAuth approval, project files and jobs remain on the Mac. The VPS runs
Caddy on HTTPS port 443 and forwards the complete hostname to its own
`127.0.0.1:39393`, which SSH carries back to Luti. That forwarding port is never
exposed on a public interface. No WireGuard or Cloudflare Tunnel Token is needed.

## First setup: an empty Ubuntu or Debian VPS

1. Point a dedicated domain, such as `mcp.example.com`, at the VPS using DNS-only
   A/AAAA records. Allow inbound TCP on your SSH port (normally 22), 80 and 443 in
   the VPS firewall and cloud security group. Do not open 39393 to the Internet.
2. Click **Self-hosted VPS** in Luti. Enter the HTTPS domain and VPS IP or DNS-only
   SSH hostname. The SSH hostname must reach the VPS directly, even if the public
   MCP domain will later use Cloudflare orange-cloud proxying.
3. Expand the setup guide and copy the server setup script. Review it and run it
   as root in the VPS console. The script installs the distribution's Caddy and
   OpenSSH packages, creates a dedicated `luti` account, and enables automatic
   HTTPS. It refuses to replace an existing website configuration or an unrelated
   `luti` account. The script configures this one Mac as the allowed connector.
4. Copy the `ssh-ed25519` **server host public key** printed in that trusted VPS
   console into Luti. Save the settings and start the runtime. Luti automatically
   generates and keeps its own SSH identity; never copy its private key to the VPS.
5. Add the displayed `/mcp` URL to your MCP client using OAuth/DCR. Approve the
   request in Luti on this Mac, as with the Cloudflare connection.

After the domain's HTTPS works, Cloudflare orange-cloud proxying is optional. Use
**Full (strict)** so Cloudflare validates the VPS certificate. Caddy proxies every
path, including `/mcp`, `/.well-known/*` and `/oauth/*`, preserving the original
Host and Authorization headers. The app does not need Cloudflare DNS credentials.

## Ownership and recovery

- Luti uses macOS's `/usr/bin/ssh`, with batch mode, a dedicated identity, strict
  host-key verification, and no shell, password prompt, agent forwarding or user
  SSH configuration. The VPS account permits only the loopback reverse forward;
  SSH sessions and other forwarding destinations are disabled.
- The private key is stored with mode `0600` under `~/.luti/vps/` (`development/vps/`
  in Debug builds). Clearing connection settings keeps this identity. Host-key
  changes require checking the new key in the VPS console and saving it explicitly.
- The SSH connection is supervised by the existing process owner. A dropped
  connection uses the existing retry backoff without restarting project jobs.
  Readiness checks the public OAuth metadata after SSH is established. A live
  SSH connection waits while DNS, certificates or HTTPS routing recover.
- Cloudflare and VPS use separate local listeners (Release 39393/39394, Debug
  39395/39396) and separate authorization stores. Changing transport may require
  clients to authorize again, even when reusing a domain.
- The Mac must remain running and online. Traffic traverses the VPS and consumes
  its bandwidth. HTTPS and SSH encrypt each network leg; the VPS reverse proxy,
  and Cloudflare when orange-clouded, can read the HTTP content at TLS termination.

The generated setup targets an empty systemd-based Ubuntu/Debian VPS. On a server
that already hosts websites, integrate an equivalent Caddy/Nginx hostname route
and the restricted SSH account manually instead of running the bootstrap script.

References: [SSH forwarding](https://man.openbsd.org/ssh#R),
[SSH server forwarding restrictions](https://man.openbsd.org/sshd_config#PermitListen),
[Caddy automatic HTTPS](https://caddyserver.com/docs/automatic-https),
[Cloudflare Full (strict)](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/).
