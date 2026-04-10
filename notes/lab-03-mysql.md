# LAB-03: MySQL Server Administration

**Status:** Completed
**Machine:** rhel-web01 (Rocky Linux 9, VM — QEMU/KVM)
**Reference:** [lab-plan.md — LAB-03](../lab-plan.md)

### Lab context

| Element | Value |
|---|---|
| Host | rhel-web01 (10.10.10.21) |
| OS | Rocky Linux 9 (full VM — QEMU/KVM) |
| SELinux | Enforcing |
| Apache | Running (post-LAB-02) — MySQL extends this into a LAMP stack |
| Prerequisite | rhel-web01 post-LAB-02 (Apache running, SELinux enforcing). Proxmox snapshot taken before starting. |

**End state after this lab:**
- MySQL installed and secured on rhel-web01 (LAMP stack with Apache from LAB-02)
- Application database with role-separated users (app user, backup user)
- Sample dataset imported
- Server parameters tuned: network binding, slow query log, binary logging
- Automated backup script with rotation (cron-scheduled)
- Restore procedure verified
- SELinux contexts and firewall rules configured

---

## Step 1 — Install MySQL and run initial security hardening

### 1.1 — Install MySQL server package

```bash
dnf install -y mysql-server
```

Verify:
```bash
rpm -q mysql-server
mysqld --version
```

Result:
```
[root@rhel-web01 ~]# rpm -q mysql-server
mysql-server-8.0.45-1.el9_7.x86_64

[root@rhel-web01 ~]# mysqld --version
/usr/libexec/mysqld  Ver 8.0.45 for Linux on x86_64 (Source distribution)
```

### 1.2 — Start and enable MySQL service

```bash
systemctl enable --now mysqld
systemctl status mysqld
```

Verify MySQL is listening:
```bash
ss -tlnp | grep 3306
```

Result:
```
LISTEN 0      70                 *:33060            *:*    users:(("mysqld",pid=3204,fd=21))
LISTEN 0      151                *:3306             *:*    users:(("mysqld",pid=3204,fd=24))
```

### 1.3 — Run mysql_secure_installation

Securing the MySQL server deployment.
```bash
mysql_secure_installation
```

Recommended answers for lab environment:
```
Would you like to setup VALIDATE PASSWORD component? → y
Password validation policy (0=LOW, 1=MEDIUM, 2=STRONG) → 1
New root password → (set a strong password)
Re-enter new root password → (repeat)
Remove anonymous users? → y
Disallow root login remotely? → y
Remove test database and access to it? → y
Reload privilege tables now? → y
```

### 1.4 — Verify root login and MySQL version

```bash
mysql -u root -p -e "SELECT VERSION();"
mysql -u root -p -e "SHOW DATABASES;"
```

Alternative — using MYSQL_PWD environment variable (lab only, deprecated in production):
```bash
export MYSQL_PWD="<root_password>"
mysql -u root -e "SELECT VERSION();"
mysql -u root -e "SHOW DATABASES;"
```

Alternative — using ~/.my.cnf (recommended for production):
```bash
cat > ~/.my.cnf << 'EOF'
[client]
user=root
password=<root_password>
EOF
chmod 600 ~/.my.cnf

mysql -e "SELECT VERSION();"
mysql -e "SHOW DATABASES;"
```

Note on password methods:
- `-p` (interactive prompt) — safest, no password stored anywhere
- `MYSQL_PWD` env var — convenient for lab, but deprecated: visible in `/proc/<pid>/environ`, other users on the system can read it
- `~/.my.cnf` with chmod 600 — good balance: no typing, file readable only by owner, used by all mysql client tools automatically
- `mysql_config_editor` — stores credentials encrypted in `~/.mylogin.cnf`, most secure non-interactive option

Expected: only system databases remain (mysql, information_schema, performance_schema, sys). No `test` database.

Result:
```
[root@rhel-web01 ~]# mysql -u root -p -e "SELECT VERSION();"
Enter password: 
+-----------+
| VERSION() |
+-----------+
| 8.0.45    |
+-----------+
[root@rhel-web01 ~]# cat > ~/.my.cnf << 'EOF'
[client]
user=root
password=${VM_RHEL_WEB01_MYSQL_ROOT_PASSWORD}
EOF
chmod 600 ~/.my.cnf

mysql -e "SELECT VERSION();"
mysql -e "SHOW DATABASES;"
+-----------+
| VERSION() |
+-----------+
| 8.0.45    |
+-----------+
+--------------------+
| Database           |
+--------------------+
| information_schema |
| mysql              |
| performance_schema |
| sys                |
+--------------------+
```


---
### Notes

Zainstalowałem MySQL 8.0.45 z repozytorium Rocky Linux 9 (`dnf install -y mysql-server`). Uruchomiłem serwis i dodałem do autostartu (`systemctl enable --now mysqld`). MySQL nasłuchuje na portach 3306 (klasyczny protokół) i 33060 (X Protocol). Uruchomiłem `mysql_secure_installation` — ustawiłem hasło root, usunąłem anonimowych użytkowników, wyłączyłem zdalny login root, usunąłem bazę test. Skonfigurowałem `~/.my.cnf` z hasłem root w zmiennej środowiskowej, żeby nie wpisywać hasła za każdym razem. Weryfikacja: pozostały tylko bazy systemowe (information_schema, mysql, performance_schema, sys).

---
### Conclusion

#### What - Co zrobiłem?
Instalacja pakietu mysql-server 8.0.45 na rhel-web01, uruchomienie i włączenie serwisu mysqld, przeprowadzenie `mysql_secure_installation` (hasło root, usunięcie anonimowych użytkowników, wyłączenie zdalnego logowania root, usunięcie bazy test). Konfiguracja `~/.my.cnf` z poświadczeniami root dla wygody w labie.

---
#### Why - Dlaczego to zrobiłem?
MySQL to główny cel LAB-03. Instalacja na rhel-web01 (pełna VM z SELinux enforcing) zamiast na rhel-srv01 (LXC) pozwala ćwiczyć konteksty SELinux dla MySQL w kroku 7. `mysql_secure_installation` to standardowy pierwszy krok po instalacji — usuwa znane luki bezpieczeństwa w domyślnej konfiguracji MySQL.

---
#### Result - Co dzięki temu uzyskałem?
MySQL 8.0.45 działa na rhel-web01 obok Apache (początek LAMP stack). Serwis nasłuchuje na portach 3306 i 33060, uruchamia się automatycznie po restarcie. Domyślna konfiguracja zabezpieczona — brak anonimowych użytkowników, brak zdalnego root, brak bazy test. Logowanie root działa zarówno interaktywnie (`-p`) jak i przez `~/.my.cnf`.

---
#### Lesson Learned - Co się nauczyłem?
MySQL 8.0 nasłuchuje domyślnie na dwóch portach: 3306 (klasyczny protokół MySQL) i 33060 (X Protocol — nowszy protokół wspierający m.in. dokumentowy model danych). `mysql_secure_installation` to skrypt, który automatyzuje podstawowe hardening — w produkcji zawsze powinien być uruchomiony zaraz po instalacji. Metody podawania hasła MySQL mają różne poziomy bezpieczeństwa: interaktywny prompt jest najbezpieczniejszy, `~/.my.cnf` z chmod 600 to dobry kompromis, a zmienna `MYSQL_PWD` jest deprecated bo widoczna w `/proc/<pid>/environ`.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

## Step 2 — Create application database and role-separated users

### 2.1 — Create application database

```bash
mysql -u root -p
#or
mysql -u root
```

```sql
CREATE DATABASE webapp_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SHOW DATABASES;
```

### 2.2 — Create application user (read/write, limited privileges)

```sql
CREATE USER 'webapp_user'@'localhost' IDENTIFIED BY '<app_password>';
GRANT SELECT, INSERT, UPDATE, DELETE ON webapp_db.* TO 'webapp_user'@'localhost';
FLUSH PRIVILEGES;
```

This user can only read/write data — no DDL (CREATE, DROP, ALTER), no GRANT, no admin operations.

#### Verification

