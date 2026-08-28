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
- An email address for Let's Encrypt expiry notices

Do not proxy either responder through Cloudflare. In particular, Cloudflare's
zone-wide IPv6 compatibility prevents a proxied hostname from being a strict
IPv4-only browser destination.

## Provision

```sh
curl -fsSL https://raw.githubusercontent.com/mehrnet/ip-api/main/install.sh |
  sudo bash -s -- --family ipv4 --email admin@mehrnet.com
```

For a new origin whose DNS has not been moved yet, use the bootstrap mode. It
starts the direct HTTP responder and applies the Nginx, sysctl, and zram
configuration without contacting Let's Encrypt:

```sh
curl -fsSL https://raw.githubusercontent.com/mehrnet/ip-api/main/install.sh |
  sudo bash -s -- --family ipv4 --bootstrap-only
```

After the DNS-only record resolves to that host, rerun the first command with
`--email` to issue the certificate and add HTTPS. The HTTP responder remains
active and returns the same direct peer address without redirecting callers.

The installer first enables an HTTP-only ACME challenge vhost, obtains a
certificate with Certbot's webroot authenticator, and activates the repository
TLS vhost. Certbot renewal uses the same webroot; its deploy hook validates and
reloads Nginx after a successful renewal.

For an IPv6 origin, replace `ipv4` with `ipv6`. Do not install both roles on a
host lacking either public address family.

## Update and removal

The installer is retained as `/usr/local/sbin/mehrnet-ip-api`, so a checked-out
repository is never needed after provisioning:

```sh
sudo /usr/local/sbin/mehrnet-ip-api --update
sudo /usr/local/sbin/mehrnet-ip-api --uninstall
```

The update resolves and downloads one exact GitHub commit before it changes the
live configuration. Supply `--auto-update` at initial installation to schedule
that update daily at 05:30 UTC. Removal leaves the Nginx and Certbot packages,
as well as any issued certificate, in place.

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
