#!/usr/bin/env bash
# =============================================================================
# setup_custom_tls.sh - Configure custom TLS certificates for Caddy
# =============================================================================
# Updates caddy-addon/tls-snippet.conf to use corporate/internal certificates
# instead of Let's Encrypt, generates a self-signed certificate, or enables plain HTTP (--http-only).
#
# Usage:
#   bash scripts/setup_custom_tls.sh                          # Interactive (files in ./certs/)
#   bash scripts/setup_custom_tls.sh cert.crt key.key       # Files in ./certs/ (basename)
#   bash scripts/setup_custom_tls.sh /path/to.crt /path/to.key   # Any paths (copied into ./certs/)
#   bash scripts/setup_custom_tls.sh --generate-self-signed # SANs from .env *_HOSTNAME + localhost
#   bash scripts/setup_custom_tls.sh --generate-self-signed --days 3650 --san "DNS:extra.local,IP:10.0.0.5"
#   bash scripts/setup_custom_tls.sh --remove               # Reset to Let's Encrypt
#   bash scripts/setup_custom_tls.sh --http-only           # Plain HTTP (CADDY_HTTP_PREFIX + auto_https off)
#   bash scripts/setup_custom_tls.sh --remove -y            # Same, restart Caddy without prompt
#
# Flags:
#   -y, --yes          Restart Caddy without confirmation (if running)
#   -n, --no-restart   Do not restart Caddy
#   --days N           Validity for --generate-self-signed (default: 825)
#   --san LIST         Extra subjectAltName entries (comma-separated, e.g. DNS:a,IP:1.2.3.4)
#
# Prerequisites for custom paths:
#   - Files are copied into ./certs/ so the Caddy volume mount can read them.
# =============================================================================

set -euo pipefail

source "$(dirname "$0")/utils.sh" && init_paths

SNIPPET_FILE="$PROJECT_ROOT/caddy-addon/tls-snippet.conf"
SNIPPET_EXAMPLE="$PROJECT_ROOT/caddy-addon/tls-snippet.conf.example"
GLOBAL_AUTO_HTTPS_FILE="$PROJECT_ROOT/caddy-addon/global-auto-https.conf"
GLOBAL_AUTO_HTTPS_EXAMPLE="$PROJECT_ROOT/caddy-addon/global-auto-https.conf.example"
WELCOME_ROUTING_FILE="$PROJECT_ROOT/caddy-addon/welcome-routing.conf"
WELCOME_ROUTING_EXAMPLE="$PROJECT_ROOT/caddy-addon/welcome-routing.conf.example"
CERTS_DIR="$PROJECT_ROOT/certs"
CADDYFILE_PATH="$PROJECT_ROOT/Caddyfile"
SELF_SIGNED_CERT_BASENAME="local-selfsigned.crt"
SELF_SIGNED_KEY_BASENAME="local-selfsigned.key"

# Legacy file that causes duplicate host errors (must be cleaned up on migration)
# TODO: Remove OLD_CONFIG and cleanup_legacy_config() after v3.0 release (all users migrated)
OLD_CONFIG="$PROJECT_ROOT/caddy-addon/custom-tls.conf"

AUTO_YES=0
NO_RESTART=0
SELF_SIGNED_DAYS=825
EXTRA_SANS=""
# Populated by parse_options(); caller runs: set -- "${REMAINING[@]}"
REMAINING=()

# =============================================================================
# FUNCTIONS
# =============================================================================

cleanup_legacy_config() {
    if [[ -f "$OLD_CONFIG" ]]; then
        log_warning "Removing obsolete custom-tls.conf (causes duplicate host errors)"
        rm -f "$OLD_CONFIG"
    fi
}