List of users configured user:
```sql
SELECT User FROM mysql.user;
```

Show privileges for webapp_user:
```sql
SHOW GRANTS FOR 'webapp_user'@'localhost';
```


### 2.3 — Create backup user (read-only + LOCK + RELOAD for mysqldump)

```sql
CREATE USER 'backup_user'@'localhost' IDENTIFIED BY '<backup_password>';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER ON webapp_db.* TO 'backup_user'@'localhost';
GRANT RELOAD, PROCESS ON *.* TO 'backup_user'@'localhost';
FLUSH PRIVILEGES;
```

Why these privileges:
- SELECT — read data for dump
- LOCK TABLES — consistent snapshot during mysqldump
- SHOW VIEW, EVENT, TRIGGER — dump views, events, triggers
- RELOAD — flush logs (needed for `--flush-logs`)
- PROCESS — see all threads (needed for `--single-transaction` info)

### 2.4 — Verify user privileges

```sql
SHOW GRANTS FOR 'webapp_user'@'localhost';
SHOW GRANTS FOR 'backup_user'@'localhost';
```

Test login as each user:
```bash
mysql -u webapp_user -p -e "USE webapp_db; SELECT 1;"
mysql -u backup_user -p -e "USE webapp_db; SELECT 1;"
```

Result:
```
[root@rhel-web01 ~]# mysql -u webapp_user -p -e "USE webapp_db; SELECT 1;"
Enter password: 
+---+
| 1 |
+---+
| 1 |
+---+
[root@rhel-web01 ~]# mysql -u backup_user -p -e "USE webapp_db; SELECT 1;"
Enter password: 
+---+
| 1 |
+---+
| 1 |
+---+
```

---
### Notes

Utworzyłem bazę danych `webapp_db` z kodowaniem utf8mb4. Utworzyłem dwóch użytkowników z rozdzielonymi rolami: `webapp_user` (SELECT, INSERT, UPDATE, DELETE na webapp_db — tylko operacje DML) oraz `backup_user` (SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER na webapp_db + RELOAD, PROCESS globalnie — minimum potrzebne do mysqldump). Zweryfikowałem logowanie obu użytkowników i dostęp do bazy.

---
### Conclusion

#### What - Co zrobiłem?
Utworzenie bazy `webapp_db` (utf8mb4/utf8mb4_unicode_ci) oraz dwóch użytkowników z rozdzielonymi uprawnieniami: `webapp_user` (DML only — SELECT/INSERT/UPDATE/DELETE) i `backup_user` (uprawnienia potrzebne do mysqldump: SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER + globalne RELOAD i PROCESS).

---
#### Why - Dlaczego to zrobiłem?
Zasada least privilege — każdy użytkownik dostaje tylko te uprawnienia, których potrzebuje do swojej funkcji. Aplikacja nie powinna mieć uprawnień do DROP/ALTER/GRANT, a użytkownik backupowy nie potrzebuje prawa do zapisu danych. Rozdzielenie ról ogranicza skutki ewentualnego przejęcia jednego z kont.

---
#### Result - Co dzięki temu uzyskałem?
Baza webapp_db gotowa do importu danych (Step 3). Dwóch użytkowników z rozdzielonymi rolami — webapp_user do operacji aplikacyjnych, backup_user do tworzenia kopii zapasowych. Oba konta zweryfikowane — logowanie działa, dostęp do bazy potwierdzony.

---
#### Lesson Learned - Co się nauczyłem?
W MySQL uprawnienia dzielą się na poziomy: globalny (`*.*`), bazodanowy (`webapp_db.*`), tabelowy i kolumnowy. backup_user potrzebuje uprawnień na dwóch poziomach — bazodanowym (SELECT, LOCK TABLES itp. na webapp_db) i globalnym (RELOAD, PROCESS na `*.*`), bo te operacje nie są per-database. FLUSH PRIVILEGES wymusza natychmiastowe przeładowanie tablic uprawnień — bez tego zmiany mogą nie być widoczne od razu. Kodowanie utf8mb4 to "prawdziwy" UTF-8 w MySQL (obsługuje 4 bajty, w tym emoji), podczas gdy starszy utf8 (alias utf8mb3) obsługuje tylko 3 bajty.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

## Step 3 — Import sample dataset

### 3.1 — Create sample schema and data as SQL file

Create file `/root/sample-data.sql`:
```sql
USE webapp_db;

CREATE TABLE departments (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE employees (
    id INT AUTO_INCREMENT PRIMARY KEY,
    first_name VARCHAR(50) NOT NULL,
    last_name VARCHAR(50) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    department_id INT,
    hire_date DATE NOT NULL,
    salary DECIMAL(10,2),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (department_id) REFERENCES departments(id)
);

INSERT INTO departments (name) VALUES
    ('IT'),
    ('HR'),
    ('Finance'),
    ('Operations');

INSERT INTO employees (first_name, last_name, email, department_id, hire_date, salary) VALUES
    ('Jan', 'Kowalski', 'jan.kowalski@lab.local', 1, '2024-03-15', 12000.00),
    ('Anna', 'Nowak', 'anna.nowak@lab.local', 1, '2024-06-01', 11500.00),
    ('Piotr', 'Wiśniewski', 'piotr.wisniewski@lab.local', 2, '2023-09-10', 9500.00),
    ('Maria', 'Wójcik', 'maria.wojcik@lab.local', 3, '2025-01-20', 10500.00),
    ('Tomasz', 'Kamiński', 'tomasz.kaminski@lab.local', 4, '2024-11-05', 8800.00);
```

### 3.2 — Import the dataset as root

```bash
mysql -u root -p < /root/sample-data.sql
```

### 3.3 — Verify data as webapp_user

```bash
mysql -u webapp_user -p -e "
  USE webapp_db;
  SHOW TABLES;
  SELECT e.first_name, e.last_name, d.name AS department
  FROM employees e JOIN departments d ON e.department_id = d.id;
"
```
Result:
```
[root@rhel-web01 ~]# mysql -u webapp_user -p -e "
  USE webapp_db;
  SHOW TABLES;
  SELECT e.first_name, e.last_name, d.name AS department
  FROM employees e JOIN departments d ON e.department_id = d.id;
"
Enter password: 
+---------------------+
| Tables_in_webapp_db |
+---------------------+
| departments         |
| employees           |
+---------------------+
+------------+-------------+------------+
| first_name | last_name   | department |
+------------+-------------+------------+
| Jan        | Kowalski    | IT         |
| Anna       | Nowak       | IT         |
| Piotr      | Wiśniewski  | HR         |
| Maria      | Wójcik      | Finance    |
| Tomasz     | Kamiński    | Operations |
+------------+-------------+------------+
```
### 3.4 — Verify webapp_user cannot modify schema

```bash
mysql -u webapp_user -p -e "USE webapp_db; DROP TABLE employees;"
```

Expected: `ERROR 1142 (42000): DROP command denied to user 'webapp_user'@'localhost'`

Result:
```
[root@rhel-web01 ~]# mysql -u webapp_user -p -e "USE webapp_db; DROP TABLE employees;"
Enter password: 
ERROR 1142 (42000) at line 1: DROP command denied to user 'webapp_user'@'localhost' for table 'employees'
```
---
### Notes

Utworzyłem plik `/root/sample-data.sql` z dwoma tabelami (departments, employees) powiązanymi kluczem obcym. Zaimportowałem dane jako root (`mysql -u root -p < /root/sample-data.sql`). Zweryfikowałem dostęp jako webapp_user — dane widoczne, JOIN działa poprawnie (5 pracowników, 4 departamenty). Potwierdziłem, że webapp_user nie może wykonać DROP TABLE — błąd `ERROR 1142 (42000): DROP command denied`.

---
### Conclusion

#### What - Co zrobiłem?
Utworzenie schematu bazy webapp_db: tabela `departments` (id, name, created_at) i `employees` (id, first_name, last_name, email, department_id, hire_date, salary, created_at) z kluczem obcym na department_id. Import 4 departamentów i 5 pracowników z pliku SQL. Weryfikacja danych jako webapp_user i test ograniczeń uprawnień (DROP denied).

