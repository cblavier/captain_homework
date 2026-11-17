# Captures de Captain Homework

Dix vues de l’interface réelle, capturées dans Chromium avec Playwright le 5 novembre 2026.

Le seul enfant est **Alice**, en **6B au collège Jules Ferry**, avec un portrait fictif repris de Captain Notes. Les exemples de géométrie, d’histoire-géographie et d’anglais proviennent d’une copie locale anonymisée des leçons et contrôles. La base et les fichiers d’origine restent inchangés.

La génération de quatre questions est un **état de démonstration enregistré**, sans appel IA : deux questions prêtes, une en vérification et une en rédaction. La création de leçon montre deux photos sélectionnées, avant validation du formulaire.

- `originaux/alice/` : captures PNG sans cadre.
- `alice/` : versions encadrées affichées dans le README.
- `portraits/alice.png` : portrait fictif.
- `frame.py` : régénère les cadres à partir des originaux avec ImageMagick, sans modifier leur contenu.
- `alice-screenshots.zip` : archive locale des images finales et des captures complémentaires, ignorée par Git.

Les viewports sont de 1440 × 1100 sur desktop et 430 × 932 sur mobile. Le contrôle et sa correction utilisent 1440 × 1400 pour montrer le dépôt de photo et la correction.

La correction d’histoire-géographie utilise un viewport de 1440 × 1920 pour afficher la note de 14/20, l’appréciation, la définition correcte avec correction orthographique et le QCM illustré erroné. Ses réponses et sa notation sont des données de démonstration cohérentes (14 points sur 20), sans appel IA.

Aucun secret, compte réel, base de données ou fichier de session n’est versionné avec les captures.

Capture complémentaire du 12 novembre 2026 : `desktop-evaluations-partagees.png`, page réelle sur une copie isolée de la base de tests, avec Alice et deux partages de démonstration (statuts enregistrés sans appel IA).


Captures complémentaires du 13 novembre 2026, après la refonte des pages de leçons et de ressources :

- `desktop-refonte-galerie.png` : galerie de trois pages nommées.
- `desktop-refonte-page.png` : détail d’une page, texte reconnu et illustration extraite.
- `mobile-refonte-page.png` : même détail sur mobile.

Ces trois vues proviennent de l’interface réelle dans une copie isolée et vidée de toute donnée réelle. Alice est le seul profil. Le texte et les schémas de cellule sont des données de démonstration enregistrées, sans appel IA. Les captures utilisent les largeurs de 1440 et 430 pixels et conservent toute la hauteur du contenu. Les PNG bruts sont conservés dans `originaux/alice/` et les images encadrées dans `alice/`.
