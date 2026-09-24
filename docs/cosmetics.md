# Cosméticos: inventario, tienda y equipamiento — fase 2 (diseño)

Estado: **IMPLEMENTADO** (diseño aprobado, decisiones A/B/C: sí). Depende de la fase 1 (`docs/progression.md`: créditos, perfil v2, rotación por
fecha UTC y hash determinista `DateUtil`).

Principio: **solo visual**. Ningún cosmético toca `Physics/`, las hitboxes (`CarConfig`), el tamaño de las piezas que
chocan (los coches visuales ya no tienen colisión) ni las reglas de partida. La hitbox se sigue eligiendo aparte (AJUSTES
› CARRO) y todas se pueden usar gratis.

---

## 0. Lo que hay hoy (leído del código)

| Pieza | Qué hace hoy |
|---|---|
| `Game/CarVisual.lua` | `CarVisual.new(car, parent, skin)` — `skin` es `"Octane"` o `"Troll"`, con plantillas en `Game/CarModels` (instancias de Studio, no están en el repo: `<Skin>` azul y `<Skin>Orange`). Tres rutas: plantilla compuesta (`Composite`), plantilla de malla y coche procedural de respaldo. Colores de equipo en `TEAM_COLORS` (`body` / `accent`). `_effects()` crea el turbo: `ParticleEmitter` «BoostFlame», `Trail` desde la tobera (color `accent`) y una `PointLight`. Las ruedas traseras del procedural tienen una estela supersónica. `SetNameplate(name, color)` pone un `BillboardGui` con el nombre. |
| `Party/MinigameClient.lua` → `paint(v, color)` | Los minijuegos «todos contra todos» repintan el coche: las piezas llamadas `Part 1`, `Part 2`, `Part`, `Part 4` (las de carrocería de la plantilla compuesta) y los colores de la llama y la estela. |
| `Game/Effects.lua` | `Goal(pos, color, slowmo)`: dos ráfagas de partículas, una esfera de neón que se expande y una luz. `Demolish(pos, color)`. Llamadas desde `GameClient` (local), `MinigameViews/Soccar` (en línea, con el evento `goal` del servidor) y otros minijuegos. |
| `MainMenu.lua` → GARAJE | Submenú de palabras con los dos skins (`● OCTANE / ○ CARRITO TROLL`); `cfg.skin` va al cliente y el cliente lo manda al `MatchMaker` (`carChoice` valida contra `SKINS`). |
| Servidor | `MatchMaker` / `PartyServer` guardan `skin` y `hitbox` por miembro; `MinigameSession.LoadPayload` los reparte en `participants`. |

---

## 1. Slots

| Slot (`slot`) | Qué cambia | Dónde se aplica |
|---|---|---|
| `body` | Carrocería: `Octane` / `Troll` (lo que ya hay; los dos gratis). Se integra en el inventario para que el servidor, y no el cliente, diga qué carrocería llevas | `CarVisual.new` (plantilla) |
| `primary` | **Acabado del color de equipo:** tono, material y brillo. El color sigue siendo azul u naranja (se lee siempre de qué equipo eres) | Piezas de carrocería |
| `secondary` | Color de acento libre (franja, alerón, luz inferior) | Piezas de acento, `PointLight` inferior |
| `wheels` | Pintura de llantas (color, material y, las legendarias, un brillo) | Llantas (no el neumático) |
| `boost` | Estela de turbo: colores y tamaño de la llama, textura integrada, color, ancho y vida del `Trail`, chispas extra, color de la luz | `CarVisual._effects` |
| `goal` | Explosión de gol | `Effects.Goal` |
| `title` | Título bajo tu nombre | Placa sobre el coche, tarjeta de perfil, presentación previa (`Intro`) |
| `frame` | Marco del avatar | Tarjeta del menú, modal PERFIL, lista de la fiesta |

**Cómo se reconocen las piezas en las plantillas de Studio** (sin tocar las plantillas):

- Carrocería (`primary`): el atributo `PaintSlot = "primary"` si existe. Si no, las piezas llamadas `Part 1/Part 2/Part/
  Part 4` (la convención que ya usa `MinigameClient.paint`). En el coche procedural: el cuerpo, la cuña, el techo y los
  pasos de rueda.
