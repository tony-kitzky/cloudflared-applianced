#!/usr/bin/env bash
#------------------------------------------------------------------------------
# cloudflared-native-setup.sh
# Alternative to cloudflared-container-setup.sh: installs the cloudflared
# binary directly on the host (no Podman/pasta) and runs it as a native
# systemd service under a dedicated, unprivileged, no-login system user.
#
# Why this exists:
#   The container-based setup (cloudflared-container-setup.sh) runs
#   cloudflared inside a rootless Podman container, connected to the host
#   via a single pasta tap device bound to exactly one host interface
#   (Network=pasta:-i,<iface>). pasta has no supported way to bind more
#   than one host interface into that same container namespace -- see
#   https://github.com/containers/podman/issues/26114 -- so a container
#   that needs simultaneous eth0 (VPC-wide origin traffic) and eth1
#   (edge-bound traffic) reachability cannot get it from pasta today.
#
#   Running cloudflared as a normal host process sidesteps this entirely:
#   there is no pasta, no container network namespace, and no address
#   translation layer. The process uses the host kernel's own routing
#   table directly, so normal per-destination route selection already
#   sends edge traffic out whichever interface holds the edge routes
#   (see configure_edge_routing below) and origin/WARP-routing traffic
#   out whichever interface holds the route to that destination --
#   both simultaneously, with no extra configuration.
#
# Security note:
#   cloudflared only ever makes OUTBOUND connections (the edge tunnel on
#   TCP/UDP 7844, and outbound dials for WARP-routed private destinations).
#   It never needs to bind a privileged (<1024) port, so the dedicated
#   service user needs no special capabilities -- a plain unprivileged,
#   no-login system account is sufficient. See:
#   https://github.com/cloudflare/cloudflared/issues/672 (Cloudflare's own
#   recommendation to run cloudflared as a non-root user).
#
# This script is independent of cloudflared-container-setup.sh. It does
# NOT touch any existing Podman/Quadlet installation -- run it side by
# side, compare, and migrate (via cloudflared-container-uninstall.sh) at
# your own pace.
#
# Implements:
#  1) Install the cloudflared RPM from Cloudflare's official repo (not
#     Podman/passt -- this path needs neither).
#  2) Prompt once for a base username (default: cloudflared-native). The
#     prod instance always runs as "<base>-prod" (created if missing, as
#     a system/no-login account -- NOT the rootless container user of
#     the same base name, kept in its own namespace to avoid confusion):
#       a) cloudflared tunnel token (dashboard-generated)
#  3) OPTIONAL: prompt to also install a second "dev" instance, running
#     as "<base>-dev":
#       a) cloudflared tunnel token
#  3b) Prompt once (shared by both prod and dev) for the network
#      interface to bind outgoing Cloudflare Edge connections to, and
#      apply the same configure_edge_routing() logic used by the
#      container-based script (static routes for the Cloudflare Tunnel
#      edge ranges + DNS resolver, via that interface's gateway, with
#      ipv4.never-default set so it never grabs the default route).
#  4) Enable persistent journaling + per-user journals
#  5) Create one systemd unit per instance (cloudflared.service /
#     cloudflared-dev.service), running as the dedicated unprivileged
#     user with NoNewPrivileges/ProtectHome/ProtectSystem hardening.
#  6) Install a single merged /usr/local/sbin/cloudflared-native
#     management command (status/restart/upgrade/change-token), usable
#     by any sudoer, mirroring cloudflared-container's UX.
#
# Notes:
#  - Token is stored in a root-owned, 0600 EnvironmentFile, readable only
#    by root and the systemd unit itself (systemd reads EnvironmentFile
#    before dropping privileges to User=), never on the process command
#    line (which would be visible via ps/`/proc/<pid>/cmdline`).
#  - Because there is no pasta/container namespace here, TUNNEL_EDGE_
#    BIND_ADDRESS / TUNNEL_EDGE_IP_VERSION are not needed -- cloudflared
#    on the bare host already sees every host interface and its normal
#    routing table, so it binds outbound connections the same way any
#    other host process would (via the routes configure_edge_routing
#    installs), with no explicit bind-address override required.
#  - This script assumes the cloudflared binary is NOT already installed
#    via the container path's image; it installs the native RPM package
#    from Cloudflare's own repo (pkg.cloudflare.com), independent of any
#    docker.io/cloudflare/cloudflared image already pulled for Podman.
#
# Usage:
#   sudo bash cloudflared-native-setup.sh
#------------------------------------------------------------------------------

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*" >&2; }
warn() { echo "WARN: $*" >&2; }

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash $0"; }

