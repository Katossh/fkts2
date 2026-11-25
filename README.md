# fkts2 — Xray on one VPS with two public IPs

A separate, modular Docker Compose stack for this topology:

```text
Client -- VLESS + REALITY --> ENTRY_IP:INBOUND_PORT
                                  |
                                  | Xray freedom outbound
                                  | sendThrough = EXIT_IP
                                  v
                             Internet
                         websites see EXIT_IP
```

This is **one VPS**, not a two-server chain. There is no second VLESS tunnel and no self-steal. REALITY is used only on the inbound; `freedom.sendThrough` selects the source address for outbound connections.

## Why the container uses host networking

`sendThrough` binds outbound sockets to `EXIT_IP`. The Xray process therefore needs to see the host's actual addresses in its network namespace. Docker bridge networking would put Xray in a separate namespace and normally make the host's public `EXIT_IP` unavailable for `bind(2)`. The Compose service uses `network_mode: host` and intentionally has no `ports:` section.

The host must have **both IPs configured/routed locally**. Merely seeing two IPs in the provider dashboard is not enough. The preflight checks local address assignment and asks the kernel for a route sourced from `EXIT_IP`; it does not modify host networking.

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

Run these commands from the `fkts2` directory on the VPS:

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
- `ENTRY_ADDRESS`: IP or DNS name clients will connect to
- `REALITY_TARGET` and `REALITY_SERVER_NAME`: a real TLS target and SNI that the target accepts
- `INBOUND_PORT`: leave `8443` while staging; use `443` only during cutover

`init.sh` creates a new client UUID and short ID. Do not publish `.env` or `runtime/`.

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

1. `EXIT_IP` must be a source address that the provider permits. Some providers route an additional IPv4 through a gateway or require a specific `/32` route; the preflight cannot invent that provider-specific setup.
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