show_help() {
    cat << EOF
Setup Custom TLS Certificates for Caddy

Usage: $(basename "$0") [OPTIONS] [CERT_FILE] [KEY_FILE]

Options:
  -h, --help              Show this help message
  -y, --yes               Restart Caddy without confirmation (when running)
  -n, --no-restart        Do not restart Caddy after configuration changes
  --remove                Reset to Let's Encrypt automatic certificates
  --http-only             Plain HTTP for Caddy (empty tls snippet, auto_https off, welcome HTTP-only). Set CADDY_TLS_MODE=http and CADDY_HTTP_PREFIX=http:// in .env.
  --generate-self-signed  Create a self-signed certificate (SANs from .env + localhost)
  --days N                Validity period in days for self-signed (default: $SELF_SIGNED_DAYS)
  --san LIST              Extra subjectAltName entries (comma-separated)

Arguments (optional, instead of --generate-self-signed / --remove / --http-only):
  CERT_FILE, KEY_FILE     Either basenames under ./certs/ or absolute/relative paths to files.
                          External paths are copied into ./certs/ for the Caddy bind mount.

Examples:
  $(basename "$0")
  $(basename "$0") wildcard.crt wildcard.key
  $(basename "$0") ~/company/fullchain.pem ~/company/privkey.pem
  $(basename "$0") --generate-self-signed
  $(basename "$0") --generate-self-signed --san "DNS:mybox.lan,IP:192.168.1.10"
  $(basename "$0") --remove
  $(basename "$0") --remove -y
  $(basename "$0") --http-only --no-restart

Local HTTPS:
  1. Set *_HOSTNAME in .env to hostnames you will use (e.g. n8n.local.test).
  2. Add those names to /etc/hosts pointing at this machine (or use real DNS).
  3. Run: $(basename "$0") --generate-self-signed
  4. Trust the certificate in the browser/OS if needed (self-signed warning).

EOF
}

find_certificates() {
    local certs=()
    if [[ -d "$CERTS_DIR" ]]; then
        while IFS= read -r -d '' file; do
            certs+=("$(basename "$file")")
        done < <(find "$CERTS_DIR" -maxdepth 1 -type f \( -name "*.crt" -o -name "*.pem" -o -name "*.cer" \) -print0 2>/dev/null)
    fi
    echo "${certs[*]:-}"
}

find_keys() {
    local keys=()
    if [[ -d "$CERTS_DIR" ]]; then
        while IFS= read -r -d '' file; do
            keys+=("$(basename "$file")")
        done < <(find "$CERTS_DIR" -maxdepth 1 -type f \( -name "*.key" -o -name "*-key.pem" \) -print0 2>/dev/null)
    fi
    echo "${keys[*]:-}"
}

ensure_snippet_exists() {
    if [[ ! -f "$SNIPPET_FILE" ]]; then
        if [[ -f "$SNIPPET_EXAMPLE" ]]; then
            cp "$SNIPPET_EXAMPLE" "$SNIPPET_FILE"
            log_info "Created tls-snippet.conf from template"
        else
            remove_config
        fi
    fi
    ensure_global_auto_https_exists
    ensure_welcome_routing_exists
}

ensure_global_auto_https_exists() {
    if [[ ! -f "$GLOBAL_AUTO_HTTPS_FILE" ]] && [[ -f "$GLOBAL_AUTO_HTTPS_EXAMPLE" ]]; then
        cp "$GLOBAL_AUTO_HTTPS_EXAMPLE" "$GLOBAL_AUTO_HTTPS_FILE"
        log_info "Created global-auto-https.conf from template"
    fi
}

copy_welcome_routing_from_example() {
    if [[ -f "$WELCOME_ROUTING_EXAMPLE" ]]; then
        cp "$WELCOME_ROUTING_EXAMPLE" "$WELCOME_ROUTING_FILE"
        log_info "Restored welcome-routing.conf from template (HTTP + HTTPS welcome)"
    fi
}

ensure_welcome_routing_exists() {
    if [[ ! -f "$WELCOME_ROUTING_FILE" ]] && [[ -f "$WELCOME_ROUTING_EXAMPLE" ]]; then
        cp "$WELCOME_ROUTING_EXAMPLE" "$WELCOME_ROUTING_FILE"
        log_info "Created welcome-routing.conf from template"
    fi
}

# Caddy 2.10+: if a site uses tls cert.pem key.pem but the cert SAN does not match the site name,
# Caddy may try ACME for that name. For a single PEM shared across all vhosts, disable cert automation globally.
write_global_auto_https_file_tls() {
    mkdir -p "$(dirname "$GLOBAL_AUTO_HTTPS_FILE")"
    cat > "$GLOBAL_AUTO_HTTPS_FILE" << 'EOF'
# File-based TLS (setup_custom_tls.sh): do not obtain certificates via ACME
auto_https disable_certs
EOF
}

