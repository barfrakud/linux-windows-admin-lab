# LAB-01: Bind DNS Server on RHEL

**Status:** In progress
**Machine:** rhel-srv01 (Rocky Linux 9) · win-dc01 · all Linux LXCs
**Reference:** [lab-plan.md — LAB-01](../lab-plan.md)

### Lab context

| Host | IP | DNS role |
|---|---|---|
| win-dc01 | 10.10.10.10 | Authoritative for `lab.local` (AD DNS) |
| win-mgmt01 | 10.10.10.11 | `lab.local` |
| rhel-srv01 | 10.10.10.20 | Authoritative for `linux.lab.local` + reverse zone (Bind) |
| ubuntu-ws01 | 10.10.10.30 | `linux.lab.local` |
| ipa-srv01 | 10.10.10.40 | `linux.lab.local` |
| repo-srv01 | 10.10.10.50 | `linux.lab.local` |

**End state after this lab:**
- Bind on rhel-srv01 is authoritative for `linux.lab.local` and `10.10.10.in-addr.arpa`
- `lab.local` queries forwarded to win-dc01 (10.10.10.10)
- All Linux LXCs use 10.10.10.20 as primary DNS resolver
- win-dc01 has a delegation for `linux.lab.local` → rhel-srv01

---

## Step 1 — Install Bind and DNS utilities

### 1.1. — Install packages

Connect to rhel-srv01 via SSH:
```bash
ssh root@10.10.10.20
# or via tunnel: ssh -L 10020:10.10.10.20:22 root@10.28.0.200
```

Install:
```bash
dnf install -y bind bind-utils
```

Verify:
```bash
rpm -q bind bind-utils
named -v
```
--- 

### Conclusion

#### What - Co zrobiłem?
Zainstalowałem Bind i narzędzia DNS.

---
#### Why - Dlaczego to zrobiłem?
Aby mieć serwer DNS który będzie autoritatywny dla domeny `linux.lab.local`.

---
#### Result - Co dzięki temu uzyskałem?
Serwer DNS jest gotowy do konfiguracji strefy.

---
#### Lesson Learned - Co się nauczyłem?
Nauczyłem się, które pakiety należy zainstalować, żeby uruchomić bind.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
W tym przyapdku nie było żadnych.

---

### 1.2 — Enable and start named service

```bash
systemctl enable --now named
systemctl status named
```

**Before:**

**After:**

**Notes:**
Done

### Conclusion

#### What - Co zrobiłem?
Włączyłem i uruchomiłem usługę `named` za pomocą `systemctl enable --now named`.

---
#### Why - Dlaczego to zrobiłem?
Zainstalowane pakiety to tylko pliki na dysku — bez uruchomienia usługi Bind nie nasłuchuje na żadnym porcie i nie obsługuje zapytań DNS. `enable` zapewnia autostart po rebootcie.

---
#### Result - Co dzięki temu uzyskałem?
Usługa `named` jest uruchomiona i włączona do autostartu. Bind nasłuchuje na domyślnym interfejsie (`127.0.0.1`) i jest gotowy do konfiguracji stref.

---
#### Lesson Learned - Co się nauczyłem?
`systemctl enable --now` to skrót łączący `enable` (autostart po rebootcie) i `start` (natychmiastowe uruchomienie) w jednym poleceniu. Bez `enable` usługa działałaby do restartu maszyny, a potem trzeba by ją uruchamiać ręcznie.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
W tym kroku nie wystąpiły żadne problemy.

---

## Step 2 — Configure forward zone for `linux.lab.local`

### 2.1 — Create zone file

Create `/var/named/linux.lab.local.zone`:
```dns
$TTL 86400
@   IN  SOA  rhel-srv01.linux.lab.local. admin.linux.lab.local. (
              2024010101 ; Serial
              3600       ; Refresh
              900        ; Retry
              604800     ; Expire
              86400 )    ; Minimum TTL

; Name server
@           IN  NS      rhel-srv01.linux.lab.local.

; A records
rhel-srv01  IN  A       10.10.10.20
ubuntu-ws01 IN  A       10.10.10.30
ipa-srv01   IN  A       10.10.10.40
repo-srv01  IN  A       10.10.10.50
```

Set ownership:
```bash
chown root:named /var/named/linux.lab.local.zone
chmod 640 /var/named/linux.lab.local.zone
```

### Conclusion

#### What - Co zrobiłem?
Stworzyłem plik strefy `/var/named/linux.lab.local.zone` z rekordem SOA, rekordem NS i rekordami A dla wszystkich hostów Linux w labie. Ustawiłem uprawnienia (`root:named`, `640`), żeby usługa `named` mogła go odczytać.

---
#### Why - Dlaczego to zrobiłem?
Bez centralnego pliku strefy każda maszyna musiałaby mieć własny `/etc/hosts` z ręcznie synchronizowanymi wpisami. Plik strefy definiuje mapowanie nazw na adresy IP dla całej domeny `linux.lab.local` w jednym miejscu — to źródło prawdy dla DNS.

---
#### Result - Co dzięki temu uzyskałem?
Plik strefy istnieje na dysku z poprawnymi rekordami i uprawnieniami. Sam w sobie nic jeszcze nie zmienia — Bind nie wie o jego istnieniu. Dopiero kroki 2.2 (rejestracja w `named.conf`) i 2.3 (reload) aktywują strefę.

---
#### Lesson Learned - Co się nauczyłem?
- Subdomenę `linux.lab.local` tworzymy zamiast `lab.local`, bo AD DNS musi pozostać właścicielem strefy `lab.local` (rekordy SRV Kerberos, DC locator). Deklaracja autorytywności Bind dla `lab.local` zepsułaby Active Directory.
- Numer seryjny w SOA (`2024010101`) musi być inkrementowany przy każdej zmianie — serwery secondary sprawdzają go, żeby wiedzieć czy pobrać nową kopię strefy.
- Usługa `named` działa jako użytkownik `named` (nie root) — bez `chown root:named` i `chmod 640` Bind nie załaduje pliku strefy.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
W tym kroku nie wystąpiły żadne problemy.

---

### 2.2 — Modify `/etc/named.conf` options and add zone stanza

Back up the original config first:
```bash
cp /etc/named.conf /etc/named.conf.orig
```

In the `options { }` block, update or add these lines:
```
listen-on port 53 { 127.0.0.1; 10.10.10.20; };
allow-query     { localhost; 10.10.10.0/24; };
forwarders      { 8.8.8.8; 8.8.4.4; };
```

Add zone stanza at the end of the file:
```
zone "linux.lab.local" IN {
    type master;
    file "linux.lab.local.zone";
    allow-query { any; };
};
```

**Before:**

**After:**

**Notes:**

**`listen-on port 53 { 127.0.0.1; 10.10.10.20; }` — domyślnie named jest głuchy dla sieci:**
Domyślna konfiguracja RHEL słucha tylko na `127.0.0.1` — żadna zewnętrzna maszyna nie może wysłać zapytania. Dodanie `10.10.10.20` otwiera nasłuch na interfejsie sieciowym labu. Jawne podanie interfejsów zamiast `any` to dobra praktyka — serwer DNS nie eksponuje się np. gdybyśmy dodali drugi interfejs WAN.

**`allow-query { localhost; 10.10.10.0/24; }` — ACL zapytań:**
Nawet jeśli named słucha na interfejsie, ta dyrektywa kontroluje, kto może zadawać zapytania — dwupoziomowa kontrola dostępu: `listen-on` (interfejs) + `allow-query` (klient). Bez `10.10.10.0/24` inne maszyny labu dostałyby `REFUSED`.

**`forwarders { 8.8.8.8; 8.8.4.4; }` — rezolucja internetu:**
Dla stref, dla których Bind nie jest autorytatywny i nie ma jawnego `zone ... forward`, zapytania trafiają do Google DNS zamiast Bind próbował samodzielnie rekurować po korzeniach. W praktyce: maszyny w labie będą mogły rozwiązywać nazwy internetowe przez rhel-srv01.

**`type master` i `allow-query { any; }` w strefie:**
`type master` (alias: `primary` w nowszym Bind) oznacza, że to jest pierwotne, autorytatywne źródło danych — Bind nie pobiera tej strefy od nikogo. `allow-query { any; }` w strefie nadpisuje globalne `allow-query` dla tej konkretnej strefy — po konfiguracji delegacji Windows będzie mógł odpytywać strefę bezpośrednio.

**Sam wpis w `named.conf` nie aktywuje strefy — dopiero reload (krok 2.3):**
Po modyfikacji pliku named działa ze starą konfiguracją w pamięci. Do `systemctl reload named` zapytania o `linux.lab.local` nadal zwracają `SERVFAIL`.

### Conclusion

#### What - Co zrobiłem?
Zmodyfikowałem `/etc/named.conf` — otworzyłem nasłuch na interfejsie sieciowym (`10.10.10.20`), ustawiłem ACL dla podsieci labowej, dodałem globalne forwardery (Google DNS) i zarejestrowałem strefę `linux.lab.local`.

---
#### Why - Dlaczego to zrobiłem?
Sam plik strefy nie wystarczy — Bind musi wiedzieć, gdzie szukać danych, kto może go odpytywać i co zrobić z zapytaniami, których nie obsługuje sam. `named.conf` jest centralnym plikiem konfiguracyjnym, który to wszystko spina.

---
#### Result - Co dzięki temu uzyskałem?
Konfiguracja jest kompletna, ale aktywuje się dopiero po `reload` w kroku 2.3. Named wciąż działa ze starą konfiguracją w pamięci — zapytania o `linux.lab.local` nadal zwracają `SERVFAIL`.

