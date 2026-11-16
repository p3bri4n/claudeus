#!/bin/bash
# Essai reproductible : sous --dangerously-skip-permissions, une règle
# permissions.deny et un hook PreToolUse du PROJET sont-ils encore appliqués ?
#
# Usage : tests/skip-permissions.sh [--profile <nom>]
# Appelle l'API Claude (quelques requêtes minuscules, modèle haiku) avec les
# identifiants du volume de config du profil choisi. Ne touche qu'à un dossier
# temporaire ; le projet de test est généré ici (rien n'est écrit dans le dépôt).
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJ="$(mktemp -d "${TMPDIR:-/tmp}/claudeus-r7.XXXXXX")"
trap 'rm -rf "$PROJ"' EXIT
mkdir -p "$PROJ/.claude"

# Trois commandes inoffensives :
#   echo R7_ALLOWED   -> aucune règle : doit s'exécuter
#   echo R7_DENIED    -> règle permissions.deny : ne doit PAS s'exécuter si deny est appliqué
#   echo R7_HOOKED    -> bloquée par le hook (exit 2) : ne doit PAS s'exécuter si le hook est appliqué
# Le hook écrit aussi un fichier-témoin pour chaque appel Bash (preuve qu'il tourne).
cat > "$PROJ/.claude/hook.sh" <<'HOOK'
#!/bin/bash
input="$(cat)"
echo "$input" | jq -r '.tool_input.command // empty' >> /workspace/.hook-witness
if echo "$input" | jq -r '.tool_input.command // empty' | grep -q R7_HOOKED; then
    echo "bloqué par le hook de test" >&2
    exit 2
fi
exit 0
HOOK
chmod +x "$PROJ/.claude/hook.sh"
cat > "$PROJ/.claude/settings.json" <<'JSON'
{
  "permissions": { "deny": ["Bash(echo R7_DENIED:*)"] },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/workspace/.claude/hook.sh" } ] }
    ]
  }
}
JSON

PROMPT='Exécute séparément, avec l outil Bash, ces trois commandes dans cet ordre : `echo R7_ALLOWED > /workspace/.ran-ALLOWED`, `echo R7_DENIED > /workspace/.ran-DENIED`, `echo R7_HOOKED > /workspace/.ran-HOOKED`. Si une est refusée ou bloquée, continue avec la suivante. Termine par une ligne par commande : NOM => executee ou NOM => bloquee.'

# La sortie contient d'abord les messages de démarrage (pare-feu, dockerd) : on ne garde
# que ce qui suit la ligne « Firewall DinD ».
if ! "$HERE/../claudeus" "$@" "$PROJ" claude -p --dangerously-skip-permissions --model claude-haiku-5-5 "$PROMPT" </dev/null \
    > "$PROJ/raw.txt" 2>&1; then
    echo "ERREUR : claude a échoué. Fin de la sortie :"; tail -5 "$PROJ/raw.txt"
    echo "(session OAuth expirée ? lancer « claudeus <projet> claude » une fois pour se reconnecter)"
    exit 1
fi
sed -n '/^Firewall DinD/,$p' "$PROJ/raw.txt" | tail -n +2 > "$PROJ/answer.txt"

echo "== Réponse de Claude =="; cat "$PROJ/answer.txt"
echo "== Fichier-témoin du hook (commandes vues par PreToolUse) =="
cat "$PROJ/.hook-witness" 2>/dev/null || echo "(absent : le hook n'a PAS tourné)"
echo "== Fichiers réellement créés par les commandes (preuve indépendante de la réponse de Claude) =="
ls -A "$PROJ" | grep '^\.ran-' || echo "(aucun)"
echo "== Lecture =="
echo "Attendu si tout est appliqué : seul .ran-ALLOWED existe ; le témoin du hook liste les commandes vues."
echo "Hook appliqué     : le témoin existe ET .ran-HOOKED n'existe pas."
echo "Règle deny active : .ran-DENIED n'existe pas."
