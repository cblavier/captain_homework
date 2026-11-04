# Génération d’un contrôle

Le serveur Phoenix orchestre les appels à l’API Responses d’OpenAI. Les documents importés, les brouillons, les questions validées et les diagnostics sont enregistrés séparément : une reprise repart du dernier état utile.

## Vue d’ensemble

Les blocs bleus représentent des appels OpenAI ; les autres traitements sont exécutés par l’application.

```mermaid
flowchart TD
    A["Import : leçon, ressources, contrôles d’exemple"] --> B["Extraction locale des pages"]
    B --> C["OpenAI · OCR et analyse du document"]
    C --> D["OpenAI · catalogue pédagogique réutilisable"]
    B --> E["OpenAI · analyse du style des contrôles d’exemple"]
    D --> F["Paramètres : format, nombre, types, consignes"]
    E --> F
    F --> G{"Format"}

    G -->|Classique| H["Sélection du catalogue et des images sources"]
    H --> I["OpenAI · plan complet et questions"]
    I --> J["Validation locale du JSON, des références et des types"]
    J --> K["Sauvegarde des brouillons"]
    K --> M["Choix des vérifications nécessaires via le cache"]
    M -->|Vérification nécessaire| L["VisibleImages · chargement des ressources entières"]
    L --> N["OpenAI · audit ciblé sur les pixels réellement affichés"]
    M -->|Aucune vérification nécessaire| O["Sauvegarde des images finales, questions acceptées et diagnostics"]
    N --> O
    O --> P{"Résultat"}

    P -->|Tout est valide| Q["Contrôle prêt"]
    P -->|Défaut de contenu| T["OpenAI · réparation des seules questions rejetées"]
    T --> J
    P -->|Aucun progrès ou limite atteinte| U["Contrôle partiel\nQuestions validées conservées"]
    U --> V["Reprise depuis le dernier état enregistré"]
    V --> Y{"État conservé"}
    Y -->|Brouillons à vérifier| M
    Y -->|Questions à réparer| P
    Y -->|Plan absent ou périmé| H

    G -->|Flashcards| W["OpenAI · cartes autonomes issues des seules leçons"]
    W --> X["Validation locale : format, autonomie, sources, doublons"]
    X --> M

    classDef openai fill:#e7f0ff,stroke:#3978bf,color:#16365d;
    class C,D,E,I,N,T,W openai;
```

Une consigne personnalisée peut déclencher un appel supplémentaire `instructions` pour sélectionner les entrées autorisées du catalogue. Sans consigne particulière, la sélection est locale. Le catalogue et les profils des exemples sont réutilisés tant que leurs sources n’ont pas changé.

## Échanges avec OpenAI

| Étape / trace | Données envoyées | Résultat attendu |
| --- | --- | --- |
| `ocr`, `ocr_analysis` | Image d’une page, ou texte extrait d’une ressource | Transcription fidèle ; type de document pour une ressource |
| `catalogue` | Textes reconnus, identifiants et nature des pages | Notions, exercices autonomes, liens vers les pages et illustrations utiles |
| `example_style` | Page d’un ancien contrôle | Structure, types et répartition ; pas de réutilisation de son contenu |
| `instructions` — facultatif | Catalogue et consignes personnalisées | Entrées utilisables et autorisation d’employer les exemples |
| `planning` | Catalogue sélectionné, images sources, profils des exemples, paramètres du contrôle | Questions complètes, réponses, barèmes, supports, références aux images chargées |
| `audit` | Questions à vérifier, documents tels que chargés, contexte visible des autres questions, sources justificatives cachées à l’élève | Verdicts pédagogiques, paraphrases et éventuelles réponses révélées ailleurs |
| `repair` | Questions rejetées, diagnostics, questions conservées et sources pertinentes | Réparation des questions concernées ; les autres restent conservées |
| `draft` — flashcards | Texte des leçons, paramètres et cartes déjà conservées | Cartes autonomes ; aucun document externe ni support partagé |

Les réponses utilisent un schéma JSON strict. Les identifiants de question sont attribués par l’application. OpenAI ne propose plus de rectangles : les nouvelles questions et leurs supports utilisent les images entières, telles qu’elles ont été chargées. Leur cadrage est préparé manuellement en amont, indépendamment de la génération. Les anciennes illustrations enregistrées sont conservées pour les devoirs existants et leurs reprises.

Les textes OCR et les analyses du catalogue servent à préparer le contrôle. Ils ne deviennent pas automatiquement des documents visibles pour l’élève. L’audit distingue un texte source légitime à étudier d’une paraphrase ajoutée qui réalise la lecture demandée à sa place.

