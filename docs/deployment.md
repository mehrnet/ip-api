# Deployment

`ip-api` has no application process, database, build artifact, or release
sync. It is an Nginx configuration deployed independently from `bgp-api`.

## 1. Provision network paths

Provision these independently:

| Service | Required origin connectivity | DNS record |
| --- | --- | --- |
| `ipv4.mehrnet.com` | Public IPv4 | `A` only |
| `ipv6.mehrnet.com` | Public IPv6 | `AAAA` only |

Do not create an `AAAA` record for the IPv4 service or an `A` record for the
IPv6 service. Keep both records DNS-only when you need strict address-family
semantics.

## 2. Install Nginx

On each relevant origin:

```sh
sudo apt-get update
sudo apt-get install -y nginx curl
sudo systemctl enable --now nginx
```

## 3. Install the shared responder location

```sh
sudo install -d -m 0755 /etc/nginx/snippets
sudo install -m 0644 nginx/ip-response.conf /etc/nginx/snippets/mehrnet-ip-response.conf
```

## 4. Install the correct virtual host

On the IPv4 origin:

```sh
sudo install -m 0644 nginx/ipv4.mehrnet.com.conf /etc/nginx/sites-available/
sudo ln -s ../sites-available/ipv4.mehrnet.com.conf /etc/nginx/sites-enabled/
```

On the IPv6 origin:

```sh
sudo install -m 0644 nginx/ipv6.mehrnet.com.conf /etc/nginx/sites-available/
sudo ln -s ../sites-available/ipv6.mehrnet.com.conf /etc/nginx/sites-enabled/
```

Disable any conflicting default Nginx site, then validate and reload:

```sh
sudo nginx -t
sudo systemctl reload nginx
```

## 5. Enable TLS

Use the certificate tooling appropriate to the host. With Certbot and a
reachable HTTP-01 path:

```sh
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d ipv4.mehrnet.com
sudo certbot --nginx -d ipv6.mehrnet.com
```

For an IPv6-only origin, DNS-01 validation may be more practical if the
certificate authority cannot reach the HTTP-01 challenge over the published
address family.

## Optional: Cloudflare proxy mode

Cloudflare proxy mode does not preserve a strict IPv4-only or IPv6-only DNS
service because its edge advertises both address families. Use it only if a
generic "show my IP" endpoint is acceptable.

If proxy mode is enabled, trust only Cloudflare's published origin ranges:

```sh
sudo install -m 0755 scripts/update-cloudflare-realip.sh /usr/local/sbin/
sudo /usr/local/sbin/update-cloudflare-realip.sh
```

Uncomment the real-IP include in the relevant vhost, then validate/reload
Nginx. Re-run the script periodically with a systemd timer or configuration
management system.

## Connect the BGP frontend

After both HTTPS endpoints are operational, update `mehrnet/bgp`:

- IPv4 resolver: `https://ipv4.mehrnet.com`
- IPv6 resolver: `https://ipv6.mehrnet.com`

The browser should read the plain-text response, validate it, then request
`https://bgp-api.mehrnet.com/v1/ip?query={address}`. No API key, database change, or
deployment of `bgp-api` is involved.