---
#### Lesson Learned - Co się nauczyłem?
- Bind ma dwupoziomową kontrolę dostępu: `listen-on` (na jakim interfejsie nasłuchuje) + `allow-query` (kto może zadawać zapytania). Obie muszą być poprawnie ustawione.
- `type master` oznacza autorytatywne źródło danych — Bind nie pobiera tej strefy od nikogo.
- `allow-query { any; }` w deklaracji strefy nadpisuje globalne `allow-query` — przydatne gdy delegacja z Windows wymaga dostępu spoza labowego /24.
- Globalne `forwarders` obsługują zapytania internetowe — Bind staje się lokalnym proxy DNS.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
W tym kroku nie wystąpiły żadne problemy.

---

### 2.3 — Validate configuration and reload named

```bash
named-checkconf
named-checkzone linux.lab.local /var/named/linux.lab.local.zone
systemctl reload named
```

Test:
```bash
dig @10.10.10.20 rhel-srv01.linux.lab.local
dig @10.10.10.20 ubuntu-ws01.linux.lab.local
```

**Before:**

**After:**
```
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 56519
;; flags: qr aa rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1
;; ANSWER SECTION:
rhel-srv01.linux.lab.local. 86400 IN    A       10.10.10.20
;; Query time: 0 msec
;; SERVER: 10.10.10.20#53(10.10.10.20)

;; ANSWER SECTION:
ubuntu-ws01.linux.lab.local. 86400 IN   A       10.10.10.30
;; Query time: 0 msec
```

**Notes:**

**Jak czytać odpowiedź `dig` — najważniejsze pola:**

`status: NOERROR` — zapytanie zostało obsłużone bez błędu. Inne możliwe statusy: `NXDOMAIN` (domena nie istnieje), `SERVFAIL` (serwer napotkał błąd), `REFUSED` (serwer odmówił odpowiedzi — np. ACL).

**Flagi w nagłówku (`flags: qr aa rd ra`) — to jest kluczowe:**
- `qr` — Query Response: to jest odpowiedź, nie zapytanie
- `aa` — **Authoritative Answer**: serwer odpowiedział jako autorytet dla tej strefy — nie pobrał odpowiedzi z cache ani od innego serwera. To dowód, że Bind faktycznie serwuje strefę `linux.lab.local` autorytatywnie. Gdyby `aa` nie było — odpowiedź byłaby z cache lub z forwardera.
- `rd` — Recursion Desired: klient (dig) poprosił o rekurencję
- `ra` — Recursion Available: serwer obsługuje rekurencję

**`AUTHORITY: 0` mimo odpowiedzi autorytatywnej:**

### Conclusion

#### What - Co zrobiłem?
Zwalidowałem konfigurację (`named-checkconf`, `named-checkzone`) i przeładowałem Bind (`systemctl reload named`). Przetestowałem odpowiedzi `dig` dla hostów w strefie `linux.lab.local`.

---
#### Why - Dlaczego to zrobiłem?
Bez walidacji błąd składniowy mógłby spowodować odmowę restartu lub przerwanie obsługi zapytań. `reload` wczytuje nową konfigurację bez przerywania działania usługi — w odróżnieniu od `restart`, który na chwilę zatrzymuje named.

---
#### Result - Co dzięki temu uzyskałem?
Bind jest autorytatywny dla `linux.lab.local` — flaga `aa` w odpowiedzi `dig` to potwierdza. Każda maszyna w labie może odpytać `10.10.10.20` o hosty w tej domenie i dostanie poprawną odpowiedź. To fundament całej reszty konfiguracji DNS w tym labie.

---
#### Lesson Learned - Co się nauczyłem?
- Flaga `aa` (Authoritative Answer) w `dig` jest dowodem, że Bind serwuje strefę autorytatywnie — odpowiedź nie pochodzi z cache ani od forwardera.
- `status: NOERROR` potwierdza brak błędów. Inne statusy: `NXDOMAIN` (domena nie istnieje), `SERVFAIL` (błąd serwera), `REFUSED` (ACL odrzuciło zapytanie).
- Test `dig @10.10.10.20` weryfikuje cały łańcuch naraz: plik strefy → named.conf → interfejs sieciowy → firewall.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
W tym kroku nie wystąpiły żadne problemy.

---

## Step 3 — Configure reverse zone for the lab subnet

### 3.1 — Create reverse zone file

Create `/var/named/10.10.10.rev`:
```dns
$TTL 86400
@   IN  SOA  rhel-srv01.linux.lab.local. admin.linux.lab.local. (
              2024010101 ; Serial
              3600       ; Refresh
              900        ; Retry
              604800     ; Expire
              86400 )    ; Minimum TTL

; Name server
@    IN  NS   rhel-srv01.linux.lab.local.

; PTR records — last octet only
10   IN  PTR  win-dc01.lab.local.
11   IN  PTR  win-mgmt01.lab.local.
20   IN  PTR  rhel-srv01.linux.lab.local.
30   IN  PTR  ubuntu-ws01.linux.lab.local.
40   IN  PTR  ipa-srv01.linux.lab.local.
50   IN  PTR  repo-srv01.linux.lab.local.
```

Set ownership:
```bash
chown root:named /var/named/10.10.10.rev
chmod 640 /var/named/10.10.10.rev
```

**Before:**

**After:**

**Notes:**

**Skąd się bierze nazwa strefy `10.10.10.in-addr.arpa`?**
Reverse DNS działa przez odwrócenie oktetów adresu IP i dodanie sufiksu `.in-addr.arpa`. Dla sieci `10.10.10.0/24` strefa to `10.10.10.in-addr.arpa`. Gdy `dig -x 10.10.10.20` jest wykonywany, klient buduje zapytanie o `20.10.10.10.in-addr.arpa.` — Bind wie, że jest autorytatywny dla tej strefy i odpowiada na nie rekordem PTR.

**Rekordy PTR — tylko ostatni oktet:**
W pliku strefy `10.10.10.in-addr.arpa` etykieta rekordu to tylko ostatni oktet IP (np. `20`). Pełna nazwa kwalifikowana jest budowana przez Bind automatycznie: `20` → `20.10.10.10.in-addr.arpa.`. Wartość PTR musi być absolutną nazwą FQDN — **kropka na końcu jest obowiązkowa** (np. `rhel-srv01.linux.lab.local.`). Bez niej Bind dołączyłby nazwę strefy i wynik byłby błędny.

**Dlaczego reverse zone obejmuje też hosty Windows (10, 11)?**
Bind jest jedynym serwerem autorytatywnym dla całej strefy `10.10.10.in-addr.arpa` — nie ma tu podziału między Windows a Linux. AD DNS na win-dc01 mógłby obsługiwać własną reverse zone, ale wymagałoby to dodatkowej delegacji. Prostszym rozwiązaniem w tym labie jest obsługa całego /24 przez Bind z ręcznie wpisanymi rekordami PTR dla maszyn Windows.

### Conclusion

#### What - Co zrobiłem?
Stworzyłem plik strefy odwrotnej `/var/named/10.10.10.rev` z rekordami PTR dla wszystkich hostów w labie (Linux i Windows). Ustawiłem uprawnienia `root:named`, `640`.

---
#### Why - Dlaczego to zrobiłem?
Reverse DNS (IP → nazwa) jest wymagany przez wiele usług: SSH sprawdza reverse lookup klienta, Kerberos weryfikuje tożsamość przez PTR, narzędzia monitoringu wyświetlają nazwy zamiast adresów. Bez tej konfiguracji `dig -x 10.10.10.20` zwróciłoby `NXDOMAIN`.

---
#### Result - Co dzięki temu uzyskałem?
Plik strefy odwrotnej leży na dysku z poprawnymi rekordami i uprawnieniami. Sam w sobie nic nie aktywuje — kroki 3.2 i 3.3 zarejestrują go w Bind i przeładują usługę.

---
#### Lesson Learned - Co się nauczyłem?
- Reverse DNS odwraca oktety IP i dodaje `.in-addr.arpa` — dla sieci `10.10.10.0/24` strefa to `10.10.10.in-addr.arpa`.
- Etykiety rekordów PTR to tylko ostatni oktet (np. `20`). Pełną nazwę buduje Bind automatycznie.
- Wartość PTR musi kończyć się kropką (FQDN) — bez niej Bind dołączyłby nazwę strefy i wynik byłby błędny.
- Bind obsługuje reverse lookup dla całego /24 włącznie z hostami Windows — prostsze niż delegacja reverse zone do AD DNS.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
W tym kroku nie wystąpiły żadne problemy.

---

### 3.2 — Add reverse zone declaration to `/etc/named.conf`

Append to the end of `/etc/named.conf`:
```
zone "10.10.10.in-addr.arpa" IN {
    type master;
    file "10.10.10.rev";
    allow-query { any; };
};
```

**Before:**

**After:**

**Notes:**

**Nazwa strefy musi być dokładnym odwzoreniem struktury reverse DNS:**
`"10.10.10.in-addr.arpa"` to nie jest dowolna nazwa — Bind dopasowuje przychodzące zapytanie `20.10.10.10.in-addr.arpa.` do tej strefy przez sufiks. Gdyby nazwa była wpisana inaczej (np. `"10.in-addr.arpa"`), strefa obejmowałaby całą klasę A 10.0.0.0/8, a nie tylko nasz /24.

**Analogia do kroku 2.2:**
Deklaracja jest identyczna w strukturze jak przy strefie forward — `type master`, `file`, `allow-query`. Różni się tylko nazwa strefy i plik. Bind traktuje strefę reverse tak samo jak forward — autorytatywnie serwuje rekordy PTR, tak jak serwuje rekordy A.

