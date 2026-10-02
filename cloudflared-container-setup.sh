#!/usr/bin/env bash
#------------------------------------------------------------------------------
# cloudflared-container-setup.sh
# Setup environment on Alma Linux 9 server to run rootless container for
#  CloudflareD tunnel daemon.
#
# Vibe coded with Cloude Sonet 4.6 on July 27, 2026.
#   -- https://www.perplexity.ai/search/914c5f0b-13c3-4605-a520-7f495d7792b9
#
# Implements:
#  1) Install packages: podman, passt
#  2) Prompt once for a base username (default: cloudflared). The prod
#     instance always runs as "<base>-prod" (created if missing):
#      a) cloudflared image tag
#      b) cloudflared tunnel token (dashboard-generated)
#  3) OPTIONAL: prompt to also install a second "dev" instance, which
#     always runs as "<base>-dev" (a distinct account from prod):
#      a) cloudflared image tag
#      b) cloudflared tunnel token
# 3b) Prompt once (shared by both prod and dev) for the network interface
#     the container should use (passed to pasta as "-i <iface>" so pasta
#     copies that interface's address/routes into the container
#     namespace -- see create_quadlet_rootless). Only prompted when the
#     host has more than one physical Ethernet adapter; with exactly one,
#     it's auto-selected with no prompt. The chosen interface is fully
#     handed to the container via pasta and left untouched on the host
#     routing table -- no static routes or ipv4.never-default changes
#     are made to it (see container_iface / create_quadlet_rootless).
#  4) Enable persistent journaling + per-user journals
#  5) Enable boot-start for user services (linger) for each instance's user
#  6) Write /etc/sysctl.d/99-cloudflared.conf to update system limits for ping users and udp socket buffers
#  7) Pull cloudflared image (fully-qualified docker.io/cloudflare/cloudflared:<tag>) per instance
#  8) Create Quadlet base + drop-ins per instance:
#      - prod unit: cloudflared.service (container file: cloudflared.container), user "<base>-prod"
#      - dev unit:  cloudflared-dev.service (container file: cloudflared-dev.container), user "<base>-dev"
#      - dev drop-in files are suffixed "-dev" to keep them unambiguous
#  9) Start each instance's systemd --user service
# 10) Install a single merged /usr/local/sbin/cloudflared-container
#     management command (menu-driven status/restart/upgrade tool; usable
#     by any sudoer). It prompts for the base username and prod/dev
#     instance at startup, and again from its "switch" menu item.
# 11) Write /etc/profile.d/cloudflare-alias.sh (aliases for both instances,
#     if dev was installed)
#
# Notes:
#  - Token is stored on disk in a drop-in file (0600). Protect the user account.
#  - Rootless systemd user services require a working user runtime dir; the script
#    sets XDG_RUNTIME_DIR to avoid "Failed to connect to bus: No medium found".
#  - The "prod" and "dev" instances always run under distinct rootless
#    users, "<base>-prod" and "<base>-dev", derived from one base username.
#  - The container interface (container_iface) is selected once and
#    shared by both instances; it is passed to pasta via
#    "Network=pasta:-i,<iface>,--outbound-if4,<iface>" in each
#    instance's Quadlet .container file only. -i controls what the
#    container's own namespace sees (addresses/routes/gateway copied
#    in via pasta's "--config-net"); --outbound-if4 separately pins
#    pasta's own IPv4 host-side forwarding sockets to the same
#    interface, since -i alone does not do that -- left unset, those
#    sockets would fall back to whatever the host's main routing table
#    prefers (its default route), which can be a different interface
#    entirely. With both set, the container is isolated end-to-end for
#    IPv4: its namespace only knows this interface, and pasta's real
#    host-side traffic for it can only egress this interface. IPv6 is
#    deliberately NOT pinned with --outbound-if6: pasta requires the
#    named interface to have a genuinely usable (global, non-link-
#    local) IPv6 address, and will abort the whole container start
#    with "External interface not usable" if it doesn't -- an
#    interface with only an automatic fe80::/10 link-local address
#    (the common case for an otherwise IPv4-only interface) fails this
#    check outright. The host's own routing table for the interface is
#    never modified.
#
# Usage:
#   sudo bash cloudflared-container-setup.sh
#------------------------------------------------------------------------------

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*" >&2; }
warn() { echo "WARN: $*" >&2; }

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash $0"; }

iface_exists() { ip link show dev "$1" >/dev/null 2>&1; }

