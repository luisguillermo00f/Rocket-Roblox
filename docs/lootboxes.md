# Cajas de botín — fase 3 (diseño)

Estado: **IMPLEMENTADO** (decisiones en la sección 14). Se apoya en la fase 1 (`docs/progression.md`: créditos, perfil con bloqueo de
sesión, rotación UTC) y en la fase 2 (`docs/cosmetics.md`: catálogo, rarezas, inventario, `CosmeticsRequest`).

Principios:

- Las cajas **solo dan cosméticos** del catálogo. Nada da ventaja en el juego.
- **No hay dinero real en esta fase.** Las cajas se pagan solo con créditos ganados jugando. Robux queda preparado
  pero **desactivado** por configuración (sección 8).
- **Todo es transparente:** las probabilidades exactas se ven **antes** de abrir o comprar.
- La tirada solo existe en el servidor. Se guarda en el perfil **antes** de responder, y repetir una petición nunca
  produce una segunda tirada.

---

## 1. Rarezas

Se añade **Exótica** a las cuatro de la fase 2. Solo sale en cajas: no está en la tienda, no es recompensa de nivel y
se puede conseguir con fragmentos (sección 5).

| Rareza | id | Color | Efecto de revelado (sección 9) |
|---|---|---|---|
| Común | `common` | gris claro `(200,200,196)` | destello suave y 20 partículas |
| Rara | `rare` | azul `(70,150,255)` | destello y 35 partículas, sonido `tick` + `whoosh` |
| Épica | `epic` | violeta `(170,90,255)` | destello largo, 50 partículas, anillo que se expande, sonido `win` |
| Legendaria | `legendary` | dorado `(255,196,64)` | +0,6 s de carga, pantalla dorada, 70 partículas, rayos que giran, `goalBoom` + `win` |
| Exótica | `exotic` | magenta `(255,60,170)` | como Legendaria + un segundo estallido en arcoíris y sacudida de cámara, `goalBoom` + `crowdGoal` |

## 2. Objetos nuevos del catálogo (solo en cajas)

Se añaden 25 objetos a `CosmeticCatalog` con `sources = { "box" }`, todos por código como en la fase 2. En el
catálogo total quedan 88.

| id | Nombre | Slot | R | Caja | Idea |
|---|---|---|---|---|---|
| boost_comet | COLA DE COMETA | boost | X | Estándar | `Trail` largo (0,9 s) blanco → cian + chispas que caen |
| goal_galaxy | GALAXIA | goal | X | Estándar | espiral de partículas violeta/azul que gira y colapsa |
| primary_forcefield | CAMPO DE FUERZA | primary | X | Estándar | material `ForceField` del motor sobre el color de equipo |
| secondary_nitro | NITRO | secondary | C | Temporada | turquesa (0,200,180) |
| frame_nitro | NITRO | frame | C | Temporada | trazo turquesa |
| title_season1 | TEMPORADA 1 | title | C | Temporada | — |
| primary_carbonfiber | FIBRA DE CARBONO | primary | R | Temporada | `Slate`, sombra −0,4 |
| boost_nitro | DESCARGA NITRO | boost | R | Temporada | blanco → turquesa, chispas |
| wheels_nitro | LLANTAS NITRO | wheels | R | Temporada | turquesa `Neon` |
| goal_nitro | ONDA NITRO | goal | E | Temporada | anillo doble turquesa + columna de luz |
| title_supersonic | SUPERSÓNICO | title | E | Temporada | texto con degradado |
| boost_hyperdrive | HIPERESPACIO | boost | L | Temporada | estrellas estiradas (`Trail` fino ×3) y luz blanca |
| primary_iridescent | IRISADO | primary | L | Temporada | `Glass` + reflectancia 0,5 y acento que cambia de tono |
| wheels_hologram | HOLOGRAMA | wheels | X | Temporada | `ForceField` cian con brillo |
| frame_aurora | AURORA | frame | X | Temporada | degradado de 4 colores que gira |
| title_partygoer | FIESTERO | title | C | Minijuegos | — |
| secondary_bubblegum | CHICLE | secondary | C | Minijuegos | (255,140,200) |
| frame_confetti | CONFETI | frame | C | Minijuegos | trazo multicolor a trozos |
| boost_bubbles | BURBUJAS | boost | R | Minijuegos | partículas redondas que suben y flotan |
| wheels_candy | CARAMELO | wheels | R | Minijuegos | rojo/blanco `Neon` |
| goal_pinata | PIÑATA | goal | E | Minijuegos | caja que se rompe en trozos de colores y caramelos |
| title_partychamp | CAMPEÓN DE FIESTA | title | E | Minijuegos | — |
| boost_disco | DISCO | boost | L | Minijuegos | luces de colores que rotan, `Trail` de 6 colores |
| goal_partyblast | FIESTA TOTAL | goal | X | Minijuegos | confeti + fuegos + serpentinas (neón con `Trail`) |
| frame_crown | CORONA | frame | L | Minijuegos | trazo dorado grueso con brillo que gira |