- Acento (`secondary`): `PaintSlot = "secondary"`. Si no hay ninguna pieza marcada, solo cambian la luz inferior y el
  segundo color del `Trail`. En el procedural: la franja central y el alerón.
- Llantas (`wheels`): `PaintSlot = "wheel"`. Si no, dentro de cada submodelo de rueda, las piezas que no son casi negras
  (luminancia > 0,25; el neumático es negro). En el procedural: `hub` y `spoke`.

Marcar piezas con `PaintSlot` en Studio es **opcional** y solo mejora el resultado. Queda en la lista de «Probar en Studio».

## 2. Rarezas

| Rareza | id | Color de la UI | Precio en la tienda |
|---|---|---|---|
| Común | `common` | gris claro `(200,200,196)` | 150–250 |
| Rara | `rare` | azul `(70,150,255)` | 400–600 |
| Épica | `epic` | violeta `(170,90,255)` | 1 000–1 400 |
| Legendaria | `legendary` | dorado `(255,196,64)` (el `GOLD` del menú) | 2 200–3 000 |

(La fase 3 añade **Exótica**, que solo sale en cajas.)

## 3. Cómo se obtiene cada objeto (`sources`)

- `default`: gratis y de todos desde el principio. **No se guarda en el perfil:** es propio si `item.default == true`.
- `shop`: entra en la rotación de la tienda y se compra con créditos al precio del catálogo.
- `level = N`: se da al llegar al nivel N (recompensa de nivel de la fase 1).
- `challenge`: se da al completar **los 3 semanales** de una semana. El premio de cada semana se elige con
  `hash(semana, "chreward")` entre los objetos `challenge` que el jugador **aún no tiene**; si ya los tiene todos, 500
  créditos.
- Un objeto puede tener varias fuentes, por ejemplo `shop` y `level`.

---

## 4. Catálogo inicial (63 objetos; `ReplicatedStorage/Economy/CosmeticCatalog.lua`)

Todo se hace por código: `Color3`, `Enum.Material`, `ParticleEmitter`, `Trail`, `Beam`, `PointLight`, `UIStroke` y
`UIGradient`. **Sin assets externos.** Las únicas texturas son las del motor (`rbxasset://textures/particles/
sparkles_main.dds`, `fire_main.dds`, `smoke_main.dds`), que vienen con Roblox; si se prefiere, se quitan y se usa la
partícula por defecto.

Formato: `{ id, slot, name, rarity, sources, price?, params }`. Abreviaturas: C = Común, R = Rara, E = Épica,
L = Legendaria; `lvl N` = recompensa de nivel N; `ch` = premio de semanales.

### 4.1 Carrocería (2)

| id | Nombre | R | Fuente | params |
|---|---|---|---|---|
| body_octane | OCTANE | C | default | `template = "Octane"` |
| body_troll | CARRITO TROLL | C | default | `template = "Troll"` |

### 4.2 Acabado primario (9); el color de equipo se transforma, nunca se sustituye

`params = { shade = −1..1 (oscurece/aclara hacia negro/blanco), sat = factor, material, reflectance }`

| id | Nombre | R | Fuente | params |
|---|---|---|---|---|
| primary_standard | ESTÁNDAR | C | default | shade 0, SmoothPlastic, refl 0.06 |
| primary_shadow | SOMBRA | C | shop 150 | shade −0.35 |
| primary_dawn | ALBA | C | shop 150 | shade +0.3 |
| primary_matte | MATE | C | shop 200 | sat 0.8, refl 0 |
| primary_pearl | PERLADO | R | lvl 10 | shade +0.15, refl 0.25 |
| primary_metal | METALIZADO | R | shop 450 | Metal, refl 0.2 |
| primary_glass | CRISTAL | E | lvl 20 · shop 1 200 | Glass, refl 0.3 |
| primary_neon | NEÓN | E | shop 1 300 | Neon, shade −0.2 (para que no deslumbre) |
| primary_chrome | CROMO | L | shop 2 600 | Foil, refl 0.45, shade +0.1 |

### 4.3 Color secundario (11)

`params = { color, material? }`

