#!/usr/bin/env bash
#------------------------------------------------------------------------------
# cloudflared-container-uninstall.sh
# Reverse every change made by cloudflared-container-setup.sh on an
# Alma Linux 9 server running rootless cloudflared via Podman Quadlet.
#
# This script mirrors cloudflared-container-setup.sh step for step and
# reverses only what that script actually does. You are prompted once for
# the base username; the "prod" instance (user "<base>-prod") is always
# processed, and the "dev" instance (user "<base>-dev", cloudflared-dev.service
# and its -dev-suffixed Quadlet/drop-in files) is processed too if you
# confirm it was installed:
#  1) Stop, disable, and remove the cloudflared[-dev].service + Quadlet
#     files (base container unit, image/icmp/token drop-ins, token env file)
#  2) Remove the cloudflared[-dev] container and pulled image(s)
#  3) Disable linger for the instance's user
#  4) Remove /etc/sysctl.d/99-cloudflared.conf (ping_group_range, UDP buffers)
#     -- shared by both instances, removed once
#  5) Policy routing cleanup (legacy) -- ALWAYS runs and auto-detects
#     whatever is present, regardless of which interface it's on or
#     whether setup put it there. No prompt needed; every step is a
#     no-op if nothing matches. Covers an older setup script design
#     (ip-rule/route-table based) kept here for hosts set up before the
#     current nmcli-static-route design (see 5b):
#      - remove any ip rule that routes into table "origin"
#      - remove any RFC1918 routes from route-table "origin"
#      - remove the "origin" entry from /etc/iproute2/rt_tables
#      - remove any /etc/sysconfig/network-scripts/route-* or rule-*
#        persistence file that references the origin table
#      - restore any NetworkManager profile with ipv4.never-default yes
#        (re-enable default-route eligibility; gateway is not restored
#        since setup does not record the original value)
#  5b) Cloudflare Tunnel edge static routes cleanup -- ALWAYS runs.
#     Reverses the current configure_edge_routing() design: auto-detects
#     the NetworkManager connection with ipv4.never-default=yes (the
#     edge interface's connection), clears all of its ipv4.routes
#     entries (the Cloudflare Tunnel edge /24s, 1.1.1.1/1.0.0.1, and
#     the resolved api.cloudflare.com / cfd-features.argotunnel.com
#     addresses), and resets ipv4.never-default to no. Gateway is not
#     restored since setup does not record the original value.
#  6) Remove /etc/systemd/journald.conf.d/99-persistent.conf (persistent
#     journaling) and restart journald if requested
#  7) Remove /etc/profile.d/cloudflared-aliases.sh (contains both prod and
#     dev aliases, if dev was installed; removed once)
#  8) Remove the single merged /usr/local/sbin/cloudflared-container
#     management command (also cleans up legacy per-instance
#     -prod/-dev named commands left by older setup script versions)
#  9) Remove subuid/subgid ranges this setup allocated (only the range the
#     setup script adds: 100000-165535), IF each instance's user account is
#     not being kept for other purposes. If prod and dev share the same
#     user, this is only done once for that user.
# 10) OPTIONAL: remove the instance user account(s) and home directory
#
# What this script deliberately does NOT touch:
#  - Packages installed by setup (podman, passt) -- shared system packages,
#    not safe to assume they're unused elsewhere. Removal command is printed
#    at the end for you to run manually if desired.
#  - eth0's default route / gateway -- setup never modifies eth0, so
#    uninstall never touches it either.
#  - The edge connection's original gateway value -- setup does not
#    record it before ipv4.never-default strips it, so it isn't
#    restored; set it manually afterward if the interface still needs
#    a default route: nmcli con mod <connection> ipv4.gateway <ip>
#
# Usage:
#   sudo bash cloudflared-container-uninstall.sh
#------------------------------------------------------------------------------

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*" >&2; }
warn() { echo "WARN: $*" >&2; }

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash $0"; }

user_exists() { id "$1" >/dev/null 2>&1; }

user_uid() { id -u "$1"; }

is_systemctl_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# Run systemctl --user for a given user in non-interactive contexts.
# Mirrors user_systemctl() in the setup script.
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