L’audit ne juge plus le cadrage et ne demande aucune retouche des images. Il vérifie que la question est réalisable avec les ressources visibles, qu’elle ne paraphrase pas la lecture attendue et qu’aucun autre support ne dévoile indûment la réponse. Si une information nécessaire manque, la question doit être adaptée ou utiliser une autre ressource.

## Vérifications conservées et réparations

`AuditCache` compare le contenu des questions et le contexte visible avant de préparer les images de l’audit. Une révision explicite entre dans l’empreinte des verdicts ; l’incrémenter lorsque les règles d’audit changent invalide les validations enregistrées.

À la reprise d’un contrôle partiel évalué avec d’anciennes règles, les brouillons conservés sont d’abord réaudités avec la nouvelle révision. Les anciens diagnostics et le compteur de stagnation sont réinitialisés une seule fois ; les réparations déjà reçues priment sur leurs versions antérieures. Les contrôles terminés ne sont pas relancés.

La sélection distingue trois cas :

- Une question nouvelle, modifiée ou dont les sources ont changé reçoit un audit pédagogique complet.
- Une question inchangée dont la validation reste valable est conservée sans nouvelle appréciation de son effort ou de son barème.
- Pour une question de connaissances déjà validée, un changement du contexte visible peut nécessiter uniquement de vérifier qu’un autre énoncé ou document ne dévoile pas sa réponse. Ce contrôle ne remet pas en cause sa validation pédagogique.

Les questions conservées restent fournies comme contexte à l’auditeur, même lorsqu’aucun nouveau verdict n’est demandé pour elles. Les supports partagés des questions conservées restent protégés lors des réparations de contenu.

`RepairProgress` conserve le meilleur nombre de questions acceptées et le nombre de défauts correspondant. Deux tentatives successives sans amélioration arrêtent la boucle ; perdre puis récupérer une question ne compte pas comme un progrès. Cet état persiste entre les reprises : relancer sans changement un plan arrêté ne déclenche pas une nouvelle série d’appels. Un changement des sources ou des paramètres nécessitant un nouveau plan réinitialise cet état.

Chaque réponse de réparation est sauvegardée avant l’audit suivant. Une interruption de cet audit ne fait pas perdre le contenu déjà reçu. Les diagnostics des questions non encore revues restent disponibles. Les anciens plans dépourvus de diagnostics structurés passent d’abord par un audit de leurs brouillons conservés.

## Exécution, modèles et observabilité

- Les appels passent par `POST https://api.openai.com/v1/responses`, avec `store: false` et `text.format.type: "json_schema"` en mode strict.
- Le modèle de génération est configurable par `OPENAI_MODEL` ; la valeur par défaut du code est `gpt-5.4`. OCR, catalogue, planification, réparation et audit utilisent ce réglage.
- `OPENAI_FLASHCARD_MODEL`, par défaut `gpt-5.4-mini`, sert à la **correction des réponses aux flashcards**, pas à leur génération. La correction des réponses de l’élève intervient après le workflow représenté ici.
- `GenerationJobs` exécute la génération en tâche supervisée. Le délai global est configurable ; sa valeur par défaut est de dix minutes. Une interruption conserve le dernier point de reprise.
- `ai_calls` enregistre étape, contrôle, modèle, durée, statut, nombre d’images, consommation de tokens et motif d’interruption. Cette table ne contient ni prompts, ni réponses complètes, ni secrets.
- Phoenix PubSub informe la LiveView de l’avancement et des questions disponibles.

## Correspondance avec le code

| Responsabilité | Module / fichier |
| --- | --- |
| Import et OCR des ressources | [`Resources`](../lib/captain_homework/resources.ex) |
| Catalogue et sélection des sources | [`Catalogues`](../lib/captain_homework/catalogues.ex) |
| Style des exemples | [`ExampleStyles`](../lib/captain_homework/example_styles.ex) |
| Création et reprise d’un contrôle | [`Exams`](../lib/captain_homework/exams.ex) |
| Orchestration et points de reprise | [`Exams.Generation`](../lib/captain_homework/exams/generation.ex) |
| Tâches et délai global | [`Exams.GenerationJobs`](../lib/captain_homework/exams/generation_jobs.ex) |
| Validations réutilisables et arrêt sans progrès | [`AuditCache`](../lib/captain_homework/exams/audit_cache.ex), [`RepairProgress`](../lib/captain_homework/exams/repair_progress.ex) |
| Images visibles et compatibilité des anciens cadrages | [`AI.VisibleImages`](../lib/captain_homework/ai/visible_images.ex), [`ImageCrops`](../lib/captain_homework/image_crops.ex) |
| Contrats et appels OpenAI | [`AI.OpenAI`](../lib/captain_homework/ai/open_ai.ex), [`AI.QuestionContract`](../lib/captain_homework/ai/question_contract.ex) |
| Mesures des appels | [`AI.Trace`](../lib/captain_homework/ai/trace.ex) |