## 3. Tipos de caja y tablas de botín (`ReplicatedStorage/Economy/LootboxData.lua`)

Hay **tres cajas**. Probabilidad de cada objeto = `P(rareza) × peso / Σ pesos de esa rareza en esa caja`. Por defecto
todos los pesos valen 1 y los objetos exclusivos de la caja pesan 2. Las probabilidades por objeto se calculan con
esta fórmula y la UI las muestra con 2 decimales. Un test verifica que suman 100 %.

### 3.1 CAJA ESTÁNDAR (`standard`)

| Rareza | Probabilidad | Contenido |
|---|---|---|
| Común | **60 %** | los 13 comunes de la tienda |
| Rara | **27 %** | los 10 raros de la tienda |
| Épica | **10 %** | los 8 épicos de la tienda |
| Legendaria | **2,5 %** | los 5 legendarios de la tienda |
| Exótica | **0,5 %** | boost_comet, goal_galaxy, primary_forcefield (peso 1 cada uno → 0,1667 %) |
| **Total** | **100 %** | 39 objetos |

Garantía: Épica o mejor como máximo cada **10** cajas; Legendaria o mejor como máximo cada **40**.

### 3.2 CAJA DE TEMPORADA — «TEMPORADA 1: NITRO» (`season1`)

| Rareza | Probabilidad | Contenido |
|---|---|---|
| Común | **45 %** | 3 exclusivos (peso 2) + 4 comunes de la tienda (peso 1) |
| Rara | **32 %** | 3 exclusivos (peso 2) + 3 raros de la tienda (peso 1) |
| Épica | **16 %** | goal_nitro, title_supersonic (peso 2) + 2 épicos de la tienda (peso 1) |
| Legendaria | **5 %** | boost_hyperdrive, primary_iridescent |
| Exótica | **2 %** | wheels_hologram, frame_aurora |
| **Total** | **100 %** | |

Garantía: Épica o mejor cada **8**; Legendaria o mejor cada **30**. La temporada tiene `startsAt` y `endsAt` en la
configuración. Fuera de esas fechas **no se reparte ni se vende**, pero las cajas que ya tienes se pueden abrir siempre,
con la tabla de su temporada (cada temporada tiene su id de caja).

### 3.3 CAJA DE MINIJUEGOS (`minigames`)

| Rareza | Probabilidad | Contenido |
|---|---|---|
| Común | **55 %** | 3 exclusivos (peso 2) + frame_white, secondary_yellow, goal_shockwave (peso 1) |
| Rara | **30 %** | boost_bubbles, wheels_candy (peso 2) + goal_confetti, title_wrecker (peso 1) |
| Épica | **11 %** | goal_pinata, title_partychamp (peso 2) + goal_fireworks (peso 1) |
| Legendaria | **3,5 %** | boost_disco, frame_crown |
| Exótica | **0,5 %** | goal_partyblast |
| **Total** | **100 %** | |

Garantía: Épica o mejor cada **10**; Legendaria o mejor cada **40**.

## 4. Garantía (pity)

Por caja y por jugador: `pity[boxId] = { epic = n, legendary = n }`, donde cada contador es el número de aperturas
seguidas sin esa rareza o mejor.

```
al abrir:
  si pity.legendary == M − 1  → la rareza se tira SOLO entre {Legendaria, Exótica}, con sus pesos base renormalizados
  si no, si pity.epic == N − 1 → la rareza se tira SOLO entre {Épica, Legendaria, Exótica}, renormalizados
  si no                        → tirada normal
  luego: epic      = 0 si rareza ≥ Épica,      si no epic + 1
         legendary = 0 si rareza ≥ Legendaria, si no legendary + 1
```