user_service_exists() {
  local u="$1" service="$2"
  local uid; uid="$(user_uid "$u")"
  local runtime_dir="/run/user/${uid}"

  sudo -u "$u" env XDG_RUNTIME_DIR="$runtime_dir" \
    systemctl --user list-unit-files "$service" 2>/dev/null | grep -q "$service"
}

user_home() {
  local u="$1"
  getent passwd "$u" | awk -F: '{print $6}'
}

#------------------------------------------------------------------------------
# 1) Stop, disable, and remove the cloudflared service + Quadlet files
#    instance: "prod" (unit base "cloudflared") or "dev" (unit base
#    "cloudflared-dev", all drop-ins suffixed "-dev")
#------------------------------------------------------------------------------
stop_disable_and_remove_service() {
  local instance="$1" u="$2"
  local unit_base
  [[ "$instance" == "prod" ]] && unit_base="cloudflared" || unit_base="cloudflared-dev"

  if ! user_exists "$u"; then
    warn "User $u does not exist; skipping ${instance} service stop/removal"
    return 0
  fi

  info "Stopping and disabling ${unit_base}.service (instance: ${instance}) for user: $u"

  if user_service_exists "$u" "${unit_base}.service"; then
    user_systemctl "$u" stop "${unit_base}.service" 2>/dev/null || warn "Failed to stop ${unit_base}.service"
    user_systemctl "$u" disable "${unit_base}.service" 2>/dev/null || warn "Failed to disable ${unit_base}.service"
  else
    warn "${unit_base}.service not found for user $u (may already be removed)"
  fi

  local homedir quadlet_dir
  homedir="$(user_home "$u")"
  if [[ -z "$homedir" || ! -d "$homedir" ]]; then
    warn "Could not determine home directory for user: $u; skipping Quadlet file removal"
    return 0
  fi

  quadlet_dir="${homedir}/.config/containers/systemd"

  if [[ -d "${quadlet_dir}/${unit_base}.container.d" || -f "${quadlet_dir}/${unit_base}.container" ]]; then
    info "Removing Quadlet files for instance '${instance}' from: $quadlet_dir"
    # Matches exactly what create_quadlet_rootless() in setup writes:
    #   <unit_base>.container, <unit_base>.container.d/{40-image,50-icmp,50-token}[-dev].conf,
    #   <unit_base>.container.d/cloudflared[-dev].env
    rm -f "${quadlet_dir}/${unit_base}.container"
    rm -rf "${quadlet_dir}/${unit_base}.container.d"
  else
    warn "Quadlet files for instance '${instance}' not found under $quadlet_dir (may already be removed)"
  fi

  info "Reloading systemd --user daemon for: $u"
  user_systemctl "$u" daemon-reload 2>/dev/null || warn "Failed to reload user daemon for $u"
  user_systemctl "$u" reset-failed "${unit_base}.service" 2>/dev/null || true
}

