FROM node:20

ARG TZ=Europe/Paris
ENV TZ="$TZ"

# Versions exactes (reproductibilité). Pour changer :
#   docker build --build-arg CLAUDE_CODE_VERSION=x.y.z --build-arg MISE_VERSION=vYYYY.M.P -t claudeus .devcontainer
# (ou : CLAUDE_CODE_VERSION=x.y.z claudeus <projet>, après `docker rmi claudeus`)
ARG CLAUDE_CODE_VERSION=2.1.325
ARG MISE_VERSION=v2026.11.9
# Sommes SHA-256 du binaire mise pour MISE_VERSION (copiées de SHASUMS256.txt de la release).
# Si vous changez MISE_VERSION, changez aussi ces deux valeurs : le build échoue sinon.
ARG MISE_SHA256_X64=f13f3e5ec88807e0161669b3aa07a91d84478cdf1e95b5b92b63f85a25d42395
ARG MISE_SHA256_ARM64=b8dd05af6447cee933928664982a8cb2fa646e6951cfc8539db23ce2554a7b04

# Outils de base + iptables/ipset pour le firewall + Python
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  curl \
  python3 \
  python3-pip \
  python3-venv \
  build-essential \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Docker Engine (dockerd interne, isolé du hôte via sysbox-runc au lancement)
RUN install -m 0755 -d /etc/apt/keyrings && \
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
  chmod a+r /etc/apt/keyrings/docker.asc && \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
    > /etc/apt/sources.list.d/docker.list && \
  apt-get update && \
  apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

# Accès npm global pour l'utilisateur node
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# node dans le groupe docker pour parler au dockerd interne sans sudo
RUN groupadd -f docker && usermod -aG docker $USERNAME

# Historique bash persistant (volume monté sur /commandhistory)
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Variable d'orientation pour Claude
ENV DEVCONTAINER=true

# Répertoires de travail et de config
RUN mkdir -p /workspace /home/node/.claude && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

# Utilisateur non-root (obligatoire pour --dangerously-skip-permissions)
USER node

# npm global + PATH
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin:/home/node/.local/bin

# Locale UTF-8 (C.UTF-8 est intégrée à Debian) : sans elle, git et les outils
# affichent les accents en <C3><A9>.
ENV LANG=C.UTF-8

ENV SHELL=/bin/bash
ENV EDITOR=nano
ENV VISUAL=nano

# uv : gestionnaire de paquets/venv Python rapide
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# mise : gestionnaire de versions d'outils générique. Claudeus n'embarque AUCUN
# outil de projet : chaque projet lance lui-même `mise install`. Les shims passent
# devant /usr/local/bin dans le PATH, de sorte qu'un node/python installé par mise
# remplace celui de l'image (node 20, python 3.11) pour ce projet.
RUN set -e; \
  case "$(dpkg --print-architecture)" in \
    amd64) a=x64;   sum="$MISE_SHA256_X64" ;; \
    arm64) a=arm64; sum="$MISE_SHA256_ARM64" ;; \
    *) echo "architecture non supportée pour mise" >&2; exit 1 ;; \
  esac; \
  mkdir -p /home/node/.local/bin; \
  curl -fsSL -o /home/node/.local/bin/mise "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${a}"; \
  echo "${sum}  /home/node/.local/bin/mise" | sha256sum -c -; \
  chmod +x /home/node/.local/bin/mise
# Répertoire des outils installés : créé ici, propriété de node, pour qu'un volume
# nommé monté dessus (claudeus) en hérite et reste inscriptible par node.
RUN mkdir -p /home/node/.local/share/mise
ENV PATH=/home/node/.local/share/mise/shims:$PATH
# Pas de vérification des attestations GitHub pour les outils aqua : elle exige
# tmaproduction.blob.core.windows.net (stockage Azure partagé), que le pare-feu, filtrant
# par IP, ne peut autoriser sans ouvrir d'autres comptes Azure (canal de sortie possible).
# Sans ce réglage, `mise install aqua:...` échoue (testé avec aqua:cli/cli@2.60.0).
ENV MISE_AQUA_GITHUB_ATTESTATIONS=false

# Claude Code
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Firewall egress : whitelist stricte des domaines sortants (OUTPUT + FORWARD
# pour les conteneurs imbriqués du DinD via DOCKER-USER).
# URL_whitelist.yml est copiée ici comme valeur par défaut : en usage normal
# elle est écrasée par un bind-mount (host) pointant sur le même chemin, pour
# permettre l'édition à chaud sans rebuild d'image.
COPY init-firewall.sh init-firewall-dind.sh check-token-expiry.sh /usr/local/bin/
COPY URL_whitelist.yml /usr/local/etc/url-whitelist.yml
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/init-firewall-dind.sh /usr/local/bin/check-token-expiry.sh && \
  echo 'node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh "", /usr/local/bin/init-firewall-dind.sh "", /usr/bin/dockerd ""' > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall
USER node
