# Centrify DirectControl vs SSSD/realmd — feature-by-feature comparison

*Deliverable dla LAB-05. Punkt odniesienia: wdrożenie Linux↔AD wykonane w tym labie (realmd + adcli + SSSD na `rhel-web01` i `ubuntu-ws02`, GPO z SSSD `ad_gpo_access_control = enforcing`).*

---

## 1. TL;DR

**Centrify DirectControl** (obecnie Delinea Server Suite / Delinea Authentication Suite) to komercyjny, pełny stack tożsamości AD-dla-Linuksa, historyczny "złoty standard" w dużych korporacjach sprzed ~2015. Oferuje jeden obiekt tożsamości per user w AD (zone-based), rozbudowane GPO-for-UNIX, MFA, PAM-rules, smart-card, auditing, i własny daemon (`adclient`).

**SSSD + realmd + adcli** to natywny, otwarty stack w RHEL/Ubuntu/SUSE, domyślny od 2013 r. Pokrywa ~80% funkcji DirectControl na potrzeby standardowego join + logon + access-control + Kerberos SSO. Skaluje się do tysięcy hostów bez licencji. Braki w zaawansowanej politynie GPO, audycie i MFA uzupełnia się zewnętrznymi narzędziami (FreeIPA, Ansible, osobny SIEM, duo_unix, etc.).

Decyzja "Centrify czy SSSD" w 2026 r. jest niemal zawsze po stronie SSSD — chyba że istnieje historyczny kontrakt Centrify, wymóg certyfikacji (FIPS/Common Criteria w konkretnej konfiguracji), albo wysoce specyficzne potrzeby audytowe.

---

## 2. Join workflow

| Wymiar | Centrify DirectControl | SSSD + realmd + adcli (ten lab) |
|---|---|---|
| Komenda join | `adjoin -w <domain> -c <OU> -u <admin> -z <zone>` | `realm join --verbose <domain> -U <admin>` |
| Pakiet | `CentrifyDC` (RPM/DEB, ~70 MB) | `realmd`, `sssd`, `sssd-ad`, `adcli`, `oddjob-mkhomedir` |
| Obiekt AD | Computer + zone-user/group per host | Computer (`CN=Computers` → później ręczne OU); user/group enumerowane z DC |
| Pre-join requirements | DNS, NTP, reverse PTR | DNS, NTP, reverse PTR (identycznie) |
| Keytab | `/etc/krb5.keytab` + osobny `/var/centrify/kset.<host>` | `/etc/krb5.keytab` (jedno miejsce) |
| Zone model | **Tak** — "zones" segregują mapping UID/GID na poziomie AD | Nie ma — UID deterministyczny z SID (`ldap_id_mapping = True`) |
| Leave | `adleave` | `realm leave` |

**Uwagi z labu:** `realm join` na Ubuntu 22.04 wypisuje cosmetic warning `Setting attribute standard::type not supported`, ale keytab i enrolment są poprawne (patrz Step 5.3). W Centrify `adjoin` ma dużo bardziej rozbudowany preflight (`adcheck`) — odpowiednik to `realm discover` + `dig` + `kinit` z ręki.

---

## 3. Identity mapping (UID/GID dla użytkowników AD)

| Wymiar | Centrify | SSSD |
|---|---|---|
| Źródło UID/GID | Centrify Zones — UID przypisywany **per-zone** przez admina, trzymany w AD (atrybuty Centrify) | Auto-deterministic z SID użytkownika (`ldap_id_mapping = True`) lub z atrybutów AD `uidNumber`/`gidNumber` (RFC 2307bis) |
| Spójność cross-host | Gwarantowana przez zone (ten sam user → ten sam UID w całej zonie) | Gwarantowana matematycznie (ten sam SID → ten sam UID na każdym hoście) |
| Kolizje UID | Admin zarządza przestrzenią w zone | Brak ryzyka kolizji między użytkownikami AD (każdy SID unikalny); możliwe kolizje z lokalnymi UID-ami — rozwiązywane przez `ldap_idmap_range` |
| Per-zone overrides | **Tak** — user może mieć inny UID/GECOS w różnych zonach (legacy merge scenarios) | Nie — jeden użytkownik = jeden UID, globalnie |
| Ręczne sterowanie | Tak, zawsze — zone admin decyduje | Opcjonalne (przez atrybuty `uidNumber` w AD, jeśli UNIX Attributes w ADUC są wypełniane) |