---
#### Why - Dlaczego to zrobiłem?
Baza potrzebuje danych testowych, żeby w kolejnych krokach móc weryfikować backup/restore (Step 5–6) i obserwować zapytania w slow query log (Step 4). Schemat z kluczem obcym i JOINem jest bliższy rzeczywistej aplikacji niż pojedyncza tabela.

---
#### Result - Co dzięki temu uzyskałem?
Baza webapp_db zawiera dwie powiązane tabele z danymi testowymi. webapp_user może czytać i łączyć dane (SELECT, JOIN), ale nie może modyfikować schematu (DROP denied). Dane gotowe do backupu w Step 5.

---
#### Lesson Learned - Co się nauczyłem?
Import danych z pliku SQL (`mysql < file.sql`) wymaga uprawnień CREATE TABLE — dlatego import robiony jest jako root, a nie jako webapp_user. Klucz obcy (FOREIGN KEY) wymusza integralność referencyjna — nie można wstawić pracownika z department_id, który nie istnieje w tabeli departments. Weryfikacja negatywna (próba DROP jako webapp_user) jest równie ważna jak pozytywna — potwierdza, że rozdzielenie uprawnień z kroku 2 działa poprawnie.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

## Step 4 — Configure server parameters: network binding, slow query log, binary logging

### 4.1 — Create custom MySQL configuration file

Create `/etc/my.cnf.d/lab-custom.cnf`:
```ini
[mysqld]
# --- Network binding ---
# Listen only on localhost — no remote connections
bind-address = 127.0.0.1
port = 3306

# --- Slow query log ---
# Log queries taking longer than 1 second
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow-query.log
long_query_time = 1

# --- Binary logging (for point-in-time recovery) ---
log_bin = /var/log/mysql/mysql-bin
binlog_expire_logs_seconds = 604800
max_binlog_size = 100M

# --- General tuning ---
innodb_buffer_pool_size = 256M
max_connections = 50
```

### 4.2 — Create log directory and set permissions

```bash
mkdir -p /var/log/mysql
chown mysql:mysql /var/log/mysql
chmod 750 /var/log/mysql
```

### 4.3 — Restart MySQL and verify

```bash
systemctl restart mysqld
systemctl status mysqld
```

Verify settings:
```bash
mysql -u root -e "
  SHOW VARIABLES LIKE 'bind_address';
  SHOW VARIABLES LIKE 'slow_query_log%';
  SHOW VARIABLES LIKE 'long_query_time';
  SHOW VARIABLES LIKE 'log_bin%';
  SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
  SHOW VARIABLES LIKE 'max_connections';
"
```

Result:
```
[root@rhel-web01 ~]# mysql -u root -e "
  SHOW VARIABLES LIKE 'bind_address';
  SHOW VARIABLES LIKE 'slow_query_log%';
  SHOW VARIABLES LIKE 'long_query_time';
  SHOW VARIABLES LIKE 'log_bin%';
  SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
  SHOW VARIABLES LIKE 'max_connections';
"
+---------------+-----------+
| Variable_name | Value     |
+---------------+-----------+
| bind_address  | 127.0.0.1 |
+---------------+-----------+
+---------------------+-------------------------------+
| Variable_name       | Value                         |
+---------------------+-------------------------------+
| slow_query_log      | ON                            |
| slow_query_log_file | /var/log/mysql/slow-query.log |
+---------------------+-------------------------------+
+-----------------+----------+
| Variable_name   | Value    |
+-----------------+----------+
| long_query_time | 1.000000 |
+-----------------+----------+
+---------------------------------+--------------------------------+
| Variable_name                   | Value                          |
+---------------------------------+--------------------------------+
| log_bin                         | ON                             |
| log_bin_basename                | /var/log/mysql/mysql-bin       |
| log_bin_index                   | /var/log/mysql/mysql-bin.index |
| log_bin_trust_function_creators | OFF                            |
| log_bin_use_v1_row_events       | OFF                            |
+---------------------------------+--------------------------------+
+-------------------------+-----------+
| Variable_name           | Value     |
+-------------------------+-----------+
| innodb_buffer_pool_size | 268435456 |
+-------------------------+-----------+
+-----------------+-------+
| Variable_name   | Value |
+-----------------+-------+
| max_connections | 50    |
+-----------------+-------+
```

### 4.4 — Test slow query log

Generate a slow query to verify logging:
```bash
mysql -u root -e "SELECT SLEEP(2);"
cat /var/log/mysql/slow-query.log
```

Expected: the `SELECT SLEEP(2)` query appears in the slow log with `Query_time: 2.0...`.

Result:
```
[root@rhel-web01 ~]# mysql -u root -e "SELECT SLEEP(2);"
+----------+
| SLEEP(2) |
+----------+
|        0 |
+----------+
[root@rhel-web01 ~]# cat /var/log/mysql/slow-query.log
/usr/libexec/mysqld, Version: 8.0.45 (Source distribution). started with:
Tcp port: 3306  Unix socket: /var/lib/mysql/mysql.sock
Time                 Id Command    Argument
# Time: 2026-04-10T09:10:53.527979Z
# User@Host: root[root] @ localhost []  Id:    10
# Query_time: 2.000319  Lock_time: 0.000000 Rows_sent: 1  Rows_examined: 1
SET timestamp=1775812251;
SELECT SLEEP(2);
```

---
### Notes

Utworzyłem plik konfiguracyjny `/etc/my.cnf.d/lab-custom.cnf` z parametrami: bind-address=127.0.0.1 (tylko localhost), slow_query_log z progiem 1s, binary logging do `/var/log/mysql/`, innodb_buffer_pool_size=256M, max_connections=50. Utworzyłem katalog `/var/log/mysql` z właścicielem mysql:mysql. Po restarcie mysqld wszystkie parametry potwierdzone przez SHOW VARIABLES. Test slow query log: `SELECT SLEEP(2)` pojawił się w logu z Query_time: 2.000319.

---
### Conclusion

#### What - Co zrobiłem?
Utworzenie pliku `/etc/my.cnf.d/lab-custom.cnf` z konfiguracją: bind-address 127.0.0.1, slow query log (próg 1s, plik `/var/log/mysql/slow-query.log`), binary logging (`/var/log/mysql/mysql-bin`, retencja 7 dni, max 100M per plik), innodb_buffer_pool_size 256M, max_connections 50. Utworzenie katalogu logów z odpowiednimi uprawnieniami. Restart MySQL i weryfikacja wszystkich parametrów.

---
#### Why - Dlaczego to zrobiłem?
bind-address=127.0.0.1 ogranicza MySQL do połączeń lokalnych — w LAMP stack Apache łączy się z MySQL na tym samym hoście, więc nie ma potrzeby wystawiania portu na sieć. Slow query log pozwala identyfikować wolne zapytania (kluczowe w diagnostyce wydajności). Binary logging rejestruje wszystkie zmiany danych i umożliwia point-in-time recovery — odtworzenie bazy do dowolnego momentu między backupami.

---
#### Result - Co dzięki temu uzyskałem?
MySQL nasłuchuje wyłącznie na 127.0.0.1:3306 (nie jest dostępny zdalnie). Slow query log działa — zapytania trwające dłużej niż 1s są logowane z pełnymi metadanymi (czas, użytkownik, query_time, rows). Binary logging włączony — pliki binlog w `/var/log/mysql/` z automatyczną rotacją po 7 dniach. InnoDB buffer pool ustawiony na 256M (przy 2 GB RAM to rozsądna wartość).

---
#### Lesson Learned - Co się nauczyłem?
MySQL na Rocky Linux 9 czyta konfigurację z `/etc/my.cnf.d/*.cnf` — tworzenie osobnego pliku (`lab-custom.cnf`) zamiast edycji głównego `/etc/my.cnf` jest czystsze i łatwiejsze do zarządzania (np. przez Ansible). Slow query log zawiera nie tylko treść zapytania, ale też metadane: Query_time, Lock_time, Rows_sent, Rows_examined — te wartości pomagają diagnozować, czy problem to wolne zapytanie, blokada, czy skanowanie zbyt wielu wierszy. Binary logging (`log_bin`) to nie to samo co general query log — binlog rejestruje tylko zmiany danych (INSERT/UPDATE/DELETE) w formacie binarnym, a nie wszystkie zapytania. `innodb_buffer_pool_size` to najważniejszy parametr wydajnościowy InnoDB — określa ile danych i indeksów MySQL trzyma w pamięci RAM zamiast czytać z dysku.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

