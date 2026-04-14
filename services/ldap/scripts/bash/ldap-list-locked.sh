#!/bin/bash
# =============================================================================
# ldap-list-locked.sh — List locked LDAP user accounts in 389 Directory Server
# =============================================================================
#
# DESCRIPTION:
#   This script queries 389DS for accounts that are currently locked.
#   Accounts can be locked in two ways in 389DS:
#
#   1. ADMINISTRATIVELY LOCKED — the attribute nsAccountLock is set to "true".
#      This is a manual lock set by an administrator using ldapmodify or dsidm.
#      The account remains locked until an admin explicitly removes the attribute.
#
#   2. INTRUDER LOCKOUT — after too many failed password attempts, 389DS
#      automatically locks the account based on password policy settings:
#      - passwordLockout: on/off
#      - passwordMaxFailure: number of allowed failed attempts
#      - passwordLockoutDuration: how long the lockout lasts (seconds)
#      - passwordRetryCount: current failed attempt counter (operational attr)
#      - accountUnlockTime: when the lockout expires (operational attr)
#
#   This script checks BOTH types and displays a combined report.
#
# USAGE:
#   ./ldap-list-locked.sh          # list all locked accounts
#   ./ldap-list-locked.sh -v       # verbose — show all accounts with lock status
#
# REQUIREMENTS:
#   - openldap-clients (ldapsearch)
#   - Network access to LDAP server on port 636 (LDAPS)
#   - Bind credentials with read access to operational attributes
#
# LDAP CONCEPTS EXPLAINED:
#   - nsAccountLock: 389DS-specific attribute. When set to "true", the account
#     is locked and cannot authenticate. This is the administrative lock.
#   - passwordRetryCount: tracks consecutive failed bind attempts. Reset to 0
#     on successful authentication. When it reaches passwordMaxFailure, the
#     account is locked for passwordLockoutDuration seconds.
#   - accountUnlockTime: Generalized Time when the intruder lockout expires.
#     After this time, the account is automatically unlocked by 389DS.
#   - LDAP filter syntax: (attribute=value) for exact match,
#     (|(filter1)(filter2)) for OR, (&(filter1)(filter2)) for AND.
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
Usage: $(basename "$0") [-v] [-a] [-h]

Options:
  -v    Verbose — show ALL accounts with their lock status (not just locked ones)
  -a    Check all OUs (People + Services). Default: People only
  -h    Show this help

Examples:
  $(basename "$0")        # show only locked accounts in ou=People
  $(basename "$0") -v     # show all accounts with lock status
  $(basename "$0") -a     # include service accounts (ou=Services)
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

