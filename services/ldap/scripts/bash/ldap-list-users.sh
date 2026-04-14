#!/bin/bash
# =============================================================================
# ldap-list-users.sh — List all LDAP users in 389 Directory Server
# =============================================================================
#
# DESCRIPTION:
#   Lists all user accounts in the LDAP directory with key POSIX attributes.
#   By default shows users from ou=People. With -a flag, also shows service
#   accounts from ou=Services.
#
#   Output modes:
#   - Default: compact table with uid, cn, uidNumber, gidNumber, shell
#   - Verbose (-v): full LDAP attributes for each user
#   - Count only (-c): just the number of accounts
#
# USAGE:
#   ./ldap-list-users.sh              # list users in ou=People
#   ./ldap-list-users.sh -a           # include ou=Services
#   ./ldap-list-users.sh -v           # verbose (all attributes)
#   ./ldap-list-users.sh -c           # count only
#   ./ldap-list-users.sh -g 10001     # filter by gidNumber (group)
#
# REQUIREMENTS:
#   - openldap-clients (ldapsearch)
#   - Network access to LDAP server on port 636 (LDAPS)
#
# LDAP CONCEPTS EXPLAINED:
#   - ldapsearch scope: "-s one" (onelevel) searches only direct children of
#     the base DN, not deeper subtrees. "-s sub" (subtree) searches everything
#     below, including nested OUs. We use "one" to list users in a single OU.
#   - LDIF output: ldapsearch returns entries in LDIF format by default.
#     -LLL suppresses comments, version info, and trailing blank lines.
#   - objectClass filter: (objectClass=posixAccount) matches only entries
#     that have POSIX attributes (uid, uidNumber, gidNumber, etc.).
#     This excludes OUs, groups, and other non-user entries.
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
Usage: $(basename "$0") [-a] [-v] [-c] [-g <gidNumber>] [-h]

Options:
  -a              Include service accounts (ou=Services)
  -v              Verbose — show all LDAP attributes per user
  -c              Count only — just print the number of accounts
  -g <gidNumber>  Filter by primary group (gidNumber)
  -h              Show this help

Examples:
  $(basename "$0")              # list all users in ou=People
  $(basename "$0") -a           # include service accounts
  $(basename "$0") -v           # verbose output
  $(basename "$0") -g 10001     # only linuxadmins members
