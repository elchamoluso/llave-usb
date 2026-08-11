#!/usr/bin/env bash
# Suite de verificación de 'llave'. Corre entera en un sandbox: ni toca tus
# secretos reales ni tu pendrive. El PIN de prueba va por LLAVE_PIN, que existe
# solo para esto.
set -euo pipefail

LLAVE="$(dirname "$(readlink -f "$0")")/../bin/llave"
SB="$(mktemp -d "${TMPDIR:-/tmp}/llave-test.XXXXXX")"
trap 'rm -rf "$SB"' EXIT

export LLAVE_ROOT="$SB/home"
export LLAVE_HOME="$SB/home/.llave"
export LLAVE_RUNTIME="$SB/run/llave"
export LLAVE_USB="$SB/usb"
export LLAVE_PIN="pin-de-prueba-8+"
mkdir -p "$LLAVE_ROOT" "$SB/run" "$LLAVE_USB"

N=0; FALLOS=0
t()  { N=$((N+1)); printf '  %2d. %s\n' "$N" "$1"; }
ok() { printf '      \033[32m✓\033[0m %s\n' "$1"; }
no() { printf '      \033[31m✗ %s\033[0m\n' "$1"; FALLOS=$((FALLOS+1)); }
assert()      { if eval "$1"; then ok "${2:-$1}"; else no "${2:-$1}"; fi; }
assert_fail() { if eval "$1" >/dev/null 2>&1; then no "${2:-debería haber fallado: $1}"; else ok "${2:-$1}"; fi; }

# ── datos de mentira que imitan las rutas reales ──────────────────────────────
mkdir -p "$LLAVE_ROOT/.config/hostinger" "$LLAVE_ROOT/.supabase" "$LLAVE_ROOT/secrets" \
         "$LLAVE_ROOT/.config/gws" "$LLAVE_HOME/manifiestos"
printf 'token-hostinger-de-mentira' > "$LLAVE_ROOT/.config/hostinger/token"
printf 'token-supabase-de-mentira'  > "$LLAVE_ROOT/.supabase/access-token"
head -c 2048 /dev/urandom           > "$LLAVE_ROOT/.config/gws/credentials.enc"
printf 'clave-cloudflare'           > "$LLAVE_ROOT/secrets/cloudflare-personal.token"
cat > "$LLAVE_HOME/manifiestos/personal.txt" <<'EOF'
.config/hostinger/token
.supabase/access-token
.config/gws/credentials.enc
secrets/cloudflare-personal.token
EOF
ORIG="$SB/originales"; mkdir -p "$ORIG"
cp -a "$LLAVE_ROOT/.config" "$LLAVE_ROOT/.supabase" "$LLAVE_ROOT/secrets" "$ORIG/"

echo; echo "── F1: núcleo de la llave ─────────────────────────────────────────"

t "init crea la clave"
"$LLAVE" init >/dev/null
assert '[[ "$(stat -c%s "$LLAVE_USB/.llave/key.bin")" == 32 ]]' "key.bin mide 32 bytes"
assert '[[ -f "$LLAVE_USB/.llave/keyid" ]]' "el pendrive guarda su keyid"
assert '[[ -f "$LLAVE_HOME/llaves/$(cat "$LLAVE_USB/.llave/keyid")" ]]' "la máquina registra esa llave por su id"
assert '[[ "$(cat "$LLAVE_HOME/llaves/$(cat "$LLAVE_USB/.llave/keyid")")" == "personal" ]]' "con el nombre que se le dio"

t "init no pisa una llave existente sin --force"
assert_fail '"$LLAVE" init' "se niega a regenerar la llave"

t "selftest pasa"
assert '"$LLAVE" selftest >/dev/null' "cifrado, papel y rechazo de PIN malo"

