#!/usr/bin/env sh
set -eu

output_path="${1:-/etc/nginx/snippets/cloudflare-realip.conf}"
output_dir=$(dirname "$output_path")
mkdir -p "$output_dir"
temp_path=$(mktemp "${output_path}.XXXXXX")

cleanup() {
    rm -f "$temp_path"
}
trap cleanup EXIT INT TERM

{
    printf '%s\n' '# Generated from Cloudflare IP ranges. Do not edit by hand.'
    printf '%s\n' 'real_ip_header CF-Connecting-IP;'
    printf '%s\n' 'real_ip_recursive on;'
    curl --fail --silent --show-error https://www.cloudflare.com/ips-v4 | while IFS= read -r cidr; do
        [ -n "$cidr" ] && printf 'set_real_ip_from %s;\n' "$cidr"
    done
    curl --fail --silent --show-error https://www.cloudflare.com/ips-v6 | while IFS= read -r cidr; do
        [ -n "$cidr" ] && printf 'set_real_ip_from %s;\n' "$cidr"
    done
} > "$temp_path"

install -m 0644 "$temp_path" "$output_path"
nginx -t
systemctl reload nginx
