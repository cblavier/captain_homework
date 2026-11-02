# Captain Homework

## Description du projet

Une application de révision pour les collégiens : importer ses cours, préparer des contrôles et obtenir une correction détaillée, dans un espace dédié à chaque enfant.

Les leçons sont organisées par matière et présentées dans trois onglets : **Contrôles**, **Cours** et **Ressources**. Les pages de cours et les contrôles d’exemple peuvent être ajoutés en photo, vérifiés après reconnaissance du texte, puis réordonnés.

Les ressources complémentaires peuvent être des PDF, des images ou des liens vers des documents publics. Leur texte et leurs illustrations enrichissent les contrôles. Les exercices des évaluations et fiches d’activité sont utilisés en priorité, avec leurs illustrations originales dans les questions.

Les réponses sont sauvegardées pendant le contrôle. La correction fournit une note sur 20 et un retour par question. Les exercices précédemment mal réussis peuvent être repris lors des prochaines révisions.

## Motivations

- Aider les enfants à réviser à partir de leurs propres cours.
- Faciliter la préparation de contrôles variés sans ressaisir les documents.
- Garder les leçons, les ressources et les résultats au même endroit.
- Proposer une interface simple, utilisable sur ordinateur, tablette et téléphone.

L’interface reprend les conventions de [Captain Notes](https://github.com/cblavier/captain_notes), avec un avatar et un thème de couleur par enfant. L’application peut être ajoutée à l’écran d’accueil comme PWA.

## Techno

- Elixir, Phoenix LiveView et SQLite.
- OpenAI pour la reconnaissance des documents, la génération des contrôles et leur correction.
- Poppler pour lire les PDF et extraire leurs illustrations.
- Code massivement généré par intelligence artificielle avec OpenAI Codex.
- Prévu pour tourner avec Docker en production.

## Lancer le projet en local

Prérequis : Elixir et Erlang/OTP (versions locales dans [.tool-versions](.tool-versions)), ainsi que Poppler. L’image Docker utilise Elixir 1.19.4 et OTP 28.

Sur macOS, installer Poppler :

```sh
brew install poppler
```

Sur Debian ou Ubuntu, le paquet correspondant est `poppler-utils`.

```sh
git clone https://github.com/cblavier/captain_homework.git
cd captain_homework
cp -n .env.example .env
```

Compléter le fichier `.env` :

- `OPENAI_API_KEY` : clé API OpenAI.
- `OPENAI_MODEL` : modèle utilisé pour tous les appels IA (OCR, ressources, génération et correction), `gpt-5.4` par défaut.
- `HOMEWORK_CHILD_n_FIRST_NAME` : prénom de chaque enfant.
- `HOMEWORK_CHILD_n_AVATAR_BASE64` : avatar facultatif en PNG, JPEG ou WebP encodé en base64.
- `PRONOTE_CHILD_n_THEME` : thème `blue` ou `green`, avec le même numéro que l’enfant. Le nom de variable est partagé avec Captain Notes.
- `HOMEWORK_PASSWORD` : mot de passe familial facultatif.

Les variables `PHX_HOST` et `SECRET_KEY_BASE` du fichier exemple servent au déploiement en production.

L’OCR utilise un raisonnement `low` ; la préparation des catalogues et la conception des contrôles utilisent un raisonnement `medium`.

```sh
set -a
source .env
set +a
mix setup
mix phx.server
```

Ouvrir [localhost:4125](http://localhost:4125). Après modification des variables, les recharger et redémarrer le serveur. Pour utiliser direnv, ajouter `dotenv .env` dans `.envrc`, puis exécuter `direnv allow`.

Les fichiers `.env`, `.envrc` et `env` ne sont pas versionnés. Sans clé OpenAI, les cours peuvent être importés et leur texte saisi manuellement ; l’analyse des ressources, la génération et la correction nécessitent une connexion IA configurée. Les appels à l’API OpenAI sont facturés sur le compte associé à la clé.

Pour lancer les vérifications :

```sh
mix precommit
```

### Espaces enfants et paramètres

Remplacer `n` par `1`, `2`, etc. Les numéros identifient durablement les enfants : conserver le même numéro lors d’un changement de prénom et ne jamais le réattribuer à une autre personne. Retirer une variable `FIRST_NAME` masque l’espace sans supprimer ses données. Sans enfant configuré, aucun espace n’est proposé.

Les avatars acceptent au maximum 262 144 caractères base64. Sans avatar valide, l’initiale du prénom est affichée. Sans thème valide, les palettes bleu et vert alternent dans l’ordre des enfants.

Depuis le menu utilisateur, la page **Paramètres** permet de choisir le thème et d’activer les matières de chaque enfant. Désactiver une matière conserve ses leçons et résultats. Les règles pédagogiques communes sont intégrées au code ; des instructions facultatives peuvent être ajoutées à la création de chaque contrôle. Toute réponse doit pouvoir être déduite des leçons ou des supports affichés avec la question.

Les profils enfants sont des espaces de travail, pas des comptes avec authentification individuelle. Le mot de passe familial protège l’accès global à l’application.

### Ressources pédagogiques

L’onglet **Ressources** accepte :

- Les fichiers PDF, JPEG, PNG et WebP, sans plafond de taille à l’import.
- Les URL publiques de pages HTML, de PDF ou d’images, y compris les liens de partage de fichiers Google Drive (accès « Tous les utilisateurs disposant du lien », téléchargement autorisé).
- Jusqu’à 100 pages et 300 images par PDF (160 mégapixels et 256 Mo extraits maximum), et 40 images par page web.

Le lien sous la zone d’upload ouvre une fenêtre pour importer une URL. Les téléchargements par URL n’ont pas de plafond de taille ; les limites de traitement des PDF et des images restent applicables.

Les pages nécessitant une connexion ou JavaScript, les documents Word et les présentations doivent être exportés en PDF avant import. Les images intégrées aux pages web doivent être en JPEG, PNG ou WebP ; si une image est inaccessible ou non prise en charge, l’import affiche une erreur.

Les originaux, les pages rendues et les illustrations extraites sont conservés sur le serveur. Le texte reconnu peut être vérifié et corrigé. Un import incomplet ou en erreur peut être relancé sans refaire l’OCR des pages déjà reconnues ; la génération demande de terminer ou retirer ces imports avant de continuer.

Après l’OCR, un catalogue pédagogique est préparé et enregistré en base pour chaque ressource et chaque page de cours : notions, exercices, mots-clés, pages d’appui et supports visuels nécessaires. Une empreinte du contenu, du modèle et de la version d’analyse permet de réutiliser ce catalogue entre les contrôles et après redémarrage. Réordonner les pages de cours ne relance pas leur analyse individuelle. Une modification du document entraîne une nouvelle préparation de son catalogue. Les documents plus anciens sans catalogue sont préparés une seule fois lors de leur première utilisation.

Pour chaque contrôle, l’application sélectionne localement les entrées du catalogue selon les notions demandées, en donnant la priorité aux exercices existants et en conservant leurs connaissances d’appui. La rédaction reçoit cet extrait (40 Ko maximum) et ses supports utiles ; l’audit reçoit aussi le texte OCR des pages citées pour vérifier les réponses. Aucun appel supplémentaire de sélection des pages n’est nécessaire. Les images envoyées sont limitées à 24 fichiers et 24 Mio par appel, uniquement pour les supports pédagogiques. Les vidéos et les liens cités dans un document ne sont pas automatiquement consultés.

Pour les dessins vectoriels et les documents scannés, la page rendue reste disponible comme support visuel. Les illustrations retenues dans les questions sont copiées avec le contrôle pour rester accessibles après suppression de la ressource source.

Les documents et réponses nécessaires à l’OCR, à la génération ou à la correction sont transmis à l’API OpenAI. La base SQLite et les fichiers importés restent dans le stockage de l’application.

### Génération et correction des contrôles

Le nombre de réponses directes, courtes et développées est calculé conjointement avec le nombre de questions de connaissances et de questions sur documents. La cible est 40 % / 40 % / 20 %, avec environ moitié connaissances et moitié documents lorsque les sources et les formats le permettent. Une réponse courte demande une seule explication en une ou deux phrases ; une réponse développée demande au moins deux aspects expliqués en trois à cinq phrases. Les formats personnalisés sont déduits une seule fois de leur nom et de leur consigne, puis enregistrés.

Un premier appel produit le contrôle complet : notions, compétences, consignes, réponses, barèmes et supports partagés. Cette version est sauvegardée avant un audit indépendant de l’effort, du mode de résolution, des sources citées et des réponses involontairement révélées. L’audit voit les supports réellement affichés, y compris les schémas, et distingue les sources OCR cachées à l’élève. Un contrôle valide nécessite donc deux appels principaux, hors préparation de documents encore non analysés. Les questions sur un même document sont regroupées à l’affichage.

La création permet de cocher les types autorisés (définition, QCM, texte à trous, compréhension de texte, réponse rédigée, schéma). Tous sont cochés par défaut, au moins un doit rester sélectionné. Ce choix est enregistré avec le contrôle et respecté lors des réparations, reprises et révisions d’erreurs précédentes.

À l’import, chaque page de contrôle d’exemple est analysée une fois pour enregistrer un profil de forme composé uniquement de catégories et de nombres : types et quantités de questions, barème observé, regroupement, style des consignes et longueur des réponses. Aucune transcription pédagogique n’est enregistrée dans ce profil. Les générations réutilisent ces profils sans renvoyer les images d’exemple à l’IA. Une modification du fichier ou du modèle invalide le profil ; les anciens exemples sont préparés à leur première utilisation.

Tous les contrôles d’exemple de la leçon sont automatiquement pris en compte pour la forme, le style des consignes et la répartition des types de questions et du barème. Leur contenu pédagogique est exclu : seuls les cours et les ressources alimentent les connaissances et les exercices du contrôle.

Seules les questions rejetées sont réécrites ; un support partagé peut être corrigé avec elles, puis l’ensemble est vérifié à nouveau. Le nombre total, les types et les quotas restent ceux du plan global, y compris pour les questions reprises d’un contrôle précédent de la même leçon. Les illustrations identiques ne sont transmises qu’une fois par appel.

Un contrôle incomplet reste dans l’historique avec le statut **À compléter**. Le bouton de reprise conserve les questions prêtes, les brouillons en attente d’audit et les instructions initiales. Une modification des sources ou de la version des règles entraîne une nouvelle préparation. Une erreur de service ou de quota interrompt les appels ; fermer ou recharger la page laisse la génération continuer en arrière-plan. Après un redémarrage serveur, les tâches orphelines deviennent récupérables à l’ouverture du contrôle. Un délai maximal de dix minutes interrompt une tâche bloquée en conservant le dernier état sauvegardé.

La table `ai_calls` enregistre pour chaque appel l’étape, le contrôle concerné, la durée, le modèle, le statut, l’identifiant de requête et les tokens utilisés (entrée, sortie, cache et raisonnement). Elle ne contient ni clé API, ni prompt, ni contenu des réponses. Ces mesures permettent de comparer les temps et les consommations réels, sans les confondre avec une estimation.

Les contrôles non rendus peuvent être supprimés. Supprimer une leçon retire également ses pages, ses ressources et ses contrôles, après confirmation.

La reconnaissance et la correction restent des propositions de l’IA : la validation du format ne garantit pas la justesse du contenu pédagogique.

## Construire et lancer en production avec Docker

Prérequis : Docker avec Buildx et Compose. Depuis le dossier du projet :

```sh
docker buildx build --platform linux/amd64 --load -t captain_homework:local .
cp -n .env.example env
chmod 600 env
```

Le fichier **`env`** contient les variables de l’application, sans `export`. Renseigner la clé OpenAI, les enfants, puis :

- `PHX_HOST` : nom de domaine de l’application, sans protocole ni chemin.
- `SECRET_KEY_BASE` : secret généré avec `mix phx.gen.secret`, à conserver lors des mises à jour.
- `HOMEWORK_PASSWORD` : mot de passe familial pour protéger l’accès si le service est exposé.

Les secrets ne sont pas intégrés à l’image. Ne pas versionner `env`.

### Configuration du stockage

Compose utilise un fichier distinct, **`.env`**, à côté de `docker-compose.yml`, pour configurer le stockage et l’identité Unix du conteneur :

```dotenv
DATA_DIR=./data
APP_UID=1000
APP_GID=1000
DOCKER_PLATFORM=linux/amd64
```

Sur la machine cible, remplacer `APP_UID` et `APP_GID` par les résultats de `id -u` et `id -g` du compte propriétaire du dossier de données. Créer ce dossier et lui donner les droits d’écriture nécessaires. Compose refuse de le créer implicitement.

```sh
mkdir -p data
docker compose up -d
docker compose ps
docker compose logs --tail=100 -f captain_homework
```

La base SQLite est située dans `/app/data/captain_homework.db` et les documents dans `/app/data/uploads`. Les migrations sont appliquées au démarrage de la release. Sauvegarder l’ensemble du dossier de données ; pour une copie simple et cohérente de SQLite et des documents, arrêter le conteneur pendant la sauvegarde.

### Reverse proxy et mises à jour

Le conteneur écoute sur **127.0.0.1:4125** sur la machine hôte. Configurer un reverse proxy avec un certificat valide pour servir `https://<PHX_HOST>` et transmettre les requêtes vers `http://127.0.0.1:4125`, avec `X-Forwarded-Proto: https` et la prise en charge des WebSockets.

Pour transférer l’image vers une autre machine :

```sh
docker save -o captain_homework-image.tar captain_homework:local
```

Transférer l’archive, `docker-compose.yml`, `env` et la configuration Compose `.env`, puis lancer sur la machine cible :

```sh
docker load -i captain_homework-image.tar
docker compose up -d --force-recreate
```

Reconstruire l’image et recréer le conteneur pour chaque mise à jour. Une modification de `env` nécessite aussi de recréer le conteneur. Le point d’entrée `/health` permet de vérifier son état.

Le script [deploy.sh](deploy.sh) automatise la construction et le transfert SSH/SFTP vers un NAS Synology. Configurer `DEPLOY_HOST`, `DEPLOY_PORT`, `DEPLOY_REMOTE_DIR`, `DEPLOY_SFTP_DIR` et `DOCKER_PLATFORM` pour la destination souhaitée. Le script conserve le fichier `env` distant et vérifie l’état du conteneur après le déploiement.

## Licence

Captain Homework est distribué sous [licence MIT](LICENSE). Elle autorise l’utilisation, la modification et la redistribution, y compris commerciales, sous réserve de conserver la notice de copyright et la licence. Le logiciel est fourni sans garantie. Les dépendances et éléments tiers restent soumis à leurs licences respectives.

Les paramètres de chaque matière permettent de gérer une liste de types de questions propre à chaque enfant. Les six types initiaux peuvent être supprimés et de nouveaux types ajoutés avec un nom, une consigne et un format de réponse. Cette liste alimente les cases à cocher à la création d’un contrôle ; les consignes sélectionnées sont conservées avec celui-ci. Supprimer un type ne modifie pas les contrôles existants.

Dans les paramètres, le thème Jour / Nuit / Système est conservé sur l’appareil. Le mode Système suit automatiquement l’apparence du système ; le mode sombre conserve la couleur de chaque enfant, sans modifier les images des documents.