t "un PIN corto se rechaza"
rm -rf "$SB/usb2" "$SB/home2"; mkdir -p "$SB/usb2" "$SB/home2"
assert_fail 'LLAVE_USB="$SB/usb2" LLAVE_HOME="$SB/home2" LLAVE_PIN="corto" "$LLAVE" init' \
            "PIN de menos de 8 caracteres rechazado"
assert '[[ ! -e "$SB/usb2/.llave/key.bin" ]]' "no ha llegado a generar clave"

echo; echo "── F2: bóveda (lock / unlock / sync) ──────────────────────────────"

t "lock --dry-run no toca nada"
"$LLAVE" lock personal --dry-run >/dev/null
assert '[[ -f "$LLAVE_ROOT/.config/hostinger/token" ]]' "el token sigue en su sitio"
assert '[[ ! -f "$LLAVE_USB/.llave/vault/personal.tar.gpg" ]]' "no se ha creado bóveda"

t "lock cifra y retira el claro"
"$LLAVE" lock personal >/dev/null
assert '[[ -f "$LLAVE_USB/.llave/vault/personal.tar.gpg" ]]' "bóveda en el pendrive"
assert '[[ -f "$LLAVE_HOME/vault/personal.tar.gpg" ]]'       "espejo cifrado en la máquina"
assert '[[ ! -e "$LLAVE_ROOT/.config/hostinger/token" ]]'    "el token de Hostinger YA NO está en disco"
assert '[[ ! -e "$LLAVE_ROOT/.supabase/access-token" ]]'     "el token de Supabase YA NO está en disco"
assert '[[ ! -e "$LLAVE_ROOT/.config/gws/credentials.enc" ]]' "las credenciales de gws YA NO están en disco"

t "ningún resto en claro por el sandbox"
# $ORIG es la copia de referencia del propio test: se excluye a propósito
assert '! grep -rl "token-hostinger-de-mentira" "$SB" 2>/dev/null | grep -qv "^$ORIG/"' \
       "el texto del token no aparece en ningún fichero fuera de la copia de referencia"

t "sin la llave no se abre"
mv "$LLAVE_USB/.llave" "$SB/llave-guardada"
assert_fail '"$LLAVE" unlock personal' "unlock falla con el pendrive fuera"
mv "$SB/llave-guardada" "$LLAVE_USB/.llave"

t "con un PIN equivocado no se abre"
assert_fail 'LLAVE_PIN="otro-pin-distinto" "$LLAVE" unlock personal' "unlock falla con PIN incorrecto"

t "unlock devuelve los ficheros byte a byte"
"$LLAVE" unlock personal >/dev/null
assert '[[ -L "$LLAVE_ROOT/.config/hostinger/token" ]]' "la ruta real es un enlace a RAM"
assert 'cmp -s "$ORIG/.config/hostinger/token" "$LLAVE_ROOT/.config/hostinger/token"' "token de Hostinger idéntico"
assert 'cmp -s "$ORIG/.supabase/access-token" "$LLAVE_ROOT/.supabase/access-token"'   "token de Supabase idéntico"
assert 'cmp -s "$ORIG/.config/gws/credentials.enc" "$LLAVE_ROOT/.config/gws/credentials.enc"' "credenciales de gws idénticas (2 KB binarios)"
assert '[[ "$(readlink "$LLAVE_ROOT/.config/hostinger/token")" == "$LLAVE_RUNTIME"/* ]]' "el claro vive en el tmpfs, no en el disco"

t "sync guarda un cambio hecho con la bóveda abierta"
printf 'token-hostinger-NUEVO' > "$LLAVE_ROOT/.config/hostinger/token"
"$LLAVE" sync personal >/dev/null
rm -rf "$LLAVE_RUNTIME"                       # simula reiniciar: el tmpfs se vacía
"$LLAVE" unlock personal >/dev/null
assert '[[ "$(cat "$LLAVE_ROOT/.config/hostinger/token")" == "token-hostinger-NUEVO" ]]' "el cambio sobrevive al reinicio"

