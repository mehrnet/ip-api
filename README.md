# ip-api

Minimal, DNS-only address-family responders for MehrNet.

```text
http://ipv4.mehrnet.com and https://ipv4.mehrnet.com  -> caller IPv4 address
http://ipv6.mehrnet.com and https://ipv6.mehrnet.com  -> caller IPv6 address
```

The runtime is stock Nginx. There is no application process, database,
container, proxy-header trust, or request-time dependency.

## Contract

`GET /` and `HEAD /` return `text/plain; charset=utf-8`, the direct TCP peer
address over either HTTP or HTTPS. Other paths return `404`; other methods on
`/` return `405`.

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

The single-file installer supports Debian 12 and installs one responder per
host. It downloads a pinned set of Nginx assets from this repository; no Git
checkout is required. The matching DNS record must point to that host before
certificate issuance.

```sh
curl -fsSL https://raw.githubusercontent.com/mehrnet/ip-api/main/install.sh |
  sudo bash -s -- --family ipv4 --email admin@mehrnet.com
```

To provision a host before its DNS record is moved, install the HTTP responder
first, then rerun the command with `--email` after the record is live to add
HTTPS:

```sh
curl -fsSL https://raw.githubusercontent.com/mehrnet/ip-api/main/install.sh |
  sudo bash -s -- --family ipv4 --bootstrap-only
```

On the IPv6-capable host:

```sh
curl -fsSL https://raw.githubusercontent.com/mehrnet/ip-api/main/install.sh |
  sudo bash -s -- --family ipv6 --email admin@mehrnet.com
```

The installer configures Nginx, Let's Encrypt renewal, modest per-address
request and connection limits, 4,096-connection listen backlogs, and a
low-CPU persistent zram safety net suitable for a 1 GiB host.

## Update

```sh
sudo /usr/local/sbin/mehrnet-ip-api --update
```

The update reuses the installed family and certificate. It can also be run
without keeping the local script:

```sh
curl -fsSL https://raw.githubusercontent.com/mehrnet/ip-api/main/install.sh |
  sudo bash -s -- --update
```

Add `--auto-update` during installation to run the same update at 05:30 UTC
each day.

## Uninstall

```sh
sudo /usr/local/sbin/mehrnet-ip-api --uninstall
```

This removes the MehrNet-managed Nginx, sysctl, zram, renewal-hook, and cron
configuration. It leaves Nginx, Certbot, and any already-issued certificate in
place.

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
