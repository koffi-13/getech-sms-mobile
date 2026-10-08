# Améliorations GeTech-SMS Mobile — V2

Ce document décrit les 5 améliorations demandées, leur implémentation dans
l'application mobile, et les **patches serveur optionnels** à appliquer côté
desktop pour débloquer les fonctionnalités d'écriture.

---

## Sommaire

1. [Accueil différencié par type d'utilisateur](#1-accueil-différencié-par-type-dutilisateur)
2. [Classes : titulaire, effectif, onglets Élèves et Emploi du temps](#2-classes--titulaire-effectif-onglets-élèves-et-emploi-du-temps)
3. [Élèves : filtres, noms, formulaire, détail, export](#3-élèves--filtres-noms-formulaire-détail-export)
4. [Notes : autorisations, périodes par cycle, vue enseignant, admin non verrouillé](#4-notes--autorisations-périodes-par-cycle-vue-enseignant-admin-non-verrouillé)
5. [Emploi du temps : gestion complète avec RBAC](#5-emploi-du-temps--gestion-complète-avec-rbac)
6. [Patches serveur (dépôt desktop)](#patches-serveur-dépôt-desktop)
7. [Notes de compatibilité](#notes-de-compatibilité)

---

## 1. Accueil différencié par type d'utilisateur

**Problème** : le tableau de bord était identique pour tous — un enseignant
voyait les statistiques financières (paiements, solde dû) et les compteurs
globaux des autres utilisateurs.

**Solution** :

- **Enseignant** (rôle `TEACHER` déclaré, ou détecté via ses relations
  d'enseignement) → un accueil dédié **sans aucune donnée financière ni
  globale** :
  - KPIs : *Mes classes*, *Mes élèves* (effectif cumulé), *Mes matières*,
    *Cours aujourd'hui* ;
  - section *Mes cours aujourd'hui* (horaire, matière, classe, salle) ;
  - section *Mes classes* (effectif, capacité, badge « Titulaire »).
  - Aucun appel à `GET /dashboard/stats` (cet endpoint n'est pas scopé par
    rôle côté serveur et expose `total_balance_due` + les paiements récents).
- **Autres profils** → le tableau de bord existant, avec les tuiles
  financières conditionnées à la permission `PAYMENT_READ` et la tuile
  Utilisateurs à `USER_READ`.

**Fichiers** : `lib/features/dashboard/dashboard_controller.dart`
(`teacherDashboardProvider`), `dashboard_page.dart` (`_TeacherDashboard`,
`_KpiGrid` filtré par permission), `lib/core/auth/teacher_scope.dart`.

**Détection enseignant** (défensive, sans dépendre d'un seul signal) :
rôle `TEACHER` dans `roles[]` du login **OU** `UserDto.role` contenant
teacher/enseignant **OU** relations de données (matières assignées via
`GET /classrooms?teacher_only=true`, cours planifiés via `GET /schedule/my`,
titulariat via `head_teacher_id == user.id`). Les admins
(superuser/`ADMIN`/`HEADMASTER`) ne sont jamais restreints.

---

## 2. Classes : titulaire, effectif, onglets Élèves et Emploi du temps

**Problème** : la liste affichait les classes sans titulaire ni effectif ; le
détail montrait l'effectif mais l'onglet Élèves était vide et l'onglet Emploi
du temps affichait « EDT non implémenté ».

**Causes corrigées** :

| Cause | Correction |
|---|---|
| Le state final de la liste venait du cache Drift qui ne stockait PAS les champs dénormalisés | Migration **schéma v2** : colonnes `head_teacher_name`, `level_name`, `cycle_name`, `cycle_id`, `series_name`, `current_students_count`, `is_active`, `establishment_id` ajoutées à la table `classrooms` et persistées depuis `ClassroomResponse` |
| `teacherName != null` toujours vrai (getter retourne `''`) | Test corrigé en `teacherName.isNotEmpty` |
| Effectif = COUNT local d'assignations jamais écrites | (a) `GET /students` renvoie désormais `classroom_id` côté serveur ([Fix-CLASSROOM-ID]) et le mobile persiste les assignations ; (b) effectif = valeur serveur si > 0, sinon comptage local |
| Assignations dupliquées à chaque synchro | Delete-then-insert des assignations non-dirty par élève |
| Statuts stockés en labels mais relus en codes | Stockage des **codes** (`NOUVEAU`, `REDOUBLANT`, …) via `fromLabel` |
| Onglet EDT = placeholder | Intégration de `ScheduleGridView` (grille Lundi→Samedi, badge A/B) via `classroomScheduleProvider` |
| `getById` : URL relative invalide + `firstWhere` sans orElse | `buildUrl(...)` + `orElse` propre |

**Onglet Élèves du détail** : liste des élèves de la classe (nom « NOM
Prénoms », matricule, statut), navigation vers la fiche élève, tri par nom.

**Fichiers** : `lib/core/database/tables/academic_tables.dart`,
`lib/core/database/database.dart` (migration v1→v2),
`lib/features/classrooms/classroom_controller.dart`,
`classrooms_list_page.dart`, `classroom_detail_page.dart`.

---

## 3. Élèves : filtres, noms, formulaire, détail, export

**Problème** : les filtres et la barre de recherche ne filtraient rien, les
noms s'affichaient « Prénoms Nom », le formulaire était incomplet, le détail
n'affichait pas les données satellites, et l'export renvoyait une erreur 422.

### Filtres et recherche (corrigés)

- **Cause racine** : la page consommait la liste brute
  (`studentControllerProvider`) au lieu de la liste filtrée
  (`studentsListProvider`). La page consomme désormais
  `studentsListProvider(_filter)` → **recherche, classe, sexe, statut
  fonctionnent réellement**.
- Filtre **type d'inscription** ajouté (Nouveau / Ancien / Exclu / Abandon) —
  les filtres sont désormais au complet.
- Recherche insensible à la casse sur nom, prénoms **et** matricule ;
  tri alphabétique par nom.

### Ordre des noms

Tous les affichages passent au format **« NOM Prénoms »** (élèves, parents,
tuteurs, classement, bulletin) — `StudentDto.fullName`,
`RankingRowDto.studentName`, `BulletinDto.studentName`.

### Formulaire d'ajout/édition (complet)

8 sections : **Identité** (nom*, prénoms, matricule — auto-généré si vide à
la création, sexe, date de naissance, groupe), **Lieu de naissance** (lieu,
préfecture, région, pays), **Classe & scolarité** (classe, statut, type
d'inscription, école précédente, transport), **Contact** (téléphone, email,
adresse, ville), **Médical** (groupe sanguin, allergies, médecin), **Père**,
**Mère**, **Tuteur**. Le controller `birthPlace` non branché (bug historique)
est corrigé.

- Création : écriture locale complète (offline-first) + `POST /students`
  avec satellites → repli **outbox** si le serveur ne propose pas encore
  l'endpoint.
- Édition : `PATCH /students/{id}` incluant `classroom_id` (changement de
  classe possible).

### Détail élève (complet)

- Âge affiché (serveur, sinon calculé localement depuis la date de
  naissance).
- Les cartes Contact / Médical / Scolarité / Parents / Tuteurs sont
  alimentées : en ligne via `GET /students/{id}` enrichi (patch serveur), et
  **hors-ligne** via les jointures locales Drift (satellites persistés à
  chaque synchro).

### Export (erreur 422 corrigée)

- **Cause** : le catalogue de colonnes envoyait des clés non supportées par
  le serveur (`guardian`, `parent_pere`, `blood_type`, `phone`, etc.). Le
  serveur ([Fix-EXPORT]) n'accepte que : `matricule, nom, prenoms, sexe, dob,
  classroom, inscription_type, student_status, age` (+ `photo_path` si
  `include_photos`).
- Le catalogue est désormais **aligné sur le contrat réel**, `columns` est
  envoyé en chaîne séparée par virgules (contrat serveur), et un **retry
  automatique sans `columns`** est tenté en cas de 422 (export par défaut).
- Pagination `GET /students` : `per_page=200` toutes pages (la synchro ne
  ramène plus seulement la première page).

**Fichiers** : `lib/features/students/*` (controller, list, form, detail,
import/export controller), `lib/shared/models/student_dto.dart`.

---

## 4. Notes : autorisations, périodes par cycle, vue enseignant, admin non verrouillé

Étude du module desktop (`ui/flet/pages/notes/notes_list_page.py`,
`grade_entry_page.py`, `api/routers/grades.py`, `grade_service.py`) et
réplication dans le mobile :

### Champ « Période » — filtrage par cycle (collège vs lycée)

- Le desktop filtre : `classroom.level.cycle_id` →
  `GradeService.get_periods(session, year, cycle_id)` ([Fix-PERIOD-CYCLE] :
  `cycle_id` exposé dans `PeriodResponse` **et** `ClassroomResponse`).
- Le mobile fait de même : `periodsForClassroomProvider(classroomId)` filtre
  `period.cycle_id == classroom.cycle_id`, avec **fallback** sur toutes les
  périodes si le filtre ne renvoie rien (données legacy / serveur non patché).
- Appliqué partout : **saisie des notes, classement, bulletin**.
- Auto-sélection : 1ère classe → **période active du jour**
  (`start_date <= today <= end_date`, miroir de `get_active_period`) → 1ère
  matière (le flux ne reste plus bloqué sans interaction).

### Autorisations (miroir du desktop)

| Profil | Accès |
|---|---|
| Enseignant | Classes où il enseigne (`GET /classrooms?teacher_only=true`) ∪ classes dont il est titulaire (`head_teacher_id == me`) ; matières déjà scoppées serveur (`/grades/class-subjects` filtre `assigned_teacher_id`) ; notes déjà saisies **verrouillées** (insert-only) |
| Admin / headmaster / superuser | Toutes les classes et matières ; suppression d'évaluations ; **notes existantes modifiables** (voir ci-dessous) |
| GRADE_READ seul | Lecture seule (bandeau + champs désactivés) |

### « Pour les administrateurs, ne verrouillez pas la modification des notes »

- Le badge « Verrouillée » et la désactivation des champs ne s'appliquent
  **plus aux admins** (`is_locked` ignoré pour
  superuser/`ADMIN`/`HEADMASTER`) — ils peuvent corriger une note déjà
  saisie, comme sur le desktop (`GradeService.upsert_grade`).
- Côté serveur, `POST /grades/assessments/{id}/grades` était **insert-only**
  (les existantes étaient skippées pour tout le monde). Le patch serveur
  (`grades-admin-edit`) ajoute l'**upsert pour les admins**. Sans le patch,
  l'UI mobile reste éditable mais affiche un message explicite :
  « N existante(s) non mise(s) à jour — appliquez le patch serveur ».

### Types d'évaluation (robustesse)

`GET /grades/assessment-types` (patch serveur) avec double repli : types
**dérivés des évaluations existantes** de la matière
(`assessment_type_id`/`assessment_type_name` dénormalisés), sinon valeurs par
défaut. Les IDs ne sont plus codés en dur de façon fragile.

**Fichiers** : `lib/features/grades/grade_controller.dart`
(`periodsForClassroomProvider`, `activePeriodOf`, `assessmentTypesProvider`,
`classroomsForGradesProvider` scopé enseignant), `grade_entry_page.dart`,
`ranking_page.dart`, `bulletin_page.dart`, `grade_utils.dart`.

---

## 5. Emploi du temps : gestion complète avec RBAC

Étude du desktop (`ui/flet/pages/schedule/schedule_page.py`,
`api/routers/schedule.py`, `schedule_service.py`) et implémentation :

### Qui voit quoi, qui modifie quoi (règles du desktop)

| Profil | Vue | Édition |
|---|---|---|
| Admin / headmaster / superuser | « **Par classe** » (dropdown) et « **Par enseignant** » (dropdown) | ✅ Ajout / modification / suppression de cours |
| Enseignant | « **Mes cours** » (grille de tous ses cours, `GET /schedule/my`, affichage classe/matière/salle) + « **Mes classes** » (EDT complet des classes où il enseigne **et** de celles dont il est **titulaire**, marquées d'une étoile) | ❌ Lecture seule |
| Autres profils | Vue par classe, lecture seule | ❌ |

### Fonctionnalités

- Grille Lundi→Samedi, cartes triées par heure, badge **A/B**, badge salle,
  colonne du jour surlignée ;
- Filtre **Toutes / A / B** (le serveur ignore le paramètre `week_type` —
  filtrage côté client via `matchesWeek`, qui traite `null` = toutes les
  semaines) ;
- **Auto-détection de la semaine courante** (A/B) depuis
  `school_years.alternating_week_start_date` (miroir de
  `ScheduleService.week_type_for_date`) ;
- Édition admin (nécessite le patch serveur) : formulaire d'ajout (matière
  de la classe via `/grades/class-subjects`, jour, heures début/fin,
  semaine, salle), feuille d'édition/suppression ; les **conflits classe et
  enseignant** sont détectés par le serveur (409 avec message clair) ;
- Onglet **Emploi du temps du détail de classe** (lecture seule) ;
- Le module **Présence** continue de fonctionner (compatibilité
  `weeklyScheduleProvider`).

**Fichiers** : `lib/features/schedule/schedule_controller.dart` (refonte),
`schedule_grid.dart` (grille réutilisable), `schedule_editor.dart` (édition
admin), `schedule_page.dart` (refonte RBAC), `lib/core/auth/teacher_scope.dart`.

---

## Patches serveur (dépôt desktop)

Le fichier **`docs/0001-feat-api-mobile-companion-endpoints-schedule-write-g.patch`**
(contenu du commit `feature/mobile-companion-patches` basé sur
`feature/desktop-control-center`) ajoute côté API desktop :

| Endpoint | Permission | Description |
|---|---|---|
| `GET /schedule/time-slots` | `STUDENT_READ` | Grille des créneaux (pauses incluses) |
| `POST /schedule/entries` | `CLASSROOM_MANAGE` | Créer un cours (résolution `TimeSlot` + `ScheduleSession`, détection de conflits classe & enseignant) |
| `PUT /schedule/entries/{id}` | `CLASSROOM_MANAGE` | Modifier un cours (horaire, semaine, salle) |
| `DELETE /schedule/entries/{id}` | `CLASSROOM_MANAGE` | Supprimer un cours |
| `GET /grades/assessment-types` | `GRADE_READ` | Référentiel des types d'évaluation |
| `POST /grades/assessments/{id}/grades` | `GRADE_EDIT` | **Upsert pour les admins** (les enseignants restent insert-only) |
| `GET /students/{id}` | `STUDENT_READ` | Détail **enrichi des satellites** (contact, médical, scolarité, parents, tuteurs) |
| `POST /students` | `STUDENT_CREATE` | Création complète (satellites + assignation de classe, matricule auto-généré si vide) |
| `PATCH /students/{id}` | `STUDENT_CREATE` | Édition complète (identité, satellites, changement de classe) |
| `GET /schedule` (fix) | — | `week_type` **null préservé** (= toutes les semaines ; avant : null → "A") |

### Application du patch

```bash
cd getech-sms-desktop
git checkout feature/desktop-control-center
git checkout -b feature/mobile-companion-patches
git apply docs/0001-feat-api-mobile-companion-endpoints-schedule-write-g.patch
# ou : git am docs/0001-*.patch  (conserve le message de commit)
# puis redémarrer l'API desktop.
```

### Comportement du mobile SANS le patch

L'app est **entièrement fonctionnelle en lecture**. Les fonctionnalités
d'écriture dégradent proprement :

| Fonction | Sans patch serveur |
|---|---|
| Édition EDT (admin) | Message « Édition indisponible : appliquez le patch serveur » (404/405 interceptés) |
| Modification de notes existantes (admin) | Champs éditables mais le serveur skippe les existantes → message explicite après sauvegarde |
| Création/édition d'élève | Écrite localement + file **outbox** (rejouée à la synchro) |
| Détail élève complet | Satellites servis par le cache local Drift (persistés via `/sync/pull`) |
| Types d'évaluation | Déduits des évaluations existantes |
| Badge « toutes les semaines » | Les cours toutes-semaines apparaissent comme semaine A (fix serveur recommandé) |

---

## Notes de compatibilité

- **Schéma Drift v2** : migration automatique au premier lancement (colonnes
  ajoutées à `classrooms` — aucune donnée perdue). Après toute modification
  du code des tables, re-exécuter `dart run build_runner build
  --delete-conflicting-outputs`.
- Le filtrage des périodes par cycle exploite `cycle_id` ([Fix-PERIOD-CYCLE],
  commit `96324a6` du desktop) — sans ce champ, fallback sur toutes les
  périodes.
- L'export exploite l'endpoint `[Fix-EXPORT]` (commit `1132634`) — les clés
  non supportées ne sont plus envoyées.
- `GET /students` exploite `classroom_id` ([Fix-CLASSROOM-ID], commit
  `f80afea`) — sans ce champ, l'onglet Élèves du détail de classe tombe sur
  le comptage par assignations synchronisées.
- Devise XOF, interface en français, format « NOM Prénoms » — inchangés.

---

# V2 — Les 9 améliorations suivantes (session du 08/10/2026)

> Build sur le commit b523205. Patch serveur associé : branche
> `feature/mobile-companion-patches` (commit 8f6fc69) du dépôt desktop.

## 1. Multi-serveurs (bascule entre établissements)

- **Nouveau registre** `lib/features/connections/server_profiles.dart` :
  liste persistée de profils (`SharedPreferences`), un **JWT, un token
  d'appairage et une base Drift PAR serveur** (`getech_sms.db` pour le
  profil hérité — données conservées ; `getech_sms_<id>.db` pour les
  nouveaux). Migration automatique de l'ancienne config mono-serveur.
- « Gérer les connexions serveur » ouvre désormais une carte **« Mes
  serveurs »** : liste (établissement, URL, état en ligne), **Basculer**
  (bascule à chaud : connexion + session + base + caches réinitialisés),
  **Oublier** (supprime profil + session + données locales de CE serveur).
- L'écran **« Appairage du terminal »** garde son rôle d'ajout de nouveaux
  serveurs ET affiche un bandeau « Serveurs déjà appairés » permettant de
  **revenir aux serveurs existants** sans ré-appairage (+ bouton « Gérer »).
- Déconnexion : n'efface que la session du serveur ACTIF (les autres
  serveurs restent connectés).

## 2. Tableau de bord enseignant (finances + inscriptions masquées)

- Détection enseignant durcie : tant que le scope n'a pas tranché
  (chargement/erreur), un **état d'attente** est affiché — JAMAIS la vue
  générique (qui contenait « Paiements récents » et « Élèves récemment
  inscrits »).
- Les sections récentes de la vue générique sont désormais **filtrées par
  permission** (PAYMENT_READ / STUDENT_READ).
- Serveur : `/auth/login` et `/auth/me` renvoient `user.role` (premier rôle
  RBAC) — la détection ne dépend plus uniquement de `roles[]`.

## 3. Modules Notes / EDT / Présence toujours visibles chez les enseignants

- Barre du bas + tiroir + grille « Plus » : ces trois modules portent le
  repli `teacherVisible` — visibles pour tout enseignant détecté (rôle
  déclaré OU relations de données), même si sa liste de permissions RBAC
  est incomplète côté serveur.
- Le serveur fournit désormais le **router /attendance complet**
  (session, absences, cahier de texte, historique) — le module Présence
  n'est plus en 404.

## 4. Mode hors-ligne complet (fin des blocages)

- **`checking` n'est plus un état bloquant** (démarrage à froid) sur tous
  les modules : `canReachServer && !isChecking` partout.
- **Saisie des notes hors-ligne** : la page lit le cache Drift + les
  soumissions en attente de l'outbox ; l'enregistrement part dans l'outbox
  (`grade_submission`) et est poussé à la prochaine connexion via
  `POST /grades/assessments/{id}/grades`.
- **[Fix-SYNC-PUSH]** : le push utilisait `{changes: …}` alors que le
  serveur attend `{lines: […]}` → 422 permanent (les écritures hors-ligne
  ne se synchronisaient JAMAIS). Corrigé au contrat réel + traitement des
  résultats par ligne (applied / conflict_server_wins / invalid / error).
- **File de validation/rejet des notes** (abandon du verrouillage) :
  une note existante modifiée par un non-admin devient une **proposition**
  marquée (`En attente de validation (10 → 14)`), qu'un admin **valide**
  (applique la nouvelle note) ou **rejette** (conserve l'ancienne) —
  implémenté côté serveur (table `grade_modifications`, migration v1_0019,
  endpoints approve/reject + liste) ET côté desktop (champs déverrouillés,
  colonne Statut, dialogue « Modifications en attente (N) »).
  L'anti-bypass convertit même un `/sync/push` direct en proposition.
- Marques visibles dans l'app : « Sera synchronisée » / « En attente de
  validation (X → Y) » / « Modification validée » / « Modifiée — rejetée ».

## 5. Onglet Classes : erreur 500 corrigée + résilience

- **Cause racine serveur** : `Classroom.cycle_id` n'existe pas sur le
  modèle (la colonne vit sur `Level`) → `AttributeError` → 500 sur
  `GET /classrooms` (liste ET détail) dès qu'une classe existe. Corrigé
  (lecture `level.cycle_id`) — test de non-régression ajouté.
- **Résilience mobile** : échelle de dégradation (per_page=200 toutes
  pages → 1 page per_page=50) puis repli cache Drift ; le détail classe
  ne remonte plus jamais d'exception brute à l'UI.

## 6. Photos des élèves en miniature

- Nouveau service `student_photos.dart` : téléchargement authentifié via
  `GET /students/{id}/photo` (octets), **cache disque par serveur**
  (`photos/<hash-serveur>_<id>.jpg`), mémo négatif (404 → initiales,
  pas de re-tentative). `StudentAvatar` branché sur la liste des élèves
  et l'en-tête du détail (initiales en fallback).
- Serveur : endpoint `GET /students/{id}/photo` (auth, FileResponse).

## 7. Notifications utilisateurs

- **Rappels de cours (enseignants)**, programmés depuis le cache local
  (donc y compris hors-ligne), via le système natif (zonedSchedule,
  alarmes exactes si permises) :
  2 min avant (« pensez à vérifier la présence des élèves »), à l'heure
  (« vérifiez la présence avant de démarrer »), 5 min avant la fin.
  Semaines A/B respectées.
- **Suivi de la validation des notes** : après chaque synchro, comparaison
  avec l'instantané précédent → enseignant : « N validée(s) et M
  rejetée(s) » ; admin : « N modification(s) en attente de validation ».
- Permissions Android (POST_NOTIFICATIONS, SCHEDULE_EXACT_ALARM,
  RECEIVE_BOOT_COMPLETED) ajoutées au manifest.

## 8. Icône du logiciel desktop + nom « GeTech-SMS »

- Icône : générée depuis `icon.jpg` du desktop (source de l'ICO officiel)
  — Android (48→192 + round), iOS (20→1024 complet), web (favicon, 192,
  512 + maskable). Script réutilisable :
  ``scripts/generate_mobile_icons.py` (à la racine du dépôt mobile)`.
- Nom : `android:label`, `CFBundleDisplayName`/`CFBundleName`, titre web,
  manifest → **GeTech-SMS** (identifiants techniques inchangés).

## 9. Nombre d'enseignants corrigé (0 → réel)

- **API** `/dashboard/stats` **et** service desktop (même source que l'UI
  Flet) : comptage par **union** des 3 chemins de création
  (`user_roles/roles` "TEACHER" ; `UserEstablishment.role` legacy ;
  `User.role` du formulaire desktop), `count(distinct)` — plus aucun
  double comptage, plus aucun 0 permanent.
