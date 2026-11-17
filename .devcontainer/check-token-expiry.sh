#!/bin/bash
# Avertit (stderr) quand le jeton GitHub (GH_TOKEN) est expiré ou expire bientôt.
# Jamais bloquant : sans jeton, sans réseau, ou sans date d'expiration (PAT classique
# sans expiration), le script se tait et sort avec 0. Le jeton n'est jamais affiché.
#   CLAUDEUS_TOKEN_WARN_DAYS : seuil d'alerte en jours (défaut 7)
WARN_DAYS="${CLAUDEUS_TOKEN_WARN_DAYS:-7}"
[[ "$WARN_DAYS" =~ ^[0-9]+$ ]] || WARN_DAYS=7
[ -n "${GH_TOKEN:-}" ] || exit 0

resp=$(timeout 10 gh api -i user 2>/dev/null | tr -d '\r') || true
[ -n "$resp" ] || exit 0

status=$(printf '%s\n' "$resp" | sed -n '1s/^HTTP[^ ]* \([0-9][0-9]*\).*/\1/p')
if [ "$status" = 401 ]; then
    echo "AVERTISSEMENT : le jeton GitHub (GH_TOKEN) est refusé (invalide, expiré ou révoqué) : les opérations GitHub vont échouer. Générez-en un nouveau." >&2
    exit 0
fi

# En-tête présent uniquement pour les jetons qui expirent, ex. « 2026-12-01 10:00:00 UTC ».
exp=$(printf '%s\n' "$resp" | sed -n 's/^github-authentication-token-expiration: *//Ip' | head -n1)
[ -n "$exp" ] || exit 0
exp_s=$(date -d "$exp" +%s 2>/dev/null) || exit 0

days=$(( (exp_s - $(date +%s)) / 86400 ))
if [ "$exp_s" -le "$(date +%s)" ]; then
    echo "AVERTISSEMENT : le jeton GitHub (GH_TOKEN) a expiré le $exp." >&2
elif [ "$days" -le "$WARN_DAYS" ]; then
    echo "AVERTISSEMENT : le jeton GitHub (GH_TOKEN) expire dans $days jour(s) (le $exp). Pensez à le renouveler." >&2
fi
exit 0