t "tras reiniciar sin unlock, las rutas quedan rotas (= cerrado)"
rm -rf "$LLAVE_RUNTIME"
assert '[[ -L "$LLAVE_ROOT/.config/hostinger/token" && ! -e "$LLAVE_ROOT/.config/hostinger/token" ]]' \
       "enlace colgando: cualquier herramienta ve 'no existe'"

t "unlock no pisa un fichero real sin avisar"
rm -f "$LLAVE_ROOT/.supabase/access-token"
printf 'algo-que-escribi-a-mano' > "$LLAVE_ROOT/.supabase/access-token"
assert_fail '"$LLAVE" unlock personal' "se niega y explica las dos salidas"
assert '[[ "$(cat "$LLAVE_ROOT/.supabase/access-token")" == "algo-que-escribi-a-mano" ]]' "no ha tocado el fichero del usuario"
"$LLAVE" unlock personal --force >/dev/null
assert '[[ -n "$(find "$LLAVE_HOME/apartados" -name access-token 2>/dev/null)" ]]' "--force lo aparta en vez de borrarlo"

echo; echo "── Recuperación desde el papel ────────────────────────────────────"

t "el papel + el espejo reconstruyen todo tras perder el pendrive"
PAPEL="$("$LLAVE" paper 2>/dev/null | awk '/clave *:/ {print $3}')"
assert '[[ ${#PAPEL} -eq 44 ]]' "la clave del papel son 44 caracteres"
"$LLAVE" lock personal >/dev/null
rm -rf "$LLAVE_USB"; mkdir -p "$LLAVE_USB"          # pendrive perdido
assert_fail '"$LLAVE" status | grep -q PRESENTE' "sin pendrive, status dice AUSENTE"
LLAVE_PAPER="$PAPEL" "$LLAVE" restore "$LLAVE_USB" >/dev/null
assert '[[ -f "$LLAVE_HOME/llaves/$(cat "$LLAVE_USB/.llave/keyid")" ]]' "la llave restaurada es la misma que conocía la máquina"
assert '[[ -f "$LLAVE_USB/.llave/vault/personal.tar.gpg" ]]' "la bóveda vuelve desde el espejo"
"$LLAVE" unlock personal --force >/dev/null
assert '[[ "$(cat "$LLAVE_ROOT/.config/hostinger/token")" == "token-hostinger-NUEVO" ]]' "los secretos vuelven intactos"

t "una clave de papel mal transcrita se rechaza"
rm -rf "$SB/usb3"; mkdir -p "$SB/usb3"
assert_fail 'LLAVE_PAPER="AAAA" "$LLAVE" restore "$SB/usb3"' "rechaza una clave que no mide 32 bytes"

echo; echo "── Segunda máquina (adoptar) ──────────────────────────────────────"

t "otra máquina adopta el mismo pendrive sin tocar la llave"
KEYID_ORIG="$(cat "$LLAVE_USB/.llave/keyid")"
M2="$SB/maquina2"; mkdir -p "$M2"
assert_fail 'LLAVE_HOME="$M2/.llave" LLAVE_ROOT="$M2" "$LLAVE" init' "init se niega: el pendrive ya tiene llave"
LLAVE_HOME="$M2/.llave" LLAVE_ROOT="$M2" LLAVE_NOMBRE="personal" "$LLAVE" adoptar >/dev/null
assert '[[ -f "$M2/.llave/llaves/$KEYID_ORIG" ]]' "la 2.ª máquina registra la MISMA llave"
assert '[[ "$(cat "$LLAVE_USB/.llave/keyid")" == "$KEYID_ORIG" ]]' "la llave del pendrive sigue intacta"
assert '[[ -f "$M2/.llave/vault/personal.tar.gpg" ]]' "se copia el espejo de la bóveda"
assert '[[ -f "$M2/.llave/manifiestos/personal.txt" ]]' "se copian los manifiestos"
assert_fail 'LLAVE_HOME="$M2/.llave" LLAVE_ROOT="$M2" "$LLAVE" adoptar' "no se adopta dos veces"
assert_fail 'LLAVE_HOME="$M2/.llave" LLAVE_ROOT="$M2" LLAVE_PIN="pin-equivocado" "$LLAVE" adoptar' "adoptar exige el PIN correcto"