# Check a single OU for locked accounts
# Parameters:
#   $1 — search base (OU DN)
#   $2 — "verbose" or "locked-only"
check_ou() {
    local search_base="$1"
    local mode="$2"
    local locked_count=0
    local total_count=0

    log "Searching: ${search_base}"
    echo ""

    # Get all posixAccount entries with their lock-related attributes
    # We request both regular and operational attributes we need
    local result
    result=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${search_base}" "(objectClass=posixAccount)" \
        -LLL \
        uid cn \
        nsAccountLock \
        passwordRetryCount \
        accountUnlockTime 2>/dev/null)

    if [[ -z "${result}" ]]; then
        echo "  No accounts found."
        echo ""
        return
    fi

    # Process results entry by entry
    # LDIF entries are separated by blank lines. We parse line by line
    # and process each complete entry when we hit a blank line or EOF.
    local uid="" cn="" locked="" retries="" unlock_time=""

    # We use a while loop reading line by line from the ldapsearch output.
    # IFS= prevents trimming of leading whitespace.
    # -r prevents backslash interpretation.
    while IFS= read -r line || [[ -n "${uid}" ]]; do
        # Blank line or EOF = end of an entry, process it
        if [[ -z "${line}" && -n "${uid}" ]]; then
            total_count=$((total_count + 1))

            # Determine if account is locked
            local is_locked="false"
            local lock_reason=""

            # Check administrative lock
            if [[ "${locked,,}" == "true" ]]; then
                is_locked="true"
                lock_reason="ADMINISTRATIVE (nsAccountLock=true)"
            fi

            # Check intruder lockout (accountUnlockTime set and in the future)
            if [[ -n "${unlock_time}" && "${unlock_time}" != "0" ]]; then
                # Parse unlock time to check if still active
                local ut_year="${unlock_time:0:4}"
                local ut_month="${unlock_time:4:2}"
                local ut_day="${unlock_time:6:2}"
                local ut_hour="${unlock_time:8:2}"
                local ut_min="${unlock_time:10:2}"
                local ut_sec="${unlock_time:12:2}"
                local ut_iso="${ut_year}-${ut_month}-${ut_day}T${ut_hour}:${ut_min}:${ut_sec}Z"
                local ut_epoch
                ut_epoch=$(date -d "${ut_iso}" +%s 2>/dev/null || echo "0")
                local now_epoch
                now_epoch=$(date +%s)

                if [[ ${ut_epoch} -gt ${now_epoch} ]]; then
                    is_locked="true"
                    lock_reason="${lock_reason:+${lock_reason} + }INTRUDER LOCKOUT (unlocks at ${ut_year}-${ut_month}-${ut_day} ${ut_hour}:${ut_min} UTC)"
                fi
            fi

            # Display based on mode
            if [[ "${mode}" == "verbose" ]]; then
                if [[ "${is_locked}" == "true" ]]; then
                    echo "  🔒 ${uid} (${cn:-N/A}) — LOCKED: ${lock_reason}"
                    echo "     Failed attempts: ${retries:-0}"
                    locked_count=$((locked_count + 1))
                else
                    echo "  ✅ ${uid} (${cn:-N/A}) — active (failed attempts: ${retries:-0})"
                fi
            else
                # locked-only mode — show only locked accounts
                if [[ "${is_locked}" == "true" ]]; then
                    echo "  🔒 ${uid} (${cn:-N/A})"
                    echo "     Reason:          ${lock_reason}"
                    echo "     Failed attempts: ${retries:-0}"
                    echo ""
                    locked_count=$((locked_count + 1))
                fi
            fi

            # Reset for next entry
            uid="" cn="" locked="" retries="" unlock_time=""
            continue
        fi

        # Parse attribute lines
        # Each line in LDIF format is "attribute: value"
        case "${line}" in
            uid:*)                      uid="${line#uid: }" ;;
            cn:*)                       cn="${line#cn: }" ;;
            nsAccountLock:*)            locked="${line#nsAccountLock: }" ;;
            passwordRetryCount:*)       retries="${line#passwordRetryCount: }" ;;
            accountUnlockTime:*)        unlock_time="${line#accountUnlockTime: }" ;;
        esac
    done <<< "${result}"

    # Process the last entry (if no trailing blank line)
    if [[ -n "${uid}" ]]; then
        total_count=$((total_count + 1))
        local is_locked="false"
        if [[ "${locked,,}" == "true" ]]; then
            is_locked="true"
            locked_count=$((locked_count + 1))
        fi
        if [[ "${mode}" == "verbose" || "${is_locked}" == "true" ]]; then
            if [[ "${is_locked}" == "true" ]]; then
                echo "  🔒 ${uid} (${cn:-N/A}) — LOCKED"
            else
                echo "  ✅ ${uid} (${cn:-N/A}) — active"
            fi
        fi
    fi

    echo ""
    echo "  Summary: ${locked_count} locked / ${total_count} total accounts"
    echo ""
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

VERBOSE="false"
CHECK_ALL="false"

while getopts "vah" opt; do
    case ${opt} in
        v) VERBOSE="true" ;;
        a) CHECK_ALL="true" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Check dependencies
command -v ldapsearch >/dev/null 2>&1 || die "ldapsearch not found."

# Prompt for bind password once and store in a temp file
PASS_FILE=$(mktemp /tmp/.ldap-locked-XXXXXX)
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

MODE="locked-only"
[[ "${VERBOSE}" == "true" ]] && MODE="verbose"

echo ""
log "Listing locked LDAP accounts"
log "LDAP server: ${LDAP_URI}"
log "Mode: ${MODE}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Always check People OU
check_ou "${PEOPLE_OU}" "${MODE}"

# Optionally check Services OU
if [[ "${CHECK_ALL}" == "true" ]]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    check_ou "${SERVICES_OU}" "${MODE}"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Check complete."
echo ""
log "TIP: To unlock an account, use: ./ldap-lock-user.sh -u <uid> -U"
