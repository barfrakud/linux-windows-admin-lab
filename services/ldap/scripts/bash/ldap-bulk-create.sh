#!/bin/bash
# =============================================================================
# ldap-bulk-create.sh — Bulk create LDAP users from a CSV file
# =============================================================================
#
# DESCRIPTION:
#   Reads a CSV file with user data and creates multiple LDAP accounts
#   in a single run. This is the standard approach for onboarding batches
#   of users — HR provides a spreadsheet, admin converts to CSV, script
#   creates all accounts.
#
#   The script processes each line independently:
#   - Skips comments (lines starting with #) and empty lines
#   - Validates each row before attempting creation
#   - Reports success/failure per user
#   - Continues on error (one bad row doesn't stop the rest)
#   - Produces a summary at the end
#
# CSV FORMAT:
#   uid,first_name,last_name,uid_number,gid_number,login_shell,password
#
#   See templates/users.csv for a complete example with comments.
#
# USAGE:
#   ./ldap-bulk-create.sh -f users.csv                # create all users
#   ./ldap-bulk-create.sh -f users.csv --dry-run      # validate only, don't create
#   ./ldap-bulk-create.sh -f users.csv --skip-existing # skip users that already exist
#
# EXAMPLES:
#   # Standard bulk creation:
#   ./ldap-bulk-create.sh -f ../templates/users.csv
#
#   # Dry run first (recommended):
#   ./ldap-bulk-create.sh -f ../templates/users.csv --dry-run
#   # Review output, then:
#   ./ldap-bulk-create.sh -f ../templates/users.csv
#
# REQUIREMENTS:
#   - openldap-clients (ldapadd, ldapmodify, ldapsearch)
#   - Network access to LDAP server on port 636 (LDAPS)
#   - Directory Manager credentials
#
# LDAP CONCEPTS EXPLAINED:
#   - Batch operations: LDAP doesn't have a native "bulk create" operation.
#     Each entry is created individually via ldapadd. The script automates
#     the loop and error handling.
#
#   - LDIF batching: You CAN put multiple entries in a single LDIF file
#     (separated by blank lines) and feed it to ldapadd once. This is
#     faster (one connection) but if one entry fails, behavior depends
#     on the -c (continue) flag. Our approach of one-by-one gives better
#     error reporting.
#
#   - Password file (-y): For non-interactive use, the bind password can
#     be read from a file instead of prompting. This is essential for
#     batch operations. We use a temporary password file that's deleted
#     after the script finishes.
#
#   - uidNumber uniqueness: LDAP doesn't enforce unique uidNumber by default.
#     Two users CAN have the same uidNumber, which causes confusion.
#     The script checks for duplicates within the CSV and against existing
#     LDAP entries.
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

LDAP_URI="ldaps://rhel-srv01.linux.lab.local:636"
BASE_DN="dc=linux,dc=lab,dc=local"
PEOPLE_OU="ou=People,${BASE_DN}"
BIND_DN="cn=Directory Manager"

DEFAULT_GID="10002"
DEFAULT_SHELL="/bin/bash"

# =============================================================================
# FUNCTIONS
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") -f <csv_file> [--dry-run] [--skip-existing] [-h]

Required:
  -f <csv_file>     Path to CSV file with user data

Optional:
  --dry-run         Validate CSV and check for conflicts, but don't create users
  --skip-existing   Skip users that already exist (instead of reporting error)
  -h                Show this help

CSV format:
  uid,first_name,last_name,uid_number,gid_number,login_shell,password

  - gid_number, login_shell, password are optional (defaults: 10002, /bin/bash, none)
  - Lines starting with # are comments
  - See templates/users.csv for example

Examples:
  $(basename "$0") -f ../templates/users.csv --dry-run    # validate first
  $(basename "$0") -f ../templates/users.csv               # create users
EOF
    exit 1
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Print colored status messages
ok()   { echo "  ✅ $1"; }
skip() { echo "  ⏭️  $1"; }
fail() { echo "  ❌ $1"; }
warn() { echo "  ⚠️  $1"; }

# Check if a user already exists in LDAP
user_exists() {
    local uid="$1"
    local count
    count=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${PEOPLE_OU}" "(uid=${uid})" dn \
        -LLL 2>/dev/null | grep -c "^dn:" || true)
    [[ ${count} -gt 0 ]]
}

# Check if a uidNumber is already used
uidnumber_exists() {
    local uidnum="$1"
    local count
    count=$(ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
        -b "${BASE_DN}" "(uidNumber=${uidnum})" dn \
        -LLL 2>/dev/null | grep -c "^dn:" || true)
    [[ ${count} -gt 0 ]]
}

