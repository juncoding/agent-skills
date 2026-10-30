# Maintenance page

Two pages, both served by Caddy from `/data/maint` on the server, branded per client from `deploy/maint/`:

| Page | When | Response |
|---|---|---|
| `maintenance.html` | **planned**: while the flag `/data/maint/ON` exists | 503, `Retry-After: 1800`, for every path and method except `/health` |
| `down.html` | **unplanned**: the app answers 502/503/504 or can't be reached (crash, restart, deploy swap) | 503, `Retry-After: 30`, refreshes itself every 30 s |

An error page the app renders itself (e.g. its own 500) is passed through unchanged. `/health` always
reaches the app, so health checks keep telling the truth during maintenance.

## Commands

```bash
maint.sh on --message "We're upgrading the system." --until "23:00 SGT"   # page on, site-down alert paused
maint.sh on --no-link        # same, without printing the bypass link
maint.sh status              # on | off
maint.sh off                 # page off, site-down alert resumed
maint.sh rotate-bypass       # new bypass token in SSM; old links keep working until the next deploy.sh
```

- Defaults: message "We're carrying out scheduled maintenance to improve the service.", until "shortly".
  Both are free text, HTML-escaped on the server. `--until` is only displayed — nothing is scheduled: to
  do "tonight 10–11pm", run `maint.sh on` at 10pm and `maint.sh off` when the work is done.
- The message is visible in SSM command history (like every remote command): never put secrets in it.
- With `monitoring: cloudwatch`, `on` disables the actions of the `edh-<client>-<env>-site-down` alarm and
  `off` re-enables them, so a planned outage sends no "site down" email. The other alarms stay active.
- `on`/`off` change nothing else: the app keeps running behind the page.

## Bypass link

`maint.sh on` prints `https://<domain>/?maint_bypass=<token>`. Opening it once sets a cookie
(`maint_bypass`, 24 h, HttpOnly, Secure) that lets that browser see the real site while everyone else sees
the maintenance page — for checking the work before switching maintenance off.

- The token is the SSM SecureString `/<client>/<env>/_edh/maint-bypass` (40 hex, made by provision).
- The link is written to the terminal when there is one (so it doesn't land in captured output or logs),
  otherwise to stderr. Treat it as a secret: give it only to the people doing the work, not to a shared
  channel. Use `--no-link` when nobody needs it.
- If it leaked: `maint.sh rotate-bypass`, then `deploy.sh` (the token reaches Caddy at deploy time).

## Customizing the pages

Edit `deploy/maint/maintenance.html` and `deploy/maint/down.html` in the project, commit, get it into main
(the user's review), deploy.

- Keep the placeholders `{{MESSAGE}}` and `{{UNTIL}}` in `maintenance.html`; they are replaced literally.
- Keep `id="edh-maintenance"` and `id="edh-down"` on the main element (tests and checks look for them).
- Make each page **self-contained** (inline CSS, images as `data:` URIs or from another host): every path
  on the domain returns the page itself during maintenance, so `/logo.png` would not load.
- New templates are installed by the next deploy. If maintenance is on at that moment, the page already
  showing is kept until the next `maint.sh on`.

## Maintenance switched on automatically

- `deploy.sh --maint`: during migrations, switched off once the new version is healthy (left **on** if no
  version is healthy, so users see the maintenance page rather than the down page).
- `restore.sh db` (a real restore): during the database swap, off once the app is healthy again.

These run on the server and do **not** pause the site-down alarm — but `/health` keeps answering unless
the app is really down.

## When no page can be shown

The page needs Caddy running. While the server is stopped or rebooting — `resize.sh instance` (3–5 min),
`upgrade.sh os --reboot` (1–2 min), `restore.sh disk` (the whole stack is down for the volume swap) —
visitors get a connection error. Tell the user beforehand, pick a quiet time, and expect a site-down email
if monitoring is on and the outage lasts more than ~2 minutes (or `maint.sh on` first to pause that alarm,
then `maint.sh off` afterwards).