Así **nunca** hay N cajas seguidas sin Épica+ ni M sin Legendaria+. Los contadores se guardan en el perfil, no se
reinician por día y no se comparten entre tipos de caja. La UI los muestra: «ÉPICA O MEJOR GARANTIZADA EN 4 CAJAS ·
LEGENDARIA EN 27».

**Probabilidades publicadas.** Con garantía, la tasa real a la larga es algo mayor que la de cada tirada (Estándar:
Épica+ ≈ 17 % en vez de 13 %). La UI enseña las dos columnas:

- **«POR CAJA»:** la tabla de la sección 3, que es la probabilidad de cada apertura sin garantía activa.
- **«MEDIA CON GARANTÍA»:** la tasa a largo plazo. Se calcula **exactamente** con la cadena de Markov sobre los estados
  `(epic, legendary)` (N·M ≤ 400 estados, distribución estacionaria), en `LootboxData.EffectiveRates(box)`. No es una
  estimación.

## 5. Duplicados y fragmentos

La tirada **no mira lo que ya tienes**, así que las probabilidades publicadas son siempre las reales. Si sale un
objeto que ya tienes, se convierte según la preferencia del jugador (`dupMode`, que se cambia en la pantalla CAJAS):

| Rareza | `fragments` (por defecto): fragmentos de **esa** caja | `credits`: créditos |
|---|---|---|
| Común | 5 | 30 |
| Rara | 15 | 80 |
| Épica | 40 | 200 |
| Legendaria | 100 | 500 |
| Exótica | 200 | 1 000 |

**Canjear fragmentos:** con fragmentos de una caja se compra **cualquier objeto de su tabla que no tengas**, sin azar:

| Rareza | Coste en fragmentos |
|---|---|
| Común | 50 |
| Rara | 150 |
| Épica | 400 |
| Legendaria | 1 000 |
| Exótica | 2 000 |

La tasa es 10 duplicados de una rareza por un objeto elegido de esa rareza. Los créditos de duplicados valen
aproximadamente un 15–20 % del precio de tienda de su rareza. Los créditos por duplicados **no** cuentan para el tope
diario, porque la cantidad de cajas ya está limitada.

## 6. Cómo se consiguen las cajas

| Vía | Qué da | Límite |
|---|---|---|
| **Recompensa de nivel** | cada 5 niveles → 1 Estándar; cada 10 niveles → además 1 de Temporada (si no hay temporada activa, Estándar) | la curva de XP |
| **Desafíos semanales** | cada semanal de la categoría minijuegos → 1 de Minijuegos; completar **los 3 semanales** → 1 de Temporada (junto al premio de la fase 2) | 1 vez por semana |
| **Drop al terminar una partida en línea** | al final de un resultado que dio recompensa (fase 1): `online_pvp` / `ranked` 12 %, `online_bots` 5 %, `minigame` 5 % → 80 % Estándar / 20 % Temporada (minijuegos: la de Minijuegos). **Nunca** en `local` ni `training`, ni en partidas abandonadas o sin recompensa | **2 al día** (UTC) |
| **Compra con créditos** | Estándar **450** · Temporada **650** · Minijuegos **350** | **10 compras al día** (freno a la compulsión) y **nunca** con restricción de PolicyService |

Migración: los niveles ya alcanzados dan cajas retroactivas **con un máximo de 5 Estándar** (ver decisión A).

## 7. Transparencia y normas de Roblox

### 7.1 Probabilidades visibles antes de abrir

- La pantalla CAJAS siempre muestra, junto a los botones ABRIR y COMPRAR, la tabla de rarezas (POR CAJA y MEDIA CON
  GARANTÍA) de la caja seleccionada.
- **PROBABILIDADES** abre la lista completa: cada objeto con su rareza y su % exacto.
- La confirmación de compra repite el resumen («ÉPICA O MEJOR: 13 % · VER PROBABILIDADES») antes de gastar.
- Las cifras de la UI salen del **mismo** `LootboxData` que usa el servidor, así que no pueden divergir. Un test
  comprueba que la tabla publicada coincide con la tirada simulada.

### 7.2 PolicyService