iface_exists() { ip link show dev "$1" >/dev/null 2>&1; }

# Print the first IPv4 address (no CIDR suffix) assigned to the given
# interface, or return non-zero if none is found.
iface_ipv4_address() {
  local iface="$1"
  ip -4 -o addr show dev "$iface" scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | head -n1
}

# Print the interface currently holding the default (0.0.0.0/0) IPv4
# route, or nothing if there isn't one.
default_route_iface() {
  ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1
}

# Print the gateway of the default IPv4 route on the given interface, or
# nothing if that interface has no default route.
default_route_gateway_on_iface() {
  local iface="$1"
  ip -4 route show default dev "$iface" 2>/dev/null \
    | awk '{for (i=1;i<=NF;i++) if ($i=="via") print $(i+1)}' | head -n1
}

# Print the NetworkManager connection name that currently owns the given
# interface, or nothing if NetworkManager doesn't manage it (or isn't
# running).
nm_connection_for_iface() {
  local iface="$1"
  command -v nmcli >/dev/null 2>&1 || return 0
  nmcli -t -f DEVICE,CONNECTION device status 2>/dev/null \
    | awk -F: -v d="$iface" '$1==d {print $2; exit}'
}

# Print every distinct IPv4 address a hostname resolves to (one per
# line), or nothing on failure. Uses getent (NSS-aware: honours
# /etc/nsswitch.conf, /etc/hosts, etc.) rather than dig/host, since
# those tools aren't guaranteed to be installed on a minimal AlmaLinux
# image.
resolve_ipv4_addresses() {
  local hostname="$1"
  getent ahostsv4 "$hostname" 2>/dev/null | awk '{print $1}' | sort -u
}

readonly CLOUDFLARE_TUNNEL_EDGE_PREFIXES=("198.41.192.0/24" "198.41.200.0/24")

# Fixed Cloudflare Tunnel edge hostnames whose currently-resolved IPv4
# addresses also need explicit routes (SRV/API lookups cloudflared
# performs at startup and periodically thereafter).
readonly CLOUDFLARE_TUNNEL_EDGE_HOSTNAMES=("api.cloudflare.com" "cfd-features.argotunnel.com")

# Fixed hosts (Cloudflare's own public resolvers) that cloudflared and
# the host may need to reach via the edge interface too.
readonly CLOUDFLARE_TUNNEL_EDGE_HOSTS=("1.1.1.1" "1.0.0.1")

