#!/bin/bash
# Firewall egress : politique DROP par défaut, whitelist stricte.
# Basé sur le script de référence anthropics/claude-code, adapté pour
# le dev Python/ML (PyPI, Hugging Face ajoutés).
set -euo pipefail
IFS=$'\n\t'

# Deux modes :
#  - premier démarrage : politique DROP + règles + ipset (tout ci-dessous) ;
#  - relance en session (règles déjà en place) : on ne touche NI aux règles NI à
#    celles de dockerd ; on reconstruit seulement l'ipset dans un ensemble neuf
#    puis on l'échange atomiquement. Pas de fenêtre ouverte, pas de blocage : le
#    flush complet coupait l'accès à api.github.com avant de le relire, et
#    supprimait les chaînes de dockerd.
SET=allowed-domains
REFRESH=0
if ipset list allowed-domains >/dev/null 2>&1 && iptables -S OUTPUT 2>/dev/null | grep -q -- '--match-set allowed-domains'; then
    REFRESH=1
    SET=allowed-domains-new
    ipset destroy "$SET" 2>/dev/null || true
    trap 'ipset destroy allowed-domains-new 2>/dev/null || true' EXIT
    echo "Règles déjà en place : rafraîchissement de l'ipset uniquement"
fi

if [ "$REFRESH" = 0 ]; then
# 1. Sauvegarder les règles DNS internes de Docker AVANT le flush
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush des règles existantes
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Restaurer uniquement la résolution DNS interne Docker
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restauration des règles DNS Docker..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "Pas de règles DNS Docker à restaurer"
fi

# DNS et localhost autorisés avant toute restriction
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
# SSH sortant (git via ssh)
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
# Localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

fi  # fin du bloc premier démarrage

# ipset avec support CIDR
ipset create "$SET" hash:net

# Plages IP GitHub (web + api + git)
# api.github.com/meta est limité à 60 requêtes/heure par IP sans authentification
# (le script tourne sous sudo : GH_TOKEN n'y est pas transmis). Quota épuisé =
# réponse « rate limit » : au premier démarrage on s'arrête avec un message clair ;
# en relance on garde les plages GitHub de l'ipset actuel plutôt que d'échouer.
# Source préférée : fichier lu et validé sur l'hôte par claudeus, monté en lecture
# seule (pas d'appel réseau, pas de quota, non modifiable par l'agent).
GITHUB_META_FILE=/usr/local/etc/github-meta.json
if [ -s "$GITHUB_META_FILE" ]; then
    echo "Plages IP GitHub : lues depuis $GITHUB_META_FILE (fourni par l'hôte)"
    gh_ranges=$(cat "$GITHUB_META_FILE")
else
    echo "Récupération des plages IP GitHub..."
    gh_ranges=$(curl -s --connect-timeout 10 --max-time 30 https://api.github.com/meta || true)
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
    gh_msg=$(echo "$gh_ranges" | jq -r '.message // empty' 2>/dev/null | sed -E 's/ for [0-9a-fA-F.:]+//' | cut -c1-60 || true)
    if [ "$REFRESH" = 1 ]; then
        echo "AVERTISSEMENT : plages GitHub non rafraîchies (${gh_msg:-réponse vide ou incomplète}) ; plages de l'ipset actuel conservées"
        while read -r cidr; do
            ipset add "$SET" "$cidr" 2>/dev/null || true
        done < <(ipset save allowed-domains | awk '$1=="add" && $3 ~ /\// {print $3}')
        gh_ranges=""
    else
        echo "ERREUR : impossible de lire les plages IP GitHub (${gh_msg:-réponse vide ou incomplète})"
        exit 1
    fi
fi

if [ -n "$gh_ranges" ]; then
    echo "Ajout des plages GitHub..."
    while read -r cidr; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo "ERREUR : CIDR invalide depuis GitHub meta : $cidr"
            exit 1
        fi
        ipset add "$SET" "$cidr"
    done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)
fi