- Al entrar el jugador, el servidor llama a `PolicyService:GetPolicyInfoForPlayerAsync(player)` dentro de un `pcall`,
  con 2 reintentos. **Si falla, se trata como restringido** (se falla hacia lo seguro) y se vuelve a intentar a los
  60 s.
- `restricted[player] = info.ArePaidRandomItemsRestricted`, que se manda al cliente en `state`.
- **Si está restringido:**
  - el servidor **rechaza** `buy` de cajas con cualquier moneda (créditos incluidos) y la UI no enseña ni el botón ni
    el precio;
  - las compras con Robux (desactivadas de todas formas) tampoco se ofrecen;
  - **Modo sin azar** (`RESTRICTED_MODE = "fragments"`, por defecto): las cajas que ganas jugando no se abren al azar.
    **CANJEAR** convierte cada caja en una cantidad fija de fragmentos (Estándar 60, Temporada 80, Minijuegos 50) y
    eliges el objeto directamente en la lista de la sección 5. La pantalla muestra el contenido como un **catálogo con
    precio en fragmentos**, sin tiradas ni probabilidades.
  - Alternativa por config (`RESTRICTED_MODE = "free_only"`): las cajas ganadas (gratis) se abren al azar y solo se
    bloquea la compra.

### 7.3 Robux: preparado pero desactivado

`LootboxConfig.ROBUX_ENABLED = false` y `LootboxConfig.CREDIT_PACKS_ENABLED = false`. Con `false`, el servidor no
registra `ProcessReceipt` para cajas y la UI no enseña ningún precio en Robux. El código deja el punto de entrada
(`Lootboxes.GrantPurchasedBox(player, boxId, receiptId)`) con la idempotencia por `receiptId` ya hecha.

**Para activarlo algún día hace falta (y queda documentado en el config):**

1. Productos de desarrollador por tipo de caja; la compra **da la caja**, no la abre.
2. `MarketplaceService.ProcessReceipt` idempotente: el `PurchaseId` se guarda en el perfil (registro de recibos) y se
   persiste con `UpdateAsync` **antes** de devolver `PurchaseGranted`; si no se pudo guardar, `NotProcessedYet`.
3. Comprobar `ArePaidRandomItemsRestricted` **en el servidor en cada compra**, no solo en la UI.
4. Si se venden créditos con Robux, los créditos pasan a ser «moneda de pago»: comprar cajas con créditos pasa a ser un
   «paid random item» y le aplican las mismas reglas (ya se cumplen, porque `buy` ya mira la política).
5. Responder **sí** a «Paid Random Items» en el cuestionario de madurez y cumplimiento de la experiencia (Creator
   Dashboard).
6. Probabilidades visibles antes de la compra (ya está), nada de «casi te toca» engañoso en la animación (ya está: la
   rareza solo se revela al final) y revisar las normas vigentes de Roblox sobre paid random items y las leyes
   regionales antes de publicar.

## 8. Seguridad

- **La tirada solo existe en el servidor**, con `Random.new()` (una instancia por servidor, sembrada por el motor).
  El cliente no manda semilla ni nada que influya: solo `boxId` y un `requestId`.
- **Orden estricto en `open`:**
  1. validaciones: perfil cargado y persistente, caja válida, `boxes[boxId] > 0`, política (en modo `fragments` el
     `open` al azar se rechaza para los jugadores restringidos);
  2. **tirada y aplicación en memoria sin ningún `yield`**: `boxes −1`, pity, objeto o duplicado→fragmentos/créditos,
     entrada de historial y `boxRequests[requestId] = resultado`;
  3. **guardado inmediato** (`UpdateAsync` con el bloqueo de sesión de la fase 1) y **esperar** a que termine;
  4. y solo entonces devolver el resultado.
  - Si el guardado falla, **no se deshace nada**: el resultado queda en memoria y se guarda en el siguiente autoguardado
    o al salir. Deshacer permitiría repetir la tirada hasta que saliera algo bueno.
  - Si el jugador se desconecta durante la animación (o durante el guardado), el objeto ya está en su perfil y el
    `PlayerRemoving` lo guarda. En el historial queda como `seen = false` y, al volver, CAJAS muestra
    «¡TIENES OBJETOS NUEVOS!».