# Create a single user from parsed CSV fields
create_user() {
    local uid="$1"
    local first_name="$2"
    local last_name="$3"
    local uid_number="$4"
    local gid_number="${5:-${DEFAULT_GID}}"
    local login_shell="${6:-${DEFAULT_SHELL}}"
    local password="$7"

    local cn="${first_name} ${last_name}"
    local user_dn="uid=${uid},${PEOPLE_OU}"
    local home_dir="/home/${uid}"

    # Create the user entry
    # -y reads the bind password from a file (non-interactive)
    ldapadd -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" <<EOF 2>/dev/null
dn: ${user_dn}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: organizationalPerson
uid: ${uid}
cn: ${cn}
sn: ${last_name}
givenName: ${first_name}
displayName: ${cn}
uidNumber: ${uid_number}
gidNumber: ${gid_number}
homeDirectory: ${home_dir}
loginShell: ${login_shell}
EOF

    if [[ $? -ne 0 ]]; then
        return 1
    fi

    # Set password if provided
    if [[ -n "${password}" ]]; then
        ldapmodify -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" <<EOF 2>/dev/null
dn: ${user_dn}
changetype: modify
replace: userPassword
userPassword: ${password}
EOF
        if [[ $? -ne 0 ]]; then
            warn "${uid}: created but password set FAILED"
            return 0
        fi
    fi

    return 0
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

CSV_FILE=""
DRY_RUN="false"
SKIP_EXISTING="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f)
            CSV_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --skip-existing)
            SKIP_EXISTING="true"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "[ERROR] Unknown option: $1" >&2
            usage
            ;;
    esac
done

[[ -z "${CSV_FILE}" ]] && { echo "[ERROR] Missing -f <csv_file>" >&2; usage; }
[[ ! -f "${CSV_FILE}" ]] && { echo "[ERROR] File not found: ${CSV_FILE}" >&2; exit 1; }

# Check dependencies
command -v ldapadd >/dev/null 2>&1 || { echo "[ERROR] ldapadd not found." >&2; exit 1; }
command -v ldapsearch >/dev/null 2>&1 || { echo "[ERROR] ldapsearch not found." >&2; exit 1; }

# =============================================================================
# GET BIND PASSWORD
# =============================================================================
# For batch operations, we save the password to a temporary file so we don't
# have to prompt for every single user. The file is deleted on exit.
#
# mktemp creates a file with restrictive permissions (600 = owner read/write only).
# The trap ensures cleanup even if the script exits unexpectedly.

PASS_FILE=$(mktemp /tmp/.ldap-bulk-XXXXXX)
chmod 600 "${PASS_FILE}"

# Cleanup function — removes the password file on exit
cleanup() {
    rm -f "${PASS_FILE}"
}
trap cleanup EXIT

echo "Enter Directory Manager password (will be used for all operations):"
read -rsp "Password: " BIND_PASS
echo ""
printf '%s' "${BIND_PASS}" > "${PASS_FILE}"
# Clear the variable immediately — the file is enough
BIND_PASS=""

# Verify the password works
if ! ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -y "${PASS_FILE}" \
    -b "${BASE_DN}" -s base "(objectClass=*)" dn -LLL >/dev/null 2>&1; then
    echo "[ERROR] Cannot connect to LDAP or invalid credentials." >&2
    exit 1
fi

# =============================================================================
# PARSE AND VALIDATE CSV
# =============================================================================

echo ""
log "Bulk LDAP User Creation"
log "Server:   ${LDAP_URI}"
log "CSV file: ${CSV_FILE}"
log "Mode:     $(if [[ "${DRY_RUN}" == "true" ]]; then echo "DRY RUN (validate only)"; else echo "CREATE"; fi)"
echo ""

# Counters for summary
TOTAL=0
CREATED=0
SKIPPED=0
FAILED=0
ERRORS=()

