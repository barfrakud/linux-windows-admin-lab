#!/bin/bash
# =============================================================================
# ldap-reset-password.sh — Reset an LDAP user's password in 389DS
# =============================================================================
#
# DESCRIPTION:
#   Resets the password for an LDAP user account. This is the single most
#   common LDAP administrative operation — help desk password resets.
#
#   Two methods are supported:
#   1. Interactive — prompts for the new password (default)
#   2. Generated  — generates a random temporary password (-g flag)
#
#   The script also:
#   - Verifies the user exists before attempting the change
#   - Optionally forces password change on next login (if password policy supports it)
#   - Clears SSSD cache reminder after the reset
#
# USAGE:
#   ./ldap-reset-password.sh -u <uid>            # prompt for new password
#   ./ldap-reset-password.sh -u <uid> -g         # generate random password
#   ./ldap-reset-password.sh -u <uid> -p <pass>  # set specific password (insecure!)
#
# REQUIREMENTS:
#   - openldap-clients (ldapmodify, ldapsearch)
#   - Network access to LDAP server on port 636 (LDAPS)
#   - Directory Manager credentials
#
# LDAP CONCEPTS EXPLAINED:
#   - userPassword attribute: stores the user's password. In 389DS, when you
#     write a cleartext value, the server automatically hashes it using the
#     configured password storage scheme (default: PBKDF2_SHA256 in 389DS 2.x).
#     You NEVER store plaintext passwords in LDAP — the server handles hashing.
#
#   - passwordMustChange: 389DS operational attribute. When set to "on" by
#     a password policy, the user is forced to change their password on the
#     next LDAP bind. Not all clients (e.g., SSH via SSSD) honor this — it
#     depends on the PAM configuration.
#
#   - ldappasswd vs ldapmodify for password changes:
#     - ldappasswd: LDAP Extended Operation (RFC 3062). Server-side password
#       change with optional old password verification. Can trigger password
#       policy checks (history, min age, complexity).
#     - ldapmodify (replace userPassword): direct attribute modification.
#       When done by Directory Manager, bypasses password policy checks.
#       More reliable in our lab (as discovered in LAB-04).
#
#   - Security note: Always use LDAPS for password operations. Passwords
#     sent over unencrypted LDAP are visible in network captures.
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

# Random password settings
RANDOM_PASS_LENGTH=16

# =============================================================================
# FUNCTIONS
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") -u <uid> [-g] [-p <password>] [-h]

Required:
  -u <uid>       User login name

Password source (choose one):
  (default)      Prompt for new password interactively
  -g             Generate a random temporary password
  -p <password>  Set this specific password (NOT recommended — visible in history!)

Optional:
  -h             Show this help

Examples:
  $(basename "$0") -u jkowalski           # prompt for password
  $(basename "$0") -u jkowalski -g        # generate random password
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

# Generate a random password
# Uses /dev/urandom as the entropy source (Linux kernel random number generator).
# tr filters to printable characters, head limits the length.
# The character set includes uppercase, lowercase, digits, and common symbols.
generate_password() {
    local length="$1"
    # Read random bytes, filter to allowed characters, take desired length
    tr -dc 'A-Za-z0-9!@#$%&*+=' < /dev/urandom | head -c "${length}"
    echo ""
}

# Find user DN in People or Services OU
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

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

TARGET_USER=""
GENERATE_PASS="false"
EXPLICIT_PASS=""

while getopts "u:gp:h" opt; do
    case ${opt} in
        u) TARGET_USER="${OPTARG}" ;;
        g) GENERATE_PASS="true" ;;
        p) EXPLICIT_PASS="${OPTARG}" ;;
        h) usage ;;
        *) usage ;;
    esac
done

[[ -z "${TARGET_USER}" ]] && die "Missing required parameter: -u <uid>"

# Check dependencies
command -v ldapmodify >/dev/null 2>&1 || die "ldapmodify not found."
command -v ldapsearch >/dev/null 2>&1 || die "ldapsearch not found."

# Prompt for bind password once and store in a temp file
PASS_FILE=$(mktemp /tmp/.ldap-resetpw-XXXXXX)
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
log "LDAP Password Reset Tool"
log "Server: ${LDAP_URI}"
echo ""

# Step 1: Find user
log "Looking up user '${TARGET_USER}'..."
USER_DN=$(find_user_dn "${TARGET_USER}")

if [[ -z "${USER_DN}" ]]; then
    die "User '${TARGET_USER}' not found in LDAP."
fi

log "Found: ${USER_DN}"
echo ""

# Step 2: Determine new password
NEW_PASS=""

if [[ -n "${EXPLICIT_PASS}" ]]; then
    # Password provided on command line (insecure — visible in process list and shell history)
    NEW_PASS="${EXPLICIT_PASS}"
    log "WARNING: Password provided on command line. It may be visible in shell history."
    log "         Use 'history -d' to remove, or use -g (generate) or interactive mode."
elif [[ "${GENERATE_PASS}" == "true" ]]; then
    # Generate a random password
    NEW_PASS=$(generate_password "${RANDOM_PASS_LENGTH}")
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Generated temporary password for ${TARGET_USER}:"
    echo ""
    echo "  ${NEW_PASS}"
    echo ""
    echo "  Give this password to the user and instruct them to"
    echo "  change it immediately after first login."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
else
    # Interactive — prompt for password with confirmation
    echo "Enter new password for '${TARGET_USER}':"
    read -rsp "  New password: " NEW_PASS
    echo ""
    read -rsp "  Confirm password: " CONFIRM_PASS
    echo ""

    if [[ "${NEW_PASS}" != "${CONFIRM_PASS}" ]]; then
        die "Passwords do not match!"
    fi

    if [[ -z "${NEW_PASS}" ]]; then
        die "Password cannot be empty!"
    fi
fi

echo ""

# Step 3: Set the password using ldapmodify
# We use ldapmodify with "replace: userPassword" rather than ldappasswd
# because it's more reliable (as discovered in LAB-04).
# When Directory Manager sets userPassword, it bypasses password policy
# (min length, history, etc.) — appropriate for admin password resets.
log "Setting new password for '${TARGET_USER}'..."

ldapmodify -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" <<EOF
dn: ${USER_DN}
changetype: modify
replace: userPassword
userPassword: ${NEW_PASS}
EOF

if [[ $? -eq 0 ]]; then
    log "Password reset successfully for '${TARGET_USER}'."
else
    die "Failed to reset password!"
fi

# Step 4: Verify — try to check if the user can bind with new password
# Note: This is optional verification. It binds as the user to confirm
# the password works. This might fail if the account is locked.
echo ""
log "Verifying new password..."
if ldapsearch -x -H "${LDAP_URI}" -D "${USER_DN}" -w "${NEW_PASS}" \
    -b "${USER_DN}" -s base "(objectClass=*)" dn -LLL >/dev/null 2>&1; then
    log "Password verified — user can authenticate."
else
    log "WARNING: Password verification failed."
    log "  This might be because the account is locked (nsAccountLock=true)"
    log "  or because password policy rejected the new password."
fi

# Clear the password from the variable (security hygiene)
NEW_PASS=""
EXPLICIT_PASS=""

echo ""
log "Post-reset checklist:"
log "  1. Clear SSSD cache on clients: sss_cache -E && systemctl restart sssd"
log "  2. Inform the user of their new password (via secure channel)"
log "  3. Instruct the user to change their password on first login"