## Step 5 — Implement automated backup script with rotation (cron-scheduled)

### 5.1 — Store backup credentials securely

Create `/root/.my-backup.cnf`:
```ini
[mysqldump]
user=backup_user
password=VM_RHEL_WEB01_MYSQL_BACKUP_USER_PASSWORD
```

```bash
chmod 600 /root/.my-backup.cnf
```

### 5.2 — Create backup script

Create `/usr/local/bin/mysql-backup.sh`:
```bash
#!/bin/bash
# MySQL backup script with rotation
# Usage: called by cron, no arguments needed

BACKUP_DIR="/var/backup/mysql"
RETENTION_DAYS=7
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/webapp_db_${DATE}.sql.gz"
LOG_FILE="/var/log/mysql/backup.log"

# Create backup directory if not exists
mkdir -p "${BACKUP_DIR}"

# Run mysqldump with backup user credentials
mysqldump --defaults-extra-file=/root/.my-backup.cnf \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --flush-logs \
    webapp_db | gzip > "${BACKUP_FILE}"

# Check result
if [ $? -eq 0 ]; then
    SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
    echo "${DATE} — OK — ${BACKUP_FILE} (${SIZE})" >> "${LOG_FILE}"
else
    echo "${DATE} — FAILED — mysqldump error" >> "${LOG_FILE}"
    exit 1
fi

# Rotate: remove backups older than RETENTION_DAYS
find "${BACKUP_DIR}" -name "webapp_db_*.sql.gz" -mtime +${RETENTION_DAYS} -delete

# Log rotation cleanup
DELETED=$(find "${BACKUP_DIR}" -name "webapp_db_*.sql.gz" -mtime +${RETENTION_DAYS} -delete -print | wc -l)
echo "${DATE} — Rotation: removed ${DELETED} old backups" >> "${LOG_FILE}"
```

```bash
chmod 700 /usr/local/bin/mysql-backup.sh
```

### 5.3 — Create backup directory

```bash
mkdir -p /var/backup/mysql
chmod 700 /var/backup/mysql
```

### 5.4 — Test backup script manually

```bash
/usr/local/bin/mysql-backup.sh
ls -la /var/backup/mysql/
cat /var/log/mysql/backup.log
```

Verify backup content:
```bash
zcat /var/backup/mysql/webapp_db_*.sql.gz | head -30
```

Result:
```
[root@rhel-web01 ~]# ls -la /var/backup/mysql/
total 0
drwx------. 2 root root  6 Apr 10 11:19 .
drwxr-xr-x. 3 root root 19 Apr 10 11:19 ..
[root@rhel-web01 ~]# /usr/local/bin/mysql-backup.sh
[root@rhel-web01 ~]# ls -la /var/backup/mysql/
total 4
drwx------. 2 root root   46 Apr 10 11:19 .
drwxr-xr-x. 3 root root   19 Apr 10 11:19 ..
-rw-r--r--. 1 root root 1213 Apr 10 11:19 webapp_db_20260410_111946.sql.gz
[root@rhel-web01 ~]# cat /var/log/mysql/backup.log
20260410_111946 — OK — /var/backup/mysql/webapp_db_20260410_111946.sql.gz (4.0K)
20260410_111946 — Rotation: removed 0 old backups
[root@rhel-web01 ~]# zcat /var/backup/mysql/webapp_db_*.sql.gz | head -30
-- MySQL dump 10.13  Distrib 8.0.45, for Linux (x86_64)
--
-- Host: localhost    Database: webapp_db
-- ------------------------------------------------------
-- Server version       8.0.45

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!50503 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `departments`
--

DROP TABLE IF EXISTS `departments`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `departments` (
  `id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL,
  `created_at` timestamp NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=5 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
[root@rhel-web01 ~]# 
```
### 5.5 — Schedule with cron (daily at 02:00)

```bash
crontab -e
```

Add line:
```
0 2 * * * /usr/local/bin/mysql-backup.sh
```

Verify:
```bash
crontab -l
```

Result:
```
[root@rhel-web01 ~]# crontab -l
0 2 * * * /usr/local/bin/mysql-backup.sh
```

---
### Notes

Utworzyłem plik `/root/.my-backup.cnf` z poświadczeniami backup_user (chmod 600). Napisałem skrypt `/usr/local/bin/mysql-backup.sh`, który robi mysqldump bazy webapp_db z kompresją gzip, loguje wynik do `/var/log/mysql/backup.log` i rotuje backupy starsze niż 7 dni. Test ręczny: backup `webapp_db_20260410_111946.sql.gz` (1213 B) utworzony poprawnie, log OK, zawartość dumpa zawiera pełną strukturę tabel i dane. Cron ustawiony na codziennie o 02:00.

---
### Conclusion

#### What - Co zrobiłem?
Utworzenie pliku poświadczeń `/root/.my-backup.cnf` dla backup_user (chmod 600). Napisanie skryptu `/usr/local/bin/mysql-backup.sh` — mysqldump z opcjami `--single-transaction --routines --triggers --events --flush-logs`, kompresja gzip, logowanie wyniku, rotacja backupów starszych niż 7 dni. Test ręczny i zaplanowanie w cronie na 02:00.

---
#### Why - Dlaczego to zrobiłem?
Automatyczny backup to podstawa disaster recovery. Skrypt używa dedykowanego backup_user (nie root) zgodnie z zasadą least privilege. Poświadczenia w osobnym pliku z chmod 600 zamiast w linii komend (hasło w `ps aux` byłoby widoczne). Rotacja zapobiega zapełnieniu dysku. `--single-transaction` zapewnia spójny snapshot bez blokowania tabel (działa z InnoDB). `--flush-logs` rotuje binlogi przy każdym backupie, co ułatwia point-in-time recovery.

---
#### Result - Co dzięki temu uzyskałem?
Automatyczny backup bazy webapp_db codziennie o 02:00. Backup skompresowany (~1.2 KB dla testowych danych), logowany do `/var/log/mysql/backup.log`. Stare backupy automatycznie usuwane po 7 dniach. Dump zawiera pełną strukturę (CREATE TABLE, DROP TABLE IF EXISTS) i dane — gotowy do restore.

---
#### Lesson Learned - Co się nauczyłem?
`--defaults-extra-file` w mysqldump pozwala podać plik z poświadczeniami zamiast hasła w linii komend. `--single-transaction` używa transakcji InnoDB do uzyskania spójnego snapshotu bez LOCK TABLES — kluczowe dla produkcji, gdzie blokowanie tabel oznacza przestój. Dump mysqldump zawiera komendy `/*!40101 ... */` — to warunkowe komentarze MySQL, które ustawiają zmienne sesji (character set, foreign key checks) i są wykonywane tylko przez MySQL, ignorowane przez inne bazy. Sprawdzanie `$?` po poleceniu z pipe (`mysqldump | gzip`) sprawdza kod wyjścia ostatniego polecenia w pipe (gzip) — w produkcji lepiej użyć `set -o pipefail`, żeby wykryć błąd mysqldump.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

## Step 6 — Test full restore from backup

### 6.1 — Simulate data loss

```bash
mysql -u root -p
```

```sql
SHOW DATABASES;
DROP DATABASE webapp_db;
SHOW DATABASES;
```

Confirm webapp_db is gone.

Result:
```
mysql> SHOW DATABASES;
+--------------------+
| Database           |
+--------------------+
| information_schema |
| mysql              |
| performance_schema |
| sys                |
| webapp_db          |
+--------------------+
5 rows in set (0.00 sec)

mysql> DROP DATABASE webapp_db;
Query OK, 2 rows affected (0.02 sec)