**Obserwacja z labu:** `testuser01@lab.local` dostał UID `264601103` na obu hostach bez żadnej konfiguracji UID-ów w AD. To jest fundament cross-host ACL w LAB-07/08.

---

## 4. Access control / logon policy

| Wymiar | Centrify | SSSD (z tego labu) |
|---|---|---|
| Miejsce polityki | AD + Centrify Zones + `centrifydc.conf` (per host) | AD (GPO User Rights Assignment) + `sssd.conf` (per host) |
| Model polityki | Rich rules: per-zone user assignment, role-based (RBAC), per-command sudo rules | GPO SeInteractive/SeRemoteInteractive (logon types); `simple_allow_groups`; `ad_gpo_access_control = enforcing` |
| SSH allow/deny | Zone membership + `adclient` PAM module | GPO → `pam_sss(sshd:account)` → deny w PAM account phase |
| Sudo integration | **Tak** — natywnie, sudo rules w AD zarządzane przez Centrify UI | Przez zewnętrzny `sudo-ldap` lub SSSD sudo provider (`sudo_provider = ad`) |
| MFA / smart-card | Natywnie (DirectAuthenticate, U2F, smart-card, Duo) | Przez `pam_sss` + zewnętrzne moduły (`pam_u2f`, `pam_duo`, PKCS#11) |
| Granularność | Bardzo wysoka — per-zone, per-role, per-command | Średnia — logon/no-logon; do finer-grained trzeba dokładać sudo rules i/lub HBAC z IPA |

**Obserwacja z labu:** GPO `Linux Access Policy` podpięte na `OU=Linux Systems` z User Rights Assignment (Allow/Deny log on locally / Remote Desktop Services) daje pełną funkcjonalność allow/deny dla logonu SSH i konsoli — odpowiednik Centrify zone-based access. Dla sudo-rules trzeba dołożyć osobny kawałek (albo `sudo-ldap`, albo SSSD `sudo_provider`).

---

## 5. GPO / policy enforcement

| Wymiar | Centrify | SSSD |
|---|---|---|
| Natywny silnik GPO | **Tak** — Centrify GPO (rozszerzenie GPMC o sekcje "Computer/User → Centrify Settings" z setkami ustawień: `sudoers`, `/etc/hosts.allow`, firewall, crypto policies, itd.) | Ograniczony — tylko `UserRightsAssignment` (logon types). Brak native mapping dla innych polityk bez własnych rozszerzeń (można to nadrabiać Ansible/Puppet) |
| Refresh interval | `adclient.refresh.interval` — domyślnie 30 min, konfigurowalne | `ad_gpo_cache_timeout` — domyślnie 6 h, konfigurowalne |
| Per-user polityka | Tak — Centrify User Configuration | SSSD ignoruje sekcję User Configuration GPO; tylko Computer-side |
| GPO targeting | Standardowe AD (linki na OU/site/domain + WMI + security filtering) | Standardowe AD + SSSD filtruje wg `ad_gpo_policy_target` (`deny`/`permit`/`access_control`) |
| GUI do polityki | GPMC + rozszerzenia Centrify (instalowane na admin workstation) | GPMC standardowy (bez rozszerzeń) |

**Obserwacja z labu:** SSSD przy `ad_gpo_access_control = enforcing` przetworzył `SeInteractiveLogonRight`, `SeRemoteInteractiveLogonRight`, `SeDenyInteractiveLogonRight`, `SeDenyRemoteInteractiveLogonRight` bezbłędnie na obu dystrybucjach. `/var/lib/sss/gpo_cache/` był pusty, ale decyzje on-the-fly dokładnie zgodne z policy. Aby dodać enforcement dla np. `/etc/sudoers.d/` albo firewall, w SSSD trzeba by użyć Ansible/Puppet poza silnikiem GPO.

---

## 6. Kerberos SSO

| Wymiar | Centrify | SSSD |
|---|---|---|
| krb5.conf | Generowany i zarządzany przez `adclient` | Generowany przez `realmd`; po join wpis `[sssd]` providera |
| Keytab rotation | `adclient` rotuje automatycznie co `adclient.krb5.password.change.interval` (domyślnie 28 dni) | SSSD + `adcli update` (cron lub systemd timer) rotuje co `ad_maximum_machine_account_password_age` (30 dni) |
| SSO na SMB / HTTP | Natywnie, integrated w adclient | Przez `gss-spnego` w Samba/Apache — działa, ale wymaga per-service keytabu (`net ads keytab`) |
| Cross-realm trust | Pełne wsparcie | Pełne wsparcie przez `subdomain_provider` |

---

## 7. Deployment footprint & operations

| Wymiar | Centrify | SSSD |
|---|---|---|
| Instalacja | Zewnętrzne repo Centrify + RPM/DEB ~70 MB + reboot zwykle niepotrzebny | Natywne repozytorium dystrybucji (0 repo trzecich) |
| Daemon | `adclient` (single, privileged) | `sssd` + workers (`sssd_be`, `sssd_nss`, `sssd_pam`, optional `sssd_kcm`, `sssd_pac`) |
| Logi | `/var/log/centrifydc.log` + integracja z syslog | `/var/log/sssd/sssd_<domain>.log` + syslog/journald |
| Health check | `adinfo`, `adcheck` | `sssctl domain-status`, `sssctl config-check` |
| Aktualizacje | Pakiet Centrify — zwykle roczne cykle | Z dystrybucją (RHSA, USN) — miesięczne cykle |
| Wsparcie komercyjne | Tak, płatne — Delinea | Red Hat/Canonical/SUSE w ramach subskrypcji dystrybucji; community upstream |

**Ryzyko Centrify:** stack zależny od jednego vendora, migracja po wyjściu z kontraktu jest kosztowna (ekstrakcja zone data, re-keytab, re-PAM config). Po przejęciu przez Delinea w 2021 r. product-roadmap stał się mniej przewidywalny, co wielu klientów wypchnęło w stronę SSSD/FreeIPA.

---

## 8. Licensing & cost

| Wymiar | Centrify | SSSD |
|---|---|---|
| Model licencyjny | Per-host/per-identity, roczny subscription | Darmowy (w ramach dystrybucji) |
| Typowy TCO (100 hostów, rok) | ~$20–50k licencje + wdrożenie | $0 licencje; czas ops + ewentualny support Red Hat |
| Dodatkowe moduły | MFA, auditing, privileged sessions — osobno płatne | Odpowiedniki (FreeIPA HBAC, auditd + SIEM, ipa-otp) w cenie OS |

---

## 9. Audit & compliance

| Wymiar | Centrify | SSSD |
|---|---|---|
| Session recording | Wbudowane (DirectAudit) — pełne nagrania sesji, wyszukiwanie | Zewnętrzne (tlog, auditd) |
| Compliance reporting | Gotowe reporty PCI/SOX/HIPAA | Trzeba zbudować (auditd + SIEM + custom dashboards) |
| FIPS mode | Certyfikowany | SSSD sam nie jest certyfikowany, ale używa OpenSSL/NSS, które mają FIPS mode w RHEL |

---

## 10. Migration path

Jeśli organizacja ma Centrify i chce zmigrować na SSSD:

1. Wygenerować listę zone-users + UID-ów z Centrify (`adquery user -A`).
2. Zdecydować o modelu UID w SSSD: (a) przepisać UID-y do atrybutów AD `uidNumber` i użyć `ldap_id_mapping = False`, albo (b) zaakceptować nowe UID-y z SID mapping (wymaga chown całego userspace).
3. Per host: `adleave` z Centrify → `realm join` z SSSD → `authselect select sssd`/`pam-auth-update`.
4. Przepisać polityki GPO: Centrify-specific GPO settings na standardowe UserRightsAssignment + Ansible/Puppet dla reszty.
5. Sudo rules: eksport z Centrify → `sudoers.d/` zarządzany konfiguracją lub `sudo_provider = ad` w SSSD.

W praktyce: duża operacja, ale wykonalna przez rolling upgrade (zone po zonie, host po hoście), bez downtime dla samego AD.

---

## 11. Kiedy wybrać co — rekomendacje

**Wybierz SSSD (default w 2026):**
- Standardowy workload: login SSH/console, Kerberos SSO, GPO allow/deny logon.
- Nowe wdrożenie bez legacy Centrify.
- Chcesz mieć stack zgodny z upstream dystrybucji (brak vendor lock-in).
- Budżet licencyjny = 0.
- Mała/średnia skala (do kilkuset hostów), prostą polityką, uzupełnioną Ansible dla reszty.

**Rozważ Centrify (edge cases):**
- Istniejące wdrożenie Centrify + zone-based UID + trudna migracja danych.
- Wymaganie session recording z pełnym audytem (zamiast `tlog` + SIEM).
- Zaawansowane GPO dla UNIX (natywny kontroler `sudoers`, `/etc/hosts.allow`, per-file policies) bez chęci utrzymywania Ansible/Puppet.
- Silne wymagania compliance gdzie konkretna certyfikacja Centrify jest warunkiem audytu.

**Na pewno wybierz SSSD:**
- Darmowe labo / edukacja (ten lab).
- Każde środowisko cloud-native (chmura publiczna) — Centrify agents są drogie per-instance.
- Kontenery (SSSD działa jako sidecar/shared socket; Centrify kontenerowo działa kiepsko).

---

## 12. Interview-ready talking points

- *Czym różni się `realm join` od `adjoin`?* — Ten sam cel (computer account + keytab), ale realm join jest natywny w dystrybucji i nie ma pojęcia "zone"; adjoin wpisuje hosta do konkretnej zony Centrify, co wpływa na UID/GID mapping dla userów.
- *Jak SSSD decyduje o UID dla usera AD?* — Domyślnie z SID (`ldap_id_mapping = True`): pierwsze N bitów RID mapowane do zakresu `ldap_idmap_range_min..max` (w RHEL 9: `200000..2000200000`). Deterministyczne, cross-host.
- *Jak egzekwujesz "allow only these AD groups to SSH into Linux"?* — W SSSD przez `realm permit -g linuxadmins linuxusers` (ustawia `simple_allow_groups`) albo przez GPO z `ad_gpo_access_control = enforcing` (User Rights Assignment na OU). Obie drogi są mutually exclusive; GPO ma pierwszeństwo.
- *Dlaczego service02 nie mógł się zalogować, mimo że hasło miał dobre?* — PAM ma dwa osobne etapy: `auth` (hasło poprawne → `pam_sss(sshd:auth): authentication success`) i `account` (polityka → `pam_sss(sshd:account): Access denied`). GPO deny SSH działa w `account`.
- *Jak Centrify rozwiązuje to samo?* — `adclient` w module PAM robi zone-check + role-check przy auth/account. Efekt końcowy identyczny, tylko źródłem decyzji jest Centrify-specific atrybut w AD, nie standardowy User Rights Assignment.
- *Co byś przeniósł z Centrify na SSSD, gdyby ktoś Cię o to poprosił?* — Patrz sekcja 10. Najtrudniejsze: zone-based UID-y (trzeba zdecydować o `ldap_id_mapping` vs RFC 2307bis), sudo rules (eksport → `sudo_provider`), zaawansowane Centrify GPO settings (przejście na Ansible).