| id | Nombre | R | Fuente | color |
|---|---|---|---|---|
| secondary_white | BLANCO | C | default | (240,240,240) |
| secondary_black | NEGRO | C | shop 150 | (24,24,28) |
| secondary_red | ROJO | C | shop 150 | (220,40,50) |
| secondary_green | VERDE | C | shop 150 | (40,190,90) |
| secondary_yellow | AMARILLO | C | shop 200 | (250,215,40) |
| secondary_purple | MORADO | R | shop 400 | (140,70,230) |
| secondary_pink | ROSA | R | shop 400 | (255,110,190) |
| secondary_cyan | CIAN | R | shop 450 | (40,220,235) |
| secondary_lime | LIMA | R | ch | (170,255,60) |
| secondary_gold | ORO | E | shop 1 100 | (255,196,64), Metal |
| secondary_titanium | TITANIO | E | lvl 30 | (170,176,186), Foil |

### 4.4 Llantas (8)

`params = { color, material, glow? (PointLight en el buje), sparkle? (ParticleEmitter en las llantas traseras) }`

| id | Nombre | R | Fuente | params |
|---|---|---|---|---|
| wheels_standard | PLATA | C | default | (150,155,165) Metal |
| wheels_black | NEGRO MATE | C | shop 150 | (30,30,34) SmoothPlastic |
| wheels_red | ROJO | C | shop 200 | (200,40,40) Metal |
| wheels_chrome | CROMADAS | R | shop 500 | (220,224,232) Foil |
| wheels_team | EQUIPO NEÓN | R | lvl 15 | color del acento de equipo, Neon |
| wheels_gold | DORADAS | E | shop 1 200 | (255,196,64) Metal |
| wheels_carbon | CARBONO | E | ch | (40,42,48) Foil |
| wheels_plasma | PLASMA | L | shop 2 400 | (120,200,255) Neon + glow + sparkle |

### 4.5 Estelas de turbo (10)

`params = { flame = {c0,c1}, flameSize, texture?, trail = {c0,c1}, trailWidth, trailLife, light, extra? }`.
Nunca pasan de 1,5× el tamaño actual de la llama para no tapar la visión.

| id | Nombre | R | Fuente | Idea |
|---|---|---|---|---|
| boost_standard | ESTÁNDAR | C | default | la actual (crema → naranja, `Trail` al acento) |
| boost_team | EQUIPO | C | shop 200 | llama y `Trail` en el color de equipo |
| boost_vapor | VAPOR | C | shop 250 | blanco, `smoke_main`, sin luz |
| boost_blue | LLAMA AZUL | R | shop 500 | (200,240,255) → (40,120,255), luz azul |
| boost_toxic | TÓXICO | R | lvl 5 | (220,255,160) → (60,220,40) |
| boost_sparks | CHISPAS | R | shop 550 | llama estándar + emisor extra `sparkles_main` dorado |
| boost_plasma | PLASMA | E | shop 1 200 | (255,200,255) → (170,60,255), `Trail` más ancho (1,3×) |
| boost_gold | ORO | E | ch | (255,250,210) → (255,190,40), chispas doradas |
| boost_rainbow | ARCOÍRIS | L | shop 2 800 | `ColorSequence` de 6 paradas en el `Trail`, vida 0,5 s |
| boost_inferno | INFIERNO | L | lvl 40 | `fire_main`, rojo → amarillo, llama 1,4×, luz roja |

### 4.6 Explosiones de gol (8)

`params = { colors, shell = "ball"|"ring"|"none", shellMaterial, bursts = {…}, extra? }`. Duran como la actual
(≤ 4 s con cámara lenta) y respetan `GS.ParticleMult()`.

