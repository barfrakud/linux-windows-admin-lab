#!/bin/bash
# =============================================================================
# ldap-check-expiry.sh — Check password and account expiry for LDAP users
# =============================================================================
#
# DESCRIPTION:
#   This script queries 389 Directory Server for password expiry information.
#   It can check a specific user or all users in the People OU.
#
#   389DS tracks password policy through operational attributes:
#   - passwordExpirationTime — when the password expires (format: YYYYMMDDHHmmssZ)
#   - accountUnlockTime      — when a locked account will be auto-unlocked
#   - passwordRetryCount     — number of failed login attempts
#   - passwordExpWarned      — whether the user has been warned about expiry
#
#   These are OPERATIONAL ATTRIBUTES — they are NOT returned by default in
#   ldapsearch. You must explicitly request them with '+' or by name.
#
# USAGE:
#   ./ldap-check-expiry.sh [-u <uid>]   # specific user
#   ./ldap-check-expiry.sh              # all users in ou=People
#
# EXAMPLES:
#   ./ldap-check-expiry.sh                  # check all users
#   ./ldap-check-expiry.sh -u jkowalski     # check specific user
#
# REQUIREMENTS:
#   - openldap-clients (ldapsearch) installed
#   - Network access to LDAP server on port 636 (LDAPS)
#   - Bind credentials with read access to password policy attributes
#
# LDAP CONCEPTS EXPLAINED:
#   - Operational attributes: metadata maintained by the server automatically.
#     Not visible in normal searches. Examples: createTimestamp, modifyTimestamp,
#     passwordExpirationTime. Request them with '+' in ldapsearch.
#   - Password policy: 389DS can enforce password expiration, lockout after
#     failed attempts, password history, and minimum age. Configured via
#     cn=config or per-subtree password policies.
#   - Generalized Time format: YYYYMMDDHHmmssZ (e.g. 20260415120000Z)
#     — always in UTC. The trailing 'Z' means Zulu/UTC time.
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

LDAP_URI="ldaps://rhel-srv01.linux.lab.local:636"
BASE_DN="dc=linux,dc=lab,dc=local"
PEOPLE_OU="ou=People,${BASE_DN}"
BIND_DN="cn=Directory Manager"

# =============================================================================
# FUNCTIONS
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [-u <uid>] [-h]

Options:
  -u <uid>   Check a specific user (default: all users in ou=People)
  -h         Show this help

Examples:
  $(basename "$0")                  # check all users
  $(basename "$0") -u jkowalski     # check specific user
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

# Convert LDAP Generalized Time (YYYYMMDDHHmmssZ) to human-readable format
# and calculate days until expiry.
#
# Parameters:
#   $1 — Generalized Time string (e.g. "20260415120000Z")
#
# How it works:
#   1. Extract date components using bash substring expansion ${var:offset:length}
#   2. Reconstruct into a format that 'date' can parse
#   3. Calculate difference between expiry and now in days
parse_generalized_time() {
    local gt="$1"

    # Guard: if the value is empty or "0" (never expires), report that
    if [[ -z "${gt}" || "${gt}" == "0" ]]; then
        echo "NEVER (no expiry set)"
        return
    fi

    # Extract components from Generalized Time format
    # YYYYMMDDHHmmssZ
    # 20260415120000Z
    local year="${gt:0:4}"
    local month="${gt:4:2}"
    local day="${gt:6:2}"
    local hour="${gt:8:2}"
    local min="${gt:10:2}"
    local sec="${gt:12:2}"

    # Reconstruct into ISO 8601 format for the 'date' command
    local iso_date="${year}-${month}-${day}T${hour}:${min}:${sec}Z"

    # Convert to epoch seconds for calculation
    # date -d works on GNU date (Linux); on macOS use 'gdate' from coreutils
    local expiry_epoch
    expiry_epoch=$(date -d "${iso_date}" +%s 2>/dev/null) || {
        echo "${year}-${month}-${day} ${hour}:${min}:${sec} UTC (cannot calculate days)"
        return
    }

    local now_epoch
    now_epoch=$(date +%s)

    # Calculate days remaining (can be negative if already expired)
    local diff_seconds=$(( expiry_epoch - now_epoch ))
    local diff_days=$(( diff_seconds / 86400 ))

    local human_date="${year}-${month}-${day} ${hour}:${min}:${sec} UTC"

    if [[ ${diff_days} -lt 0 ]]; then
        echo "${human_date} (EXPIRED ${diff_days#-} days ago)"
    elif [[ ${diff_days} -eq 0 ]]; then
        echo "${human_date} (EXPIRES TODAY)"
    elif [[ ${diff_days} -le 14 ]]; then
        echo "${human_date} (expires in ${diff_days} days — WARNING)"
    else
        echo "${human_date} (expires in ${diff_days} days)"
    fi
}