# Same edge-routing logic as cloudflared-container-setup.sh's
# configure_edge_routing(): adds static routes for the Cloudflare Tunnel
# edge ranges (plus the host's own DNS resolver, needed once
# ipv4.never-default removes the edge interface's implicit default-route
# path) via the given interface's gateway, and sets ipv4.never-default=yes
# on that interface's connection so NetworkManager never hands it the
# default route. Kept byte-for-byte equivalent to the container script's
# copy so both setups converge on identical routing tables and can be
# run side by side without conflicting route changes.
configure_edge_routing() {
  local edge_iface="$1"

  command -v nmcli >/dev/null 2>&1 || {
    warn "nmcli not found; skipping Cloudflare Tunnel edge static routes for ${edge_iface}."
    return 0
  }

  local primary_iface
  primary_iface="$(default_route_iface)"
  if [[ -z "$primary_iface" ]]; then
    warn "Could not determine the interface currently holding the default route; skipping Cloudflare Tunnel edge static routes."
    return 0
  fi
  if [[ "$primary_iface" == "$edge_iface" ]]; then
    info "${edge_iface} already holds the default route; no separate routing needed for Cloudflare Tunnel edge ranges, skipping."
    return 0
  fi

  local edge_gateway
  edge_gateway="$(default_route_gateway_on_iface "$edge_iface")"
  if [[ -z "$edge_gateway" ]]; then
    warn "Could not determine a gateway on ${edge_iface} (no default route present on it); skipping Cloudflare Tunnel edge static routes."
    return 0
  fi

  local edge_conn
  edge_conn="$(nm_connection_for_iface "$edge_iface")"
  if [[ -z "$edge_conn" ]]; then
    warn "Could not resolve a NetworkManager connection for ${edge_iface}; skipping Cloudflare Tunnel edge static routes."
    return 0
  fi

  local edge_prefixes=("${CLOUDFLARE_TUNNEL_EDGE_PREFIXES[@]}")
  local host_ip
  for host_ip in "${CLOUDFLARE_TUNNEL_EDGE_HOSTS[@]}"; do
    edge_prefixes+=("${host_ip}/32")
  done

  local hostname resolved_ips ip
  for hostname in "${CLOUDFLARE_TUNNEL_EDGE_HOSTNAMES[@]}"; do
    resolved_ips="$(resolve_ipv4_addresses "$hostname")"
    if [[ -z "$resolved_ips" ]]; then
      warn "Could not resolve ${hostname} to an IPv4 address; skipping its route for now."
      continue
    fi
    while IFS= read -r ip; do
      [[ -n "$ip" ]] && edge_prefixes+=("${ip}/32")
    done <<<"$resolved_ips"
  done

  local resolver_ip
  while IFS= read -r resolver_ip; do
    [[ -n "$resolver_ip" ]] && edge_prefixes+=("${resolver_ip}/32")
  done < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)

  local -A seen_prefixes=()
  local deduped_prefixes=()
  local prefix
  for prefix in "${edge_prefixes[@]}"; do
    [[ -n "${seen_prefixes[$prefix]:-}" ]] && continue
    seen_prefixes["$prefix"]=1
    deduped_prefixes+=("$prefix")
  done
  edge_prefixes=("${deduped_prefixes[@]}")

  echo
  info "Planned network changes so this host reaches Cloudflare Tunnel edge servers via ${edge_iface}, while everything else (including the public internet and RFC 1918 destinations) keeps using ${primary_iface} unchanged:"
  info "  - Add static routes via ${edge_gateway} on '${edge_conn}' (${edge_iface}) for: ${edge_prefixes[*]}"
  info "  - Set ipv4.never-default=yes on '${edge_conn}' (${edge_iface}) so NetworkManager never assigns it the default route"
  read -r -p "Apply these network changes now? [y/N]: " confirm_routing
  if [[ "${confirm_routing,,}" != "y" ]]; then
    warn "Skipping Cloudflare Tunnel edge routing changes at your request."
    return 0
  fi

  local existing_routes route_changed=0
  existing_routes="$(nmcli -t -g ipv4.routes connection show "$edge_conn" 2>/dev/null)"
  for prefix in "${edge_prefixes[@]}"; do
    if [[ "$existing_routes" == *"${prefix}"* ]]; then
      info "Route for ${prefix} already present on '${edge_conn}', leaving as-is."
      continue
    fi
    info "Adding route ${prefix} via ${edge_gateway} to '${edge_conn}'"
    nmcli connection modify "$edge_conn" +ipv4.routes "${prefix} ${edge_gateway}" \
      || { warn "Failed to add route ${prefix} to '${edge_conn}'"; continue; }
    route_changed=1
  done

  local current_never_default
  current_never_default="$(nmcli -t -g ipv4.never-default connection show "$edge_conn" 2>/dev/null)"
  if [[ "${current_never_default,,}" != "yes" ]]; then
    info "Setting ipv4.never-default=yes on '${edge_conn}' (${edge_iface})"
    nmcli connection modify "$edge_conn" ipv4.never-default yes \
      || { warn "Failed to set ipv4.never-default on '${edge_conn}'"; }
    route_changed=1
  else
    info "ipv4.never-default already set on '${edge_conn}', leaving as-is."
  fi

  if [[ "$route_changed" == "1" ]]; then
    nmcli device reapply "$edge_iface" \
      || warn "Failed to reapply '${edge_conn}' on ${edge_iface}; changes are saved but may need 'nmcli connection up ${edge_conn}' (or a reboot) to take effect."
  fi

  echo
  info "Resulting IPv4 routing table:"
  ip -4 route show >&2
}

user_exists() { id "$1" >/dev/null 2>&1; }

