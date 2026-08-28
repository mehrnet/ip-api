#!/usr/bin/env bash
# Install, update, or remove a DNS-only MehrNet address-family responder.
set -Eeuo pipefail

readonly REPOSITORY="${MEHRNET_IP_API_REPOSITORY:-mehrnet/ip-api}"
readonly SOURCE_REF="${MEHRNET_IP_API_SOURCE_REF:-main}"
readonly INSTALL_DIR="${MEHRNET_IP_API_INSTALL_DIR:-/srv/mehrnet-ip-api}"
readonly INSTALLED_SCRIPT="${MEHRNET_IP_API_SCRIPT:-/usr/local/sbin/mehrnet-ip-api}"
readonly CONFIG_DIR=/etc/mehrnet-ip-api
readonly CONFIG_FILE="$CONFIG_DIR/install.conf"
readonly CRON_FILE=/etc/cron.d/mehrnet-ip-api-update
readonly NGINX_SNIPPET_DIR=/etc/nginx/snippets
readonly NGINX_CONF_DIR=/etc/nginx/conf.d
readonly NGINX_SITE_DIR=/etc/nginx/sites-available
readonly NGINX_ENABLED_DIR=/etc/nginx/sites-enabled
readonly NGINX_DEFAULT_SITE="$NGINX_ENABLED_DIR/default"
readonly ACME_ROOT=/var/lib/mehrnet-ip-api/acme
readonly RENEWAL_HOOK=/etc/letsencrypt/renewal-hooks/deploy/mehrnet-ip-api-reload

ACTION=install
family=""
email=""
bootstrap_only=false
auto_update=false

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Install, update, or remove the MehrNet direct IP responder.

Usage:
  install.sh --family ipv4|ipv6 [--email admin@example.com] [--bootstrap-only] [--auto-update]
  install.sh --update
  install.sh --uninstall

Options:
  --family NAME       One address-family responder: ipv4 or ipv6.
  --email ADDRESS     Let's Encrypt expiry-notice address. Required unless bootstrapping.
  --bootstrap-only    Serve HTTP only until the DNS-only record points to this host.
  --auto-update       Update the installed Nginx configuration every day at 05:30 UTC.
  --update            Download and apply the latest matching repository configuration.
  --uninstall         Remove MehrNet-managed Nginx, kernel, zram, renewal, and cron configuration.
  -h, --help          Show this help.

The matching DNS record must be DNS-only and address-family specific:
  ipv4.mehrnet.com: one A record and no AAAA record
  ipv6.mehrnet.com: one AAAA record and no A record
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --family)
            [ "$#" -ge 2 ] || die "--family requires ipv4 or ipv6"
            family="${2,,}"
            shift 2
            ;;
        --email)
            [ "$#" -ge 2 ] || die "--email requires an address"
            email="$2"
            shift 2
            ;;
        --bootstrap-only) bootstrap_only=true; shift ;;
        --auto-update) auto_update=true; shift ;;
        --update)
            [ "$ACTION" = install ] || die "only one operation can be selected"
            ACTION=update
            shift
            ;;
        --uninstall)
            [ "$ACTION" = install ] || die "only one operation can be selected"
            ACTION=uninstall
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "run as root"
[ "$(uname -s)" = Linux ] || die "this installer requires Linux"
. /etc/os-release
[ "$ID" = debian ] && [ "$VERSION_ID" = 12 ] || die "this installer supports Debian 12"

if [ "$ACTION" != install ] && { [ -n "$family" ] || [ -n "$email" ] || [ "$bootstrap_only" = true ] || [ "$auto_update" = true ]; }; then
    die "--$ACTION cannot be combined with installation options"
fi

case "$family" in
    ""|ipv4|ipv6) ;;
    *) die "--family must be ipv4 or ipv6" ;;
esac

github_api() {
    local -a headers=(-H 'Accept: application/vnd.github+json')
    if [ -n "${MEHRNET_IP_API_GITHUB_TOKEN:-}" ]; then
        headers+=(-H "Authorization: Bearer $MEHRNET_IP_API_GITHUB_TOKEN")
    fi
    curl --fail --location --silent --show-error --retry 3 "${headers[@]}" "https://api.github.com$1"
}

