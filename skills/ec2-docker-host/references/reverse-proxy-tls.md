# Reverse proxy + TLS

The proxy is the only thing facing the internet. Get it right and apps are reachable over HTTPS with
zero per-app TLS work; get it wrong and you can take down every site at once. Hence the discipline here.

The default is **Caddy running as a host systemd service** (not in a container). Running on the host lets
it own ports 80/443 directly and keep its certificate store on the persistent `/data` volume. If a host
you've adopted uses nginx or Traefik instead, the *principles* below still apply — adapt the mechanics.

## Why systemd, not a container

A containerized proxy adds a layer between the internet and the thing that must always be up, and
complicates binding 80/443 and persisting certs. The host service is simpler and its `reload` is a clean,
well-understood operation. Certs live at `/data/caddy` so they survive container *and* instance rebuilds
— re-issuing Let's Encrypt certs on every rebuild risks hitting rate limits.

## How TLS happens

Caddy obtains a certificate **per FQDN automatically** via Let's Encrypt (HTTP-01 challenge on :80) the
first time that hostname is requested. You do nothing per app except make the hostname resolve to the
host's IP. A **wildcard DNS record** (`*.example.com` → EIP) means subdomains resolve immediately with no
DNS change; you still get a normal per-FQDN cert (wildcard DNS does not require a wildcard cert).

A **custom apex domain** (`someapp.com`, not a subdomain of your wildcard) is the exception: it needs its
own A record at that domain's registrar pointing to the host IP, and its own vhost block. Flag this to the
user — it's a manual DNS step they must do, and email/other records may need attention too.

## Adding a vhost is additive — always

Each app contributes its **own** server block. Adding an app appends a block; it never edits another
app's block. This is what makes the proxy safe to touch during a deploy: the change set is purely "one
new block."

```caddy
# one app's block — see assets/Caddyfile.vhost for all three shapes
app.example.com {
    reverse_proxy 127.0.0.1:3001
    encode gzip zstd
}
```

Three shapes (full templates in `assets/Caddyfile.vhost`):
- **reverse_proxy** → the app's host port (combined container or backend-only).
- **no block at all** → frontend hosted externally (e.g. Vercel); only a CNAME exists, the proxy isn't
  involved.
- **file_server** → host-served static frontend, pointed at the release directory.

## The reload dance: validate → swap → reload, never restart

This sequence is non-negotiable because a malformed config must never be able to interrupt the vhosts
already serving live traffic:

1. **Validate locally** if you can (`caddy validate --adapter caddyfile`), to catch typos before they
   reach the host.
2. **Copy to the host as a `.new` file**, don't overwrite the live config yet.
3. **Validate on the host**: `caddy validate --config /etc/caddy/Caddyfile.new`. If it fails, stop — the
   live config is untouched, nothing breaks.
4. **Swap then hot-reload**: move `.new` over the live file and `systemctl reload caddy` (graceful — it
   re-reads config without dropping connections). **Never `restart`** — a restart drops every connection
   to every app on the box.

`scripts/add-vhost.sh` performs exactly this. The mantra: a bad new vhost should cost *nothing* to the
neighbors. If validation fails, you simply don't swap.

## Common gotchas

- After adding a vhost, the **first** HTTPS request triggers cert issuance and may take a second or two;
  a quick 502 immediately after reload usually means the app container isn't up yet, not a proxy problem.
- If a cert won't issue: check DNS actually resolves to the host IP, that :80 is reachable (HTTP-01
  needs it), and that you haven't hit Let's Encrypt rate limits from repeated rebuilds (another reason
  certs live on `/data`).
- Don't hand-edit a proxy config that's generated from a template/source of truth — edit the source and
  re-render, or your change gets clobbered on the next render.