| id | Nombre | R | Fuente | Idea |
|---|---|---|---|---|
| goal_standard | CLÁSICA | C | default | la actual, color de equipo |
| goal_shockwave | ONDA | C | shop 250 | un anillo plano (cilindro de neón) que se expande por el suelo |
| goal_confetti | CONFETI | R | shop 550 | ráfaga de cuadrados de 5 colores con gravedad (`Acceleration`) |
| goal_frost | ESCARCHA | R | lvl 25 | azul hielo, esfera `Glass`, copos lentos |
| goal_fireworks | FUEGOS ARTIFICIALES | E | shop 1 300 | 5 cohetes (partes neón con `Trail`) que suben y estallan con retardo |
| goal_supernova | SUPERNOVA | E | ch | esfera blanca → color de equipo, dos anillos cruzados |
| goal_blackhole | AGUJERO NEGRO | L | shop 3 000 | esfera negra que implosiona (tween a 0) con partículas atraídas hacia dentro (`Speed` negativa), destello final |
| goal_lightning | RELÁMPAGO | L | lvl 50 | 6 `Beam` en zigzag del cielo a la portería, destello blanco |

### 4.7 Títulos (8)

`params = { text, color, glow? }`. Se ven en la placa (segunda línea, más pequeña), en el perfil y en la presentación.

| id | Texto | R | Fuente |
|---|---|---|---|
| title_rookie | NOVATO | C | default |
| title_scorer | GOLEADOR | R | ch |
| title_wall | EL MURO | R | ch |
| title_wrecker | DEMOLEDOR | R | shop 400 |
| title_pilot | AVIADOR | E | shop 1 000 |
| title_partyking | REY DE LA FIESTA | E | ch |
| title_veteran | VETERANO | E | lvl 35 |
| title_legend | LEYENDA | L | lvl 60 (texto dorado con brillo) |

### 4.8 Marcos de avatar (7)

`params = { stroke = color | gradient, thickness, spin? (UIGradient que gira) }`

| id | Nombre | R | Fuente |
|---|---|---|---|
| frame_none | SIN MARCO | C | default (el anillo blanco tenue actual) |
| frame_white | BLANCO | C | shop 150 |
| frame_blue | AZUL ELÉCTRICO | R | shop 450 |
| frame_level | ESTRELLA | R | lvl 10 |
| frame_gold | DORADO | E | shop 1 100 |
| frame_neon | NEÓN | E | ch (degradado cian → violeta que gira) |
| frame_fire | EN LLAMAS | L | shop 2 400 (degradado rojo → amarillo que gira) |

**Total: 2 + 9 + 11 + 8 + 10 + 8 + 8 + 7 = 63.** Por defecto: 9 (uno por slot más la segunda carrocería).
Tienda: 36 (13 C · 10 R · 8 E · 5 L; `primary_glass` también es de nivel) · Nivel: 11 · Premio de semanales: 8.

### 4.9 Recompensas de nivel (tabla en el catálogo)

| Nivel | Objeto | Nivel | Objeto |
|---|---|---|---|
| 5 | boost_toxic | 30 | secondary_titanium |
| 10 | primary_pearl, frame_level | 35 | title_veteran |
| 15 | wheels_team | 40 | boost_inferno |
| 20 | primary_glass | 50 | goal_lightning |
| 25 | goal_frost | 60 | title_legend |

Se reparten con la lógica `rewardedLevel` de la fase 1: al subir de nivel se dan todas las recompensas entre
`rewardedLevel + 1` y el nivel nuevo. Si ya tienes el objeto (por ejemplo, porque lo compraste), recibes su precio en
créditos, o 300 si no tiene precio.

---

## 5. Tienda rotativa

- **6 objetos al día**, iguales para todos, que cambian a las 00:00 UTC. Rotación determinista con
  `hash(dia, "shop")` (el splitmix32 de `DateUtil`, no `Random`) sobre los objetos con fuente `shop`:
  - reparto fijo por rareza: **3 comunes, 2 raras, 1 épica** (si faltan de una rareza, se rellena con la inferior);
  - como mucho **2 del mismo slot**;
  - no repite ninguno de los 6 del día anterior si hay alternativa.
- **Destacado semanal:** 1 objeto **Legendario** (o Épico si no quedan) con `hash(semana, "featured")`, lunes 00:00 UTC.
  Nunca coincide con los 6 del día.
- La rotación **no depende del jugador** (lo que ya tienes aparece como «COMPRADO»), así que se puede calcular igual en
  el cliente y en el servidor. El servidor **siempre la vuelve a calcular** al comprar; lo que diga el cliente no cuenta.
