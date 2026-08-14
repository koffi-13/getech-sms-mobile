# PROMPT — Application Mobile GeTech-SMS (Companion App)

## Contexte du projet

GeTech-SMS est un système de gestion scolaire (School Management System) existant en application **desktop Python (Flet)** avec une **API REST FastAPI** et une base de données **MySQL** (SQLite en dev). Le dépôt Git est : `https://github.com/koffi-13/getech-sms-desktop.git` (branche `feature/web-enrichment`).

L'objectif est de créer une **application mobile companion** (iOS + Android) qui :
1. Réplique les fonctionnalités des modules **Classes, Élèves, Emploi du temps, Notes, Présence, Paramètres** + **Tableau de bord**.
2. Fonctionne de manière **indépendante** (offline-first avec base locale SQLite).
3. Se **synchronise** automatiquement en arrière-plan avec le terminal principal (desktop hébergeant la base centrale) quand le mobile est sur le même réseau, OU manuellement via **pull-to-refresh**.
4. Inclut un nouveau module **« Connexions »** (présent sur desktop, web et mobile) pour gérer les connexions entre terminaux.

---

## Architecture technique recommandée

### Stack mobile
- **Framework** : **Flutter** (Dart) — choix justifié : single codebase iOS/Android, excellent support offline, large écosystème, performances natives.
- **State management** : **Riverpod** (ou Bloc) — pour la séparation des préoccupations et le test.
- **Base de données locale** : **Drift** (ex-Moor) — ORM SQLite type-safe pour Dart, avec reactive streams et migrations.
- **HTTP client** : **Dio** — interceptors pour JWT, retry, timeout, logging.
- **Routing** : **GoRouter** — declarative routing avec guards d'auth.
- **Local storage sécurisé** : **flutter_secure_storage** — pour le token JWT et les credentials.
- **Background sync** : **workmanager** (Android) + **background_fetch** (iOS) — pour la synchro automatique.

### Architecture offline-first
```
┌─────────────────────────────────────────────┐
│              Mobile App (Flutter)            │
│  ┌─────────┐  ┌──────────┐  ┌────────────┐  │
│  │  UI     │←→│ Repository│←→│ Local DB   │  │
│  │ (Pages) │  │ (Logic)   │  │ (Drift/SQL)│  │
│  └─────────┘  └────┬─────┘  └──────┬─────┘  │
│                    │                │        │
│              ┌─────▼─────┐   ┌─────▼─────┐  │
│              │ Sync Engine│   │  Outbox   │  │
│              │ (Pull/Push)│   │ (Queue)   │  │
│              └─────┬─────┘   └─────┬─────┘  │
└────────────────────┼────────────────┼───────┘
                     │                │
              ┌──────▼────────────────▼──────┐
              │     Dio HTTP (JWT Bearer)    │
              └──────────────┬───────────────┘
                             │
              ┌──────────────▼───────────────┐
              │  Terminal Principal (Desktop) │
              │  FastAPI REST API :8000       │
              │  MySQL (base centrale)        │
              └───────────────────────────────┘
```

### Stratégie de synchronisation
- **Pull** : Le mobile télécharge les données modifiées depuis le serveur depuis le dernier `synced_at` (watermark). Endpoint : `GET /api/v1/sync/pull?since=<timestamp>`.
- **Push** : Le mobile envoie les modifications locales (marquées `is_dirty=True`) via `POST /api/v1/sync/push`.
- **Conflict resolution** : **Server-wins** pour la V1 (le serveur a toujours raison en cas de conflit). Le mobile re-pull après un push.
- **Déclencheurs** :
  - Automatique : toutes les 5 minutes en background (via workmanager) quand sur le même réseau que le serveur.
  - Manuel : pull-to-refresh sur n'importe quelle liste.
  - On app launch : synchro immédiate au démarrage.
- **Détection du serveur** : mDNS/Bonjour (le desktop publie `_getech-sms._tcp.local`) + fallback par IP manuelle (module Connexions).

---

