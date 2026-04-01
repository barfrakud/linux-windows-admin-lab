---
description: Pisanie i aktualizacja notatek laboratoryjnych zgodnie z wytycznymi użytkownika
---

## Zasady stylu notatek

Przed zapisaniem lub aktualizacją notatek w plikach `notes/lab-XX-*.md` przestrzegaj poniższych reguł:

1. Pisz w pierwszej osobie liczby pojedynczej (np. "zainstalowałem", "skonfigurowałem", "zrobiłem"), jeśli notatka jest po polsku to przetłumacz na język angielski używająć prostego języka.

2. Używaj prostego tekstu. Unikaj zbędnego formatowania markdown:
   - bez pogrubień (**tekst**)
   - bez list z myślnikami tam, gdzie wystarczy zdanie
   - bez tabel — zamiast nich blok kodu z wyrównanymi kolumnami
   - nagłówki (##, ###) tylko do sekcji kroków

3. Dane techniczne (parametry, IP, komendy, konfiguracja) umieszczaj w bloku kodu (``` ... ```).
   Dla konfiguracji VM w Proxmox używaj wcięć hierarchicznych — kolejne parametry tej samej sekcji wyrównuj do `>`:
   ```
   General > Name: win-dc01
           > VM ID: 101
   OS > ISO image: Windows Server 2022 ISO
      > Type: Microsoft Windows
      > Version: 11/2022/2025
   System > Machine: q35
          > BIOS: OVMF (UEFI)
   Network > Bridge: vmbr10
           > Model: VirtIO (paravirtualized)
   ```

4. Numeracja kroków musi być zgodna z planem w `lab-plan.md`:
   - kroki główne: "Krok 1", "Krok 2", itd.
   - podkroki: "3.1", "3.2", "3.3", itd.
   - nazwy sekcji muszą dokładnie odpowiadać nazwom z planu

5. Problemy i ich rozwiązania zapisuj bezpośrednio w sekcji której dotyczą, w formacie:
   ```
   Problem — [krótki opis]:
   [co zaobserwowałem]
   Rozwiązanie: [co zrobiłem]
   ```

6. Każdy krok (sub-step) kończy się sekcją `### Conclusion` w następującym formacie:
   ```
   ### Conclusion

   #### What - Co zrobiłem?
   [Krótko, konkretnie — co zostało wykonane w tym kroku: jakie pliki, komendy, konfiguracje]

   ---
   #### Why - Dlaczego to zrobiłem?
   [Kontekst i uzasadnienie — dlaczego ten krok jest potrzebny w ramach laba, jaki problem rozwiązuje]

   ---
   #### Result - Co dzięki temu uzyskałem?
   [Stan po wykonaniu kroku — co działa, co jeszcze nie, co wymaga kolejnych kroków]

   ---
   #### Lesson Learned - Co się nauczyłem?
   [Kluczowe wnioski techniczne — czego się nauczyłem wykonując ten krok. Może być lista punktów jeśli jest kilka wniosków]

   ---
   #### Problem solved - Jakie problemy zostały rozwiązane?
   [Opis napotkanego problemu i jego rozwiązania, lub informacja że problemów nie było]
   ```
   Zasady:
   - Treść Conclusion pisz po polsku
   - Charakter edukacyjny — notatka ma utrwalać wiedzę, nie tylko dokumentować czynności
   - Lesson Learned powinien zawierać techniczne wyjaśnienia (dlaczego coś działa tak a nie inaczej)
   - Result powinien jasno wskazywać czy krok jest samodzielny czy wymaga kolejnych kroków do aktywacji
   - Jeśli w kroku nie było problemów, napisz to wprost w Problem solved

7. Po zakończeniu **wszystkich kroków** ćwiczenia, na samym końcu pliku dodaj sekcję `## LAB-XX — Conclusion` w tym samym formacie co Conclusion per krok, ale na wyższym poziomie:
   - **What** — lista wszystkich wykonanych czynności (zwięźle, bez powtarzania szczegółów z kroków)
   - **Why** — dlaczego to ćwiczenie było potrzebne w kontekście całego labu
   - **Result** — docelowy stan po ćwiczeniu, architektura, gotowość pod kolejne ćwiczenia
   - **Lesson Learned** — skompilowane wnioski ze WSZYSTKICH kroków, pogrupowane tematycznie (np. "Architektura DNS", "Konfiguracja BIND", "Weryfikacja"). Przejrzyj każdy krok i wyciągnij kluczowe lekcje — nie pomijaj żadnej.
   - **Problem solved** — pełna lista WSZYSTKICH problemów napotkanych w trakcie ćwiczenia (z numerem kroku), nie tylko ostatnich. Przejrzyj każdy krok i zbierz wszystkie problemy.

   Zasady:
   - Conclusion per krok = szczegóły techniczne tego kroku
   - Conclusion per LAB = wysokopoziomowe podsumowanie całego ćwiczenia, wnioski pogrupowane tematycznie
   - Przy kompilacji Lesson Learned przejrzyj KAŻDY krok — łatwo pominąć problemy i lekcje z wcześniejszych kroków

8. Ukończone kroki oznaczaj znakiem ✅ w nagłówku sekcji.

9. Przyszłe kroki (jeszcze niewykonane) pozostawiaj z komentarzem:
   <!-- TODO: wypełnić -->

## Jak używać tego workflow

Gdy użytkownik poprosi o zapisanie notatek lub aktualizację postępu:

1. Przeczytaj aktualną zawartość pliku notatek dla danego LAB-u.
2. Zidentyfikuj sekcję do uzupełnienia na podstawie numeru kroku z planu.
3. Przepisz lub uzupełnij treść zgodnie z zasadami stylu powyżej.
4. Oznacz ukończony krok jako ✅.
5. Nie usuwaj sekcji przyszłych kroków — zostaw je z komentarzem TODO.
6. Zachowaj sens logiczny i poprawną pisownię.
7. Gdy napotkasz dane jak hasła to nie usuwaj ich. To jest lab więc hasła są celowo tutaj umieszczone.