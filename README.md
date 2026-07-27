# ip-api

Minimal public IPv4 and IPv6 address responders for MehrNet.

The deployed endpoints return only the caller address as plain text with a
trailing newline:

```text
https://ipv4.mehrnet.com
https://ipv6.mehrnet.com
```

They are intentionally independent of the BGP API, its Go binary, PostgreSQL,
and its daily dataset workflow.

## Role in MehrNet

```text
Browser
  |-- ipv4.mehrnet.com / ipv6.mehrnet.com --> ip-api (Nginx, address only)
  `-- bgp-api.mehrnet.com/v1/ip/{address} --> bgp-api (Go + PostgreSQL, BGP data)

bgp.mehrnet.com
  `-- static frontend: resolves a visitor address, then requests the BGP lookup
```

| Repository | Responsibility |
| --- | --- |
| [`mehrnet/bgp`](https://github.com/mehrnet/bgp) | Static public UI at `bgp.mehrnet.com`; temporarily resolves addresses through IPify, then calls `bgp-api`. |
| [`mehrnet/bgp-api`](https://github.com/mehrnet/bgp-api) | Go/PostgreSQL BGP, RIR, route, ASN, and geofeed lookup service. |
| `mehrnet/ip-api` | This repository: independent, stateless IPv4/IPv6 responder configuration. |

Once these responders are live, `bgp` should replace its temporary IPify URLs
with the MehrNet responder URLs. No change to `bgp-api` is required.

## Contract

`GET /` returns a UTF-8 plain-text address and newline:

```text
203.0.113.42
```

or:

```text
2001:db8::42
```

The response includes:

- `Content-Type: text/plain`
- `Cache-Control: no-store`
- `Access-Control-Allow-Origin: *`

Only `GET` and `HEAD` are accepted. Other paths return `404`; other methods on
`/` return `405`.

## Deployment

Detailed instructions are in [docs/deployment.md](docs/deployment.md). The
short version is:

```sh
sudo install -d -m 0755 /etc/nginx/snippets
sudo install -m 0644 nginx/ip-response.conf /etc/nginx/snippets/mehrnet-ip-response.conf
sudo install -m 0644 nginx/ipv4.mehrnet.com.conf /etc/nginx/sites-available/
sudo ln -s ../sites-available/ipv4.mehrnet.com.conf /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

Deploy `ipv4.mehrnet.com` on an IPv4-capable origin and `ipv6.mehrnet.com` on
an IPv6-capable origin. They may be separate servers. The current BGP API host
has no public IPv6 address, so it cannot provide the IPv6 responder.

## Cloudflare and DNS

For actual family-specific behavior, use DNS-only records:

- `ipv4.mehrnet.com`: one `A` record, no `AAAA` record.
- `ipv6.mehrnet.com`: one `AAAA` record, no `A` record.

An orange-cloud Cloudflare hostname presents both Cloudflare anycast address
families, so Nginx cannot guarantee that `ipv4` receives only IPv4 callers or
that `ipv6` receives only IPv6 callers. Cloudflare proxying is acceptable only
when this family distinction is not required.

When proxying through Cloudflare, generate the trusted proxy list before
enabling the real-IP include:

```sh
sudo install -m 0755 scripts/update-cloudflare-realip.sh /usr/local/sbin/
sudo /usr/local/sbin/update-cloudflare-realip.sh
```

Then uncomment the `cloudflare-realip.conf` include in the relevant server
configuration. Never trust `CF-Connecting-IP` from arbitrary direct clients.

## Verification

Run the checks from a dual-stack machine after DNS and TLS are configured:

```sh
curl -4fsS https://ipv4.mehrnet.com
curl -6fsS https://ipv6.mehrnet.com
curl -i -X POST https://ipv4.mehrnet.com/
```

The first command must return an IPv4 address, the second an IPv6 address, and
the final command must return `405`.

## Operations

Nginx is the only runtime. Inspect its logs and configuration with:

```sh
sudo nginx -t
sudo systemctl status nginx
sudo journalctl -u nginx -f
```

Refresh the Cloudflare trusted-proxy ranges periodically only if Cloudflare
proxying is enabled. For DNS-only family-specific responders, no real-IP proxy
configuration is needed.