# Create a dedicated, unprivileged, no-login SYSTEM account for one
# cloudflared instance. Unlike the container script's ensure_user (which
# creates a full login user with a home directory and subuid/subgid
# ranges for rootless Podman), this account never logs in, has no home
# directory, and needs no special uid/gid allocation -- it just needs to
# own its own config directory and be usable as systemd's User=.
ensure_native_user() {
  local u="$1"
  if user_exists "$u"; then
    info "User exists: $u"
  else
    info "User does not exist, creating (system, no-login): $u"
    useradd --system --no-create-home --shell /usr/sbin/nologin "$u"
  fi
}

install_cloudflared_rpm() {
  command -v cloudflared >/dev/null 2>&1 && {
    info "cloudflared binary already installed: $(command -v cloudflared) ($(cloudflared --version 2>/dev/null | head -n1))"
    return 0
  }

  info "Adding Cloudflare's official RPM repo (pkg.cloudflare.com) and installing cloudflared"
  mkdir -p /etc/yum.repos.d
  cat >/etc/yum.repos.d/cloudflared.repo <<'EOF'
[cloudflared]
name=Cloudflare cloudflared
baseurl=https://pkg.cloudflare.com/cloudflared/rpm
gpgcheck=1
gpgkey=https://pkg.cloudflare.com/cloudflare-main.gpg
enabled=1
EOF
  dnf install -y cloudflared >/dev/null
}

enable_persistent_journaling() {
  info "Enabling persistent journaling and per-user journals (SplitMode=uid)"

  mkdir -p /var/log/journal
  chmod 2755 /var/log/journal

  mkdir -p /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/99-persistent.conf <<'EOF'
[Journal]
Storage=persistent
SplitMode=uid
EOF

  systemctl restart systemd-journald.service
  journalctl --flush >/dev/null 2>&1 || true
}

# Create the config directory + systemd unit for one native cloudflared
# instance ("prod" or "dev"). Unlike create_quadlet_rootless (the
# container script's equivalent), this writes a system-level (root-owned
# tree, root:root systemd unit under /etc/systemd/system) service that
# runs as an unprivileged User=/Group= -- there is no per-user systemd
# instance, no XDG_RUNTIME_DIR dance, and no linger requirement, because
# this is a normal system service, not systemd --user.
create_native_service() {
  local instance="$1" u="$2" token="$3"
  local unit_name config_dir env_file unit_file

  if [[ "$instance" == "prod" ]]; then
    unit_name="cloudflared"
    config_dir="/etc/cloudflared"
  else
    unit_name="cloudflared-dev"
    config_dir="/etc/cloudflared-dev"
  fi

  env_file="${config_dir}/${unit_name}.env"
  unit_file="/etc/systemd/system/${unit_name}.service"

  info "Creating native systemd unit for instance '${instance}' (unit: ${unit_name}.service) under user $u"

  install -d -m 0750 -o root -g "$u" "$config_dir"

  # Token via EnvironmentFile, not a CLI argument: a --token argument
  # would be visible to any local user via `ps` or the world-readable
  # /proc/<pid>/cmdline, regardless of file permissions on this file.
  # systemd reads EnvironmentFile as root (before dropping to User=), so
  # keeping this root-owned/0600 (unreadable even by the service's own
  # unprivileged user) is strictly tighter than the container script's
  # user-owned 0600 env file -- there, the file has to be readable by
  # the rootless container user itself; here, root reads it on the
  # service's behalf and the running process never needs read access to
  # the file itself, only to the TUNNEL_TOKEN value systemd already
  # placed in its environment.
  cat >"$env_file" <<EOF
TUNNEL_TOKEN=${token}
EOF
  chown root:root "$env_file"
  chmod 0600 "$env_file"

  cat >"$unit_file" <<EOF
[Unit]
Description=CloudflareD Tunnel Agent (cloudflared) Native Service -- ${instance}
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
User=${u}
Group=${u}
EnvironmentFile=${env_file}
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run
Restart=always
RestartSec=5
TimeoutStartSec=900
LimitNOFILE=250000

# Hardening: this account never needs to bind privileged ports (cloudflared
# only makes outbound connections), write outside its own config dir, or
# gain any new privileges once started.
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${config_dir}

[Install]
WantedBy=multi-user.target
EOF
  chown root:root "$unit_file"
  chmod 0644 "$unit_file"

  info "Reloading systemd and starting ${unit_name}.service"
  systemctl daemon-reload
  systemctl reset-failed "${unit_name}.service" 2>/dev/null || true
  systemctl enable --now "${unit_name}.service"
  systemctl status "${unit_name}.service" -l --no-pager || true
}