write_global_auto_https_lets_encrypt() {
    mkdir -p "$(dirname "$GLOBAL_AUTO_HTTPS_FILE")"
    cat > "$GLOBAL_AUTO_HTTPS_FILE" << 'EOF'
# Let's Encrypt / default automatic HTTPS (ACME enabled)
EOF
}

write_global_auto_https_http_only() {
    mkdir -p "$(dirname "$GLOBAL_AUTO_HTTPS_FILE")"
    cat > "$GLOBAL_AUTO_HTTPS_FILE" << 'EOF'
# Plain HTTP mode (CADDY_TLS_MODE=http): no automatic TLS or HTTP→HTTPS redirects
auto_https off
EOF
}

write_welcome_routing_http_only() {
    mkdir -p "$(dirname "$WELCOME_ROUTING_FILE")"
    cat > "$WELCOME_ROUTING_FILE" << 'EOF'
# HTTP-only stack: single welcome site (no duplicate http:// block)
http://{$WELCOME_HOSTNAME} {
    basic_auth {
        {$WELCOME_USERNAME} {$WELCOME_PASSWORD_HASH}
    }
    root * /srv/welcome
    file_server
    try_files {path} /index.html
}
EOF
}

write_http_only_mode() {
    cleanup_legacy_config
    ensure_snippet_exists
    ensure_welcome_routing_exists

    cat > "$SNIPPET_FILE" << 'EOF'
# TLS snippet empty — sites use http:// addresses (CADDY_HTTP_PREFIX in Caddyfile)
(service_tls) {
}
EOF

    write_global_auto_https_http_only
    write_welcome_routing_http_only
    log_success "Caddy configured for plain HTTP (tls snippet empty, auto_https off, welcome HTTP-only)"
}

generate_config() {
    local cert_file="$1"
    local key_file="$2"

    cat > "$SNIPPET_FILE" << EOF
# TLS Configuration Snippet
# Generated by setup_custom_tls.sh on $(date -Iseconds)
# Using custom certificates instead of Let's Encrypt.
# Reset to Let's Encrypt: make setup-tls ARGS=--remove

(service_tls) {
    tls /etc/caddy/certs/$cert_file /etc/caddy/certs/$key_file
}
EOF

    write_global_auto_https_file_tls
    copy_welcome_routing_from_example
    log_success "Generated $SNIPPET_FILE and $GLOBAL_AUTO_HTTPS_FILE (auto_https disable_certs)"
}

remove_config() {
    cat > "$SNIPPET_FILE" << 'EOF'
# TLS Configuration Snippet
# Imported by all service blocks in the main Caddyfile.
#
# Default: Empty (uses Let's Encrypt automatic certificates)
# Custom: Overwritten by 'make setup-tls' with your certificate paths
# Reset: Run make setup-tls ARGS=--remove to restore Let's Encrypt

(service_tls) {
    # Default: Let's Encrypt automatic certificates (empty = no override)
}
EOF

    write_global_auto_https_lets_encrypt
    copy_welcome_routing_from_example
    log_success "Reset to Let's Encrypt (automatic certificates)"
}

# Resolve user-supplied cert/key to (basename_in_certs, basename_in_certs) after optional copy
resolve_cert_key_paths() {
    local cert_in="$1"
    local key_in="$2"
    local cert_path=""
    local key_path=""

    if [[ -f "$cert_in" ]]; then
        cert_path="$(cd "$(dirname "$cert_in")" && pwd)/$(basename "$cert_in")"
    elif [[ -f "$CERTS_DIR/$cert_in" ]]; then
        cert_path="$CERTS_DIR/$cert_in"
    else
        log_error "Certificate not found: $cert_in (also tried $CERTS_DIR/$cert_in)"
        exit 1
    fi

    if [[ -f "$key_in" ]]; then
        key_path="$(cd "$(dirname "$key_in")" && pwd)/$(basename "$key_in")"
    elif [[ -f "$CERTS_DIR/$key_in" ]]; then
        key_path="$CERTS_DIR/$key_in"
    else
        log_error "Key not found: $key_in (also tried $CERTS_DIR/$key_in)"
        exit 1
    fi

    mkdir -p "$CERTS_DIR"
    local cert_out_base key_out_base
    cert_out_base="$(basename "$cert_path")"
    key_out_base="$(basename "$key_path")"

    # Normalize into certs/ so Caddy volume sees them
    if [[ "$cert_path" != "$CERTS_DIR/$cert_out_base" ]]; then
        cert_out_base="imported-$(basename "$cert_path")"
        cp -f "$cert_path" "$CERTS_DIR/$cert_out_base"
        log_info "Copied certificate to $CERTS_DIR/$cert_out_base"
    fi
    if [[ "$key_path" != "$CERTS_DIR/$key_out_base" ]]; then
        key_out_base="imported-$(basename "$key_path")"
        cp -f "$key_path" "$CERTS_DIR/$key_out_base"
        log_info "Copied private key to $CERTS_DIR/$key_out_base"
    fi

    printf '%s\n%s\n' "$cert_out_base" "$key_out_base"
}

