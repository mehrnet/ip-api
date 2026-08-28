# MehrNet IP API

`ip-api` is the direct-address responder for MehrNet. It returns the caller's
network address as raw text, with one DNS-only hostname per address family.

```text
ipv4.mehrnet.com -> caller IPv4 address
ipv6.mehrnet.com -> caller IPv6 address
```

It is a stock Nginx deployment. There is no application runtime, database,
container, upstream proxy, or request-time dependency.

## Service Contract

| Hostname | Required DNS | Supported transports | Response |
| --- | --- | --- | --- |
| `ipv4.mehrnet.com` | One `A` record; no `AAAA` record | HTTP and HTTPS | Raw caller IPv4 address |
| `ipv6.mehrnet.com` | One `AAAA` record; no `A` record | HTTP and HTTPS | Raw caller IPv6 address |

`GET /` returns `200`, `text/plain; charset=utf-8`, the direct TCP peer
address, and no trailing newline. `HEAD /` returns the same metadata without a
body. Other paths return `404`; methods other than `GET` and `HEAD` on `/`
return `405`.

Responses include `Cache-Control: no-store`, `Access-Control-Allow-Origin: *`,
and `X-Content-Type-Options: nosniff`.

## Network Model

The Nginx vhost returns `$remote_addr`. This is correct only when the endpoint
is DNS-only: the client must connect directly to the responder.

Do not proxy either hostname through Cloudflare or another reverse proxy. Do
not add `CF-Connecting-IP`, `X-Forwarded-For`, or real-IP trust configuration.
Those changes would make the service depend on proxy behavior and would break
strict IPv4-only or IPv6-only discovery in browsers.

Each installer-managed deployment handles one address family. Use separate
deployments for the IPv4 and IPv6 roles; this installer does not manage both
roles on one host. The matching DNS record must resolve to the host before
HTTPS can be issued.

## Install

Supported platform: Debian 12.

The installer downloads a pinned repository revision and retains itself at
`/usr/local/sbin/mehrnet-ip-api`; a local Git checkout is not required after
installation.

```sh
curl -fsSL https://raw.githubusercontent.com/mehrnet/ip-api/main/install.sh |
  sudo bash -s -- --family ipv4 --email admin@mehrnet.com
```

Install the IPv6 responder with the corresponding hostname and certificate:

```sh
curl -fsSL https://raw.githubusercontent.com/mehrnet/ip-api/main/install.sh |
  sudo bash -s -- --family ipv6 --email admin@mehrnet.com
```

For a host whose DNS record has not been moved yet, start with the HTTP-only
bootstrap vhost:

```sh
curl -fsSL https://raw.githubusercontent.com/mehrnet/ip-api/main/install.sh |
  sudo bash -s -- --family ipv4 --bootstrap-only
```

After the DNS-only record points to the host, rerun the first command with
`--email` to obtain the certificate. HTTP remains available; callers are not
redirected to HTTPS.

## Lifecycle

```sh
# Apply the latest pinned Nginx configuration.
sudo /usr/local/sbin/mehrnet-ip-api --update

# Remove the responder and its managed configuration.
sudo /usr/local/sbin/mehrnet-ip-api --uninstall
```

Add `--auto-update` during installation to schedule the same update at `05:30
UTC` each day. Uninstall removes MehrNet-managed Nginx, sysctl, zram,
renewal-hook, and cron files. Nginx, Certbot, and issued certificates remain
installed.

## Verify

Run these checks from a dual-stack machine after both responders are deployed:

```sh
curl -4fsS https://ipv4.mehrnet.com
curl -6fsS https://ipv6.mehrnet.com
curl -si -X POST https://ipv4.mehrnet.com/
```

The first command must return an IPv4 address, the second an IPv6 address, and
the third must return `405 Method Not Allowed`.

On the responder host:

```sh
sudo nginx -t
sudo systemctl status nginx certbot.timer systemd-zram-setup@zram0.service
sudo journalctl -u nginx -u certbot.timer -f
```

## Runtime and Operations

The vhosts listen with a `4096`-connection backlog, disable access logs, allow
`30` requests per second per source address with a burst of `60`, and limit a
source to `16` concurrent connections. TLS accepts `1.2` and `1.3`; Certbot
renews certificates through the configured webroot and reloads Nginx after a
successful renewal.

The installer also configures a small persistent zram device as an OOM safety
net for constrained hosts. Normal request handling does not rely on swap.

Managed files:

| Path | Purpose |
| --- | --- |
| `/etc/nginx/sites-enabled/ipv4.mehrnet.com` | IPv4 responder vhost |
| `/etc/nginx/sites-enabled/ipv6.mehrnet.com` | IPv6 responder vhost |
| `/etc/nginx/snippets/mehrnet-ip-response.conf` | Common HTTP response rules |
| `/etc/nginx/conf.d/mehrnet-ip-api-limits.conf` | Request and connection limits |
| `/etc/mehrnet-ip-api/install.conf` | Installed family and lifecycle settings |
| `/etc/cron.d/mehrnet-ip-api-update` | Optional daily update schedule |

## MehrNet Integration

| Repository | Responsibility |
| --- | --- |
| [`mehrnet/bgp`](https://github.com/mehrnet/bgp) | Public network lookup interface; discovers the visitor address before querying BGP data |
| [`mehrnet/bgp-api`](https://github.com/mehrnet/bgp-api) | Read-only BGP, allocation, and geofeed API backed by an immutable bbolt dataset |
| `mehrnet/ip-api` | Direct IPv4 and IPv6 address-family responders |

See [deployment details](docs/deployment.md) for firewall, DNS bootstrap, and
host-hardening guidance.