- **Doble apertura por spam o reintentos:**
  - `requestId`: un GUID que genera el cliente por cada **clic** (`HttpService:GenerateGUID(false)`, ≤ 40
    caracteres). Si llega un `requestId` ya procesado (anillo de los últimos 20 en el perfil), se devuelve **el mismo
    resultado guardado** sin volver a tirar.
  - Cerrojo por jugador (`busy[player]`): mientras una petición espera el guardado, cualquier otra de cajas devuelve
    `{ ok = false, error = "busy" }`. El cliente reintenta con el mismo `requestId` y recibe el resultado.
  - Ritmo: como mucho 1 apertura por segundo por jugador y como mucho 1 compra por segundo.
  - El botón ABRIR se desactiva en el cliente mientras hay una petición en vuelo (solo es comodidad; la protección real
    es la del servidor).
- `buy`, `redeem` y `convert` (modo sin azar) usan el mismo cerrojo, el mismo `requestId` y el mismo orden de guardado.
- El bloqueo de sesión de la fase 1 impide abrir la misma caja en dos servidores a la vez (teleports).

## 9. Historial

`boxHistory`: las **últimas 50** entradas (FIFO), cada una con `{ t, box, item, rarity, dup, gave = { fragments | credits },
pity = "epic" | "legendary" | nil, seen }`. Se ve en CAJAS › HISTORIAL (fecha local, caja, objeto con el color de su
rareza, «DUPLICADO +15 FRAGMENTOS», «GARANTÍA»). Las acciones `ack` marcan `seen`. Además se guarda una estadística
total `boxesOpened`.

## 10. Perfil v4 y migración

```lua
schema = 4,
boxes       = { standard = 0, season1 = 0, minigames = 0 },
pity        = { standard = { epic = 0, legendary = 0 }, ... },
fragments   = { standard = 0, season1 = 0, minigames = 0 },
dupMode     = "fragments",
boxHistory  = {},                  -- ≤ 50
boxRequests = {},                  -- ≤ 20: { id, result }
boxesOpened = 0,
econ.drops = 0, econ.boxBuys = 0,  -- contadores del día (dentro de econ, que ya se reinicia por día)
```

v3 → v4 solo añade campos. Las cajas retroactivas se dan como `floor(nivel / 5)` Estándar, con un máximo de 5, y la
subida de nivel marca desde dónde seguir. Los ids de caja desconocidos (una temporada futura) se conservan como el
resto de claves desconocidas.

## 11. Remotes y módulos

RemoteFunction **`LootboxRequest(action, arg)`**, creada por código:

| action | arg | Respuesta |
|---|---|---|
| `state` | — | `{ boxes, pity, fragments, dupMode, history, restricted, mode, prices, buysLeft, dropsLeft, season }` |
| `open` | `{ box, requestId }` | `{ ok, result = { item, rarity, dup, gave, pity }, state }` |
| `buy` | `{ box, requestId }` | `{ ok, credits, boxes }` |
| `redeem` | `{ box, item, requestId }` | `{ ok, fragments, owned }` |
| `convert` | `{ box, requestId }` | (modo sin azar) `{ ok, fragments }` |
| `dupMode` | `"fragments"` \| `"credits"` | `{ ok }` |
| `ack` | — | marca el historial como visto |

```
ReplicatedStorage/Economy/LootboxData.lua      cajas, tablas, probabilidades, ItemOdds(box), EffectiveRates(box) (Markov)
ReplicatedStorage/Economy/LootboxConfig.lua    precios, topes, drops, pity N/M, RESTRICTED_MODE, ROBUX_ENABLED = false
ServerScriptService/Economy/Lootboxes.lua      Roll(box, pity, rng) puro · Open/Buy/Redeem/Convert sobre el perfil · Drop
ServerScriptService/Economy/Policy.lua         caché de PolicyService (se puede inyectar en los tests)
ServerScriptService/Economy/LootboxTests.lua   RunAll()
Game/LootboxScreen.lua                          pantalla CAJAS + animación (usa los helpers de MainMenu)
Cambios: ProfileService (remote, drops tras partidas, cajas de nivel), Challenges (cajas de semanales),
         CosmeticCatalog (+25 objetos, rareza exotic), MainMenu (acceso a CAJAS)
```

Para no duplicar `frame`, `text`, `corner` y `tween`, `MainMenu` los expondrá como `MainMenu.UI = { frame, text,
button, brackets, chip, newGui, fmtInt }` y las pantallas nuevas (DESAFÍOS, GARAJE, TIENDA, CAJAS) los reutilizan.

