# Sideloaded Apps Ranking — Kompletne scenariusze testowe

## Role testowe
| Rola | Opis |
|------|------|
| **Author** | Zalogowany user, tworca review |
| **User** | Zalogowany user, NIE tworca review |
| **Staff** | Admin lub moderator |
| **Anon** | Niezalogowany uzytkownik |

## Wymagania wstepne
- Kategoria o slug `sideloaded-apps-ranking` istnieje
- Site setting `sideloaded_apps_ranking_enabled` = true
- Site setting `sideloaded_apps_verification_enabled` = true
- Conajmniej 1 review juz istnieje (do testow odczytu)

---

## 1. SITE SETTINGS I WLACZANIE PLUGINU

### 1.1 Master toggle
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Admin > Settings > `sideloaded_apps_ranking_enabled` = false | Plugin wylaczony |
| 2 | Wejdz na homepage | Brak zakladki "Sideloaded Apps" w nawigacji |
| 3 | Brak bannera na homepage | - |
| 4 | Wejdz bezposrednio na `/c/sideloaded-apps-ranking` | Normalna kategoria Discourse bez customowych elementow |
| 5 | Wlacz z powrotem `sideloaded_apps_ranking_enabled` = true | Wszystkie elementy pluginu widoczne |

### 1.2 Category slug
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Zmien `sideloaded_apps_category_slug` na inny slug | Plugin szuka kategorii pod nowym slugiem |
| 2 | Wrocz do domyslnego `sideloaded-apps-ranking` | Wszystko wraca do normy |

### 1.3 Verification settings
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | `sideloaded_apps_verification_enabled` = false | Scheduled job nie odpala weryfikacji |
| 2 | `sideloaded_apps_verification_interval_minutes` = 1 | Weryfikacja co 1 minute (job co 5 min sprawdza stale > 1 min) |
| 3 | `sideloaded_apps_max_apk_file_size_mb` = 10 | Pliki > 10MB nie beda checksumowane |

---

## 2. NAWIGACJA

### 2.1 Zakladka "Sideloaded Apps" w nawigacji
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Wejdz na homepage | Zakladka "Sideloaded Apps" widoczna w nawigacji |
| 2 | Kliknij zakladke | Przekierowanie do `/c/sideloaded-apps-ranking` |
| 3 | Bedac w kategorii | Zakladka jest aktywna (podswietlona) |
| 4 | Wejdz w inna kategorie | Zakladka NIE jest aktywna |
| 5 | Bedac wewnatrz kategorii (np. w subslugo) | Zakladka widoczna w nawigacji glownej, nie wewnatrz kategorii |

### 2.2 Banner na homepage
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Wejdz na homepage (Latest) | Banner "Sideloaded Apps Ranking" widoczny |
| 2 | Banner zawiera tytul, opis i CTA | Tytul: "Sideloaded Apps Ranking", tekst: "Discover community-rated apps...", CTA: "Browse Sideloaded Apps" |
| 3 | Kliknij CTA | Przekierowanie do `/c/sideloaded-apps-ranking` |
| 4 | Na stronie kategorii sideloaded apps | Banner **NIE jest widoczny** |
| 5 | Na innej kategorii (np. General) | Banner **jest widoczny** |

### 2.3 Ukryte elementy UI na stronie kategorii
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Wejdz na strone kategorii | `body` ma klase `sideloaded-apps-category` |
| 2 | | Navigation bar (Latest/Top/New) `#navigation-bar.nav.nav-pills` — **UKRYTY** |
| 3 | | `.filter-category-boxes` — **UKRYTE** |
| 4 | | Przyciski `.navigation-controls` (New Review, itp.) — wyrownane do **prawej** strony |
| 5 | Opusc kategorie (wejdz na inna strone) | Klasa `sideloaded-apps-category` **usunieta** z body |

---

## 3. FILTRY KATEGORII (PILLS)

### 3.1 Wyswietlanie
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Wejdz na strone kategorii | Widoczny naglowek "Sideloaded Apps Categories" |
| 2 | | Widoczne pills: **All**, Communication, Productivity, Utilities, Health, Finance, **Logic Games**, Music, Navigation, Weather, News, Education, Other |
| 3 | | Pill "Social" — **NIE ISTNIEJE** |
| 4 | | "All" jest domyslnie aktywny (podswietlony) |

### 3.2 Filtrowanie tematow
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Kliknij pill "Communication" | Pill "Communication" podswietlony, "All" nie |
| 2 | | Body dostaje klase `apk-filter--communication` |
| 3 | | Tematy bez kategorii "communication" — ukryte (CSS) |
| 4 | Kliknij pill "Communication" ponownie | Filtr wylaczony — wszystkie tematy widoczne |
| 5 | Kliknij "All" | Filtr wyczyszczony — wszystkie tematy widoczne |
| 6 | Kliknij "Logic Games" | Filtruje do kategorii `entertainment` |
| 7 | Kliknij inny pill (np. "Music") | Przelacza filtr — teraz tylko Music |

---

## 4. LISTA TEMATOW (TOPIC LIST)

### 4.1 Kolumna Community Rating
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Wejdz na strone kategorii | Widoczna kolumna "Community Rating" |
| 2 | Temat z ocenami | Wyswietla: `★ X.X (N)` — srednia i liczba ocen |
| 3 | Temat bez ocen | Wyswietla: `—` (myslnik) |
| 4 | Kolumna widoczna TYLKO na stronie kategorii sideloaded apps | Na homepage i innych kategoriach — brak tej kolumny |

