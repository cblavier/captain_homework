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
- `OPENAI_MODEL` : modèle utilisé, `gpt-5.4-mini` par défaut.
- `HOMEWORK_CHILD_n_FIRST_NAME` : prénom de chaque enfant.
- `HOMEWORK_CHILD_n_AVATAR_BASE64` : avatar facultatif en PNG, JPEG ou WebP encodé en base64.
- `PRONOTE_CHILD_n_THEME` : thème `blue` ou `green`, avec le même numéro que l’enfant. Le nom de variable est partagé avec Captain Notes.
- `HOMEWORK_PASSWORD` : mot de passe familial facultatif.

Les variables `PHX_HOST` et `SECRET_KEY_BASE` du fichier exemple servent au déploiement en production.

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

Depuis le menu utilisateur, la page **Paramètres** permet de modifier les instructions communes aux contrôles et d’activer les matières de chaque enfant. Désactiver une matière conserve ses leçons et résultats. Lors de la création d’un contrôle, des instructions supplémentaires peuvent compléter les instructions communes.

Les profils enfants sont des espaces de travail, pas des comptes avec authentification individuelle. Le mot de passe familial protège l’accès global à l’application.

### Ressources pédagogiques

L’onglet **Ressources** accepte :

- Les fichiers PDF, JPEG, PNG et WebP, jusqu’à 20 Mo.
- Les URL publiques de pages HTML, de PDF ou d’images.
- Jusqu’à 20 pages et 40 images par PDF, et 40 images par page web.

Les pages nécessitant une connexion ou JavaScript, les documents Word et les présentations doivent être exportés en PDF avant import. Les images intégrées aux pages web doivent être en JPEG, PNG ou WebP ; si une image est inaccessible ou non prise en charge, l’import affiche une erreur.

Les originaux, les pages rendues et les illustrations extraites sont conservés sur le serveur. Le texte reconnu peut être vérifié et corrigé. Un import incomplet ou en erreur peut être relancé ; la génération demande de terminer ou retirer ces imports avant de continuer.

Pour les dessins vectoriels et les documents scannés, la page rendue reste disponible comme support visuel. Les illustrations retenues dans les questions sont copiées avec le contrôle pour rester accessibles après suppression de la ressource source.

Les documents et réponses nécessaires à l’OCR, à la génération ou à la correction sont transmis à l’API OpenAI. La base SQLite et les fichiers importés restent dans le stockage de l’application.

### Génération et correction des contrôles

Les questions sont validées individuellement et sauvegardées au fur et à mesure. Après la première proposition, seules les questions invalides ou manquantes sont redemandées : deux réparations au maximum, puis une tentative limitée aux définitions et réponses rédigées, soit quatre appels maximum par lancement.

Un contrôle incomplet reste dans l’historique avec le statut **À compléter**. Le bouton de reprise conserve les questions déjà prêtes et les instructions initiales. Une erreur de service ou de quota interrompt la génération ; une génération interrompue devient récupérable après quinze minutes.

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