## 12. Interfaz

- **Pantalla CAJAS** (pestaña dentro de TIENDA: bumpers `OBJETOS | CAJAS`; ver decisión C):
  - izquierda: las 3 cajas con su contador «×3» y una franja de color; las que tienes a 0 salen atenuadas;
  - derecha, para la caja elegida: nombre y cómo se consigue; **tabla de probabilidades siempre visible**; estado de la
    garantía; botones **ABRIR**, **COMPRAR · 450** (oculto si hay restricción o te quedan 0 compras hoy),
    **PROBABILIDADES**, **FRAGMENTOS: 35 · CANJEAR**, **HISTORIAL** y el selector **DUPLICADOS: FRAGMENTOS / CRÉDITOS**.
  - Mando: `PushPanel` y selección del motor. Arriba/abajo recorre las cajas, derecha va a los botones, A pulsa y B
    vuelve. `HintBar`: «ABRIR · PROBABILIDADES · VOLVER».
- **Animación de apertura** (en 2D sobre un `ScreenGui` propio: los `ParticleEmitter` **no se ven** en un
  `ViewportFrame`, así que las partículas son pequeños `Frame` animados con tweens):
  1. Petición enviada: la caja (frames con tapa y aristas) aparece y se balancea **en color neutro** mientras espera
     la respuesta. **Nunca** revela nada antes de que conteste el servidor.
  2. Respuesta: tiembla 1,2 s cada vez más fuerte, con `tick` que acelera (`Sounds.Play("tick")`).
  3. Destello del **color de la rareza** (Legendaria/Exótica: +0,6 s de carga previa, `boom`).
  4. La tapa sale volando y hay un estallido de partículas del color de la rareza (`whoosh`), con la cantidad de la
     tabla de la sección 1.
  5. Tarjeta del objeto: nombre, slot, rareza, «NUEVO» o «DUPLICADO → +15 FRAGMENTOS» y la etiqueta «GARANTÍA» si la
     sacó el pity. Épica o mejor → `win`.
  6. Botones: **ABRIR OTRA** (si quedan) · **EQUIPAR** (si es nuevo) · **CERRAR**. A / Enter en cualquier momento salta
     directamente a la tarjeta.
  - Sin «casi te toca»: durante la espera y el temblor no se muestra ningún color ni pista de la rareza.

## 13. Tests (`LootboxTests.RunAll()` → nº de tests pasados)

Todos usan `Random.new(semilla)` inyectado, así que son reproducibles.

- **Frecuencias:** por cada caja, **100 000** tiradas **sin garantía**: la frecuencia de cada rareza y de cada objeto
  queda a **±1 punto** de lo publicado en «POR CAJA».
- **Frecuencias con garantía:** 100 000 aperturas **con garantía** por caja: cada rareza a ±1 punto de «MEDIA CON
  GARANTÍA» (la de Markov).
- **Pity:** en esas 100 000 aperturas la racha máxima sin Épica+ es ≤ N−1 y sin Legendaria+ ≤ M−1; los contadores se
  reinician bien; son independientes por caja; con `legendary == M−1` sale siempre Legendaria o Exótica.
- **Datos:** las probabilidades de cada caja suman 100 %; toda rareza con p > 0 tiene ≥ 1 objeto; todo id de las
  tablas existe en el catálogo; los exóticos no tienen la fuente `shop`.
- **Duplicados:** con `fragments` → fragmentos exactos de esa caja y el inventario no cambia; con `credits` → créditos
  exactos; si es nuevo → se añade al inventario y no da nada más; canjear con fragmentos suficientes funciona; con
  insuficientes, con un objeto de otra caja o con uno que ya tienes falla sin cambiar nada.
- **PolicyService:** si está restringido, `buy` falla y no cobra; en modo `fragments`, `open` falla y `convert` da los
  fragmentos fijos; si la política da error → restringido; si no está restringido → se permite todo.
- **Doble apertura:** el mismo `requestId` dos veces → una sola tirada, el mismo resultado y una sola caja descontada;
  con `busy` activo la segunda petición devuelve `busy`; 10 peticiones con ids distintos y 1 caja → 1 éxito y 9
  «NO TIENES CAJAS»; el anillo de `requestId` guarda como mucho 20.
