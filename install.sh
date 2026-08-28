#!/usr/bin/env bash
# Install one DNS-only, address-family-specific MehrNet IP responder.
set -Eeuo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly NGINX_SNIPPET_DIR=/etc/nginx/snippets
readonly NGINX_CONF_DIR=/etc/nginx/conf.d
readonly NGINX_SITE_DIR=/etc/nginx/sites-available
readonly NGINX_ENABLED_DIR=/etc/nginx/sites-enabled
readonly NGINX_DEFAULT_SITE="$NGINX_ENABLED_DIR/default"
readonly ACME_ROOT=/var/lib/mehrnet-ip-api/acme
readonly RENEWAL_HOOK=/etc/letsencrypt/renewal-hooks/deploy/mehrnet-ip-api-reload

family=""
email=""
bootstrap_only=0

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh --family ipv4|ipv6 [--email admin@example.com] [--bootstrap-only]

The matching DNS-only record must already point at this host:
  ipv4: one A record and no AAAA record
  ipv6: one AAAA record and no A record

--bootstrap-only installs and starts the HTTP responder without obtaining a
certificate. Re-run without that flag after DNS points at this host.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

activate_nginx() {
    systemctl enable nginx
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        systemctl start nginx
    fi
}

disable_debian_default_site() {
    # This project is a dedicated responder. Preserve Debian's stock vhost so
    # its default listener settings cannot override the responder listener.
    if [ -L "$NGINX_DEFAULT_SITE" ] && [ "$(readlink -f "$NGINX_DEFAULT_SITE")" = "$NGINX_SITE_DIR/default" ]; then
        mv "$NGINX_DEFAULT_SITE" "$NGINX_ENABLED_DIR/default.disabled-by-mehrnet-ip-api"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --family) family="${2:-}"; shift 2 ;;
        --email) email="${2:-}"; shift 2 ;;
        --bootstrap-only) bootstrap_only=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "run as root"
[ "$bootstrap_only" -eq 1 ] || [ -n "$email" ] || die "--email is required for Let's Encrypt"
case "$family" in
    ipv4) domain=ipv4.mehrnet.com; local_address=127.0.0.1 ;;
    ipv6) domain=ipv6.mehrnet.com; local_address='[::1]' ;;
    *) usage >&2; die "--family must be ipv4 or ipv6" ;;
esac

. /etc/os-release
[ "$ID" = debian ] && [ "$VERSION_ID" = 12 ] || die "this installer supports Debian 12"

site="$NGINX_SITE_DIR/$domain"
bootstrap="$ROOT_DIR/nginx/$domain.bootstrap.conf"
final="$ROOT_DIR/nginx/$domain.conf"
certificate="/etc/letsencrypt/live/$domain/fullchain.pem"

step "Installing Nginx, Certbot, and persistent zram"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates certbot curl nginx systemd-zram-generator

step "Installing direct responder configuration"
install -d -m 0755 "$NGINX_SNIPPET_DIR" "$NGINX_CONF_DIR" "$ACME_ROOT" "$(dirname "$RENEWAL_HOOK")"
disable_debian_default_site
install -m 0644 "$ROOT_DIR/nginx/http-limits.conf" "$NGINX_CONF_DIR/mehrnet-ip-api-limits.conf"
install -m 0644 "$ROOT_DIR/nginx/ip-response.conf" "$NGINX_SNIPPET_DIR/mehrnet-ip-response.conf"
install -m 0644 "$ROOT_DIR/sysctl/60-mehrnet-ip-api.conf" /etc/sysctl.d/60-mehrnet-ip-api.conf
install -m 0644 "$ROOT_DIR/zram/zram-generator.conf" /etc/systemd/zram-generator.conf
install -m 0755 "$ROOT_DIR/scripts/reload-nginx.sh" "$RENEWAL_HOOK"

step "Applying kernel and zram settings"
sysctl --load /etc/sysctl.d/60-mehrnet-ip-api.conf
systemctl daemon-reload
systemctl start /dev/zram0

if [ ! -s "$certificate" ]; then
    step "Starting the HTTP challenge vhost"
    install -m 0644 "$bootstrap" "$site"
    ln -sfn "../sites-available/$domain" "$NGINX_ENABLED_DIR/$domain"
    nginx -t
    activate_nginx

    if [ "$bootstrap_only" -eq 1 ]; then
        printf '\n%s HTTP bootstrap is active. Point the matching DNS-only record here, then rerun with --email to enable HTTPS.\n' "$domain"
        exit 0
    fi

    step "Obtaining the TLS certificate for $domain"
    certbot certonly --webroot --webroot-path "$ACME_ROOT" \
        --non-interactive --agree-tos --email "$email" --keep-until-expiring \
        --domain "$domain"
fi

step "Activating the HTTPS responder"
install -m 0644 "$final" "$site"
ln -sfn "../sites-available/$domain" "$NGINX_ENABLED_DIR/$domain"
nginx -t
activate_nginx
systemctl enable --now certbot.timer 2>/dev/null || true

step "Verifying local responder"
curl --noproxy '*' --fail --silent --show-error \
    --resolve "$domain:443:$local_address" "https://$domain/" >/dev/null
printf '\n%s is installed. Verify from a client with: curl -%sfsS https://%s\n' \
    "$domain" "$([ "$family" = ipv4 ] && printf 4 || printf 6)" "$domain"
