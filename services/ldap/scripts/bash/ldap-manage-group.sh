#!/bin/bash
# =============================================================================
# ldap-manage-group.sh — Add or remove users from LDAP groups in 389DS
# =============================================================================
#
# DESCRIPTION:
#   Manages POSIX group membership in 389 Directory Server. Supports:
#   - Adding a user to a group
#   - Removing a user from a group
#   - Listing members of a group
#   - Listing all groups a user belongs to
#
# USAGE:
#   ./ldap-manage-group.sh -g <group> -u <uid> -A     # add user to group
#   ./ldap-manage-group.sh -g <group> -u <uid> -R     # remove user from group
#   ./ldap-manage-group.sh -g <group> -M              # list group members
#   ./ldap-manage-group.sh -u <uid> -G                # list user's groups
#
# EXAMPLES:
#   ./ldap-manage-group.sh -g linuxadmins -u jkowalski -A
#   ./ldap-manage-group.sh -g linuxadmins -u jkowalski -R
#   ./ldap-manage-group.sh -g linuxadmins -M
#   ./ldap-manage-group.sh -u jkowalski -G
#
# REQUIREMENTS:
#   - openldap-clients (ldapsearch, ldapmodify)
#   - Network access to LDAP server on port 636 (LDAPS)
#
# LDAP CONCEPTS EXPLAINED:
#   - posixGroup objectClass: defines a UNIX group in LDAP. Key attributes:
#     - cn: group name (e.g., "linuxadmins")
#     - gidNumber: numeric group ID (e.g., 10001)
#     - memberUid: multi-valued attribute listing members by uid
#
#   - rfc2307 vs rfc2307bis schemas:
#     - rfc2307 (used in this lab): group members stored as "memberUid: jkowalski"
#       (plain uid string). Simple but no referential integrity.
#     - rfc2307bis: group members stored as "member: uid=jkowalski,ou=People,..."
#       (full DN). Supports nested groups and referential integrity.
#     SSSD supports both via ldap_schema = rfc2307 | rfc2307bis.
#
#   - Multi-valued attributes: memberUid can have many values (one per member).
#     ldapmodify "add: memberUid" adds a new value without replacing existing ones.
#     ldapmodify "delete: memberUid" with a specific value removes only that one.
#
#   - Primary vs supplementary groups:
#     - Primary group: set by gidNumber on the user entry. Does NOT require
#       memberUid. The user is implicitly a member.
#     - Supplementary groups: set by memberUid on group entries. These are
#       additional groups beyond the primary.
#     The `id` command shows both: "uid=20001(jkowalski) gid=10001(linuxadmins)
#     groups=10001(linuxadmins),10002(linuxusers)"
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
Usage: $(basename "$0") [options]

Group membership operations:
  -g <group> -u <uid> -A    Add user to group
  -g <group> -u <uid> -R    Remove user from group

Query operations:
  -g <group> -M             List all members of a group
  -u <uid> -G               List all groups for a user

Options:
  -h                        Show this help

Examples:
  $(basename "$0") -g linuxadmins -u jkowalski -A    # add to group
  $(basename "$0") -g linuxadmins -u jkowalski -R    # remove from group
  $(basename "$0") -g linuxadmins -M                  # list members
  $(basename "$0") -u jkowalski -G                    # list user's groups
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

# Find a group's DN by its cn (common name)
find_group_dn() {
    local group_cn="$1"
    ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${GROUPS_OU}" "(cn=${group_cn})" dn \
        -LLL 2>/dev/null | grep "^dn:" | sed 's/^dn: //'
}

# Check if a user exists in LDAP (either People or Services)
user_exists() {
    local uid="$1"
    local count
    count=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${BASE_DN}" "(uid=${uid})" dn \
        -LLL 2>/dev/null | grep -c "^dn:" || true)
    [[ ${count} -gt 0 ]]
}

# Check if a user is already a member of a group
is_member() {
    local group_dn="$1"
    local uid="$2"
    local count
    count=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${group_dn}" -s base "(memberUid=${uid})" memberUid \
        -LLL 2>/dev/null | grep -c "memberUid: ${uid}" || true)
    [[ ${count} -gt 0 ]]
}

# Add a user to a group
add_to_group() {
    local group_cn="$1"
    local uid="$2"

    log "Adding '${uid}' to group '${group_cn}'..."

    # Find group
    local group_dn
    group_dn=$(find_group_dn "${group_cn}")
    [[ -z "${group_dn}" ]] && die "Group '${group_cn}' not found in ${GROUPS_OU}"

    # Verify user exists
    user_exists "${uid}" || die "User '${uid}' not found in LDAP"

    # Check if already a member
    if is_member "${group_dn}" "${uid}"; then
        log "User '${uid}' is already a member of '${group_cn}'. No change."
        return 0
    fi

    # Add memberUid value to the group
    # "add: memberUid" appends a new value to the multi-valued attribute
    # without touching existing values
    ldapmodify -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" <<EOF
dn: ${group_dn}
changetype: modify
add: memberUid
memberUid: ${uid}
EOF

    if [[ $? -eq 0 ]]; then
        log "User '${uid}' added to group '${group_cn}' successfully."
    else
        die "Failed to add user to group!"
    fi
}