mysql> SHOW DATABASES;
+--------------------+
| Database           |
+--------------------+
| information_schema |
| mysql              |
| performance_schema |
| sys                |
+--------------------+
4 rows in set (0.00 sec)
```


### 6.2 — Restore from backup

```bash
# Recreate the empty database first
mysql -u root -p -e "CREATE DATABASE webapp_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -e "CREATE DATABASE webapp_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"


# Restore from the latest backup
LATEST=$(ls -t /var/backup/mysql/webapp_db_*.sql.gz | head -1)
echo "Restoring from: ${LATEST}"
zcat "${LATEST}" | mysql -u root -p webapp_db
zcat "${LATEST}" | mysql -u root webapp_db

```

### 6.3 — Verify restored data

```bash
mysql -u root -e "
  USE webapp_db;
  SHOW TABLES;
  SELECT COUNT(*) AS dept_count FROM departments;
  SELECT COUNT(*) AS emp_count FROM employees;
  SELECT e.first_name, e.last_name, d.name AS department
  FROM employees e JOIN departments d ON e.department_id = d.id;
"
```

Expected: 4 departments, 5 employees — same as before the DROP.

Result:
```
[root@rhel-web01 ~]# mysql -u root -e "
  USE webapp_db;
  SHOW TABLES;
  SELECT COUNT(*) AS dept_count FROM departments;
  SELECT COUNT(*) AS emp_count FROM employees;
  SELECT e.first_name, e.last_name, d.name AS department
  FROM employees e JOIN departments d ON e.department_id = d.id;
"
+---------------------+
| Tables_in_webapp_db |
+---------------------+
| departments         |
| employees           |
+---------------------+
+------------+
| dept_count |
+------------+
|          4 |
+------------+
+-----------+
| emp_count |
+-----------+
|         5 |
+-----------+
+------------+-------------+------------+
| first_name | last_name   | department |
+------------+-------------+------------+
| Jan        | Kowalski    | IT         |
| Anna       | Nowak       | IT         |
| Piotr      | Wiśniewski  | HR         |
| Maria      | Wójcik      | Finance    |
| Tomasz     | Kamiński    | Operations |
+------------+-------------+------------+
```


### 6.4 — Verify application user still works after restore

```bash
mysql -u webapp_user -p -e "USE webapp_db; SELECT * FROM employees;"
```
Result:
```
[root@rhel-web01 ~]# mysql -u webapp_user -p -e "USE webapp_db; SELECT * FROM employees;"
Enter password: 
+----+------------+-------------+----------------------------+---------------+------------+----------+---------------------+
| id | first_name | last_name   | email                      | department_id | hire_date  | salary   | created_at          |
+----+------------+-------------+----------------------------+---------------+------------+----------+---------------------+
|  1 | Jan        | Kowalski    | jan.kowalski@lab.local     |             1 | 2024-03-15 | 12000.00 | 2026-04-10 11:01:42 |
|  2 | Anna       | Nowak       | anna.nowak@lab.local       |             1 | 2024-06-01 | 11500.00 | 2026-04-10 11:01:42 |
|  3 | Piotr      | Wiśniewski  | piotr.wisniewski@lab.local |             2 | 2023-09-10 |  9500.00 | 2026-04-10 11:01:42 |
|  4 | Maria      | Wójcik      | maria.wojcik@lab.local     |             3 | 2025-01-20 | 10500.00 | 2026-04-10 11:01:42 |
|  5 | Tomasz     | Kamiński    | tomasz.kaminski@lab.local  |             4 | 2024-11-05 |  8800.00 | 2026-04-10 11:01:42 |
+----+------------+-------------+----------------------------+---------------+------------+----------+---------------------+
```
---
### Notes

Zasymulowałem utratę danych — `DROP DATABASE webapp_db`. Potwierdziłem, że baza zniknęła (SHOW DATABASES — 4 bazy systemowe, brak webapp_db). Odtworzyłem bazę: utworzyłem pustą webapp_db, a następnie wgrałem ostatni backup (`zcat ... | mysql`). Weryfikacja: 2 tabele (departments, employees), 4 departamenty, 5 pracowników — dane identyczne jak przed DROP. webapp_user nadal ma dostęp do odtworzonej bazy — uprawnienia (GRANT) przetrwały, bo są przechowywane w bazie `mysql`, a nie w webapp_db.

---
### Conclusion

#### What - Co zrobiłem?
Symulacja disaster recovery: DROP DATABASE webapp_db, odtworzenie z backupu gzip (z kroku 5), weryfikacja danych (count + JOIN) i uprawnień webapp_user.

---
#### Why - Dlaczego to zrobiłem?
Backup bez przetestowanego restore jest bezwartościowy. Procedura restore musi być zweryfikowana zanim będzie potrzebna w sytuacji awaryjnej. Testowanie obejmuje nie tylko dane, ale też czy uprawnienia użytkowników nadal działają po przywróceniu.

---
#### Result - Co dzięki temu uzyskałem?
Potwierdzona procedura restore: CREATE DATABASE → zcat backup | mysql. Dane odtworzone w 100% (4 departamenty, 5 pracowników, wszystkie kolumny, klucze obce). webapp_user działa po restore bez ponownego nadawania uprawnień.

---
#### Lesson Learned - Co się nauczyłem?
Restore wymaga dwóch kroków: najpierw `CREATE DATABASE` (dump z mysqldump nie zawiera tej komendy — zawiera tylko `DROP TABLE IF EXISTS` i `CREATE TABLE`), potem import danych. Uprawnienia (GRANT) są przechowywane w systemowej bazie `mysql`, nie w webapp_db — dlatego DROP DATABASE webapp_db nie usuwa uprawnień webapp_user i backup_user. Po restore nie trzeba ponownie nadawać GRANT. Dump mysqldump wyłącza foreign key checks i unique checks na czas importu (komendy `/*!40014 ... */`) — dzięki temu kolejność tabel w dumpie nie ma znaczenia.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Brak problemów w tym kroku.

---

## Step 7 — Configure SELinux contexts and firewall rules

### 7.1 — Verify current SELinux context for MySQL

```bash
# Check mysqld process context
ps -eZ | grep mysqld

# Check default MySQL data directory context
ls -lZ /var/lib/mysql/

# Check custom log directory context
ls -lZ /var/log/mysql/