set_cert_permissions() {
    local cert_base="$1"
    local key_base="$2"
    chmod 644 "$CERTS_DIR/$cert_base" 2>/dev/null || true
    chmod 600 "$CERTS_DIR/$key_base" 2>/dev/null || true
}

maybe_restart_caddy() {
    if [[ "$NO_RESTART" == 1 ]]; then
        log_info "Skipped Caddy restart (--no-restart)."
        return
    fi

    if ! docker info >/dev/null 2>&1; then
        log_info "Docker not available; skipped Caddy restart."
        return
    fi

    if ! (cd "$PROJECT_ROOT" && docker compose -p localai ps -q caddy 2>/dev/null | grep -q .); then
        log_info "Caddy container is not running; skipped restart."
        return
    fi

    if [[ "$AUTO_YES" == 1 ]]; then
        log_info "Restarting Caddy..."
        (cd "$PROJECT_ROOT" && docker compose -p localai restart caddy)
        log_success "Caddy restarted"
        return
    fi

    if [[ -t 0 ]] && command -v whiptail >/dev/null 2>&1; then
        if wt_yesno "Restart Caddy" "Do you want to restart Caddy to apply the new configuration?" "yes"; then
            log_info "Restarting Caddy..."
            (cd "$PROJECT_ROOT" && docker compose -p localai restart caddy)
            log_success "Caddy restarted"
        else
            log_info "Skipped Caddy restart. Run manually: docker compose -p localai restart caddy"
        fi
    else
        log_info "Non-interactive: skipped Caddy restart. Run: cd $PROJECT_ROOT && docker compose -p localai restart caddy"
    fi
}

# Collect subjectAltName entries (OpenSSL comma-separated), deduplicated
build_subject_alt_name() {
    declare -A seen=()
    local out=()

    add_entry() {
        local e="${1:-}"
        e="${e//$'\r'/}"
        e="${e#"${e%%[![:space:]]*}"}"
        e="${e%"${e##*[![:space:]]}"}"
        [[ -n "$e" ]] || return
        [[ ${seen[$e]+_} ]] && return
        seen[$e]=1
        out+=("$e")
    }

    add_entry "DNS:localhost"
    add_entry "IP:127.0.0.1"

    if [[ -f "$ENV_FILE" ]]; then
        local ud
        ud="$(read_env_var "USER_DOMAIN_NAME" "$ENV_FILE" || true)"
        ud="${ud//$'\r'/}"
        if [[ -n "$ud" && "$ud" != "$DOMAIN_PLACEHOLDER" ]]; then
            add_entry "DNS:${ud}"
            add_entry "DNS:*.${ud}"
        fi

        local line val
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[A-Za-z][A-Za-z0-9_]*_HOSTNAME= ]] || continue
            val="${line#*=}"
            val="${val//$'\r'/}"
            val="${val#\"}"; val="${val%\"}"
            val="${val#\'}"; val="${val%\'}"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"
            [[ -n "$val" ]] || continue
            add_entry "DNS:${val}"
        done < <(grep -E '^[A-Za-z][A-Za-z0-9_]*_HOSTNAME=' "$ENV_FILE" 2>/dev/null || true)
    fi

    # Every {$VAR} site address in Caddyfile (must match certificate SAN or Caddy falls back to ACME)
    if [[ -f "$CADDYFILE_PATH" ]] && [[ -f "$ENV_FILE" ]]; then
        local vname vval
        while IFS= read -r vname || [[ -n "$vname" ]]; do
            [[ "$vname" =~ _HOSTNAME$ ]] || continue
            vval="$(read_env_var "$vname" "$ENV_FILE" 2>/dev/null || true)"
            vval="${vval//$'\r'/}"
            vval="${vval#\"}"; vval="${vval%\"}"
            vval="${vval#\'}"; vval="${vval%\'}"
            vval="${vval#"${vval%%[![:space:]]*}"}"
            vval="${vval%"${vval##*[![:space:]]}"}"
            [[ -n "$vval" ]] || continue
            add_entry "DNS:${vval}"
        done < <(grep -oE '\{\$[A-Za-z0-9_]+\}' "$CADDYFILE_PATH" 2>/dev/null | sed 's/{\$\([^}]*\)}/\1/' | sort -u)
    fi

    if [[ -n "$EXTRA_SANS" ]]; then
        local IFS_save=$IFS
        IFS=',' read -ra extra_parts <<< "$EXTRA_SANS"
        for part in "${extra_parts[@]}"; do
            add_entry "$part"
        done
        IFS=$IFS_save
    fi

    (IFS=','; echo "${out[*]}")
}

