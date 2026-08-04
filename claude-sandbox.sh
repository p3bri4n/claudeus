#!/bin/bash
# Lance Claude Code en mode autonome dans un conteneur isolé, sans VS Code.
#
# Usage :
#   cd ~/mon-projet
#   ~/tools/claude-sandbox/claude-sandbox.sh              # shell dans le conteneur
#   ~/tools/claude-sandbox/claude-sandbox.sh claude       # Claude directement (mode normal)
#   ~/tools/claude-sandbox/claude-sandbox.sh yolo         # Claude en --dangerously-skip-permissions
#
# Premier lancement : build de l'image (~2-3 min), puis authentification
# Claude (persistée dans le volume claude-sandbox-config).
#
# Accès GitHub (optionnel) : crée ~/.config/claude-sandbox/env contenant
#   export GH_TOKEN="github_pat_XXXX"        # fine-grained PAT scopé aux repos utiles
#   export GIT_USER_NAME="Ton Nom"
#   export GIT_USER_EMAIL="ton@email.fr"
# (chmod 600). Le script le source automatiquement s'il existe.
set -euo pipefail

# Charger la config GitHub si présente
ENV_FILE="$HOME/.config/claude-sandbox/env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="claude-sandbox"
PROJECT_DIR="$(pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

# Build de l'image si absente
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo ">> Build de l'image $IMAGE_NAME..."
    docker build -t "$IMAGE_NAME" "$SCRIPT_DIR/.devcontainer"
fi

# Commande à exécuter dans le conteneur
if [ "${1:-}" = "yolo" ]; then
    CMD=(claude --dangerously-skip-permissions)
elif [ $# -gt 0 ]; then
    CMD=("$@")
else
    CMD=(bash)
fi

# --runtime=sysbox-runc : isolation utilisateur complète, permet un dockerd
# interne (Docker-in-Docker) sans --privileged et sans cap-add (sysbox donne
# déjà les capacités nécessaires à root dans son user-namespace).
# Volume nommé pour ~/.claude : auth persistée entre les sessions
# Volume nommé pour /var/lib/docker : images/layers du DinD persistées
# Seul le dossier projet courant est monté — rien d'autre de l'hôte
docker run -it --rm \
    --name "claude-sandbox-${PROJECT_NAME}-$$" \
    --runtime=sysbox-runc \
    -v "$PROJECT_DIR":/workspace \
    -v claude-sandbox-config:/home/node/.claude \
    -v claude-sandbox-history:/commandhistory \
    -v claude-sandbox-dind:/var/lib/docker \
    -v "$SCRIPT_DIR/.devcontainer/URL_whitelist.yml":/usr/local/etc/url-whitelist.yml:ro \
    -e CLAUDE_CONFIG_DIR=/home/node/.claude \
    -e GH_TOKEN="${GH_TOKEN:-}" \
    -e GIT_AUTHOR_NAME="${GIT_USER_NAME:-}" \
    -e GIT_AUTHOR_EMAIL="${GIT_USER_EMAIL:-}" \
    -e GIT_COMMITTER_NAME="${GIT_USER_NAME:-}" \
    -e GIT_COMMITTER_EMAIL="${GIT_USER_EMAIL:-}" \
    -w /workspace \
    "$IMAGE_NAME" \
    bash -c '
        sudo /usr/local/bin/init-firewall.sh
        sudo dockerd >/tmp/dockerd.log 2>&1 &
        for i in $(seq 1 30); do
            [ -S /var/run/docker.sock ] && break
            sleep 0.5
        done
        if [ ! -S /var/run/docker.sock ]; then
            echo "ERREUR : dockerd interne non démarré, voir /tmp/dockerd.log" >&2
            exit 1
        fi
        sudo /usr/local/bin/init-firewall-dind.sh
        { [ -n "${GH_TOKEN:-}" ] && gh auth setup-git 2>/dev/null || true; }
        exec "$@"
    ' -- "${CMD[@]}"