echo; echo "── Dos llaves en la misma máquina (personal + ipnj) ───────────────"

t "una segunda llave NO desbanca a la primera"
KEY_PERSONAL="$(ls "$LLAVE_HOME/llaves")"
mkdir -p "$SB/usb-ipnj"
LLAVE_USB="$SB/usb-ipnj" LLAVE_PIN="pin-de-ipnj-999" LLAVE_NOMBRE="ipnj" "$LLAVE" init >/dev/null
assert '[[ "$(ls "$LLAVE_HOME/llaves" | wc -l)" == 2 ]]' "la máquina conoce ahora 2 llaves"
assert '[[ -f "$LLAVE_HOME/llaves/$KEY_PERSONAL" ]]' "la llave personal sigue registrada"
assert '[[ "$(cat "$LLAVE_HOME/llaves/$KEY_PERSONAL")" == "personal" ]]' "conserva su nombre"
KEY_IPNJ="$(ls "$LLAVE_HOME/llaves" | grep -v "^$KEY_PERSONAL\$")"
assert '[[ "$(cat "$LLAVE_HOME/llaves/$KEY_IPNJ")" == "ipnj" ]]' "la nueva se llama ipnj"

t "cada ámbito queda atado a SU llave"
cat > "$LLAVE_HOME/manifiestos/ipnj.txt" <<'EOF'
.config/cosa-de-ipnj/token
EOF
mkdir -p "$LLAVE_ROOT/.config/cosa-de-ipnj"; printf 'token-de-ipnj' > "$LLAVE_ROOT/.config/cosa-de-ipnj/token"
LLAVE_USB="$SB/usb-ipnj" LLAVE_PIN="pin-de-ipnj-999" "$LLAVE" lock ipnj >/dev/null
assert '[[ "$(cat "$LLAVE_HOME/duenos/ipnj")" == "$KEY_IPNJ" ]]' "el ámbito ipnj apunta a la llave ipnj"
assert '[[ "$(cat "$LLAVE_HOME/duenos/personal")" == "$KEY_PERSONAL" ]]' "el ámbito personal apunta a la personal"

t "la llave equivocada NO abre el ámbito ajeno"
assert_fail 'LLAVE_USB="$SB/usb-ipnj" LLAVE_PIN="pin-de-ipnj-999" "$LLAVE" unlock personal' \
            "con el pendrive de ipnj no se abre lo personal"
assert_fail 'LLAVE_PIN="$LLAVE_PIN" "$LLAVE" unlock ipnj' "con el pendrive personal no se abre lo de ipnj"
assert '[[ ! -e "$LLAVE_ROOT/.config/cosa-de-ipnj/token" ]]' "el secreto de ipnj sigue cifrado"

t "cada llave sí abre lo suyo"
LLAVE_USB="$SB/usb-ipnj" LLAVE_PIN="pin-de-ipnj-999" "$LLAVE" unlock ipnj >/dev/null
assert '[[ "$(cat "$LLAVE_ROOT/.config/cosa-de-ipnj/token")" == "token-de-ipnj" ]]' "la llave ipnj abre el ámbito ipnj"
"$LLAVE" unlock personal --force >/dev/null
assert '[[ "$(cat "$LLAVE_ROOT/.config/hostinger/token")" == "token-hostinger-NUEVO" ]]' "la llave personal abre el ámbito personal"

