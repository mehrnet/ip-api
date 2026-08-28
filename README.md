# ip-api

Minimal, DNS-only address-family responders for MehrNet.

```text
http://ipv4.mehrnet.com and https://ipv4.mehrnet.com  -> caller IPv4 address and newline
http://ipv6.mehrnet.com and https://ipv6.mehrnet.com  -> caller IPv6 address and newline
```

The runtime is stock Nginx. There is no application process, database,
container, proxy-header trust, or request-time dependency.

## Contract

`GET /` and `HEAD /` return `text/plain; charset=utf-8`, the direct TCP peer
address, and a trailing newline over either HTTP or HTTPS. Other paths return
`404`; other methods on `/` return `405`.

Responses include `Cache-Control: no-store` and permissive CORS so the public
[`mehrnet/bgp`](https://github.com/mehrnet/bgp) frontend can resolve an address
before calling `bgp-api`.

## DNS Requirement

These endpoints must be **DNS-only**. A reverse proxy cannot preserve strict
address-family semantics because it becomes the browser's network peer.

| Hostname | DNS record | Do not publish |
| --- | --- | --- |
| `ipv4.mehrnet.com` | one `A` record | `AAAA` |
| `ipv6.mehrnet.com` | one `AAAA` record | `A` |

Use separate origins when necessary. An IPv4-only server cannot host the IPv6
responder, and vice versa.

## Install

The installer supports Debian 12 and installs one responder per host. The
matching DNS record must point to that host before certificate issuance.

```sh
sudo apt-get update
sudo apt-get install -y --no-install-recommends git
git clone https://github.com/mehrnet/ip-api.git /srv/ip-api
sudo /srv/ip-api/install.sh --family ipv4 --email admin@mehrnet.com
```

To provision a host before its DNS record is moved, install the HTTP responder
first, then rerun the command with `--email` after the record is live to add
HTTPS:

```sh
sudo /srv/ip-api/install.sh --family ipv4 --bootstrap-only
```

On the IPv6-capable host:

```sh
sudo apt-get update
sudo apt-get install -y --no-install-recommends git
git clone https://github.com/mehrnet/ip-api.git /srv/ip-api
sudo /srv/ip-api/install.sh --family ipv6 --email admin@mehrnet.com
```

The installer configures Nginx, Let's Encrypt renewal, modest per-address
request and connection limits, 4,096-connection listen backlogs, and a
low-CPU persistent zram safety net suitable for a 1 GiB host.

## Update

```sh
cd /srv/ip-api
git pull --ff-only
sudo ./install.sh --family ipv4 --email admin@mehrnet.com
```

Use `--family ipv6` on the IPv6 origin. The script is idempotent and preserves
an existing certificate.

## Verify

Run these from a dual-stack machine after both responders are installed:

```sh
curl -4fsS https://ipv4.mehrnet.com
curl -6fsS https://ipv6.mehrnet.com
curl -si -X POST https://ipv4.mehrnet.com/
```

The first two commands must return their corresponding address families; the
last must return `405`.

## Role in MehrNet

| Repository | Responsibility |
| --- | --- |
| [`mehrnet/bgp`](https://github.com/mehrnet/bgp) | Static public UI. It temporarily uses IPify until both responders are live. |
| [`mehrnet/bgp-api`](https://github.com/mehrnet/bgp-api) | Read-only IP intelligence API backed by bbolt. |
| `mehrnet/ip-api` | This direct address responder service. |

After deployment, update `bgp` to fetch `https://ipv4.mehrnet.com` and
`https://ipv6.mehrnet.com` instead of IPify.
