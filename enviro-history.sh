#!/bin/bash
#
# enviro-history.sh - historisation + graphes pour Enviro Mini Dashboard
#
# Poll le endpoint /data d'une sonde Enviro Mini, historise en CSV plain text
# (append-only, ni compression ni purge), et regenere des graphes gnuplot
# 24h / 7j / 30j / 1an pour chaque metrique, servis par Apache.
#
# Sonde      : https://github.com/deuza/enviromini_dashboard  (expose /data en JSON)
# Cron (crontab root, pas de sudo) :
#   */5 * * * * /opt/enviro-history/enviro-history.sh >> /var/log/enviro-history.log 2>&1
#
set -euo pipefail

# --------------------------------------------------------------------- config
NODE_URL="${NODE_URL:-http://192.168.1.50}"        # IP de la sonde, A ADAPTER ; http://localhost en self-poll
NODE_NAME="${NODE_NAME:-enviro}"                   # cle CSV (utile si plusieurs sondes)
DATA_DIR="${DATA_DIR:-/var/lib/enviro-history}"    # ou vivent les CSV
OUTPUT_DIR="${OUTPUT_DIR:-/var/www/html/enviro}"   # docroot Apache du dashboard -> A ADAPTER
CURL_TIMEOUT="${CURL_TIMEOUT:-5}"
GRAPH_W="${GRAPH_W:-880}"
GRAPH_H="${GRAPH_H:-420}"

CSV="${DATA_DIR}/${NODE_NAME}.csv"
# Schema collecte depuis /data : tout l'environnemental, hors temp CPU et flags.
# La temperature est DEJA compensee = temperature de la piece (pas le CPU).
HEADER="timestamp,temperature,temp_raw,pressure_hpa,humidity,lux,proximity,noise_amp"

# Graphes a produire : field|col|label|unite|couleur|ymin|ymax
#   col       = index de la colonne dans le CSV (1 = timestamp)
#   ymin|ymax = plage Y fixe ; laisser vide ("||") pour un calage auto serre
# Commenter une ligne retire son graphe : la donnee reste collectee dans le CSV.
METRICS=(
  "temperature|2|Temperature piece|deg C|#db6d28|15|45"
  "pressure_hpa|4|Pression|hPa|#bc8cff||"
  "humidity|5|Humidite|%|#58a6ff||"
  # "lux|6|Lumiere|lux|#d29922||"
  # "noise_amp|8|Bruit (relatif)|amp|#3fb950||"
  # "temp_raw|3|Temp brute BME280|deg C|#8b949e||"
  # "proximity|7|Proximite|-|#bc8cff||"
)
# fenetre : key|secondes|format_x|pas_x|libelle
WINDOWS=(
  "day|86400|%Hh|10800|24 heures"
  "week|604800|%a %d|86400|7 jours"
  "month|2592000|%d/%m|604800|30 jours"
  "year|31536000|%d/%m|2592000|1 an"
)

# ----------------------------------------------------------------------- init
mkdir -p "$DATA_DIR" "$OUTPUT_DIR"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
[ -f "$CSV" ] || echo "$HEADER" > "$CSV"

# ------------------------------------------------------------- poll + append
NOW="$(date +%s)"
if ! JSON="$(curl -fsS --max-time "$CURL_TIMEOUT" "${NODE_URL}/data" 2>/dev/null)"; then
  echo "[enviro-history] poll KO : ${NODE_URL}/data injoignable" >&2
  exit 1
fi

if [ "$(printf '%s' "$JSON" | jq -r '.demo')" = "true" ]; then
  echo "[enviro-history] sonde en mode DEMO (capteurs absents), pas d'historisation" >&2
  exit 0
fi

VALUES="$(printf '%s' "$JSON" | jq -r \
  '[.temperature,.temp_raw,.pressure_hpa,.humidity,.lux,.proximity,.noise_amp]
   | map(if . == null then "NaN" else tostring end) | join(",")')"
echo "${NOW},${VALUES}" >> "$CSV"

# ------------------------------------------------------------------- graphes
for m in "${METRICS[@]}"; do
  IFS='|' read -r field col label unit color fymin fymax <<< "$m"
  for w in "${WINDOWS[@]}"; do
    IFS='|' read -r wkey wsecs xfmt xstep wlabel <<< "$w"
    start="$((NOW - wsecs))"
    data="${WORKDIR}/${field}_${wkey}.dat"

    awk -F',' -v s="$start" -v c="$col" \
      'NR>1 && $1>=s && $c!="NaN" {print $1, $c}' "$CSV" > "$data"
    [ -s "$data" ] || continue

    stats="$(awk 'NR==1{mn=mx=$2}
                  {sum+=$2; if($2<mn)mn=$2; if($2>mx)mx=$2; last=$2}
                  END{printf "%.2f %.2f %.2f %.2f", mn, mx, sum/NR, last}' "$data")"
    read -r vmin vmax vavg vlast <<< "$stats"

    if [ -n "$fymin" ] && [ -n "$fymax" ]; then
      ylo="$fymin"; yhi="$fymax"
    else
      read -r ylo yhi <<< "$(awk -v a="$vmin" -v b="$vmax" 'BEGIN{
        r=b-a; if(r<=0){pad=(a<0?-a:a)*0.05; if(pad<=0)pad=1} else pad=r*0.08;
        printf "%.4f %.4f", a-pad, b+pad}')"
    fi

    out="${OUTPUT_DIR}/${field}_${wkey}.png"
    if ! gnuplot 2>/dev/null <<GP
