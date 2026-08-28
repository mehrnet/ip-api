# Deployment

`ip-api` is deliberately a DNS-only Nginx service. It returns the direct TCP
peer with `$remote_addr`; no `CF-Connecting-IP`, `X-Forwarded-For`, or proxy
trust configuration is present.

## Prerequisites

- Debian 12
- A public IPv4 origin for `ipv4.mehrnet.com`, or a public IPv6 origin for
  `ipv6.mehrnet.com`
- Ports `80` and `443` reachable for the deployed address family
- A DNS-only record already pointing at that origin
- Git for the initial repository checkout
- An email address for Let's Encrypt expiry notices

Do not proxy either responder through Cloudflare. In particular, Cloudflare's
zone-wide IPv6 compatibility prevents a proxied hostname from being a strict
IPv4-only browser destination.

## Provision

```sh
sudo apt-get update
sudo apt-get install -y --no-install-recommends git
git clone https://github.com/mehrnet/ip-api.git /srv/ip-api
cd /srv/ip-api
sudo ./install.sh --family ipv4 --email admin@mehrnet.com
```

For a new origin whose DNS has not been moved yet, use the bootstrap mode. It
starts the direct HTTP responder and applies the Nginx, sysctl, and zram
configuration without contacting Let's Encrypt:

```sh
sudo ./install.sh --family ipv4 --bootstrap-only
```

After the DNS-only record resolves to that host, rerun the first command with
`--email` to issue the certificate and activate HTTPS.

The installer first enables an HTTP-only ACME challenge vhost, obtains a
certificate with Certbot's webroot authenticator, and activates the repository
TLS vhost. Certbot renewal uses the same webroot; its deploy hook validates and
reloads Nginx after a successful renewal.

For an IPv6 origin, replace `ipv4` with `ipv6`. Do not install both roles on a
host lacking either public address family.

## Resource Profile

The service uses one Nginx worker on a one-vCPU Debian host (`worker_processes
auto` resolves to one), has no upstream application, and disables access logs.
The only per-request work is HTTP/TLS handling, the direct peer lookup, and a
small plaintext response.

`systemd-zram-generator` creates a 512 MiB logical zram device on a 1 GiB host
with `lzo-rle` compression. It is an OOM safety net; normal response handling
does not depend on swap.

The Nginx request limit is per source address (`30r/s`, burst `60`) and the
connection limit is `16` per source address. These values allow normal browser
and programmatic use while containing a single source. They are not a
substitute for upstream network DDoS protection.

## Operations

```sh
sudo nginx -t
sudo systemctl status nginx systemd-zram-setup@zram0.service certbot.timer
sudo zramctl
sudo journalctl -u nginx -u certbot.timer -f
```

Only expose `80` and `443` publicly. Restrict SSH to a management network or
WireGuard. Keep the two responder origins separate from stateful services when
possible: DNS-only records reveal the origin address by design.