cmd_generate_self_signed() {
    require_command openssl "Install OpenSSL (openssl package)."

    if ! [[ "$SELF_SIGNED_DAYS" =~ ^[0-9]+$ ]] || [[ "$SELF_SIGNED_DAYS" -lt 1 ]]; then
        log_error "--days must be a positive integer"
        exit 1
    fi

    cleanup_legacy_config
    ensure_snippet_exists
    mkdir -p "$CERTS_DIR"

    if [[ ! -f "$ENV_FILE" ]]; then
        log_warning "No .env at $ENV_FILE — certificate will only include localhost/127.0.0.1. Create .env from .env.example (with *_HOSTNAME) then re-run, or use --san."
    fi

    local san_line
    san_line="$(build_subject_alt_name)"
    if [[ -z "$san_line" ]]; then
        san_line="DNS:localhost,IP:127.0.0.1"
    fi

    local tmp_cnf
    tmp_cnf="$(mktemp)"
    trap 'rm -f "$tmp_cnf"' RETURN

    cat > "$tmp_cnf" << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
O = n8n-install local
CN = localhost

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $san_line
EOF

    local cert_path="$CERTS_DIR/$SELF_SIGNED_CERT_BASENAME"
    local key_path="$CERTS_DIR/$SELF_SIGNED_KEY_BASENAME"

    log_info "Generating self-signed certificate (${SELF_SIGNED_DAYS} days)..."
    log_info "subjectAltName: $san_line"

    openssl req -newkey rsa:4096 -nodes \
        -keyout "$key_path" \
        -x509 -days "$SELF_SIGNED_DAYS" \
        -out "$cert_path" \
        -config "$tmp_cnf" \
        -extensions v3_req

    set_cert_permissions "$SELF_SIGNED_CERT_BASENAME" "$SELF_SIGNED_KEY_BASENAME"
    generate_config "$SELF_SIGNED_CERT_BASENAME" "$SELF_SIGNED_KEY_BASENAME"

    echo ""
    log_success "Self-signed TLS is configured: $cert_path"
    log_info "Leave LETSENCRYPT_EMAIL empty for local installs; Caddy uses the files above via tls-snippet.conf."
    echo ""
    maybe_restart_caddy
}