EOF
    exit 1
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Pad a UTF-8 string to a given display width (right-pad with spaces).
# printf "%-Ns" pads by byte count, so multibyte chars (ś, ó, ł...) break
# column alignment. We truncate to N chars then append spaces to reach N.
pad_utf8() {
    local str="$1" width="$2"
    local len=${#str}
    if (( len > width )); then
        str="${str:0:width}"
        len=${width}
    fi
    printf '%s%*s' "${str}" $((width - len)) ""
}

die() {
    echo "[ERROR] $1" >&2
    exit 1
}

# List users from a given OU
# Parameters:
#   $1 — search base (OU DN)
#   $2 — LDAP filter
#   $3 — output mode: "table", "verbose", or "count"
list_ou() {
    local search_base="$1"
    local filter="$2"
    local mode="$3"

    # Build the ldapsearch command
    # -x  = simple bind (not SASL)
    # -H  = server URI
    # -D  = bind DN
    # -y  = read password from file (non-interactive)
    # -b  = search base
    # -s one = search only direct children (onelevel scope)
    # -LLL = clean LDIF output
    local result
    result=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${search_base}" -s one "${filter}" \
        -LLL \
        uid cn sn uidNumber gidNumber homeDirectory loginShell nsAccountLock \
        2>/dev/null)

    if [[ -z "${result}" ]]; then
        echo "  (no accounts found)"
        return 0
    fi

    case "${mode}" in
        verbose)
            # Just print the raw LDIF output — useful for debugging
            echo "${result}"
            ;;
        count)
            # Count entries by counting "dn:" lines
            local count
            count=$(echo "${result}" | grep -c "^dn:" || true)
            echo "  ${count} account(s)"
            ;;
        table)
            # Parse LDIF and format as a table
            # We read line by line, collecting attributes for each entry,
            # then print a formatted row when we hit a blank line (end of entry).
            echo ""
            # Columns are padded by character count (pad_utf8), not bytes,
            # so rows containing multibyte UTF-8 chars stay aligned.
            printf "  %s %s %s %s %s %s\n" \
                "$(pad_utf8 "UID" 16)" \
                "$(pad_utf8 "CN" 25)" \
                "$(pad_utf8 "UIDNUM" 8)" \
                "$(pad_utf8 "GIDNUM" 8)" \
                "$(pad_utf8 "SHELL" 15)" \
                "STATUS"
            printf "  %s %s %s %s %s %s\n" \
                "$(pad_utf8 "────────────────" 16)" \
                "$(pad_utf8 "─────────────────────────" 25)" \
                "$(pad_utf8 "────────" 8)" \
                "$(pad_utf8 "────────" 8)" \
                "$(pad_utf8 "───────────────" 15)" \
                "──────"

            local uid="" cn="" uidnum="" gidnum="" shell="" locked=""

            while IFS= read -r line; do
                if [[ -z "${line}" && -n "${uid}" ]]; then
                    # End of entry — print row
                    local status="active"
                    [[ "${locked,,}" == "true" ]] && status="LOCKED"

                    printf "  %s %s %s %s %s %s\n" \
                        "$(pad_utf8 "${uid}" 16)" \
                        "$(pad_utf8 "${cn}" 25)" \
                        "$(pad_utf8 "${uidnum}" 8)" \
                        "$(pad_utf8 "${gidnum}" 8)" \
                        "$(pad_utf8 "${shell}" 15)" \
                        "${status}"

                    # Reset for next entry
                    uid="" cn="" uidnum="" gidnum="" shell="" locked=""
                    continue
                fi

                # Parse attribute lines
                # LDAP returns UTF-8 as base64 when it contains non-ASCII chars
                # Format: "cn:: <base64>" vs "cn: <plaintext>"
                # NOTE: base64 patterns (`attr::`) must be checked BEFORE plain
                # patterns (`attr:`), because `attr:*` also matches `attr:: ...`
                # (the `*` swallows the second colon). ldapsearch emits base64
                # encoding (attr::) whenever a value contains non-ASCII chars.
                case "${line}" in
                    dn:*)           ;; # skip DN line
                    uid::*)         uid="$(echo "${line#uid:: }" | base64 -d)" ;;
                    uid:*)          uid="${line#uid: }" ;;
                    cn::*)          cn="$(echo "${line#cn:: }" | base64 -d)" ;;
                    cn:*)           cn="${line#cn: }" ;;
                    uidNumber:*)    uidnum="${line#uidNumber: }" ;;
                    gidNumber:*)    gidnum="${line#gidNumber: }" ;;
                    loginShell:*)   shell="${line#loginShell: }" ;;
                    nsAccountLock:*) locked="${line#nsAccountLock: }" ;;
                esac
            done <<< "${result}"

            # Handle last entry (if no trailing blank line)
            if [[ -n "${uid}" ]]; then
                local status="active"
                [[ "${locked,,}" == "true" ]] && status="LOCKED"
                printf "  %s %s %s %s %s %s\n" \
                    "$(pad_utf8 "${uid}" 16)" \
                    "$(pad_utf8 "${cn}" 25)" \
                    "$(pad_utf8 "${uidnum}" 8)" \
                    "$(pad_utf8 "${gidnum}" 8)" \
                    "$(pad_utf8 "${shell}" 15)" \
                    "${status}"
            fi
            echo ""
            ;;
    esac
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

INCLUDE_SERVICES="false"
OUTPUT_MODE="table"
GID_FILTER=""

while getopts "avcg:h" opt; do
    case ${opt} in
        a) INCLUDE_SERVICES="true" ;;
        v) OUTPUT_MODE="verbose" ;;
        c) OUTPUT_MODE="count" ;;
        g) GID_FILTER="${OPTARG}" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Check dependencies
command -v ldapsearch >/dev/null 2>&1 || die "ldapsearch not found."

# =============================================================================
# BIND PASSWORD
# =============================================================================
# Prompt once and store in a temp file. All ldapsearch calls use -y (read
# password from file) instead of -W (interactive prompt per call).
# The temp file is deleted automatically on script exit via trap.

PASS_FILE=$(mktemp /tmp/.ldap-list-XXXXXX)
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

# Build LDAP filter
# Base filter: all posixAccount entries
LDAP_FILTER="(objectClass=posixAccount)"

# If gidNumber filter is specified, combine with AND
# LDAP filter syntax: (&(filter1)(filter2)) = both must match
if [[ -n "${GID_FILTER}" ]]; then
    LDAP_FILTER="(&(objectClass=posixAccount)(gidNumber=${GID_FILTER}))"
fi

echo ""
log "LDAP User Listing"
log "Server: ${LDAP_URI}"
log "Filter: ${LDAP_FILTER}"
echo ""

# List People OU
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ou=People — User accounts"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
list_ou "${PEOPLE_OU}" "${LDAP_FILTER}" "${OUTPUT_MODE}"

# Optionally list Services OU
if [[ "${INCLUDE_SERVICES}" == "true" ]]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ou=Services — Service accounts"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    list_ou "${SERVICES_OU}" "${LDAP_FILTER}" "${OUTPUT_MODE}"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Done."