# List physical Ethernet adapter names on this host, one per line.
# Scans /sys/class/net for entries with a "device" symlink (i.e.
# backed by a real PCI/virtual-NIC device, not a software construct)
# whose ethtool-reported driver isn't one of the well-known
# virtual/software interface drivers. This deliberately excludes lo,
# veth*, docker/podman bridges, tunnel devices, and tap/pasta devices,
# so only genuine NICs (eth0, eth1, ensX, enpXsY, ...) are counted --
# used by main() to decide whether to prompt for container_iface at all.
list_ethernet_ifaces() {
  local dev sys_path driver
  for sys_path in /sys/class/net/*; do
    [[ -e "${sys_path}/device" ]] || continue
    dev="$(basename "$sys_path")"
    [[ "$dev" == "lo" ]] && continue
    driver="$(basename "$(readlink -f "${sys_path}/device/driver" 2>/dev/null)" 2>/dev/null || true)"
    case "$driver" in
      veth|bridge|tun|tap|dummy|bonding) continue ;;
    esac
    echo "$dev"
  done
}

user_exists() { id "$1" >/dev/null 2>&1; }

ensure_user() {
  local u="$1"
  if user_exists "$u"; then
    info "User exists: $u"
  else
    info "User does not exist, creating: $u"
    useradd -m -s /bin/bash "$u"
  fi
  ensure_subuid_subgid "$u"
}

user_uid() { id -u "$1"; }

# Ensure a user has subuid/subgid ranges allocated for rootless Podman.
# Handles both newly created and pre-existing users. useradd normally
# allocates these automatically via /etc/login.defs for new accounts, but
# pre-existing accounts (the user_exists branch above) are never verified,
# which can cause confusing rootless Podman failures later.
ensure_subuid_subgid() {
  local u="$1"
  local need_subuid=1 need_subgid=1

  grep -Eq "^${u}:" /etc/subuid 2>/dev/null && need_subuid=0
  grep -Eq "^${u}:" /etc/subgid 2>/dev/null && need_subgid=0

  if [[ "$need_subuid" -eq 0 && "$need_subgid" -eq 0 ]]; then
    info "subuid/subgid already allocated for user: $u"
    return 0
  fi

  info "Allocating missing subuid/subgid range(s) for user: $u"
  if command -v usermod >/dev/null 2>&1; then
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$u" 2>/dev/null || true
  fi

  grep -Eq "^${u}:" /etc/subuid 2>/dev/null || echo "${u}:100000:65536" >> /etc/subuid
  grep -Eq "^${u}:" /etc/subgid 2>/dev/null || echo "${u}:100000:65536" >> /etc/subgid

  grep -Eq "^${u}:" /etc/subuid 2>/dev/null || die "Failed to allocate subuid range for user: $u"
  grep -Eq "^${u}:" /etc/subgid 2>/dev/null || die "Failed to allocate subgid range for user: $u"

  info "subuid/subgid ranges confirmed for user: $u (run 'podman system migrate' as $u if the service already ran before this change)"
}

# Run systemctl --user for a given user in non-interactive contexts.
user_systemctl() {
  local u="$1"; shift
  local uid; uid="$(user_uid "$u")"

  mkdir -p "/run/user/${uid}"
  chown "${uid}:${uid}" "/run/user/${uid}"
  chmod 0700 "/run/user/${uid}"

  sudo -u "$u" env XDG_RUNTIME_DIR="/run/user/${uid}" systemctl --user "$@"
}

# Check which transport protocol cloudflared's currently-registered
# tunnel connections actually negotiated, by reading "Registered
# tunnel connection ... protocol=<quic|http2>" lines from this boot's
# journal for unit $2 (as user $1). This reflects the real, live
# connections -- NOT cloudflared's own startup "connectivity
# pre-checks" summary (the "SUMMARY: Environment ready with degraded
# transport..." message), which Cloudflare's own docs describe as
# purely diagnostic and non-blocking: it can warn about a transport
# probe failure (e.g. to region2) even when every connection the
# tunnel actually registers ends up using QUIC. Only the per-connection
# "protocol=" field reflects what's really in use. Prints one line per
# distinct connection (deduplicated by connection ID, keeping the most
# recent registration if a connection re-registered) and warns loudly
# if any is not "quic". Returns 1 if any non-quic connection is found
# or none could be read at all, 0 if every connection found is quic.
check_tunnel_protocol() {
  local u="$1" unit="$2"
  local uid; uid="$(user_uid "$u")"
  local lines
  lines="$(sudo -u "$u" env XDG_RUNTIME_DIR="/run/user/${uid}" \
    journalctl --user -u "$unit" -b --no-pager 2>/dev/null | \
    grep -E 'Registered tunnel connection' || true)"

  if [[ -z "$lines" ]]; then
    warn "No 'Registered tunnel connection' log lines found for ${unit} yet -- cannot verify protocol (service may still be starting; try again in a few seconds)."
    return 1
  fi

  # Keep only the last registration line per connection= ID, in case a
  # connection dropped and re-registered during this boot.
  local parsed
  parsed="$(echo "$lines" | grep -oE 'connection=[^ ]+ event=[0-9]+ ip=[^ ]+ location=[^ ]+ protocol=[a-z0-9]+' | \
    awk -F'connection=| location=| protocol=' '{conn=$2; sub(/ .*/,"",conn); print conn"\t"$0}' | \
    sort -k1,1 -u)"

  if [[ -z "$parsed" ]]; then
    warn "Found 'Registered tunnel connection' lines for ${unit} but could not parse connection/protocol fields -- check journal format: journalctl --user -u ${unit} -b | grep 'Registered tunnel connection'"
    return 1
  fi

  local any_bad=0
  local rest location protocol
  while IFS=$'\t' read -r _conn_field rest; do
    [[ -n "$rest" ]] || continue
    location="$(echo "$rest" | grep -oE 'location=[^ ]+' | sed 's/^location=//')"
    protocol="$(echo "$rest" | grep -oE 'protocol=[a-z0-9]+' | sed 's/^protocol=//')"
    if [[ "$protocol" == "quic" ]]; then
      info "Tunnel connection OK: location=${location:-?} protocol=quic"
    else
      any_bad=1
      warn "Tunnel connection DEGRADED: location=${location:-?} protocol=${protocol:-unknown} (expected quic)"
    fi
  done <<<"$parsed"

  if [[ "$any_bad" -eq 1 ]]; then
    warn "${unit}: at least one tunnel connection is NOT using QUIC. Check firewall/UDP egress on port 7844 for the container's interface."
    return 1
  fi

  info "${unit}: all registered tunnel connections are using QUIC."
  return 0
}

