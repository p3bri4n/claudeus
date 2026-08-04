#!/bin/bash
# Firewall egress : politique DROP par défaut, whitelist stricte.
# Basé sur le script de référence anthropics/claude-code, adapté pour
# le dev Python/ML (PyPI, Hugging Face ajoutés).
set -euo pipefail
IFS=$'\n\t'

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

# ipset avec support CIDR
ipset create allowed-domains hash:net

# Plages IP GitHub (web + api + git)
echo "Récupération des plages IP GitHub..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERREUR : impossible de récupérer les plages IP GitHub"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERREUR : réponse GitHub incomplète"
    exit 1
fi

echo "Ajout des plages GitHub..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERREUR : CIDR invalide depuis GitHub meta : $cidr"
        exit 1
    fi
    ipset add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

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
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done < <(echo "$ips")
done

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
