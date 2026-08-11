# llave — el pendrive como llave de credenciales y apps

Un pendrive corriente que desbloquea tus credenciales y tus apps de Linux en el
Chromebook. Bash + `gpg` simétrico; aquí no se inventa criptografía.

```
llave init          crea una llave en el pendrive, pide PIN, imprime el respaldo en papel
llave adoptar       registra en ESTA máquina una llave ya creada (segunda máquina)
llave llaves        qué llaves conoce la máquina y qué ámbito abre cada una
llave status        ¿está la llave? ¿qué hay abierto, cerrado o todavía en claro?
llave lock   [ámb]  cifra las rutas del manifiesto y las QUITA del disco
llave unlock [ámb]  descifra a RAM (tmpfs) y enlaza las rutas reales
llave sync   [ámb]  vuelve a cifrar tras un cambio (p.ej. un login nuevo)
llave proteger APP  la app no arranca sin el pendrive (llave desproteger APP lo deshace)
llave run -- CMD    ejecuta CMD solo si la llave está puesta
llave keepass init  base de contraseñas en el pendrive, para webs y apps de ChromeOS
llave paper         reimprime el respaldo en papel
llave restore       reconstruye el pendrive desde ese papel
llave selftest      comprueba llave, PIN, cifrado y respaldo
```

## Cómo funciona

El pendrive lleva 32 bytes aleatorios (`key.bin`). La frase de cifrado real es
`base64(key.bin) + ":" + PIN`, así que hacen falta **las dos cosas**. El cifrado es
`gpg --symmetric` AES-256 con S2K SHA-512 al máximo (65 011 712 iteraciones).

```
<USB>/.llave/                 ~/.llave/                    /run/user/1000/llave/
  key.bin    la llave           llaves/<keyid> → nombre       <ámbito>/…
  keyid                         duenos/<ámbito> → keyid       ← el claro, solo en RAM
  vault/personal.tar.gpg        vault/*.tar.gpg  (espejo)
  passwords.kdbx                manifiestos/*.txt · apartados/
```

## Una llave por entidad

Una máquina puede conocer **varias llaves**: un pendrive personal, otro de IPNJ, otro del
negocio. Cada ámbito queda atado a la llave con la que se cerró la primera vez (`duenos/`),
así que **el pendrive de IPNJ no abre lo personal y viceversa** — enchufas la llave de aquello
en lo que vas a trabajar y el resto sigue cifrado.

```bash
llave init --nombre ipnj     # con el pendrive de IPNJ puesto; PIN propio
llave lock ipnj              # ese ámbito queda atado a esa llave
```

Un `llave init` con un pendrive nuevo **no desbanca** a las llaves ya registradas. Para
registrar en otra máquina una llave que ya existe, `llave adoptar` (nunca `init --force`,
que genera una clave nueva y deja ilegible todo lo cifrado con la anterior).

Con la bóveda abierta, `~/.config/hostinger/token` (y las demás rutas) son **enlaces
al tmpfs**: el texto en claro nunca toca el disco. Al reiniciar, el tmpfs se vacía y
esos enlaces quedan colgando — cualquier herramienta ve "no existe", que es
exactamente lo que se quiere. Un `llave unlock` los rehace.

El **espejo cifrado** en `~/.llave/vault/` es respaldo, no una fuga: sin `key.bin` no
se abre. Si pierdes el pendrive, el papel + el espejo lo reconstruyen todo.

## Uso diario

```bash
llave unlock personal     # al empezar (una vez por arranque)
… trabajar …
llave sync personal       # si algo reescribió un token (gh auth login, gws re-auth)
```

`gws` renueva su `token_cache.json` sola cada pocas horas. Mientras la bóveda esté
abierta se escribe en RAM; si quieres conservar ese refresco entre arranques, un
`llave sync personal` de vez en cuando basta. Aunque no lo hagas, el refresh token
vive en `credentials.enc` y `gws` se rehace sola.

## Qué protege esto de verdad, y qué no

| Escenario | Antes | Con la llave |
|---|---|---|
| Portátil apagado y robado | ChromeOS ya lo cifra con tu login | igual |
| **Sesión abierta y desatendida** | **todos tus tokens en claro** | **ilegibles sin pendrive + PIN** |
| Algo malicioso corriendo en el contenedor | lee todo | solo lo que esté abierto en ese momento |
| Pendrive perdido, portátil en casa | — | el ladrón tiene la llave; le falta el PIN |
| Pendrive **y** portátil robados | — | solo el PIN separa al ladrón de todo |

De ahí que el PIN sea de 8+ caracteres y no de 4 dígitos: con 4 dígitos, quien tenga
el pendrive los prueba todos en minutos aunque el S2K sea el máximo.

**Límites honestos:**

- **El candado de apps es un candado, no una caja fuerte.** `llave proteger obsidian`
  reescribe el lanzador; quien abra una terminal y ejecute `/opt/Obsidian/obsidian`
  entra igual. Frena el uso casual, no a alguien que sepa lo que hace.
- **Ningún pendrive normal es anticopiable.** Quien lo tenga cinco minutos se lleva
  `key.bin`. Eso solo lo arregla una llave hardware (YubiKey/FIDO2).
- **Las apps de ChromeOS, Android y Chrome no se pueden bloquear** desde el
  contenedor Linux. Para esas la llave cubre las *credenciales* (`llave keepass`), no
  el arranque. El portapapeles sí cruza de Linux a ChromeOS, así que copiar y pegar
  funciona; la integración con el navegador, no (no hay puente de native messaging).
- **El pendrive llega por 9p**, como carpeta compartida (`/mnt/chromeos/removable/…`).
  ChromeOS no permite passthrough de almacenamiento USB, así que no hay LUKS, ni UUID,
  ni udev. Si al reenchufarlo no aparece, hay que volver a compartirlo desde Archivos
  (clic derecho → Compartir con Linux).

## Pruebas

```bash
./test/verificar.sh
```

26 comprobaciones en un sandbox: ni toca tus secretos ni tu pendrive. Cubre el ciclo
completo (init → lock → unlock → sync → reinicio simulado → pérdida del pendrive →
restauración desde el papel), los guardarraíles (no borra sin verificar, no pisa
ficheros tuyos, rechaza PIN corto o incorrecto), la convivencia de dos llaves
(cada una abre solo su ámbito) y las fases 3 y 4.

`LLAVE_PIN` y `LLAVE_PAPER` existen **solo** para esa suite: usarlas de verdad dejaría
el secreto en el historial de la shell y en el entorno.