## Modules à implémenter (V1)

### 1. Tableau de bord
- KPIs : effectif total élèves, nombre de classes, enseignants, paiements du jour, solde dû.
- Graphiques simples : répartition par sexe, taux d'occupation des classes.
- Alertes : élèves absentéistes, paiements en retard.
- Endpoint : `GET /api/v1/dashboard/stats`.

### 2. Classes
- Liste des classes (avec niveau, filière, effectif, titulaire, taux d'occupation).
- Détail d'une classe : liste des élèves, emploi du temps, matières/coefficients.
- Création/édition de classe (admin only).
- Endpoints : `GET /api/v1/classrooms`, `GET /api/v1/classrooms/{id}`.

### 3. Élèves
- Liste avec recherche (nom, matricule), filtre par classe/sexe/statut.
- Fiche élève complète : identité, lieu de naissance, contact, parents, tuteur, médical, scolarité, photo.
- Inscription/édition d'élève (avec photo via caméra ou galerie).
- Import Excel (téléchargement modèle + upload fichier).
- Export (sélection colonnes + format Excel/CSV).
- Endpoints : `GET /api/v1/students`, `GET /api/v1/students/{id}`.
- **Champs Student** : matricule, nom, prenoms, dob, sexe, birth_place, birth_prefecture, birth_region, birth_country, photo_path, groupe.
- **Satellites** : StudentContact (phone, email, address, city), StudentMedical (blood_type, allergies, doctor), StudentScholastic (previous_school, transport), StudentParent (père/mère), Guardian (tuteur).

### 4. Emploi du temps
- Vue hebdomadaire (grille jour × heure) pour une classe ou un enseignant.
- Support des semaines alternées (A/B) si `SchoolYear.alternating_week_start_date` est défini.
- Détail d'un cours : matière, enseignant, salle, horaire.
- Endpoints à créer : `GET /api/v1/schedule?classroom_id=X&week_type=A`.
- **Modèles** : `WeeklySchedule` (cours récurrent), `TimeSlot` (créneaux), `ScheduleSession`/`ScheduleEntry` (curriculum).

### 5. Notes
- Sélection classe → période → matière.
- Saisie de notes par évaluation (avec support absent = note nulle, notes par incréments de 0.5).
- Consultation du classement (rang, moyenne, progression vs période précédente).
- Consultation du bulletin (PDF ou vue structurée).
- Endpoints : `GET /api/v1/grades/class-subjects`, `GET /api/v1/grades/assessments`, `POST /api/v1/grades/assessments/{id}/grades`, `GET /api/v1/grades/ranking`, `GET /api/v1/grades/bulletin/{student_id}`.
- **Modèles** : `Grade` (value, is_absent, comments), `Assessment` (max_score, type), `Period` (start_date, end_date, weight), `ClassSubject` (coefficient).

### 6. Présence (Attendance)
- Sélection classe → date → cours (CourseSession).
- Marquage des absences (checkbox par élève, avec motif/justification).
- Historique des absences par élève.
- Cahier de texte (LessonRecord : contenu du cours, devoirs).
- Endpoints à créer : `POST /api/v1/attendance/session`, `GET /api/v1/attendance/absences?student_id=X`.
- **Modèles** : `CourseSession` (date, state: PENDING/COMPLETED/CANCELLED), `StudentAbsence` (is_justified, reason), `LessonRecord` (content, homework).
- **Note** : Les présences sont implicites (pas de StudentAbsence = présent).

### 7. Paramètres
- Profil utilisateur (nom, prénoms, email, téléphone, photo, sexe).
- Changement de mot de passe.
- Sélection de l'établissement (si multi-établissement).
- Sélection de l'année scolaire / période courante.
- Préférences : thème (clair/sombre), langue, format de date.
- Endpoints : `GET /api/v1/auth/me`, `PATCH /api/v1/auth/update-profile`, `POST /api/v1/auth/change-password`, `GET /api/v1/settings/periods`, `GET /api/v1/settings/establishment`.

### 8. Connexions (NOUVEAU MODULE — dans tous les modes)
Ce module gère les connexions entre le terminal mobile et le terminal principal (desktop). Il doit exister dans **tous les modes** (desktop, web, mobile).

#### Fonctionnalités du module Connexions
- **Découverte automatique** : mDNS/Bonjour — le desktop publie `_getech-sms._tcp.local` sur le réseau local. Le mobile scanne et affiche les serveurs détectés.
- **Appairage manuel** : saisie de l'IP:port du serveur (ex: `192.168.1.10:8000`).
- **Appairage par QR code** : le desktop affiche un QR code contenant `{ip, port, establishment_code}`. Le mobile scanne avec sa caméra.
- **Statut de connexion** : affiche si le serveur est joignable, la latence, la dernière synchro.
- **Gestion des appareils** (côté serveur/desktop) : liste des terminaux connectés, révocation d'un appareil, limite du nombre d'appareils.
- **Sécurité** : chaque appareil doit être appairé (token d'appairage) avant de pouvoir se synchroniser. Le desktop génère un token d'appairage qui doit être validé par l'admin.
- **Mode hors-ligne** : si le serveur est injoignable, le mobile fonctionne en mode hors-ligne (lecture seule sur les données synchronisées, écriture en file d'attente).

#### Architecture du module Connexions
- **Desktop (serveur)** :
  - Démarre le serveur FastAPI sur `0.0.0.0:8000`.
  - Publie le service mDNS.
  - Page « Connexions » : liste des appareils appairés, génération de QR code, révocation.
  - Endpoint API : `POST /api/v1/devices/pair` (valide le token d'appairage), `GET /api/v1/devices` (liste), `DELETE /api/v1/devices/{id}` (révocation).
- **Mobile (client)** :
  - Scan mDNS ou saisie manuelle ou scan QR code.
  - Stocke la configuration de connexion (`server_url`, `establishment_code`, `device_token`).
  - Page « Connexions » : statut, serveur actuel, changement de serveur, synchro manuelle.

---

## API REST existante (à consommer)

### Base URL
`http://<server-ip>:8000/api/v1` (configurable dans le module Connexions).

### Authentification
- **Login** : `POST /api/v1/auth/login` avec `{username, password, establishment_code}`.
- **Réponse** : `{access_token, token_type: "bearer", expires_in: 86400, user, roles, permissions, establishment}`.
- **Token** : JWT HS256, TTL 24h, claims `{sub: user_id, est: establishment_id, iat, exp}`.
- **Usage** : `Authorization: Bearer <token>` sur tous les endpoints protégés.

### Endpoints existants (à consommer directement)

| Méthode | Path | Permission | Description |
|---|---|---|---|
| GET | `/health` | — | Health check |
| POST | `/auth/login` | — | Connexion |
| GET | `/auth/me` | any | Profil courant |
| POST | `/auth/logout` | any | Déconnexion |
| POST | `/auth/change-password` | any | Changer mot de passe |
| PATCH | `/auth/update-profile` | any | Modifier profil |
| GET | `/establishments/current` | any | Établissement courant |
| GET | `/establishments` | any | Liste établissements |
| GET | `/users` | `USER_READ` | Liste utilisateurs |
| POST | `/users` | `USER_MANAGE` | Créer utilisateur |
| GET | `/users/{id}` | `USER_READ` | Détail utilisateur |
| GET | `/students` | `STUDENT_READ` | Liste élèves (search, classroom_id, teacher_only, page, per_page) |
| GET | `/students/{id}` | `STUDENT_READ` | Détail élève |
| GET | `/classrooms` | `CLASSROOM_MANAGE` ou `STUDENT_READ` | Liste classes |
| GET | `/classrooms/{id}` | idem | Détail classe |
| GET | `/subjects` | `SUBJECT_MANAGE` ou `GRADE_READ` | Liste matières |
| GET | `/grades` | `GRADE_READ` | Liste notes |
| GET | `/grades/ranking` | `GRADE_READ` | Classement (classroom_id, period_id, ranking_mode) |
| GET | `/grades/bulletin/{student_id}` | `GRADE_READ` | Bulletin |
| GET | `/grades/class-subjects` | `GRADE_READ` | Matières d'une classe |
| GET | `/grades/assessments` | `GRADE_READ` | Évaluations |
| POST | `/grades/assessments` | `GRADE_EDIT` | Créer évaluation |
| GET | `/grades/assessments/{id}/grades` | `GRADE_READ` | Notes d'une évaluation |
| POST | `/grades/assessments/{id}/grades` | `GRADE_EDIT` | Sauvegarder notes (bulk) |
| DELETE | `/grades/assessments/{id}` | `GRADE_EDIT` | Supprimer évaluation |
| GET | `/finance/payments` | `PAYMENT_READ` | Liste paiements |
| POST | `/finance/payments` | `PAYMENT_VALIDATE` | Enregistrer paiement |
| GET | `/finance/balances` | `PAYMENT_READ` | Soldes élèves |
| GET | `/dashboard/stats` | any | Stats tableau de bord |
| GET | `/settings/periods` | any | Périodes |
| GET | `/settings/establishment` | any | Détail établissement |

### Endpoints À CRÉER (manquants pour le mobile)

| Méthode | Path | Description |
|---|---|---|
| GET | `/sync/pull?since=<timestamp>` | Pull incrémental (toutes tables, `updated_at > since`) |
| POST | `/sync/push` | Push des modifications locales (batch) |
| GET | `/schedule?classroom_id=X&week_type=A` | Emploi du temps d'une classe |
| POST | `/attendance/session` | Créer/démarrer une session de cours |
| POST | `/attendance/session/{id}/absences` | Enregistrer les absences |
| GET | `/attendance/absences?student_id=X` | Historique absences d'un élève |
| POST | `/devices/pair` | Appairer un appareil (token d'appairage) |
| GET | `/devices` | Liste des appareils appairés |
| DELETE | `/devices/{id}` | Révoquer un appareil |
| POST | `/students` | Créer un élève (manquant dans l'API actuelle) |
| PATCH | `/students/{id}` | Modifier un élève (manquant) |
| GET | `/students/export` | Export (colonnes + format) (manquant) |
| POST | `/students/import` | Import Excel (manquant) |

### Codes de permission RBAC
- `STUDENT_READ`, `STUDENT_CREATE` — élèves
- `GRADE_READ`, `GRADE_EDIT` — notes
- `CLASSROOM_MANAGE` — classes
- `SUBJECT_MANAGE` — matières
- `USER_READ`, `USER_MANAGE` — utilisateurs
- `PAYMENT_READ`, `PAYMENT_VALIDATE` — finances
- `*` — superuser (bypass tout)

---

## Schéma de base de données local (SQLite/Drift)

Le mobile doit répliquer localement les tables suivantes (sous-ensemble du schéma central) :

### Tables à répliquer (V1)
1. **establishments** — Établissement (1 seul localement)
2. **school_years** — Années scolaires
3. **periods** — Périodes (trimestres/semestres)
4. **classrooms** — Classes
5. **levels, series, streams** — Référentiels
6. **subjects, class_subjects** — Matières et affectations
7. **students** — Élèves (+ birth_place, birth_prefecture, birth_region, birth_country)
8. **student_contacts** — Contacts (1-1)
9. **student_medicals** — Médical (1-1)
10. **student_scholastics** — Scolarité (1-1)
11. **student_parents** — Parents (père/mère)
12. **guardians, student_guardians** — Tuteurs (N-N)
13. **student_class_assignments** — Assignations classe/année
14. **student_statuses, inscription_types** — Référentiels
15. **assessments, grades** — Évaluations et notes
16. **weekly_schedules, time_slots** — Emploi du temps
17. **course_sessions, student_absences, lesson_records** — Présence/cahier de texte
18. **users** — Utilisateurs (cache local pour noms/roles)
19. **sync_metadata** — Table locale : `{table_name, last_synced_at, is_dirty}`

### Colonnes de synchronisation
Chaque table répliquée doit avoir :
- `synced_at` (DateTime nullable) — dernière synchro réussie
- `is_dirty` (Boolean default False) — modifications locales en attente de push
- `deleted` (Boolean default False) — soft-delete pour synchro

---

## Fichiers du projet existant à fournir

### Fichiers critiques (à lire absolument)

1. **`src/getech_sms/models/`** — Tous les modèles SQLAlchemy (schéma DB complet)
   - `models/__init__.py` — Base + registre
   - `models/base.py`, `models/mixins.py` — Base, IDMixin, TimestampMixin, SoftDeleteMixin, TenantMixin, SyncMixin
   - `models/core/establishment.py` — Établissement
   - `models/core/school_year.py` — Année scolaire
   - `models/academic/classroom.py` — Classe
   - `models/academic/period.py` — Période
   - `models/academic/grade.py` — Note
   - `models/academic/assessment.py` — Évaluation
   - `models/academic/subject.py`, `class_subject.py` — Matières
   - `models/academic/student_class_assignment.py` — Assignation
   - `models/academic/student_status.py`, `inscription_type.py` — Référentiels
   - `models/academic/schedule_session.py`, `schedule_entry.py`, `time_slot.py` — EDT (curriculum)
   - `models/people/student.py` — Élève (avec birth_place)
   - `models/people/student_contact.py`, `student_medical.py`, `student_scholastic.py`, `student_parent.py`, `guardian.py`, `student_guardian.py` — Satellites
   - `models/auth/user.py`, `role.py`, `permission.py`, `user_role.py`, `user_establishment.py` — Auth
   - `models/attendance/weekly_schedule.py`, `course_session.py`, `student_absence.py`, `lesson_record.py`, `teaching_absence.py`, `staff_presence.py` — Présence

2. **`src/getech_sms/api/`** — API REST FastAPI
   - `api/main.py` — Factory FastAPI, CORS, routers
   - `api/deps.py` — Dépendances (get_db, get_current_user, require_permission_api)
   - `api/jwt_utils.py` — Création/vérification JWT
   - `api/schemas.py` — Schémas Pydantic (contrat wire)
   - `api/routers/auth.py` — Auth endpoints
   - `api/routers/students.py` — Élèves
   - `api/routers/classrooms.py` — Classes
   - `api/routers/grades.py` — Notes
   - `api/routers/dashboard.py` — Tableau de bord
   - `api/routers/settings.py` — Paramètres

3. **`src/getech_sms/services/`** — Logique métier (référence pour les règles)
   - `services/auth/auth_service.py` — Authentification
   - `services/auth/session_manager.py` — Sessions JWT
   - `services/academic/grade_service.py` — Calcul des moyennes/classement
   - `services/user/student_service.py` — CRUD élèves
   - `services/academic/student_import_service.py` — Import Excel
   - `services/academic/student_export_service.py` — Export Excel/CSV

4. **Configuration**
   - `pyproject.toml` — Dépendances Python
   - `.env.example` — Variables d'environnement
   - `db/session.py` — Configuration engine DB + ensure_db_schema()
   - `alembic.ini`, `migrations/versions/` — Migrations

5. **UI Desktop (référence pour les fonctionnalités)**
   - `ui/flet/pages/students/students_list_page.py` — Liste élèves
   - `ui/flet/pages/students/student_form_page.py` — Formulaire élève
   - `ui/flet/pages/classrooms/classrooms_list_page.py` — Liste classes
   - `ui/flet/pages/schedule/schedule_page.py` — Emploi du temps
   - `ui/flet/pages/grades/grade_entry_page.py` — Saisie notes
   - `ui/flet/pages/grades/ranking_page.py` — Classement
   - `ui/flet/pages/grades/bulletin_generation_page.py` — Bulletin
   - `ui/flet/pages/dashboard/` — Tableau de bord
   - `ui/flet/pages/settings/settings_page.py` — Paramètres

---

## Structure du projet mobile (à créer)

```
getech_sms_mobile/
├── pubspec.yaml
├── lib/
│   ├── main.dart                      # Entry point
│   ├── app.dart                       # MaterialApp + routing
│   ├── core/
│   │   ├── config/
│   │   │   ├── app_config.dart        # Config (server URL, timeouts)
│   │   │   └── theme.dart             # Thème clair/sombre
│   │   ├── network/
│   │   │   ├── dio_client.dart        # Dio + interceptors (JWT, retry)
│   │   │   ├── api_endpoints.dart     # Constantes des paths API
│   │   │   └── auth_interceptor.dart  # Ajoute Bearer token
│   │   ├── database/
│   │   │   ├── database.dart          # Drift database definition
│   │   │   ├── tables/               # Définitions des tables Drift
│   │   │   │   ├── establishments.dart
│   │   │   │   ├── students.dart
│   │   │   │   ├── classrooms.dart
│   │   │   │   ├── grades.dart
│   │   │   │   ├── attendance.dart
│   │   │   │   └── ...
│   │   │   └── daos/                  # Data Access Objects
│   │   │       ├── student_dao.dart
│   │   │       ├── classroom_dao.dart
│   │   │       └── ...
│   │   ├── sync/
│   │   │   ├── sync_engine.dart       # Moteur de synchro (pull/push)
│   │   │   ├── sync_scheduler.dart    # Scheduler background (workmanager)
│   │   │   ├── conflict_resolver.dart # Résolution conflits (server-wins)
│   │   │   └── outbox.dart            # File d'attente des writes offline
│   │   ├── auth/
│   │   │   ├── auth_service.dart      # Login/logout, gestion JWT
│   │   │   └── secure_storage.dart    # flutter_secure_storage wrapper
│   │   └── utils/
│   │       ├── permissions.dart       # RBAC helper (hasPermission)
│   │       └── formatters.dart        # Dates, nombres, devise (XOF)
│   ├── features/
│   │   ├── auth/
│   │   │   ├── login_page.dart
│   │   │   └── login_controller.dart
│   │   ├── dashboard/
│   │   │   ├── dashboard_page.dart
│   │   │   └── dashboard_controller.dart
│   │   ├── students/
│   │   │   ├── students_list_page.dart
│   │   │   ├── student_detail_page.dart
│   │   │   ├── student_form_page.dart
│   │   │   └── student_controller.dart
│   │   ├── classrooms/
│   │   │   ├── classrooms_list_page.dart
│   │   │   ├── classroom_detail_page.dart
│   │   │   └── classroom_controller.dart
│   │   ├── schedule/
│   │   │   ├── schedule_page.dart     # Grille hebdomadaire
│   │   │   └── schedule_controller.dart
│   │   ├── grades/
│   │   │   ├── grade_entry_page.dart  # Saisie notes
│   │   │   ├── ranking_page.dart      # Classement
│   │   │   ├── bulletin_page.dart     # Bulletin
│   │   │   └── grade_controller.dart
│   │   ├── attendance/
│   │   │   ├── attendance_page.dart   # Marquage absences
│   │   │   ├── attendance_history_page.dart
│   │   │   └── attendance_controller.dart
│   │   ├── settings/
│   │   │   ├── settings_page.dart
│   │   │   ├── profile_page.dart
│   │   │   └── settings_controller.dart
│   │   └── connections/              # NOUVEAU MODULE
│   │       ├── connections_page.dart  # Statut, serveur, synchro
│   │       ├── device_pairing_page.dart  # QR code / IP manuelle
│   │       ├── qr_scanner_page.dart
│   │       └── connections_controller.dart
│   └── shared/
│       ├── widgets/                   # Composants réutilisables
│       │   ├── empty_state.dart
│       │   ├── loading_indicator.dart
│       │   ├── error_widget.dart
│       │   ├── search_bar.dart
│       │   └── pull_to_refresh.dart
│       └── models/                    # DTOs / modèles Dart
│           ├── student_dto.dart
│           ├── classroom_dto.dart
│           └── ...
├── assets/
│   ├── icons/
│   └── images/
└── test/
```

---

## Module « Connexions » — Spécifications détaillées

### Rôle
Le module Connexions gère la relation entre le terminal mobile et le terminal principal (desktop qui héberge la base centrale + l'API FastAPI). Il doit exister dans **tous les modes** (desktop, web, mobile) pour assurer la cohérence.

### Côté Desktop (terminal principal — serveur)
Le desktop joue le rôle de **serveur**. Il doit :

1. **Démarrer l'API FastAPI** en arrière-plan (déjà existante via `getech-sms-api`).
   - Bind sur `0.0.0.0:8000` (accessible depuis le réseau local).
   - Le desktop doit afficher son IP locale (ex: `192.168.1.10`) dans le module Connexions.

2. **Publier un service mDNS** (`_getech-sms._tcp.local`) pour la découverte automatique par les mobiles.
   - Utiliser `python-zeroconf` (à ajouter aux dépendances).
   - Publier : IP, port, establishment_code, establishment_name.

3. **Générer un QR code d'appairage** contenant :
   ```json
   {
     "ip": "192.168.1.10",
     "port": 8000,
     "establishment_code": "GETECH-TSEVIE-01",
     "pairing_token": "ABC123XYZ"
   }
   ```
   - Le token d'appairage est généré à la volée (validité 5 minutes).
   - Affiché dans la page Connexions du desktop.

4. **Gérer les appareils appairés** :
   - Table `paired_devices` (à créer) : `{id, device_name, device_type, device_uuid, paired_at, last_seen, is_revoked, user_id}`.
   - Liste des appareils dans la page Connexions avec bouton « Révoquer ».
   - Limite configurable du nombre d'appareils (défaut: 10).

5. **Nouveaux endpoints API** :
   - `POST /api/v1/devices/pair` — Valide le token d'appairage, enregistre l'appareil, retourne un `device_token` persistant.
   - `GET /api/v1/devices` — Liste des appareils appairés (admin only).
   - `DELETE /api/v1/devices/{id}` — Révoquer un appareil.
   - `GET /api/v1/devices/server-info` — Retourne `{establishment_code, establishment_name, server_version, api_url}` pour la découverte.

### Côté Mobile (client)
Le mobile joue le rôle de **client**. Il doit :

1. **Découverte automatique** :
   - Scan mDNS au démarrage de la page Connexions.
   - Affiche la liste des serveurs détectés sur le réseau local.
   - L'utilisateur sélectionne un serveur.

2. **Appairage manuel** :
   - Saisie de l'IP:port + establishment_code.
   - Demande du token d'appairage (saisi manuellement ou via QR code).

3. **Scan QR code** :
   - Bouton « Scanner QR code » → ouvre la caméra.
   - Décode le JSON `{ip, port, establishment_code, pairing_token}`.
   - Appaire automatiquement.

4. **Page Connexions** (après appairage) :
   - Affiche : serveur actuel (nom établissement, IP, statut en ligne/hors-ligne).
   - Latence (ping en ms).
   - Dernière synchro (timestamp + nombre d'éléments synchronisés).
   - Bouton « Synchroniser maintenant » (pull-to-refresh manuel).
   - Bouton « Changer de serveur » (désappairage + retour à la découverte).
   - Bouton « Mode hors-ligne » (force le mode offline).

5. **Stockage sécurisé** :
   - `server_url`, `establishment_code`, `device_token`, `user_jwt` dans `flutter_secure_storage`.

### Côté Web (futur)
Le mode web se connecte directement à l'API FastAPI (pas de base locale). Le module Connexions web affiche juste le statut de la connexion serveur et permet de changer l'URL de l'API.

---

## Options avantageuses pour la gestion des connexions

### Option recommandée : Desktop comme serveur + mDNS + QR code

**Avantages** :
- **Aucune configuration réseau manuelle** : mDNS découvre automatiquement le serveur sur le LAN.
- **Appairage sécurisé par QR code** : l'admin scanne une fois, le mobile est appairé durablement.
- **Aucun service cloud requis** : tout reste sur le réseau local (privacy, pas de frais cloud).
- **Le desktop est déjà le serveur** : l'API FastAPI existe déjà, il suffit de la binder sur `0.0.0.0`.
- **Multi-plateformes** : le desktop peut être Windows/Linux/Mac, le mobile iOS/Android.

**Inconvénients** :
- Le desktop doit être allumé et sur le même réseau pour la synchro.
- Pas d'accès distant (hors LAN) sauf VPN/tunnel.

### Alternative : Serveur central dédié (cloud/on-premise)

Si l'établissement a plusieurs sites ou veut un accès distant :
- Déployer l'API FastAPI + MySQL sur un serveur dédié (VPS, Raspberry Pi, serveur local).
- Le desktop et les mobiles se connectent tous à ce serveur central.
- Le module Connexions gère juste l'URL du serveur central (pas de mDNS).

**Avantages** : Accès distant, multi-sites, desktop n'a pas besoin d'être allumé.
**Inconvénients** : Coût hébergement, complexité déploiement, dépendance réseau.

### Recommandation pour la V1
Implémenter l'**Option 1 (desktop comme serveur + mDNS + QR code)** car :
- C'est le cas d'usage principal (un établissement, un desktop, plusieurs mobiles).
- Aucune infrastructure supplémentaire à déployer.
- L'API FastAPI existe déjà.
- La découverte mDNS rend l'appairage trivial.

Prévoir quand même la possibilité de configurer une URL de serveur manuelle (pour le cas multi-sites ou accès distant via VPN).

---

## Livrables attendus

1. **Projet Flutter** complet et fonctionnel (`getech_sms_mobile/`).
2. **Modifications du projet desktop** existant :
   - Ajouter `python-zeroconf` aux dépendances pour mDNS.
   - Démarrer l'API FastAPI en arrière-plan au lancement du desktop.
   - Ajouter la page « Connexions » au desktop (liste appareils, QR code, révocation).
   - Ajouter les endpoints `/devices/*` et `/sync/*` à l'API.
   - Ajouter la table `paired_devices` (migration Alembic).
3. **Documentation** : README du projet mobile avec instructions de build/deploy.

## Contraintes
- **Language** : Dart (Flutter) pour le mobile, Python pour les modifications desktop.
- **API** : Consommer l'API FastAPI existante (`/api/v1/*`), créer les endpoints manquants.
- **Auth** : JWT existant (HS256, 24h TTL), `establishment_code` au login.
- **Multi-tenant** : Toutes les données sont scopées par `establishment_id` (dans le JWT `est` claim).
- **Permissions** : Cacher/afficher les features selon les codes RBAC (`STUDENT_READ`, `GRADE_EDIT`, etc.).
- **Offline-first** : Base SQLite locale (Drift), synchro background (workmanager), outbox pour les writes offline.
- **Devise** : XOF (Franc CFA) par défaut.
- **Langue** : Français (interface en français).
- **Thème** : Support clair/sombre (le desktop utilise le sombre par défaut).

## Données de référence (à coder en dur ou charger depuis l'API)
- **Sexe** : M, F
- **Statuts élève** : NOUVEAU, REDOUBLANT (codes depuis `/settings` ou en dur)
- **Types inscription** : NOUVEAU, ANCIEN, EXCLU, ABANDON
- **Jours de la semaine** : Lundi(1) à Samedi(6) — pas de dimanche
- ** États session cours** : PENDING, COMPLETED, CANCELLED
- **Format date** : JJ/MM/AAAA
- **Format note** : 0-20, incréments de 0.5

## Worklog
Tenir un worklog détaillé dans `/home/z/my-project/worklog.md` (format : Task ID, Agent, Task, Work Log, Stage Summary) pour tracer l'avancement.
