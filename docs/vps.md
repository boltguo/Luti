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
   the cloud security group. The setup script also adds TCP 80/443 rules when UFW
   is already active; other system firewalls need equivalent rules. Do not open
   39393 to the Internet.
2. Click **Self-hosted VPS** in Luti. Enter the HTTPS domain (e.g. `mcp.example.com`). By default, Luti connects SSH directly to that domain and pins the server's SSH host public key automatically on first connection. (If your domain already uses orange-cloud proxying or you want strict manual verification, use the visible **SSH settings** fields to set a direct VPS IP or host public key.)
3. Expand **VPS setup guide**. The script domain is taken from the current HTTPS
   input above and is displayed next to the copy button. The button is disabled
   until the domain is valid; you do not need to save settings first. Copy the
   server setup script, review it and run it
   as root in the VPS console. The script installs the distribution's Caddy and
   OpenSSH packages, creates a dedicated `luti` account, and enables automatic
   HTTPS. It refuses to replace an existing website configuration or an unrelated
   `luti` account. The script configures this one Mac as the allowed connector. Use `sudo -i`
   first when signed in as a regular user. It does not enable/reset UFW or change
   SSH rules. Cloud security groups must still be configured in the cloud console.
4. Save the settings in Luti and start the runtime. Luti automatically generates
   and keeps its own SSH identity; never copy its private key to the VPS. The
   optional server public key is the complete `ssh-ed25519 ...` line printed by
   the script, not the Mac identity. Wait for **Connected** in Luti.
5. Add the displayed `/mcp` URL to your MCP client using OAuth/DCR. Approve the
   request in Luti on this Mac, as with the Cloudflare connection.

After the domain's HTTPS works, Cloudflare orange-cloud proxying is optional. Use
**Full (strict)** so Cloudflare validates the VPS certificate, and set your
VPS IP in **SSH settings** so SSH keeps reaching the server directly. Caddy
proxies every path, including `/mcp`, `/.well-known/*` and `/oauth/*`,
preserving the original Host and Authorization headers. The app does not need
Cloudflare DNS credentials.

## Checks and troubleshooting

The cloud security group and the VPS system firewall are separate layers. Both
must allow inbound TCP 80/443 for this setup. The script only manages these two
rules in an already active UFW; it cannot change the cloud security group.
`Valid configuration` confirms Caddyfile syntax. Certificate issuance happens
separately and needs public access to the server.

| Observed result | Meaning and next check |
|---|---|
| SSH connected, public HTTPS not ready | Check DNS, both firewall layers and Caddy certificate logs. Project tasks continue. |
| Caddy log: ACME `Timeout during connect` | The certificate authority cannot reach the server on 80/443. Check inbound rules before retrying. |
| HTTPS returns 502 | Caddy is reachable, but its SSH upstream is not ready. Keep Luti running and check the VPS loopback listener on 39393. A brief 502 can occur during Runtime restart. |
| OAuth discovery returns 200 | The public HTTPS route reaches Luti. |
| `/mcp` returns 401 without a token | Expected authentication boundary. Connect from an AI client and approve OAuth on the Mac. |

Read-only checks on the VPS:

```sh
sudo ufw status verbose
sudo ss -lntp | grep -E ':(80|443|39393)[[:space:]]'
sudo journalctl -u caddy -n 60 --no-pager
```

For deployments made with the earlier script, an active UFW may still need:

```sh
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo systemctl restart caddy
```

After changing the firewall, check
`https://YOUR_DOMAIN/.well-known/oauth-protected-resource/mcp`. A 200 JSON response
with the expected `/mcp` resource and **Connected** in Luti confirm transport
readiness. Authorizing a real AI client is the final check. The deployment guide
remains readable while the Runtime runs; configuration changes require stopping it.

## Ownership and recovery

- Luti uses macOS's `/usr/bin/ssh`, with batch mode, a dedicated identity,
  `accept-new` (or strict manual) host-key pinning, and no shell, password
  prompt, agent forwarding or user SSH configuration. The VPS account permits
  only the loopback reverse forward; SSH sessions and other forwarding
  destinations are disabled.
- The private key and pinned `known_hosts` are stored with mode `0600` under
  `~/.luti/vps/` (`development/vps/` in Debug builds). Clearing connection
  settings keeps the SSH identity but resets auto-pinned host keys. Saving settings
  preserves existing pins, including when changing the public domain. If a pinned
  server key changes, the connection is refused. Verify the new key in the VPS
  console, then enter it in SSH settings or clear and configure the connection again.
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
