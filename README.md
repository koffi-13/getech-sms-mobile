# GeTech-SMS Mobile

Application mobile companion (**iOS + Android**) pour le système de gestion scolaire GeTech-SMS.

> Application **Flutter** offline-first qui se synchronise avec le terminal principal (desktop Python/Flet + API FastAPI) via le module **Connexions** (mDNS, QR code, IP manuelle).

---

## Modules implémentés (V1)

| # | Module | Description |
|---|---|---|
| 1 | **Connexions** ⭐ | Découverte mDNS, appairage QR code / IP manuelle, statut serveur, latence, synchro manuelle, mode hors-ligne forcé |
| 2 | **Auth** | Login JWT (`{username, password, establishment_code}`), restauration de session, déconnexion |
| 3 | **Tableau de bord** | KPIs (effectifs, classes, enseignants, paiements, solde dû), répartition par sexe, taux d'occupation, alertes absentéisme / retards |
| 4 | **Classes** | Liste (niveau, filière, effectif, titulaire, taux d'occupation), détail (élèves, EDT, matières) |
| 5 | **Élèves** | Recherche + filtres, fiche complète (identité, contact, médical, scolarité, parents, tuteur), création/édition, photo |
| 6 | **Emploi du temps** | Grille hebdomadaire (Lundi→Samedi), semaines alternées A/B |
| 7 | **Notes** | Sélection classe→période→matière, saisie (absent, pas de 0.5), classement, bulletin |
| 8 | **Présence** | Sélection classe→date→cours, marquage absences (motif + justifié), cahier de texte, historique |
| 9 | **Paramètres** | Thème clair/sombre, mode hors-ligne, année/période courante, profil, changement de mot de passe |

---

## Stack technique

| Couche | Technologie |
|---|---|
| Framework | Flutter (Dart) ≥ 3.22 |
| State management | Riverpod 2 |
| Base locale | Drift (SQLite) — 19 tables répliquées + tables système |
| HTTP client | Dio (interceptors JWT, erreurs typées) |
| Routing | GoRouter (gardes d'auth/connexion) |
| Stockage sécurisé | flutter_secure_storage (JWT, device token) |
| Background sync | workmanager |
| Découverte serveur | bonsoir (mDNS/Bonjour) |
| QR code | mobile_scanner + qr_flutter |
| Thème | Material 3, émeraude, clair/sombre |

---

## Architecture offline-first

```
UI (Pages) ↔ Controllers (Riverpod) ↔ Repository
                                        ↓
                          ┌─────────────┴─────────────┐
                          │ Local DB (Drift/SQLite)    │
                          │ + Sync Engine (pull/push)  │
                          │ + Outbox (writes offline)  │
                          └─────────────┬─────────────┘
                                        ↓ Dio (JWT Bearer)
                          ┌─────────────────────────────┐
                          │ Terminal Principal (Desktop) │
                          │ FastAPI :8000  MySQL centrale│
                          └─────────────────────────────┘
```

- **Pull** incrémental (`GET /sync/pull?since=<watermark>`) — upsert local, watermark `synced_at`.
- **Push** des writes offline (`POST /sync/push`) — dépile l'outbox.
- **Résolution de conflits** : **server-wins** (V1).
- **Déclencheurs** : automatique (workmanager, ~15 min), manuel (pull-to-refresh / bouton synchro), au démarrage.

---

## Démarrage

### Prérequis
- Flutter SDK ≥ 3.22 (Dart ≥ 3.3)
- Le terminal desktop GeTech-SMS (API FastAPI sur `:8000`) sur le même réseau local
  — dépôt : https://github.com/koffi-13/getech-sms-desktop

### Installation & codegen

```bash
# 1. Dépendances
flutter pub get

# 2. Génération du code Drift (database.g.dart, companions, data classes)
dart run build_runner build --delete-conflicting-outputs

# 3. Lancer (avec un émulateur/appareil connecté)
flutter run
```

> ⚠️ **Étape codegen obligatoire** : `dart run build_runner build` génère `lib/core/database/database.g.dart`
> (classes companion, accesseurs de tables, `_$AppDatabase`). Sans cette étape, le projet ne compile pas.

### Configuration iOS (permissions)

`ios/Runner/Info.plist` — ajouter :
```xml
<key>NSCameraUsageDescription</key>
<string>Scan du QR code d'appairage GeTech-SMS</string>
<key>NSLocalNetworkUsageDescription</key>
<string>Découverte du serveur GeTech-SMS sur le réseau local</string>
<key>NSBonjourServices</key>
<array>
  <string>_getech-sms._tcp</string>
</array>
```

### Configuration Android (permissions)

`android/app/src/main/AndroidManifest.xml` — ajouter :
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
<!-- Android 9+ : traffic HTTP clair pour le serveur local -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
```

Et pour autoriser le HTTP clair vers le serveur local (FastAPI sans TLS en LAN) :
```xml
<application
    android:usesCleartextTraffic="true"
    ...>
```

---

## Flux de première utilisation

1. **Appairage** : au premier lancement, le routeur redirige vers `/pairing`.
   - Découverte mDNS automatique, **OU** saisie IP:port + code établissement + token d'appairage, **OU** scan QR code.
   - Le desktop affiche le QR code `{ip, port, establishment_code, pairing_token}`.
2. **Connexion** : une fois appairé, `/login` (JWT 24h, claim `est` = establishment_id).
3. **Tableau de bord** : synchro initiale au démarrage, puis toutes les ~15 min en arrière-plan.

---

## Structure du projet

```
lib/
├── main.dart                      # Entry point + workmanager
├── app.dart                       # MaterialApp + GoRouter (gardes)
├── app_shell.dart                 # Bottom nav + drawer (RBAC)
├── core/
│   ├── config/                    # app_config, theme, constants (RBAC, enums)
│   ├── network/                   # dio_client, auth_interceptor, api_endpoints, api_exceptions
│   ├── auth/                      # secure_storage, auth_state (AuthNotifier)
│   ├── database/                  # database.dart + tables/ (30 tables Drift)
│   ├── sync/                      # sync_engine, sync_scheduler, outbox, conflict_resolver
│   └── utils/                     # formatters (XOF, dates), permissions (RBAC)
├── features/
│   ├── connections/               # ⭐ Module Connexions (mDNS, QR, appairage, statut)
│   ├── auth/                      # login_page
│   ├── dashboard/                 # dashboard_page + controller
│   ├── students/                  # list, detail, form, controller
│   ├── classrooms/                # list, detail, controller
│   ├── schedule/                  # schedule_page + controller
│   ├── grades/                    # grade_entry, ranking, bulletin, controller
│   ├── attendance/                # attendance_page, history, controller
│   └── settings/                  # settings_page, profile_page, controller
└── shared/
    ├── models/                    # DTOs (auth, student, classroom, grade, attendance, sync)
    └── widgets/                   # EmptyState, KpiCard, StatusBadge, AppSearchBar, ...
```

---

## API REST consommée

Base URL configurable (module Connexions) : `http://<server-ip>:8000/api/v1`

- **Auth** : `/auth/login`, `/auth/me`, `/auth/logout`, `/auth/change-password`, `/auth/update-profile`
- **Élèves** : `/students`, `/students/{id}` (+ créations d'endpoints `/students` POST/PATCH, import/export)
- **Classes** : `/classrooms`, `/classrooms/{id}`
- **Notes** : `/grades/class-subjects`, `/grades/assessments[/{id}/grades]`, `/grades/ranking`, `/grades/bulletin/{id}`
- **Présence** : `/attendance/session[/{id}/absences]`, `/attendance/absences`
- **Synchro** : `/sync/pull?since=`, `/sync/push` (à créer côté serveur)
- **Appareils** : `/devices/pair`, `/devices`, `/devices/{id}`, `/devices/server-info` (à créer côté serveur)
- **Dashboard** : `/dashboard/stats`

> Les endpoints `/sync/*`, `/devices/*`, `/schedule`, `/attendance/*` doivent être **créés** côté desktop (voir PROMPT.md).

---

## Contraintes respectées

- ✅ **Langue** : interface en français
- ✅ **Devise** : XOF (Franc CFA)
- ✅ **Auth** : JWT HS256, 24h, `establishment_code` au login
- ✅ **Multi-tenant** : données scopées par `establishment_id` (claim `est`)
- ✅ **RBAC** : features masquées selon `STUDENT_READ`, `GRADE_EDIT`, etc. (`*` = superuser)
- ✅ **Offline-first** : SQLite (Drift), synchro background (workmanager), outbox
- ✅ **Thème** : clair/sombre (émeraude)
- ✅ **Module Connexions** prioritaire (point d'entrée de l'app)

---

## État du projet & notes

Cette base de code a été générée comme **structure source complète** prête à compiler.
Quelques points d'attention lors de la première compilation :

1. **Codegen Drift** : exécuter `dart run build_runner build` (voir ci-dessus).
2. **Versions de packages** : `bonsoir`, `mobile_scanner` évoluent vite — si l'API diffère
   légèrement de la version pinée dans `pubspec.yaml`, ajuster les appels dans
   `lib/features/connections/` (mDNS) et `qr_scanner_page.dart`.
3. **Endpoints serveur à créer** : `/sync/*`, `/devices/*`, `/schedule`, `/attendance/*`
   côté desktop (PROMPT.md §« Endpoints À CRÉER »).
4. **Tests** : non inclus (génération source seule).

## Dépôt desktop associé

- **Desktop (serveur)** : https://github.com/koffi-13/getech-sms-desktop
- Le desktop héberge la base centrale (MySQL) et l'API FastAPI (`/api/v1`, docs sur `/api/v1/docs`).

## Licence

Propriétaire — © GeTech-SMS