### 4.2 Sortowanie po ratingu
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Domyslnie (bez klikania) | Lista posortowana po community rating **malejaco** (najlepsze na gorze) |
| 2 | | Pinned topics **zawsze na gorze** (przed sortowaniem po ratingu) |
| 3 | Kliknij naglowek "Community Rating" | Zmiana na sortowanie **rosnaco** |
| 4 | Kliknij ponownie | Powrot do sortowania **malejacego** |

### 4.3 Badges w liscie tematow
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Temat z review | Przed linkiem: badge kategorii apki (np. "Communication") |
| 2 | Temat z `author_is_developer = true` | Badge "DEV" widoczny |
| 3 | Temat z ikona apki | Miniatura ikony widoczna — klikniecie przenosi do tematu |
| 4 | Temat bez ikony | Brak miniatur — tylko badge kategorii |

### 4.4 Wykluczenie z homepage
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Wejdz na homepage (Latest) | Tematy z kategorii sideloaded apps **NIE widoczne** |
| 2 | Wejdz na `/c/sideloaded-apps-ranking` | Tematy widoczne normalnie |
| 3 | Wejdz na inna kategorie | Tematy sideloaded apps NIE pojawiaja sie tam |

---

## 5. TWORZENIE REVIEW (COMPOSER)

### 5.1 Otwarcie composera
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Na stronie kategorii, kliknij przycisk tworzenia | Przycisk ma label "New Review" (nie "New Topic") |
| 2 | | Otwiera sie composer z formularzem review |
| 3 | | Body dostaje klase `sideloaded-composer-active` |
| 4 | | Standardowe pola Discourse (title, category, textarea) — **UKRYTE** |
| 5 | | Widoczne: formularz z naglowkiem "Submit App Review" |

### 5.2 Pola formularza
| # | Pole | Typ | Wymagane | Walidacja |
|---|------|-----|----------|-----------|
| 1 | Application Name | text | TAK | min 2, max 100 znakow |
| 2 | Application Category | select/dropdown | TAK | Musi byc wybrany |
| 3 | Link to APK | url | TAK | http/https, walidacja real-time |
| 4 | Checksum | text | NIE | Opcjonalne, SHA-256 |
| 5 | APK Version | text | TAK | Niepuste |
| 6 | Your rating for the App | gwiazdki 1-5 | TAK | 1-5 |
| 7 | I am the developer | checkbox | NIE | - |
| 8 | App icon URL | url | NIE | Opcjonalne |
| 9 | App Description & Usability | textarea | TAK | min 20 znakow |
| 10 | Known Issues | textarea | NIE | Opcjonalne |
| 11 | Screenshots on Kompakt | upload/preview | NIE | Tylko obrazy |

### 5.3 Dropdown kategorii w composerze
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Rozwin dropdown "Application Category" | Opcje: Communication, Productivity, Utilities, Health, Finance, **Logic Games**, Music, Navigation, Weather, News, Education, Other |
| 2 | | "Social" — **NIE ISTNIEJE** w dropdown |
| 3 | | Domyslnie: placeholder "Select a category..." |

### 5.4 Walidacja formularza
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Kliknij Submit bez wypelniania | Bledy walidacji przy wszystkich wymaganych polach |
| 2 | | Scroll do pierwszego pola z bledem |
| 3 | Wpisz nazwe < 2 znaki | Blad: "at least 2 characters" |
| 4 | Wpisz nazwe > 100 znakow | Blad: "at most 100 characters" |
| 5 | Wpisz opis < 20 znakow | Blad: "at least 20 characters" |
| 6 | Wpisz URL bez http/https | Blad: "Please enter a valid URL" |
| 7 | Nie wybierz kategorii | Blad: "Please select a category" |
| 8 | Nie wybierz ratingu (0 gwiazdek) | Blad: "Please select a rating (1-5 stars)" |
| 9 | Zostaw wersje pusta | Blad: "Version is required" |

