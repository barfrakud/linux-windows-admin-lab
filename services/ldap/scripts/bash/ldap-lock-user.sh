#!/bin/bash
# =============================================================================
# ldap-lock-user.sh — Lock or unlock an LDAP user account in 389DS
# =============================================================================
#
# DESCRIPTION:
#   This script locks or unlocks a user account in 389 Directory Server.
#
#   LOCKING an account sets nsAccountLock=true on the user entry. This is
#   an administrative lock — the user cannot authenticate until an admin
#   explicitly unlocks the account. It differs from intruder lockout (which
#   is automatic and time-limited).
#
#   UNLOCKING removes the nsAccountLock attribute AND resets the
#   passwordRetryCount to 0 (clearing any failed attempt counters).
#
#   Common use cases:
#   - Employee leaves: lock their account immediately
#   - Security incident: lock compromised account
#   - Lockout recovery: unlock account after too many failed attempts
#   - Temporary deactivation: lock during leave, unlock on return
#
# USAGE:
#   ./ldap-lock-user.sh -u <uid> -L        # lock account
#   ./ldap-lock-user.sh -u <uid> -U        # unlock account
#
# EXAMPLES:
#   ./ldap-lock-user.sh -u jkowalski -L    # lock jkowalski's account
#   ./ldap-lock-user.sh -u jkowalski -U    # unlock jkowalski's account
#
# REQUIREMENTS:
#   - openldap-clients (ldapmodify, ldapsearch)
#   - Network access to LDAP server on port 636 (LDAPS)
#   - Directory Manager credentials (or bind DN with write access)
#
# LDAP CONCEPTS EXPLAINED:
#   - nsAccountLock: 389DS-specific operational attribute.
#     When set to "true", the account is disabled — any LDAP bind attempt
#     with this DN will fail with error 53 (LDAP_UNWILLING_TO_PERFORM).
#     This is the simplest and most reliable way to disable an account.
#
#   - ldapmodify changetype: modify — used to change existing entries.
#     Operations:
#       "add"     — add a new attribute (fails if it already exists)
#       "replace" — set attribute value (creates if missing, overwrites if exists)
#       "delete"  — remove an attribute entirely
#     We use "replace" for locking (idempotent) and "delete" for unlocking.
#
#   - Why not just delete the account?
#     Locking is preferred over deletion because:
#     1. Locked account retains audit trail (who it was, when created)
#     2. Can be unlocked if needed (e.g. false alarm)
#     3. uidNumber is preserved (avoids UID reuse security issues)
#     4. Group memberships are preserved
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

LDAP_URI="ldaps://rhel-srv01.linux.lab.local:636"
BASE_DN="dc=linux,dc=lab,dc=local"
PEOPLE_OU="ou=People,${BASE_DN}"
SERVICES_OU="ou=Services,${BASE_DN}"
BIND_DN="cn=Directory Manager"

# =============================================================================
# FUNCTIONS
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") -u <uid> [-L | -U] [-h]

Required:
  -u <uid>   User login name to lock/unlock

Action (choose one):
  -L         Lock the account (set nsAccountLock=true)
  -U         Unlock the account (remove nsAccountLock, reset retry count)

Optional:
  -h         Show this help

Examples:
  $(basename "$0") -u jkowalski -L     # lock account
  $(basename "$0") -u jkowalski -U     # unlock account
EOF
    exit 1
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

die() {
    echo "[ERROR] $1" >&2
    exit 1
}

# Find which OU the user is in (People or Services)
# Returns the full DN or empty string if not found
find_user_dn() {
    local uid="$1"
    local dn=""

    # Search in People OU first (most common)
    dn=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${PEOPLE_OU}" "(uid=${uid})" dn \
        -LLL 2>/dev/null | grep "^dn:" | sed 's/^dn: //')

    if [[ -n "${dn}" ]]; then
        echo "${dn}"
        return
    fi

    # Search in Services OU
    dn=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${SERVICES_OU}" "(uid=${uid})" dn \
        -LLL 2>/dev/null | grep "^dn:" | sed 's/^dn: //')

    echo "${dn}"
}

# Get current lock status of an account
get_lock_status() {
    local user_dn="$1"
    local lock_status
    lock_status=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${user_dn}" -s base "(objectClass=*)" \
        nsAccountLock passwordRetryCount \
        -LLL 2>/dev/null)

    local locked
    locked=$(echo "${lock_status}" | grep "^nsAccountLock:" | awk '{print $2}')
    local retries
    retries=$(echo "${lock_status}" | grep "^passwordRetryCount:" | awk '{print $2}')

    echo "locked=${locked:-false},retries=${retries:-0}"
}