- Margen de medianoche: una compra que llega ≤ 60 s después del cambio de día se acepta si el objeto estaba en la
  rotación anterior (así no falla quien pulsó a las 23:59:59).

## 6. Compra y equipamiento (solo en el servidor)

RemoteFunction **`CosmeticsRequest(action, arg)`**, creada por código en `Remotes`, con el mismo patrón que
`PartyRequest` y `MatchRequest`: `pcall` alrededor y respuesta `{ ok, error?, … }`.

| action | arg | Validación en el servidor | Respuesta |
|---|---|---|---|
| `state` | — | — | `{ owned, equipped, shop = { day, items, featured, resetIn }, credits }` |
| `buy` | `itemId` | 1) perfil cargado y persistente (sin DataStore no se compra); 2) el objeto existe; 3) tiene fuente `shop`; 4) está en la rotación de hoy o en el destacado (o en la de ayer dentro del margen); 5) no lo tienes ya; 6) `credits ≥ price`; 7) sin otra compra en curso del mismo jugador (cerrojo) y como mucho 1 compra por segundo | `{ ok, credits, owned }` o `{ ok = false, error = "YA LO TIENES" / "CRÉDITOS INSUFICIENTES" / "YA NO ESTÁ EN LA TIENDA" / … }` |
| `equip` | `{ slot, itemId }` | el objeto existe, **su `slot` es igual al `slot` pedido** y lo tienes (o es `default`); como mucho 5 cambios por segundo | `{ ok, equipped }` |

- La compra descuenta créditos y añade el objeto en **la misma operación sobre la tabla en memoria** (sin `yield`
  entre la comprobación y el cambio) y después pide un guardado inmediato.
- Equipar solo cambia `equipped` en memoria y se guarda con el autoguardado.
- Tras cada compra o equipamiento se envía `ProfileUpdate` (fase 1) con `owned` / `equipped`.
- La hitbox **no** forma parte del inventario: sigue libre y validada como hoy (`CarConfig`).

## 7. Replicación: quién ve qué

El servidor es la única fuente del loadout. Loadout = `{ body, primary, secondary, wheels, boost, goal, title, frame }`
con ids del catálogo. Los clientes lo convierten en parámetros con `CosmeticCatalog.Resolve(loadout)`, que pone el
objeto por defecto en cualquier id desconocido o que falte.

| Contexto | Cómo viaja | Dónde se aplica |
|---|---|---|
| **Partida local contra bots** | El cliente lee su propio `equipped` de `GetProfile`. Los bots usan el loadout por defecto | `GameClient`: `CarVisual.new(car, folder, loadout)`; en el gol, el loadout del autor (el de `MatchEvents`) va a `Effects.Goal` |
| **En línea (`MatchMaker`)** | Al montar los miembros, el servidor pone `m.cosmetics = Inventory.Loadout(player)` (lo lee del perfil con un `BindableFunction` `GetLoadout`, hijo de `ProfileService`) y **deja de usar el `skin` que manda el cliente**: `carChoice` solo valida la hitbox. `MinigameSession.LoadPayload` añade `cosmetics` a cada `participant` | `MinigameClient.AddVisual` → `CarVisual.new(car, folder, p.cosmetics)` y la placa con `title` |
| **Gol en línea** | El evento `goal` de `Soccar` gana un campo `scorer = memberId` (el autor que ya calcula `MatchEvents` en el servidor). Si es autogol o no hay autor, `nil` | `MinigameViews/Soccar`: `Effects.Goal(pos, color, true, participant(scorer).cosmetics.goal)` |
| **Minijuegos** | El mismo `participants[i].cosmetics` | Se ven carrocería, llantas, turbo y título. En los «todos contra todos», `paint()` sigue **sobrescribiendo el color primario** con el del jugador, porque ahí el color identifica a cada uno. Los minijuegos que hoy llaman a `Effects.Goal` usan la explosión del autor cuando su evento lo trae y, si no, la estándar |
| **Lobby de la fiesta** | `PartyServer.State` añade `cosmetics` a cada miembro | `PartyManager` (hoy pinta con `"Octane"`) y marco en la lista |
| **Presentación previa** (`Intro`) | `entries[i].loadout` | `CarVisual.new` y `title` en la etiqueta |