### 5.5 Walidacja linku (real-time)
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Wklej prawidlowy link do pliku APK (.apk) | Status: spinner "Verifying link..." → ✓ "Direct download link verified" (zielony) + rozmiar pliku |
| 2 | Wklej link do strony HTML (np. GitHub release page) | Status: ℹ "This links to a webpage. Checksum verification will be skipped." (info) |
| 3 | Wklej link zwracajacy 404 | Status: ✗ "Server returned HTTP 404" (czerwony) |
| 4 | Wklej link do nieosiagalnego serwera | Status: ✗ "Could not reach server: ..." (czerwony) |
| 5 | Skasuj URL | Status znika |
| 6 | Wklej link z nieprawidlowym schematem (ftp://) | Blad walidacji formularza (nie real-time — bo format nieprawidlowy) |
| 7 | Proba submitu z linkiem w trakcie sprawdzania | Blad: "Link verification is still in progress" |
| 8 | Proba submitu z invalid linkiem | Blad: "The APK link could not be verified" |

### 5.6 Checksum przy tworzeniu
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Direct download link + pusty checksum | Checksum obliczany automatycznie server-side przy submit |
| 2 | Direct download link + prawidlowy checksum | Submit OK — checksum match |
| 3 | Direct download link + bledny checksum | Dialog: "checksum does not match" — submit zablokowany |
| 4 | Webpage link + jakikolwiek checksum | Checksum ignorowany — submit przechodzi |

### 5.7 Screenshoty w composerze
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Kliknij przycisk "Add Screenshot" (ikona obrazka) | Otwiera sie dialog wyboru plikow |
| 2 | Wybierz obraz (.jpg, .png, .gif, .webp) | Upload przez Uppy → podglad miniaturki w formularzu |
| 3 | Dodaj wiele screenshotow | Wszystkie widoczne jako miniaturki |
| 4 | Kliknij × przy screenshotie | Screenshot usuniety z podgladu |
| 5 | Proba uploadu pliku nie-obrazu | Walidacja Uppy blokuje upload |

### 5.8 Gwiazdki autora
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Kliknij 3. gwiazdke | 3 gwiazdki podswietlone (★★★☆☆) |
| 2 | Kliknij 5. gwiazdke | 5 gwiazdek podswietlonych (★★★★★) |
| 3 | Kliknij 1. gwiazdke | 1 gwiazdka (★☆☆☆☆) |
| 4 | Label | "Your rating for the App" |
| 5 | Help text | "Rate this app 1-5 stars based on usability on Kompakt" |

### 5.9 Checkbox developera
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Zaznacz "I am the developer of this app" | Checkbox zaznaczony |
| 2 | Submit review | W kontenerze review widoczny badge "DEV" |
| 3 | W liscie tematow | Badge "DEV" przy temacie |

### 5.10 Ikona apki
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Podaj URL ikony (prawidlowy link do obrazu) | - |
| 2 | Submit review | Ikona widoczna w kontenerze review i w liscie tematow |
| 3 | Puste pole ikony | Brak ikony — bez bledow |

### 5.11 Auto-generowanie tytulu i tresci
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Wpisz nazwe apki "Signal" | Tytul tematu automatycznie: "Signal review by {username}" |
| 2 | Wpisz wersje i opis | Tresc postu generowana automatycznie z nazwy, wersji, opisu |

### 5.12 Poprawne tworzenie review
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Wypelnij wszystkie wymagane pola prawidlowo | - |
| 2 | Kliknij "Submit Review" | Temat utworzony |
| 3 | | Przekierowanie do nowego tematu |
| 4 | | Kontener review widoczny pod postem |
| 5 | | Dane z formularza poprawnie wyswietlone |
| 6 | | Tag `app-{category}` automatycznie przypisany (np. `app-communication`) |
| 7 | | Weryfikacja linku uruchomiona automatycznie |
| 8 | | `ApkVerification` record utworzony z `last_checked_at` |
| 9 | | `last_access_date` ustawione na czas tworzenia |

### 5.13 Persistence danych formularza
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Wypelnij czesc pol | - |
| 2 | Zamknij composer | - |
| 3 | Otworz composer ponownie (w tej samej kategorii) | Pola wypelnione wczesniejszymi danymi (draft) |

### 5.14 Info Post (Staff)
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Jako **Staff**, otworz composer w kategorii | Widoczny checkbox "Create info post (tutorial, FAQ, etc.)" |
| 2 | Zaznacz checkbox | Formularz review **znika** — widoczny hint "Use the fields below to write your tutorial, FAQ or other info post." |
| 3 | | Standardowy composer Discourse (title, textarea) — **dostepny** |
| 4 | Odznacz checkbox | Formularz review wraca |
| 5 | Jako **User** (nie-staff) | Checkbox "Create info post" — **NIE WIDOCZNY** |

---

## 6. WIDOK REVIEW (TOPIC VIEW)

### 6.1 Kontener review — wyglad
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Wejdz w temat z review | Body dostaje klase `sideloaded-apps-topic` |
| 2 | Pod pierwszym postem | Widoczny kontener review |
| 3 | Naglowek kontenera: ikona apki (jesli podana), nazwa apki, badge kategorii | - |
| 4 | Jesli developer | Badge "DEV" obok nazwy |
| 5 | Info grid: APK Version, Author's Rating (gwiazdki), Community Rating, (opcjonalnie) Your rating | - |
| 6 | Sekcja download: przycisk "Download APK", badge weryfikacji | - |
| 7 | Checksum (jesli podany) | Widoczny pod sekcja download |
| 8 | Opis apki | Widoczny |
| 9 | Screenshoty (jesli sa) | Galeria miniatur |
| 10 | Known Issues (jesli podane) | Widoczne |
| 11 | Sekcja "LAST SUCCESSFUL ACCESS" | **NIE ISTNIEJE** (usunieta) |
| 12 | Opusc temat | Klasa `sideloaded-apps-topic` **usunieta** z body |

### 6.2 Author's Rating (statyczny)
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Review z author_rating = 4 | Wyswietla: ★★★★☆ + tekst "4 out of 5" |
| 2 | | Gwiazdki sa **nieinteraktywne** (span, nie button) |

### 6.3 Community Rating
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Temat z ocenami community | Wyswietla: ★ X.X (N ratings) |
| 2 | Temat bez ocen community | Wyswietla: "No ratings yet" |

### 6.4 Download APK
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Kliknij "Download APK" | Przycisk zmienia sie na "Checking..." |
| 2 | | Wysylane jest POST `/sideloaded-apps/track-download` |
| 3 | | Nowe okno/tab z linkiem do APK |
| 4 | | `last_access_date` zaktualizowany na serwerze |
| 5 | Jesli link niedostepny | Nowe okno i tak sie otwiera (tracking moze failowac, link i tak otwierany) |

### 6.5 Badge weryfikacji
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Link dostepny + checksum poprawny | Badge: ✓ "Verified" (success/zielony) |
| 2 | Link dostepny + brak checksum | Badge: ✓ "Accessible" (accessible/zielony) |
| 3 | Checksum mismatch | Badge: ✗ "Changed" (danger/czerwony) |
| 4 | Link niedostepny | Badge: ✗ "File is not accessible" / "Link is not accessible" (danger/czerwony) |
| 5 | Brak weryfikacji | Badge: — "Unverified" (unknown/szary) |
| 6 | Hover/title na badge | Tooltip z opisem dostepnosci i spojnosci |
| 7 | | Tekst "Last checked: DD/MM/YYYY, HH:MM TZ" pod badge |
| 8 | Link type = "webpage" | Uzywa "Link is accessible/unavailable" zamiast "File is..." |
| 9 | Link type = "file" | Uzywa "File is accessible/unavailable" |

### 6.6 Auto-weryfikacja przy wejsciu
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Wejdz w temat, ktory NIE ma jeszcze `apk_verification` | Automatycznie odpala POST `/sideloaded-apps/verify-now` |
| 2 | | Badge aktualizuje sie z wynikiem weryfikacji |
| 3 | Wejdz w temat, ktory JUZ ma weryfikacje | Weryfikacja **NIE jest odpalana** (dane z serializer) |

### 6.7 Checksum display
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Review z checksumem | Widoczny label "SHA-256 Checksum" + hash |
| 2 | Review bez checksum | Sekcja checksum **nie wyswietla sie** |

### 6.8 Screenshoty
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Review ze screenshotami | Galeria miniatur z lazy loading |
| 2 | Kliknij screenshot | Otwiera pelny rozmiar w nowym tabie |
| 3 | Review bez screenshotow | Sekcja screenshotow **nie wyswietla sie** |

### 6.9 Known Issues
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Review z known issues | Sekcja "Known Issues" z trescia |
| 2 | Review bez known issues | Sekcja **nie wyswietla sie** |

---

## 7. EDYCJA REVIEW

### 7.1 Dostep do edycji
| # | Rola | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | **Author** — we wlasnym review | Przycisk "Edit Review" **WIDOCZNY** |
| 2 | **Staff** — w dowolnym review | Przycisk "Edit Review" **WIDOCZNY** |
| 3 | **User** (nie-autor) | Przycisk "Edit Review" — **NIE WIDOCZNY** |
| 4 | **Anon** | Przycisk "Edit Review" — **NIE WIDOCZNY** |

### 7.2 Tryb edycji — wejscie i wyjscie
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Kliknij "Edit Review" | Kontener przechodzi w tryb edycji (klasa `--editing`) |
| 2 | | Pola wypelnione aktualnymi danymi review |
| 3 | | Przycisk "Edit Review" znika |
| 4 | | Widoczne: "Save Changes" i "Cancel" |
| 5 | Kliknij "Cancel" | Powrot do widoku — bez zmian w danych |

### 7.3 Edytowalne pola
| # | Pole | Walidacja |
|---|------|-----------|
| 1 | APK Version | Wymagane, niepuste |
| 2 | APK Link | Wymagane, http/https, real-time walidacja |
| 3 | Checksum | Opcjonalne |
| 4 | Author Rating | Gwiazdki 1-5, wymagane |
| 5 | Description | Wymagane, min 20 znakow |
| 6 | Known Issues | Opcjonalne |
| 7 | Screenshots | Upload/usuwanie |

### 7.4 Walidacja w trybie edycji
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Skasuj wersje i kliknij poza pole (blur) | Blad walidacji |
| 2 | Wpisz nieprawidlowy URL | Blad walidacji + real-time walidacja linku |
| 3 | Skasuj opis | Blad walidacji |
| 4 | Ustaw rating na 0 | Blad walidacji |
| 5 | Walidacja odpalana na blur i debounced na input | Automatycznie po 400ms |

### 7.5 Walidacja linku w edycji
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Zmien link na nowy prawidlowy | Status: spinner → ✓ lub ℹ |
| 2 | Zmien link na nieprawidlowy | Status: ✗ z komunikatem bledu |
| 3 | Nie zmieniaj linku (ten sam co oryginalny) | Status walidacji **nie wyswietla sie** (bez zbednego sprawdzania) |
| 4 | Link w trakcie sprawdzania — kliknij Save | Dialog: "Link verification is still in progress" — save zablokowany |

### 7.6 Zmiana linku APK + weryfikacja po edycji
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | W edycji, zmien link APK na nowy prawidlowy (direct download) | Walidacja: ✓ "Direct download link verified" |
| 2 | Kliknij "Save Changes" | Frontend: walidacja linku + obliczanie checksum → PUT request |
| 3 | | Backend: `refresh_verification_after_edit` — HTTP probe + aktualizacja ApkVerification |
| 4 | | **"Last checked" zaktualizowane** na aktualna date/godzine |
| 5 | | Badge weryfikacji odswiezony z nowym statusem |
| 6 | | Review dane zaktualizowane w kontenerze |

### 7.7 Zmiana linku na webpage
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Zmien link z direct download na webpage | Status: ℹ "This links to a webpage" |
| 2 | Save | Checksum NIE jest przeliczany (webpage) |
| 3 | | Weryfikacja: `link_type = "webpage"` |

### 7.8 Edycja screenshotow
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | W trybie edycji | Istniejace screenshoty widoczne jako miniaturki |
| 2 | Kliknij × przy screenshotie | Screenshot usuniety z listy |
| 3 | Kliknij "Add Screenshot" | Upload nowego obrazka |
| 4 | Save | Zaktualizowane screenshoty w review |

### 7.9 Zmiana ratingu autora
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | W trybie edycji, kliknij inna gwiazdke | Rating zmieniony |
| 2 | Save | Nowy rating autora widoczny w kontenerze |

### 7.10 Audit post po edycji
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Zmien wersje z "1.0" na "2.0" i zapisz | Automatycznie dodany post z: |
| 2 | | > **Review updated by @username** |
| 3 | | > - **Version**: `1.0` → `2.0` |
| 4 | Zmien opis | Post z: > - **Description** updated |
| 5 | Zmien kilka pol naraz | Jeden post z wszystkimi zmianami |
| 6 | Kliknij Save bez zmian | **Brak** audit postu (nic sie nie zmienilo) |

### 7.11 Bledy zapisu
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Proba zapisu z walidacjami | Dialog z bledem |
| 2 | Serwer zwraca blad | Dialog z komunikatem bledu serwera |
| 3 | | Przycisk "Save" wraca do stanu normalnego |

---

## 8. SYSTEM OCEN (RATING)

### 8.1 Ocena inline w kontenerze review
| # | Rola | Krok | Oczekiwany rezultat |
|---|------|------|---------------------|
| 1 | **User** | Wejdz w review | Widoczne interaktywne gwiazdki z labelem "Your rating for the App" |
| 2 | **User** | Kliknij 4. gwiazdke | POST `/sideloaded-apps/rate` z rating=4 |
| 3 | | | Rating zapisany w PluginStore (`t{id}_u{id}`) |
| 4 | | | Community average i count zaktualizowane w UI |
| 5 | **User** | Kliknij 2. gwiazdke | **Rating ZMIENIONY** na 2 — PluginStore nadpisany |
| 6 | | | Community average przeliczony (count bez zmian!) |
| 7 | **Author** | Wejdz we wlasne review | Interaktywne gwiazdki "Your rating" — **NIE WIDOCZNE** |
| 8 | **Anon** | Wejdz w review | Gwiazdki do oceniania — **NIE WIDOCZNE** |
| 9 | **User** | Rating w trakcie wysylania | Przycisk zablokowany (debounce) |

### 8.2 Ocena w reply composerze
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Jako **User**, kliknij "Reply" w temacie review | Body dostaje klase `sideloaded-reply-composer` |
| 2 | | Widoczne gwiazdki z labelem "Your rating for the App" |
| 3 | | Help text: "Your star rating is required when commenting" |
| 4 | Wybierz 3 gwiazdki | Gwiazdki podswietlone (★★★☆☆) |
| 5 | | metaData `apk_rating = 3` ustawione na modelu composera |
| 6 | | Help text zmienia sie na: "Click stars to change your rating" |
| 7 | Zmien na 5 gwiazdek | Rating zmieniony na 5 |
| 8 | Wyslij reply | Rating zapisany (PluginStore + PostCustomField) |
| 9 | Zamknij composer | Klasa `sideloaded-reply-composer` **usunieta** z body |

### 8.3 Walidacja ratingu w reply
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | **User** bez wczesniejszego ratingu — reply bez wybrania gwiazdek | Dialog: "Please select a star rating (1-5) for your comment." — blokada |
| 2 | **User** z istniejacym ratingiem — reply bez wybrania gwiazdek | Submit **PRZECHODZI** (uzywa istniejacego ratingu) |
| 3 | **Author** — reply bez ratingu | Submit **PRZECHODZI** (autor nie ocenia) |

### 8.4 Istniejacy rating w reply composerze
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | User z ratingiem 4 — otworz reply composer | Gwiazdki pokazuja 4/5 |
| 2 | | Help text: "Click stars to change your rating" |
| 3 | Zmien na 2 gwiazdki | Rating zmieniony |
| 4 | Zamknij i otworz composer ponownie | Gwiazdki pokazuja zaktualizowany rating (z cache) |

### 8.5 Reply autora
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Jako **Author**, kliknij "Reply" w swoim temacie | Gwiazdki do oceniania — **NIE WIDOCZNE** (autor juz ocenil przy tworzeniu) |
| 2 | Wyslij reply | - |

### 8.6 Auto-prefix w reply (User)
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | User z ratingiem 4 pisze reply | Post zawiera prefix: |
| 2 | | `> Review for version X.X.X` |
| 3 | | `> User rating: ★★★★☆` |
| 4 | | (pusta linia) |
| 5 | | (tresc odpowiedzi) |

### 8.7 Auto-prefix w reply (Author)
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Autor pisze reply w swoim temacie | Post zawiera prefix: |
| 2 | | `> Review for version X.X.X` |
| 3 | | `> Author's rating: ★★★★☆ · Author of this review` |
| 4 | | (pusta linia) |
| 5 | | (tresc odpowiedzi) |

### 8.8 Auto-prefix — edge cases
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | User bez zadnego ratingu pisze reply (jesli wymuszone) | Prefix z wersja, ale **BEZ** linii ratingu |
| 2 | Audit post (z edycji review — "Review updated by") | **BEZ** prefixu (pomijany) |
| 3 | Prefix juz istnieje w tresci | **NIE** dodawany ponownie |

### 8.9 Deduplikacja ocen (KRYTYCZNE)
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | User A wystawia ocene inline 4★ | Community: avg=4.0, count=1 |
| 2 | User A pisze reply z ocena 3★ | Community: avg=3.0, count=**1** (nie 2!) |
| 3 | User A zmienia ocene inline na 5★ | Community: avg=5.0, count=**1** |
| 4 | User B wystawia ocene 2★ | Community: avg=3.5, count=**2** |
| 5 | Odswiezenie strony (F5) | Community rating **taki sam** (dane z serwera) |
| 6 | PluginStore jest source of truth | Jesli user ma wpis w PostCustomField I PluginStore, liczy sie PluginStore |

---

## 9. REPORT OUTDATED

### 9.1 Dostep
| # | Rola | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | **User** (nie-autor) | Przycisk "Report outdated version" **WIDOCZNY** |
| 2 | **Author** (wlasne review) | Przycisk — **NIE WIDOCZNY** |
| 3 | **Anon** | Przycisk — **NIE WIDOCZNY** |
| 4 | **Staff** (nie-autor) | Przycisk **WIDOCZNY** |

### 9.2 Modal raportu
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Kliknij "Report outdated version" | Otwiera sie modal z: |
| 2 | | Tekst wstepny: "Please describe why you believe this app version is outdated..." |
| 3 | | Textarea z placeholderem: "e.g. The Play Store shows version 6.50..." |
| 4 | | Info: "Minimum 20 characters required" |
| 5 | | Przycisk "Send report" (disabled) + "Cancel" |

### 9.3 Walidacja raportu
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Wpisz < 20 znakow | Przycisk "Send report" — **disabled** |
| 2 | Wpisz >= 20 znakow | Przycisk "Send report" — **enabled** |
| 3 | Kliknij Submit z < 20 znakow (force) | Blad walidacji inline |

### 9.4 Wysylanie raportu
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Wpisz prawidlowa wiadomosc i kliknij "Send report" | POST `/sideloaded-apps/report-outdated` |
| 2 | | Modal zamkniety |
| 3 | | Dialog: "Report sent to review author and moderators." |
| 4 | | PM (Private Message) utworzony: |
| 5 | | — Odbiorcy: autor review + moderatorzy |
| 6 | | — Tytul: "Outdated version report: {app_name}" |
| 7 | | — Tresc: info o reporterze, nazwie apki, wersji, linku do tematu + cytat z wiadomosci |
| 8 | | Przycisk "Report outdated version" **znika** (po jednym udanym raporcie) |

### 9.5 Edge cases raportu
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Raport na wlasne review (API) | Blad 422: "You cannot report your own review" |
| 2 | Brak moderatorow i autor = reporter | Blad 422: "No recipients" |

---

## 10. REVIEW QUEUE (MODERACJA)

### 10.1 Temat wymagajacy moderacji
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Ustaw kategorie na "require topic approval" | - |
| 2 | Jako nowy user, utworz review | Review trafia do kolejki moderacyjnej |
| 3 | | ApkReview **NIE jest jeszcze** tworzony |

### 10.2 Podglad w kolejce
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Jako **Staff**, wejdz w review queue | Podglad review widoczny (outlet `after-reviewable-queued-post-body`) |
| 2 | Podglad zawiera: | Naglowek "Sideloaded Apps Ranking" |
| 3 | | Nazwa apki + ikona (jesli podana) + badge DEV (jesli developer) |
| 4 | | Kategoria, wersja, link APK (klikalny) |
| 5 | | Gwiazdki autora |
| 6 | | Checksum (jesli podany) |
| 7 | | Opis apki |
| 8 | | Known issues (jesli podane) |
| 9 | | Screenshoty (jesli sa) |

### 10.3 Akceptacja z kolejki
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Zaakceptuj review z kolejki | Hook `on(:approved_post)` tworzy `ApkReview` |
| 2 | | Custom fields zapisane do tematu |
| 3 | | Tag `app-{category}` przypisany |
| 4 | | Weryfikacja linku uruchomiona |
| 5 | | ApkVerification record utworzony |

### 10.4 Duplikacja — admin bypass
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Admin tworzy review (bypass kolejki) | Hook `:topic_created` tworzy review |
| 2 | Temat przechodzi tez przez `:approved_post` | **NIE** tworzy duplikatu (sprawdza `ApkReview.exists?`) |

---

## 11. AUTO-TAGGING

### 11.1 Tagi przy tworzeniu review
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Utworz review z kategoria "communication" | Tag `app-communication` automatycznie przypisany |
| 2 | Utworz review z kategoria "entertainment" | Tag `app-entertainment` przypisany |

### 11.2 Tag Group
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Sprawdz Admin > Tags > Tag Groups | Istnieje grupa "Sideloaded App Category" |
| 2 | | Zawiera tagi: `app-communication`, `app-productivity`, `app-utilities`, `app-health`, `app-finance`, `app-entertainment`, `app-music`, `app-navigation`, `app-weather`, `app-news`, `app-education`, `app-other` |
| 3 | | Grupa powiazana z kategoria sideloaded apps |

### 11.3 Backfill tagow
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Restart serwera z istniejacymi review bez tagow | Tagi automatycznie dodane do istniejacych tematow |

---

## 12. SCHEDULED JOB — WERYFIKACJA LINKOW

### 12.1 Automatyczna weryfikacja
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Job `VerifyApkLinks` uruchamia sie co 5 minut | - |
| 2 | Review z `last_checked_at` starszym niz `verification_interval_minutes` | Weryfikacja uruchomiona |
| 3 | Review z swiezym `last_checked_at` | **Pominiete** |
| 4 | | Sprawdza dostepnosc linku (HEAD, fallback GET) |
| 5 | Link dostepny | `availability_status = "available"`, `last_access_date` zaktualizowana |
| 6 | Link niedostepny | `availability_status = "unavailable"` |
| 7 | Link dostepny + checksum podany | Pobiera plik, oblicza SHA-256, porownuje |
| 8 | Checksum match | `consistency_status = "consistent"` |
| 9 | Checksum mismatch | `consistency_status = "inconsistent"` |
| 10 | Brak checksum | `consistency_status = "unknown"` |
| 11 | Plik za duzy (> `max_apk_file_size_mb`) | `consistency_status = "inconsistent"`, opis "exceeds max size" |
| 12 | `sideloaded_apps_verification_enabled` = false | Job nie robi nic |

---

## 13. API ENDPOINTS

### 13.1 Reviews CRUD
| # | Endpoint | Metoda | Auth | Oczekiwany rezultat |
|---|----------|--------|------|---------------------|
| 1 | `/sideloaded-apps/reviews` | GET | public | Lista review (paginated, 20/page) |
| 2 | `/sideloaded-apps/reviews/:id` | GET | public | Pojedynczy review |
| 3 | `/sideloaded-apps/reviews` | POST | logged in | Tworzenie review (autor/staff) |
| 4 | `/sideloaded-apps/reviews/:id` | PUT | logged in | Edycja review (autor/staff) |

### 13.2 Rating
| # | Endpoint | Metoda | Auth | Oczekiwany rezultat |
|---|----------|--------|------|---------------------|
| 1 | `/sideloaded-apps/rate` | POST | logged in | Ustaw/zmien ocene |
| 2 | | | | Nie mozna ocenic wlasnego review (422) |
| 3 | | | | Rating 1-5 (422 jesli poza zakresem) |

### 13.3 Download i weryfikacja
| # | Endpoint | Metoda | Auth | Oczekiwany rezultat |
|---|----------|--------|------|---------------------|
| 1 | `/sideloaded-apps/track-download` | POST | any? | Track download, zwraca `last_access_date` |
| 2 | `/sideloaded-apps/validate-link` | POST | logged in | Walidacja URL (HTTP probe) |
| 3 | `/sideloaded-apps/compute-checksum` | POST | logged in | Pobranie pliku + SHA-256 |
| 4 | `/sideloaded-apps/verify-now` | POST | logged in | On-demand weryfikacja |
| 5 | `/sideloaded-apps/report-outdated` | POST | logged in | Wyslanie raportu (PM) |

### 13.4 Kontrola dostepu
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | POST create review jako non-author | 403 Forbidden |
| 2 | PUT update review jako non-author (nie-staff) | 403 Forbidden |
| 3 | POST rate wlasne review | 422 "cannot rate your own" |
| 4 | POST report-outdated wlasne review | 422 "cannot report own" |
| 5 | Niezalogowany user — rate/create/update | 403 (before_action ensure_logged_in) |

---

## 14. MODEL I DANE

### 14.1 ApkReview walidacje
| # | Pole | Walidacja |
|---|------|-----------|
| 1 | topic_id | required, unique |
| 2 | user_id | required |
| 3 | app_name | required, max 255 |
| 4 | app_category | required, max 100 |
| 5 | apk_link | required, http/https URL |
| 6 | apk_version | required, max 50 |
| 7 | author_rating | required, 1-5 |
| 8 | app_description | required |

### 14.2 ApkVerification walidacje
| # | Pole | Walidacja |
|---|------|-----------|
| 1 | topic_id | required, unique |
| 2 | availability_status | in: available, unavailable, unknown |
| 3 | consistency_status | in: consistent, inconsistent, unknown |

### 14.3 Duplikat review
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | POST create review dla tematu ktory juz ma review | 422 "A review already exists" |

---

## 15. SERIALIZER I PRELOAD

### 15.1 Topic View serializer
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | GET temat w kategorii sideloaded apps | JSON zawiera: `apk_review`, `apk_user_rating`, `apk_verification`, `apk_author_is_developer`, `apk_icon_url` |
| 2 | GET temat w innej kategorii | Brak tych pol (nil) |

### 15.2 Topic List Item serializer
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Lista tematow w kategorii sideloaded apps | Kazdy topic ma: `apk_app_name`, `apk_app_category`, `apk_community_average`, `apk_community_count`, `apk_last_access_date`, `apk_author_is_developer`, `apk_icon_url` |
| 2 | Lista tematow na homepage | Brak tych pol (tematy sideloaded wykluczone) |

### 15.3 Bulk preload — deduplikacja
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | 3 usery ocenily temat | community_count = 3 |
| 2 | Jeden user ma rating w PostCustomField i PluginStore | Liczy sie **PluginStore** (count = 3, nie 4) |

---

## 16. COPY / LABELLING

### 16.1 Poprawne labele
| # | Lokalizacja | Oczekiwany tekst |
|---|-------------|------------------|
| 1 | Composer — rating autora | "Your rating for the App" |
| 2 | Reply composer — rating usera | "Your rating for the App" |
| 3 | Kontener review — inline rating | "Your rating for the App" |
| 4 | Kategoria "entertainment" | "Logic Games" (nie "Entertainment") |
| 5 | Brak kategorii "Social" | Wszedzie: pills, dropdown composera — brak "Social" |

---

## 17. CSS / BODY CLASSES

### 17.1 Klasy body
| # | Kontekst | Klasa body |
|---|----------|-----------|
| 1 | Na stronie kategorii sideloaded apps | `sideloaded-apps-category` |
| 2 | W temacie review | `sideloaded-apps-topic` |
| 3 | W composerze (nowy temat) | `sideloaded-composer-active` |
| 4 | W reply composerze | `sideloaded-reply-composer` |
| 5 | Filtr aktywny (np. Communication) | `apk-filter--communication` |
| 6 | Opuszczenie strony | Odpowiednie klasy **usuwane** |

### 17.2 Ukrywanie elementow w composerze
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Otworz composer review | `.composer-action-title` — ukryty |
| 2 | | `.title-and-category` — ukryty |
| 3 | | `.d-editor-textarea-wrapper` — ukryty |
| 4 | | `.d-editor-preview-wrapper` — ukryty |
| 5 | | Formularz review scrollowalny w ramach composera |

---

## 18. EDGE CASES I REGRESJE

### 18.1 Wielokrotne review
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | User probujeUtworzuc drugi review dla tego samego tematu | Blad: "A review already exists" |

### 18.2 Usuniety temat
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Usun temat z review | Review record pozostaje w bazie |
| 2 | Weryfikacja pomija usuniete tematy? | Job operuje na ApkReview, nie filtruje po `deleted_at` — potencjalnie weryfikuje |

### 18.3 Puste dane opcjonalne
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Review bez screenshotow | Sekcja screenshotow nie wyswietla sie |
| 2 | Review bez known issues | Sekcja known issues nie wyswietla sie |
| 3 | Review bez checksum | Sekcja checksum nie wyswietla sie, badge "Accessible" (nie "Verified") |
| 4 | Review bez ikony | Brak miniaturki ikony — bez bledow |

### 18.4 Refresh i nawigacja
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Po wystawieniu oceny — F5 | Ocena zachowana, community rating poprawny |
| 2 | Wrocz do listy i wejdz ponownie | Rating widoczny — brak duplikatow |
| 3 | Zmiana URL reczna (wpisanie w pasku) | Body classes prawidlowo ustawione |

### 18.5 Link probe fallback
| # | Krok | Oczekiwany rezultat |
|---|------|---------------------|
| 1 | Serwer zwraca 403 na HEAD request | Automatyczny fallback na GET z Range header |
| 2 | Serwer zwraca 405 na HEAD | Fallback na GET |
| 3 | Serwer zwraca 501 na HEAD | Fallback na GET |

---

## SMOKE TEST CHECKLIST (szybkie przeklikanie)

### Nawigacja i strona
- [ ] Zakladka "Sideloaded Apps" → przekierowanie do kategorii
- [ ] Banner na homepage, brak na kategorii
- [ ] Nav-bar (Latest/Popular) ukryty na kategorii
- [ ] Przyciski po prawej stronie
- [ ] `.filter-category-boxes` ukryte

### Filtry i lista
- [ ] Brak pill "Social"
- [ ] "Logic Games" zamiast "Entertainment"
- [ ] Filtrowanie po kategoriach dziala
- [ ] Community rating column z danymi
- [ ] Sortowanie po ratingu
- [ ] Tematy sideloaded **NIE** na homepage

### Tworzenie review
- [ ] Przycisk "New Review"
- [ ] Formularz z wszystkimi polami
- [ ] Walidacja — puste pola blokuja submit
- [ ] Walidacja linku real-time
- [ ] Dropdown bez "Social"
- [ ] Gwiazdki interaktywne, label "Your rating for the App"
- [ ] Screenshoty — upload i usuwanie
- [ ] Submit → temat z kontenerem review
- [ ] Tag automatycznie przypisany
- [ ] Weryfikacja uruchomiona po tworzeniu

### Widok review
- [ ] Kontener z danymi review pod postem
- [ ] Author's rating (statyczne gwiazdki)
- [ ] Community rating (srednia + count)
- [ ] Download APK — otwiera link
- [ ] Badge weryfikacji + "Last checked"
- [ ] Brak "Last Successful Access"
- [ ] Screenshoty (jesli sa)
- [ ] Known issues (jesli sa)

### Edycja review
- [ ] Przycisk "Edit Review" (autor/staff)
- [ ] Pola wypelnione danymi
- [ ] Zmiana linku → weryfikacja linku
- [ ] Save → "Last checked" zaktualizowane
- [ ] Audit post z lista zmian
- [ ] Cancel — bez zmian

### Rating
- [ ] Inline rating — ustawienie i **zmiana**
- [ ] Reply rating — ustawienie i **zmiana**
- [ ] Deduplikacja: 1 user = 1 rating
- [ ] Reply prefix — wersja + gwiazdki (user)
- [ ] Author reply — prefix z "Author of this review"
- [ ] "Your rating for the App" — poprawny copy wszedzie

### Report outdated
- [ ] Przycisk widoczny dla non-autorow
- [ ] Modal — walidacja 20 znakow
- [ ] PM do autora + moderatorow

### Staff features
- [ ] Info post checkbox (tylko staff)
- [ ] Review queue — podglad danych review
- [ ] Akceptacja z kolejki → review tworzony