# Remove a user from a group
remove_from_group() {
    local group_cn="$1"
    local uid="$2"

    log "Removing '${uid}' from group '${group_cn}'..."

    local group_dn
    group_dn=$(find_group_dn "${group_cn}")
    [[ -z "${group_dn}" ]] && die "Group '${group_cn}' not found in ${GROUPS_OU}"

    # Check if the user is actually a member
    if ! is_member "${group_dn}" "${uid}"; then
        log "User '${uid}' is not a member of '${group_cn}'. No change."
        return 0
    fi

    # Delete specific memberUid value from the group
    # "delete: memberUid" with "memberUid: <value>" removes ONLY that value
    ldapmodify -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" <<EOF
dn: ${group_dn}
changetype: modify
delete: memberUid
memberUid: ${uid}
EOF

    if [[ $? -eq 0 ]]; then
        log "User '${uid}' removed from group '${group_cn}'."
    else
        die "Failed to remove user from group!"
    fi
}

# List all members of a group
list_members() {
    local group_cn="$1"

    log "Members of group '${group_cn}':"

    local group_dn
    group_dn=$(find_group_dn "${group_cn}")
    [[ -z "${group_dn}" ]] && die "Group '${group_cn}' not found in ${GROUPS_OU}"

    # Get group info
    local result
    result=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${group_dn}" -s base "(objectClass=*)" \
        -LLL cn gidNumber memberUid 2>/dev/null)

    local gid
    gid=$(echo "${result}" | grep "^gidNumber:" | awk '{print $2}')

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Group:     ${group_cn} (gid=${gid})"
    echo "  DN:        ${group_dn}"
    echo ""
    echo "  Members (via memberUid — supplementary membership):"

    # Extract all memberUid values
    local members
    members=$(echo "${result}" | grep "^memberUid:" | sed 's/^memberUid: //')

    if [[ -z "${members}" ]]; then
        echo "    (none)"
    else
        echo "${members}" | while IFS= read -r member; do
            echo "    - ${member}"
        done
    fi

    # Also show users whose primary group (gidNumber) matches this group
    echo ""
    echo "  Primary group members (gidNumber=${gid} on user entry):"
    local primary_members
    primary_members=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${BASE_DN}" "(&(objectClass=posixAccount)(gidNumber=${gid}))" uid \
        -LLL 2>/dev/null | grep "^uid:" | sed 's/^uid: //')

    if [[ -z "${primary_members}" ]]; then
        echo "    (none)"
    else
        echo "${primary_members}" | while IFS= read -r member; do
            echo "    - ${member}"
        done
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# List all groups for a user
list_user_groups() {
    local uid="$1"

    log "Groups for user '${uid}':"

    user_exists "${uid}" || die "User '${uid}' not found in LDAP"

    # Get user's primary gidNumber
    local user_gid
    user_gid=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${BASE_DN}" "(uid=${uid})" gidNumber \
        -LLL 2>/dev/null | grep "^gidNumber:" | awk '{print $2}')

    # Find primary group name
    local primary_group
    primary_group=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${GROUPS_OU}" "(gidNumber=${user_gid})" cn \
        -LLL 2>/dev/null | grep "^cn:" | sed 's/^cn: //')

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  User: ${uid}"
    echo ""
    echo "  Primary group:"
    echo "    - ${primary_group:-unknown} (gid=${user_gid})"
    echo ""
    echo "  Supplementary groups (via memberUid):"

    # Find all groups where memberUid matches
    local groups
    groups=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${GROUPS_OU}" "(memberUid=${uid})" cn gidNumber \
        -LLL 2>/dev/null)

    local found_groups
    found_groups=$(echo "${groups}" | grep "^cn:" | sed 's/^cn: //')

    if [[ -z "${found_groups}" ]]; then
        echo "    (none)"
    else
        echo "${found_groups}" | while IFS= read -r grp; do
            echo "    - ${grp}"
        done
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

GROUP_NAME=""
TARGET_USER=""
ACTION=""

while getopts "g:u:ARMGh" opt; do
    case ${opt} in
        g) GROUP_NAME="${OPTARG}" ;;
        u) TARGET_USER="${OPTARG}" ;;
        A) ACTION="add" ;;
        R) ACTION="remove" ;;
        M) ACTION="list-members" ;;
        G) ACTION="list-groups" ;;
        h) usage ;;
        *) usage ;;
    esac
done

[[ -z "${ACTION}" ]] && die "No action specified. Use -A (add), -R (remove), -M (list members), or -G (list groups)."

# Validate required args per action
case "${ACTION}" in
    add|remove)
        [[ -z "${GROUP_NAME}" ]]  && die "Missing -g <group>"
        [[ -z "${TARGET_USER}" ]] && die "Missing -u <uid>"
        ;;
    list-members)
        [[ -z "${GROUP_NAME}" ]]  && die "Missing -g <group>"
        ;;
    list-groups)
        [[ -z "${TARGET_USER}" ]] && die "Missing -u <uid>"
        ;;
esac

# Check dependencies
command -v ldapsearch >/dev/null 2>&1 || die "ldapsearch not found."
command -v ldapmodify >/dev/null 2>&1 || die "ldapmodify not found."

# Prompt for bind password once and store in a temp file
PASS_FILE=$(mktemp /tmp/.ldap-group-XXXXXX)
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
log "LDAP Group Management Tool"
log "Server: ${LDAP_URI}"
echo ""

case "${ACTION}" in
    add)           add_to_group "${GROUP_NAME}" "${TARGET_USER}" ;;
    remove)        remove_from_group "${GROUP_NAME}" "${TARGET_USER}" ;;
    list-members)  list_members "${GROUP_NAME}" ;;
    list-groups)   list_user_groups "${TARGET_USER}" ;;
esac

if [[ "${ACTION}" == "add" || "${ACTION}" == "remove" ]]; then
    echo ""
    log "TIP: Clear SSSD cache on clients: sss_cache -E && systemctl restart sssd"
fi
