#!/bin/bash
# =============================================================================
# ldap-create-user.sh — Create a new POSIX user in 389 Directory Server
# =============================================================================
#
# DESCRIPTION:
#   This script creates a new LDAP user with full POSIX attributes required
#   for Linux authentication via SSSD. The user is added to the People OU
#   and optionally assigned to an existing POSIX group.
#
#   The script uses ldapadd to create the LDIF entry and ldappasswd to set
#   the initial password. It connects over LDAPS (port 636) for security.
#
# USAGE:
#   ./ldap-create-user.sh -u <uid> -f <first_name> -l <last_name> \
#                          -n <uidNumber> [-g <gidNumber>] [-s <shell>]
#
# EXAMPLES:
#   # Create user with default group (linuxusers, gid 10002) and bash shell:
#   ./ldap-create-user.sh -u mwisniewska -f Maria -l Wiśniewska -n 20003
#
#   # Create user in linuxadmins group with zsh shell:
#   ./ldap-create-user.sh -u pnowicki -f Paweł -l Nowicki -n 20004 -g 10001 -s /bin/zsh
#
# REQUIREMENTS:
#   - openldap-clients (ldapadd, ldappasswd) installed
#   - Network access to LDAP server on port 636 (LDAPS)
#   - CA certificate trusted in system store (for TLS verification)
#   - Directory Manager credentials (or other bind DN with write access)
#
# LDAP CONCEPTS EXPLAINED:
#   - objectClass: inetOrgPerson — standard LDAP person class (cn, sn, uid)
#   - objectClass: posixAccount  — POSIX attributes (uidNumber, gidNumber,
#                                   homeDirectory, loginShell) required by
#                                   Linux NSS for user resolution
#   - objectClass: organizationalPerson — required by inetOrgPerson hierarchy
#   - dn (Distinguished Name) — unique path to the entry in the DIT tree,
#                                e.g. uid=jkowalski,ou=People,dc=linux,dc=lab,dc=local
#   - LDAPS (port 636) — LDAP over TLS, encrypts the entire connection
#                         including the bind (password) operation
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION — adjust these values for your environment
# =============================================================================

# LDAP server connection
LDAP_URI="ldaps://rhel-srv01.linux.lab.local:636"

# Base DN — the root of your DIT (Directory Information Tree)
BASE_DN="dc=linux,dc=lab,dc=local"

# OU where users are stored — SSSD searches this subtree
PEOPLE_OU="ou=People,${BASE_DN}"

# Bind DN — the account used to authenticate to LDAP for write operations
# Directory Manager has full access; in production, use a dedicated admin account
BIND_DN="cn=Directory Manager"

# Default values for optional parameters
DEFAULT_GID="10002"         # gidNumber of linuxusers group
DEFAULT_SHELL="/bin/bash"   # default login shell

# =============================================================================
# FUNCTIONS
# =============================================================================

# Print usage information and exit
usage() {
    cat <<EOF
Usage: $(basename "$0") -u <uid> -f <first_name> -l <last_name> -n <uidNumber> [-g <gidNumber>] [-s <shell>]

Required:
  -u  uid          Login name (e.g. mwisniewska)
  -f  first_name   First name / given name (cn will be "first last")
  -l  last_name    Last name / surname (sn attribute)
  -n  uidNumber    Numeric user ID (must be unique, e.g. 20003)

Optional:
  -g  gidNumber    Primary group ID (default: ${DEFAULT_GID} = linuxusers)
  -s  shell        Login shell (default: ${DEFAULT_SHELL})
  -h               Show this help

Example:
  $(basename "$0") -u mwisniewska -f Maria -l Wiśniewska -n 20003
EOF
    exit 1
}

# Print a message with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Print error message and exit
die() {
    echo "[ERROR] $1" >&2
    exit 1
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

# Initialize variables
UID_NAME=""
FIRST_NAME=""
LAST_NAME=""
UID_NUMBER=""
GID_NUMBER="${DEFAULT_GID}"
LOGIN_SHELL="${DEFAULT_SHELL}"

# Parse command-line options using getopts
# getopts is a bash built-in for parsing short options (-u, -f, etc.)
# The colon after a letter means that option requires an argument
while getopts "u:f:l:n:g:s:h" opt; do
    case ${opt} in
        u) UID_NAME="${OPTARG}" ;;
        f) FIRST_NAME="${OPTARG}" ;;
        l) LAST_NAME="${OPTARG}" ;;
        n) UID_NUMBER="${OPTARG}" ;;
        g) GID_NUMBER="${OPTARG}" ;;
        s) LOGIN_SHELL="${OPTARG}" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate that all required parameters are provided
[[ -z "${UID_NAME}" ]]   && die "Missing required parameter: -u <uid>"
[[ -z "${FIRST_NAME}" ]] && die "Missing required parameter: -f <first_name>"
[[ -z "${LAST_NAME}" ]]  && die "Missing required parameter: -l <last_name>"
[[ -z "${UID_NUMBER}" ]] && die "Missing required parameter: -n <uidNumber>"