- **Guardado antes de responder:** con un guardador falso que registra el orden, «guardar» ocurre antes de «responder»;
  si el guardado falla, el objeto sigue en el perfil.
- **Compras:** descuenta el precio exacto; créditos insuficientes → falla sin cambiar nada; el tope de 10 al día se
  reinicia al cambiar el día UTC.
- **Drops:** como mucho 2 al día; nunca en `local`, `training` ni resultados sin recompensa.
- **Historial:** nunca más de 50 y la más antigua sale primero.
- **Migración:** v3 → v4 conserva todo lo anterior; las cajas retroactivas llegan como máximo a 5; la cadena
  v1 → v4 completa no pierde ningún campo.

## 14. Decisiones

- **A. Cajas retroactivas por nivel:** `floor(nivel/5)` Estándar, máximo 5. **Aprobado.**
- **B. Modo para jugadores restringidos:** **pendiente de definir.** Queda configurable en
  `LootboxConfig.RESTRICTED_MODE`: por defecto `"fragments"` (sin ningún azar, lo más seguro) y `"free_only"` como
  alternativa. Ambos modos están implementados y tienen tests.
- **C. CAJAS como pestaña de TIENDA** (OBJETOS | CAJAS, LB/RB o Q/E para cambiar). **Aprobado.**
- **D. Precio y probabilidades estipulados en la caja antes de tirar.** Implementado así:
  - cada caja declara en `LootboxData` su precio, sus probabilidades por rareza (en puntos básicos que suman 10 000),
    los pesos de cada objeto y su garantía. El servidor tira con **esos mismos datos**;
  - la pantalla CAJAS muestra siempre el precio y la tabla de probabilidades (por caja y media con garantía) junto a
    ABRIR / COMPRAR, y PROBABILIDADES lista el % exacto de cada objeto. La confirmación de compra repite el resumen;
  - cada petición `open` / `buy` lleva `OddsVersion(box)`, una huella de precio, probabilidades, objetos, pesos y
    garantía. Si no coincide con la del servidor, **se rechaza sin tirar ni cobrar**. Así nadie puede abrir una caja
    con unas probabilidades distintas de las que tenía en pantalla.

## 15. Cambios respecto al diseño

- `LootboxService` se divide en `LootboxRequests` (la lógica de una petición, con las dependencias inyectadas y con
  tests) y `LootboxService` (conecta el remote con ProfileStore, PolicyService y `Random.new()`).
- `LootboxConfig.STUDIO_POLICY` (solo en Studio): fuerza `"restricted"` o `"unrestricted"` para probar los dos
  flujos. En servidores reales se ignora.
- GALAXIA, PIÑATA y FIESTA TOTAL reutilizan estilos de explosión existentes (agujero negro, confeti y fuegos
  artificiales) con su propia paleta. El pulido visual queda para Studio.
- La animación es 2D (GUI): los `ParticleEmitter` no se ven dentro de un `ViewportFrame`.
- La temporada 1 va del 21/09/2026 al 01/01/2027 (UTC) para que se pueda probar ya. Se cambia en
  `LootboxConfig.SEASON`.

---

## Probar en Studio

Requisitos: los de las fases 1 y 2. Sin API Services también se puede abrir y comprar en Studio (el perfil es de
sesión). Para tener material de prueba, en la barra de comandos del **servidor** (Play → pestaña Server):

```lua
local P = require(game.ServerScriptService.Economy.ProfileStore).Get(game.Players.TU_NOMBRE)
P.credits = 20000; P.boxes.standard = 20; P.boxes.season1 = 5; P.boxes.minigames = 5
require(game.ServerScriptService.Economy.ProfileStore).Push(game.Players.TU_NOMBRE)
```

1. **Tests:** `print(require(game.ServerScriptService.Economy.LootboxTests).RunAll(true))` → **29 / 29**, en unos
   segundos (son 600 000 tiradas). Las otras suites: `EconomyTests` 36/36 y `CosmeticsTests` 23/23.