### Conclusion

#### What - Co zrobiłem?
Dodałem deklarację strefy `10.10.10.in-addr.arpa` do `/etc/named.conf` z `type master` i `allow-query { any; }`.

---
#### Why - Dlaczego to zrobiłem?
Bind musi wiedzieć o istnieniu strefy odwrotnej i skąd wczytać jej rekordy — sam plik na dysku nie wystarczy.

---
#### Result - Co dzięki temu uzyskałem?
Konfiguracja jest kompletna. Krok 3.3 wykona walidację i reload, po którym reverse lookup zacznie działać.

---
#### Lesson Learned - Co się nauczyłem?
- Deklaracja strefy reverse jest identyczna strukturalnie jak forward (`type master`, `file`, `allow-query`). Bind traktuje obie tak samo — autorytatywnie serwuje rekordy.
- Nazwa strefy `10.10.10.in-addr.arpa` musi dokładnie odpowiadać strukturze reverse DNS — Bind dopasowuje zapytania przez sufiks. Błędna nazwa (np. `10.in-addr.arpa`) obejmowałaby całą klasę A zamiast naszego /24.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
W tym kroku nie wystąpiły żadne problemy.

---

### 3.3 — Validate and reload named

```bash
named-checkconf
named-checkzone 10.10.10.in-addr.arpa /var/named/10.10.10.rev
systemctl reload named
```

Test:
```bash
dig @10.10.10.20 -x 10.10.10.20
dig @10.10.10.20 -x 10.10.10.10
```

**Before:**

**After:**
```
;; flags: qr aa rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1
;; QUESTION SECTION:
;20.10.10.10.in-addr.arpa.      IN      PTR
;; ANSWER SECTION:
20.10.10.10.in-addr.arpa. 86400 IN      PTR     rhel-srv01.linux.lab.local.
;; Query time: 0 msec

;; QUESTION SECTION:
;10.10.10.10.in-addr.arpa.      IN      PTR
;; ANSWER SECTION:
10.10.10.10.in-addr.arpa. 86400 IN      PTR     win-dc01.lab.local.
;; Query time: 0 msec
```

**Notes:**

**QUESTION SECTION potwierdza mechanizm `in-addr.arpa` z kroku 3.1:**
Widać dokładnie, co `dig -x 10.10.10.20` robi wewnętrznie — buduje zapytanie PTR o `20.10.10.10.in-addr.arpa.` (odwrócone oktety + sufiks). To nie jest magia — to standardowy mechanizm DNS. Teraz, gdy widzimy go w praktyce, nazwa strefy `10.10.10.in-addr.arpa` z konfiguracji staje się oczywista.

**Flaga `aa` — Bind autorytatywny dla reverse zone:**
Podobnie jak przy strefie forward w kroku 2.3, flaga `aa` potwierdza, że Bind odpowiada jako autorytet — nie forwarduje zapytania i nie pobiera odpowiedzi z cache.

**Drugi wynik — `win-dc01.lab.local.` z reverse zone Bind:**
`10.10.10.10` → `win-dc01.lab.local.` pochodzi z Bind, nie z win-dc01. Bind jest autorytatywny dla całego /24 i obsługuje reverse lookup nawet dla maszyn Windows. Gdyby ktoś zapytał win-dc01 o `dig -x 10.10.10.20`, wynik mógłby być inny (AD DNS nie ma tego rekordu) — ale w labie wszystkie maszyny będą pytać Bind.

### Conclusion

#### What - Co zrobiłem?
Zwalidowałem konfigurację reverse zone i przeładowałem Bind. Przetestowałem reverse lookup dla hosta Linux (`10.10.10.20`) i Windows (`10.10.10.10`).

---
#### Why - Dlaczego to zrobiłem?
Walidacja chroni przed błędami składniowymi przed przeładowaniem. Test potwierdza, że reverse DNS działa end-to-end dla obu typów hostów.

---
#### Result - Co dzięki temu uzyskałem?
Reverse DNS działa dla wszystkich hostów w labie — zarówno Linux (`linux.lab.local`) jak i Windows (`lab.local`). Od tego momentu usługi korzystające z reverse lookup (SSH, Kerberos, logi systemowe) widzą nazwy hostów zamiast surowych adresów IP. Step 3 kompletny.

---
#### Lesson Learned - Co się nauczyłem?
- `dig -x` buduje zapytanie PTR z odwróconymi oktetami — widać to w QUESTION SECTION (np. `20.10.10.10.in-addr.arpa.`). To nie jest magia, to standardowy mechanizm DNS.
- Flaga `aa` potwierdza autorytatywność Bind dla reverse zone — analogicznie jak przy strefie forward w kroku 2.3.
- Bind obsługuje reverse lookup nawet dla hostów Windows, bo jest jedynym autorytetem dla całego /24. AD DNS nie ma tych rekordów PTR.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
W tym kroku nie wystąpiły żadne problemy.

---

## Step 4 — Set up conditional forwarding to AD DNS and external internet forwarder

### 4.1 — Verify global forwarders in options block

The `forwarders` entry was added in step 2.2. Confirm it is present in `/etc/named.conf`:
```
options {
    ...
    forwarders { 8.8.8.8; 8.8.4.4; };
    ...
};
```

This handles all queries not covered by explicit zones (internet resolution).

**Before:**

**After:**

**Notes:**

**Hierarchia rozwiązywania nazw w Bind — od najwęższego do najszerszego:**
Bind dopasowuje zapytania w kolejności: (1) jawna strefa autorytatywna (`linux.lab.local` → serwuje lokalnie), (2) jawna strefa `forward` (`lab.local` → krok 4.2), (3) globalne `forwarders` w `options` (wszystko inne → 8.8.8.8). Globalne forwardery są ostatnią linią — obsługują internet i wszystko, czego Bind sam nie potrafi obsłużyć.

**Dlaczego forwardery zamiast pełnej rekurencji:**
Bez `forwarders` Bind musiałby sam chodzić po korzeniach DNS (root servers → TLD → authoritative). To działa, ale wymaga otwartego dostępu do internetu z serwera DNS i jest wolniejsze. Forwardowanie do Google DNS jest prostsze i wystarczające w środowiskach laboratoryjnych.

### Conclusion

#### What - Co zrobiłem?
Zweryfikowałem obecność globalnych forwarderów (`8.8.8.8`, `8.8.4.4`) w bloku `options` pliku `/etc/named.conf`.

---
#### Why - Dlaczego to zrobiłem?
Bind musi obsługiwać zapytania o nazwy internetowe, mimo że nie jest dla nich autorytatywny. Globalne forwardery delegują tę pracę do Google DNS — Bind staje się lokalnym proxy DNS dla całej sieci labowej.

---
#### Result - Co dzięki temu uzyskałem?
Forwardery są na miejscu (skonfigurowane w kroku 2.2). Bind jest gotowy do dodania bardziej specyficznego forwardingu AD w kroku 4.2.

---
#### Lesson Learned - Co się nauczyłem?
- Bind rozwiązuje nazwy hierarchicznie: (1) strefa autorytatywna → serwuje lokalnie, (2) jawna strefa `forward` → dedykowany forwarder, (3) globalne `forwarders` → ostatnia linia dla wszystkiego innego.
- Forwardowanie do Google DNS jest prostsze niż pełna rekurencja po korzeniach DNS (root servers → TLD → authoritative) i wystarczające w środowisku laboratoryjnym.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
W tym kroku nie wystąpiły żadne problemy.

---

### 4.2 — Add forward-only zone for `lab.local`

Append to `/etc/named.conf`:
```
zone "lab.local" IN {
    type forward;
    forwarders { 10.10.10.10; };
    forward only;
};
```

**Before:**

**After:**

**Notes:**

**`type forward` — Bind jako proxy, nie autorytet:**
W odróżnieniu od `type master`, Bind nie posiada danych tej strefy — tylko przekazuje zapytania dalej. Dla klienta wygląda to tak, jakby Bind odpowiadał, ale faktycznym źródłem jest win-dc01. Dzięki temu klient nie musi znać adresu win-dc01 — wszystko idzie przez jeden serwer DNS (rhel-srv01).

**`forward only` vs `forward first`:**
`forward only` — jeśli win-dc01 nie odpowie, Bind zwraca SERVFAIL. Żadnego fallbacku. To jest właściwe zachowanie dla AD DNS — nie chcemy żeby Bind próbował rekurować po internecie w poszukiwaniu `lab.local`. `forward first` — próbuje forwardera, a jeśli brak odpowiedzi, próbuje rekurencji. Użyteczne gdy forwarder jest zawodny.

**Dlaczego jawna strefa dla `lab.local`, nie kolejny globalny forwarder:**
Globalne `forwarders { 8.8.8.8; }` nie wiedziałyby nic o wewnętrznej domenie `lab.local` — zapytanie trafiłoby do Google i wróciłoby NXDOMAIN. Jawna strefa `forward` dla `lab.local` tworzy regułę routing DNS: ta konkretna domena → ten konkretny serwer.

### Conclusion

#### What - Co zrobiłem?
Dodałem strefę `type forward` dla `lab.local` w `/etc/named.conf` z forwarderem `10.10.10.10` (win-dc01) i trybem `forward only`.

---
#### Why - Dlaczego to zrobiłem?
Maszyny Linux muszą rozwiązywać nazwy domeny AD (`win-dc01.lab.local`, rekordy SRV Kerberos) — te dane istnieją tylko na win-dc01. Jawna strefa forward tworzy dedykowaną trasę DNS: każde zapytanie o `lab.local` trafia do win-dc01.