`CarVisual.new(car, parent, skinOrLoadout)` acepta la cadena de antes (`"Octane"`) **o** una tabla de loadout, así que
las llamadas que no se toquen siguen funcionando igual. Toda la personalización se aplica **después** de construir el
coche, sobre las piezas ya creadas: no cambian `self.parts`, `self.offsets`, las posiciones ni los tamaños de la
carrocería, así que el ajuste a la hitbox (`HITBOX_MARGIN`) sigue igual.

## 8. Perfil v3 y migración

```lua
schema = 3,
owned    = { [itemId] = unixTime },          -- solo lo no-default
equipped = { body = "body_octane", primary = "primary_standard", secondary = "secondary_white",
             wheels = "wheels_standard", boost = "boost_standard", goal = "goal_standard",
             title = "title_rookie", frame = "frame_none" },
weeklyPrize = 0,                              -- semana cuyo premio de semanales ya se dio
```

- Migración v2 → v3 (se añade a la cadena de `ProfileSchema`): `owned = {}`, `equipped` = valores por defecto. Si el
  jugador usaba el Carrito Troll, su preferencia vive solo en el cliente (`cfg.skin`), así que el primer equipamiento
  lo hace el cliente enviando `equip` una vez.
- **Recompensas de nivel retroactivas:** en la migración se dan todos los objetos de nivel ≤ nivel actual, así que
  nadie pierde lo que ya se había ganado.
- Al cargar: los ids de `owned` que ya no existen en el catálogo se **conservan** (por si vuelven) pero no se muestran;
  un `equipped` con un id desconocido o no poseído pasa al objeto por defecto de ese slot.

## 9. Interfaz

- **GARAJE** (sustituye al submenú de dos palabras): pantalla a pantalla completa con el mismo lenguaje que AJUSTES.
  - A la izquierda, la lista de slots (CARRO, PINTURA, ACENTO, LLANTAS, TURBO, GOL, TÍTULO, MARCO) y el objeto equipado
    de cada uno.
  - A la derecha, una cuadrícula con los objetos del slot elegido: nombre, franja del color de su rareza, «EQUIPADO» o
    un candado si no lo tienes (con «TIENDA» o «NIVEL 20»).
  - Vista del coche: el coche del menú que ya existe (`onPreview(cfg)` / `MenuCinematic`) se reconstruye con el loadout
    de prueba. Con TURBO se enciende el turbo en bucle y con GOL se lanza `Effects.Goal` delante de la cámara.
  - Mando: bumpers (`tabs`) para cambiar de slot, cruceta para la cuadrícula, A equipa, B vuelve.
    `InputGlyphs.HintBar`: «RANURA · EQUIPAR / PROBAR · VOLVER».
  - Un objeto que no tienes se puede **probar**: el coche del menú lo lleva hasta que eliges otro o sales. La línea de
    estado dice cómo se consigue. Al salir del garaje, el coche vuelve a lo guardado.
- **TIENDA** (palabra nueva del menú): una tarjeta grande para el destacado semanal («DESTACADO · QUEDAN 3 D 4 H») y 6
  tarjetas del día («SE RENUEVA EN 5 H 12 MIN»). Cada tarjeta muestra nombre, slot, rareza, precio o «COMPRADO», y
  «EQUIPADO» si procede. Al pulsar, confirmación con `MainMenu.Modal`: «¿COMPRAR X POR 450 CRÉDITOS?» (COMPRAR /
  CANCELAR). Arriba, el saldo con el rombo de la fase 1. Mando con `PushPanel` y selección del motor.
- Menú principal: JUGAR, GARAJE, **TIENDA**, DESAFÍOS, ENTRENAMIENTO, RANKED, AJUSTES.

## 10. Módulos