set terminal pngcairo size ${GRAPH_W},${GRAPH_H} enhanced font "DejaVu Sans,9" background rgb "#0d1117"
set output "${out}"
set xdata time
set timefmt "%s"
set xrange [${start}:${NOW}]
set format x "${xfmt}"
set xtics ${xstep} tc rgb "#8b949e"
set ytics tc rgb "#8b949e"
set grid xtics ytics back lc rgb "#30363d" lw 1
set border 3 lc rgb "#30363d" lw 1
set tics nomirror
set yrange [${ylo}:${yhi}]
set ylabel "${unit}" tc rgb "#e6edf3"
set title "${label} - ${wlabel}" tc rgb "#58a6ff" font "DejaVu Sans,12"
set key off
set object 1 rectangle from graph 0,0 to graph 1,1 behind fc rgb "#161b22" fs solid 1.0 noborder
set label 1 "Actuel: ${vlast} ${unit}      Min: ${vmin}      Max: ${vmax}      Moyenne: ${vavg}" at screen 0.5,0.04 center tc rgb "#8b949e" font "DejaVu Sans,9"
set bmargin 5
plot "${data}" using 1:2 with filledcurves y1=${ylo} lc rgb "${color}" fs transparent solid 0.25 notitle, \
     "" using 1:2 with lines lc rgb "${color}" lw 2 notitle
GP
    then
      echo "[enviro-history] gnuplot KO pour ${field}/${wkey}" >&2
    fi
  done
done

# ---------------------------------------------------------------------- html
GEN_HUMAN="$(date -d "@${NOW}" '+%Y-%m-%d %H:%M:%S %Z')"
{
  cat <<'HTMLHEAD'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Enviro Mini - Historique</title>
<style>
:root{--bg:#0d1117;--card:#161b22;--border:#30363d;--text:#e6edf3;--muted:#8b949e;--accent:#58a6ff}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:'Courier New',monospace;padding:1rem}
header{display:flex;align-items:center;gap:.75rem;flex-wrap:wrap;margin-bottom:1rem;padding-bottom:.75rem;border-bottom:1px solid var(--border)}
h1{font-size:1.1rem;color:var(--accent)}
#upd{margin-left:auto;font-size:.72rem;color:var(--muted)}
.tabs{display:flex;gap:.5rem;margin-bottom:1rem;flex-wrap:wrap}
.tab{font-family:inherit;font-size:.8rem;cursor:pointer;padding:.4rem .9rem;border-radius:6px;border:1px solid var(--border);background:var(--card);color:var(--muted)}
.tab.active{border-color:var(--accent);color:var(--accent)}
.period{display:none;grid-template-columns:repeat(2,1fr);gap:1rem}
.period.active{display:grid}
@media (max-width:900px){.period.active{grid-template-columns:1fr}}
.period img{width:100%;height:auto;border:1px solid var(--border);border-radius:8px;display:block}
footer{margin-top:1.25rem;padding-top:.75rem;border-top:1px solid var(--border);font-size:.72rem;color:var(--muted)}
footer a{color:var(--accent)}
</style>
</head>
<body>
<header>
<h1>&#127807; Enviro Mini &mdash; Historique</h1>
HTMLHEAD

  echo "<span id=\"upd\">maj : ${GEN_HUMAN}</span>"
  echo "</header>"

  echo '<div class="tabs">'
  first=1
  for w in "${WINDOWS[@]}"; do
    IFS='|' read -r -a wf <<< "$w"
    cls="tab"; [ "$first" -eq 1 ] && cls="tab active"
    echo "<button class=\"${cls}\" data-period=\"${wf[0]}\">${wf[4]}</button>"
    first=0
  done
  echo '</div>'

  first=1
  for w in "${WINDOWS[@]}"; do
    IFS='|' read -r -a wf <<< "$w"
    cls="period"; [ "$first" -eq 1 ] && cls="period active"
    echo "<div class=\"${cls}\" id=\"p-${wf[0]}\">"
    for m in "${METRICS[@]}"; do
      IFS='|' read -r -a mf <<< "$m"
      echo "<img src=\"${mf[0]}_${wf[0]}.png?v=${NOW}\" alt=\"${mf[0]} ${wf[0]}\">"
    done
    echo "</div>"
    first=0
  done

  cat <<'HTMLFOOT'
<footer>Pimoroni Enviro Mini &middot; historisation CSV + gnuplot &middot; <a href="https://github.com/deuza/enviromini_dashboard">enviromini_dashboard</a></footer>
<script>
"use strict";
document.querySelectorAll('.tab').forEach(function(b){
  b.addEventListener('click', function(){
    var p = b.getAttribute('data-period');
    document.querySelectorAll('.tab').forEach(function(x){ x.classList.remove('active'); });
    document.querySelectorAll('.period').forEach(function(x){ x.classList.remove('active'); });
    b.classList.add('active');
    document.getElementById('p-' + p).classList.add('active');
  });
});
</script>
</body>
</html>
HTMLFOOT
} > "${OUTPUT_DIR}/index.html"

points="$(($(wc -l < "$CSV") - 1))"
echo "[enviro-history] OK ${GEN_HUMAN} - ${points} points - ${OUTPUT_DIR}/index.html"
