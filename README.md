# GeTech-SMS Mobile

Application mobile companion (iOS + Android) pour le système de gestion scolaire GeTech-SMS.

## Description

Application **Flutter** offline-first qui se synchronise avec le terminal principal (desktop Python/Flet + API FastAPI) pour les modules :

- **Tableau de bord** — KPIs et alertes
- **Classes** — liste, détail, CRUD
- **Élèves** — fiches complètes, import/export Excel
- **Emploi du temps** — grille hebdomadaire (semaines A/B)
- **Notes** — saisie, classement, bulletins
- **Présence** — absences, cahier de texte
- **Paramètres** — profil, établissement, préférences
- **Connexions** — gestion des appareils, QR code, mDNS, statut synchro

## Stack technique

| Couche | Technologie |
|---|---|
| Framework | Flutter (Dart) |
| State management | Riverpod |
| Base locale | Drift (SQLite) |
| HTTP client | Dio |
| Routing | GoRouter |
| Stockage sécurisé | flutter_secure_storage |
| Background sync | workmanager + background_fetch |

## Synchronisation

- **Pull incrémental** avec watermark `synced_at`
- **Push** des modifications locales (`is_dirty=True`)
- **Server-wins** pour la résolution de conflits (V1)
- Déclencheurs : automatique (5 min), manuel (pull-to-refresh), au lancement
- **Découverte serveur** : mDNS/Bonjour + QR code + IP manuelle

## Démarrer

> ⚠️ Ce dépôt est initialisé avec le **prompt de création** (`PROMPT.md`).
> L'implémentation Flutter doit encore être générée en suivant ce prompt.

### Prérequis
- Flutter SDK ≥ 3.0
- Dart ≥ 3.0
- Le dépôt desktop GeTech-SMS : https://github.com/koffi-13/getech-sms-desktop

### Créer le projet Flutter
```bash
flutter create --org com.getech . --project-name getech_sms_mobile
```

## Dépôt desktop associé

- **Desktop (serveur)** : https://github.com/koffi-13/getech-sms-desktop
- Le desktop héberge la base de données centrale (MySQL) et l'API REST FastAPI (`/api/v1`)
- L'API est documentée sur `/api/v1/docs` (Swagger)

## Licence

Propriétaire — © GeTech-SMS