# Lock an account by setting nsAccountLock=true
lock_account() {
    local user_dn="$1"
    local uid="$2"

    log "Locking account: ${uid}"
    log "DN: ${user_dn}"

    # Use "replace" instead of "add" because replace is idempotent:
    # - If nsAccountLock doesn't exist → it creates it with value "true"
    # - If nsAccountLock already exists → it overwrites with "true"
    # This means running the script twice won't cause an error.
    ldapmodify -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" <<EOF
dn: ${user_dn}
changetype: modify
replace: nsAccountLock
nsAccountLock: true
EOF

    if [[ $? -eq 0 ]]; then
        log "Account '${uid}' locked successfully."
        log ""
        log "The user will see this error when trying to authenticate:"
        log "  ldap_bind: Server is unwilling to perform (53)"
        log "  additional info: Account inactivated. Contact system administrator."
    else
        die "Failed to lock account '${uid}'!"
    fi
}

# Unlock an account by removing nsAccountLock and resetting retry count
unlock_account() {
    local user_dn="$1"
    local uid="$2"

    log "Unlocking account: ${uid}"
    log "DN: ${user_dn}"

    # We perform two modifications in one ldapmodify call:
    # 1. Delete nsAccountLock — removes the administrative lock
    # 2. Replace passwordRetryCount with 0 — clears failed attempts
    #
    # The "-" between modifications separates them within the same entry.
    # Both modifications are applied atomically (all or nothing).
    #
    # Note: "delete: nsAccountLock" will fail if the attribute doesn't exist.
    # We handle this by checking first, or by ignoring the error.
    ldapmodify -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" <<EOF 2>/dev/null
dn: ${user_dn}
changetype: modify
delete: nsAccountLock
-
replace: passwordRetryCount
passwordRetryCount: 0
EOF

    # If the above fails (nsAccountLock didn't exist), try just resetting retries
    if [[ $? -ne 0 ]]; then
        log "nsAccountLock was not set. Resetting retry count only..."
        ldapmodify -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" <<EOF
dn: ${user_dn}
changetype: modify
replace: passwordRetryCount
passwordRetryCount: 0
EOF
    fi

    log "Account '${uid}' unlocked successfully."
    log "Failed attempt counter reset to 0."
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

TARGET_USER=""
ACTION=""

while getopts "u:LUh" opt; do
    case ${opt} in
        u) TARGET_USER="${OPTARG}" ;;
        L) ACTION="lock" ;;
        U) ACTION="unlock" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate arguments
[[ -z "${TARGET_USER}" ]] && die "Missing required parameter: -u <uid>"
[[ -z "${ACTION}" ]]      && die "Missing action: specify -L (lock) or -U (unlock)"

# Check dependencies
command -v ldapmodify >/dev/null 2>&1 || die "ldapmodify not found."
command -v ldapsearch >/dev/null 2>&1 || die "ldapsearch not found."

# Prompt for bind password once and store in a temp file
PASS_FILE=$(mktemp /tmp/.ldap-lock-XXXXXX)
chmod 600 "${PASS_FILE}"
cleanup() { rm -f "${PASS_FILE}"; }
trap cleanup EXIT

read -rsp "Enter Directory Manager password: " BIND_PASS
echo ""
printf '%s' "${BIND_PASS}" > "${PASS_FILE}"
BIND_PASS=""

# =============================================================================
# MAIN
# =============================================================================

echo ""
log "LDAP Account ${ACTION^} Tool"
log "LDAP server: ${LDAP_URI}"
echo ""

# Find the user's DN
log "Looking up user '${TARGET_USER}'..."
USER_DN=$(find_user_dn "${TARGET_USER}")

if [[ -z "${USER_DN}" ]]; then
    die "User '${TARGET_USER}' not found in ${PEOPLE_OU} or ${SERVICES_OU}"
fi

log "Found: ${USER_DN}"

# Show current status before making changes
log "Current status: $(get_lock_status "${USER_DN}")"
echo ""

# Confirm action
echo "You are about to ${ACTION^^} the account: ${TARGET_USER}"
echo "DN: ${USER_DN}"
read -rp "Continue? [y/N]: " confirm
if [[ "${confirm,,}" != "y" ]]; then
    log "Cancelled."
    exit 0
fi
echo ""

# Execute the action
case "${ACTION}" in
    lock)   lock_account "${USER_DN}" "${TARGET_USER}" ;;
    unlock) unlock_account "${USER_DN}" "${TARGET_USER}" ;;
esac

echo ""

# Show status after change
log "Status after change: $(get_lock_status "${USER_DN}")"
echo ""
log "TIP: On SSSD clients, clear cache to reflect changes immediately:"
log "     sss_cache -E && systemctl restart sssd"