# Track uidNumbers within this CSV to catch duplicates
declare -A SEEN_UIDS
declare -A SEEN_UIDNUMS

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Read CSV line by line
# IFS=, tells read to split on commas
# -r prevents backslash interpretation
LINE_NUM=0
while IFS= read -r line; do
    LINE_NUM=$((LINE_NUM + 1))

    # Skip comments and empty lines
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    TOTAL=$((TOTAL + 1))

    # Parse CSV fields
    # Using IFS=, with read to split the line into variables
    IFS=',' read -r uid first_name last_name uid_number gid_number login_shell password <<< "${line}"

    # Trim whitespace from fields
    uid=$(echo "${uid}" | xargs)
    first_name=$(echo "${first_name}" | xargs)
    last_name=$(echo "${last_name}" | xargs)
    uid_number=$(echo "${uid_number}" | xargs)
    gid_number=$(echo "${gid_number:-${DEFAULT_GID}}" | xargs)
    login_shell=$(echo "${login_shell:-${DEFAULT_SHELL}}" | xargs)
    password=$(echo "${password}" | xargs)

    # Apply defaults for empty optional fields
    [[ -z "${gid_number}" ]] && gid_number="${DEFAULT_GID}"
    [[ -z "${login_shell}" ]] && login_shell="${DEFAULT_SHELL}"

    echo "  [${LINE_NUM}] ${uid} (${first_name} ${last_name}) uid=${uid_number} gid=${gid_number}"

    # ---- Validation ----

    # Check required fields
    if [[ -z "${uid}" || -z "${first_name}" || -z "${last_name}" || -z "${uid_number}" ]]; then
        fail "Line ${LINE_NUM}: missing required field(s)"
        FAILED=$((FAILED + 1))
        ERRORS+=("Line ${LINE_NUM}: missing required field")
        continue
    fi

    # Check uidNumber is a number
    if ! [[ "${uid_number}" =~ ^[0-9]+$ ]]; then
        fail "Line ${LINE_NUM}: uid_number '${uid_number}' is not a number"
        FAILED=$((FAILED + 1))
        ERRORS+=("Line ${LINE_NUM}: invalid uid_number")
        continue
    fi

    # Check for duplicate uid within CSV
    if [[ -n "${SEEN_UIDS[${uid}]:-}" ]]; then
        fail "Line ${LINE_NUM}: duplicate uid '${uid}' (also on line ${SEEN_UIDS[${uid}]})"
        FAILED=$((FAILED + 1))
        ERRORS+=("Line ${LINE_NUM}: duplicate uid in CSV")
        continue
    fi
    SEEN_UIDS[${uid}]=${LINE_NUM}

    # Check for duplicate uidNumber within CSV
    if [[ -n "${SEEN_UIDNUMS[${uid_number}]:-}" ]]; then
        fail "Line ${LINE_NUM}: duplicate uidNumber ${uid_number} (also on line ${SEEN_UIDNUMS[${uid_number}]})"
        FAILED=$((FAILED + 1))
        ERRORS+=("Line ${LINE_NUM}: duplicate uidNumber in CSV")
        continue
    fi
    SEEN_UIDNUMS[${uid_number}]=${LINE_NUM}

    # Check if user already exists in LDAP
    if user_exists "${uid}"; then
        if [[ "${SKIP_EXISTING}" == "true" ]]; then
            skip "${uid}: already exists in LDAP (skipping)"
            SKIPPED=$((SKIPPED + 1))
            continue
        else
            fail "${uid}: already exists in LDAP"
            FAILED=$((FAILED + 1))
            ERRORS+=("${uid}: already exists")
            continue
        fi
    fi

    # Check if uidNumber is already used in LDAP
    if uidnumber_exists "${uid_number}"; then
        fail "${uid}: uidNumber ${uid_number} already in use in LDAP"
        FAILED=$((FAILED + 1))
        ERRORS+=("${uid}: uidNumber conflict")
        continue
    fi

    # ---- Create (or dry-run) ----

    if [[ "${DRY_RUN}" == "true" ]]; then
        ok "${uid}: validation passed (dry-run, not created)"
        CREATED=$((CREATED + 1))
    else
        if create_user "${uid}" "${first_name}" "${last_name}" "${uid_number}" \
                       "${gid_number}" "${login_shell}" "${password}"; then
            ok "${uid}: created successfully"
            CREATED=$((CREATED + 1))
        else
            fail "${uid}: creation FAILED"
            FAILED=$((FAILED + 1))
            ERRORS+=("${uid}: ldapadd failed")
        fi
    fi

done < "${CSV_FILE}"

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log "SUMMARY"
echo "  Total in CSV:  ${TOTAL}"
if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  Would create:  ${CREATED}"
else
    echo "  Created:       ${CREATED}"
fi
echo "  Skipped:       ${SKIPPED}"
echo "  Failed:        ${FAILED}"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "  ERRORS:"
    for err in "${ERRORS[@]}"; do
        echo "    - ${err}"
    done
fi

echo ""
if [[ "${DRY_RUN}" == "true" ]]; then
    log "Dry run complete. No changes made."
    log "To create users, run without --dry-run"
else
    log "Bulk creation complete."
    log ""
    log "NEXT STEPS:"
    log "  1. Clear SSSD cache on clients:  sss_cache -E && systemctl restart sssd"
    log "  2. Verify:  getent passwd <uid>"
    log "  3. Communicate passwords to users via secure channel"
fi
