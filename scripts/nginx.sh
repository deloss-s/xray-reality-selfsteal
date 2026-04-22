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
    echo "  ║             Nginx Manager                     ║"
    echo "  ╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
    if systemctl is-active --quiet nginx; then
        echo -e "  Status: ${GREEN}● running${NC}"
    else
        echo -e "  Status: ${RED}● stopped${NC}"
    fi
    echo ""
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

detect_distro() {
    if [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/fedora-release ]; then
        echo "fedora"
    else
        echo "unknown"
    fi
}

get_config_dir() {
    local distro=$(detect_distro)
    if [ "$distro" = "debian" ]; then
        echo "/etc/nginx/sites-available"
    else
        echo "/etc/nginx/conf.d"
    fi
}

get_configs() {
    local dir=$(get_config_dir)
    local distro=$(detect_distro)
    local configs=()
    if [ "$distro" = "debian" ]; then
        for f in "$dir"/*.conf "$dir"/fake; do
            [ -f "$f" ] && configs+=("$f")
        done
    else
        for f in "$dir"/*.conf; do
            [ -f "$f" ] && configs+=("$f")
        done
    fi
    printf '%s\n' "${configs[@]}"
}

is_enabled() {
    local f=$1
    local base=$(basename "$f")
    local distro=$(detect_distro)
    [ "$distro" = "debian" ] && [ -L "/etc/nginx/sites-enabled/$base" ] && return 0
    return 1
}

# ─────────────────────────────────────────
# 1. Control
# ─────────────────────────────────────────

nginx_start() {
    print_section "1.1" "Control › Start"
    systemctl start nginx && sleep 1
    if systemctl is-active --quiet nginx; then
        ok "Nginx started successfully"
    else
        fail "Failed to start Nginx"
        echo ""
        journalctl -u nginx -n 10 --no-pager
    fi
    pause
}

nginx_stop() {
    print_section "1.2" "Control › Stop"
    systemctl stop nginx && sleep 1
    if ! systemctl is-active --quiet nginx; then
        ok "Nginx stopped"
    else
        fail "Failed to stop Nginx"
    fi
    pause
}

nginx_restart() {
    print_section "1.3" "Control › Restart"
    systemctl restart nginx && sleep 1
    if systemctl is-active --quiet nginx; then
        ok "Nginx restarted successfully"
    else
        fail "Restart failed"
        echo ""
        journalctl -u nginx -n 10 --no-pager
    fi
    pause
}

menu_control() {
    while true; do
        print_section "1" "Control"
        echo -e "  ${GREEN}1.${NC} Start"
        echo -e "  ${GREEN}2.${NC} Stop"
        echo -e "  ${GREEN}3.${NC} Restart"
        echo -e "  ${YELLOW}0.${NC} Back"
        echo ""
        read -p "  Choice: " c
        case $c in
        1) nginx_start ;;
        2) nginx_stop ;;
        3) nginx_restart ;;
        0) return ;;
        *) echo -e "${RED}Invalid${NC}" && sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────
# 2. Configs
# ─────────────────────────────────────────

nginx_list_configs() {
    print_section "2.1" "Configs › List"
    local distro=$(detect_distro)
    local dir=$(get_config_dir)
    echo -e "  ${YELLOW}Config dir: $dir${NC}\n"

    local found=0
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local base=$(basename "$f")
        local enabled=""
        [ "$distro" = "debian" ] && is_enabled "$f" && enabled=" ${GREEN}[enabled]${NC}"
        echo -e "  ${GREEN}•${NC} $base$enabled"
        found=1
    done < <(get_configs)

    [ $found -eq 0 ] && echo -e "  ${YELLOW}No configs found${NC}"
    pause
}

nginx_edit_config() {
    print_section "2.2" "Configs › Edit config"

    local configs=()
    while IFS= read -r f; do
        [ -n "$f" ] && configs+=("$f")
    done < <(get_configs)

    if [ ${#configs[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}No configs found${NC}"
        pause
        return
    fi

    local distro=$(detect_distro)
    local i=1
    for f in "${configs[@]}"; do
        local base=$(basename "$f")
        local enabled=""
        [ "$distro" = "debian" ] && is_enabled "$f" && enabled=" ${GREEN}[enabled]${NC}"
        echo -e "  ${GREEN}$i.${NC} $base$enabled"
        ((i++))
    done

    echo -e "  ${YELLOW}0.${NC} Cancel"
    echo ""
    read -p "  Select config to edit: " choice
    [ "$choice" = "0" ] && return

    local idx=$((choice - 1))
    local target="${configs[$idx]}"
    [ -z "$target" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }

    # Open in nvim, script waits until nvim exits
    nvim "$target"

    echo ""
    read -p "  Run nginx -t to verify? (y/n): " verify
    if [ "$verify" = "y" ]; then
        nginx -t
        echo ""
        read -p "  Restart Nginx now? (y/n): " restart
        [ "$restart" = "y" ] && systemctl restart nginx && sleep 1 && ok "Nginx restarted"
    fi
    pause
}

nginx_create_config() {
    print_section "2.3" "Configs › Create new config"
    local distro=$(detect_distro)

    ask_input "Enter domain" DOMAIN || {
        pause
        return
    }
    ask_input "Enter local port" PORT || {
        pause
        return
    }

    local CONF_CONTENT="# $DOMAIN
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    client_max_body_size 10G;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;

        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \"upgrade\";

        proxy_buffering off;
    }
}"

    local conf_path
    if [ "$distro" = "debian" ]; then
        conf_path="/etc/nginx/sites-available/$DOMAIN.conf"
        echo "$CONF_CONTENT" >"$conf_path"
        ln -sf "$conf_path" "/etc/nginx/sites-enabled/$DOMAIN.conf"
        ok "Config saved to $conf_path"
        ok "Symlink created in sites-enabled"
    else
        conf_path="/etc/nginx/conf.d/$DOMAIN.conf"
        echo "$CONF_CONTENT" >"$conf_path"
        ok "Config saved to $conf_path"
    fi

    echo ""
    read -p "  Open in nvim to review/edit? (y/n): " edit
    [ "$edit" = "y" ] && nvim "$conf_path"

    echo ""
    read -p "  Run nginx -t to verify? (y/n): " verify
    if [ "$verify" = "y" ]; then
        nginx -t
        echo ""
        read -p "  Restart Nginx now? (y/n): " restart
        [ "$restart" = "y" ] && systemctl restart nginx && sleep 1 && ok "Nginx restarted"
    fi
    pause
}

nginx_delete_config() {
    print_section "2.4" "Configs › Delete config"
    local distro=$(detect_distro)

    local configs=()
    while IFS= read -r f; do
        [ -n "$f" ] && configs+=("$f")
    done < <(get_configs)

    if [ ${#configs[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}No configs found${NC}"
        pause
        return
    fi

    local i=1
    for f in "${configs[@]}"; do
        local base=$(basename "$f")
        local enabled=""
        [ "$distro" = "debian" ] && is_enabled "$f" && enabled=" ${GREEN}[enabled]${NC}"
        echo -e "  ${RED}$i.${NC} $base$enabled"
        ((i++))
    done

    echo -e "  ${YELLOW}0.${NC} Cancel"
    echo ""
    read -p "  Select config to delete: " choice
    [ "$choice" = "0" ] && return

    local idx=$((choice - 1))
    local target="${configs[$idx]}"
    [ -z "$target" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }

    echo ""
    read -p "  Delete '$(basename $target)'? (y/n): " confirm
    [ "$confirm" != "y" ] && {
        echo -e "\n  Cancelled."
        pause
        return
    }

    if [ "$distro" = "debian" ]; then
        local base=$(basename "$target")
        rm -f "$target" "/etc/nginx/sites-enabled/$base"
        ok "Removed from sites-available and sites-enabled"
    else
        rm -f "$target"
        ok "Removed from conf.d"
    fi

    echo -e "  ${YELLOW}Restart Nginx (3) to apply${NC}"
    pause
}

menu_configs() {
    while true; do
        print_section "2" "Configs"
        echo -e "  ${GREEN}1.${NC} List configs"
        echo -e "  ${GREEN}2.${NC} Edit config"
        echo -e "  ${GREEN}3.${NC} Create new config"
        echo -e "  ${RED}4.${NC} Delete config"
        echo -e "  ${YELLOW}0.${NC} Back"
        echo ""
        read -p "  Choice: " c
        case $c in
        1) nginx_list_configs ;;
        2) nginx_edit_config ;;
        3) nginx_create_config ;;
        4) nginx_delete_config ;;
        0) return ;;
        *) echo -e "${RED}Invalid${NC}" && sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────
# 3. Test & Restart
# ─────────────────────────────────────────

nginx_test_restart() {
    print_section "3" "Test & Restart"
    echo -e "  ${YELLOW}Running nginx -t...${NC}\n"
    nginx -t
    local result=$?
    echo ""
    if [ $result -eq 0 ]; then
        ok "Config test passed"
        echo ""
        read -p "  Restart Nginx now? (y/n): " confirm
        if [ "$confirm" = "y" ]; then
            systemctl restart nginx && sleep 1
            systemctl is-active --quiet nginx && ok "Nginx restarted" || fail "Restart failed"
        fi
    else
        fail "Config test failed — fix errors before restarting"
    fi
    pause
}

# ─────────────────────────────────────────
# Main Menu
# ─────────────────────────────────────────

while true; do
    print_header
    echo -e "  ${CYAN}1.${NC} Control"
    echo -e "  ${CYAN}2.${NC} Configs"
    echo -e "  ${CYAN}3.${NC} Test & Restart"
    echo -e "  ${YELLOW}0.${NC} Exit"
    echo ""
    read -p "  Choice: " choice
    case $choice in
    1) menu_control ;;
    2) menu_configs ;;
    3) nginx_test_restart ;;
    0) echo "" && exit 0 ;;
    *) echo -e "${RED}Invalid choice${NC}" && sleep 1 ;;
    esac
done