# Domaines autorisés — lus depuis URL_whitelist.yml (édition à chaud, pas de
# rebuild d'image nécessaire : voir ce fichier pour le format).
WHITELIST_FILE="${WHITELIST_FILE:-/usr/local/etc/url-whitelist.yml}"
if [ ! -f "$WHITELIST_FILE" ]; then
    echo "ERREUR : fichier de whitelist introuvable : $WHITELIST_FILE"
    exit 1
fi

parse_yaml_list() {
    local key="$1" file="$2"
    awk -v key="$key" '
        $0 ~ "^"key":" { flag=1; next }
        /^[^ \t#]/ { flag=0 }
        flag && /^[ \t]*-/ { print }
    ' "$file" | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]*#.*$//; s/^"(.*)"$/\1/' | grep -v '^[[:space:]]*$'
}

required_domains=()
while IFS= read -r line; do required_domains+=("$line"); done < <(parse_yaml_list "domains" "$WHITELIST_FILE")
optional_domains=()
while IFS= read -r line; do optional_domains+=("$line"); done < <(parse_yaml_list "optional_domains" "$WHITELIST_FILE")

for entry in "${required_domains[@]}" $(printf '%s:optional\n' "${optional_domains[@]}"); do
    domain="${entry%%:*}"
    optional=""
    [[ "$entry" == *":optional" ]] && optional=1

    echo "Résolution de $domain..."
    # dig +short suit les CNAME et renvoie les IP finales ;
    # on ne garde que les IPv4 (les CNAME intermédiaires sont ignorés)
    ips=$(dig +short A "$domain" | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || true)
    if [ -z "$ips" ]; then
        if [ -n "$optional" ]; then
            echo "AVERTISSEMENT : résolution impossible pour $domain (optionnel, ignoré)"
            continue
        fi
        echo "ERREUR : résolution impossible pour $domain"
        exit 1
    fi

    while read -r ip; do
        echo "Ajout de $ip pour $domain"
        ipset add "$SET" "$ip" 2>/dev/null || true
    done < <(echo "$ips")
done

if [ "$REFRESH" = 1 ]; then
    ipset swap allowed-domains-new allowed-domains
    ipset destroy allowed-domains-new
    trap - EXIT
    echo "ipset allowed-domains rafraîchi"
else
# IP de l'hôte via la route par défaut
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERREUR : IP hôte introuvable"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Réseau hôte détecté : $HOST_NETWORK"

iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Politique par défaut : tout bloquer
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Connexions déjà établies
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Sortant autorisé uniquement vers la whitelist
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Tout le reste : REJECT explicite (feedback immédiat plutôt que timeout)
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

fi  # fin du bloc premier démarrage

# Empreintes lues par « claudeus selftest » (node ne peut pas lire iptables) :
# - rules : hashes par chaîne gérée (OUTPUT, INPUT, DOCKER-USER, politique FORWARD)
# - whitelist : hash du fichier de whitelist réellement utilisé
# L'empreinte de référence (état complet après init-firewall-dind.sh) est écrite par
# ce dernier dans /run, root only en écriture : une relance ne la remplace pas, on
# peut ainsi prouver qu'elle ne modifie pas les règles.
# Seules les chaînes que NOUS gérons sont empreintées : dockerd modifie les siennes
# (DOCKER, bridge, FORWARD) à son rythme, ce qui rendait la comparaison intermittente.
fp_chain() { iptables -S "$1" 2>/dev/null | sha256sum | cut -c1-8; }
RULES_HASH="out=$(fp_chain OUTPUT),in=$(fp_chain INPUT),du=$(fp_chain DOCKER-USER),fwd=$(iptables -S FORWARD 2>/dev/null | head -1 | sha256sum | cut -c1-8)"
WL_HASH=$(sha256sum "$WHITELIST_FILE" | cut -c1-16)
echo "FIREWALL_FINGERPRINT rules=$RULES_HASH whitelist=$WL_HASH"

echo "Configuration firewall terminée"
echo "Vérification..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERREUR : example.com joignable, le firewall ne fonctionne pas"
    exit 1
else
    echo "OK : example.com bloqué comme attendu"
fi

if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERREUR : api.github.com injoignable"
    exit 1
else
    echo "OK : api.github.com joignable comme attendu"
fi