#------------------------------------------------------------------------------
# 2) Remove the cloudflared container and pulled image(s)
#    instance: "prod" (container name "cloudflared") or "dev" (container
#    name "cloudflared-dev")
#------------------------------------------------------------------------------
remove_container_and_image() {
  local instance="$1" u="$2" tag="${3:-}"
  local container_name
  [[ "$instance" == "prod" ]] && container_name="cloudflared" || container_name="cloudflared-dev"

  if ! user_exists "$u"; then
    warn "User $u does not exist; skipping ${instance} container/image removal"
    return 0
  fi

  local homedir
  homedir="$(user_home "$u")"
  if [[ -z "$homedir" || ! -d "$homedir" ]]; then
    warn "Could not determine home directory for user: $u; skipping container/image removal"
    return 0
  fi

  info "Removing ${container_name} container for user: $u"
  sudo -H -u "$u" bash -lc "cd '$homedir' && podman rm -f ${container_name}" >/dev/null 2>&1 || \
    warn "No running/stopped '${container_name}' container found (or removal failed)"

  info "Removing pulled cloudflared image(s) for user: $u (instance: ${instance})"
  if [[ -n "$tag" ]]; then
    sudo -H -u "$u" bash -lc "cd '$homedir' && podman rmi -f 'docker.io/cloudflare/cloudflared:${tag}'" >/dev/null 2>&1 || \
      warn "Image docker.io/cloudflare/cloudflared:${tag} not found (or removal failed)"
  else
    sudo -H -u "$u" bash -lc "
      cd '$homedir'
      ids=\$(podman images 'docker.io/cloudflare/cloudflared' -q)
      if [[ -n \"\$ids\" ]]; then
        podman rmi -f \$ids
      fi
    " >/dev/null 2>&1 || warn "No cloudflared images found (or removal failed)"
  fi
}

#------------------------------------------------------------------------------
# 3) Disable linger for the cloudflared user
#------------------------------------------------------------------------------
disable_linger_for_user() {
  local u="$1"

  if ! user_exists "$u"; then
    warn "User $u does not exist; skipping linger disable"
    return 0
  fi

  info "Disabling linger for user: $u"
  loginctl disable-linger "$u" 2>/dev/null || warn "Failed to disable linger for $u (may already be disabled)"
}

#------------------------------------------------------------------------------
# 4) Remove /etc/sysctl.d/99-cloudflared.conf
#------------------------------------------------------------------------------
remove_sysctl_cloudflared() {
  local sysctl_file="/etc/sysctl.d/99-cloudflared.conf"

  if [[ -f "$sysctl_file" ]]; then
    info "Removing sysctl configuration: $sysctl_file"
    rm -f "$sysctl_file"
    sysctl --system >/dev/null 2>&1 || warn "Failed to reload sysctl settings after removal"
  else
    warn "sysctl configuration not found: $sysctl_file (may already be removed)"
  fi
}

#------------------------------------------------------------------------------
# 5) Remove any leftover dual-NIC policy routing, unconditionally.
#
# This does NOT depend on the setup script having created these -- it
# actively detects and removes anything matching the "origin" policy
# routing pattern (ip rules, routes, rt_tables entry, persistence files,
# and NetworkManager never-default flags), regardless of which interface
# they reference or whether the interface still exists. Safe to run even
# if none of this is present; every removal step is a no-op when nothing
# matches.
#------------------------------------------------------------------------------
remove_policy_routing_two_nic() {
  local rt_name="origin"
  local rt_id="100"
  local rt_tables_file="/etc/iproute2/rt_tables"
  local found_any=0

  info "Scanning for leftover policy routing (table '${rt_name}')"

  # Remove every ip rule that references the origin table, regardless of
  # source address or priority (handles rules left behind by any prior
  # version of the setup script, or ones edited by hand).
  local rule_line
  while IFS= read -r rule_line; do
    [[ -n "$rule_line" ]] || continue
    found_any=1
    info "Removing ip rule: ${rule_line}"
    # shellcheck disable=SC2086
    ip rule del ${rule_line} 2>/dev/null || warn "Failed to remove ip rule: ${rule_line}"
  done < <(ip -4 rule show 2>/dev/null | grep -w "lookup ${rt_name}" | sed -E 's/^[0-9]+:[[:space:]]*//')

  # Remove every route in the origin table, on whatever interface(s) it
  # was created for (not hardcoded to eth1).
  local route_line
  while IFS= read -r route_line; do
    [[ -n "$route_line" ]] || continue
    found_any=1
    info "Removing route from table ${rt_name}: ${route_line}"
    # shellcheck disable=SC2086
    ip route del ${route_line} table "$rt_name" 2>/dev/null || \
      warn "Failed to remove route from table ${rt_name}: ${route_line}"
  done < <(ip -4 route show table "$rt_name" 2>/dev/null)

  # Remove the named route table entry from rt_tables.
  if [[ -f "$rt_tables_file" ]] && grep -Eq "^[[:space:]]*${rt_id}[[:space:]]+${rt_name}([[:space:]]|$)" "$rt_tables_file"; then
    found_any=1
    info "Removing '${rt_id} ${rt_name}' entry from ${rt_tables_file}"
    sed -i.bak -E "/^[[:space:]]*${rt_id}[[:space:]]+${rt_name}([[:space:]]|$)/d" "$rt_tables_file"
    rm -f "${rt_tables_file}.bak"
  fi

  # Remove persistence files for every interface, not just eth1 -- match
  # anything named rule-* / route-* under the network-scripts persistence
  # directory whose content references the origin table.
  local scripts_dir="/etc/sysconfig/network-scripts"
  if [[ -d "$scripts_dir" ]]; then
    local f
    for f in "${scripts_dir}"/rule-* "${scripts_dir}"/route-*; do
      [[ -f "$f" ]] || continue
      if grep -q "$rt_name" "$f" 2>/dev/null; then
        found_any=1
        info "Removing persistence file: $f"
        rm -f "$f"
      fi
    done
  fi

  # Restore any NetworkManager profile that has ipv4.never-default set,
  # regardless of which interface it's attached to.
  if command -v nmcli >/dev/null 2>&1; then
    local con
    while IFS= read -r con; do
      [[ -n "$con" ]] || continue
      found_any=1
      info "Restoring default-route eligibility on NetworkManager connection: ${con}"
      nmcli con mod "$con" ipv4.never-default no >/dev/null 2>&1 || \
        warn "Failed to reset ipv4.never-default on ${con}"
      info "Note: the original gateway for '${con}' was not recorded by setup;"
      info "      set it manually if needed: nmcli con mod ${con} ipv4.gateway <ip>"
      nmcli con up "$con" >/dev/null 2>&1 || warn "Failed to bring up connection: $con (may not be active right now)"
    done < <(nmcli -t -f NAME,ipv4.never-default con show 2>/dev/null | awk -F: '$2=="yes" {print $1}')
  fi

  if [[ "$found_any" -eq 1 ]]; then
    info "Policy routing rollback complete."
  else
    info "No leftover policy routing found; nothing to remove."
  fi

  info "Sanity check:"
  ip rule show | sed 's/^/  /'
  ip route show table "$rt_name" 2>/dev/null | sed 's/^/  /' || echo "  (table ${rt_name} is now empty or removed)"
}

#------------------------------------------------------------------------------
# 5b) Remove Cloudflare Tunnel edge static routes and ipv4.never-default,
#     as applied by configure_edge_routing() in
#     cloudflared-container-setup.sh (nmcli +ipv4.routes / ipv4.never-default
#     on the edge interface's own NetworkManager connection -- NOT the
#     origin policy-routing-table model handled above). Auto-detects the
#     edge connection by scanning every connection's ipv4.routes for the
#     Cloudflare Tunnel /24 markers (198.41.192.0/24 / 198.41.200.0/24),
#     which every version of the setup script has always added -- this is
#     more reliable than relying on ipv4.never-default=yes alone, since
#     that flag was only added in a later version of the setup script and
#     hosts set up before it will have the static routes but never set
#     that flag. Also includes any connection that DOES have
#     ipv4.never-default=yes, in case a future version of the setup
#     script sets that flag without also matching these exact prefixes.
#     A no-op if neither is found. Clears the entire ipv4.routes property
#     on each matched connection (setting it to "" resets it, per
#     NetworkManager's nmcli reference), since setup is the only thing
#     expected to add routes there and route contents (e.g.
#     api.cloudflare.com's resolved IPs) can drift over time -- easier
#     and more reliable than removing individual entries.
#------------------------------------------------------------------------------
remove_edge_static_routes() {
  command -v nmcli >/dev/null 2>&1 || {
    warn "nmcli not found; skipping Cloudflare Tunnel edge static route cleanup."
    return 0
  }

  info "Scanning NetworkManager connections for Cloudflare Tunnel edge static routes"

  local edge_marker="198.41.192.0/24"
  local con matched_cons="" found_any=0

  # Match 1: any connection whose ipv4.routes contains the Cloudflare
  # Tunnel edge marker prefix -- present regardless of setup script
  # version, since every version has always added this route.
  while IFS= read -r con; do
    [[ -n "$con" ]] || continue
    local routes
    routes="$(nmcli -t -g ipv4.routes connection show "$con" 2>/dev/null)"
    if [[ "$routes" == *"${edge_marker}"* ]]; then
      matched_cons="${matched_cons}${con}"$'\n'
    fi
  done < <(nmcli -t -f NAME connection show 2>/dev/null)

  # Match 2: any connection with ipv4.never-default=yes (set by newer
  # setup script versions), in case its routes don't include the marker
  # for some reason.
  while IFS= read -r con; do
    [[ -n "$con" ]] || continue
    matched_cons="${matched_cons}${con}"$'\n'
  done < <(nmcli -t -f NAME,ipv4.never-default connection show 2>/dev/null | awk -F: '$2=="yes" {print $1}')

  matched_cons="$(printf '%s' "$matched_cons" | sort -u)"

  local dev
  while IFS= read -r con; do
    [[ -n "$con" ]] || continue
    found_any=1

    local existing_routes
    existing_routes="$(nmcli -t -g ipv4.routes connection show "$con" 2>/dev/null)"
    if [[ -n "$existing_routes" ]]; then
      info "Removing all static routes from connection: ${con}"
      nmcli connection modify "$con" ipv4.routes "" 2>/dev/null || \
        warn "Failed to clear ipv4.routes on ${con}"
    else
      info "No static routes found on connection: ${con}"
    fi

    info "Resetting ipv4.never-default on connection: ${con}"
    nmcli connection modify "$con" ipv4.never-default no 2>/dev/null || \
      warn "Failed to reset ipv4.never-default on ${con}"
    info "Note: the original gateway for '${con}' was not recorded by setup;"
    info "      set it manually if needed: nmcli con mod ${con} ipv4.gateway <ip>"

    dev="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v c="$con" '$1==c {print $2; exit}')"
    if [[ -n "$dev" ]]; then
      nmcli device reapply "$dev" >/dev/null 2>&1 || \
        nmcli connection up "$con" >/dev/null 2>&1 || \
        warn "Failed to reapply/bring up connection: ${con} (may not be active right now)"
    else
      warn "Connection ${con} is not currently attached to a device; changes are saved but not yet applied."
    fi
  done <<<"$matched_cons"

  if [[ "$found_any" -eq 1 ]]; then
    info "Cloudflare Tunnel edge static route cleanup complete."
  else
    info "No Cloudflare Tunnel edge static routes found; nothing to remove."
  fi
}

#------------------------------------------------------------------------------
# 6) Remove persistent journaling configuration
#------------------------------------------------------------------------------
remove_journaling_config() {
  local journal_conf="/etc/systemd/journald.conf.d/99-persistent.conf"

  if [[ ! -f "$journal_conf" ]]; then
    warn "Journaling configuration not found: $journal_conf (may already be removed)"
    return 0
  fi

  info "Removing persistent journaling configuration: $journal_conf"
  rm -f "$journal_conf"

  read -r -p "Restart systemd-journald now to apply the change? [y/N]: " restart_journal
  if [[ "${restart_journal,,}" == "y" ]]; then
    systemctl restart systemd-journald.service
    info "systemd-journald restarted"
  else
    warn "Journald config removed but service not restarted; change applies after reboot"
  fi
}

#------------------------------------------------------------------------------
# 7) Remove /etc/profile.d/cloudflared-aliases.sh
#------------------------------------------------------------------------------
remove_cloudflared_aliases() {
  local aliases_file="/etc/profile.d/cloudflared-aliases.sh"

  if [[ -f "$aliases_file" ]]; then
    info "Removing shell aliases: $aliases_file"
    rm -f "$aliases_file"
  else
    warn "Aliases file not found: $aliases_file (may already be removed)"
  fi
}

#------------------------------------------------------------------------------
# 8) Remove the single merged /usr/local/sbin/cloudflared-container
#    management command installed by cloudflared-container-setup.sh
#    (also removes older-style per-instance -prod/-dev named commands
#    left behind by earlier versions of the setup script, if present)
#------------------------------------------------------------------------------
remove_management_command() {
  local install_path="/usr/local/sbin/cloudflared-container"

  if [[ -f "$install_path" ]]; then
    info "Removing management command: $install_path"
    rm -f "$install_path"
  else
    warn "Management command not found: $install_path (may already be removed)"
  fi

  local legacy_path
  for legacy_path in /usr/local/sbin/cloudflared-container-prod /usr/local/sbin/cloudflared-container-dev; do
    if [[ -f "$legacy_path" ]]; then
      info "Removing legacy management command: $legacy_path"
      rm -f "$legacy_path"
    fi
  done
}

#------------------------------------------------------------------------------
# 9) Remove the subuid/subgid range setup allocated (100000-165535)
#------------------------------------------------------------------------------
remove_subuid_subgid_range() {
  local u="$1"
  local range="100000-165535"

  if ! user_exists "$u"; then
    warn "User $u does not exist; skipping subuid/subgid cleanup"
    return 0
  fi

  info "Removing subuid/subgid range ${range} for user: $u (only if it matches what setup allocated)"

  if command -v usermod >/dev/null 2>&1; then
    usermod --del-subuids "$range" --del-subgids "$range" "$u" 2>/dev/null || \
      warn "usermod could not remove subuid/subgid range for $u (may not match, or already removed)"
  else
    warn "usermod not available; edit /etc/subuid and /etc/subgid manually if needed"
  fi
}

#------------------------------------------------------------------------------
# 10) Optionally remove the cloudflared user account
#------------------------------------------------------------------------------
remove_user_account() {
  local u="$1"

  if ! user_exists "$u"; then
    warn "User $u does not exist; skipping user removal"
    return 0
  fi

  info "Removing user account: $u (including home directory)"
  userdel -r "$u" 2>/dev/null || warn "Failed to fully remove user $u (may have running processes; check 'loginctl' / 'ps')"
}

# Remove subuid/subgid range and optionally the user account for one
# instance's user, but only once per distinct username -- if prod and dev
# share the same user, calling this twice for that user would be harmless
# but redundant/confusing in output, so callers pass an already-deduped list.
remove_user_state_if_requested() {
  local u="$1" remove_user="$2"

  if [[ "$remove_user" == "y" ]]; then
    # userdel -r deletes the home directory and, on most distros, the
    # associated subuid/subgid entries. Run the explicit removal first
    # in case that behavior differs.
    remove_subuid_subgid_range "${u}"
    remove_user_account "${u}"
  else
    info "Keeping user account: ${u} (leaving subuid/subgid range intact for future rootless use)"
  fi
}

main() {
  require_root

  echo "=========================================="
  echo "Cloudflared Container Uninstall Script"
  echo "=========================================="
  echo
  echo "This reverses the changes made by cloudflared-container-setup.sh."
  echo

  #-----------------------------------------------------------------------
  # Base username -- prod and dev always run as "<base>-prod" and
  # "<base>-dev", matching cloudflared-container-setup.sh.
  #-----------------------------------------------------------------------
  read -r -p "Enter the base username used for cloudflared [cloudflared]: " BASE_USER
  BASE_USER="${BASE_USER:-cloudflared}"

  #-----------------------------------------------------------------------
  # "prod" instance (always processed)
  #-----------------------------------------------------------------------
  info "Configuring removal of the 'prod' cloudflared container"
  CF_USER="${BASE_USER}-prod"

  if ! user_exists "${CF_USER}"; then
    warn "User ${CF_USER} does not exist. Steps tied to that user will be skipped."
  fi

  read -r -p "Enter the prod cloudflared image tag to remove (leave blank to remove all cloudflared images): " CF_TAG

  #-----------------------------------------------------------------------
  # "dev" instance (optional)
  #-----------------------------------------------------------------------
  echo
  read -r -p "Was a second (dev) cloudflared container installed on this host? [y/N]: " REMOVE_DEV
  REMOVE_DEV="${REMOVE_DEV,,}"

  DEV_USER=""
  DEV_TAG=""
  if [[ "$REMOVE_DEV" == "y" ]]; then
    info "Configuring removal of the 'dev' cloudflared container"
    DEV_USER="${BASE_USER}-dev"

    if ! user_exists "${DEV_USER}"; then
      warn "User ${DEV_USER} does not exist. Steps tied to that user will be skipped."
    fi

    read -r -p "Enter the dev cloudflared image tag to remove (leave blank to remove all cloudflared images): " DEV_TAG
  fi

  echo
  echo "Starting uninstall..."
  echo

  # 1/2. Stop/disable/remove service + Quadlet files, container, and image(s) -- prod
  stop_disable_and_remove_service "prod" "${CF_USER}"
  remove_container_and_image "prod" "${CF_USER}" "${CF_TAG}"

  # 1/2. Same steps for dev, if requested
  if [[ "$REMOVE_DEV" == "y" ]]; then
    echo
    stop_disable_and_remove_service "dev" "${DEV_USER}"
    remove_container_and_image "dev" "${DEV_USER}" "${DEV_TAG}"
  fi

  # 3. Disable linger (once per distinct user)
  disable_linger_for_user "${CF_USER}"
  if [[ "$REMOVE_DEV" == "y" && "${DEV_USER}" != "${CF_USER}" ]]; then
    disable_linger_for_user "${DEV_USER}"
  fi

  # 4. Remove sysctl config (shared, once)
  remove_sysctl_cloudflared

  # 5. Remove any leftover policy routing -- always runs, auto-detects
  # whatever is present rather than relying on the user to know if/where
  # it was configured.
  echo
  remove_policy_routing_two_nic

  # 5b. Remove Cloudflare Tunnel edge static routes (nmcli +ipv4.routes /
  # ipv4.never-default) -- always runs, auto-detects the edge connection.
  echo
  remove_edge_static_routes

  # 6. Remove persistent journaling config
  echo
  read -r -p "Remove persistent journaling configuration? [y/N]: " REMOVE_JOURNAL
  REMOVE_JOURNAL="${REMOVE_JOURNAL,,}"
  if [[ "$REMOVE_JOURNAL" == "y" ]]; then
    remove_journaling_config
  else
    info "Keeping persistent journaling configuration"
  fi

  # 7. Remove shell aliases (single shared file covers both instances)
  remove_cloudflared_aliases

  # 8. Remove the single merged cloudflared-container management command
  remove_management_command

  # 9/10. subuid/subgid + optional user removal
  echo
  read -r -p "Remove user account '${CF_USER}' and home directory? [y/N]: " REMOVE_USER
  REMOVE_USER="${REMOVE_USER,,}"
  remove_user_state_if_requested "${CF_USER}" "${REMOVE_USER}"

  REMOVE_DEV_USER="n"
  if [[ "$REMOVE_DEV" == "y" ]]; then
    if [[ "${DEV_USER}" == "${CF_USER}" ]]; then
      info "Dev shares the same user as prod (${CF_USER}); already handled above."
      REMOVE_DEV_USER="${REMOVE_USER}"
    else
      echo
      read -r -p "Remove dev user account '${DEV_USER}' and home directory? [y/N]: " REMOVE_DEV_USER
      REMOVE_DEV_USER="${REMOVE_DEV_USER,,}"
      remove_user_state_if_requested "${DEV_USER}" "${REMOVE_DEV_USER}"
    fi
  fi

  echo
  info "=========================================="
  info "Uninstall complete!"
  info "=========================================="
  echo
  info "Summary of what was processed:"
  echo "  - cloudflared.service (prod) stopped, disabled, and Quadlet files removed"
  echo "  - Prod container and image(s) removed"
  echo "  - Linger disabled for ${CF_USER}"
  if [[ "$REMOVE_DEV" == "y" ]]; then
    echo "  - cloudflared-dev.service (dev) stopped, disabled, and Quadlet files removed"
    echo "  - Dev container and image(s) removed"
    if [[ "${DEV_USER}" != "${CF_USER}" ]]; then
      echo "  - Linger disabled for ${DEV_USER}"
    fi
  fi
  echo "  - /etc/sysctl.d/99-cloudflared.conf removed"
  echo "  - Any leftover legacy policy routing removed (ip rules, origin table routes, rt_tables entry, persistence files, NetworkManager profile -- auto-detected)"
  echo "  - Cloudflare Tunnel edge static routes and ipv4.never-default removed from the edge NetworkManager connection (auto-detected)"
  [[ "$REMOVE_JOURNAL" == "y" ]] && echo "  - Persistent journaling configuration removed"
  echo "  - /etc/profile.d/cloudflared-aliases.sh removed"
  echo "  - /usr/local/sbin/cloudflared-container management command removed"
  if [[ "$REMOVE_USER" == "y" ]]; then
    echo "  - subuid/subgid range removed and prod user account '${CF_USER}' deleted"
  fi
  if [[ "$REMOVE_DEV" == "y" && "${DEV_USER}" != "${CF_USER}" && "$REMOVE_DEV_USER" == "y" ]]; then
    echo "  - subuid/subgid range removed and dev user account '${DEV_USER}' deleted"
  fi
  echo
  info "Not removed (shared system state, left for you to review):"
  echo "  - Packages: podman, passt -- remove manually if unused elsewhere:"
  echo "      sudo dnf remove podman passt"
  echo "  - Any policy-routed interface's original NetworkManager gateway value (not recorded) -- set manually if needed:"
  echo "      nmcli con mod <connection> ipv4.gateway <ip>"
  echo
  info "Verify final state:"
  echo "  ip rule show"
  echo "  ip route show"
  echo "  systemctl status systemd-journald"
  echo
}

main "$@"