install_packages() {
  info "Installing packages: podman, passt"
  dnf install -y podman passt >/dev/null
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

enable_linger_for_user() {
  local u="$1"
  info "Enabling linger (boot-start for systemd --user) for user: $u"
  loginctl enable-linger "$u"
}

write_sysctl_cloudflared() {
  info "Writing /etc/sysctl.d/99-cloudflared.conf"

  cat >/etc/sysctl.d/99-cloudflared.conf <<'EOF'
# Cloudflared ICMP proxy enablement and QUIC UDP socket buffer ceilings.

# Allow the cloudflared container's nonroot group (65532) to create ICMP echo sockets.
net.ipv4.ping_group_range = 0 65532
net.ipv6.ping_group_range = 0 65532

# QUIC UDP socket buffer ceilings (helps avoid quic-go UDP buffer warnings).
net.core.rmem_max = 12000000
net.core.wmem_max = 12000000
EOF

  sysctl --system >/dev/null
}

pull_cloudflared_image_rootless() {
  local u="$1" tag="$2"
  local homedir
  homedir="$(getent passwd "$u" | awk -F: '{print $6}')"
  [[ -n "$homedir" && -d "$homedir" ]] || die "Could not determine home directory for user: $u"

  info "Pulling image as rootless user $u: docker.io/cloudflare/cloudflared:${tag}"
  sudo -H -u "$u" bash -lc "cd '$homedir' && podman pull 'docker.io/cloudflare/cloudflared:${tag}'"
}

# Install the single merged management command, which prompts for a base
# username and prod/dev instance selection at runtime (and again whenever
# you use the "switch user/instance" menu item), rather than being baked
# to one fixed instance at install time.
# Installs to: /usr/local/sbin/cloudflared-container
install_management_command() {
  local install_path="/usr/local/sbin/cloudflared-container"

  info "Installing cloudflared-container management command to: ${install_path}"

  cat >"${install_path}" <<'MANAGE_SCRIPT_EOF'
#!/usr/bin/env bash
#------------------------------------------------------------------------------
# cloudflared-container
# Menu-driven management tool for rootless cloudflared Podman Quadlet
# deployments created by cloudflared-container-setup.sh.
#
# Manages either the "prod" or "dev" instance, selected at runtime:
#   - prod: user "<base>-prod", unit cloudflared.service
#   - dev:  user "<base>-dev",  unit cloudflared-dev.service
#
# Must be run with sudo/root. Internally switches to the instance user's
# systemd --user session via XDG_RUNTIME_DIR so any sudoer can manage the
# container without needing to log in as that user directly.
#
# Usage:
#   sudo cloudflared-container
#------------------------------------------------------------------------------

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*" >&2; }
warn() { echo "WARN: $*" >&2; }

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo cloudflared-container"; }

user_exists() { id "$1" >/dev/null 2>&1; }

user_uid() { id -u "$1"; }

user_home() { getent passwd "$1" | awk -F: '{print $6}'; }

iface_exists() { ip link show dev "$1" >/dev/null 2>&1; }

# Recover the container's interface name from its Quadlet .container
# file (written by create_quadlet_rootless() as
# "Network=pasta:-i,<iface>,--outbound-if4,<iface>"), without
# re-prompting the operator. Matches only the -i,<iface> token (stops
# at the next comma) so the --outbound-if4 repeat of the same
# interface doesn't get swept into the match. Used by action_upgrade to
# re-apply the same pasta network line after rewriting the image drop-in.
container_iface_from_container_file() {
  [[ -f "$CONTAINER_FILE" ]] || { warn "Container unit not found: ${CONTAINER_FILE}"; return 1; }
  local iface
  # grep -Eo exits non-zero when the pattern isn't found. Under
  # `set -o pipefail` that would otherwise kill this assignment (and,
  # without a guard at the call site, the whole script) before the
  # empty-check below ever runs -- add `|| true` so a genuine "not
  # found" is reported by that check instead of a silent script exit.
  iface="$(grep -Eo 'pasta:-i,[^,[:space:]]+' "$CONTAINER_FILE" 2>/dev/null | sed -E 's/^pasta:-i,//' | head -n1 || true)"
  if [[ -z "$iface" ]]; then
    warn "Could not determine the container's interface from ${CONTAINER_FILE} (no 'pasta:-i,<iface>' network line found)."
    return 1
  fi
  echo "$iface"
}

# Run systemctl --user for a given user, setting XDG_RUNTIME_DIR so that
# any sudo-privileged caller (not just the instance user itself) can
# reach that user's systemd --user session and manage the container.
user_systemctl() {
  local u="$1"; shift
  local uid; uid="$(user_uid "$u")"
  local runtime_dir="/run/user/${uid}"

  if [[ ! -d "$runtime_dir" ]]; then
    mkdir -p "$runtime_dir"
    chown "${uid}:${uid}" "$runtime_dir"
    chmod 0700 "$runtime_dir"
  fi

  sudo -u "$u" env XDG_RUNTIME_DIR="$runtime_dir" systemctl --user "$@"
}

# Run an arbitrary command as the instance user with XDG_RUNTIME_DIR set,
# e.g. for podman commands that talk to the user's rootless Podman socket.
user_run() {
  local u="$1"; shift
  local uid; uid="$(user_uid "$u")"
  local runtime_dir="/run/user/${uid}"
  local homedir; homedir="$(user_home "$u")"

  if [[ ! -d "$runtime_dir" ]]; then
    mkdir -p "$runtime_dir"
    chown "${uid}:${uid}" "$runtime_dir"
    chmod 0700 "$runtime_dir"
  fi

  sudo -H -u "$u" env XDG_RUNTIME_DIR="$runtime_dir" bash -lc "cd '$homedir' && $*"
}

# Check which transport protocol cloudflared's currently-registered
# tunnel connections actually negotiated, by reading "Registered
# tunnel connection ... protocol=<quic|http2>" lines from this boot's
# journal for unit $2 (as user $1). This reflects the real, live
# connections -- NOT cloudflared's own startup "connectivity
# pre-checks" summary (the "SUMMARY: Environment ready with degraded
# transport..." message), which Cloudflare's own docs describe as
# purely diagnostic and non-blocking: it can warn about a transport
# probe failure (e.g. to region2) even when every connection the
# tunnel actually registers ends up using QUIC. Only the per-connection
# "protocol=" field reflects what's really in use. Prints one line per
# distinct connection (deduplicated by connection ID, keeping the most
# recent registration if a connection re-registered) and warns loudly
# if any is not "quic". Returns 1 if any non-quic connection is found
# or none could be read at all, 0 if every connection found is quic.
check_tunnel_protocol() {
  local u="$1" unit="$2"
  local uid; uid="$(user_uid "$u")"
  local lines
  lines="$(sudo -u "$u" env XDG_RUNTIME_DIR="/run/user/${uid}" \
    journalctl --user -u "$unit" -b --no-pager 2>/dev/null | \
    grep -E 'Registered tunnel connection' || true)"

  if [[ -z "$lines" ]]; then
    warn "No 'Registered tunnel connection' log lines found for ${unit} yet -- cannot verify protocol (service may still be starting; try again in a few seconds)."
    return 1
  fi

  # Keep only the last registration line per connection= ID, in case a
  # connection dropped and re-registered during this boot.
  local parsed
  parsed="$(echo "$lines" | grep -oE 'connection=[^ ]+ event=[0-9]+ ip=[^ ]+ location=[^ ]+ protocol=[a-z0-9]+' | \
    awk -F'connection=| location=| protocol=' '{conn=$2; sub(/ .*/,"",conn); print conn"\t"$0}' | \
    sort -k1,1 -u)"

  if [[ -z "$parsed" ]]; then
    warn "Found 'Registered tunnel connection' lines for ${unit} but could not parse connection/protocol fields -- check journal format: journalctl --user -u ${unit} -b | grep 'Registered tunnel connection'"
    return 1
  fi

  local any_bad=0
  local rest location protocol
  while IFS=$'\t' read -r _conn_field rest; do
    [[ -n "$rest" ]] || continue
    location="$(echo "$rest" | grep -oE 'location=[^ ]+' | sed 's/^location=//')"
    protocol="$(echo "$rest" | grep -oE 'protocol=[a-z0-9]+' | sed 's/^protocol=//')"
    if [[ "$protocol" == "quic" ]]; then
      info "Tunnel connection OK: location=${location:-?} protocol=quic"
    else
      any_bad=1
      warn "Tunnel connection DEGRADED: location=${location:-?} protocol=${protocol:-unknown} (expected quic)"
    fi
  done <<<"$parsed"

  if [[ "$any_bad" -eq 1 ]]; then
    warn "${unit}: at least one tunnel connection is NOT using QUIC. Check firewall/UDP egress on port 7844 for the container's interface."
    return 1
  fi

  info "${unit}: all registered tunnel connections are using QUIC."
  return 0
}

# Try to auto-detect a sensible default base username by scanning for any
# existing "<base>-prod" or "<base>-dev" account with a Quadlet container
# file already in place. Falls back to "cloudflared" if nothing is found.
detect_base_user() {
  local pw_home pw_user

  for pw_home in $(getent passwd | awk -F: '{print $6}'); do
    pw_user="$(getent passwd | awk -F: -v h="$pw_home" '$6==h {print $1; exit}')"
    [[ -n "$pw_user" ]] || continue

    if [[ "$pw_user" == *-prod && -f "${pw_home}/.config/containers/systemd/cloudflared.container" ]]; then
      echo "${pw_user%-prod}"
      return 0
    fi
    if [[ "$pw_user" == *-dev && -f "${pw_home}/.config/containers/systemd/cloudflared-dev.container" ]]; then
      echo "${pw_user%-dev}"
      return 0
    fi
  done

  echo "cloudflared"
  return 0
}

# Prompt for the base username and prod/dev instance, then resolve the
# concrete user + unit/container names + Quadlet file paths for it.
# Called at startup and again from the "switch user/instance" menu item.
resolve_instance() {
  local detected_base
  detected_base="$(detect_base_user)"

  read -r -p "Base username for cloudflared [${detected_base}]: " BASE_USER
  BASE_USER="${BASE_USER:-$detected_base}"

  local inst_choice=""
  while [[ "$inst_choice" != "prod" && "$inst_choice" != "dev" ]]; do
    read -r -p "Manage which instance? [prod/dev] (default: prod): " inst_choice
    inst_choice="${inst_choice:-prod}"
    inst_choice="${inst_choice,,}"
    [[ "$inst_choice" == "prod" || "$inst_choice" == "dev" ]] || warn "Please enter 'prod' or 'dev'"
  done
  INSTANCE="$inst_choice"

  if [[ "$INSTANCE" == "prod" ]]; then
    CF_USER="${BASE_USER}-prod"
    UNIT_BASE="cloudflared"
    CONTAINER_NAME="cloudflared"
    IMAGE_DROPIN_NAME="40-image.conf"
    TOKEN_ENV_NAME="cloudflared.env"
  else
    CF_USER="${BASE_USER}-dev"
    UNIT_BASE="cloudflared-dev"
    CONTAINER_NAME="cloudflared-dev"
    IMAGE_DROPIN_NAME="40-image-dev.conf"
    TOKEN_ENV_NAME="cloudflared-dev.env"
  fi

  user_exists "$CF_USER" || die "User '${CF_USER}' does not exist on this system"

  QUADLET_DIR="$(user_home "$CF_USER")/.config/containers/systemd"
  DROPIN_DIR="${QUADLET_DIR}/${UNIT_BASE}.container.d"
  IMAGE_DROPIN="${DROPIN_DIR}/${IMAGE_DROPIN_NAME}"
  TOKEN_ENV_FILE="${DROPIN_DIR}/${TOKEN_ENV_NAME}"
  CONTAINER_FILE="${QUADLET_DIR}/${UNIT_BASE}.container"

  [[ -d "$QUADLET_DIR" ]] || die "Quadlet directory not found for ${CF_USER}: ${QUADLET_DIR}"
}

#------------------------------------------------------------------------------
# 1) Show cloudflared container status
#------------------------------------------------------------------------------
action_status() {
  echo
  info "== podman status (as user: ${CF_USER}) =="
  user_run "$CF_USER" "podman ps -a --filter name=${CONTAINER_NAME}" || warn "Failed to list podman containers"

  echo
  user_run "$CF_USER" "podman inspect ${CONTAINER_NAME} --format 'State: {{.State.Status}}  |  Started: {{.State.StartedAt}}  |  Image: {{.Config.Image}}'" 2>/dev/null || \
    warn "Could not inspect '${CONTAINER_NAME}' container (it may not be running)"

  echo
  info "== systemctl --user status ${UNIT_BASE}.service (as user: ${CF_USER}) =="
  user_systemctl "$CF_USER" status "${UNIT_BASE}.service" -l --no-pager || \
    warn "Could not read systemctl --user status for ${UNIT_BASE}.service"

  echo
  info "== Recent journal (last 30 lines) =="
  if user_systemctl "$CF_USER" list-units "${UNIT_BASE}.service" >/dev/null 2>&1; then
    sudo -u "$CF_USER" env XDG_RUNTIME_DIR="/run/user/$(user_uid "$CF_USER")" \
      journalctl --user -u "${UNIT_BASE}.service" -n 30 --no-pager 2>/dev/null || \
      warn "Could not read recent journal entries"
  else
    warn "${UNIT_BASE}.service unit not found; skipping journal output"
  fi

  echo
  info "== Tunnel connection protocol (live connections, not the startup pre-check) =="
  check_tunnel_protocol "$CF_USER" "${UNIT_BASE}.service" || \
    warn "Protocol check reported an issue -- see above."
}

#------------------------------------------------------------------------------
# 2) Restart the cloudflared container
#------------------------------------------------------------------------------
action_restart() {
  echo
  info "Restarting ${UNIT_BASE}.service for user: ${CF_USER}"
  user_systemctl "$CF_USER" restart "${UNIT_BASE}.service" || die "Failed to restart ${UNIT_BASE}.service"

  sleep 2
  info "Restart complete. Current status:"
  user_systemctl "$CF_USER" status "${UNIT_BASE}.service" -l --no-pager || true
}

#------------------------------------------------------------------------------
# 3) Stop the cloudflared container
#------------------------------------------------------------------------------
action_stop() {
  echo
  info "Stopping ${UNIT_BASE}.service for user: ${CF_USER}"
  user_systemctl "$CF_USER" stop "${UNIT_BASE}.service" || die "Failed to stop ${UNIT_BASE}.service"

  sleep 1
  info "Stop complete. Current status:"
  user_systemctl "$CF_USER" status "${UNIT_BASE}.service" -l --no-pager || true
}

#------------------------------------------------------------------------------
# 4) Start the cloudflared container
#------------------------------------------------------------------------------
action_start() {
  echo
  info "Starting ${UNIT_BASE}.service for user: ${CF_USER}"
  user_systemctl "$CF_USER" start "${UNIT_BASE}.service" || die "Failed to start ${UNIT_BASE}.service"

  sleep 2
  info "Start complete. Current status:"
  user_systemctl "$CF_USER" status "${UNIT_BASE}.service" -l --no-pager || true
}

# Ensure the Quadlet .container unit has a complete pasta Network= line:
#   Network=pasta:-i,<iface>,--outbound-if4,<iface>
# -i alone only controls what the container's own namespace sees; it
# does not pin pasta's host-side forwarding sockets to that interface
# -- without --outbound-if4, those sockets fall back to whatever the
# host's main routing table prefers (i.e. its default route), which
# can silently egress a different interface than the one the operator
# chose. --outbound-if6 is deliberately NOT added: pasta requires the
# named interface to have a genuinely usable (global, non-link-local)
# IPv6 address, and aborts the whole container start with "External
# interface not usable" if it only has the automatic fe80::/10
# link-local address -- the common case for an otherwise IPv4-only
# interface. Older installs (created before this fix, or before pasta
# networking existed at all) may have no Network= line, or an
# -i-only line missing the --outbound-if4 pinning -- both are
# corrected here. Called from action_upgrade so existing deployments
# get the fix without a full reinstall; also re-applies the existing
# line unchanged when it's already correct, so repeated upgrades are
# idempotent.
repair_pasta_network_line() {
  [[ -f "$CONTAINER_FILE" ]] || { warn "Container unit not found, skipping network fix: ${CONTAINER_FILE}"; return 0; }

  local existing_network_line
  existing_network_line="$(grep -E '^Network=pasta:' "$CONTAINER_FILE" 2>/dev/null || true)"

  local iface=""
  iface="$(container_iface_from_container_file 2>/dev/null || true)"

  if [[ -z "$iface" ]]; then
    if [[ -n "$existing_network_line" ]]; then
      info "Existing Network= line found (${existing_network_line}); leaving it as-is."
      return 0
    fi
    read -r -p "Enter the network interface the container should bind to [skip]: " iface
    [[ -n "$iface" ]] || { warn "No interface given; not adding a Network= line."; return 0; }
    iface_exists "$iface" || die "Interface not found: ${iface}"
  fi

  local desired_network_line="Network=pasta:-i,${iface},--outbound-if4,${iface}"
  if [[ "$existing_network_line" == "$desired_network_line" ]]; then
    info "Network= line already correct (${desired_network_line})."
    return 0
  fi

  info "Setting ${desired_network_line} in ${CONTAINER_FILE}"
  if [[ -n "$existing_network_line" ]]; then
    sed -i -E "s#^Network=pasta:.*#${desired_network_line}#" "$CONTAINER_FILE"
  else
    sed -i "/^Exec=/a ${desired_network_line}" "$CONTAINER_FILE"
  fi
}

# Ensure the Quadlet .container unit's Exec= line pins the tunnel
# transport to "--protocol quic". Installs created before this flag was
# added have no such option in their Exec= line at all; called from
# action_upgrade so existing deployments pick it up without a full
# uninstall/reinstall.
repair_exec_protocol_flag() {
  [[ -f "$CONTAINER_FILE" ]] || { warn "Container unit not found, skipping protocol flag fix: ${CONTAINER_FILE}"; return 0; }

  local existing_exec_line
  existing_exec_line="$(grep -E '^Exec=' "$CONTAINER_FILE" 2>/dev/null || true)"
  [[ -n "$existing_exec_line" ]] || { warn "No Exec= line found in ${CONTAINER_FILE}; skipping protocol flag fix."; return 0; }

  if [[ "$existing_exec_line" == *"--protocol"* ]]; then
    info "Exec= line already has a --protocol flag (${existing_exec_line}); leaving it as-is."
    return 0
  fi

  local desired_exec_line="${existing_exec_line/--no-autoupdate/--no-autoupdate --protocol quic}"
  if [[ "$desired_exec_line" == "$existing_exec_line" ]]; then
    # --no-autoupdate wasn't present to anchor on; append the flag right
    # after "Exec=tunnel" instead.
    desired_exec_line="${existing_exec_line/Exec=tunnel/Exec=tunnel --protocol quic}"
  fi

  info "Setting ${desired_exec_line} in ${CONTAINER_FILE}"
  sed -i -E "s#^Exec=.*#${desired_exec_line}#" "$CONTAINER_FILE"
}

#------------------------------------------------------------------------------
# 5) Upgrade the cloudflared container
#------------------------------------------------------------------------------
action_upgrade() {
  [[ -f "$IMAGE_DROPIN" ]] || die "Image drop-in not found: ${IMAGE_DROPIN}"

  local current_tag=""
  # `|| true` guards against grep's non-zero "no match" exit under
  # `set -o pipefail` silently killing the script (see comment on
  # resolve_ipv4_addresses for the same failure mode).
  current_tag="$(grep -E '^Image=' "$IMAGE_DROPIN" 2>/dev/null | sed -E 's#^Image=docker\.io/cloudflare/cloudflared:##' || true)"

  echo
  info "Current image tag: ${current_tag:-unknown}"
  read -r -p "Enter the new cloudflared image tag (e.g., 2025.11.1): " NEW_TAG
  [[ -n "$NEW_TAG" ]] || die "Image tag cannot be empty"

  if [[ "$NEW_TAG" == "$current_tag" ]]; then
    read -r -p "New tag matches the current tag (${current_tag}). Continue anyway? [y/N]: " confirm_same
    [[ "${confirm_same,,}" == "y" ]] || { info "Upgrade cancelled."; return 0; }
  fi

  local new_image="docker.io/cloudflare/cloudflared:${NEW_TAG}"

  info "Pulling new image as user ${CF_USER}: ${new_image}"
  user_run "$CF_USER" "podman pull '${new_image}'" || die "Failed to pull image: ${new_image}"

  info "Updating image drop-in: ${IMAGE_DROPIN}"
  {
    echo "[Container]"
    echo "Image=${new_image}"
    echo "Pull=never"
  } >"${IMAGE_DROPIN}"
  chown "${CF_USER}:${CF_USER}" "${IMAGE_DROPIN}"
  chmod 0600 "${IMAGE_DROPIN}"

  repair_pasta_network_line
  repair_exec_protocol_flag

  info "Reloading systemd --user daemon for user: ${CF_USER}"
  user_systemctl "$CF_USER" daemon-reload || die "Failed to reload user daemon"

  echo
  read -r -p "Restart ${UNIT_BASE}.service now to apply the new image? [Y/n]: " do_restart
  do_restart="${do_restart:-y}"
  if [[ "${do_restart,,}" == "y" ]]; then
    user_systemctl "$CF_USER" restart "${UNIT_BASE}.service" || die "Failed to restart ${UNIT_BASE}.service after upgrade"
    sleep 2
    info "Upgrade complete. Current status:"
    user_systemctl "$CF_USER" status "${UNIT_BASE}.service" -l --no-pager || true
  else
    warn "Image updated but service not restarted. The old container keeps running the previous image until restarted."
  fi
}

#------------------------------------------------------------------------------
# 6) Change the tunnel token
#------------------------------------------------------------------------------
action_change_token() {
  [[ -f "$TOKEN_ENV_FILE" ]] || die "Token env file not found: ${TOKEN_ENV_FILE}"

  echo
  warn "The new token will be visible on screen while typing."
  read -r -p "Enter the new tunnel token: " NEW_TOKEN
  [[ -n "$NEW_TOKEN" ]] || die "Token cannot be empty"

  info "Updating token file: ${TOKEN_ENV_FILE}"
  cat >"${TOKEN_ENV_FILE}" <<EOF
TUNNEL_TOKEN=${NEW_TOKEN}
EOF
  chown "${CF_USER}:${CF_USER}" "${TOKEN_ENV_FILE}"
  chmod 0600 "${TOKEN_ENV_FILE}"

  info "Reloading systemd --user daemon for user: ${CF_USER}"
  user_systemctl "$CF_USER" daemon-reload || die "Failed to reload user daemon"

  echo
  read -r -p "Restart ${UNIT_BASE}.service now to apply the new token? [Y/n]: " do_restart
  do_restart="${do_restart:-y}"
  if [[ "${do_restart,,}" == "y" ]]; then
    user_systemctl "$CF_USER" restart "${UNIT_BASE}.service" || die "Failed to restart ${UNIT_BASE}.service after token change"
    sleep 2
    info "Token updated. Current status:"
    user_systemctl "$CF_USER" status "${UNIT_BASE}.service" -l --no-pager || true
  else
    warn "Token updated but service not restarted. The old token stays active until restarted."
  fi
}

#------------------------------------------------------------------------------
# 7) Reload the systemd --user daemon
#------------------------------------------------------------------------------
action_daemon_reload() {
  echo
  info "Running systemctl --user daemon-reload for user: ${CF_USER}"
  user_systemctl "$CF_USER" daemon-reload || die "Failed to reload user daemon"
  info "Daemon reload complete."
}

print_menu() {
  echo
  echo "=========================================="
  echo " cloudflared-container management (instance: ${INSTANCE}, user: ${CF_USER})"
  echo "=========================================="
  echo "  1) Show status"
  echo "  2) Restart container"
  echo "  3) Stop container"
  echo "  4) Start container"
  echo "  5) Upgrade container (change image tag, repair pasta network line and protocol flag)"
  echo "  6) Change tunnel token"
  echo "  7) Reload systemd --user daemon"
  echo "  8) Switch base username / prod-dev instance"
  echo "  q) Quit"
  echo
}

main() {
  require_root
  resolve_instance

  # Allow non-interactive one-shot invocation, still prompting first for
  # base username / instance:
  #   cloudflared-container status|restart|stop|start|upgrade|change-token|daemon-reload
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
  info "  Run interactively: sudo cloudflared-container"
  info "  Or non-interactively (after prompting for base username/instance): sudo cloudflared-container status|restart|upgrade"
}

# Create the Quadlet unit + drop-ins for one cloudflared instance.
#   instance: "prod" or "dev"
#     - prod uses unit basename "cloudflared" (unit: cloudflared.service)
#     - dev uses unit basename "cloudflared-dev" (unit: cloudflared-dev.service)
#       and all drop-in filenames are suffixed "-dev"
#   container_iface: the host interface the container is isolated to.
#     Passed to pasta via two independent flags, both required:
#       -i <iface>              -- which host interface pasta reads
#                                   addresses/routes/gateway FROM to
#                                   populate the container's own
#                                   network namespace (what the
#                                   container itself sees via its
#                                   "ip route").
#       --outbound-if4 <iface>  -- which host interface pasta's own
#                                   IPv4 forwarding sockets actually
#                                   bind to and egress on, on the HOST
#                                   side.
#     -i alone does not pin pasta's host-side sockets to that
#     interface -- left unset, those sockets fall back to whatever the
#     host's main routing table prefers (i.e. its default route, which
#     may be a different interface entirely). Setting --outbound-if4
#     to the same interface as -i closes that gap, so the container is
#     genuinely isolated end-to-end for IPv4: its own namespace only
#     knows about this interface, AND pasta's real host-side traffic
#     for it can only egress this interface, never the host's default
#     route. --outbound-if6 is deliberately NOT set: pasta requires
#     the named interface to have a genuinely usable (global,
#     non-link-local) IPv6 address, and aborts the ENTIRE container
#     start with "External interface not usable" if it only has the
#     automatic fe80::/10 link-local address every interface gets --
#     the common case for an otherwise IPv4-only interface (confirmed
#     on this deployment's eth1). Same value used for both prod and
#     dev (selected once in main()). Without an explicit Network=
#     line, pasta defaults to the host's main/default-route interface,
#     which is why this is always set
#     explicitly rather than left implicit.
create_quadlet_rootless() {
  local instance="$1" u="$2" tag="$3" token="$4" container_iface="$5"
  local homedir quadlet_dir unit_base container_name container_file dropin_dir
  local image_dropin icmp_dropin token_dropin env_file suffix

  homedir="$(getent passwd "$u" | awk -F: '{print $6}')"
  [[ -n "$homedir" && -d "$homedir" ]] || die "Could not determine home directory for user: $u"

  if [[ "$instance" == "prod" ]]; then
    unit_base="cloudflared"
    container_name="cloudflared"
    suffix=""
  else
    unit_base="cloudflared-dev"
    container_name="cloudflared-dev"
    suffix="-dev"
  fi

  quadlet_dir="${homedir}/.config/containers/systemd"
  container_file="${quadlet_dir}/${unit_base}.container"
  dropin_dir="${quadlet_dir}/${unit_base}.container.d"
  image_dropin="${dropin_dir}/40-image${suffix}.conf"
  icmp_dropin="${dropin_dir}/50-icmp${suffix}.conf"
  token_dropin="${dropin_dir}/50-token${suffix}.conf"
  env_file="${dropin_dir}/cloudflared${suffix}.env"

  info "Creating Quadlet files for instance '${instance}' (unit: ${unit_base}.service) under user $u"

  install -d -m 0700 -o "$u" -g "$u" "$quadlet_dir"
  install -d -m 0700 -o "$u" -g "$u" "$dropin_dir"

  cat >"$container_file" <<EOF
[Unit]
Description=CloudflareD Tunnel Agent (cloudflared) Container -- ${instance}
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=${container_name}
Exec=tunnel --no-autoupdate --protocol quic run
Network=pasta:-i,${container_iface},--outbound-if4,${container_iface}

[Service]
Restart=always
TimeoutStartSec=900

[Install]
WantedBy=default.target
EOF
  chown "$u:$u" "$container_file"
  chmod 0600 "$container_file"

  cat >"$image_dropin" <<EOF
[Container]
Image=docker.io/cloudflare/cloudflared:${tag}
Pull=never
EOF
  chown "$u:$u" "$image_dropin"
  chmod 0600 "$image_dropin"

  cat >"$icmp_dropin" <<EOF
[Container]
Sysctl="net.ipv4.ping_group_range=65532 65532"
EOF
  chown "$u:$u" "$icmp_dropin"
  chmod 0600 "$icmp_dropin"

  # Pass the tunnel token via environment rather than as a CLI argument.
  # A --token CLI arg would be visible to any local user via `ps` or
  # /proc/<pid>/cmdline (both world-readable), regardless of file
  # permissions on this drop-in. Env vars land in /proc/<pid>/environ,
  # which is readable only by the owning user and root.
  cat >"$env_file" <<EOF
TUNNEL_TOKEN=${token}
EOF
  chown "$u:$u" "$env_file"
  chmod 0600 "$env_file"

  cat >"$token_dropin" <<EOF
[Container]
EnvironmentFile=${env_file}

[Service]
LimitNOFILE=250000
EOF
  chown "$u:$u" "$token_dropin"
  chmod 0600 "$token_dropin"

  info "Reloading generator and starting service as user $u"
  user_systemctl "$u" daemon-reload
  user_systemctl "$u" reset-failed "${unit_base}.service" || true
  user_systemctl "$u" start "${unit_base}.service"
  user_systemctl "$u" status "${unit_base}.service" -l --no-pager || true
}

# Append profile.d alias definitions for one instance to the shared
# aliases file. unit_base/alias_suffix let prod keep unsuffixed alias
# names (cloudflared-status) while dev gets "-dev" suffixed names
# (cloudflared-status-dev), avoiding collisions when both are installed.
write_cloudflared_aliases() {
  local instance_user="$1" unit_base="$2" alias_suffix="$3"

  cat >>/etc/profile.d/cloudflared-aliases.sh <<EOF
alias cloudflared-status${alias_suffix}='sudo -u ${instance_user} XDG_RUNTIME_DIR=/run/user/\$(id -u ${instance_user}) systemctl --user status ${unit_base}.service'
alias cloudflared-stop${alias_suffix}='sudo -u ${instance_user} XDG_RUNTIME_DIR=/run/user/\$(id -u ${instance_user}) systemctl --user stop ${unit_base}.service'
alias cloudflared-start${alias_suffix}='sudo -u ${instance_user} XDG_RUNTIME_DIR=/run/user/\$(id -u ${instance_user}) systemctl --user start ${unit_base}.service'
alias cloudflared-restart${alias_suffix}='sudo -u ${instance_user} XDG_RUNTIME_DIR=/run/user/\$(id -u ${instance_user}) systemctl --user restart ${unit_base}.service'
EOF
}

main() {
  require_root

  iface_exists eth0 || die "Interface eth0 not found. This script expects eth0 as the primary NIC."

  install_packages

  #-----------------------------------------------------------------------
  # Base username -- always suffixed "-prod" / "-dev" per instance
  #-----------------------------------------------------------------------
  echo
  read -r -p "Enter base username for cloudflared (rootless) [cloudflared]: " BASE_USER
  BASE_USER="${BASE_USER:-cloudflared}"

  CF_USER="${BASE_USER}-prod"

  #-----------------------------------------------------------------------
  # Container interface -- same value used for both prod and dev. This
  # interface is handed entirely to the container via pasta ("-i
  # <iface>"); the host's own routing table for it is never touched.
  # Only prompted when the host has more than one physical Ethernet
  # adapter -- with exactly one, it's auto-selected and reported.
  #-----------------------------------------------------------------------
  echo
  local container_iface=""
  local -a eth_ifaces=()
  while IFS= read -r iface_line; do
    [[ -n "$iface_line" ]] && eth_ifaces+=("$iface_line")
  done < <(list_ethernet_ifaces)

  if [[ "${#eth_ifaces[@]}" -eq 1 ]]; then
    container_iface="${eth_ifaces[0]}"
    info "Only one physical Ethernet adapter found (${container_iface}); using it for the container with no prompt."
  else
    if [[ "${#eth_ifaces[@]}" -eq 0 ]]; then
      warn "Could not detect any physical Ethernet adapters; falling back to a manual prompt."
    else
      info "Detected Ethernet adapters: ${eth_ifaces[*]}"
    fi
    while true; do
      read -r -p "Enter the network interface the container should use [eth0]: " container_iface
      container_iface="${container_iface:-eth0}"
      if iface_exists "${container_iface}"; then
        break
      fi
      warn "Interface not found: ${container_iface}"
    done
  fi

  info "Container will be isolated to interface: ${container_iface} (pasta -i ${container_iface}; host routing table left unchanged)"

  #-----------------------------------------------------------------------
  # "prod" instance (always installed)
  #-----------------------------------------------------------------------
  echo
  info "Configuring the 'prod' cloudflared container (user: ${CF_USER})"
  ensure_user "${CF_USER}"

  read -r -p "Enter prod cloudflared image tag (e.g., 2025.11.1): " CF_TAG
  [[ -n "${CF_TAG}" ]] || die "Image tag cannot be empty"

  echo
  read -r -s -p "Enter prod Cloudflare tunnel token (dashboard-generated): " CF_TOKEN
  echo
  [[ -n "${CF_TOKEN}" ]] || die "Tunnel token cannot be empty"

  enable_persistent_journaling
  write_sysctl_cloudflared

  enable_linger_for_user "${CF_USER}"
  pull_cloudflared_image_rootless "${CF_USER}" "${CF_TAG}"
  create_quadlet_rootless "prod" "${CF_USER}" "${CF_TAG}" "${CF_TOKEN}" "${container_iface}"

  info "Waiting for prod tunnel connections to register before checking protocol..."
  sleep 10
  check_tunnel_protocol "${CF_USER}" "cloudflared.service" || \
    warn "PROD: one or more tunnel connections established using http2 instead of quic. Run 'sudo cloudflared-container' (option 1, status) to re-check, and see WARN lines above for which region/connection degraded -- this usually means outbound UDP/7844 is blocked for ${container_iface}."

  #-----------------------------------------------------------------------
  # "dev" instance (optional) -- always runs as "${BASE_USER}-dev"
  #-----------------------------------------------------------------------
  echo
  read -r -p "Install a second (dev) cloudflared container? [y/N]: " INSTALL_DEV
  INSTALL_DEV="${INSTALL_DEV:-n}"

  DEV_USER="${BASE_USER}-dev"
  if [[ "${INSTALL_DEV,,}" == "y" ]]; then
    info "Configuring the 'dev' cloudflared container (user: ${DEV_USER})"
    ensure_user "${DEV_USER}"

    read -r -p "Enter dev cloudflared image tag (e.g., 2025.11.1): " DEV_TAG
    [[ -n "${DEV_TAG}" ]] || die "Image tag cannot be empty"

    echo
    read -r -s -p "Enter dev Cloudflare tunnel token (dashboard-generated): " DEV_TOKEN
    echo
    [[ -n "${DEV_TOKEN}" ]] || die "Tunnel token cannot be empty"

    enable_linger_for_user "${DEV_USER}"
    pull_cloudflared_image_rootless "${DEV_USER}" "${DEV_TAG}"
    create_quadlet_rootless "dev" "${DEV_USER}" "${DEV_TAG}" "${DEV_TOKEN}" "${container_iface}"

    info "Waiting for dev tunnel connections to register before checking protocol..."
    sleep 10
    check_tunnel_protocol "${DEV_USER}" "cloudflared-dev.service" || \
      warn "DEV: one or more tunnel connections established using http2 instead of quic. Run 'sudo cloudflared-container' (option 1, status) to re-check, and see WARN lines above for which region/connection degraded -- this usually means outbound UDP/7844 is blocked for ${container_iface}."
  else
    info "Skipping dev container installation."
  fi

  #-----------------------------------------------------------------------
  # Single merged management command (covers both prod and dev)
  #-----------------------------------------------------------------------
  install_management_command

  #-----------------------------------------------------------------------
  # Shared profile.d aliases
  #-----------------------------------------------------------------------
  info "Installing cloudflared aliases for user ${CF_USER}"
  : >/etc/profile.d/cloudflared-aliases.sh
  echo 'export PATH="/usr/local/sbin:$PATH"' >>/etc/profile.d/cloudflared-aliases.sh
  write_cloudflared_aliases "${CF_USER}" "cloudflared" ""

  if [[ "${INSTALL_DEV,,}" == "y" ]]; then
    info "Installing dev cloudflared aliases for user ${DEV_USER}"
    write_cloudflared_aliases "${DEV_USER}" "cloudflared-dev" "-dev"
  fi

  chmod 0644 /etc/profile.d/cloudflared-aliases.sh

  info "Done. Verify after reboot:"
  echo "  sudo -u ${CF_USER} env XDG_RUNTIME_DIR=/run/user/\$(id -u ${CF_USER}) systemctl --user status cloudflared.service -l --no-pager"
  echo "  journalctl --user -u cloudflared.service -b --no-pager | tail -n 200"
  echo "  Manage: sudo cloudflared-container (prompts for base username '${BASE_USER}' and prod/dev)"

  if [[ "${INSTALL_DEV,,}" == "y" ]]; then
    echo "  sudo -u ${DEV_USER} env XDG_RUNTIME_DIR=/run/user/\$(id -u ${DEV_USER}) systemctl --user status cloudflared-dev.service -l --no-pager"
    echo "  journalctl --user -u cloudflared-dev.service -b --no-pager | tail -n 200"
  fi
}

main "$@"
