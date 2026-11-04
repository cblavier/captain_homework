# Captain Homework

## Description du projet

Une application de révision pour les collégiens : importer ses cours, préparer des contrôles et obtenir une correction détaillée, dans un espace dédié à chaque enfant.

Les leçons sont organisées par matière et présentées dans trois onglets : **Contrôles**, **Cours** et **Ressources**. Les pages de cours et les contrôles d’exemple peuvent être ajoutés en photo, vérifiés après reconnaissance du texte, puis réordonnés.

Les ressources complémentaires peuvent être des PDF, des images ou des liens vers des documents publics. Leur texte et leurs illustrations enrichissent les contrôles. Les exercices des évaluations et fiches d’activité sont utilisés en priorité, avec leurs illustrations originales dans les questions.

Les réponses sont sauvegardées pendant le contrôle. La correction fournit une note sur 20 et un retour par question. Les exercices précédemment mal réussis peuvent être repris lors des prochaines révisions.

La compréhension orale est disponible en contrôle classique et en flashcards : un court monologue
est créé dans la langue étudiée, puis lu par une voix de synthèse naturelle. La voix est choisie
selon le locuteur du texte (féminine, masculine ou neutre quand le genre n’est pas indiqué).
L’élève peut réécouter l’extrait et répond par écrit ; la transcription reste côté serveur pour la
correction. Les fichiers sont conservés avec le contrôle, copiés lorsqu’on le refait et supprimés
avec lui. Un échec de synthèse laisse les questions prêtes disponibles et la génération reprenable.

## Motivations

- Aider les enfants à réviser à partir de leurs propres cours.
- Faciliter la préparation de contrôles variés sans ressaisir les documents.
- Garder les leçons, les ressources et les résultats au même endroit.
- Proposer une interface simple, utilisable sur ordinateur, tablette et téléphone.