```
ReplicatedStorage/Economy/CosmeticCatalog.lua   catálogo, rarezas, rangos de precio, Resolve(loadout), Defaults(), LevelItems(L)
ReplicatedStorage/Economy/ShopRotation.lua      Daily(day), Featured(week), OnSale(now), View(now)   (puro, determinista)
ReplicatedStorage/Game/CosmeticApply.lua        aplica un loadout resuelto a un CarVisual + marco de avatar (UIStroke)
ReplicatedStorage/Game/GarageScreen.lua         pantalla GARAJE
ReplicatedStorage/Game/ShopScreen.lua           pantalla TIENDA (con pestañas extra para la fase 3)
ServerScriptService/Economy/Inventory.lua       Owns, Buy, Equip, Loadout, Grant, WeeklyPrize, Install(Rewards) (puro)
ServerScriptService/Economy/CosmeticsService.lua  remote CosmeticsRequest, LoadoutFor(player), ganchos de resumen
ServerScriptService/Economy/CosmeticsTests.lua  RunAll()
Cambios: CarVisual (acepta loadout, título en la placa), Effects.Goal (4.º parámetro goalId), MainMenu (GARAJE/TIENDA,
         marco y título en la tarjeta), GameClient, MenuCinematic, MinigameClient, MinigameViews/Soccar, PartyManager,
         Minigames/Soccar (campo scorer), MinigameSession/PartyServer (cosmetics en participantes y miembros),
         ProfileSchema (v3), ProfileService (CosmeticsService.Init)
```

Cambios respecto al diseño:

- En lugar del `BindableFunction GetLoadout`, el código del servidor usa directamente
  `CosmeticsService.LoadoutFor(player)`, que es un ModuleScript compartido. `MinigameSession.LoadPayload` lo llama para
  cada humano, así que el loadout vale igual para partidas en línea y para minijuegos, y `MatchMaker` no cambia.
- La tarjeta del menú muestra el **marco** y el **título**. En la lista de la fiesta (PartyUI) el marco todavía no
  aparece.
- **Lobby de la fiesta:** los coches llevan carrocería, llantas y título, pero el color del asiento sigue pintando la
  carrocería y la estela (como en los minijuegos todos contra todos, el color identifica al jugador).
- **Minijuegos todos contra todos:** `MinigameClient.paint()` sigue sobrescribiendo la carrocería **y** el color de la
  llama y la estela con el color del jugador. Llantas, título y carrocería (Octane/Troll) se ven.
- Explosión del autor: en partidas locales (solo la tuya; los bots usan la clásica) y en línea (evento `goal` con
  `scorer`). Los demás minijuegos que llaman a `Effects.Goal` siguen con la clásica.
- Plantillas de malla con textura (`MeshPart.TextureID`): el acabado primario solo cambia material y brillo, porque
  el color no se vería sobre la textura. Marcar piezas con el atributo `PaintSlot` en Studio mejora el resultado (ver
  «Probar en Studio»).

## 11. Tests (`CosmeticsTests.RunAll()`)

- **Compra válida:** descuenta el precio exacto y añade el objeto.
- **Compras inválidas:** sin créditos (el saldo no cambia); ya comprado; objeto fuera de la rotación de hoy; objeto sin
  fuente `shop`; id inexistente o de tipo no string; objeto de ayer dentro del margen (sí) y fuera de él (no); dos
  compras seguidas del mismo objeto (la segunda falla).
- **Equipar:** correcto en su slot; un objeto de otro slot se rechaza; uno que no tienes se rechaza; uno `default`
  siempre se puede.
- **Rotación:** determinista (el mismo día da lo mismo, 365 días); 6 distintos; reparto 3/2/1; ≤ 2 por slot; el
  destacado nunca está en el diario; no repite el día anterior cuando hay alternativa.
- **Catálogo:** ≥ 40 objetos; ids únicos; cada slot tiene exactamente 1 `default`; todo objeto `shop` tiene precio en
  el rango de su rareza; todo objeto no-default tiene al menos una fuente; `Resolve` con ids basura devuelve los
  valores por defecto.
- **Migración:** v2 → v3 conserva créditos, XP, stats y desafíos; da los objetos de nivel ≤ nivel actual; `equipped`
  inválido → valor por defecto; un id retirado en `owned` se conserva.

## 12. Decisiones (confirmadas)

- **A.** El color primario es un acabado del color de equipo. **Sí.**
- **B.** Texturas de partícula integradas del motor (`rbxasset://textures/particles/*`). **Sí.**
- **C.** TIENDA es una palabra del menú (JUGAR, GARAJE, TIENDA, DESAFÍOS, ENTRENAMIENTO, RANKED, AJUSTES). **Sí.**