---
#### Result - Co dzięki temu uzyskałem?
Konfiguracja jest gotowa, ale wymaga reload w kroku 4.3. Poprawne działanie wymaga też `dnssec-validation no` (problem odkryty w kroku 4.3).

---
#### Lesson Learned - Co się nauczyłem?
- `type forward` — Bind jako proxy, nie autorytet. Nie posiada danych strefy, tylko przekazuje zapytania dalej.
- `forward only` oznacza brak fallbacku — jeśli win-dc01 nie odpowie, Bind zwraca SERVFAIL. To właściwe zachowanie dla AD DNS — nie chcemy, żeby Bind próbował rekurować po internecie w poszukiwaniu `lab.local`.
- Jawna strefa forward jest potrzebna, bo globalne forwardery (Google DNS) nie znają wewnętrznej domeny `lab.local` — zwróciłyby NXDOMAIN.
- To jest serce architektury split DNS w tym labie.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
W tym kroku nie wystąpiły żadne problemy (problem z DNSSEC ujawnia się dopiero w kroku 4.3).

---

### 4.3 — Validate and reload named

```bash
named-checkconf
systemctl reload named
```

Test AD forwarding:
```bash
dig @10.10.10.20 win-dc01.lab.local
dig @10.10.10.20 _ldap._tcp.lab.local SRV
dig @10.10.10.20 google.com
```

**Before:**

**After:**
```
win-dc01.lab.local:       status: SERVFAIL, ANSWER: 0,  Query time: 144 msec
_ldap._tcp.lab.local SRV: status: SERVFAIL, ANSWER: 0,  Query time: 1 msec
google.com:               status: NOERROR,  ANSWER: 1,  Query time: 58 msec
                          142.251.38.142
```

**Notes:**

**Trzy różne wyniki — trzy różne ścieżki:**
- `google.com` → NOERROR, 58 msec — globalne forwardery (8.8.8.8) działają. Bind poprawnie przekazał zapytanie do Google i otrzymał odpowiedź.
- `win-dc01.lab.local` → SERVFAIL, 144 msec — Bind próbował przekazać zapytanie do win-dc01 (10.10.10.10:53), czekał ~144 ms i nie otrzymał odpowiedzi. Brak flagi `aa` potwierdza, że to był forward, nie odpowiedź autorytatywna.
- `_ldap._tcp.lab.local` → SERVFAIL, 1 msec — wynik negatywny z cache. Bind wiedział już (z poprzedniego zapytania), że `lab.local` przez forwarder 10.10.10.10 nie działa, więc odpowiedział natychmiast z negatywnego cache.

**SERVFAIL vs REFUSED vs NXDOMAIN:**
`SERVFAIL` oznacza, że serwer DNS próbował coś zrobić, ale się nie udało (błąd serwera). W tym przypadku Bind nie mógł uzyskać odpowiedzi od win-dc01. `REFUSED` oznaczałoby, że win-dc01 odrzucił zapytanie. `NXDOMAIN` oznacza, że zapytanie dotarło i domena po prostu nie istnieje.

**Problem — AD forwarding nie działa (SERVFAIL):**
`dig @10.10.10.10 win-dc01.lab.local` (bezpośrednio do win-dc01 z rhel-srv01) zwraca NOERROR — win-dc01 odpowiada poprawnie, port 53 otwarty. Problem leży po stronie Bind.

Diagnoza przez `rndc trace 3` ujawniła:
```
validating lab.local/SOA: got insecure response; parent indicates it should be secure
no valid RRSIG resolving 'win-dc01.lab.local/DS/IN': 10.10.10.10#53
broken trust chain resolving 'win-dc01.lab.local/A/IN': 10.10.10.10#53
```
Bind ma domyślnie `dnssec-validation auto` — waliduje łańcuch DNSSEC dla każdej odpowiedzi. AD DNS nie podpisuje stref DNSSEC (brak RRSIG), więc Bind odrzuca odpowiedź jako "broken trust chain" i zwraca SERVFAIL.

Resolution: dodano `dnssec-validation no;` do bloku `options {}` w `/etc/named.conf` i przeładowano Bind. AD forwarding działa.

**Lesson Learned — DNSSEC validation w środowiskach hybrydowych:**
Domyślna konfiguracja RHEL Bind wymaga DNSSEC dla wszystkich odpowiedzi. Środowiska wewnętrzne (AD DNS, prywatne strefy) zwykle nie są podpisane DNSSEC — co powoduje SERVFAIL przy forwarding. W środowiskach produkcyjnych możliwe jest selektywne wyłączenie walidacji tylko dla konkretnych stref przez negative trust anchors (`rndc nta`), zamiast globalnego `dnssec-validation no`. W tym labie wyłączenie globalne jest akceptowalne.

### Conclusion

#### What - Co zrobiłem?
Zwalidowałem konfigurację i przeładowałem Bind. Przetestowałem forwarding do AD DNS (`lab.local`) i internet (`google.com`). Napotkałem problem z DNSSEC i go rozwiązałem dodając `dnssec-validation no;` do `options {}`.

---
#### Why - Dlaczego to zrobiłem?
Test potwierdza, że obie ścieżki forwarding (AD + internet) działają poprawnie end-to-end. Bez tego testu nie wiedzielibyśmy, że DNSSEC blokuje odpowiedzi AD DNS.

---
#### Result - Co dzięki temu uzyskałem?
Forwarding działa dla obu ścieżek: `lab.local` → win-dc01 ✅, internet → 8.8.8.8 ✅. Step 4 kompletny.

Wynik po fix:
```
win-dc01.lab.local: status: NOERROR, A 10.10.10.10, Query time: 0 msec
```

---
#### Lesson Learned - Co się nauczyłem?
- Domyślna konfiguracja RHEL Bind (`dnssec-validation auto`) wymaga podpisów DNSSEC od każdej odpowiedzi. AD DNS nie podpisuje stref — co powoduje "broken trust chain" i SERVFAIL.
- Diagnostyka: `rndc trace 3` + logi named ujawniają przyczynę — bez tego SERVFAIL jest nieczytelny.
- Rozwiązanie lab: `dnssec-validation no` globalnie. Produkcja: selektywne wyłączenie przez `rndc nta` (negative trust anchors) dla konkretnych stref.
- SERVFAIL = serwer próbował, ale się nie udało. REFUSED = serwer odrzucił zapytanie. NXDOMAIN = domena nie istnieje.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
AD forwarding zwracał SERVFAIL mimo że win-dc01 odpowiadał poprawnie na bezpośrednie zapytania. Przyczyna: walidacja DNSSEC w Bind odrzucała niepodpisane odpowiedzi AD DNS ("broken trust chain"). Rozwiązanie: dodano `dnssec-validation no;` do bloku `options {}` w `/etc/named.conf` i przeładowano Bind.

---

## Step 5 — Apply SELinux contexts and firewall rules

### 5.1 — Enable SELinux and verify context on zone files

Check current SELinux status:
```bash
getenforce
sestatus
```

**Before:**
```
[root@rhel-srv01 ~]# getenforce
Disabled
[root@rhel-srv01 ~]# sestatus
SELinux status: disabled
```

SELinux was disabled — enable it by editing the config:
```bash
vi /etc/selinux/config
# SELINUX=enforcing
```

Trigger full filesystem relabeling on next boot:
```bash
fixfiles -F onboot
```

Reboot:
```bash
reboot
```

After reboot — SELinux still disabled:
```
[root@rhel-srv01 ~]# getenforce
Disabled
[root@rhel-srv01 ~]# sestatus
SELinux status:                 disabled
```

`/etc/selinux/config` poprawnie ustawiony (`SELINUX=enforcing`), ale kernel ignoruje ustawienie.

Diagnoza:
```bash
dmesg | grep -i selinux
cat /proc/cmdline
```

```
dmesg: read kernel buffer failed: Operation not permitted
BOOT_IMAGE=/boot/vmlinuz-6.17.2-1-pve root=/dev/mapper/pve-root ro quiet
```

**Problem — SELinux nie działa w środowisku LXC:**
Kernel `6.17.2-1-pve` (sufiks `-pve`) to kernel Proxmox VE. Kontener działa jako nieprivileged LXC — brak dostępu do kernel ring buffer (`dmesg` zwraca `Operation not permitted`). SELinux w LXC wymaga wsparcia na poziomie hosta; gość nie może samodzielnie włączyć enforcement. Ustawienie `SELINUX=enforcing` w `/etc/selinux/config` jest ignorowane przez kernel.

Resolution: Świadoma decyzja — pomijamy SELinux enforcement w tym labie. Jest to znane ograniczenie LXC. Usługa `named` działa poprawnie bez SELinux. W środowisku produkcyjnym na pełnej VM SELinux byłby aktywny i konteksty `named_zone_t` na plikach stref wymagałyby weryfikacji przez `ls -lZ` i ewentualnie `restorecon`.

### Conclusion

#### What - Co zrobiłem?
Sprawdziłem status SELinux na rhel-srv01 (`getenforce`, `sestatus`). Próbowałem go włączyć — zmieniłem `/etc/selinux/config` na `SELINUX=enforcing`, uruchomiłem `fixfiles -F onboot` i zrestartowałem maszynę. Po restarcie SELinux nadal `Disabled`. Zdiagnozowałem przyczynę przez `cat /proc/cmdline` — kernel `-pve` i środowisko LXC.

---
#### Why - Dlaczego to zrobiłem?
SELinux to warstwa bezpieczeństwa mandatory access control (MAC) w RHEL/Rocky Linux. Pliki stref BIND powinny mieć kontekst `named_zone_t`, żeby `named` mógł je odczytać gdy SELinux jest aktywny. Weryfikacja i ewentualna korekta kontekstów to standardowy element konfiguracji BIND na RHEL.