download() {
    local -a headers=()
    if [ -n "${MEHRNET_IP_API_GITHUB_TOKEN:-}" ]; then
        headers+=(-H "Authorization: Bearer $MEHRNET_IP_API_GITHUB_TOKEN")
    fi
    curl --fail --location --silent --show-error --retry 3 "${headers[@]}" --output "$2" "$1"
}

install_base_packages() {
    local missing=false command
    for command in certbot curl jq nginx systemctl; do
        command -v "$command" >/dev/null 2>&1 || missing=true
    done
    [ "$missing" = false ] && return
    step "Installing Nginx, Certbot, and persistent zram"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates certbot curl jq nginx systemd-zram-generator
}

install_cron() {
    if ! command -v cron >/dev/null 2>&1; then
        step "Installing cron for automatic updates"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cron
    fi
    cat > "$CRON_FILE" <<'EOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRON_TZ=UTC
30 5 * * * root /usr/local/sbin/mehrnet-ip-api --update
EOF
    chmod 0644 "$CRON_FILE"
    systemctl enable --now cron >/dev/null
}

activate_nginx() {
    systemctl enable nginx >/dev/null
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        systemctl start nginx
    fi
}

disable_debian_default_site() {
    if [ -L "$NGINX_DEFAULT_SITE" ] && [ "$(readlink -f "$NGINX_DEFAULT_SITE")" = "$NGINX_SITE_DIR/default" ]; then
        mv "$NGINX_DEFAULT_SITE" "$NGINX_ENABLED_DIR/default.disabled-by-mehrnet-ip-api"
    fi
}

restore_debian_default_site() {
    local disabled="$NGINX_ENABLED_DIR/default.disabled-by-mehrnet-ip-api"
    if [ -e "$disabled" ] && [ ! -e "$NGINX_DEFAULT_SITE" ]; then
        mv "$disabled" "$NGINX_DEFAULT_SITE"
    fi
}

load_configuration() {
    [ -f "$CONFIG_FILE" ] || die "no MehrNet responder installation was found"
    # Written by this root-owned script using %q below.
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    family="${FAMILY:-}"
    email="${EMAIL:-}"
    bootstrap_only="${BOOTSTRAP_ONLY:-false}"
    auto_update="${AUTO_UPDATE:-false}"
    case "$family" in
        ipv4|ipv6) ;;
        *) die "installed configuration has an invalid family" ;;
    esac
}

write_configuration() {
    install -d -m 0750 "$CONFIG_DIR"
    {
        printf 'FAMILY=%q\n' "$family"
        printf 'EMAIL=%q\n' "$email"
        printf 'BOOTSTRAP_ONLY=%q\n' "$bootstrap_only"
        printf 'AUTO_UPDATE=%q\n' "$auto_update"
    } > "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"
}

download_configuration() {
    local source_sha raw path
    source_sha="$(github_api "/repos/$REPOSITORY/commits/$SOURCE_REF" | jq -er '.sha')"
    [[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve repository source ref $SOURCE_REF"
    raw="https://raw.githubusercontent.com/$REPOSITORY/$source_sha"
    for path in \
        install.sh \
        nginx/http-limits.conf \
        nginx/ip-response.conf \
        nginx/ipv4.mehrnet.com.bootstrap.conf \
        nginx/ipv4.mehrnet.com.conf \
        nginx/ipv6.mehrnet.com.bootstrap.conf \
        nginx/ipv6.mehrnet.com.conf \
        scripts/reload-nginx.sh \
        sysctl/60-mehrnet-ip-api.conf \
        zram/zram-generator.conf; do
        install -d -m 0755 "$work_dir/$(dirname "$path")"
        download "$raw/$path" "$work_dir/$path"
    done
    printf '%s\n' "$source_sha"
}

remove_installation() {
    load_configuration
    case "$family" in
        ipv4) domain=ipv4.mehrnet.com ;;
        ipv6) domain=ipv6.mehrnet.com ;;
    esac
    step "Removing the MehrNet $family responder"
    rm -f "$NGINX_ENABLED_DIR/$domain" "$NGINX_SITE_DIR/$domain"
    rm -f "$NGINX_CONF_DIR/mehrnet-ip-api-limits.conf" "$NGINX_SNIPPET_DIR/mehrnet-ip-response.conf"
    rm -f /etc/sysctl.d/60-mehrnet-ip-api.conf /etc/systemd/zram-generator.conf "$RENEWAL_HOOK" "$CRON_FILE"
    rm -rf "$ACME_ROOT" "$INSTALL_DIR" "$CONFIG_DIR"
    rm -f "$INSTALLED_SCRIPT"
    restore_debian_default_site
    sysctl --system >/dev/null 2>&1 || true
    systemctl daemon-reload
    nginx -t
    activate_nginx
    printf '\n%s was removed. Nginx, Certbot, and any existing certificate were left installed.\n' "$domain"
}