2. **Transparencia:** TIENDA → pestaña **CAJAS**. En cada caja se ven, **antes** de pulsar nada: el precio, la tabla
   de 5 rarezas con «POR CAJA» (Estándar: 60,00 / 27,00 / 10,00 / 2,50 / 0,50 %) y «MEDIA CON GARANTÍA», y los
   contadores («ÉPICA O MEJOR GARANTIZADA COMO MUCHO EN 10 CAJAS · LEGENDARIA O MEJOR EN 40»). PROBABILIDADES lista
   los 39 objetos de la Estándar con su %. La suma de la columna es 100 %.
3. **Abrir:** ABRIR (×N). La caja espera en gris, tiembla con tics cada vez más rápidos, destello del color de la
   rareza, estallido de partículas y tarjeta del objeto («¡NUEVO!» o «DUPLICADO → +N FRAGMENTOS»). A / ENTER / clic
   la salta. ABRIR OTRA encadena y EQUIPAR lo equipa en el garaje.
   - Una Legendaria o Exótica tiene la carga en blanco, los rayos y (la Exótica) el confeti arcoíris con sacudida.
     Para forzarla sin suerte: `P.pity.standard = {epic = 0, legendary = 39}` → la siguiente Estándar es Legendaria
     o Exótica y lleva la etiqueta GARANTÍA.
4. **Desconexión a mitad:** pulsa ABRIR y cierra el cliente (Stop) durante el temblor. Vuelve a entrar: el objeto ya
   es tuyo (GARAJE), la caja está descontada y en HISTORIAL aparece la entrada (y el aviso «¡TIENES OBJETOS NUEVOS!»).
   Con API Services activado, el DataStore ya lo tenía antes de que el cliente recibiera la respuesta.
5. **Spam:** pulsa ABRIR muchas veces seguidas o manda 10 peticiones desde la barra de comandos del cliente:
   `for i = 1, 10 do task.spawn(function() print(game.ReplicatedStorage.Remotes.LootboxRequest:InvokeServer("open", {box = "standard", requestId = "spam-test-1", oddsVersion = require(game.ReplicatedStorage.Economy.LootboxData).OddsVersion(require(game.ReplicatedStorage.Economy.LootboxData).Get("standard"))})) end) end`
   → como mucho **una** caja gastada. Las demás respuestas son `busy` o el mismo resultado repetido.
   Con `oddsVersion = 1` → «LAS PROBABILIDADES DE ESTA CAJA HAN CAMBIADO…» y no se gasta nada.
6. **Comprar:** COMPRAR · 450 → la confirmación con el resumen de probabilidades → la caja aparece (×N+1) y el saldo
   baja. Después de 10 compras en el mismo día: «YA HAS COMPRADO 10 CAJAS HOY».
7. **Duplicados y fragmentos:** DUPLICADOS: FRAGMENTOS / CRÉDITOS cambia el modo. Abre hasta repetir (Estándar
   común) → +5 fragmentos (o +30 créditos). FRAGMENTOS · N → lista de la caja con el coste. Canjea un común (50).
8. **PolicyService restringido:** en `LootboxConfig`, `STUDIO_POLICY = "restricted"` y Play:
   - no hay precio ni botón COMPRAR (y `InvokeServer("buy", …)` devuelve «LA COMPRA DE CAJAS NO ESTÁ DISPONIBLE…»);
   - con `RESTRICTED_MODE = "fragments"`: no hay ABRIR, hay **CANJEAR CAJA** (+60 fragmentos Estándar) y
     **CONTENIDO** muestra coste en fragmentos en lugar de %;
   - con `RESTRICTED_MODE = "free_only"`: ABRIR sí, COMPRAR no.
   - Vuelve a poner `STUDIO_POLICY = nil` al terminar.
9. **Cómo se ganan** (con 2 jugadores en *Clients and Servers*):
   - subir al nivel 5 → «+1 CAJA ESTÁNDAR (NIVEL)» en la franja del resultado (para forzarlo: `P.xp = 1590; P.rewardedLevel = 4` y termina
     una partida);
   - drop al terminar una partida en línea: con suerte (12 %) aparece «+1 CAJA … (AL TERMINAR LA PARTIDA)», como
     mucho 2 al día. Para verlo sin esperar, pon `DROP_CHANCE.online_pvp = 1` en `LootboxConfig` temporalmente;
   - una partida contra bots sin conexión **nunca** da cajas.
10. **Robux:** `ROBUX_ENABLED = false` → en ningún sitio aparece un precio en Robux. No actives el flag sin cumplir la
    lista de la sección 7.3.