---
#### Result - Co dzięki temu uzyskałem?
SELinux pozostaje wyłączony — środowisko LXC na Proxmox VE nie obsługuje SELinux enforcement od strony gościa. Krok 5.1 zakończony jako świadoma decyzja o pominięciu SELinux w tym labie. `named` działa poprawnie bez SELinux.

---
#### Lesson Learned - Co się nauczyłem?
- Kernel z sufiksem `-pve` to Proxmox VE kernel — znak, że system działa jako kontener LXC, nie VM.
- W nieprivileged LXC kontenerze `dmesg` zwraca `Operation not permitted` — brak dostępu do kernel ring buffer. To diagnostyczny wskaźnik środowiska LXC.
- SELinux w LXC jest zarządzany przez hosta, nie gościa. Zmiana `/etc/selinux/config` w kontenerze nie ma efektu, jeśli host nie ma włączonego SELinux lub kontener nie ma odpowiednich uprawnień.
- W pełnej VM (KVM/VMware) konfiguracja `/etc/selinux/config` + `fixfiles -F onboot` + reboot działa prawidłowo i po restarcie SELinux jest aktywny.
- `named_zone_t` — poprawny kontekst SELinux dla plików stref BIND. Bez tego kontekstu SELinux blokowałby dostęp `named` do plików przy włączonym enforcement.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Problemu nie rozwiązano technicznie — SELinux nie może być włączony w środowisku LXC na Proxmox VE. Podjęto świadomą decyzję o pominięciu tego kroku. Ograniczenie jest architektoniczne (LXC vs VM), nie błędem konfiguracji.

---

### 5.2 — Open DNS ports in firewalld

Check if firewalld is installed:
```bash
firewall-cmd --state
systemctl status firewalld
```

**Before:**
```
[root@rhel-srv01 ~]# firewall-cmd
-bash: firewall-cmd: command not found
[root@rhel-srv01 ~]# systemctl status firewalld
Unit firewalld.service could not be found.
```

firewalld not installed — install and enable it:
```bash
dnf install -y firewalld
systemctl enable --now firewalld
firewall-cmd --state
```

**After install:**

Open DNS port and reload:
```bash
firewall-cmd --permanent --add-service=dns
firewall-cmd --reload
firewall-cmd --list-services
```

**After:**

Verify DNS is reachable from another machine (e.g. from Proxmox host):
```bash
dig @10.10.10.20 rhel-srv01.linux.lab.local
```


### Conclusion

#### What - Co zrobiłem?
Sprawdziłem obecność firewalld na rhel-srv01 — nie był zainstalowany. Zainstalowałem go przez `dnf install -y firewalld`, włączyłem i uruchomiłem przez `systemctl enable --now firewalld`. Dodałem serwis `dns` do strefy domyślnej (`firewall-cmd --permanent --add-service=dns`) i przeładowałem reguły. Zweryfikowałem dostępność portu 53 z zewnątrz przez `dig @10.10.10.20 rhel-srv01.linux.lab.local` z hosta Proxmox i z ubuntu-ws01.

---
#### Why - Dlaczego to zrobiłem?
Port 53 (TCP i UDP) musi być dostępny, żeby zewnętrzne maszyny mogły używać BIND jako resolvera DNS. Bez otwarcia portu zapytania DNS z innych hostów byłyby blokowane przez firewall na poziomie serwera.

---
#### Result - Co dzięki temu uzyskałem?
Port 53 dostępny z zewnątrz — potwierdzone przez `dig @10.10.10.20 rhel-srv01.linux.lab.local` z Proxmox hosta i ubuntu-ws01, oba zwracają `NOERROR, A 10.10.10.20`. Flaga `aa` (authoritative answer) potwierdza, że BIND odpowiada autorytatywnie dla strefy `linux.lab.local`. Krok 5 kompletny.

Jedyna brakująca część: `nslookup rhel-srv01.linux.lab.local 10.10.10.10` zwraca NXDOMAIN — win-dc01 nie ma jeszcze delegacji NS dla podstrefy `linux.lab.local`. To jest cel kroku 6.

---
#### Lesson Learned - Co się nauczyłem?
- W Rocky Linux 9 (minimal install / LXC template) `firewalld` może nie być zainstalowany domyślnie — zawsze warto sprawdzić przed konfiguracją reguł.
- Serwis `dns` w firewalld otwiera jednocześnie **TCP/53 i UDP/53** — nie trzeba dodawać portów ręcznie.
- W środowisku LXC port 53 może być dostępny z zewnątrz nawet bez jawnie skonfigurowanego firewalld (brak domyślnych reguł blokujących), ale best practice to zawsze mieć świadomą konfigurację firewall.
- Flaga `aa` (Authoritative Answer) w odpowiedzi `dig` potwierdza, że serwer jest autorytatywny dla strefy — brak `aa` oznacza odpowiedź z cache lub przez forward.
- `WARNING: .local is reserved for Multicast DNS` w `dig` — ostrzeżenie informacyjne. `dig` z jawnym `@server` ignoruje mDNS i wysyła zapytanie bezpośrednio do wskazanego serwera.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
`firewalld` nie był zainstalowany — `firewall-cmd: command not found`. Rozwiązanie: instalacja przez `dnf install -y firewalld` i dodanie serwisu `dns`. Po konfiguracji port 53 dostępny z zewnątrz.

---

## Step 6 — Add NS delegation on win-dc01 and update Linux LXC resolvers

### 6.1 — Add NS delegation record on win-dc01

Connect to win-mgmt01 via RDP (tunnel: `ssh -L 13389:10.10.10.11:3389 root@10.28.0.200`).

**Option A — DNS Manager GUI (on win-mgmt01 or win-dc01):**
```
Server Manager > Tools > DNS > Connect to win-dc01
Forward Lookup Zones > lab.local > Right-click > New Delegation...
  Delegated domain: linux
  Name server FQDN: rhel-srv01.linux.lab.local.
  IP: 10.10.10.20
```

**Option B — PowerShell on win-mgmt01:**
```powershell
Add-DnsServerZoneDelegation -ZoneName "lab.local" -Name "linux" `
    -NameServer "rhel-srv01.linux.lab.local." -IPAddress "10.10.10.20"
```

Verify from Windows:
```powershell
Resolve-DnsName rhel-srv01.linux.lab.local
```

Result:
```
PS C:\Users\Administrator> Resolve-DnsName rhel-srv01.linux.lab.local

Name                                           Type   TTL   Section    IPAddress
----                                           ----   ---   -------    ---------
rhel-srv01.linux.lab.local                     A      86399 Answer     10.10.10.20
```

### Conclusion

#### What - Co zrobiłem?
Dodałem delegację NS dla podstrefy `linux.lab.local` na win-dc01 przez PowerShell (`Add-DnsServerZoneDelegation`). Wskazałem `rhel-srv01.linux.lab.local.` (IP: `10.10.10.20`) jako name server dla tej podstrefy. Zweryfikowałem przez `Resolve-DnsName rhel-srv01.linux.lab.local` z poziomu win-mgmt01.

---
#### Why - Dlaczego to zrobiłem?
Bez delegacji NS win-dc01 był autorytatywny dla całej strefy `lab.local`, ale nie wiedział o podstrefie `linux.lab.local` obsługiwanej przez BIND. Każde zapytanie o `*.linux.lab.local` do win-dc01 kończyło się NXDOMAIN. Delegacja mówi win-dc01: "zapytania o `linux.lab.local` przekaż do rhel-srv01".

---
#### Result - Co dzięki temu uzyskałem?
`Resolve-DnsName rhel-srv01.linux.lab.local` z Windows zwraca `A 10.10.10.20` ✅ — win-dc01 poprawnie deleguje zapytania o `linux.lab.local` do BIND na rhel-srv01. Wcześniej to samo zapytanie zwracało NXDOMAIN (widoczne w wynikach `dig @10.10.10.10` z etapu testów w kroku 5.2).

---
#### Lesson Learned - Co się nauczyłem?
- **Delegacja NS** (zone delegation) to mechanizm, który mówi nadrzędnemu serwerowi DNS: "ta podstrefa jest obsługiwana przez inny serwer — zapytaj go bezpośrednio". win-dc01 jest autorytatywny dla `lab.local`, ale nie musi znać rekordów `linux.lab.local` — wystarczy, że wskazuje na rhel-srv01.
- `Add-DnsServerZoneDelegation` tworzy w strefie `lab.local` rekord NS wskazujący na rhel-srv01 oraz rekord glue A (adres IP name servera), żeby resolver wiedział jak dotrzeć do delegowanego serwera.
- Mechanizm ten jest analogiczny do tego, jak root serwery DNS delegują strefy TLD (`.com`, `.pl`) do odpowiednich rejestrów — hierarchia DNS działa przez łańcuch delegacji.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Zapytania o `*.linux.lab.local` kierowane do win-dc01 (10.10.10.10) zwracały NXDOMAIN — win-dc01 nie wiedział o podstrefie. Po dodaniu delegacji NS zapytania są prawidłowo przekazywane do rhel-srv01 i zwracają poprawne odpowiedzi.

---

### 6.2 — Update DNS resolver on rhel-srv01

rhel-srv01 should query itself as primary DNS.

Stan przed zmianą — rhel-srv01 pytał Windows DC (10.10.10.10):

```
[root@rhel-srv01 ~]# cat /etc/resolv.conf
# Generated by NetworkManager
search lab.local
nameserver 10.10.10.10
```

```
[root@rhel-srv01 ~]# dig win-dc01.lab.local
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 51650
;; flags: qr aa rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 4000
;; ANSWER SECTION:
win-dc01.lab.local.     3600    IN      A       10.10.10.10

