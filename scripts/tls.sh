#!/bin/bash

# ─────────────────────────────────────────
# Config
# ─────────────────────────────────────────

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ─────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────

print_header() {
    clear
    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════════════╗"
    echo "  ║             TLS Manager                       ║"
    echo "  ╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_section() {
    local path=$1
    local title=$2
    print_header
    echo -e "  ${YELLOW}▸ $path${NC}"
    echo -e "  ${BOLD}$title${NC}"
    echo -e "  ${CYAN}──────────────────────────────────────────────${NC}"
    echo ""
}

pause() {
    echo ""
    read -p "  Press Enter to go back..."
}

ask_input() {
    local prompt=$1
    local varname=$2
    local allow_empty=${3:-no}
    echo -ne "  ${prompt} (or 'q' to cancel): "
    read value
    if [ "$value" = "q" ]; then
        echo -e "\n  ${YELLOW}Cancelled.${NC}"
        return 1
    fi
    if [ -z "$value" ] && [ "$allow_empty" = "no" ]; then
        echo -e "\n  ${RED}Cannot be empty${NC}"
        return 1
    fi
    eval "$varname='$value'"
    return 0
}

ok() { echo -e "  ${GREEN}✓ $1${NC}"; }
fail() { echo -e "  ${RED}✗ $1${NC}"; }

# ─────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────

print_certs() {
    if ! command -v certbot &>/dev/null; then
        echo -e "  ${RED}certbot not installed${NC}"
        return
    fi

    local certs
    certs=$(certbot certificates 2>/dev/null | grep -E "Certificate Name:|Expiry Date:|Domains:")
    if [ -n "$certs" ]; then
        while IFS= read -r line; do
            if echo "$line" | grep -q "Certificate Name:"; then
                echo -e "  ${GREEN}$(echo "$line" | xargs)${NC}"
            else
                echo -e "    $(echo "$line" | xargs)"
            fi
        done <<<"$certs"
    else
        echo -e "  ${YELLOW}No certificates found${NC}"
    fi
}

get_cert_names() {
    certbot certificates 2>/dev/null | grep "Certificate Name:" | awk '{print $3}'
}

# ─────────────────────────────────────────
# 1. List certificates
# ─────────────────────────────────────────

tls_list() {
    print_section "1" "TLS › List certificates"
    print_certs
    pause
}

# ─────────────────────────────────────────
# 2. Renew certificate
# ─────────────────────────────────────────

tls_renew() {
    print_section "2" "TLS › Renew certificate"

    local certs=()
    while IFS= read -r cert; do
        certs+=("$cert")
    done < <(get_cert_names)

    if [ ${#certs[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}No certificates found${NC}"
        pause
        return
    fi

    echo -e "  ${YELLOW}Select certificate to renew:${NC}\n"
    local i=1
    for cert in "${certs[@]}"; do
        echo -e "  ${GREEN}$i.${NC} $cert"
        ((i++))
    done
    echo -e "  ${YELLOW}0.${NC} Cancel"
    echo ""
    read -p "  Choice: " choice
    [ "$choice" = "0" ] && return

    local idx=$((choice - 1))
    local target="${certs[$idx]}"
    [ -z "$target" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }

    echo ""
    certbot renew --force-renewal --cert-name "$target"
    pause
}

# ─────────────────────────────────────────
# 3. New certificate
# ─────────────────────────────────────────

tls_new() {
    print_section "3" "TLS › Generate new certificate"
    ask_input "Enter domain" DOMAIN || {
        pause
        return
    }
    echo ""
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
    pause
}

# ─────────────────────────────────────────
# 4. Delete certificate
# ─────────────────────────────────────────

tls_delete() {
    print_section "4" "TLS › Delete certificate"

    local certs=()
    while IFS= read -r cert; do
        certs+=("$cert")
    done < <(get_cert_names)

    if [ ${#certs[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}No certificates found${NC}"
        pause
        return
    fi

    echo -e "  ${YELLOW}Select certificate to delete:${NC}\n"
    local i=1
    for cert in "${certs[@]}"; do
        echo -e "  ${RED}$i.${NC} $cert"
        ((i++))
    done
    echo -e "  ${YELLOW}0.${NC} Cancel"
    echo ""
    read -p "  Choice: " choice
    [ "$choice" = "0" ] && return

    local idx=$((choice - 1))
    local target="${certs[$idx]}"
    [ -z "$target" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }

    echo ""
    read -p "  Delete certificate for '$target'? (y/n): " confirm
    [ "$confirm" != "y" ] && {
        echo -e "\n  Cancelled."
        pause
        return
    }

    certbot delete --cert-name "$target"
    pause
}

# ─────────────────────────────────────────
# Main Menu
# ─────────────────────────────────────────

while true; do
    print_header
    echo -e "  ${GREEN}1.${NC} List certificates"
    echo -e "  ${GREEN}2.${NC} Renew certificate"
    echo -e "  ${GREEN}3.${NC} Generate new certificate"
    echo -e "  ${RED}4.${NC} Delete certificate"
    echo -e "  ${YELLOW}0.${NC} Exit"
    echo ""
    read -p "  Choice: " choice
    case $choice in
    1) tls_list ;;
    2) tls_renew ;;
    3) tls_new ;;
    4) tls_delete ;;
    0) echo "" && exit 0 ;;
    *) echo -e "${RED}Invalid choice${NC}" && sleep 1 ;;
    esac
done