# Check backup directory context
ls -lZ /var/backup/mysql/
```

Result:
```
[root@rhel-web01 ~]# ps -eZ | grep mysqld
system_u:system_r:mysqld_t:s0      3442 ?        00:00:03 mysqld
[root@rhel-web01 ~]# ls -lZ /var/lib/mysql/
total 94672
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_db_t:s0            56 Apr 10 10:03  auto.cnf
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_db_t:s0          4720 Apr 10 11:09  binlog.000001
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_db_t:s0            16 Apr 10 10:03  binlog.index
-rw-------. 1 mysql mysql system_u:object_r:mysqld_db_t:s0          1705 Apr 10 10:03  ca-key.pem
-rw-r--r--. 1 mysql mysql system_u:object_r:mysqld_db_t:s0          1112 Apr 10 10:03  ca.pem
-rw-r--r--. 1 mysql mysql system_u:object_r:mysqld_db_t:s0          1112 Apr 10 10:03  client-cert.pem
-rw-------. 1 mysql mysql system_u:object_r:mysqld_db_t:s0          1705 Apr 10 10:03  client-key.pem
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_db_t:s0        196608 Apr 10 11:27 '#ib_16384_0.dblwr'
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_db_t:s0       8585216 Apr 10 10:03 '#ib_16384_1.dblwr'
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_db_t:s0          3638 Apr 10 11:09  ib_buffer_pool
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_db_t:s0      12582912 Apr 10 11:26  ibdata1
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_db_t:s0      12582912 Apr 10 11:09  ibtmp1
drwxr-x---. 2 mysql mysql system_u:object_r:mysqld_db_t:s0          4096 Apr 10 11:09 '#innodb_redo'
drwxr-x---. 2 mysql mysql system_u:object_r:mysqld_db_t:s0           187 Apr 10 11:09 '#innodb_temp'
drwxr-x---. 2 mysql mysql system_u:object_r:mysqld_db_t:s0           143 Apr 10 10:03  mysql
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_db_t:s0      29360128 Apr 10 11:26  mysql.ibd
srwxrwxrwx. 1 mysql mysql system_u:object_r:mysqld_var_run_t:s0        0 Apr 10 11:09  mysql.sock
-rw-------. 1 mysql mysql system_u:object_r:mysqld_db_t:s0             5 Apr 10 11:09  mysql.sock.lock
-rw-r--r--. 1 mysql mysql system_u:object_r:mysqld_db_t:s0             7 Apr 10 10:03  mysql_upgrade_info
srwxrwxrwx. 1 mysql mysql system_u:object_r:mysqld_var_run_t:s0        0 Apr 10 11:09  mysqlx.sock
-rw-------. 1 mysql mysql system_u:object_r:mysqld_db_t:s0             5 Apr 10 11:09  mysqlx.sock.lock
drwxr-x---. 2 mysql mysql system_u:object_r:mysqld_db_t:s0          8192 Apr 10 10:03  performance_schema
-rw-------. 1 mysql mysql system_u:object_r:mysqld_db_t:s0          1705 Apr 10 10:03  private_key.pem
-rw-r--r--. 1 mysql mysql system_u:object_r:mysqld_db_t:s0           452 Apr 10 10:03  public_key.pem
-rw-r--r--. 1 mysql mysql system_u:object_r:mysqld_db_t:s0          1112 Apr 10 10:03  server-cert.pem
-rw-------. 1 mysql mysql system_u:object_r:mysqld_db_t:s0          1705 Apr 10 10:03  server-key.pem
drwxr-x---. 2 mysql mysql system_u:object_r:mysqld_db_t:s0            28 Apr 10 10:03  sys
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_db_t:s0      16777216 Apr 10 11:27  undo_001
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_db_t:s0      16777216 Apr 10 11:27  undo_002
drwxr-x---. 2 mysql mysql system_u:object_r:mysqld_db_t:s0            50 Apr 10 11:26  webapp_db
[root@rhel-web01 ~]# ls -lZ /var/log/mysql/
total 28
-rw-r--r--. 1 root  root  unconfined_u:object_r:mysqld_log_t:s0  137 Apr 10 11:19 backup.log
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_log_t:s0      359 Apr 10 11:19 mysql-bin.000001
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_log_t:s0     7920 Apr 10 11:26 mysql-bin.000002
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_log_t:s0       64 Apr 10 11:19 mysql-bin.index
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_log_t:s0     2643 Apr 10 11:09 mysqld.log
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_log_t:s0      550 Apr 10 11:19 slow-query.log
[root@rhel-web01 ~]# ls -lZ /var/backup/mysql/
total 4
-rw-r--r--. 1 root root unconfined_u:object_r:var_t:s0 1213 Apr 10 11:19 webapp_db_20260410_111946.sql.gz
```

Conclusion:
- Proces mysqld działa w domenie `mysqld_t` — SELinux poprawnie ogranicza jego uprawnienia.
- `/var/lib/mysql/` — kontekst `mysqld_db_t` (domyślny, ustawiony automatycznie przez politykę SELinux).
- `/var/log/mysql/` — kontekst `mysqld_log_t` (domyślna polityka Rocky Linux 9 już zawiera regułę dla tej ścieżki — nie wymagał ręcznej konfiguracji).
- `/var/backup/mysql/` — kontekst **`var_t`** — to domyślny kontekst dla plików w `/var/`, **nie** specyficzny dla MySQL. Backup działa, bo skrypt uruchamiany jest jako root (unconfined), ale dla spójności warto zmienić na `mysqld_db_t` w kroku 7.2.

### 7.2 — Verify and fix SELinux contexts on custom directories

```bash
# Check what context SELinux expects for mysqld_db_t
semanage fcontext -l | grep mysql

# If /var/log/mysql does not have correct context, set it:
semanage fcontext -a -t mysqld_log_t "/var/log/mysql(/.*)?"
restorecon -Rv /var/log/mysql/