L’interface reprend les conventions de [Captain Notes](https://github.com/cblavier/captain_notes), avec un avatar et un thème de couleur par enfant. L’application peut être ajoutée à l’écran d’accueil comme PWA.

## Techno

- Elixir, Phoenix LiveView et SQLite.
- OpenAI pour la reconnaissance des documents, la génération des contrôles et leur correction.
- Poppler : une suite d’outils pour extraire le texte et les images des PDF.
- ImageMagick pour la compatibilité des illustrations recadrées des anciens contrôles.
- Code massivement généré par intelligence artificielle avec OpenAI Codex.
- Prévu pour tourner avec Docker en production.

## Lancer le projet en local

Prérequis : Elixir et Erlang/OTP (versions locales dans [.tool-versions](.tool-versions)), ainsi que Poppler et ImageMagick. L’image Docker utilise Elixir 1.19.4 et OTP 28.

Sur macOS, installer les outils de traitement des documents :

```sh
brew install poppler imagemagick
```

Sur Debian ou Ubuntu, les paquets correspondants sont `poppler-utils` et `imagemagick`.

```sh
git clone https://github.com/cblavier/captain_homework.git
cd captain_homework
cp -n .env.example .env
```

Compléter le fichier `.env` :

- `OPENAI_API_KEY` : clé API OpenAI.
- `OPENAI_MODEL` : modèle utilisé pour l’OCR, les ressources, la génération et la correction des contrôles classiques, `gpt-5.4` par défaut.
- `OPENAI_ILLUSTRATION_MODEL` : modèle dédié à l’extraction des illustrations, `gpt-6-astra` par défaut, avec un raisonnement `medium` et le détail d’image `original`. Le modèle choisi doit accepter ces réglages et les sorties JSON structurées.
- `OPENAI_FLASHCARD_MODEL` : modèle dédié à la correction après chaque flashcard, `gpt-5.4-mini` par défaut, avec le raisonnement désactivé (`none`) pour réduire l’attente. Le modèle choisi doit accepter ce réglage et les sorties JSON structurées.
- `OPENAI_SPEECH_MODEL` : modèle Realtime de synthèse vocale, `gpt-realtime-2.1-mini` par défaut.
- `HOMEWORK_CHILD_n_FIRST_NAME` : prénom de chaque enfant.
- `HOMEWORK_CHILD_n_SCHOOL_NAME` et `HOMEWORK_CHILD_n_CLASS_NAME` : établissement et classe facultatifs, affichés dans l’en-tête sans connexion à Pronote. Par exemple : `Collège Jean Monnet` et `4A`.
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

L’onglet **Ressources** accepte les PDF, JPEG, PNG et WebP, les URL publiques et les fichiers Google Drive accessibles par lien. Les imports n’ont pas de plafond de taille, mais le traitement est limité à 100 pages et 300 images par PDF (160 mégapixels et 256 Mo extraits), et 40 images par page web. Les documents nécessitant une connexion ou JavaScript, Word et présentations doivent être exportés en PDF.

Le texte reconnu peut être corrigé ; un import interrompu peut reprendre sans refaire les pages déjà traitées. Les imports incomplets doivent être terminés ou retirés avant génération. Un catalogue pédagogique est réutilisé tant que le contenu et les paramètres d’analyse restent inchangés.

Les nouveaux contrôles utilisent les ressources telles qu’elles sont chargées : aucun recadrage automatique ni appel de réparation du cadrage n’est effectué. Le cadrage des ressources est préparé manuellement en amont. La vérification pédagogique examine les images entières et conserve les protections contre les paraphrases et les réponses dévoilées. Les descriptions d’analyse restent internes ; les textes sources utiles à la compréhension restent autorisés. Les contrôles déjà enregistrés conservent leurs illustrations ; leur génération n’est pas relancée automatiquement.

Les illustrations retenues restent accessibles dans le contrôle après suppression de la ressource. Les vidéos et liens cités ne sont pas consultés automatiquement.

Les documents et réponses nécessaires sont transmis à OpenAI ; la base et les fichiers restent stockés dans l’application.

### Génération et correction des contrôles

La création permet de choisir les types de questions et d’ajouter des consignes personnalisées prioritaires. La répartition des questions dépend des types sélectionnés, de leur durée de travail et du contenu disponible, sans quota fixe de rédactions ni de questions documentaires. Les contrôles d’exemple guident uniquement la forme ; les cours et ressources fournissent le contenu pédagogique.

Le mode **Flashcard** utilise toutes les pages de cours, sans exemples ni ressources externes, avec uniquement des questions rapides. Chaque carte vaut un point, avec des points partiels par quarts, et révèle sa correction après validation. Le résultat final est ramené sur 20.

La génération sauvegarde une première version, puis un audit indépendant vérifie les questions, leurs sources et leurs supports. Une différence de classification de l’effort, à elle seule, met à jour les métadonnées de la question et du plan ; les défauts pédagogiques restent soumis à réparation. Les réparations conservent les questions validées et transmettent leurs énoncés visibles, les sources utiles aux questions rejetées et les images nécessaires. Seules les questions rejetées sont réécrites. Un contrôle incomplet reste **À compléter** : la reprise conserve le travail prêt et les instructions. La génération continue après fermeture de la page ; une tâche interrompue peut être reprise et une tâche bloquée expire après dix minutes.

Pendant la génération, l’écran affiche l’étape de l’appel en cours, le temps écoulé et le nombre de questions à ajuster.

Un document partagé est conservé séparément du texte propre à chaque question. Il apparaît une seule fois avant les questions associées, sans remplacer leurs consignes ni leur contenu dynamique, y compris lors des réparations et des reprises de questions.

Le contexte conserve les connaissances de toutes les pages de cours. Les exercices des ressources sont sélectionnés avec leurs faits et supports associés dans un budget de contexte adapté au nombre de questions. Les pages visuelles sélectionnées sont transmises en entier pour préserver les légendes ; leurs figures extraites ne sont pas ajoutées automatiquement en doublon.

La table `ai_calls` conserve les durées, statuts et consommations de tokens, sans prompts ni réponses. Les contrôles non rendus ou terminés peuvent être supprimés après confirmation, avec leurs résultats et fichiers associés. Une leçon ne peut être supprimée que lorsqu’elle est vide. L’OCR et la correction restent des propositions de l’IA, à vérifier.

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

### Synthèse vocale

`CaptainHomework.AI.Speech` utilise l’API Realtime par WebSocket, côté serveur, avec
`gpt-realtime-2.1-mini`. La connexion est limitée à deux minutes et toujours fermée, sans
nouvelle tentative payante automatique. Le flux PCM mono à 24 kHz est enregistré en WAV,
sans convertisseur externe. Un extrait n’est accepté qu’après une réponse complète et une
vérification de sa transcription ; les extraits tronqués ou reformulés sont rejetés.
Les anciens MP3 restent lisibles et copiables. Les clés API restent côté serveur.

Référence : [conversations Realtime OpenAI](https://developers.openai.com/api/docs/guides/realtime-conversations).
