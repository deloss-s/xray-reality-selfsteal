#!/bin/bash

# ─────────────────────────────────────────
# Config
# ─────────────────────────────────────────
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BACKUP="/usr/local/etc/xray/config-bckp.json"
NGINX_WEB_CONF="/etc/nginx/sites-available/fake"
NGINX_WEB_ENABLED="/etc/nginx/sites-enabled/fake"
WEB_ROOT="/var/www/fake"

# Токен читается из файловой системы — имя папки внутри $WEB_ROOT/sub/
# При Autodeploy генерируется заново, после — берётся автоматически
_load_sub_token() {
    local sub_base="$WEB_ROOT/sub"
    if [ -d "$sub_base" ]; then
        local token
        token=$(find "$sub_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 | xargs basename 2>/dev/null)
        if [ -n "$token" ]; then
            SUB_TOKEN="$token"
            SUB_ROOT="$sub_base/$token"
            return 0
        fi
    fi
    SUB_TOKEN=""
    SUB_ROOT=""
    return 1
}
_load_sub_token

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
    clear
    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════════════╗"
    echo "  ║             Xray Manager                      ║"
    echo "  ╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
    if systemctl is-active --quiet xray; then
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
step() { echo -e "\n  ${CYAN}▶ $1${NC}"; }
warn() { echo -e "  ${YELLOW}! $1${NC}"; }

xray_get_users() {
    python3 -c "
import json
with open('$XRAY_CONFIG') as f:
    config = json.load(f)
for c in config['inbounds'][0]['settings']['clients']:
    print(c.get('id','') + '|' + c.get('name','(no name)'))
"
}

xray_get_private_key() {
    python3 -c "
import json
with open('$XRAY_CONFIG') as f:
    config = json.load(f)
print(config['inbounds'][0]['streamSettings']['realitySettings']['privateKey'])
"
}

xray_get_public_key() {
    local pk=$(xray_get_private_key)
    xray x25519 -i "$pk" 2>/dev/null | grep "Password (PublicKey):" | awk '{print $3}'
}

xray_get_sni() {
    python3 -c "
import json
with open('$XRAY_CONFIG') as f:
    config = json.load(f)
print(config['inbounds'][0]['streamSettings']['realitySettings']['serverNames'][0])
"
}

xray_get_short_id() {
    python3 -c "
import json
with open('$XRAY_CONFIG') as f:
    config = json.load(f)
print(config['inbounds'][0]['streamSettings']['realitySettings']['shortIds'][0])
"
}

xray_get_port() {
    python3 -c "
import json
with open('$XRAY_CONFIG') as f:
    config = json.load(f)
print(config['inbounds'][0]['port'])
"
}

xray_gen_link() {
    local UUID=$1 NAME=$2
    local PK=$(xray_get_public_key)
    local SNI=$(xray_get_sni)
    local SID=$(xray_get_short_id)
    local PORT=$(xray_get_port)
    echo "vless://${UUID}@${SNI}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PK}&sid=${SID}&type=tcp&headerType=none#${SNI}-${NAME}"
}

link_get_name() {
    echo "$1" | grep -oP '#\K.*$'
}

link_get_uuid() {
    echo "$1" | grep -oP '(?<=vless://)[^@]+'
}

list_sub_files() {
    find "$SUB_ROOT" -maxdepth 1 -type f 2>/dev/null | sort
}

sub_get_name() {
    basename "$1"
}

sub_get_url() {
    local subname=$1
    local base="https://$(xray_get_sni)/sub/${SUB_TOKEN}/$subname"
    echo "${base}#${subname}"
}

print_users_subs_overview() {
    local all_uuids_in_subs=()
    echo -e "  ${CYAN}── Subscriptions ────────────────────────────────${NC}"
    local sub_count=0
    for subfile in $(list_sub_files); do
        local subname=$(sub_get_name "$subfile")
        local decoded=$(base64 -d "$subfile" 2>/dev/null)
        echo -e "\n  ${YELLOW}▸ $subname${NC}"
        if [ -z "$(echo "$decoded" | grep -v '^$')" ]; then
            echo -e "    (empty)"
        else
            while IFS= read -r link; do
                [ -z "$link" ] && continue
                local uuid=$(link_get_uuid "$link")
                local name=$(link_get_name "$link")
                [ -z "$name" ] && name="$uuid"
                echo -e "    ${GREEN}•${NC} $name"
                all_uuids_in_subs+=("$uuid")
            done <<<"$decoded"
        fi
        ((sub_count++))
    done
    [ $sub_count -eq 0 ] && echo -e "\n    (no subscriptions)"
    echo -e "\n  ${CYAN}── Users without subscription ───────────────────${NC}\n"
    local found_nosub=0
    while IFS='|' read -r uuid name; do
        local in_sub=0
        for s in "${all_uuids_in_subs[@]}"; do
            [ "$s" = "$uuid" ] && in_sub=1 && break
        done
        if [ $in_sub -eq 0 ]; then
            echo -e "    ${GREEN}•${NC} $name"
            found_nosub=1
        fi
    done < <(xray_get_users)
    [ $found_nosub -eq 0 ] && echo -e "    (none)"
}

show_users_subs_list() {
    print_section "2.1" "User & Sub Management › List"
    print_users_subs_overview
    pause
}

xray_core_start() {
    print_section "1.1" "Core › Start"
    systemctl start xray && sleep 1
    systemctl is-active --quiet xray && ok "Xray started" || {
        fail "Failed"
        journalctl -u xray -n 5 --no-pager
    }
    pause
}

xray_core_stop() {
    print_section "1.2" "Core › Stop"
    systemctl stop xray && sleep 1
    ! systemctl is-active --quiet xray && ok "Xray stopped" || fail "Failed to stop"
    pause
}

xray_core_restart() {
    print_section "1.3" "Core › Restart"
    systemctl restart xray && sleep 1
    systemctl is-active --quiet xray && ok "Xray restarted" || {
        fail "Failed"
        journalctl -u xray -n 5 --no-pager
    }
    pause
}

xray_core_edit_config() {
    print_section "1.4" "Core › Edit main config"
    echo -e "  ${YELLOW}Opening $XRAY_CONFIG in nvim...${NC}\n"
    nvim "$XRAY_CONFIG"
    echo ""
    read -p "  Restart Xray to apply changes? (y/n): " confirm
    [ "$confirm" = "y" ] && systemctl restart xray && sleep 1 && ok "Xray restarted"
    pause
}

xray_core_backup() {
    print_section "1.5" "Core › Create config backup"
    if [ -f "$XRAY_BACKUP" ]; then
        echo -e "  ${YELLOW}Backup already exists — will be overwritten${NC}\n"
    fi
    cp "$XRAY_CONFIG" "$XRAY_BACKUP"
    if [ $? -eq 0 ]; then
        ok "Backup saved to $XRAY_BACKUP"
    else
        fail "Backup failed"
    fi
    pause
}

xray_core_edit_backup() {
    print_section "1.6" "Core › Edit backup config"
    if [ ! -f "$XRAY_BACKUP" ]; then
        fail "No backup found at $XRAY_BACKUP"
        pause
        return
    fi
    echo -e "  ${YELLOW}Opening $XRAY_BACKUP in nvim...${NC}\n"
    nvim "$XRAY_BACKUP"
    pause
}

xray_core_delete_backup() {
    print_section "1.7" "Core › Delete backup config"
    if [ ! -f "$XRAY_BACKUP" ]; then
        fail "No backup found at $XRAY_BACKUP"
        pause
        return
    fi
    echo -ne "  ${RED}Delete $XRAY_BACKUP? (y/n):${NC} "
    read confirm
    [ "$confirm" != "y" ] && {
        echo -e "\n  Cancelled."
        pause
        return
    }
    rm -f "$XRAY_BACKUP"
    ok "Backup deleted"
    pause
}

xray_core_restore() {
    print_section "1.8" "Core › Restore config from backup"
    if [ ! -f "$XRAY_BACKUP" ]; then
        fail "No backup found at $XRAY_BACKUP"
        pause
        return
    fi
    echo -e "  ${YELLOW}$XRAY_BACKUP${NC} → ${YELLOW}$XRAY_CONFIG${NC}"
    echo ""
    read -p "  Confirm restore and restart Xray? (y/n): " confirm
    [ "$confirm" != "y" ] && {
        echo -e "\n  Cancelled."
        pause
        return
    }
    cp "$XRAY_BACKUP" "$XRAY_CONFIG"
    if [ $? -eq 0 ]; then
        ok "Config restored from backup"
        systemctl restart xray && sleep 1
        systemctl is-active --quiet xray && ok "Xray restarted" || fail "Restart failed"
    else
        fail "Restore failed"
    fi
    pause
}

xray_core_list_configs() {
    print_section "1.4" "Core › List configs"
    local dir
    dir=$(dirname "$XRAY_CONFIG")
    echo -e "  ${YELLOW}$dir${NC}\n"
    if ls "$dir"/*.json &>/dev/null; then
        for f in "$dir"/*.json; do
            local size
            size=$(du -h "$f" 2>/dev/null | awk '{print $1}')
            local modified
            modified=$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null)
            local marker=""
            [ "$f" = "$XRAY_CONFIG" ] && marker=" ${GREEN}← main${NC}"
            [ "$f" = "$XRAY_BACKUP" ] && marker=" ${YELLOW}← backup${NC}"
            echo -e "  ${GREEN}•${NC} $(basename "$f")  ${CYAN}$size${NC}  $modified$marker"
        done
    else
        warn "No .json files found in $dir"
    fi
    pause
}

menu_core() {
    while true; do
        print_section "1" "Core Management"
        echo -e "  ${GREEN}1.${NC} Start Xray"
        echo -e "  ${GREEN}2.${NC} Stop Xray"
        echo -e "  ${GREEN}3.${NC} Restart Xray"
        echo -e "  ${GREEN}4.${NC} List configs ($(dirname "$XRAY_CONFIG")/)"
        echo -e "  ${GREEN}5.${NC} Edit main config ($XRAY_CONFIG)"
        echo -e "  ${GREEN}6.${NC} Create config backup ($XRAY_BACKUP)"
        echo -e "  ${GREEN}7.${NC} Edit backup config ($XRAY_BACKUP)"
        echo -e "  ${RED}8.${NC} Delete backup config ($XRAY_BACKUP)"
        echo -e "  ${GREEN}9.${NC} Restore config from backup ($XRAY_BACKUP → $XRAY_CONFIG)"
        echo -e "  ${YELLOW}0.${NC} Back"
        echo ""
        read -p "  Choice: " c
        case $c in
        1) xray_core_start ;;
        2) xray_core_stop ;;
        3) xray_core_restart ;;
        4) xray_core_list_configs ;;
        5) xray_core_edit_config ;;
        6) xray_core_backup ;;
        7) xray_core_edit_backup ;;
        8) xray_core_delete_backup ;;
        9) xray_core_restore ;;
        0) return ;;
        *) echo -e "${RED}Invalid${NC}" && sleep 1 ;;
        esac
    done
}

gen_link_qr() {
    print_section "2.2" "User & Sub Management › Link & QR generation"
    local items_label=()
    local items_type=()
    local items_ref=()
    local i=1
    echo -e "  ${CYAN}── Subscriptions ────────────────────────────────${NC}\n"
    for subfile in $(list_sub_files); do
        local subname=$(sub_get_name "$subfile")
        echo -e "  ${GREEN}$i.${NC} [SUB]  $subname"
        items_label+=("[SUB] $subname")
        items_type+=("sub")
        items_ref+=("$subfile")
        ((i++))
    done
    echo -e "\n  ${CYAN}── Users ─────────────────────────────────────────${NC}\n"
    while IFS='|' read -r uuid name; do
        echo -e "  ${GREEN}$i.${NC} [USER] $name"
        items_label+=("[USER] $name")
        items_type+=("user")
        items_ref+=("$uuid|$name")
        ((i++))
    done < <(xray_get_users)
    echo ""
    echo -e "  ${YELLOW}0.${NC} Cancel"
    echo ""
    read -p "  Select: " choice
    [ "$choice" = "0" ] && return
    local idx=$((choice - 1))
    local type="${items_type[$idx]}"
    local ref="${items_ref[$idx]}"
    [ -z "$type" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }
    print_section "2.2" "User & Sub Management › Link & QR generation"
    if [ "$type" = "sub" ]; then
        local subname=$(sub_get_name "$ref")
        local url=$(sub_get_url "$subname")
        echo -e "  ${YELLOW}Subscription:${NC} $subname\n"
        echo -e "  ${GREEN}URL:${NC}"
        echo "  $url"
        echo ""
        if command -v qrencode &>/dev/null; then
            echo -e "  ${GREEN}QR code:${NC}"
            qrencode -t ansiutf8 -s 2 "$url"
        fi
    else
        local uuid=$(echo "$ref" | cut -d'|' -f1)
        local name=$(echo "$ref" | cut -d'|' -f2)
        local link=$(xray_gen_link "$uuid" "$name")
        echo -e "  ${YELLOW}User:${NC} $name\n"
        echo -e "  ${GREEN}Link:${NC}"
        echo "  $link"
        echo ""
        if command -v qrencode &>/dev/null; then
            echo -e "  ${GREEN}QR code:${NC}"
            qrencode -t ansiutf8 -s 2 "$link"
        fi
    fi
    pause
}

user_create() {
    print_section "2.3" "Users › Create user"
    ask_input "Enter username" USERNAME || {
        pause
        return
    }
    echo ""
    echo -e "  ${YELLOW}Create user:${NC} $USERNAME"
    read -p "  Confirm? (y/n): " confirm
    [ "$confirm" != "y" ] && {
        echo -e "\n  Cancelled."
        pause
        return
    }
    local NEW_UUID=$(xray uuid)
    python3 - <<EOF
import json
with open("$XRAY_CONFIG", "r") as f:
    config = json.load(f)
config["inbounds"][0]["settings"]["clients"].append({
    "name": "$USERNAME", "id": "$NEW_UUID", "flow": "xtls-rprx-vision"
})
with open("$XRAY_CONFIG", "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
EOF
    systemctl restart xray && sleep 1 && systemctl restart nginx
    ok "User '$USERNAME' created, Xray & Nginx restarted"
    echo ""
    local LINK=$(xray_gen_link "$NEW_UUID" "$USERNAME")
    echo -e "  ${GREEN}Link:${NC}"
    echo "  $LINK"
    echo ""
    command -v qrencode &>/dev/null && qrencode -t ansiutf8 -s 2 "$LINK"
    pause
}

user_delete() {
    print_section "2.4" "Users › Delete user"
    local uuids=() names=() i=1
    while IFS='|' read -r uuid name; do
        uuids+=("$uuid")
        names+=("$name")
        echo -e "  ${RED}$i.${NC} $name"
        ((i++))
    done < <(xray_get_users)
    echo -e "  ${YELLOW}0.${NC} Cancel"
    echo ""
    read -p "  Select user to delete: " choice
    [ "$choice" = "0" ] && return
    local idx=$((choice - 1))
    local uuid="${uuids[$idx]}" name="${names[$idx]}"
    [ -z "$uuid" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }
    echo ""
    read -p "  Delete '$name'? (y/n): " confirm
    [ "$confirm" != "y" ] && {
        echo -e "\n  Cancelled."
        pause
        return
    }
    python3 - <<EOF
import json
with open("$XRAY_CONFIG", "r") as f:
    config = json.load(f)
config["inbounds"][0]["settings"]["clients"] = [
    c for c in config["inbounds"][0]["settings"]["clients"] if c.get("id") != "$uuid"
]
with open("$XRAY_CONFIG", "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
EOF
    for subfile in $(list_sub_files); do
        local decoded=$(base64 -d "$subfile" 2>/dev/null)
        echo "$decoded" | grep -v "$uuid" | grep -v '^$' | base64 -w 0 >"$subfile"
    done
    systemctl restart xray && sleep 1 && systemctl restart nginx
    ok "User '$name' deleted and removed from all subs"
    pause
}

sub_create() {
    print_section "2.5" "Subscriptions › Create"

    local domain
    domain=$(xray_get_sni 2>/dev/null)
    [ -z "$domain" ] && domain="unknown"

    ask_input "Enter subscription name (will be saved as ${domain}-name)" SUBNAME || {
        pause
        return
    }
    local full_name="${domain}-${SUBNAME}"
    mkdir -p "$SUB_ROOT"
    local subfile="$SUB_ROOT/$full_name"
    echo -n "" >"$subfile"
    ok "Subscription '$full_name' created"
    echo -e "  ${YELLOW}URL:${NC} $(sub_get_url $full_name)"
    pause
}

sub_delete() {
    print_section "2.6" "Subscriptions › Delete"
    local subfiles=() subnames=() i=1
    for subfile in $(list_sub_files); do
        subfiles+=("$subfile")
        subnames+=("$(sub_get_name $subfile)")
        echo -e "  ${GREEN}$i.${NC} $(sub_get_name $subfile)"
        ((i++))
    done
    [ ${#subfiles[@]} -eq 0 ] && {
        echo -e "  ${YELLOW}No subscriptions found${NC}"
        pause
        return
    }
    echo -e "  ${YELLOW}0.${NC} Cancel"
    echo ""
    read -p "  Select subscription to delete: " choice
    [ "$choice" = "0" ] && return
    local idx=$((choice - 1))
    local target="${subfiles[$idx]}"
    local subname="${subnames[$idx]}"
    [ -z "$target" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }
    echo ""
    read -p "  Also delete internal users in this sub from Xray? (y/n): " del_users
    echo ""
    read -p "  Confirm deletion of '$subname'? (y/n): " confirm
    [ "$confirm" != "y" ] && {
        echo -e "\n  Cancelled."
        pause
        return
    }
    if [ "$del_users" = "y" ]; then
        local decoded=$(base64 -d "$target" 2>/dev/null)
        while IFS= read -r link; do
            [ -z "$link" ] && continue
            local uuid=$(link_get_uuid "$link")
            python3 - <<EOF
import json
with open("$XRAY_CONFIG", "r") as f:
    config = json.load(f)
config["inbounds"][0]["settings"]["clients"] = [
    c for c in config["inbounds"][0]["settings"]["clients"] if c.get("id") != "$uuid"
]
with open("$XRAY_CONFIG", "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
EOF
        done <<<"$decoded"
        ok "Internal users deleted from Xray config"
    fi
    rm -f "$target"
    systemctl restart nginx
    ok "Subscription '$subname' deleted, Nginx restarted"
    pause
}

sub_add_user() {
    print_section "2.7" "Subscriptions › Add user to subscription"
    local subfiles=() subnames=() i=1
    for subfile in $(list_sub_files); do
        subfiles+=("$subfile")
        subnames+=("$(sub_get_name $subfile)")
        echo -e "  ${GREEN}$i.${NC} $(sub_get_name $subfile)"
        ((i++))
    done
    [ ${#subfiles[@]} -eq 0 ] && {
        echo -e "  ${YELLOW}No subscriptions found${NC}"
        pause
        return
    }
    echo -e "  ${YELLOW}0.${NC} Cancel"
    echo ""
    read -p "  Select subscription: " choice
    [ "$choice" = "0" ] && return
    local idx=$((choice - 1))
    local target="${subfiles[$idx]}"
    local subname="${subnames[$idx]}"
    [ -z "$target" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }
    local pending_links=()
    while true; do
        print_section "2.7" "Subscriptions › Add user to: $subname"
        if [ ${#pending_links[@]} -gt 0 ]; then
            echo -e "  ${CYAN}Pending changes (not yet saved):${NC}"
            for l in "${pending_links[@]}"; do
                local pname=$(link_get_name "$l")
                echo -e "    ${GREEN}+${NC} $pname"
            done
            echo ""
        fi
        local all_uuids_in_subs=()
        echo -e "  ${CYAN}── Current subscriptions ────────────────────────${NC}"
        for sf in $(list_sub_files); do
            local sn=$(sub_get_name "$sf")
            local dec=$(base64 -d "$sf" 2>/dev/null)
            echo -e "\n  ${YELLOW}▸ $sn${NC}"
            if [ -z "$(echo "$dec" | grep -v '^$')" ]; then
                echo -e "    (empty)"
            else
                while IFS= read -r lnk; do
                    [ -z "$lnk" ] && continue
                    local uuid=$(link_get_uuid "$lnk")
                    local name=$(link_get_name "$lnk")
                    [ -z "$name" ] && name="$uuid"
                    echo -e "    ${GREEN}•${NC} $name"
                    all_uuids_in_subs+=("$uuid")
                done <<<"$dec"
            fi
        done
        echo -e "\n  ${CYAN}── Users without subscription ───────────────────${NC}\n"
        while IFS='|' read -r uuid name; do
            local in_sub=0
            for s in "${all_uuids_in_subs[@]}"; do
                [ "$s" = "$uuid" ] && in_sub=1 && break
            done
            [ $in_sub -eq 0 ] && echo -e "    ${GREEN}•${NC} $name"
        done < <(xray_get_users)
        echo ""
        echo -e "  ${CYAN}──────────────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}1.${NC} Add internal user"
        echo -e "  ${GREEN}2.${NC} Add external user (paste vless link)"
        echo -e "  ${GREEN}3.${NC} Confirm & save"
        echo -e "  ${YELLOW}0.${NC} Cancel (discard all changes)"
        echo ""
        read -p "  Choice: " c
        case $c in
        0)
            echo -e "\n  ${YELLOW}Cancelled, no changes saved.${NC}"
            pause
            return
            ;;
        1)
            print_section "2.7.1" "Subscriptions › Add internal user to: $subname"
            local uuids=() unames=() j=1
            while IFS='|' read -r uuid name; do
                uuids+=("$uuid")
                unames+=("$name")
                echo -e "  ${GREEN}$j.${NC} $name"
                ((j++))
            done < <(xray_get_users)
            echo -e "  ${YELLOW}0.${NC} Cancel"
            echo ""
            read -p "  Select user: " uc
            [ "$uc" = "0" ] && continue
            local uidx=$((uc - 1))
            local uu="${uuids[$uidx]}" un="${unames[$uidx]}"
            [ -z "$uu" ] && {
                echo -e "\n  ${RED}Invalid${NC}"
                sleep 1
                continue
            }
            local link=$(xray_gen_link "$uu" "$un")
            pending_links+=("$link")
            ok "Added: $un"
            sleep 1
            ;;
        2)
            print_section "2.7.2" "Subscriptions › Add external user to: $subname"
            ask_input "Paste vless:// link" EXTLINK || continue
            local extname=$(link_get_name "$EXTLINK")
            [ -z "$extname" ] && extname="external"
            pending_links+=("$EXTLINK")
            ok "Added: $extname"
            sleep 1
            ;;
        3)
            if [ ${#pending_links[@]} -eq 0 ]; then
                echo -e "\n  ${YELLOW}Nothing to save${NC}"
                sleep 1
                continue
            fi
            local existing=$(base64 -d "$target" 2>/dev/null)
            local combined="$existing"
            for l in "${pending_links[@]}"; do
                combined=$(printf "%s\n%s" "$combined" "$l")
            done
            echo "$combined" | grep -v '^$' | base64 -w 0 >"$target"
            systemctl restart nginx
            ok "Saved ${#pending_links[@]} link(s), Nginx restarted"
            echo -e "  ${YELLOW}Sub URL:${NC} $(sub_get_url $subname)"
            pause
            return
            ;;
        *) echo -e "${RED}Invalid${NC}" && sleep 1 ;;
        esac
    done
}

sub_remove_user() {
    print_section "2.8" "Subscriptions › Remove user from subscription"
    local subfiles=() subnames=() i=1
    for subfile in $(list_sub_files); do
        subfiles+=("$subfile")
        subnames+=("$(sub_get_name $subfile)")
        echo -e "  ${GREEN}$i.${NC} $(sub_get_name $subfile)"
        ((i++))
    done
    [ ${#subfiles[@]} -eq 0 ] && {
        echo -e "  ${YELLOW}No subscriptions found${NC}"
        pause
        return
    }
    echo -e "  ${YELLOW}0.${NC} Cancel"
    echo ""
    read -p "  Select subscription: " choice
    [ "$choice" = "0" ] && return
    local idx=$((choice - 1))
    local target="${subfiles[$idx]}"
    local subname="${subnames[$idx]}"
    [ -z "$target" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }
    local pending_remove=()
    while true; do
        print_section "2.8" "Subscriptions › Remove user from: $subname"
        local decoded=$(base64 -d "$target" 2>/dev/null)
        local all_links=()
        while IFS= read -r link; do
            [ -z "$link" ] && continue
            all_links+=("$link")
        done <<<"$decoded"
        if [ ${#pending_remove[@]} -gt 0 ]; then
            echo -e "  ${CYAN}Pending removals (not yet saved):${NC}"
            for r in "${pending_remove[@]}"; do
                local rname=$(link_get_name "$r")
                [ -z "$rname" ] && rname="$r"
                echo -e "    ${RED}-${NC} $rname"
            done
            echo ""
        fi
        echo -e "  ${YELLOW}Users in this sub:${NC}"
        local j=1
        local display_links=()
        for link in "${all_links[@]}"; do
            local skip=0
            for r in "${pending_remove[@]}"; do
                [ "$r" = "$link" ] && skip=1 && break
            done
            [ $skip -eq 1 ] && continue
            local name=$(link_get_name "$link")
            [ -z "$name" ] && name=$(link_get_uuid "$link")
            display_links+=("$link")
            echo -e "  ${GREEN}$j.${NC} $name"
            ((j++))
        done
        [ ${#display_links[@]} -eq 0 ] && echo -e "    (none left)"
        echo ""
        echo -e "  ${GREEN}c.${NC} Confirm & save"
        echo -e "  ${YELLOW}0.${NC} Cancel (discard changes)"
        echo ""
        read -p "  Select user to remove (number / c / 0): " rc
        case $rc in
        0)
            echo -e "\n  ${YELLOW}Cancelled, no changes saved.${NC}"
            pause
            return
            ;;
        c | C)
            if [ ${#pending_remove[@]} -eq 0 ]; then
                echo -e "\n  ${YELLOW}Nothing to save${NC}"
                sleep 1
                continue
            fi
            local new_content=""
            for link in "${all_links[@]}"; do
                local skip=0
                for r in "${pending_remove[@]}"; do
                    [ "$r" = "$link" ] && skip=1 && break
                done
                [ $skip -eq 0 ] && new_content=$(printf "%s\n%s" "$new_content" "$link")
            done
            echo "$new_content" | grep -v '^$' | base64 -w 0 >"$target"
            systemctl restart nginx
            ok "${#pending_remove[@]} user(s) removed, Nginx restarted"
            pause
            return
            ;;
        *)
            local ridx=$((rc - 1))
            local rlink="${display_links[$ridx]}"
            [ -z "$rlink" ] && {
                echo -e "\n  ${RED}Invalid${NC}"
                sleep 1
                continue
            }
            pending_remove+=("$rlink")
            local rname=$(link_get_name "$rlink")
            ok "Marked for removal: $rname"
            sleep 1
            ;;
        esac
    done
}

sub_edit_file() {
    print_section "2.9" "Subscriptions › Edit or cat subscription file"

    local subfiles=() subnames=() i=1
    for subfile in $(list_sub_files); do
        subfiles+=("$subfile")
        subnames+=("$(sub_get_name $subfile)")
        echo -e "  ${GREEN}$i.${NC} $(sub_get_name $subfile)"
        ((i++))
    done
    [ ${#subfiles[@]} -eq 0 ] && {
        echo -e "  ${YELLOW}No subscriptions found${NC}"
        pause
        return
    }
    echo -e "  ${YELLOW}0.${NC} Cancel"
    echo ""
    read -p "  Select subscription: " choice
    [ "$choice" = "0" ] && return

    local idx=$((choice - 1))
    local target="${subfiles[$idx]}"
    local subname="${subnames[$idx]}"
    [ -z "$target" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }

    while true; do
        print_section "2.9" "Subscriptions › $subname"
        echo -e "  ${YELLOW}Path:${NC} $target"
        echo -e "  ${YELLOW}URL:${NC}  $(sub_get_url $subname)"
        echo ""
        echo -e "  ${GREEN}1.${NC} Edit in nvim"
        echo -e "  ${GREEN}2.${NC} Cat file (show decoded content)"
        echo -e "  ${YELLOW}0.${NC} Back"
        echo ""
        read -p "  Choice: " c
        case $c in
        1)
            local tmpfile=$(mktemp /tmp/sub-edit-XXXXXX.txt)
            base64 -d "$target" 2>/dev/null >"$tmpfile"
            echo -e "\n  ${YELLOW}Opening decoded content in nvim...${NC}\n"
            sleep 1
            nvim "$tmpfile"
            base64 -w 0 "$tmpfile" >"$target"
            rm -f "$tmpfile"
            echo ""
            read -p "  Restart Nginx to apply changes? (y/n): " confirm
            [ "$confirm" = "y" ] && systemctl restart nginx && ok "Nginx restarted"
            ;;
        2)
            print_section "2.9" "Subscriptions › $subname › Content"
            echo -e "  ${CYAN}──────────────────────────────────────────────${NC}\n"
            local decoded
            decoded=$(base64 -d "$target" 2>/dev/null)
            if [ -z "$(echo "$decoded" | grep -v '^$')" ]; then
                warn "Subscription is empty"
            else
                echo "$decoded"
            fi
            pause
            ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid${NC}" && sleep 1 ;;
        esac
    done
}

menu_xray_users() {
    while true; do
        print_section "2" "User & Subscription Management"
        echo -e "  ${GREEN}1.${NC} List subscriptions & users"
        echo -e "  ${GREEN}2.${NC} Link & QR code generation"
        echo ""
        echo -e "  ${CYAN}── Users ─────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}3.${NC} Create user"
        echo -e "  ${GREEN}4.${NC} Delete user"
        echo ""
        echo -e "  ${CYAN}── Subscriptions ────────────────────────────────${NC}"
        echo -e "  ${GREEN}5.${NC} Create new subscription"
        echo -e "  ${GREEN}6.${NC} Delete subscription"
        echo -e "  ${GREEN}7.${NC} Add user to subscription"
        echo -e "  ${GREEN}8.${NC} Remove user from subscription"
        echo -e "  ${GREEN}9.${NC} Edit or cat subscription file"
        echo -e "  ${YELLOW}0.${NC} Back"
        echo ""
        read -p "  Choice: " c
        case $c in
        1) show_users_subs_list ;;
        2) gen_link_qr ;;
        3) user_create ;;
        4) user_delete ;;
        5) sub_create ;;
        6) sub_delete ;;
        7) sub_add_user ;;
        8) sub_remove_user ;;
        9) sub_edit_file ;;
        0) return ;;
        *) echo -e "${RED}Invalid${NC}" && sleep 1 ;;
        esac
    done
}

write_web_page() {
    mkdir -p "$WEB_ROOT"
    cat >"$WEB_ROOT/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Вход в Confluence</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; background-color: #f4f5f7; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .login-container { background-color: white; padding: 40px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.12), 0 1px 2px rgba(0,0,0,0.24); width: 350px; text-align: center; }
        .logo { margin-bottom: 20px; } .logo img { width: 120px; }
        h2 { margin-bottom: 20px; font-size: 24px; color: #0052cc; }
        input[type="text"], input[type="password"] { width: 100%; padding: 10px; margin: 10px 0; border: 1px solid #dfe1e6; border-radius: 4px; box-sizing: border-box; font-size: 16px; }
        .error { border-color: red; }
        .error-message { color: red; font-size: 14px; display: none; margin-top: 10px; }
        button { width: 100%; padding: 10px; background-color: #0052cc; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 16px; margin-top: 20px; }
        button:hover { background-color: #0747a6; }
        .help-links { margin-top: 20px; font-size: 14px; }
        .help-links a { color: #0052cc; text-decoration: none; }
        .help-links a:hover { text-decoration: underline; }
        .modal { display: none; position: fixed; z-index: 1; left: 0; top: 0; width: 100%; height: 100%; overflow: auto; background-color: rgba(0,0,0,0.4); padding-top: 60px; }
        .modal-content { background-color: white; margin: 5% auto; padding: 20px; border: 1px solid #888; width: 80%; max-width: 400px; border-radius: 8px; text-align: center; }
        .close { color: #aaa; float: right; font-size: 28px; font-weight: bold; cursor: pointer; }
        .close:hover, .close:focus { color: black; text-decoration: none; }
    </style>
</head>
<body>
<div class="login-container">
    <div class="logo"><img src="https://cdn.icon-icons.com/icons2/2429/PNG/512/confluence_logo_icon_147305.png" alt="Confluence"></div>
    <h2 id="login-title">Войти в Confluence</h2>
    <form id="login-form">
        <input type="text" id="username" name="username" placeholder="Адрес электронной почты">
        <input type="password" id="password" name="password" placeholder="Введите пароль">
        <button type="submit" id="login-button">Войти</button>
    </form>
    <div id="error-message" class="error-message">Неправильное имя пользователя или пароль.</div>
    <div class="help-links"><a href="#" id="forgot-link">Не удается войти?</a> • <a href="#" id="create-link">Создать аккаунт</a></div>
</div>
<div id="myModal" class="modal">
    <div class="modal-content"><span class="close">&times;</span><p id="modal-text">Для создания аккаунта обратитесь к администратору.</p></div>
</div>
<script>
    function setLanguage(lang) {
        const e = {
            ru: { loginTitle:'Войти в Confluence', usernamePlaceholder:'Адрес электронной почты', passwordPlaceholder:'Введите пароль', loginButton:'Войти', forgotLink:'Не удается войти?', createLink:'Создать аккаунт', createAccountText:'Для создания аккаунта обратитесь к администратору.', forgotPasswordText:'Для восстановления доступа обратитесь к администратору.', errorMessage:'Неправильное имя пользователя или пароль.' },
            en: { loginTitle:'Login to Confluence', usernamePlaceholder:'Email address', passwordPlaceholder:'Enter password', loginButton:'Login', forgotLink:"Can't log in?", createLink:'Create an account', createAccountText:'To create an account, please contact your administrator.', forgotPasswordText:'To recover access, please contact your administrator.', errorMessage:'Incorrect username or password.' }
        };
        document.getElementById('login-title').innerText = e[lang].loginTitle;
        document.getElementById('username').placeholder = e[lang].usernamePlaceholder;
        document.getElementById('password').placeholder = e[lang].passwordPlaceholder;
        document.getElementById('login-button').innerText = e[lang].loginButton;
        document.getElementById('forgot-link').innerText = e[lang].forgotLink;
        document.getElementById('create-link').innerText = e[lang].createLink;
        document.getElementById('create-link').dataset.modalText = e[lang].createAccountText;
        document.getElementById('forgot-link').dataset.modalText = e[lang].forgotPasswordText;
        document.getElementById('error-message').innerText = e[lang].errorMessage;
    }
    function detectLanguage() { setLanguage((navigator.language||navigator.userLanguage).startsWith('ru') ? 'ru' : 'en'); }
    document.addEventListener('DOMContentLoaded', detectLanguage);
    var modal = document.getElementById("myModal");
    var span = document.getElementsByClassName("close")[0];
    function openModal(t) { document.getElementById('modal-text').innerText = t; modal.style.display = "block"; }
    document.getElementById("create-link").onclick = function(e) { e.preventDefault(); openModal(this.dataset.modalText); }
    document.getElementById("forgot-link").onclick = function(e) { e.preventDefault(); openModal(this.dataset.modalText); }
    span.onclick = function() { modal.style.display = "none"; }
    window.onclick = function(e) { if (e.target == modal) modal.style.display = "none"; }
    document.getElementById('login-form').onsubmit = function(e) {
        e.preventDefault();
        var u = document.getElementById('username'), p = document.getElementById('password'), err = document.getElementById('error-message');
        u.classList.remove('error'); p.classList.remove('error'); err.style.display = 'none';
        var hasError = false;
        if (u.value.trim() === '') { u.classList.add('error'); hasError = true; }
        if (p.value.trim() === '') { p.classList.add('error'); hasError = true; }
        if (hasError) return;
        err.style.display = 'block';
    };
</script>
</body>
</html>
HTMLEOF
}

write_xray_nginx_conf() {
    local DOMAIN=$1
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    cat >"$NGINX_WEB_CONF" <<EOF
server {
    listen 127.0.0.1:8443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    root $WEB_ROOT;
    index index.html;

    location /sub/ {
        default_type text/plain;
    }
}
EOF
    ln -sf "$NGINX_WEB_CONF" "$NGINX_WEB_ENABLED"
}

xray_autodeploy() {
    print_section "3" "Autodeploy"

    ask_input "Enter domain" DOMAIN || {
        pause
        return
    }

    echo ""
    echo -e "  ${BOLD}What will happen:${NC}"
    echo -e "  ${RED}•${NC} Install packages (nginx, certbot, xray, qrencode)"
    echo -e "  ${RED}•${NC} Obtain TLS certificate for ${BOLD}$DOMAIN${NC}"
    echo -e "  ${RED}•${NC} Generate new Xray keys and config"
    echo -e "  ${RED}•${NC} Overwrite existing Xray config if present"
    echo -e "  ${RED}•${NC} Restart Nginx and Xray"
    echo -e "  ${YELLOW}•${NC} All existing users will be lost"
    echo ""
    echo -e "  ${RED}${BOLD}This cannot be undone.${NC}"
    echo ""
    echo -ne "  ${RED}Type 'deploy' to confirm:${NC} "
    read confirm
    if [ "$confirm" != "deploy" ]; then
        echo -e "\n  ${YELLOW}Cancelled.${NC}"
        pause
        return
    fi

    echo ""
    step "Installing packages..."
    apt install -y sudo git curl nginx certbot python3-certbot-nginx qrencode
    ok "Packages installed"

    step "Configuring Nginx service..."
    systemctl stop nginx && systemctl enable nginx
    ok "Done"

    step "Removing default Nginx configs..."
    rm -f /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    ok "Done"

    step "Writing web page and Nginx config..."
    write_web_page
    write_xray_nginx_conf "$DOMAIN"
    ok "Done"

    step "Obtaining TLS certificate for $DOMAIN..."
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
    if [ $? -ne 0 ]; then
        fail "certbot failed — check DNS"
        pause
        return
    fi
    ok "Certificate obtained"

    step "Starting Nginx..."
    nginx -t && systemctl restart nginx
    systemctl is-active --quiet nginx && ok "Nginx started" || {
        fail "Nginx failed"
        pause
        return
    }

    step "Installing Xray..."
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
    ok "Xray installed"

    step "Removing default Xray config..."
    rm -f "$XRAY_CONFIG"
    ok "Done"

    step "Generating Xray config..."
    local KEYS=$(xray x25519)
    local PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey:" | awk '{print $2}')
    local PUBLIC_KEY=$(echo "$KEYS" | grep "Password (PublicKey):" | awk '{print $3}')
    local SHORT_ID=$(openssl rand -hex 8)

    mkdir -p "$(dirname "$XRAY_CONFIG")"
    python3 - <<EOF
import json
config = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "listen": "0.0.0.0", "port": 443, "protocol": "vless",
        "settings": {"clients": [], "decryption": "none"},
        "streamSettings": {
            "network": "tcp", "security": "reality",
            "realitySettings": {
                "dest": "127.0.0.1:8443",
                "serverNames": ["$DOMAIN"],
                "privateKey": "$PRIVATE_KEY",
                "shortIds": ["$SHORT_ID"]
            }
        },
        "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"]}
    }],
    "outbounds": [
        {"protocol": "freedom", "tag": "direct", "settings": {"domainStrategy": "AsIs", "redirect": "", "noises": []}},
        {"protocol": "blackhole", "tag": "blocked"}
    ]
}
with open("$XRAY_CONFIG", "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
EOF
    ok "Xray config generated"

    step "Configuring Xray network dependency..."
    mkdir -p /etc/systemd/system/xray.service.d
    cat >/etc/systemd/system/xray.service.d/override.conf <<EOF
[Unit]
After=network-online.target
Wants=network-online.target
EOF
    systemctl daemon-reload
    ok "Done"

    step "Starting Xray..."
    systemctl enable xray && systemctl start xray && sleep 1
    systemctl is-active --quiet xray && ok "Xray started" || {
        fail "Xray failed"
        journalctl -u xray -n 10 --no-pager
        pause
        return
    }

    step "Generating subscription token..."
    local NEW_TOKEN
    NEW_TOKEN=$(openssl rand -hex 12)
    local new_sub_root="$WEB_ROOT/sub/$NEW_TOKEN"
    mkdir -p "$new_sub_root"
    SUB_TOKEN="$NEW_TOKEN"
    SUB_ROOT="$new_sub_root"
    ok "Sub token: $NEW_TOKEN"
    ok "Sub root:  $SUB_ROOT"

    echo ""
    echo -e "${CYAN}  ╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}  ║            Autodeploy complete!                  ║${NC}"
    echo -e "${CYAN}  ╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}Domain:${NC}      $DOMAIN"
    echo -e "  ${YELLOW}Private key:${NC} $PRIVATE_KEY"
    echo -e "  ${YELLOW}Public key:${NC}  $PUBLIC_KEY"
    echo -e "  ${YELLOW}Short ID:${NC}    $SHORT_ID"
    echo ""
    echo -e "  ${RED}Save these — private key is not stored anywhere else!${NC}"
    echo -e "  ${YELLOW}Go to section 2 to add users and subscriptions.${NC}"
    pause
}

# ─────────────────────────────────────────
# 4. Eliminate
# ─────────────────────────────────────────

eliminate_xray() {
    print_section "4.1" "Eliminate › Xray and Xray config"

    echo -e "  ${BOLD}What will be removed:${NC}"
    echo -e "  ${RED}•${NC} Stop and disable xray service"
    echo -e "  ${RED}•${NC} Uninstall xray binary"
    echo -e "  ${RED}•${NC} Delete $XRAY_CONFIG and $XRAY_BACKUP"
    echo -e "  ${RED}•${NC} Delete /usr/local/etc/xray/ entirely"
    echo -e "  ${RED}•${NC} Delete systemd override /etc/systemd/system/xray.service.d/"
    echo ""
    echo -ne "  ${RED}Type 'eliminate' to confirm:${NC} "
    read confirm
    [ "$confirm" != "eliminate" ] && {
        echo -e "\n  ${YELLOW}Cancelled.${NC}"
        pause
        return
    }

    echo ""
    info "Stopping xray..."
    systemctl stop xray 2>/dev/null
    systemctl disable xray 2>/dev/null
    ok "Stopped"

    info "Uninstalling xray..."
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) -- remove 2>/dev/null ||
        rm -f /usr/local/bin/xray /usr/local/bin/xray-knife
    ok "Xray binary removed"

    info "Removing configs..."
    rm -rf /usr/local/etc/xray/
    rm -rf /etc/systemd/system/xray.service.d/
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/xray@.service
    systemctl daemon-reload
    ok "Configs removed"

    ok "Xray eliminated"
    pause
}

eliminate_nginx() {
    print_section "4.2" "Eliminate › Nginx and Nginx config"

    echo -e "  ${BOLD}What will be removed:${NC}"
    echo -e "  ${RED}•${NC} Stop and disable nginx"
    echo -e "  ${RED}•${NC} Delete $NGINX_WEB_CONF and symlink"
    echo -e "  ${RED}•${NC} Delete web root $WEB_ROOT"
    echo -e "  ${RED}•${NC} Purge nginx packages"
    echo ""
    echo -ne "  ${RED}Type 'eliminate' to confirm:${NC} "
    read confirm
    [ "$confirm" != "eliminate" ] && {
        echo -e "\n  ${YELLOW}Cancelled.${NC}"
        pause
        return
    }

    echo ""
    info "Stopping nginx..."
    systemctl stop nginx 2>/dev/null
    ok "Stopped"

    info "Removing configs..."
    rm -f "$NGINX_WEB_CONF" "$NGINX_WEB_ENABLED"
    rm -rf "$WEB_ROOT"
    ok "Configs removed"

    info "Purging nginx..."
    apt-get purge -y nginx nginx-common nginx-full 2>/dev/null ||
        {
            warn "apt not available, trying manual removal"
            rm -rf /etc/nginx /var/log/nginx
        }
    apt-get autoremove -y 2>/dev/null
    ok "Nginx purged"

    ok "Nginx eliminated"
    pause
}

eliminate_tls() {
    print_section "4.3" "Eliminate › TLS certificates"

    local domain
    domain=$(xray_get_sni 2>/dev/null)

    if [ -z "$domain" ]; then
        warn "Cannot determine domain from Xray config"
        echo -ne "  Enter domain to delete certificates for: "
        read domain
        [ -z "$domain" ] && {
            echo -e "\n  Cancelled."
            pause
            return
        }
    fi

    echo -e "  ${BOLD}What will be removed:${NC}"
    echo -e "  ${RED}•${NC} Certbot certificate for ${BOLD}$domain${NC}"
    echo -e "  ${RED}•${NC} /etc/letsencrypt/live/$domain/"
    echo -e "  ${RED}•${NC} /etc/letsencrypt/archive/$domain/"
    echo -e "  ${RED}•${NC} /etc/letsencrypt/renewal/$domain.conf"
    echo ""
    echo -ne "  ${RED}Type 'eliminate' to confirm:${NC} "
    read confirm
    [ "$confirm" != "eliminate" ] && {
        echo -e "\n  ${YELLOW}Cancelled.${NC}"
        pause
        return
    }

    echo ""
    info "Revoking and deleting certificate for $domain..."
    certbot delete --cert-name "$domain" --non-interactive 2>/dev/null ||
        {
            warn "certbot delete failed, removing manually..."
            rm -rf "/etc/letsencrypt/live/$domain"
            rm -rf "/etc/letsencrypt/archive/$domain"
            rm -f "/etc/letsencrypt/renewal/$domain.conf"
        }
    ok "TLS certificates for $domain eliminated"
    pause
}