# Backup directory — mysqld_db_t for data files:
semanage fcontext -a -t mysqld_db_t "/var/backup/mysql(/.*)?"
restorecon -Rv /var/backup/mysql/
```

Verify:
```bash
ls -lZ /var/log/mysql/
ls -lZ /var/backup/mysql/
```

Result:
```
[root@rhel-web01 ~]# semanage fcontext -l | grep mysql
/etc/my\.cnf                                       regular file       system_u:object_r:mysqld_etc_t:s0
/etc/my\.cnf\.d(/.*)?                              all files          system_u:object_r:mysqld_etc_t:s0
/etc/mysql(/.*)?                                   all files          system_u:object_r:mysqld_etc_t:s0
/etc/rc\.d/init\.d/mysqld                          regular file       system_u:object_r:mysqld_initrc_exec_t:s0
/etc/rc\.d/init\.d/mysqlmanager                    regular file       system_u:object_r:mysqlmanagerd_initrc_exec_t:s0
/home/[^/]+/\.my\.cnf                              regular file       unconfined_u:object_r:mysqld_home_t:s0
/root/\.my\.cnf                                    regular file       system_u:object_r:mysqld_home_t:s0
/run/mariadb(/.*)?                                 all files          system_u:object_r:mysqld_var_run_t:s0
/run/mysql(/.*)?                                   all files          system_u:object_r:mysqld_var_run_t:s0
/run/mysqld(/.*)?                                  all files          system_u:object_r:mysqld_var_run_t:s0
/run/mysqld/mysqlmanager.*                         regular file       system_u:object_r:mysqlmanagerd_var_run_t:s0
/usr/bin/mariadb-backup                            regular file       system_u:object_r:mysqld_exec_t:s0
/usr/bin/mariadb-upgrade                           regular file       system_u:object_r:mysqld_exec_t:s0
/usr/bin/mariadbd-safe                             regular file       system_u:object_r:mysqld_safe_exec_t:s0
/usr/bin/mariadbd-safe-helper                      regular file       system_u:object_r:mysqld_exec_t:s0
/usr/bin/mysql_upgrade                             regular file       system_u:object_r:mysqld_exec_t:s0
/usr/bin/mysqld_safe                               regular file       system_u:object_r:mysqld_safe_exec_t:s0
/usr/bin/mysqld_safe_helper                        regular file       system_u:object_r:mysqld_exec_t:s0
/usr/bin/mysqlmanager                              regular file       system_u:object_r:mysqlmanagerd_exec_t:s0
/usr/bin/ndbd                                      regular file       system_u:object_r:mysqld_exec_t:s0
/usr/lib(64)?/nagios/plugins/check_mysql           regular file       system_u:object_r:nagios_services_plugin_exec_t:s0
/usr/lib(64)?/nagios/plugins/check_mysql_query     regular file       system_u:object_r:nagios_services_plugin_exec_t:s0
/usr/lib/systemd/system/mariadb.*                  regular file       system_u:object_r:mysqld_unit_file_t:s0
/usr/lib/systemd/system/mysqld.*                   regular file       system_u:object_r:mysqld_unit_file_t:s0
/usr/libexec/mariadbd                              regular file       system_u:object_r:mysqld_exec_t:s0
/usr/libexec/mysqld                                regular file       system_u:object_r:mysqld_exec_t:s0
/usr/libexec/mysqld_safe-scl-helper                regular file       system_u:object_r:mysqld_safe_exec_t:s0
/usr/sbin/mariadbd                                 regular file       system_u:object_r:mysqld_exec_t:s0
/usr/sbin/mysqld(-max|-debug)?                     regular file       system_u:object_r:mysqld_exec_t:s0
/usr/sbin/zabbix_proxy_mysql                       regular file       system_u:object_r:zabbix_exec_t:s0
/usr/sbin/zabbix_server_mysql                      regular file       system_u:object_r:zabbix_exec_t:s0
/usr/share/munin/plugins/mysql_.*                  regular file       system_u:object_r:services_munin_plugin_exec_t:s0
/var/lib/mysql(-files|-keyring)?(/.*)?             all files          system_u:object_r:mysqld_db_t:s0
/var/lib/mysql/mysql(x)?\.sock                     socket             system_u:object_r:mysqld_var_run_t:s0
/var/log/mariadb(/.*)?                             all files          system_u:object_r:mysqld_log_t:s0
/var/log/mysql(/.*)?                               all files          system_u:object_r:mysqld_log_t:s0
/var/log/mysql.*                                   regular file       system_u:object_r:mysqld_log_t:s0
[root@rhel-web01 ~]# semanage fcontext -a -t mysqld_log_t "/var/log/mysql(/.*)?"
File context for /var/log/mysql(/.*)? already defined, modifying instead
[root@rhel-web01 ~]# semanage fcontext -a -t mysqld_db_t "/var/backup/mysql(/.*)?"
[root@rhel-web01 ~]# restorecon -Rv /var/backup/mysql/
Relabeled /var/backup/mysql from unconfined_u:object_r:var_t:s0 to unconfined_u:object_r:mysqld_db_t:s0
Relabeled /var/backup/mysql/webapp_db_20260410_111946.sql.gz from unconfined_u:object_r:var_t:s0 to unconfined_u:object_r:mysqld_db_t:s0
[root@rhel-web01 ~]# ls -lZ /var/log/mysql/
total 28
-rw-r--r--. 1 root  root  unconfined_u:object_r:mysqld_log_t:s0  137 Apr 10 11:19 backup.log
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_log_t:s0      359 Apr 10 11:19 mysql-bin.000001
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_log_t:s0     7920 Apr 10 11:26 mysql-bin.000002
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_log_t:s0       64 Apr 10 11:19 mysql-bin.index
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_log_t:s0     2643 Apr 10 11:09 mysqld.log
-rw-r-----. 1 mysql mysql system_u:object_r:mysqld_log_t:s0      550 Apr 10 11:19 slow-query.log
[root@rhel-web01 ~]# ls -lZ /var/backup/mysql/
total 4
-rw-r--r--. 1 root root unconfined_u:object_r:mysqld_db_t:s0 1213 Apr 10 11:19 webapp_db_20260410_111946.sql.gz
```

Conclusion:

**Jak działają konteksty SELinux na plikach?**

Każdy plik i katalog w systemie z SELinux ma przypisany kontekst (etykietę), np. `mysqld_db_t` lub `var_t`. Proces mysqld działa w domenie `mysqld_t` i polityka SELinux definiuje, do jakich typów plików ta domena ma dostęp. Np. `mysqld_t` może czytać/pisać pliki z typem `mysqld_db_t` (dane) i `mysqld_log_t` (logi), ale nie może dotknąć plików z typem `var_t` czy `httpd_sys_content_t`.

**Skąd plik dostaje swój kontekst?**

Kiedy tworzysz plik, SELinux sprawdza bazę reguł (`semanage fcontext -l`) — jeśli ścieżka pasuje do reguły, plik dostaje odpowiedni typ. Np.:
- `/var/lib/mysql(/.*)?` → `mysqld_db_t` — reguła wbudowana w politykę Rocky Linux 9
- `/var/log/mysql(/.*)?` → `mysqld_log_t` — również wbudowana
- `/var/backup/mysql` — **brak reguły** w domyślnej polityce, więc plik dziedziczy domyślny typ dla `/var/` → `var_t`

**Co zrobiliśmy w tym kroku?**

1. `semanage fcontext -a` dla `/var/log/mysql` — próba dodania reguły, ale SELinux odpowiedział "already defined" (reguła już istniała w domyślnej polityce — dlatego logi miały poprawny kontekst od początku).
2. `semanage fcontext -a` dla `/var/backup/mysql` → `mysqld_db_t` — **tu reguły nie było**, więc została dodana. Następnie `restorecon -Rv` przetagował istniejące pliki z `var_t` na `mysqld_db_t`.

**Dlaczego `/var/log/mysql` miał poprawny kontekst, a `/var/backup/mysql` nie?**

Bo `/var/log/mysql` to standardowa ścieżka MySQL — twórcy polityki SELinux dla RHEL/Rocky ją przewidzieli i dodali regułę. `/var/backup/mysql` to nasza niestandardowa ścieżka — nikt jej nie przewidział, więc musieliśmy dodać regułę ręcznie. To typowa sytuacja: jeśli używasz niestandardowych ścieżek, musisz sam zarządzać kontekstami SELinux.

**Czy to było konieczne?**

W naszym przypadku backup działa jako root (kontekst `unconfined_t`), który omija większość ograniczeń SELinux. Więc `var_t` nie blokował backupów. Ale gdyby skrypt backupowy był uruchamiany przez proces w ograniczonej domenie (np. przez mysqld bezpośrednio), `var_t` spowodowałby AVC denial. Ustawienie poprawnego kontekstu to **dobra praktyka** — przygotowuje system na przyszłe zmiany i utrzymuje spójność polityki.

### 7.3 — Check SELinux booleans relevant to MySQL

```bash
getsebool -a | grep mysql
```
Result:
```
[root@rhel-web01 ~]# getsebool -a | grep mysql
mysql_connect_any --> off
mysql_connect_http --> off
selinuxuser_mysql_connect_enabled --> off
```

Key booleans:
- `mysql_connect_any` — allow MySQL to connect to any port (should be off for localhost-only)
- `mysql_connect_http` — allow MySQL to initiate HTTP connections (np. do pobierania danych z REST API przez MySQL UDF/plugins — off w naszym przypadku)
- `selinuxuser_mysql_connect_enabled` — allow regular (confined) users to connect to MySQL socket/port

For localhost-only LAMP stack, defaults should be fine. If Apache needs to connect to MySQL:
```bash
# Already set in LAB-02 if httpd_can_network_connect is on,
# but for MySQL specifically:
setsebool -P httpd_can_network_connect_db on
getsebool httpd_can_network_connect_db
```

Result:
```
[root@rhel-web01 ~]# setsebool -P httpd_can_network_connect_db on
[root@rhel-web01 ~]# getsebool httpd_can_network_connect_db
httpd_can_network_connect_db --> on
```

### 7.4 — Configure firewall

MySQL is bound to localhost only (bind-address=127.0.0.1), so no firewall port opening is needed for MySQL itself. Verify current firewall state:

```bash
firewall-cmd --list-all
```

Result:
```
[root@rhel-web01 ~]# firewall-cmd --list-all
public (active)
  target: default
  icmp-block-inversion: no
  interfaces: ens18
  sources: 
  services: cockpit dhcpv6-client http https ssh
  ports: 
  protocols: 
  forward: yes
  masquerade: no
  forward-ports: 
  source-ports: 
  icmp-blocks: 
  rich rules: 
```

If in the future remote access is needed:
```bash
# DO NOT run now — documented for reference only
# firewall-cmd --permanent --add-service=mysql
# firewall-cmd --reload
```



### 7.5 — Verify SELinux is not blocking MySQL operations

```bash
# Check for any MySQL-related AVC denials
ausearch -m avc -ts recent | grep mysql
# or
grep mysqld /var/log/audit/audit.log | grep denied
```

Result:
```
[root@rhel-web01 ~]# ausearch -m avc -ts recent | grep mysql
<no matches>
[root@rhel-web01 ~]# grep mysqld /var/log/audit/audit.log | grep denied
```

Run a full test cycle to confirm nothing is blocked:
```bash
# Test backup (uses custom log and backup directories)
/usr/local/bin/mysql-backup.sh
cat /var/log/mysql/backup.log


# Test slow query log
mysql -u root -e "SELECT SLEEP(2);"
tail -5 /var/log/mysql/slow-query.log

