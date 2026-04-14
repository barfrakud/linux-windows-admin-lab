#!/bin/bash
# =============================================================================
# ldap-delete-user.sh — Delete an LDAP user from 389 Directory Server
# =============================================================================
#
# DESCRIPTION:
#   Removes a user entry from the LDAP directory. This is a DESTRUCTIVE
#   operation — once deleted, the entry cannot be recovered (unless you have
#   a backup or LDAP changelog/retrochangelog enabled).
#
#   The script performs these safety steps before deletion:
#   1. Looks up the user to confirm they exist
#   2. Displays all attributes for review
#   3. Checks for group memberships (memberUid references)
#   4. Requires explicit confirmation
#   5. Optionally removes memberUid references from groups
#   6. Deletes the user entry
#
#   IMPORTANT: In production, LOCKING an account is almost always preferred
#   over deletion. See ldap-lock-user.sh for account deactivation.
#   Delete only when you're certain the account is no longer needed and
#   all audit/compliance requirements have been met.
#
# USAGE:
#   ./ldap-delete-user.sh -u <uid>
#   ./ldap-delete-user.sh -u <uid> --remove-from-groups
#
# EXAMPLES:
#   ./ldap-delete-user.sh -u mwisniewska
#   ./ldap-delete-user.sh -u mwisniewska --remove-from-groups
#
# REQUIREMENTS:
#   - openldap-clients (ldapsearch, ldapdelete, ldapmodify)
#   - Network access to LDAP server on port 636 (LDAPS)
#   - Directory Manager credentials
#
# LDAP CONCEPTS EXPLAINED:
#   - ldapdelete: removes an LDAP entry by its DN. The entry must be a LEAF
#     node (no children). If the entry has children, you must delete them
#     first or use the -r (recursive) flag.
#
#   - memberUid: in the posixGroup objectClass (rfc2307 schema), group
#     membership is stored as memberUid attributes on the GROUP entry,
#     not on the user. Deleting a user does NOT automatically remove them
#     from groups — you must clean up memberUid references separately.
#     This is a key difference from AD, where group membership is managed
#     by the directory server automatically.
#
#   - Referential integrity plugin: 389DS has a plugin that can automatically
#     clean up references when an entry is deleted. If enabled, memberUid
#     cleanup would be automatic. In our lab setup, it's not enabled by
#     default, so we handle it manually.
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

LDAP_URI="ldaps://rhel-srv01.linux.lab.local:636"
BASE_DN="dc=linux,dc=lab,dc=local"
PEOPLE_OU="ou=People,${BASE_DN}"
SERVICES_OU="ou=Services,${BASE_DN}"
GROUPS_OU="ou=Groups,${BASE_DN}"
BIND_DN="cn=Directory Manager"

# =============================================================================
# FUNCTIONS
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") -u <uid> [--remove-from-groups] [-h]

Required:
  -u <uid>              User login name to delete

Optional:
  --remove-from-groups  Also remove memberUid references from all groups
  -h                    Show this help

Examples:
  $(basename "$0") -u mwisniewska
  $(basename "$0") -u mwisniewska --remove-from-groups

WARNING: Deletion is permanent. Consider locking the account instead:
  ./ldap-lock-user.sh -u <uid> -L
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

# Find which OU the user is in
find_user_dn() {
    local uid="$1"
    local dn=""

    dn=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${PEOPLE_OU}" "(uid=${uid})" dn \
        -LLL 2>/dev/null | grep "^dn:" | sed 's/^dn: //')

    if [[ -z "${dn}" ]]; then
        dn=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
            -b "${SERVICES_OU}" "(uid=${uid})" dn \
            -LLL 2>/dev/null | grep "^dn:" | sed 's/^dn: //')
    fi

    echo "${dn}"
}

# Find all groups that contain this user as memberUid
find_group_memberships() {
    local uid="$1"

    # Search in Groups OU for entries where memberUid matches
    # This uses an equality filter on the memberUid attribute
    ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${GROUPS_OU}" "(memberUid=${uid})" \
        -LLL dn cn 2>/dev/null | grep "^dn:\|^cn:" || true
}