;; Query time: 0 msec
;; SERVER: 10.10.10.10#53(10.10.10.10)
```

Zmiana resolvera na BIND (sam siebie):

```bash
nmcli con mod "$(nmcli -g NAME con show --active | head -1)" \
    ipv4.dns "10.10.10.20" \
    ipv4.dns-search "linux.lab.local lab.local"
nmcli con up "$(nmcli -g NAME con show --active | head -1)"
```

```
Connection successfully activated (D-Bus active path: /org/freedesktop/NetworkManager/ActiveConnection/3)
```

Weryfikacja po zmianie:

```
[root@rhel-srv01 ~]# cat /etc/resolv.conf
# Generated by NetworkManager
search linux.lab.local lab.local
nameserver 10.10.10.20
```

```
[root@rhel-srv01 ~]# dig win-dc01.lab.local
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 33984
;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1232
; COOKIE: f46393892aa3644b0100000069ccd789934b212f2579dd53 (good)
;; ANSWER SECTION:
win-dc01.lab.local.     3600    IN      A       10.10.10.10

;; Query time: 0 msec
;; SERVER: 10.10.10.20#53(10.10.10.20)
```

Porównanie odpowiedzi przed i po:

| Cecha | Przed (win-dc01) | Po (BIND/rhel-srv01) |
|---|---|---|
| SERVER | 10.10.10.10 | 10.10.10.20 |
| Flaga `aa` (authoritative) | ✅ tak | ❌ nie — BIND forwarduje, nie jest autorytatywny dla `lab.local` |
| EDNS udp buffer | 4000 (Windows DNS default) | 1232 (BIND default, RFC 8020) |
| COOKIE | brak | present (good) — mechanizm ochrony przed DNS spoofing |
| search domains | `lab.local` | `linux.lab.local lab.local` |

### Conclusion

#### What - Co zrobiłem?
Zmieniono resolver DNS na rhel-srv01 z Windows DC (10.10.10.10) na lokalny BIND (10.10.10.20) za pomocą `nmcli con mod`. Ustawiono search domains na `linux.lab.local lab.local`.

---
#### Why - Dlaczego to zrobiłem?
rhel-srv01 jest serwerem DNS dla strefy `linux.lab.local` — powinien używać samego siebie jako resolvera, a nie Windows DC. Dzięki temu zapytania o `*.linux.lab.local` są rozwiązywane lokalnie (autorytatywnie), a zapytania o `*.lab.local` są forwardowane do Windows DC przez konfigurację `forwarders` w BIND.

---
#### Result - Co dzięki temu uzyskałem?
Resolver na rhel-srv01 wskazuje na BIND (10.10.10.20). Resolucja `win-dc01.lab.local` działa poprawnie — BIND forwarduje zapytanie do Windows DC i zwraca prawidłowy wynik. Konfiguracja search domains pozwala na skrócone zapytania (np. `ping rhel-srv01` zamiast `ping rhel-srv01.linux.lab.local`).

---
#### Lesson Learned - Co się nauczyłem?
- Flaga `aa` (Authoritative Answer) znika, gdy odpowiedź przechodzi przez forwarder — BIND nie jest autorytatywny dla `lab.local`, więc przekazuje odpowiedź Windows DC bez flagi `aa`. To normalne i poprawne zachowanie.
- EDNS COOKIE to mechanizm bezpieczeństwa DNS (RFC 7873) — BIND automatycznie go wspiera. Służy do ochrony przed spoofingiem odpowiedzi DNS.
- Wartość `udp: 1232` (zamiast 4000 z Windows DNS) to zalecany rozmiar buffera EDNS wg RFC 8020 — minimalizuje ryzyko fragmentacji pakietów UDP.
- `nmcli con mod` zmienia konfigurację trwale, ale wymaga `nmcli con up` do aktywacji zmian. NetworkManager automatycznie regeneruje `/etc/resolv.conf`.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Problemów nie było — zmiana resolvera i weryfikacja przebiegły bez błędów. Zapytania DNS z rhel-srv01 przechodzą teraz przez lokalny BIND.

---

### 6.3 — Update DNS resolvers on remaining Linux LXCs

#### ipa-srv01 (10.10.10.40) i repo-srv01 (10.10.10.50) — Rocky Linux

Na obu maszynach zmieniono resolver przez `nmcli`:

```bash
nmcli con mod "$(nmcli -g NAME con show --active | head -1)" \
    ipv4.dns "10.10.10.20" \
    ipv4.dns-search "linux.lab.local lab.local"
nmcli con up "$(nmcli -g NAME con show --active | head -1)"
```

Obie aktywowane pomyślnie. Po zmianie `/etc/resolv.conf` wskazuje na `nameserver 10.10.10.20`, `search linux.lab.local lab.local`.

Problem — `dig` niedostępny na ipa-srv01 i repo-srv01:
```
-bash: dig: command not found
```
Resolution: Brak pakietu `bind-utils` na minimalnych instalacjach Rocky. Zainstalowano `dnf install bind-utils`.

Weryfikacja po instalacji `bind-utils` — na ipa-srv01 i repo-srv01:
```bash
dig rhel-srv01.linux.lab.local
dig win-dc01.lab.local
```

Wyniki identyczne na obu maszynach. Na co zwrócić uwagę:

| Zapytanie | Kluczowe elementy | Wartość | OK? |
|---|---|---|---|
| `rhel-srv01.linux.lab.local` | SERVER | `10.10.10.20` (BIND) | ✅ resolver to BIND, nie Windows DC |
| | status | NOERROR | ✅ rekord znaleziony |
| | flaga `aa` | obecna | ✅ BIND odpowiada autorytatywnie (to jego strefa) |
| | ANSWER | `A 10.10.10.20` | ✅ poprawny IP |
| `win-dc01.lab.local` | SERVER | `10.10.10.20` (BIND) | ✅ zapytanie przeszło przez BIND |
| | status | NOERROR | ✅ rekord znaleziony |
| | flaga `aa` | brak | ✅ BIND forwarduje — nie jest autorytatywny dla `lab.local` |
| | ANSWER | `A 10.10.10.10` | ✅ poprawny IP |

Oba scenariusze działają poprawnie — BIND rozwiązuje swoją strefę autorytatywnie, a zapytania o `lab.local` forwarduje do Windows DC.

#### ubuntu-ws01 (10.10.10.30)

Problem — `/etc/systemd/resolved.conf` miał poprawną konfigurację (`DNS=10.10.10.20`), ale po `systemctl restart systemd-resolved` resolver nadal wskazywał na Windows DC (`SERVER: 10.10.10.10`).

Diagnostyka:
```
resolvectl status → resolv.conf mode: foreign
ls -la /etc/resolv.conf → zwykły plik (nie symlink), z markerami # --- BEGIN PVE ---
```

Resolution: W kontenerze LXC Proxmox zarządza `/etc/resolv.conf` bezpośrednio (markery PVE) — systemd-resolved go nie nadpisuje. Edycja pliku ręcznie:
```bash
cat > /etc/resolv.conf << 'EOF'
search linux.lab.local lab.local
nameserver 10.10.10.20
EOF
```

Weryfikacja po zmianie — `SERVER: 10.10.10.20`, flaga `aa` dla `linux.lab.local`, brak `aa` dla `lab.local`. ✅

### Conclusion

#### What - Co zrobiłem?
Zmieniono resolver DNS na wszystkich 3 maszynach Linux na BIND (10.10.10.20). Rocky Linux (ipa-srv01, repo-srv01) — przez `nmcli con mod`. Ubuntu (ubuntu-ws01) — przez ręczną edycję `/etc/resolv.conf`. Zainstalowano `bind-utils` na Rocky LXC.

---
#### Why - Dlaczego to zrobiłem?
Wszystkie maszyny Linux powinny używać BIND jako primary DNS, aby zapytania o `*.linux.lab.local` były rozwiązywane autorytatywnie, a zapytania o `*.lab.local` forwardowane do Windows DC.

---
#### Result - Co dzięki temu uzyskałem?
Wszystkie 3 maszyny Linux używają BIND jako resolvera. Weryfikacja `dig` potwierdza poprawność na każdej z nich — `SERVER: 10.10.10.20`, NOERROR, poprawne IP.

---
#### Lesson Learned - Co się nauczyłem?
- **Trzy różne metody zmiany resolvera** w zależności od systemu i środowiska:
  - **Rocky Linux** → `nmcli con mod` (NetworkManager zarządza `/etc/resolv.conf`)
  - **Ubuntu (standardowo)** → edycja `/etc/systemd/resolved.conf` + restart (systemd-resolved zarządza DNS, `/etc/resolv.conf` jest symlinkiem do stub resolvera `127.0.0.53`)
  - **Ubuntu LXC (Proxmox)** → ręczna edycja `/etc/resolv.conf`, bo Proxmox zarządza tym plikiem bezpośrednio (markery `# --- BEGIN PVE ---`), a systemd-resolved raportuje `resolv.conf mode: foreign` i go nie nadpisuje
- **`bind-utils`** (zawiera `dig`, `nslookup`, `host`) nie jest instalowany domyślnie na minimalnych instalacjach Rocky Linux
- Proxmox może nadpisać `/etc/resolv.conf` przy restarcie kontenera — trwałą zmianę ustawia się przez `pct set <CTID> --nameserver ... --searchdomain ...` na hoście Proxmox

