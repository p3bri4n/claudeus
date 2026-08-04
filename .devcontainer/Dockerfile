FROM node:20

ARG TZ=Europe/Paris
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

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

ENV SHELL=/bin/bash
ENV EDITOR=nano
ENV VISUAL=nano

# uv : gestionnaire de paquets/venv Python rapide
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Claude Code
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Firewall egress : whitelist stricte des domaines sortants (OUTPUT + FORWARD
# pour les conteneurs imbriqués du DinD via DOCKER-USER).
# URL_whitelist.yml est copiée ici comme valeur par défaut : en usage normal
# elle est écrasée par un bind-mount (host) pointant sur le même chemin, pour
# permettre l'édition à chaud sans rebuild d'image.
COPY init-firewall.sh init-firewall-dind.sh /usr/local/bin/
COPY URL_whitelist.yml /usr/local/etc/url-whitelist.yml
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/init-firewall-dind.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/init-firewall-dind.sh, /usr/bin/dockerd" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall
USER node