# Remove memberUid from a specific group
remove_from_group() {
    local group_dn="$1"
    local uid="$2"

    # ldapmodify with "delete" operation removes a specific value
    # from a multi-valued attribute. If memberUid has multiple values
    # (multiple members), only the specified value is removed.
    ldapmodify -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" <<EOF
dn: ${group_dn}
changetype: modify
delete: memberUid
memberUid: ${uid}
EOF
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

TARGET_USER=""
REMOVE_GROUPS="false"

# Parse arguments — handle both short opts and long opts
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u)
            TARGET_USER="$2"
            shift 2
            ;;
        --remove-from-groups)
            REMOVE_GROUPS="true"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

[[ -z "${TARGET_USER}" ]] && die "Missing required parameter: -u <uid>"

# Check dependencies
command -v ldapsearch >/dev/null 2>&1 || die "ldapsearch not found."
command -v ldapdelete >/dev/null 2>&1 || die "ldapdelete not found."
command -v ldapmodify >/dev/null 2>&1 || die "ldapmodify not found."

# Prompt for bind password once and store in a temp file
PASS_FILE=$(mktemp /tmp/.ldap-delete-XXXXXX)
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
log "LDAP User Deletion Tool"
log "Server: ${LDAP_URI}"
echo ""

# Step 1: Find the user
log "Looking up user '${TARGET_USER}'..."
USER_DN=$(find_user_dn "${TARGET_USER}")

if [[ -z "${USER_DN}" ]]; then
    die "User '${TARGET_USER}' not found in LDAP."
fi

log "Found: ${USER_DN}"
echo ""

# Step 2: Display user details for review
log "User details:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
    -b "${USER_DN}" -s base "(objectClass=*)" \
    -LLL uid cn sn uidNumber gidNumber homeDirectory loginShell nsAccountLock 2>/dev/null
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 3: Check group memberships
log "Checking group memberships..."
GROUP_MEMBERSHIPS=$(find_group_memberships "${TARGET_USER}")

if [[ -n "${GROUP_MEMBERSHIPS}" ]]; then
    echo "  User is a member of these groups:"
    echo "${GROUP_MEMBERSHIPS}" | while IFS= read -r line; do
        echo "    ${line}"
    done
    echo ""

    if [[ "${REMOVE_GROUPS}" == "false" ]]; then
        log "WARNING: Group memberships will NOT be cleaned up."
        log "         Use --remove-from-groups to remove memberUid references."
        log "         Orphaned memberUid entries won't break anything but are messy."
        echo ""
    fi
else
    log "No group memberships found."
    echo ""
fi

# Step 4: Final confirmation
echo "╔══════════════════════════════════════════════════════╗"
echo "║  WARNING: You are about to DELETE this LDAP entry   ║"
echo "║  This action is PERMANENT and IRREVERSIBLE.         ║"
echo "║                                                     ║"
echo "║  Consider LOCKING instead:                          ║"
echo "║  ./ldap-lock-user.sh -u ${TARGET_USER} -L"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "DN to delete: ${USER_DN}"
read -rp "Type the uid '${TARGET_USER}' to confirm deletion: " confirm

if [[ "${confirm}" != "${TARGET_USER}" ]]; then
    log "Confirmation failed. Aborting."
    exit 1
fi
echo ""

# Step 5: Remove from groups (if requested)
if [[ "${REMOVE_GROUPS}" == "true" && -n "${GROUP_MEMBERSHIPS}" ]]; then
    log "Removing memberUid references from groups..."

    # Extract group DNs from the search results
    echo "${GROUP_MEMBERSHIPS}" | grep "^dn:" | sed 's/^dn: //' | while IFS= read -r group_dn; do
        log "  Removing from: ${group_dn}"
        remove_from_group "${group_dn}" "${TARGET_USER}"
    done
    echo ""
fi

# Step 6: Delete the user entry
log "Deleting user entry..."

# ldapdelete removes the entry identified by its DN
# -x = simple bind, -H = server URI, -D = bind DN, -y = password file
ldapdelete -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" "${USER_DN}"

if [[ $? -eq 0 ]]; then
    log "User '${TARGET_USER}' deleted successfully."
else
    die "Failed to delete user '${TARGET_USER}'!"
fi

echo ""
log "Post-deletion checklist:"
log "  1. Clear SSSD cache on clients: sss_cache -E && systemctl restart sssd"
log "  2. Remove home directory on clients if needed: rm -rf /home/${TARGET_USER}"
log "  3. Check for any cron jobs or file ownership by uid"
log "  4. Update any documentation or access lists"
