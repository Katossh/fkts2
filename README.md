# fkts2 — Xray on one VPS with one or two public IPs

A separate, modular Docker Compose stack. It supports temporary single-IP staging and the intended two-IP topology:

```text
Client -- VLESS + REALITY --> ENTRY_IP:INBOUND_PORT
                                  |
                                  | Xray freedom outbound
                                  | sendThrough = EXIT_IP
                                  v
                             Internet
                         websites see EXIT_IP
```

This is **one VPS**, not a two-server chain. There is no second VLESS tunnel and no self-steal. REALITY is used only on the inbound; `freedom.sendThrough` selects the source address for outbound connections. In single-IP mode, both addresses are intentionally identical, so websites see the same IP used by the inbound.

## Why the container uses host networking

`sendThrough` binds outbound sockets to `EXIT_IP`. The Xray process therefore needs to see the host's actual addresses in its network namespace. Docker bridge networking would put Xray in a separate namespace and normally make the host's public `EXIT_IP` unavailable for `bind(2)`. The Compose service uses `network_mode: host` and intentionally has no `ports:` section.

The host must have **both IPs configured/routed locally**. Merely seeing two IPs in the provider dashboard is not enough. The preflight checks local address assignment and asks the kernel for a route sourced from `EXIT_IP`; it does not modify host networking.

## Single-IP staging mode

You can deploy and test the service before purchasing or configuring a second public IP. Set these values in the private `.env` file:

```dotenv
SINGLE_IP_MODE=true
ENTRY_IP=48.103.144.17
EXIT_IP=48.103.144.17
ENTRY_ADDRESS=xray.katossh.dpdns.org
INBOUND_PORT=8443
```

Replace `48.103.144.17` if the VPS entry address changes. In this mode, inbound and outbound traffic use the same IPv4 address. This is useful for testing DNS, REALITY, Docker, and basic connectivity, but it does **not** provide IP separation.

The renderer rejects identical ENTRY/EXIT addresses unless `SINGLE_IP_MODE=true`. It also rejects different addresses while single-IP mode is enabled, preventing an accidental ambiguous configuration.

When a second public IP has been assigned and configured on the host, switch to:

```dotenv
SINGLE_IP_MODE=false
ENTRY_IP=YOUR_ENTRY_IP
EXIT_IP=YOUR_SECOND_IP
```

Then rerun:

```bash
bash ./scripts/render.sh
bash ./scripts/preflight.sh
```

The preflight still requires both addresses to be assigned locally and verifies that the kernel has a route using EXIT_IP.

## Isolation from the current `fkts`

- This directory and Compose project are independent of `fkts`.
- The default inbound port is `8443` so the new Xray process does not immediately collide with a current `:443` listener.
- No Caddy container, certificate files, UFW rules, or existing containers are changed.
- Change `INBOUND_PORT` to `443` only during a deliberate cutover, after checking what currently owns that socket.

## Modules

`config/render.py` generates these Xray `confdir` fragments:

| File | Responsibility |
|---|---|
| `00-log.json` | Conservative logging; access log disabled |
| `10-inbounds.json` | VLESS + REALITY inbound bound to `ENTRY_IP` |
| `20-outbounds.json` | `freedom` outbound bound to `EXIT_IP`, plus blackhole |
| `30-routing.json` | Blocks private-address destinations; all other traffic uses the first outbound (`exit-ip-2`) |

The source `.env` and generated files under `runtime/` are excluded from Git because they contain credentials/private keys.

## Bootstrap

Run these commands from the `fkts2` directory on the VPS. The bootstrap copies `.env.example` to a private `.env`; edit that file before deploying anything:

```bash
bash ./scripts/init.sh
bash ./scripts/keygen.sh
```

Copy the output values into `.env`:

- `PrivateKey` → `REALITY_PRIVATE_KEY` (keep secret)
- `Password` → `REALITY_PUBLIC_KEY` (client-side REALITY public key)

Then edit `.env`:

- `ENTRY_IP`: first IP, used for the inbound listener
- `EXIT_IP`: second IP, used as the outbound source address
- `ENTRY_ADDRESS`: DNS name clients will connect to; default is `xray.katossh.dpdns.org`
- `REALITY_TARGET` and `REALITY_SERVER_NAME`: a real TLS target and SNI that the target accepts
- `INBOUND_PORT`: leave `8443` while staging; use `443` only during cutover