# Install a single merged management command mirroring
# cloudflared-container's UX (status/restart/stop/start/upgrade/
# change-token/daemon-reload), but operating on plain systemd system
# services instead of systemd --user Quadlets.
install_management_command() {
  local install_path="/usr/local/sbin/cloudflared-native"

  info "Installing management command: ${install_path}"

  cat >"${install_path}" <<'MANAGE_SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*" >&2; }
warn() { echo "WARN: $*" >&2; }

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo cloudflared-native"; }

resolve_instance() {
  echo
  read -r -p "Manage which instance? [prod/dev] (default: prod): " INSTANCE
  INSTANCE="${INSTANCE:-prod}"
  case "${INSTANCE,,}" in
    prod) UNIT_NAME="cloudflared" ; CONFIG_DIR="/etc/cloudflared" ;;
    dev)  UNIT_NAME="cloudflared-dev" ; CONFIG_DIR="/etc/cloudflared-dev" ;;
    *) die "Unknown instance: ${INSTANCE}. Expected 'prod' or 'dev'." ;;
  esac
  [[ -d "$CONFIG_DIR" ]] || die "No native cloudflared config found at ${CONFIG_DIR} -- has this instance been installed?"
}

action_status()  { systemctl status "${UNIT_NAME}.service" -l --no-pager; }
action_restart() { systemctl restart "${UNIT_NAME}.service"; action_status; }
action_stop()    { systemctl stop "${UNIT_NAME}.service"; }
action_start()   { systemctl start "${UNIT_NAME}.service"; action_status; }

action_upgrade() {
  info "Upgrading cloudflared binary via dnf (repo: pkg.cloudflare.com)"
  dnf upgrade -y cloudflared
  info "Restarting ${UNIT_NAME}.service to pick up the new binary"
  systemctl restart "${UNIT_NAME}.service"
  action_status
}

action_change_token() {
  local env_file="${CONFIG_DIR}/${UNIT_NAME}.env"
  [[ -f "$env_file" ]] || die "Env file not found: ${env_file}"

  echo
  read -r -s -p "Enter new Cloudflare tunnel token for ${INSTANCE} (dashboard-generated): " NEW_TOKEN
  echo
  [[ -n "${NEW_TOKEN}" ]] || die "Tunnel token cannot be empty"

  cat >"$env_file" <<EOF
TUNNEL_TOKEN=${NEW_TOKEN}
EOF
  chown root:root "$env_file"
  chmod 0600 "$env_file"

  info "Token updated; restarting ${UNIT_NAME}.service"
  systemctl restart "${UNIT_NAME}.service"
  action_status
}

action_daemon_reload() { systemctl daemon-reload; }

print_menu() {
  echo
  echo "cloudflared-native management -- instance: ${INSTANCE:-<not selected>}"
  echo "  1) Status"
  echo "  2) Restart"
  echo "  3) Stop"
  echo "  4) Start"
  echo "  5) Upgrade cloudflared binary (dnf upgrade) + restart"
  echo "  6) Change tunnel token"
  echo "  7) systemctl daemon-reload"
  echo "  8) Switch instance (prod/dev)"
  echo "  q) Quit"
}

main() {
  require_root
  resolve_instance

  if [[ "${1:-}" != "" ]]; then
    case "${1}" in
      status)        action_status ;;
      restart)       action_restart ;;
      stop)          action_stop ;;
      start)         action_start ;;
      upgrade)       action_upgrade ;;
      change-token)  action_change_token ;;
      daemon-reload) action_daemon_reload ;;
      *) die "Unknown action: ${1}. Valid actions: status, restart, stop, start, upgrade, change-token, daemon-reload" ;;
    esac
    exit 0
  fi

  while true; do
    print_menu
    read -r -p "Select an option: " choice
    case "$choice" in
      1) action_status ;;
      2) action_restart ;;
      3) action_stop ;;
      4) action_start ;;
      5) action_upgrade ;;
      6) action_change_token ;;
      7) action_daemon_reload ;;
      8) resolve_instance ;;
      q|Q) info "Exiting."; exit 0 ;;
      *) warn "Invalid selection: ${choice}" ;;
    esac
  done
}

