# LDAP User Management Scripts

Practical scripts for managing user accounts in 389 Directory Server.
Created as part of **LAB-04** (LDAP — 389 Directory Server).

## Structure

```
scripts/
├── bash/                         # Standalone bash scripts
│   ├── ldap-list-users.sh        # List all users (table/verbose/count)
│   ├── ldap-create-user.sh       # Create a new POSIX user
│   ├── ldap-delete-user.sh       # Delete a user (with group cleanup)
│   ├── ldap-reset-password.sh    # Reset user password (manual or generated)
│   ├── ldap-lock-user.sh         # Lock or unlock an account
│   ├── ldap-check-expiry.sh      # Check password/account expiry
│   ├── ldap-list-locked.sh       # List locked accounts
│   ├── ldap-manage-group.sh      # Add/remove users from groups, list members
│   └── ldap-bulk-create.sh       # Bulk create users from CSV file
├── ansible/                      # Ansible playbooks (equivalent functionality)
│   ├── ansible.cfg               # Callback config — readable list output for debug tasks
│   ├── ldap-list-users.yml
│   ├── ldap-create-user.yml
│   ├── ldap-delete-user.yml
│   ├── ldap-reset-password.yml
│   ├── ldap-lock-user.yml
│   ├── ldap-check-expiry.yml
│   ├── ldap-list-locked.yml
│   ├── ldap-manage-group.yml
│   └── ldap-bulk-create.yml
├── templates/                    # Data files
│   └── users.csv                 # CSV template for bulk user creation
└── README.md                     # This file
```

## Quick Reference

### Bash scripts

Run these directly on any machine with `openldap-clients` (RHEL) or `ldap-utils` (Ubuntu) installed and network access to the LDAP server.

```bash
# List all users
./bash/ldap-list-users.sh                   # table format
./bash/ldap-list-users.sh -a                # include service accounts
./bash/ldap-list-users.sh -v                # verbose (all LDAP attributes)
./bash/ldap-list-users.sh -g 10001          # filter by group (linuxadmins)

# Create user
./bash/ldap-create-user.sh -u mwisniewska -f Maria -l Wiśniewska -n 20003

# Delete user
./bash/ldap-delete-user.sh -u mwisniewska
./bash/ldap-delete-user.sh -u mwisniewska --remove-from-groups

# Reset password
./bash/ldap-reset-password.sh -u jkowalski           # interactive
./bash/ldap-reset-password.sh -u jkowalski -g         # generate random

# Lock / unlock
./bash/ldap-lock-user.sh -u jkowalski -L    # lock
./bash/ldap-lock-user.sh -u jkowalski -U    # unlock

# Check expiry
./bash/ldap-check-expiry.sh                 # all users
./bash/ldap-check-expiry.sh -u jkowalski    # specific user

# List locked accounts
./bash/ldap-list-locked.sh
./bash/ldap-list-locked.sh -v               # verbose — show all accounts

# Group management
./bash/ldap-manage-group.sh -g linuxadmins -u jkowalski -A    # add to group
./bash/ldap-manage-group.sh -g linuxadmins -u jkowalski -R    # remove from group
./bash/ldap-manage-group.sh -g linuxadmins -M                  # list members
./bash/ldap-manage-group.sh -u jkowalski -G                    # list user's groups

# Bulk create from CSV
./bash/ldap-bulk-create.sh -f ../templates/users.csv --dry-run   # validate first
./bash/ldap-bulk-create.sh -f ../templates/users.csv             # create all
./bash/ldap-bulk-create.sh -f ../templates/users.csv --skip-existing
```

### Ansible playbooks

Run from the Ansible control node. Requires `community.general` collection and `python-ldap`.

