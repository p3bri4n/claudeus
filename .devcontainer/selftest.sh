#!/bin/bash
# Auto-contrôle de l'isolation, exécuté DANS le conteneur par « claudeus selftest ».
# Premier échec = arrêt avec code 1. Aucune valeur secrète n'est affichée.
# Entrées (non secrètes, validées par claudeus sur l'hôte) :
#   CLAUDEUS_SELFTEST_RO      chemins déclarés en lecture seule (un par ligne)
#   CLAUDEUS_SELFTEST_HIDDEN  chemins masqués (un par ligne)
set -u
# --require-github : l'absence de GH_TOKEN devient un échec (à utiliser pour valider une identité).
REQUIRE_GITHUB=0
[ "${1:-}" = "--require-github" ] && REQUIRE_GITHUB=1
cd /workspace || exit 1

n=0
pass() { n=$((n+1)); printf '[ OK ] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; printf '\nselftest : ÉCHEC après %d contrôle(s) réussi(s)\n' "$n" >&2; exit 1; }
note() { printf '[ -- ] %s\n' "$1"; }

echo "== Identifiants de l'hôte =="
[ ! -e "$HOME/.ssh" ] && pass "~/.ssh absent" || fail "~/.ssh existe"
[ ! -e "$HOME/.config/gh" ] && pass "~/.config/gh absent" || fail "~/.config/gh existe"
for v in GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN SSH_AUTH_SOCK; do
    [ -z "${!v+x}" ] && pass "$v absent de l'environnement" || fail "$v est défini dans le conteneur"
done

echo "== Réseau =="
if curl -sS --connect-timeout 5 -o /dev/null https://example.com 2>/dev/null; then
    fail "https://example.com est joignable (hors whitelist)"
else
    pass "domaine hors liste bloqué (example.com)"
fi
if [ -f /usr/local/etc/github-meta.json ]; then
    if (: >> /usr/local/etc/github-meta.json) 2>/dev/null; then
        fail "les plages GitHub montées sont inscriptibles"
    else
        pass "plages GitHub fournies par l'hôte, en lecture seule"
    fi
else
    note "plages GitHub non fournies par l'hôte (lecture réseau par le conteneur)"
fi
[ -f /usr/local/etc/url-whitelist.yml ] || fail "whitelist montée introuvable"
if (: >> /usr/local/etc/url-whitelist.yml) 2>/dev/null; then
    fail "la whitelist montée est inscriptible"
else
    pass "whitelist montée en lecture seule"
fi

echo "== Pare-feu : une relance ne desserre rien =="
initial=$(cat /run/claudeus-firewall-initial 2>/dev/null) || fail "empreinte initiale du pare-feu introuvable"
want_wl=$(sha256sum /usr/local/etc/url-whitelist.yml | cut -c1-16)
for i in 1; do   # une seule relance : chaque passage lit api.github.com/meta (60 req/h par IP)
    out=$(timeout 120 sudo /usr/local/bin/init-firewall.sh 2>&1) || fail "relance $i de init-firewall.sh en échec"
    fp=$(printf '%s\n' "$out" | grep '^FIREWALL_FINGERPRINT' | tail -1)
    [ "$(printf '%s' "$fp" | sed -E 's/.*rules=([0-9a-f]+).*/\1/')" = "$initial" ] \
        || fail "relance $i : les règles iptables ont changé"
    [ "$(printf '%s' "$fp" | sed -E 's/.*whitelist=([0-9a-f]+).*/\1/')" = "$want_wl" ] \
        || fail "relance $i : whitelist utilisée différente du fichier monté"
done
pass "règles identiques après relance, whitelist = fichier monté"
if timeout 60 sudo WHITELIST_FILE=/workspace/autre.yml /usr/local/bin/init-firewall.sh >/dev/null 2>&1; then
    fail "sudo accepte de surcharger WHITELIST_FILE"
else
    pass "WHITELIST_FILE non surchargeable via sudo"
fi
if curl -sS --connect-timeout 5 -o /dev/null https://example.com 2>/dev/null; then
    fail "example.com joignable après relance"
else
    pass "example.com toujours bloqué après relance"
fi

echo "== Montages =="
if [ -d .claudeus ]; then
    if (: > .claudeus/.selftest-probe) 2>/dev/null; then rm -f .claudeus/.selftest-probe; fail ".claudeus inscriptible"; else pass ".claudeus en lecture seule"; fi
else
    note ".claudeus absent du projet (rien à vérifier)"
fi
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -d "$p" ]; then
        if (: > "$p/.selftest-probe") 2>/dev/null; then rm -f "$p/.selftest-probe"; fail "$p (readonly-paths) inscriptible"; fi
    else
        if (: >> "$p") 2>/dev/null; then fail "$p (readonly-paths) inscriptible"; fi
    fi
    pass "readonly-paths : $p non inscriptible"
done <<< "${CLAUDEUS_SELFTEST_RO:-}"
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -d "$p" ]; then
        [ -z "$(ls -A "$p" 2>/dev/null)" ] || fail "$p (hidden-paths) n'est pas vide"
        if (: > "$p/.selftest-probe") 2>/dev/null; then rm -f "$p/.selftest-probe"; fail "$p (hidden-paths) inscriptible"; fi
    else
        [ "$(cat "$p" 2>/dev/null | wc -c)" = 0 ] || fail "$p (hidden-paths) est lisible"
    fi
    pass "hidden-paths : $p masqué"
done <<< "${CLAUDEUS_SELFTEST_HIDDEN:-}"

echo "== GitHub =="
if [ -z "${GH_TOKEN:-}" ]; then
    [ "$REQUIRE_GITHUB" = 0 ] || fail "GH_TOKEN absent (--require-github demandé)"
    note "SKIP : GH_TOKEN absent, contrôles GitHub non exécutés (GitHub non configuré)"
    SKIPPED=" ; GitHub non vérifié"
else
    login=$(timeout 30 gh api user --jq .login 2>/dev/null) || fail "gh api user a échoué (jeton invalide, expiré ou réseau)"
    [ -n "$login" ] || fail "gh api user n'a renvoyé aucun login"
    pass "gh api user → compte « $login »"
    if env -u GH_TOKEN gh auth status >/dev/null 2>&1; then
        fail "gh a une connexion stockée derrière GH_TOKEN"
    else
        pass "aucune connexion gh stockée (sans GH_TOKEN, gh est déconnecté)"
    fi
fi

printf '\nselftest : OK (%d contrôles%s)\n' "$n" "${SKIPPED:-}"
