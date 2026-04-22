# LAB template

Ten plik jest szablonem i przewodnikiem do tworzenia nowych notatek laboratoryjnych w katalogu `notes/`.

## Po co jest ten plik

Ten szablon ma ustalić stały workflow pracy:

1. najpierw tworzę szkielet notatki na podstawie `lab-plan.md`
2. pod każdym podkrokiem wpisuję konkretne instrukcje i komendy do wykonania
3. użytkownik wykonuje komendy bezpośrednio z pliku notatek
4. w trakcie pracy dopisywane są wyniki, problemy i ważne obserwacje
5. po zakończeniu kroku uzupełniane są `Notes` i `Conclusion`

## Jak rozdzielać sekcje

### Notes

Sekcja `Notes` ma być krótka.

Tu trafiają tylko:
- rzeczy nieoczekiwane
- cechy środowiska, które odbiegają od planu
- ograniczenia konkretnej maszyny lub systemu
- obserwacje operacyjne, które mogą się przydać w kolejnych krokach

Do `Notes` nie wrzucam pełnej narracji o tym, co zrobiłem krok po kroku.

### What - Co zrobiłem?

To jest główne miejsce na opis wykonanej pracy.

Tu trafia:
- co sprawdziłem
- co zmieniłem
- jakie komendy wykonałem
- jakie usługi uruchomiłem
- jakie testy zrobiłem
- jaki był przebieg kroku

Jeżeli trzeba wybrać między `Notes` a `What`, główny opis pracy powinien trafić do `What`.

### Why - Dlaczego to zrobiłem?

Tu zapisuję sens kroku w kontekście całego laba:
- po co ten krok jest potrzebny
- co przygotowuje
- jaki problem architektoniczny lub operacyjny rozwiązuje

### Result - Co dzięki temu uzyskałem?

Tu zapisuję stan końcowy po kroku:
- co już działa
- co zostało potwierdzone
- czy można przejść dalej
- co nadal wymaga kolejnych kroków

### Lesson Learned - Co się nauczyłem?

Tu zapisuję wiedzę uogólnioną:
- jak coś działa
- dlaczego zadziałało tak, a nie inaczej
- jakie są zależności techniczne
- jakie wnioski warto zapamiętać na przyszłość

To nie ma być powtórzenie `What`, tylko wniosek techniczny.

### Problem solved - Jakie problemy zostały rozwiązane?

Tu trafiają konkretne problemy i ich fixy.

Każdy problem zapisuję od razu po rozwiązaniu, nie dopiero na końcu całego kroku.

Format:

```text
Problem — [krótki opis]
[co nie działało / co zaobserwowałem]

Rozwiązanie:
[co zrobiłem]

Efekt:
[po czym poznałem, że problem zniknął]
```

## Workflow pracy podczas realizacji laba

### 1. Przygotowanie kroku

- biorę nazwę kroku z `lab-plan.md`
- tworzę lub aktualizuję plik `notes/lab-XX-*.md`
- wpisuję instrukcje do wykonania pod każdym sub-stepem
- zostawiam przyszłe sekcje `Notes`, `Conclusion` i `Problem solved` do uzupełnienia później

### 2. Wykonywanie komend

- komendy uruchamiam bezpośrednio z pliku notatek
- jeśli wynik jest istotny, dopisuję blok `Result:` pod danym podkrokiem
- jeśli coś nie działa, najpierw diagnozuję problem, a po fixie od razu dopisuję wpis do `Problem solved`

### 3. Zamknięcie kroku

Po ukończeniu całego kroku:
- uzupełniam `Notes`
- uzupełniam `Conclusion`
- oznaczam nagłówek kroku jako `✅`

## Minimalny szkielet nowego pliku labowego

```markdown
# LAB-XX: [nazwa laba]

**Status:** Planned
**Machine:** [hosty]
**Reference:** [lab-plan.md — LAB-XX](../lab-plan.md)

### Lab context

```text
[ważne parametry środowiska]
```

**End state after this lab:**
- [stan 1]
- [stan 2]
- [stan 3]

---

## Step 1 — [nazwa kroku z planu]

### 1.1 — [nazwa podkroku]

[krótka instrukcja]

```bash
[komendy]
```

Result:
```text
[wklej tylko jeśli wynik jest istotny]
```

### 1.2 — [nazwa podkroku]

<!-- TODO: wypełnić -->

---
### Notes

<!-- TODO: wypełnić -->

---
### Conclusion

#### What - Co zrobiłem?
<!-- TODO: wypełnić -->

---
#### Why - Dlaczego to zrobiłem?
<!-- TODO: wypełnić -->

---
#### Result - Co dzięki temu uzyskałem?
<!-- TODO: wypełnić -->

---
#### Lesson Learned - Co się nauczyłem?
<!-- TODO: wypełnić -->

---
#### Problem solved - Jakie problemy zostały rozwiązane?
<!-- TODO: wypełnić -->

---

## LAB-XX — Conclusion

### What - Co zrobiłem?
<!-- TODO: wypełnić -->

---
### Why - Dlaczego to zrobiłem?
<!-- TODO: wypełnić -->

---
### Result - Co dzięki temu uzyskałem?
<!-- TODO: wypełnić -->

---
### Lesson Learned - Co się nauczyłem?
<!-- TODO: wypełnić -->

---
### Problem solved - Jakie problemy zostały rozwiązane?
<!-- TODO: wypełnić -->
```

## Dodatkowa zasada praktyczna

Jeśli instrukcje są już wpisane do notatki, dalsze prowadzenie pracy powinno być zwięzłe:
- krótka ocena wyniku
- informacja, czy krok jest zaliczony
- ewentualna diagnoza problemu
- wskazanie następnego kroku