# Validate that uidNumber is a positive integer
# =~ is bash regex match operator; ^[0-9]+$ matches only digits
[[ "${UID_NUMBER}" =~ ^[0-9]+$ ]] || die "uidNumber must be a positive integer, got: ${UID_NUMBER}"

# Construct the full common name (cn) from first and last name
CN="${FIRST_NAME} ${LAST_NAME}"

# Construct the Distinguished Name — the unique LDAP path for this user
USER_DN="uid=${UID_NAME},${PEOPLE_OU}"

# Home directory follows standard Linux convention
HOME_DIR="/home/${UID_NAME}"

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

log "Creating LDAP user: ${UID_NAME} (${CN})"
log "  DN:            ${USER_DN}"
log "  uidNumber:     ${UID_NUMBER}"
log "  gidNumber:     ${GID_NUMBER}"
log "  homeDirectory: ${HOME_DIR}"
log "  loginShell:    ${LOGIN_SHELL}"
echo ""

# Check if ldapadd is available
command -v ldapadd >/dev/null 2>&1 || die "ldapadd not found. Install: dnf install openldap-clients (RHEL) or apt install ldap-utils (Ubuntu)"

# Prompt for bind password once and store in a temp file
PASS_FILE=$(mktemp /tmp/.ldap-create-XXXXXX)
chmod 600 "${PASS_FILE}"
cleanup() { rm -f "${PASS_FILE}"; }
trap cleanup EXIT

read -rsp "Enter Directory Manager password: " BIND_PASS
echo ""
printf '%s' "${BIND_PASS}" > "${PASS_FILE}"
BIND_PASS=""

# Check if the user already exists in LDAP
# ldapsearch returns 0 if it finds entries; we check the result count
# -x = simple authentication, -b = search base, -s sub = search subtree
EXISTING=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
    -b "${PEOPLE_OU}" "(uid=${UID_NAME})" dn 2>/dev/null | grep -c "^dn:" || true)

if [[ "${EXISTING}" -gt 0 ]]; then
    die "User '${UID_NAME}' already exists in LDAP!"
fi

# =============================================================================
# CREATE THE USER ENTRY
# =============================================================================

# LDIF (LDAP Data Interchange Format) is the standard text format for
# representing LDAP entries. Each attribute is on its own line as "key: value".
# The blank line between entries signals the end of one entry.
#
# Here we use a heredoc (<<EOF) to pass the LDIF directly to ldapadd via stdin.
# -H  = LDAP server URI (ldaps:// for TLS)
# -D  = bind DN (who we authenticate as)
# -y  = read password from file (non-interactive)
# -x  = use simple authentication (not SASL)

log "Adding user entry to LDAP..."

ldapadd -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" <<EOF
dn: ${USER_DN}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: organizationalPerson
uid: ${UID_NAME}
cn: ${CN}
sn: ${LAST_NAME}
givenName: ${FIRST_NAME}
displayName: ${CN}
uidNumber: ${UID_NUMBER}
gidNumber: ${GID_NUMBER}
homeDirectory: ${HOME_DIR}
loginShell: ${LOGIN_SHELL}
EOF

if [[ $? -eq 0 ]]; then
    log "User entry created successfully."
else
    die "Failed to create user entry!"
fi

# =============================================================================
# SET THE USER'S PASSWORD
# =============================================================================

# ldappasswd sets or changes a user's password in LDAP.
# -S = prompt for new password (interactive)
# -H = server URI
# -D = bind DN
# -W = prompt for bind password
# The last argument is the DN of the user whose password we're setting.
#
# NOTE: In LAB-04 we discovered that ldappasswd via LDAPI sometimes doesn't
# work correctly. Over LDAPS it works fine. Alternative: use ldapmodify with
# plain text userPassword attribute (less secure but more reliable).

log "Setting password for ${UID_NAME}..."

echo "Enter new password for ${UID_NAME}:"
read -rsp "  New password: " USER_PASS
echo ""
read -rsp "  Confirm password: " USER_PASS_CONFIRM
echo ""

if [[ "${USER_PASS}" != "${USER_PASS_CONFIRM}" ]]; then
    die "Passwords do not match!"
fi

ldapmodify -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" <<EOF
dn: ${USER_DN}
changetype: modify
replace: userPassword
userPassword: ${USER_PASS}
EOF
USER_PASS=""
USER_PASS_CONFIRM=""

if [[ $? -eq 0 ]]; then
    log "Password set successfully."
else
    die "Failed to set password!"
fi

# =============================================================================
# VERIFICATION
# =============================================================================

log "Verifying user creation..."

# Search for the newly created user and display key attributes
# -LLL = clean output (no comments, no version line)
ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
    -b "${PEOPLE_OU}" "(uid=${UID_NAME})" \
    -LLL uid cn sn uidNumber gidNumber homeDirectory loginShell

echo ""
log "Done! User '${UID_NAME}' created in ${PEOPLE_OU}"
log ""
log "NEXT STEPS:"
log "  1. On SSSD clients, clear cache:  sss_cache -E && systemctl restart sssd"
log "  2. Verify resolution:             getent passwd ${UID_NAME}"
log "  3. Verify login:                  ssh ${UID_NAME}@<client-hostname>"
log "  4. Optionally add to a group:     ldapmodify to add memberUid to group entry"
