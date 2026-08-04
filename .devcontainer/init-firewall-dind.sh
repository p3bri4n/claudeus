#!/bin/bash
# Étend la whitelist egress au trafic des conteneurs imbriqués (Docker-in-Docker
# via sysbox). Le dockerd interne route ce trafic par la chaîne FORWARD, pas
# OUTPUT — init-firewall.sh (qui filtre OUTPUT) ne le couvre donc pas.
#
# DOCKER-USER est la chaîne que Docker évalue en premier dans FORWARD, avant
# ses propres règles ACCEPT permissives pour le bridge docker0 : c'est le
# point d'insertion prévu pour ce genre de restriction.
#
# Prérequis : init-firewall.sh a déjà tourné (ipset allowed-domains existant)
# et le dockerd interne est démarré (chaîne DOCKER-USER créée par lui).
set -euo pipefail

if ! ipset list allowed-domains >/dev/null 2>&1; then
    echo "ERREUR : ipset allowed-domains introuvable — lancer init-firewall.sh avant ce script"
    exit 1
fi

# Docker crée DOCKER-USER au démarrage du daemon avec une règle RETURN par
# défaut ; on la retire et on repart d'une chaîne vide sous notre contrôle.
iptables -N DOCKER-USER 2>/dev/null || true
iptables -F DOCKER-USER

# DNS : nécessaire pour résoudre les domaines whitelistés eux-mêmes. Le
# resolver utilisé par les conteneurs imbriqués n'est pas un "domaine" au
# sens de la whitelist (souvent l'IP du DNS du host, copiée par dockerd dans
# /etc/resolv.conf), donc autorisé explicitement — miroir de la règle DNS de
# la chaîne OUTPUT dans init-firewall.sh.
iptables -A DOCKER-USER -p udp --dport 53 -j RETURN
iptables -A DOCKER-USER -p tcp --dport 53 -j RETURN

# Connexions déjà établies (retours de connexions sortantes autorisées)
iptables -A DOCKER-USER -m state --state ESTABLISHED,RELATED -j RETURN

# Sortant des conteneurs imbriqués autorisé uniquement vers la whitelist
iptables -A DOCKER-USER -m set --match-set allowed-domains dst -j RETURN

# Tout le reste : DROP, puis on rend la main aux chaînes Docker par défaut
# (qui ne seront jamais atteintes pour le trafic déjà DROP ici)
iptables -A DOCKER-USER -j DROP

echo "Firewall DinD (DOCKER-USER) configuré"
