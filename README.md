# Enviro Mini History

[![Built With Love](https://img.shields.io/badge/built%20with-%E2%9D%A4%20by%20DeuZa-red?style=plastic)](#)         
[![Hack The Planet](https://img.shields.io/badge/hack-the--planet-black?style=plastic&logo=gnu&logoColor=white)](#)

Historisation et graphes pour le **[Enviro Mini Dashboard](https://github.com/deuza/enviromini_dashboard)**. Un seul script Bash, lance par cron, qui interroge le endpoint `/data` JSON d'une sonde, historise les mesures en **CSV plain text** (append-only, ni base de donnees ni compression), et regenere des graphes **gnuplot** sur **24h / 7 jours / 30 jours / 1 an**, servis en statique par Apache.

Pensee KISS : aucune dependance lourde, la donnee reste un fichier texte greppable, et la page web n'embarque qu'un selecteur de periode en quelques lignes de JS.

![Dashboard Enviro Mini History](screenshot.png)

## Principe

```
  sonde Enviro Mini                 serveur du dashboard (Debian + Apache)
  (enviromini_dashboard)
  +------------------+              +-----------------------------------+
  |   expose /data   |   HTTP GET   | cron */5 -> enviro-history.sh     |
  |   en JSON        | <----------- |   1. curl /data                   |
  |                  |   JSON       |   2. append CSV (plain text)      |
  +------------------+              |   3. gnuplot -> PNG 24h/7j/30j/1an |
                                    |   4. index.html (selecteur)       |
                                    +-----------------------------------+
                                              | Apache sert le statique
                                              v
                                    http://<serveur>/enviro/
```

La sonde n'est jamais modifiee : elle continue d'exposer son `/data` en live. Toute l'historisation vit sur la machine du dashboard, qui peut d'ailleurs etre la sonde elle-meme en self-poll (`NODE_URL=http://localhost`).

## Donnees collectees

Le CSV chope tout l'environnemental renvoye par la sonde (hors temperature CPU et flags internes). La colonne `timestamp` est l'epoch Unix du poll.

| Colonne        | Source `/data`  | Description                                    |
| -------------- | --------------- | ---------------------------------------------- |
| `timestamp`    | (heure du poll) | epoch Unix                                     |
| `temperature`  | `temperature`   | temperature de la piece, **deja compensee**    |
| `temp_raw`     | `temp_raw`      | lecture brute du BME280 (lit plus chaud)       |
| `pressure_hpa` | `pressure_hpa`  | pression (hPa)                                 |
| `humidity`     | `humidity`      | humidite relative (%)                          |
| `lux`          | `lux`           | luminosite (lux)                               |
| `proximity`    | `proximity`     | proximite LTR-559                              |
| `noise_amp`    | `noise_amp`     | niveau sonore (amplitude relative, pas des dB) |

Une valeur nulle cote JSON (micro coupe par exemple) est ecrite `NaN` et simplement sautee au trace.

## Graphes et metriques

Ce qui est **graphe** est pilote par le tableau `METRICS` en tete du script, decouple de la collecte. Commenter une ligne retire son graphe ; la donnee reste collectee dans le CSV. Comme le schema du CSV est fige, commenter ou decommenter ne decale jamais les index de colonnes.

Format d'une ligne : `field|col|label|unite|couleur|ymin|ymax`

- `col` : index de la colonne dans le CSV (1 = `timestamp`)
- `ymin|ymax` : plage Y fixe ; laisser vide (`||`) pour un calage automatique serre sur les donnees

Exemple par defaut :

```sh
METRICS=(
  "temperature|2|Temperature piece|deg C|#db6d28|15|45"   # axe fixe 15-45
  "pressure_hpa|4|Pression|hPa|#bc8cff||"                 # calage auto
  "humidity|5|Humidite|%|#58a6ff||"
  # "lux|6|Lumiere|lux|#d29922||"                         # decommente pour grapher
  # "noise_amp|8|Bruit (relatif)|amp|#3fb950||"
  # "temp_raw|3|Temp brute BME280|deg C|#8b949e||"
  # "proximity|7|Proximite|-|#bc8cff||"
)
```

Chaque metrique active produit 4 PNG (24h, 7j, 30j, 1 an). La page `index.html` les regroupe avec un selecteur de periode.

## Prerequis

- Une sonde faisant tourner [enviromini_dashboard](https://github.com/deuza/enviromini_dashboard) et exposant `/data`
- Une machine Debian (teste sous **Trixie**) avec **Apache2** deja en place
- `jq`, `gnuplot`, `curl` (voir [INSTALL.md](INSTALL.md))

## Installation

Voir **[INSTALL.md](INSTALL.md)** pour le pas a pas (dependances, cron, Apache).

## Configuration

Reglages en tete du script, surchargeables aussi par variable d'environnement (`VAR=... ./enviro-history.sh`) :

| Variable       | Exemple                   | Role                                                |
| -------------- | ------------------------- | --------------------------------------------------- |
| `NODE_URL`     | `http://<ip-sonde>`       | URL de la sonde ; `http://localhost` en self-poll   |
| `NODE_NAME`    | `enviro`                  | cle du CSV (utile si plusieurs sondes)              |
| `DATA_DIR`     | `/var/lib/enviro-history` | ou vivent les CSV                                   |
| `OUTPUT_DIR`   | `/var/www/html/enviro`    | docroot Apache du dashboard (**a adapter**)         |
| `CURL_TIMEOUT` | `5`                       | timeout du poll (s)                                 |
| `GRAPH_W`      | `880`                     | largeur des PNG                                     |
| `GRAPH_H`      | `420`                     | hauteur des PNG                                     |

## Plusieurs sondes

`NODE_NAME` sert de cle : chaque sonde a son propre CSV `${DATA_DIR}/${NODE_NAME}.csv`. Pour un parc, soit une entree de cron par sonde (chacune avec ses `NODE_URL` / `NODE_NAME` / `OUTPUT_DIR`), soit on adapte le script pour boucler sur une liste de sondes. Schema de nommage suggere cote sonde : `enviro-<piece>` (salon, bureau, exterieur...).

## Notes

- **Au demarrage les graphes sont clairsemes.** Ils se garnissent au fil de la collecte : le 24h est lisible apres quelques heures, l'annee se remplit sur la duree. Tant qu'il n'y a qu'un ou deux points, ils sont colles a droite et la courbe est quasi invisible, c'est normal.
- **Pas de purge ni de compression**, volontairement. A 5 min de cadence, une annee de toutes les metriques pese environ 5 Mo de texte. Le CSV reste lisible et greppable.
- **La compensation n'est pas refaite ici.** La sonde fournit deja `temperature` compensee (temperature de la piece) ; le script ne fait que l'enregistrer telle quelle.
- Tous les graphes sont regeneres a chaque run. Throttler les fenetres longues (mois / annee moins souvent) est trivial a ajouter via le mtime des PNG si le besoin se presente.

## Licence

[![Licence WTFPL](https://img.shields.io/badge/Licence-WTFPL-b06cff?style=flat-square)](http://www.wtfpl.net/) WTFPL (Do What The Fuck You Want To Public License), version 2. Identifiant SPDX : `WTFPL`.

## Construit avec

- [gnuplot](http://www.gnuplot.info/) - generation des graphes
- [jq](https://github.com/jqlang/jq) - parsing du JSON `/data`
- [Apache HTTP Server](https://httpd.apache.org/) - service du statique
- [enviromini_dashboard](https://github.com/deuza/enviromini_dashboard) - la sonde