# Test app user access
mysql -u webapp_user -p -e "USE webapp_db; SELECT COUNT(*) FROM employees;"
```

Result:
```
[root@rhel-web01 ~]# ausearch -m avc -ts recent | grep mysql
<no matches>
[root@rhel-web01 ~]# grep mysqld /var/log/audit/audit.log | grep denied
[root@rhel-web01 ~]# /usr/local/bin/mysql-backup.sh
[root@rhel-web01 ~]# cat /var/log/mysql/backup.log
20260410_111946 — OK — /var/backup/mysql/webapp_db_20260410_111946.sql.gz (4.0K)
20260410_111946 — Rotation: removed 0 old backups
20260410_114151 — OK — /var/backup/mysql/webapp_db_20260410_114151.sql.gz (4.0K)
20260410_114151 — Rotation: removed 0 old backups
[root@rhel-web01 ~]# mysql -u root -e "SELECT SLEEP(2);"
+----------+
| SLEEP(2) |
+----------+
|        0 |
+----------+
[root@rhel-web01 ~]# tail -5 /var/log/mysql/slow-query.log
# Time: 2026-04-10T09:42:13.494070Z
# User@Host: root[root] @ localhost []  Id:    19
# Query_time: 2.000117  Lock_time: 0.000000 Rows_sent: 1  Rows_examined: 1
SET timestamp=1775814131;
SELECT SLEEP(2);
[root@rhel-web01 ~]# mysql -u webapp_user -p -e "USE webapp_db; SELECT COUNT(*) FROM employees;"
Enter password: 
+----------+
| COUNT(*) |
+----------+
|        5 |
+----------+
```

---
### Notes

Zweryfikowałem konteksty SELinux na wszystkich katalogach MySQL — `/var/lib/mysql` (mysqld_db_t), `/var/log/mysql` (mysqld_log_t) były poprawne od razu. Dla `/var/backup/mysql` dodałem regułę `mysqld_db_t` ręcznie (semanage + restorecon). Sprawdziłem booleany SELinux — wszystkie trzy mysql_* na off (poprawnie dla localhost-only). Włączyłem `httpd_can_network_connect_db` żeby Apache mógł łączyć się z MySQL. Firewall — brak potrzeby otwierania portu MySQL (bind-address=127.0.0.1). Audit log — zero AVC denials. Full test cycle: backup, slow query log, webapp_user — wszystko działa bez blokad SELinux.

---
### Conclusion

#### What - Co zrobiłem?
Weryfikacja i konfiguracja SELinux dla MySQL: sprawdzenie kontekstów plików (7.1), dodanie reguły fcontext dla niestandardowej ścieżki `/var/backup/mysql` (7.2), przegląd booleanów SELinux i włączenie `httpd_can_network_connect_db` (7.3), weryfikacja firewalla (7.4), sprawdzenie braku AVC denials i pełny test wszystkich operacji MySQL (7.5).

---
#### Why - Dlaczego to zrobiłem?
SELinux w trybie enforcing to dodatkowa warstwa bezpieczeństwa — nawet jeśli atakujący przejmie proces mysqld, SELinux ogranicza, do jakich plików i portów ten proces ma dostęp. Bez poprawnych kontekstów na niestandardowych ścieżkach, przyszłe zmiany (np. uruchomienie backupu z ograniczonej domeny) mogłyby się nie powieść. Boolean `httpd_can_network_connect_db` jest potrzebny, żeby Apache (httpd_t) mógł połączyć się z MySQL przez socket/port — bez niego aplikacja PHP/Python na Apache nie mogłaby korzystać z bazy.

---
#### Result - Co dzięki temu uzyskałem?
Kompletny LAMP stack z SELinux enforcing: Apache (httpd_t) może łączyć się z MySQL, MySQL (mysqld_t) ma dostęp tylko do swoich plików danych i logów, firewall nie wystawia portu MySQL na sieć, brak AVC denials w audit logu. Niestandardowa ścieżka backupów ma poprawny kontekst SELinux.

---
#### Lesson Learned - Co się nauczyłem?
SELinux chroni MySQL na trzech poziomach: **konteksty plików** (jakie pliki mysqld może czytać/pisać), **booleany** (czy mysqld może łączyć się z siecią, czy httpd może łączyć się z bazą), **domeny procesów** (mysqld działa w mysqld_t, nie w unconfined_t). Standardowe ścieżki RHEL mają konteksty od razu — niestandardowe wymagają ręcznej konfiguracji (`semanage fcontext -a` + `restorecon`). `ausearch -m avc` to główne narzędzie do diagnozowania problemów z SELinux — brak wyników = brak blokad. W LAMP stack kluczowy boolean to `httpd_can_network_connect_db` — bez niego Apache nie połączy się z bazą nawet na localhost.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Kontekst `var_t` na `/var/backup/mysql` zmieniony na `mysqld_db_t`. Poza tym brak problemów — SELinux nie blokował żadnych operacji MySQL.

---

## LAB-03 — Conclusion

#### What - Co zrobiłem?
Zainstalowałem i skonfigurowałem MySQL 8.0.45 na rhel-web01, tworząc kompletny LAMP stack (Apache z LAB-02 + MySQL). W 7 krokach: instalacja i hardening (mysql_secure_installation), utworzenie bazy webapp_db z dwoma użytkownikami o rozdzielonych rolach (webapp_user — DML, backup_user — dump), import danych testowych (2 tabele, 5 rekordów), tuning serwera (bind-address localhost, slow query log, binary logging, InnoDB buffer pool), automatyczny backup z rotacją (skrypt bash + cron), test restore po symulowanym DROP DATABASE, konfiguracja SELinux (konteksty fcontext, booleany, audit) i weryfikacja firewalla.

---
#### Why - Dlaczego to zrobiłem?
LAB-03 realizuje cel G4 (MySQL administration) z planu laboratoryjnego. MySQL to standardowa baza danych w środowiskach Linux — umiejętność instalacji, hardeningu, backupu/restore i integracji z SELinux jest kluczowa dla administratora systemów. Instalacja na pełnej VM (nie LXC) pozwoliła ćwiczyć SELinux w trybie enforcing, co nie byłoby możliwe na kontenerze.

---
#### Result - Co dzięki temu uzyskałem?
Kompletny LAMP stack na rhel-web01 z SELinux enforcing:
- MySQL 8.0.45 nasłuchuje tylko na localhost:3306 (nie jest dostępny zdalnie)
- Baza webapp_db z danymi testowymi i dwoma użytkownikami (least privilege)
- Slow query log (próg 1s) i binary logging (7 dni retencji) do diagnostyki i recovery
- Automatyczny backup codziennie o 02:00 z rotacją 7 dni
- Przetestowana procedura restore (DROP → CREATE → import z backupu)
- SELinux: poprawne konteksty na wszystkich ścieżkach, httpd_can_network_connect_db=on, zero AVC denials

---
#### Lesson Learned - Co się nauczyłem?
- **mysql_secure_installation** to obowiązkowy pierwszy krok po instalacji — usuwa anonimowych użytkowników, bazę test i zdalny login root.
- **Least privilege** w MySQL działa na wielu poziomach (globalny, bazodanowy, tabelowy) — webapp_user dostaje tylko DML, backup_user tylko to co potrzebuje mysqldump.
- **mysqldump** z `--single-transaction` robi spójny snapshot bez blokowania tabel (kluczowe dla InnoDB w produkcji).
- **Binary logging** umożliwia point-in-time recovery — odtworzenie do dowolnego momentu między backupami.
- **Restore wymaga dwóch kroków**: CREATE DATABASE + import (mysqldump nie eksportuje komendy CREATE DATABASE).
- **Uprawnienia GRANT przeżywają DROP DATABASE** — są w systemowej bazie `mysql`, nie w bazie użytkownika.
- **SELinux i niestandardowe ścieżki**: standardowe ścieżki RHEL mają konteksty od razu, niestandardowe (np. `/var/backup/mysql`) wymagają ręcznego `semanage fcontext -a` + `restorecon`.
- **`~/.my.cnf`** z chmod 600 to dobry kompromis między wygodą a bezpieczeństwem przy podawaniu hasła MySQL.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Lab przebiegł bez większych problemów. Jedyna korekta: kontekst SELinux `var_t` na `/var/backup/mysql` zmieniony na `mysqld_db_t` — domyślna polityka nie obejmuje niestandardowych ścieżek backupowych.