---
#### Problem solved - Jakie problemy zostały rozwiązane?
- Brak `bind-utils` na ipa-srv01 i repo-srv01 — zainstalowano `dnf install bind-utils`
- Zmiana resolvera na ubuntu-ws01 przez `systemd-resolved` nie działała — `/etc/resolv.conf` zarządzany przez Proxmox (mode: foreign). Rozwiązanie: bezpośrednia edycja pliku

---

## Step 7 — Test forward and reverse resolution and cross-platform name resolution

### 7.1 — Test A records in `linux.lab.local`

Run from rhel-srv01:
```bash
for host in rhel-srv01 ubuntu-ws01 ipa-srv01 repo-srv01; do
    echo "--- $host ---"
    dig +short ${host}.linux.lab.local
done
```

Result is:
```
rhel-srv01  → 10.10.10.20 ✅
ubuntu-ws01 → 10.10.10.30 ✅
ipa-srv01   → 10.10.10.40 ✅
repo-srv01  → 10.10.10.50 ✅
```

Wszystkie rekordy A w strefie `linux.lab.local` rozwiązane poprawnie.

### Conclusion

#### What - Co zrobiłem?
Przetestowano resolucję wszystkich rekordów A w strefie `linux.lab.local` z poziomu rhel-srv01 za pomocą `dig +short`.

---
#### Why - Dlaczego to zrobiłem?
Weryfikacja, że BIND poprawnie serwuje rekordy A dla wszystkich hostów w strefie forward.

---
#### Result - Co dzięki temu uzyskałem?
Wszystkie 4 hosty (rhel-srv01, ubuntu-ws01, ipa-srv01, repo-srv01) zwracają poprawne adresy IP. Strefa forward działa.

---
#### Lesson Learned - Co się nauczyłem?
- `dig +short` to wygodna forma weryfikacji — zwraca sam wynik bez pełnego outputu, idealna do szybkich testów wielu rekordów w pętli.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Problemów nie było.

---

### 7.2 — Test PTR records

```bash
for ip in 20 30 40 50 10 11; do
    echo "--- 10.10.10.$ip ---"
    dig +short -x 10.10.10.$ip
done
```

Result is:
```
10.10.10.20 → rhel-srv01.linux.lab.local.   ✅
10.10.10.30 → ubuntu-ws01.linux.lab.local.  ✅
10.10.10.40 → ipa-srv01.linux.lab.local.    ✅
10.10.10.50 → repo-srv01.linux.lab.local.   ✅
10.10.10.10 → win-dc01.lab.local.           ✅
10.10.10.11 → win-mgmt01.lab.local.         ✅
```

Rekordy PTR dla `linux.lab.local` (20–50) rozwiązane autorytatywnie przez BIND. Rekordy PTR dla `lab.local` (10, 11) rozwiązane przez forwarding do Windows DC.

### Conclusion

#### What - Co zrobiłem?
Przetestowano resolucję reverse DNS (PTR) dla wszystkich hostów w sieci 10.10.10.0/24.

---
#### Why - Dlaczego to zrobiłem?
Weryfikacja, że strefa reverse (`10.10.10.in-addr.arpa`) działa poprawnie — zarówno dla hostów Linux (BIND autorytatywnie) jak i Windows (forwarding do win-dc01).

---
#### Result - Co dzięki temu uzyskałem?
Wszystkie 6 rekordów PTR rozwiązanych poprawnie. Reverse DNS działa dla obu stref.

---
#### Lesson Learned - Co się nauczyłem?
- BIND obsługuje reverse lookup dla całej podsieci 10.10.10.0/24 — rekordy Linux ma lokalnie, a rekordy Windows forwarduje do win-dc01. Dzięki temu jeden `dig -x` na dowolny adres z tej podsieci zawsze zwraca wynik.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Problemów nie było.

---

### 7.3 — Test AD SRV records via forwarder

```bash
dig +short win-dc01.lab.local
dig +short _ldap._tcp.lab.local SRV
dig +short _kerberos._tcp.lab.local SRV
```

Result is:
```
win-dc01.lab.local          → 10.10.10.10                    ✅
_ldap._tcp.lab.local    SRV → 0 100 389 win-dc01.lab.local.  ✅
_kerberos._tcp.lab.local SRV → 0 100 88 win-dc01.lab.local.  ✅
```

Rekordy AD SRV (LDAP port 389, Kerberos port 88) rozwiązane poprawnie przez BIND → forwarding do Windows DC.

### Conclusion

#### What - Co zrobiłem?
Przetestowano resolucję rekordów SRV Active Directory (`_ldap._tcp`, `_kerberos._tcp`) z poziomu rhel-srv01 przez BIND.

---
#### Why - Dlaczego to zrobiłem?
Weryfikacja, że BIND poprawnie forwarduje zapytania o rekordy SRV usług AD do Windows DC. To krytyczne dla przyszłej integracji Linux ↔ AD (join domain, SSO).

---
#### Result - Co dzięki temu uzyskałem?
Rekordy SRV dla LDAP i Kerberos rozwiązane poprawnie. Maszyny Linux mogą odkrywać usługi AD przez DNS.

---
#### Lesson Learned - Co się nauczyłem?
- **Rekordy SRV** (`_usługa._protokół.domena`) to mechanizm odkrywania usług w DNS — Active Directory intensywnie z nich korzysta. Klient szukający kontrolera domeny pyta o `_ldap._tcp.lab.local` i dostaje adres + port serwera.
- Format odpowiedzi SRV: `priority weight port target` — tutaj `0 100 389 win-dc01.lab.local.` oznacza LDAP na porcie 389 na win-dc01.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
Problemów nie było.

---

### 7.4 — Test `linux.lab.local` resolution from Windows

Run from win-mgmt01 (PowerShell):
```powershell
Resolve-DnsName rhel-srv01.linux.lab.local
Resolve-DnsName ubuntu-ws01.linux.lab.local
Resolve-DnsName 10.10.10.20
```

Result is:
```
rhel-srv01.linux.lab.local   → A 10.10.10.20  ✅ (delegacja NS → BIND)
ubuntu-ws01.linux.lab.local  → A 10.10.10.30  ✅ (delegacja NS → BIND)
10.10.10.20 (PTR)            → DNS name does not exist ❌
```

Problem — reverse lookup (PTR) z Windows nie działa:
```
Resolve-DnsName: 20.10.10.10.in-addr.arpa : DNS name does not exist.
```
Przyczyna: win-dc01 nie ma delegacji dla strefy reverse `10.10.10.in-addr.arpa` do BIND. Forward delegation (NS dla `linux.lab.local`) istnieje, ale reverse zone nie ma analogicznej delegacji.

Resolution: Dodano conditional forwarder na win-dc01:
```powershell
Add-DnsServerConditionalForwarderZone -Name "10.10.10.in-addr.arpa" -MasterServers 10.10.10.20
```

Ponowna weryfikacja po dodaniu conditional forwarder:
```
rhel-srv01.linux.lab.local   → A 10.10.10.20                  ✅
ubuntu-ws01.linux.lab.local  → A 10.10.10.30                  ✅
10.10.10.20 (PTR)            → rhel-srv01.linux.lab.local      ✅
```

Wszystkie testy przechodzą — forward i reverse resolution z Windows działa.

### Conclusion

#### What - Co zrobiłem?
Przetestowano resolucję `linux.lab.local` z poziomu Windows (win-mgmt01). Po wykryciu problemu z reverse lookup dodano conditional forwarder na win-dc01 dla strefy `10.10.10.in-addr.arpa` → BIND.

---
#### Why - Dlaczego to zrobiłem?
Weryfikacja cross-platform — Windows musi umieć rozwiązywać nazwy Linux (forward i reverse) w środowisku hybrydowym.

---
#### Result - Co dzięki temu uzyskałem?
Forward i reverse resolution z Windows → Linux działa. Docelowa konfiguracja DNS osiągnięta:
- BIND auth: `linux.lab.local` + `10.10.10.in-addr.arpa`, forward `lab.local` → win-dc01
- win-dc01 auth: `lab.local`, delegacja NS `linux.lab.local` → BIND, cond. forwarder reverse → BIND

---
#### Lesson Learned - Co się nauczyłem?
- **Forward i reverse to osobne strefy** — delegacja NS dla `linux.lab.local` nie obejmuje automatycznie reverse zone. Trzeba osobno skonfigurować forwarding/delegację dla `10.10.10.in-addr.arpa`.
- **Conditional forwarder** na win-dc01 to najczystsze rozwiązanie, bo BIND już jest autorytatywny dla całej strefy reverse (ma PTR zarówno dla Linux jak i Windows). Win-dc01 po prostu przekazuje zapytania reverse do BIND.
- Architektura DNS w tym labie jest **symetryczna**: BIND forwarduje `lab.local` → win-dc01, a win-dc01 forwarduje reverse → BIND.

---
Reverse lookup (PTR) z Windows nie działał — win-dc01 nie wiedział, że o `10.10.10.in-addr.arpa` ma pytać BIND. Rozwiązanie: `Add-DnsServerConditionalForwarderZone` na win-dc01.

---

## LAB-01 — Conclusion