if [ "$ACTION" = uninstall ]; then
    remove_installation
    exit 0
fi

if [ "$ACTION" = update ]; then
    load_configuration
else
    [ -n "$family" ] || die "--family is required"
    if [ "$bootstrap_only" = false ] && [ -z "$email" ]; then
        die "--email is required unless --bootstrap-only is used"
    fi
fi

case "$family" in
    ipv4) domain=ipv4.mehrnet.com; local_address=127.0.0.1 ;;
    ipv6) domain=ipv6.mehrnet.com; local_address='[::1]' ;;
esac
site="$NGINX_SITE_DIR/$domain"
certificate="/etc/letsencrypt/live/$domain/fullchain.pem"

install_base_packages
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT
step "Downloading a pinned MehrNet configuration"
source_sha="$(download_configuration)"
install -m 0755 "$work_dir/install.sh" "$INSTALLED_SCRIPT"
install -d -m 0755 "$INSTALL_DIR"
printf '%s\n' "$source_sha" > "$INSTALL_DIR/source-commit"

step "Installing direct responder configuration"
install -d -m 0755 "$NGINX_SNIPPET_DIR" "$NGINX_CONF_DIR" "$ACME_ROOT" "$(dirname "$RENEWAL_HOOK")"
disable_debian_default_site
install -m 0644 "$work_dir/nginx/http-limits.conf" "$NGINX_CONF_DIR/mehrnet-ip-api-limits.conf"
install -m 0644 "$work_dir/nginx/ip-response.conf" "$NGINX_SNIPPET_DIR/mehrnet-ip-response.conf"
install -m 0644 "$work_dir/sysctl/60-mehrnet-ip-api.conf" /etc/sysctl.d/60-mehrnet-ip-api.conf
install -m 0644 "$work_dir/zram/zram-generator.conf" /etc/systemd/zram-generator.conf
install -m 0755 "$work_dir/scripts/reload-nginx.sh" "$RENEWAL_HOOK"

step "Applying kernel and zram settings"
sysctl --load /etc/sysctl.d/60-mehrnet-ip-api.conf
systemctl daemon-reload
systemctl start /dev/zram0 2>/dev/null || true

if [ ! -s "$certificate" ]; then
    step "Starting the HTTP challenge vhost"
    install -m 0644 "$work_dir/nginx/$domain.bootstrap.conf" "$site"
    ln -sfn "../sites-available/$domain" "$NGINX_ENABLED_DIR/$domain"
    nginx -t
    activate_nginx

    if [ "$bootstrap_only" = true ]; then
        write_configuration
        if [ "$auto_update" = true ]; then install_cron; fi
        printf '\n%s HTTP bootstrap is active. Point the matching DNS-only record here, then rerun with --email to enable HTTPS.\n' "$domain"
        exit 0
    fi

    step "Obtaining the TLS certificate for $domain"
    certbot certonly --webroot --webroot-path "$ACME_ROOT" \
        --non-interactive --agree-tos --email "$email" --keep-until-expiring \
        --domain "$domain"
fi

step "Activating the HTTP and HTTPS responder"
bootstrap_only=false
install -m 0644 "$work_dir/nginx/$domain.conf" "$site"
ln -sfn "../sites-available/$domain" "$NGINX_ENABLED_DIR/$domain"
nginx -t
activate_nginx
systemctl enable --now certbot.timer 2>/dev/null || true
write_configuration
if [ "$auto_update" = true ]; then install_cron; fi

step "Verifying local responder"
curl --noproxy '*' --fail --silent --show-error \
    --resolve "$domain:443:$local_address" "https://$domain/" >/dev/null
printf '\n%s is installed from %s. Verify with: curl -%sfsS https://%s\n' \
    "$domain" "$source_sha" "$([ "$family" = ipv4 ] && printf 4 || printf 6)" "$domain"