t "llaves las lista con su dueño"
# Captura en vez de tubería: con `| grep -q` la aserción resultaba intermitente
# (grep cierra el pipe en cuanto casa), y lo que se quiere comprobar es el listado entero.
assert 'grep -q "abre el ámbito: ipnj" <<<"$("$LLAVE" llaves)"' "dice qué ámbito abre la llave ipnj"
assert 'grep -q "abre el ámbito: personal" <<<"$("$LLAVE" llaves)"' "y cuál abre la personal"

echo; echo "── F3: candado de apps ────────────────────────────────────────────"

export LLAVE_APPS_SYS="$SB/apps-sistema" LLAVE_APPS_DIR="$SB/home/.local/share/applications"
mkdir -p "$LLAVE_APPS_SYS"
cat > "$LLAVE_APPS_SYS/appdeprueba.desktop" <<'EOF'
[Desktop Entry]
Name=App de prueba
Exec=/bin/echo arrancada %U
Type=Application
[Desktop Action nueva]
Exec=/bin/echo ventana-nueva
EOF

t "proteger reescribe el lanzador"
"$LLAVE" proteger appdeprueba >/dev/null
assert '[[ -f "$LLAVE_APPS_DIR/appdeprueba.desktop" ]]' "crea el override en el HOME"
assert 'grep -q "^Exec=.*llave run -- /bin/echo arrancada %U$" "$LLAVE_APPS_DIR/appdeprueba.desktop"' "Exec principal pasa por la llave"
assert '[[ "$(grep -c "llave run" "$LLAVE_APPS_DIR/appdeprueba.desktop")" == 2 ]]' "también el Exec de [Desktop Action]"
assert '"$LLAVE" status 2>/dev/null | grep -q "appdeprueba"' "status la lista como protegida"

t "run deja pasar con la llave puesta"
assert '[[ "$("$LLAVE" run -- /bin/echo arrancada)" == "arrancada" ]]' "ejecuta el comando real"

t "run bloquea sin la llave"
mv "$LLAVE_USB/.llave" "$SB/llave-fuera"
assert_fail '"$LLAVE" run -- /bin/echo arrancada' "sale con error en vez de arrancar la app"
assert '[[ -z "$("$LLAVE" run -- /bin/echo arrancada 2>/dev/null)" ]]' "no ejecuta nada"
mv "$SB/llave-fuera" "$LLAVE_USB/.llave"

t "desproteger devuelve el lanzador del sistema"
"$LLAVE" desproteger appdeprueba >/dev/null
assert '[[ ! -f "$LLAVE_APPS_DIR/appdeprueba.desktop" ]]' "el override desaparece"

echo; echo "── F4: base de contraseñas (KeePassXC) ────────────────────────────"

if command -v keepassxc-cli >/dev/null 2>&1; then
  t "keepass init crea la base con keyfile + PIN"
  "$LLAVE" keepass init >/dev/null 2>&1
  DB="$LLAVE_USB/.llave/passwords.kdbx"
  assert '[[ -s "$DB" ]]' "la base existe en el pendrive"
  assert 'printf "%s\n" "$LLAVE_PIN" | keepassxc-cli ls -k "$LLAVE_USB/.llave/key.bin" "$DB" >/dev/null 2>&1' \
         "abre con el key file del pendrive + el PIN"
  assert_fail 'printf "%s\n" "$LLAVE_PIN" | keepassxc-cli ls "$DB"' "no abre solo con el PIN (sin el pendrive)"
  assert_fail 'printf "otro-pin-distinto\n" | keepassxc-cli ls -k "$LLAVE_USB/.llave/key.bin" "$DB"' \
              "no abre solo con el pendrive (sin el PIN)"
else
  t "keepassxc no instalado: sección omitida"
fi

echo
if [[ $FALLOS -eq 0 ]]; then
  printf '\033[32m✓ %d comprobaciones, 0 fallos\033[0m\n' "$N"
else
  printf '\033[31m✗ %d fallo(s) de %d comprobaciones\033[0m\n' "$FALLOS" "$N"; exit 1
fi
