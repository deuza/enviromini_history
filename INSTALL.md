# Installation

Installation de **enviro-history** sur la machine qui heberge le dashboard (Debian, teste sous Trixie, avec Apache2 deja en service).

> Les etapes ci-dessous demandent les privileges root (session root, ou `sudo` devant chaque commande).

## Prerequis

- Une sonde faisant tourner [enviromini_dashboard](https://github.com/deuza/enviromini_dashboard), joignable et exposant `/data`. Verifier avec `curl http://<ip-sonde>/data`
- Debian (teste sous Trixie) avec Apache2 deja en service
- Privileges root sur la machine du dashboard

## 1. Dependances

```sh
apt install jq gnuplot-nox fonts-dejavu-core curl
```

`gnuplot-nox` est la variante sans X (suffisante, le rendu PNG passe par cairo). `fonts-dejavu-core` fournit la police des graphes, `jq` parse le JSON et `curl` interroge la sonde.

## 2. Recuperer le script

```sh
git clone https://github.com/deuza/enviromini_history.git
mkdir -p /opt/enviro-history
cp enviromini_history/enviro-history.sh /opt/enviro-history/
chmod +x /opt/enviro-history/enviro-history.sh
```

## 3. Configuration

Les reglages sont en tete du fichier, a editer :

```sh
vi /opt/enviro-history/enviro-history.sh
```

A regler au minimum :

- `NODE_URL` : l'adresse de la sonde (par exemple `http://192.168.1.50`), ou `http://localhost` si le script tourne sur la sonde elle-meme
- `OUTPUT_DIR` : le dossier servi par Apache ou la page sera publiee

Le tableau complet des variables est dans le [README](README.md#configuration).

## 4. Apache

Le script depose directement ses fichiers (PNG + `index.html`) dans `OUTPUT_DIR`. Il suffit donc que ce dossier soit servi par Apache : le placer sous le docroot, par exemple `/var/www/html/enviro`, rend la page accessible a `http://<serveur>/enviro/`. Aucun vhost ni alias a creer, et aucun reglage fin : on ne sert que du statique.

## 5. Premier run manuel

Avant le cron, un test a la main pour verifier que tout sort. Le script lit sa config interne ; elle peut aussi etre surchargee par variables d'environnement :

```sh
NODE_URL="http://192.168.1.50" OUTPUT_DIR="/var/www/html/enviro" \
  /opt/enviro-history/enviro-history.sh
```

Une ligne `[enviro-history] OK ...` doit apparaitre sur la sortie standard (un lancement manuel n'ecrit pas de fichier log, voir l'etape suivante). Verifier ensuite la presence des PNG et de la page :

```sh
ls /var/www/html/enviro/
```

Puis ouvrir `http://<serveur>/enviro/` dans un navigateur. Au premier run les courbes sont tres courtes (un ou deux points colles a droite), c'est normal, elles se remplissent avec le temps.

## 6. Cron

Collecte toutes les 5 minutes. **Attention au format selon l'emplacement de l'entree** : la crontab utilisateur n'a pas de champ utilisateur, les crontabs systeme (`/etc/crontab`, `/etc/cron.d/`) en ont un.

Le fichier log n'est cree que par la redirection `>> ... 2>&1` de la ligne cron. Sans elle, la sortie du script part dans le mail de l'utilisateur (ou dans le vide).

**Option A - crontab utilisateur** (`crontab -e` de l'utilisateur qui doit lancer le job) :

```cron
*/5 * * * * /opt/enviro-history/enviro-history.sh >> /var/log/enviro-history.log 2>&1
```

**Option B - crontab systeme** (`/etc/crontab` ou un fichier dans `/etc/cron.d/`). Noter le champ utilisateur en plus (ici `root`) :

```cron
*/5 * * * * root /opt/enviro-history/enviro-history.sh >> /var/log/enviro-history.log 2>&1
```

## 7. Logs

```sh
tail -f /var/log/enviro-history.log
```

Verifier que cron lance bien le job :

```sh
journalctl -u cron --since "20 min ago"
```

## Depannage

| Symptome                                     | Piste                                                                                            |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `poll KO : ... injoignable`                  | la sonde ne repond pas. Tester `curl http://<ip-sonde>/data`.                                     |
| `sonde en mode DEMO ... pas d'historisation` | capteurs absents cote sonde ; rien n'est historise (comportement voulu).                         |
| Graphe vide ou quasi vide                    | un ou deux points seulement, colles a droite. Normal au demarrage.                               |
| Police moche ou carres dans les graphes      | `fonts-dejavu-core` manquant : `apt install fonts-dejavu-core`.                                  |
| `jq: command not found`                      | `apt install jq`.                                                                                |
| La page ne se charge pas                     | `OUTPUT_DIR` n'est pas sous un dossier servi par Apache. Voir etape 4.                            |
| Pas de fichier log                           | redirection `>> ...` absente de la ligne cron, ou (crontab systeme) champ utilisateur manquant.  |