#### What - Co zrobiłem?
Wdrożono kompletną infrastrukturę DNS dla środowiska hybrydowego Windows/Linux:
- Zainstalowano BIND na rhel-srv01 (`bind`, `bind-utils`), uruchomiono usługę `named`
- Skonfigurowano strefę forward `linux.lab.local` z rekordami A dla 4 hostów Linux
- Skonfigurowano strefę reverse `10.10.10.in-addr.arpa` z rekordami PTR dla wszystkich 6 hostów (Linux + Windows)
- Ustawiono conditional forwarding `lab.local` → win-dc01 oraz globalne forwardery → Google DNS
- Skonfigurowano `named.conf`: `listen-on`, `allow-query`, `forwarders`, `dnssec-validation no`
- Zainstalowano i skonfigurowano `firewalld` z serwisem `dns`
- Na win-dc01 dodano delegację NS (`linux.lab.local` → BIND) i conditional forwarder (reverse zone → BIND)
- Zmieniono resolver DNS na wszystkich maszynach Linux na BIND (10.10.10.20)
- Przetestowano resolucję: A records, PTR records, SRV records (LDAP, Kerberos) i cross-platform (Linux ↔ Windows)

---
#### Why - Dlaczego to zrobiłem?
Środowisko hybrydowe Windows/Linux wymaga spójnej resolucji DNS w obu kierunkach. BIND obsługuje strefę Linux, Windows DC obsługuje strefę AD — oba serwery współpracują przez forwarding i delegację, bez duplikacji danych. DNS jest fundamentem dla kolejnych ćwiczeń — Apache (virtual hosts), AD join (SRV records), FreeIPA (Kerberos), LDAP — wszystkie wymagają działającej resolucji nazw.

---
#### Result - Co dzięki temu uzyskałem?
Pełna resolucja DNS w labie — każda maszyna (Linux i Windows) może rozwiązać nazwę i adres IP dowolnej innej maszyny. Usługi AD (LDAP port 389, Kerberos port 88) są odkrywalne z poziomu Linux przez rekordy SRV. Architektura docelowa:
- **BIND** (rhel-srv01): auth `linux.lab.local` + `10.10.10.in-addr.arpa`, forward `lab.local` → win-dc01, forward internet → 8.8.8.8
- **win-dc01**: auth `lab.local`, delegacja NS `linux.lab.local` → BIND, cond. forwarder reverse → BIND

Jedyne ograniczenie: SELinux nie działa w LXC — w produkcji na pełnej VM byłby aktywny.

---
#### Lesson Learned - Co się nauczyłem?

**Architektura DNS:**
- **Split-DNS** — w środowisku hybrydowym każda strona jest autorytatywna dla swojej strefy i forwarduje to, czego nie zna. Architektura jest symetryczna: BIND forwarduje `lab.local` → win-dc01, win-dc01 forwarduje reverse → BIND.
- **Subdomena `linux.lab.local`** zamiast `lab.local` — AD DNS musi pozostać właścicielem `lab.local` (rekordy SRV Kerberos, DC locator). Deklaracja autorytywności BIND dla `lab.local` zepsułaby Active Directory.
- **Forward ≠ reverse** — to dwie niezależne strefy i konfiguracje. Delegacja NS dla `linux.lab.local` nie obejmuje automatycznie `10.10.10.in-addr.arpa`.
- **Delegacja NS** vs **conditional forwarder** — delegacja (na win-dc01 dla forward zone) tworzy rekord NS + glue A w strefie nadrzędnej; conditional forwarder (dla reverse zone) to prostsza konfiguracja "przekaż wszystko do tego serwera". Oba mechanizmy osiągają ten sam cel różnymi metodami.

**Konfiguracja BIND:**
- **Hierarchia rozwiązywania nazw**: (1) strefa autorytatywna → serwuje lokalnie, (2) jawna strefa `forward` → dedykowany forwarder, (3) globalne `forwarders` → ostatnia linia dla internetu.
- **Dwupoziomowa kontrola dostępu**: `listen-on` (interfejs) + `allow-query` (klient). Domyślnie BIND słucha tylko na `127.0.0.1`.
- **`type master`** = autorytatywne źródło danych. **`type forward`** = proxy — nie posiada danych, tylko przekazuje. **`forward only`** = brak fallbacku, co jest właściwe dla AD DNS.
- **Walidacja przed reloadem**: `named-checkconf` + `named-checkzone` chronią przed błędami składniowymi. `reload` wczytuje konfigurację bez przerywania usługi (w odróżnieniu od `restart`).
- **Numer seryjny w SOA** musi być inkrementowany przy każdej zmianie strefy.
- **Uprawnienia plików stref**: `root:named`, `chmod 640` — `named` działa jako użytkownik `named`, nie root.

**Reverse DNS:**
- Mechanizm `in-addr.arpa` odwraca oktety IP: `dig -x 10.10.10.20` → zapytanie o `20.10.10.10.in-addr.arpa.`
- Etykiety PTR to tylko ostatni oktet; FQDN w wartości PTR musi kończyć się kropką.
- BIND obsługuje reverse dla całego /24 (Linux + Windows) — prostsze niż dzielenie strefy między dwa serwery.

**DNSSEC:**
- Domyślna konfiguracja RHEL BIND (`dnssec-validation auto`) wymaga podpisów DNSSEC od każdej odpowiedzi. AD DNS nie podpisuje stref → "broken trust chain" → SERVFAIL.
- Diagnostyka: `rndc trace 3` + logi `named` ujawniają przyczynę. Bez tego SERVFAIL jest nieczytelny.
- Lab: `dnssec-validation no` globalnie. Produkcja: selektywne wyłączenie przez `rndc nta` (negative trust anchors).

**SELinux i firewall:**
- SELinux nie działa w kontenerach LXC na Proxmox VE — kernel hosta nie wspiera enforcement w gościu. Kernel `-pve` i brak dostępu do `dmesg` to wskaźniki środowiska LXC.
- W produkcji: pliki stref BIND wymagają kontekstu `named_zone_t` (weryfikacja: `ls -lZ`, korekta: `restorecon`).
- `firewalld` może nie być zainstalowany na minimalnym Rocky Linux. Serwis `dns` otwiera TCP+UDP 53 jednocześnie.

**Weryfikacja DNS (`dig`):**
- **`SERVER`** — kto odpowiedział na zapytanie (kluczowe przy debugowaniu resolverów)
- **`status`** — NOERROR (OK), NXDOMAIN (domena nie istnieje), SERVFAIL (błąd serwera), REFUSED (ACL)
- **Flaga `aa`** — Authoritative Answer: serwer odpowiedział jako autorytet. Brak `aa` = odpowiedź z cache lub przez forward (normalne dla forwardowanych zapytań)
- **EDNS COOKIE** — mechanizm ochrony przed DNS spoofing (RFC 7873), BIND wspiera automatycznie
- **`dig +short`** — wygodna forma do szybkich testów wielu rekordów w pętli
- **Rekordy SRV** (`_usługa._protokół.domena`) — mechanizm odkrywania usług. Format: `priority weight port target`

**Zarządzanie resolverami na klientach:**
- **Rocky Linux** → `nmcli con mod` + `nmcli con up` (NetworkManager generuje `/etc/resolv.conf`)
- **Ubuntu (standardowo)** → edycja `/etc/systemd/resolved.conf` + restart (systemd-resolved zarządza DNS, `/etc/resolv.conf` jest symlinkiem do stub resolvera `127.0.0.53`)
- **Ubuntu LXC (Proxmox)** → ręczna edycja `/etc/resolv.conf` (Proxmox zarządza plikiem bezpośrednio — markery `# --- BEGIN PVE ---`, systemd-resolved raportuje `resolv.conf mode: foreign`)
- Proxmox może nadpisać `/etc/resolv.conf` przy restarcie kontenera — trwała zmiana przez `pct set <CTID> --nameserver ... --searchdomain ...`

**Post-LAB-04 discovery:** Po restarcie kontenera LXC (lub przywróceniu snapshota) resolver na rhel-srv01 cofnął się do `10.10.10.10` (Windows DC) zamiast `10.10.10.20` (BIND). Przyczyna: `nmcli con mod` zmienia konfigurację profilu NetworkManager, ale Proxmox może nadpisać `/etc/resolv.conf` przy starcie LXC. Trwała naprawa wymaga ustawienia resolvera na poziomie Proxmox: `pct set <CTID> --nameserver 10.10.10.20 --searchdomain "linux.lab.local lab.local"` — to zabezpiecza konfigurację przed nadpisaniem przy restarcie kontenera.

---
#### Problem solved - Jakie problemy zostały rozwiązane?
- **SERVFAIL przy AD forwarding** (krok 4.3) — BIND z domyślnym `dnssec-validation auto` odrzucał niepodpisane odpowiedzi AD DNS ("broken trust chain"). Rozwiązanie: `dnssec-validation no;` w `named.conf`
- **SELinux niedostępny w LXC** (krok 5.1) — kernel Proxmox VE nie wspiera SELinux enforcement w kontenerach LXC. Świadoma decyzja o pominięciu; w produkcji wymagana pełna VM
- **firewalld niezainstalowany** (krok 5.2) — `firewall-cmd: command not found` na minimalnej instalacji Rocky. Rozwiązanie: `dnf install firewalld`
- **NXDOMAIN dla `linux.lab.local` z Windows** (krok 6.1) — win-dc01 nie wiedział o podstrefie. Rozwiązanie: delegacja NS (`Add-DnsServerZoneDelegation`)
- **Brak `bind-utils` na Rocky LXC** (krok 6.3) — `dig: command not found` na ipa-srv01 i repo-srv01. Rozwiązanie: `dnf install bind-utils`
- **Resolver na Ubuntu LXC (Proxmox)** (krok 6.3) — systemd-resolved nie zarządzał `/etc/resolv.conf` (mode: foreign, markery PVE). Rozwiązanie: bezpośrednia edycja pliku
- **Reverse lookup z Windows** (krok 7.4) — PTR nie działał, bo win-dc01 nie miał konfiguracji dla reverse zone. Rozwiązanie: conditional forwarder dla `10.10.10.in-addr.arpa` → BIND