---

## Probar en Studio

Requisitos: los de `docs/progression.md` (Rojo sincronizado; API Services para guardar). **Sin API Services, en Studio
se puede comprar igualmente** (el perfil es de sesión y se pierde al parar), así que el flujo se prueba sin publicar.

1. **Tests:** `print(require(game.ServerScriptService.Economy.CosmeticsTests).RunAll(true))` → **23 / 23**, y los de la
   fase 1 siguen en **36 / 36** (`EconomyTests`).
2. **Migración:** con un perfil de nivel ≥ 10, Play → GARAJE → PINTURA: **PERLADO** aparece como tuyo (recompensa de
   nivel 10) y en TURBO, **TÓXICO** (nivel 5). La XP, los créditos y los desafíos no cambian.
3. **GARAJE** (palabra del menú):
   - A la izquierda, las 8 ranuras, cada una con lo que llevas. A la derecha, los objetos con su franja de rareza.
   - Pulsa un objeto tuyo → «EQUIPADO: …» y el coche del menú cambia. Stop/Play: sigue equipado (se guardó en el
     servidor).
   - Pulsa uno que no tienes → el coche lo **prueba** («PROBANDO … · SE CONSIGUE EN: TIENDA / NIVEL N»); al salir del
     garaje vuelve a lo equipado.
   - GOL: al pulsar una explosión, se ve delante de la cámara (prueba las 8).
   - Mando: LB/RB cambian de ranura, la cruceta mueve el marco dorado, A equipa/prueba, B sale.
4. **TIENDA:** destacado de la semana (legendario) y 6 objetos del día (1 épico, 2 raros, 3 comunes) con precio y la
   cuenta atrás. Para tener créditos en Studio:
   `require(game.ServerScriptService.Economy.ProfileStore).Get(game.Players.TU_NOMBRE).credits = 5000`.
   - Compra uno → confirmación «¿COMPRAR?» → «¡COMPRADO!» con EQUIPAR. El saldo baja en la tienda y en la tarjeta.
   - Vuelve a pulsarlo → ya no se cobra: dice COMPRADO/EQUIPADO.
   - Con 0 créditos → «CRÉDITOS INSUFICIENTES» y no cambia nada.
   - (Opcional, trampa) en la barra de comandos del cliente:
     `game.ReplicatedStorage.Remotes.CosmeticsRequest:InvokeServer("buy", "goal_lightning")` → `ok = false`
     («ESE OBJETO NO SE VENDE»). `...InvokeServer("equip", {slot = "goal", id = "goal_blackhole"})` sin tenerlo →
     «NO LO TIENES».
5. **Tu coche en partida:** equipa CROMO + LLAMA AZUL/ARCOÍRIS + PLASMA (compradas con créditos de prueba). En
   CONTRA BOTS, tu coche las lleva (la hitbox no cambia: activa el debug de hitbox si lo tienes y compara), el turbo
   tiene sus colores y al marcar ves tu explosión; los goles de los bots usan la clásica.
6. **Réplica en línea** (*Test › Clients and Servers*, 2 jugadores): cada jugador equipa algo distinto → en una
   partida 1V1 EN LÍNEA cada uno ve el coche, el turbo y el **título bajo el nombre** del otro, y al marcar sale la
   explosión **del autor** en las dos pantallas. En un minijuego de fiesta se ven llantas y títulos; en los todos
   contra todos el color del jugador tapa la carrocería y el turbo (es a propósito).
7. **Tarjeta del menú:** equipa un MARCO (p. ej. NEÓN, que gira) y un TÍTULO → la tarjeta de arriba a la derecha los
   muestra.
8. **Plantillas (opcional, mejora visual):** en `ReplicatedStorage.Game.CarModels`, pon el atributo de texto
   `PaintSlot` = `primary` en las piezas de carrocería, `secondary` en las de acento y `wheel` en las llantas de cada
   plantilla (Octane, OctaneOrange, Troll, TrollOrange). Sin atributos se usan los nombres `Part 1/Part 2/Part/Part 4`
   para la carrocería y las piezas no negras de cada rueda para las llantas.