parse_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -y|--yes)
                AUTO_YES=1
                shift
                ;;
            -n|--no-restart)
                NO_RESTART=1
                shift
                ;;
            --days)
                if [[ -z "${2:-}" ]]; then
                    log_error "--days requires a numeric argument"
                    exit 1
                fi
                SELF_SIGNED_DAYS="$2"
                shift 2
                ;;
            --san)
                if [[ -z "${2:-}" ]]; then
                    log_error "--san requires a comma-separated list"
                    exit 1
                fi
                EXTRA_SANS="$2"
                shift 2
                ;;
            --remove|--generate-self-signed|--http-only)
                break
                ;;
            -*)
                log_error "Unknown option: $1"
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done
    REMAINING=("$@")
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    parse_options "$@"
    set -- "${REMAINING[@]}"

    case "${1:-}" in
        --remove)
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -y|--yes)
                        AUTO_YES=1
                        shift
                        ;;
                    -n|--no-restart)
                        NO_RESTART=1
                        shift
                        ;;
                    *)
                        log_error "Unexpected argument after --remove: $1"
                        exit 1
                        ;;
                esac
            done
            cleanup_legacy_config
            remove_config
            maybe_restart_caddy
            exit 0
            ;;
        --http-only)
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -y|--yes)
                        AUTO_YES=1
                        shift
                        ;;
                    -n|--no-restart)
                        NO_RESTART=1
                        shift
                        ;;
                    *)
                        log_error "Unexpected argument after --http-only: $1"
                        exit 1
                        ;;
                esac
            done
            write_http_only_mode
            maybe_restart_caddy
            exit 0
            ;;
        --generate-self-signed)
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --days)
                        if [[ -z "${2:-}" ]]; then
                            log_error "--days requires a numeric argument"
                            exit 1
                        fi
                        SELF_SIGNED_DAYS="$2"
                        shift 2
                        ;;
                    --san)
                        if [[ -z "${2:-}" ]]; then
                            log_error "--san requires a comma-separated list"
                            exit 1
                        fi
                        EXTRA_SANS="$2"
                        shift 2
                        ;;
                    -y|--yes)
                        AUTO_YES=1
                        shift
                        ;;
                    -n|--no-restart)
                        NO_RESTART=1
                        shift
                        ;;
                    *)
                        log_error "Unexpected argument after --generate-self-signed: $1"
                        exit 1
                        ;;
                esac
            done
            cmd_generate_self_signed
            exit 0
            ;;
    esac

    cleanup_legacy_config
    ensure_snippet_exists
    mkdir -p "$CERTS_DIR"

    local cert_file="" key_file="" resolved

    if [[ $# -ge 2 ]]; then
        local _pair=()
        mapfile -t _pair < <(resolve_cert_key_paths "$1" "$2")
        cert_file="${_pair[0]:-}"
        key_file="${_pair[1]:-}"
        if [[ -z "$cert_file" || -z "$key_file" ]]; then
            log_error "Could not resolve certificate paths."
            exit 1
        fi
        shift 2
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -y|--yes)
                    AUTO_YES=1
                    shift
                    ;;
                -n|--no-restart)
                    NO_RESTART=1
                    shift
                    ;;
                *)
                    log_error "Unexpected argument after certificate paths: $1"
                    exit 1
                    ;;
            esac
        done
        set_cert_permissions "$cert_file" "$key_file"
    elif [[ $# -eq 1 ]]; then
        log_error "Provide both certificate and key paths (two arguments)."
        exit 1
    else
        require_whiptail

        local certs_arr
        IFS=' ' read -ra certs_arr <<< "$(find_certificates)"

        if [[ ${#certs_arr[@]} -eq 0 ]]; then
            wt_msg "No Certificates Found" "No certificate files found in ./certs/\n\nPlace .crt/.pem/.cer and .key files in ./certs/, or run:\n  bash scripts/setup_custom_tls.sh --generate-self-signed\nor pass explicit paths:\n  bash scripts/setup_custom_tls.sh /path/to.crt /path/to.key"
            exit 1
        fi

        local cert_items=()
        for cert in "${certs_arr[@]}"; do
            cert_items+=("$cert" "")
        done

        cert_file=$(wt_menu "Select Certificate" "Choose your TLS certificate file:" "${cert_items[@]}")
        [[ -z "$cert_file" ]] && exit 1

        local keys_arr
        IFS=' ' read -ra keys_arr <<< "$(find_keys)"

        if [[ ${#keys_arr[@]} -eq 0 ]]; then
            wt_msg "No Keys Found" "No key files found in ./certs/\n\nPlace a .key file in ./certs/."
            exit 1
        fi

        local key_items=()
        for key in "${keys_arr[@]}"; do
            key_items+=("$key" "")
        done

        key_file=$(wt_menu "Select Private Key" "Choose your TLS private key file:" "${key_items[@]}")
        [[ -z "$key_file" ]] && exit 1

        set_cert_permissions "$cert_file" "$key_file"
    fi

    log_info "Using certificate: $cert_file"
    log_info "Using key: $key_file"

    generate_config "$cert_file" "$key_file"

    echo ""
    log_info "Custom TLS configured successfully!"
    log_info "All services will use: /etc/caddy/certs/$cert_file"
    echo ""

    maybe_restart_caddy
}

main "$@"