# Query and display password info for a single user DN
# Parameters:
#   $1 — the uid of the user to check
check_user() {
    local uid="$1"

    # Search for the user and request both regular (*) and operational (+) attributes
    # We specifically ask for the attributes we need:
    #   uid, cn                    — identification
    #   passwordExpirationTime     — when password expires
    #   passwordRetryCount         — failed attempts counter
    #   accountUnlockTime          — when locked account unlocks
    #   createTimestamp            — when the entry was created
    #   modifyTimestamp            — when the entry was last modified
    #   nsAccountLock              — 389DS account lock flag (true = locked)
    local result
    result=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${PEOPLE_OU}" "(uid=${uid})" \
        -LLL \
        uid cn \
        passwordExpirationTime \
        passwordRetryCount \
        accountUnlockTime \
        nsAccountLock \
        createTimestamp \
        modifyTimestamp 2>/dev/null)

    # Check if user was found
    if [[ -z "${result}" || ! "${result}" =~ "dn:" ]]; then
        echo "  User '${uid}' not found in ${PEOPLE_OU}"
        return
    fi

    # Extract individual attribute values using grep + awk
    # grep -m1 = first match only; awk '{print $2}' = second field (after ": ")
    local cn
    cn=$(echo "${result}" | grep "^cn:" | head -1 | sed 's/^cn: //')
    local pwd_expiry
    pwd_expiry=$(echo "${result}" | grep "^passwordExpirationTime:" | awk '{print $2}')
    local retry_count
    retry_count=$(echo "${result}" | grep "^passwordRetryCount:" | awk '{print $2}')
    local unlock_time
    unlock_time=$(echo "${result}" | grep "^accountUnlockTime:" | awk '{print $2}')
    local account_lock
    account_lock=$(echo "${result}" | grep "^nsAccountLock:" | awk '{print $2}')
    local created
    created=$(echo "${result}" | grep "^createTimestamp:" | awk '{print $2}')
    local modified
    modified=$(echo "${result}" | grep "^modifyTimestamp:" | awk '{print $2}')

    # Display formatted output
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  User:              ${uid} (${cn:-N/A})"
    echo "  Password expiry:   $(parse_generalized_time "${pwd_expiry:-}")"
    echo "  Account locked:    ${account_lock:-false}"
    echo "  Failed attempts:   ${retry_count:-0}"

    if [[ -n "${unlock_time}" ]]; then
        echo "  Auto-unlock at:    $(parse_generalized_time "${unlock_time}")"
    fi

    echo "  Created:           $(parse_generalized_time "${created:-}")"
    echo "  Last modified:     $(parse_generalized_time "${modified:-}")"
    echo ""
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

TARGET_USER=""

while getopts "u:h" opt; do
    case ${opt} in
        u) TARGET_USER="${OPTARG}" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Check if ldapsearch is available
command -v ldapsearch >/dev/null 2>&1 || die "ldapsearch not found. Install: dnf install openldap-clients (RHEL) or apt install ldap-utils (Ubuntu)"

# Prompt for bind password once and store in a temp file
PASS_FILE=$(mktemp /tmp/.ldap-expiry-XXXXXX)
chmod 600 "${PASS_FILE}"
cleanup() { rm -f "${PASS_FILE}"; }
trap cleanup EXIT

read -rsp "Enter Directory Manager password: " BIND_PASS
echo ""
printf '%s' "${BIND_PASS}" > "${PASS_FILE}"
BIND_PASS=""

# =============================================================================
# MAIN LOGIC
# =============================================================================

echo ""
log "Checking password/account expiry information"
log "LDAP server: ${LDAP_URI}"
log "Search base: ${PEOPLE_OU}"
echo ""

if [[ -n "${TARGET_USER}" ]]; then
    # Check a single user
    check_user "${TARGET_USER}"
else
    # Get list of all UIDs in People OU
    # We search for all entries with objectClass=posixAccount to get only
    # actual user accounts (not OUs or other entries)
    UIDS=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${PEOPLE_OU}" "(objectClass=posixAccount)" uid \
        -LLL 2>/dev/null | grep "^uid:" | awk '{print $2}')

    if [[ -z "${UIDS}" ]]; then
        log "No users found in ${PEOPLE_OU}"
        exit 0
    fi

    # Count users for summary
    USER_COUNT=$(echo "${UIDS}" | wc -l)
    log "Found ${USER_COUNT} user(s):"
    echo ""

    # Iterate over each user and check their status
    # Password is read from PASS_FILE — no repeated prompts
    for uid in ${UIDS}; do
        check_user "${uid}"
    done
fi

log "Check complete."