```bash
# Install prerequisites
ansible-galaxy collection install community.general
pip install python-ldap

# Set bind password (or use Ansible Vault)
export LDAP_BIND_PASSWORD='YourDMPassword'

# List all users
ansible-playbook ansible/ldap-list-users.yml
ansible-playbook ansible/ldap-list-users.yml -e "include_services=true"
ansible-playbook ansible/ldap-list-users.yml -e "gid_filter=10001"

# Create user
ansible-playbook ansible/ldap-create-user.yml \
  -e "uid=mwisniewska first_name=Maria last_name=Wiśniewska uid_number=20003"

# Delete user
ansible-playbook ansible/ldap-delete-user.yml -e "uid=mwisniewska confirm=yes"
ansible-playbook ansible/ldap-delete-user.yml -e "uid=mwisniewska confirm=yes remove_from_groups=true"

# Reset password
ansible-playbook ansible/ldap-reset-password.yml -e "uid=jkowalski new_password=TempPass123!"
ansible-playbook ansible/ldap-reset-password.yml -e "uid=jkowalski generate_password=true"

# Lock / unlock
ansible-playbook ansible/ldap-lock-user.yml -e "uid=jkowalski action=lock"
ansible-playbook ansible/ldap-lock-user.yml -e "uid=jkowalski action=unlock"

# Check expiry
ansible-playbook ansible/ldap-check-expiry.yml
ansible-playbook ansible/ldap-check-expiry.yml -e "target_uid=jkowalski"

# List locked accounts
ansible-playbook ansible/ldap-list-locked.yml

# Group management
ansible-playbook ansible/ldap-manage-group.yml -e "group=linuxadmins uid=jkowalski action=add"
ansible-playbook ansible/ldap-manage-group.yml -e "group=linuxadmins uid=jkowalski action=remove"
ansible-playbook ansible/ldap-manage-group.yml -e "group=linuxadmins action=list"
ansible-playbook ansible/ldap-manage-group.yml -e "uid=jkowalski action=user-groups"

# Bulk create from CSV
ansible-playbook ansible/ldap-bulk-create.yml -e "csv_file=../templates/users.csv" --check  # dry run
ansible-playbook ansible/ldap-bulk-create.yml -e "csv_file=../templates/users.csv"
ansible-playbook ansible/ldap-bulk-create.yml -e "csv_file=../templates/users.csv skip_existing=true"
```

## CSV format rules

```
uid,first_name,last_name,uid_number,gid_number,login_shell,password
```

| Field | Allowed characters | Notes |
|---|---|---|
| `uid` | ASCII only (`[a-z0-9_-]`) | Used in `homeDirectory` path — LDAP IA5String syntax rejects non-ASCII |
| `first_name`, `last_name` | UTF-8 (Polish chars OK) | Stored in `cn`, `sn`, `givenName` — UTF8String syntax |
| `password` | ASCII only recommended | Non-ASCII passwords may fail PAM authentication on some systems |

**Wrong:** `kwójcik,Kamil,Wójcik,...` — ó in uid breaks LDAP `homeDirectory` attribute  
**Right:**  `kwojcik,Kamil,Wójcik,...` — ASCII uid, UTF-8 name

## Configuration

All scripts are pre-configured for the lab environment:

| Parameter | Value |
|---|---|
| LDAP URI | `ldaps://rhel-srv01.linux.lab.local:636` |
| Base DN | `dc=linux,dc=lab,dc=local` |
| People OU | `ou=People,dc=linux,dc=lab,dc=local` |
| Services OU | `ou=Services,dc=linux,dc=lab,dc=local` |
| Bind DN | `cn=Directory Manager` |
| Default GID | `10002` (linuxusers) |
| Default shell | `/bin/bash` |

To adapt for a different environment, edit the configuration section at the top of each script.

## Bash vs Ansible — when to use which?

| Scenario | Use Bash | Use Ansible |
|---|---|---|
| Quick one-off operation | ✅ | |
| Interactive troubleshooting | ✅ | |
| Repeatable, auditable process | | ✅ |
| Bulk operations from CSV/list | ✅ (with loop) | ✅ (with loop) |
| Part of larger automation | | ✅ |
| No Ansible installed | ✅ | |
| Idempotent (safe to re-run) | ❌ (scripts check manually) | ✅ (built-in) |