`init.sh` creates a new client UUID and short ID. Do not publish `.env` or `runtime/`.

## Cloudflare DNS deployment

The optional `cloudflare-dns` Compose service manages exactly one dedicated record:

- Zone: `katossh.dpdns.org`
- Record: `xray.katossh.dpdns.org`
- Type: `A`
- Content: `ENTRY_IP`
- Proxy: **DNS-only** (`proxied=false`, grey cloud)
- TTL: automatic (`1`)

It does not touch the zone apex or the existing `gw`, `cdn`, or `fallback` records. It refuses record names outside `CF_ZONE_NAME` and fails rather than choosing between duplicate A records. If a CNAME already occupies the dedicated hostname, Cloudflare will reject the A-record creation; resolve that conflict explicitly instead of deleting records automatically.

### Cloudflare credentials

Create an API token scoped to this zone with **Zone / DNS / Edit** permission and set:

- `CF_API_TOKEN`: the token (keep it private; never commit `.env`)
- `CF_ZONE_ID`: the Zone ID shown on the Cloudflare zone overview
- `CF_ZONE_NAME`: `katossh.dpdns.org`
- `CF_RECORD_NAME`: `xray.katossh.dpdns.org`

The token should be restricted to the `katossh.dpdns.org` zone. No Global API Key is needed.

After setting `ENTRY_IP` and the Cloudflare values in `.env`, deploy the record:

```bash
bash ./scripts/deploy-domain.sh
```

This builds and runs a short-lived, unprivileged container. The operation is idempotent: it creates the A record if missing, or updates only that record if its address/proxy mode/TTL differs. It deliberately forces DNS-only mode because the Xray/REALITY listener must receive direct connections; ordinary Cloudflare proxying is not enabled for this hostname. The generated client profile will use `ENTRY_ADDRESS=xray.katossh.dpdns.org`.

No AAAA record is created. Add IPv6 only after the VPS has a working global IPv6 address and Xray/firewall routing has been configured for it.

## Validate and start

```bash
bash ./scripts/preflight.sh
bash ./scripts/deploy.sh
```

`preflight.sh` checks that both IPs are present on the host, that the kernel can route using `EXIT_IP`, and that Compose accepts the service definition. `deploy.sh` then runs Xray's own `run -test` against all generated fragments before starting the container.

The repository stores shell scripts as regular GitHub content files. Invoke them through `bash` as shown above.

Useful commands:

```bash
docker compose ps
docker compose logs -f xray
docker compose exec xray /usr/local/bin/xray version
```

To regenerate the fragments after changing `.env`:

```bash
bash ./scripts/render.sh
docker compose run --rm --no-deps xray run -test -confdir /usr/local/etc/xray
```

## Client profile

After rendering, import `runtime/client-config.json` into the Xray-compatible client. It uses:

- address: `ENTRY_ADDRESS`
- port: `INBOUND_PORT`
- UUID: generated `CLIENT_UUID`
- flow: `xtls-rprx-vision`
- REALITY SNI: `REALITY_SERVER_NAME`
- REALITY public key: `REALITY_PUBLIC_KEY`
- short ID: `REALITY_SHORT_ID`

The generated client profile uses the current `password` field for the REALITY public key.

## Important caveats

1. In two-IP mode, `EXIT_IP` must be a source address that the provider permits. In single-IP staging mode, `ENTRY_IP` and `EXIT_IP` are intentionally the same. Some providers route an additional IPv4 through a gateway or require a specific `/32` route; the preflight cannot invent that provider-specific setup.
2. If `EXIT_IP` is not assigned in the host network namespace, Xray's `sendThrough` bind will fail. Do not solve that by blindly enabling non-local binds; configure the address and route correctly first.
3. REALITY forwards unauthenticated handshakes to `REALITY_TARGET`. Choose a real target/SNI pair deliberately; do not point it at a generic CDN front door without understanding the fallback behaviour.
4. `geoip:private` requires the geoip data bundled with the official Xray image. The generated config blocks private destinations but does not implement country/domain split routing.
5. This is a staging scaffold. It does not deploy itself to the remote VPS from ChatGPT, and it has not been run against the VPS provider's network. The host-specific IP assignment and final port cutover must be verified on that machine.

## Rollback

The staged stack can be stopped without affecting `fkts`:

```bash
docker compose down
```

Do not use `docker compose down` from the existing `/root/fkts` directory.