main "$@"
MANAGE_SCRIPT_EOF

  chmod 0755 "${install_path}"
  chown root:root "${install_path}"

  info "Management command installed: ${install_path}"
  info "  Run interactively: sudo cloudflared-native"
  info "  Or non-interactively (after prompting for instance): sudo cloudflared-native status|restart|upgrade"
}

main() {
  require_root

  iface_exists eth0 || die "Interface eth0 not found. This script expects eth0 as the primary NIC."

  install_cloudflared_rpm

  #-----------------------------------------------------------------------
  # Base username -- always suffixed "-prod" / "-dev" per instance.
  # Distinct default from the container script's "cloudflared" base, so
  # running both setups side by side never collides on the same account.
  #-----------------------------------------------------------------------
  echo
  read -r -p "Enter base username for native cloudflared service accounts [cloudflared-native]: " BASE_USER
  BASE_USER="${BASE_USER:-cloudflared-native}"

  CF_USER="${BASE_USER}-prod"

  #-----------------------------------------------------------------------
  # Edge interface + routing -- same routes as the container-based setup.
  # No TUNNEL_EDGE_BIND_ADDRESS/TUNNEL_EDGE_IP_VERSION needed here: a
  # native host process already sees every interface and its normal
  # routing table directly, so once the routes below are in place,
  # cloudflared reaches the edge via them automatically.
  #-----------------------------------------------------------------------
  echo
  local edge_iface=""
  while true; do
    read -r -p "Enter the network interface to bind outgoing Cloudflare Edge connections to [eth1]: " edge_iface
    edge_iface="${edge_iface:-eth1}"
    if iface_exists "${edge_iface}"; then
      break
    fi
    warn "Interface not found: ${edge_iface}"
  done

  configure_edge_routing "${edge_iface}"

  #-----------------------------------------------------------------------
  # "prod" instance (always installed)
  #-----------------------------------------------------------------------
  echo
  info "Configuring the 'prod' native cloudflared service (user: ${CF_USER})"
  ensure_native_user "${CF_USER}"

  echo
  read -r -s -p "Enter prod Cloudflare tunnel token (dashboard-generated): " CF_TOKEN
  echo
  [[ -n "${CF_TOKEN}" ]] || die "Tunnel token cannot be empty"

  enable_persistent_journaling
  create_native_service "prod" "${CF_USER}" "${CF_TOKEN}"

  #-----------------------------------------------------------------------
  # "dev" instance (optional) -- always runs as "${BASE_USER}-dev"
  #-----------------------------------------------------------------------
  echo
  read -r -p "Install a second (dev) native cloudflared service? [y/N]: " INSTALL_DEV
  INSTALL_DEV="${INSTALL_DEV:-n}"

  DEV_USER="${BASE_USER}-dev"
  if [[ "${INSTALL_DEV,,}" == "y" ]]; then
    info "Configuring the 'dev' native cloudflared service (user: ${DEV_USER})"
    ensure_native_user "${DEV_USER}"

    echo
    read -r -s -p "Enter dev Cloudflare tunnel token (dashboard-generated): " DEV_TOKEN
    echo
    [[ -n "${DEV_TOKEN}" ]] || die "Tunnel token cannot be empty"

    create_native_service "dev" "${DEV_USER}" "${DEV_TOKEN}"
  else
    info "Skipping dev service installation."
  fi

  #-----------------------------------------------------------------------
  # Single merged management command
  #-----------------------------------------------------------------------
  install_management_command

  info "Done. Verify:"
  echo "  sudo systemctl status cloudflared.service -l --no-pager"
  echo "  journalctl -u cloudflared.service -b --no-pager | tail -n 200"
  echo "  Manage: sudo cloudflared-native (prompts for prod/dev instance)"

  if [[ "${INSTALL_DEV,,}" == "y" ]]; then
    echo "  sudo systemctl status cloudflared-dev.service -l --no-pager"
    echo "  journalctl -u cloudflared-dev.service -b --no-pager | tail -n 200"
  fi

  echo
  info "This installation is independent of any existing Podman/Quadlet cloudflared setup."
  info "Both can run side by side using different tunnels/tokens while you compare and migrate."
}

main "$@"
