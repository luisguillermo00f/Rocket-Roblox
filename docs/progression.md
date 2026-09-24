# Progresión y economía — fase 1 (diseño)

Estado: **IMPLEMENTADO** (diseño aprobado; decisiones en la sección 8). Pasos de verificación al final.

Este documento define niveles/XP, la moneda **Créditos**, los desafíos diarios/semanales y cómo se guarda todo en el
perfil. Todo se calcula **solo en el servidor**: el cliente muestra lo que el servidor le manda.

---

## 0. Lo que hay hoy (leído del código)

| Pieza | Qué hace hoy |
|---|---|
| `ServerScriptService/ProfileService.server.lua` | DataStore `SupersonicProfile_v1`, clave `u_<UserId>`. Perfil = tabla plana de números (`matches, wins, …, xp, bestKmh, streak…`) + `settings`. Remotes: `GetProfile` (RF), `SubmitMatch` (RE, cliente), `SaveSettings` (RE). BindableEvent `ServerSubmit` (hijo del script) para resultados del servidor. `applyResult` suma stats con topes por partida (`LIMITS`) y `xp += points + 30 + 100·win`. Guarda (`SetAsync`) tras cada partida, al salir y en `BindToClose`. |
| `Game/Progression.lua` | Curva: pasar de nivel *n* a *n+1* cuesta `250 + 100·(n−1)` XP. `MatchXp(points, result)` = `points + 30 + 100·win` (el cliente lo usa solo para mostrar "+XP"). |
| `Game/MatchEvents.lua` | Estadísticas del jugador local en partidas **locales** (goals, assists, saves, epicSaves, shots, clears, demos, aerials, pinches, bestKmh, bestPinchKmh, points). |
| `GameClient.client.lua` → `endMatch()` | Partidas **locales contra bots** (1v1/2v2; se simulan en el cliente): al terminar dispara `SubmitMatch` con el resultado y las stats. Entrenamiento no termina nunca → no envía nada. Si el jugador sale al menú a mitad, no se envía nada. |
| `PartyMinigameService/Minigames/Soccar.lua` → `OnResults` | Partidas **en línea** (colas 1v1/2v2/ranked y salas privadas; bots rellenan huecos). El servidor manda el resultado de cada humano que sigue en la partida a `ServerSubmit` con `online = true, ranked, mode`. Quien abandona es sustituido por un bot y su resultado **no** se envía. |
| `MinigameSession` (estado `RESULTS`) | Rondas de minijuegos de la fiesta: calcula `placements` y reparte Party Points. **Hoy no escribe nada en el perfil.** Una ronda cancelada salta de fase a `CLEANUP` sin pasar por `RESULTS`. |
| `MainMenu.lua` | Tarjeta de perfil arriba a la derecha (avatar, NIVEL, barra de XP, animación de subida de nivel) y modal PERFIL (P / Y). Menú de palabras: JUGAR, GARAJE, ENTRENAMIENTO, RANKED, AJUSTES. |

**Problemas que el diseño tiene que resolver:**

1. **Hay que tratar las partidas locales como no verificables.** Un exploit puede disparar `SubmitMatch` con lo que
   quiera (hoy solo lo frenan los topes por partida y 20 s entre envíos). Deben dar poco y tener un tope propio.
2. **El `load()` actual descarta cualquier campo que no sea numérico** (salvo `settings`). Los créditos, los desafíos
   y todo lo que venga después (inventario, cajas) se perderían al cargar. Encima, un servidor con el código viejo,
   todavía abierto tras publicar, **borraría** esos campos al guardar.
3. `SetAsync` sin bloqueo de sesión: con los teleports entre servidores (códigos de fiesta y sala) dos servidores
   pueden tener el mismo perfil a la vez. Con una moneda en juego eso ya significa perder o duplicar créditos.

---

## 1. Niveles y XP

### 1.1 Curva

Se **mantiene la curva actual** para que ningún jugador cambie de nivel con la migración:

```
coste(n → n+1) = 250 + 100·(n − 1)          -- 250, 350, 450, …
XP total para llegar al nivel L = 250·(L−1) + 50·(L−1)·(L−2)
```

| Nivel | XP total | Nivel | XP total |
|---|---|---|---|
| 5 | 1 600 | 30 | 47 850 |
| 10 | 5 850 | 50 | 129 850 |
| 20 | 21 850 | 100 | 509 850 |

Sin nivel máximo. `Progression.FromXp(xp)` pasa a una forma cerrada (la raíz de la cuadrática y luego un ajuste de
±1), en vez del bucle actual, porque con 500 000 XP el bucle da cientos de vueltas. Da exactamente el mismo resultado
y un test lo compara con el bucle original hasta el nivel 300.

### 1.2 XP por partida (fórmula única, en `Game/Progression.lua`, la usa el servidor)

```
base        = 30                                   -- por terminar la partida
resultado   = victoria 100 · empate 50 · derrota 0
rendimiento = min(puntos, 1500)                    -- puntos del marcador (MatchEvents / Soccar)
XP          = floor((base + resultado + rendimiento) × multFuente)
```

Hasta ahora era `puntos + 30 + 100·victoria`. Cambian tres cosas: el empate da 50, los puntos se topan en 1 500 y se
aplica el multiplicador por fuente (tabla 1.4).

### 1.3 XP por minijuego (ronda de fiesta)

Las rondas duran ≤ 80 s, así que dan menos que una partida:

```
XP = floor((20 + porPuesto[puesto]) × multFuente)     porPuesto = { 80, 50, 30, 20 }  (1.º, 2.º, 3.º, 4.º)
```

Los empates comparten el mejor puesto, como ya hace `PartyServer` con los Party Points.

### 1.4 Fuentes y multiplicadores (el corazón del anti-farmeo)

El servidor clasifica **cada** resultado según quién lo envía y quién jugó. El cliente no puede elegir la fuente.

| Fuente | Cómo la detecta el servidor | XP × | Créditos × |
|---|---|---|---|
| `ranked` | `ServerSubmit` con `online` y `ranked`, y al menos 1 rival humano | 1,15 | 1,2 |
| `online_pvp` | `ServerSubmit` con `online` y al menos 1 **rival** humano al terminar | 1,0 | 1,0 |
| `online_bots` | `ServerSubmit` con `online` y todos los rivales bots (cola sin gente o sala privada en solitario) | 0,85 | 0,5 |
| `local` | `SubmitMatch` desde el cliente (partida sin conexión contra bots) | 0,7 | 0,3 |
| `minigame` | ronda de fiesta con ≥ 2 humanos al terminar | 1,0 | 1,0 |
| `minigame_bots` | ronda de fiesta con 1 humano (el resto bots del anfitrión) | 0,6 | 0,4 |
| `training` | `mode == "training"` (hoy no se envía, pero si llega se rechaza) | 0 | 0 |

Para saber cuántos humanos hay, `Soccar.OnResults` y el nuevo gancho de `MinigameSession` añaden `humans` y
`humanOpponents` al resultado. Son campos nuevos en la tabla que ya se envía; no cambia ninguna regla de partida.

---

## 2. Créditos

### 2.1 Cómo se ganan

| Origen | Créditos | ¿Cuenta para el tope diario? |
|---|---|---|
| Partida (sección 1.4) | `(10 + resultado + min(floor(puntos/100), 10)) × multFuente`, resultado = victoria 20 · empate 12 · derrota 6 → victoria normal ≈ 35–40, derrota ≈ 20 | **Sí** |
| Minijuego | `porPuesto[puesto] × multFuente`, porPuesto = { 12, 8, 5, 3 } | **Sí** |
| Primera victoria del día (UTC), solo en `online_pvp`, `ranked` o `minigame` | +50 créditos y +200 XP, una vez al día | No |
| Subir de nivel (al llegar al nivel L) | `100 + 20·floor(L/5)` (nivel 2 → 100, nivel 10 → 140, nivel 50 → 300) | No: la curva de XP ya lo frena |
| Desafío diario completado | 60 / 80 / 100 según dificultad (+ 150 XP) | No: tiene cantidad fija |
| Desafío semanal completado | 300 / 400 / 500 según dificultad (+ 600 XP) | No |

### 2.2 Anti-farmeo (todo en el servidor, reinicio a las 00:00 UTC)

1. **Tope diario de créditos por partidas y minijuegos: 400.** Al llegar al tope las partidas siguen dando XP pero no
   créditos, y el cliente muestra «TOPE DIARIO DE CRÉDITOS ALCANZADO».
2. **Subtope de la fuente `local`: 90 créditos y 3 000 XP al día.** Es la única fuente que el cliente puede falsear:
   aunque alguien haga trampa, lo máximo que saca son 90 créditos al día.
3. **Ritmo de la fuente `local`:** un resultado local solo da recompensa si han pasado **≥ 240 s** (reloj del servidor)
   desde la última partida local recompensada (el partido dura 300 s). Se siguen sumando las stats de carrera como
   hoy (≥ 20 s entre envíos).
4. **Nada en entrenamiento** (`mode == "training"` se rechaza) **ni en partidas abandonadas:** en línea, quien se va no
   recibe resultado (ya es así); en minijuegos, solo cuentan los humanos que siguen en la sesión al llegar a `RESULTS`;
   una ronda cancelada no pasa por `RESULTS`; en local, salir al menú no envía nada.
5. **Duración mínima de lo que corre el servidor:** una ronda de minijuego con < 15 s en `ACTIVE`, o una partida en
   línea con < 60 s de juego, no da recompensa (se registra el resultado, pero sin XP ni créditos).
6. Los topes por partida de `LIMITS` siguen igual; la XP usa además `min(puntos, 1500)`.

### 2.3 Economía esperada

- Jugador casual (5 partidas en línea + los 3 diarios): ≈ 150 + 240 = **~390 créditos al día**.
- Jugador que apura todo: 400 (tope) + 240 (diarios) + ~170 (semanales repartidos) + subidas de nivel ≈ **~850 al día**.
- Precios orientativos para la fase 2 (cosméticos): Común 150–250 · Rara 400–600 · Épica 1 000–1 400 ·
  Legendaria 2 200–3 000.

Todas las cifras están en `ReplicatedStorage/Economy/EconomyConfig.lua` para poder ajustarlas sin tocar la lógica.

---

## 3. Desafíos

### 3.1 Reglas

- **3 diarios** (se renuevan a las 00:00 UTC) y **3 semanales** (se renuevan el lunes a las 00:00 UTC).
- **Rotación determinista por fecha:** `dia = floor(os.time() / 86400)` y `semana = floor((dia + 3) / 7)` (el
  1-1-1970 fue jueves, así la semana empieza en lunes). La semilla es `hash(dia, "daily")` / `hash(semana, "weekly")`
  y el generador es propio en Luau puro con `bit32` (splitmix32), no `Random`, para que el resultado sea idéntico en
  cualquier servidor y en los tests, sea cual sea la versión del motor. Todos los jugadores tienen los mismos desafíos
  el mismo día.
- **Restricciones de la elección:** 3 tipos distintos, nunca dos de la misma categoría y como mucho **1** que no se
  pueda completar sin conexión (en línea **o** minijuegos, sumados). Así quien solo juega sin conexión puede completar
  siempre al menos 2 de 3.
- El progreso se guarda por periodo: si el periodo guardado ≠ el actual, la lista se regenera con el progreso a 0 (lo
  no completado se pierde, como en RL).
- **Recompensa automática:** al llegar al objetivo, el servidor da los créditos y la XP en el mismo momento; no hay
  botón de reclamar ni remote extra que proteger.
- El resultado se aplica a los desafíos del periodo en que el **servidor** lo procesa.

### 3.2 Tipos de progreso

- `sum`: se suma una estadística de cada resultado (p. ej. goles).
- `count`: +1 por cada resultado que cumple una condición (p. ej. victoria, 3 goles en un partido).
- `best`: se consigue en un solo partido (p. ej. golpe ≥ 110 km/h); el progreso es el mejor valor.

### 3.3 Catálogo (24 tipos; `ReplicatedStorage/Economy/ChallengeCatalog.lua`)

Todos salen de estadísticas que ya existen en `MatchEvents`, `Soccar` o las placements de los minijuegos. Solo se
añaden dos campos al resultado: `scoreFor` y `scoreAgainst` (para la portería a cero). En las partidas en línea los
rellena el servidor; en las locales, el cliente.

| # | id | Texto (UI) | Cat. | Tipo | Fuentes | Diario | Semanal |
|---|---|---|---|---|---|---|---|
| 1 | goals | MARCA {n} GOLES | ataque | sum goals | partidas | 3 | 15 |
| 2 | assists | DA {n} ASISTENCIAS | ataque | sum assists | partidas | 2 | 10 |
| 3 | shots | HAZ {n} TIROS A PUERTA | ataque | sum shots | partidas | 6 | 30 |
| 4 | hatTrick | MARCA 3 GOLES EN UN PARTIDO | ataque | count goals≥3 | partidas | 1 | 3 |
| 5 | saves | HAZ {n} ATAJADAS | defensa | sum saves | partidas | 3 | 15 |
| 6 | epicSaves | HAZ {n} ATAJADAS ÉPICAS | defensa | sum epicSaves | partidas | 1 | 5 |
| 7 | clears | HAZ {n} DESPEJES | defensa | sum clears | partidas | 5 | 25 |
| 8 | cleanSheet | GANA {n} PARTIDOS SIN RECIBIR GOLES | defensa | count win∧scoreAgainst=0 | partidas | 1 | 3 |
| 9 | demos | HAZ {n} DEMOLICIONES | físico | sum demos | partidas | 3 | 15 |
| 10 | aerials | HAZ {n} GOLPES AÉREOS | mecánica | sum aerials | partidas | 4 | 20 |
| 11 | pinches | HAZ {n} PINCHES | mecánica | sum pinches | partidas | 1 | 5 |
| 12 | hardHit | GOLPEA EL BALÓN A {n} KM/H | mecánica | best bestKmh | partidas | 110 | 130 |
| 13 | points | CONSIGUE {n} PUNTOS | general | sum points | partidas | 1 500 | 8 000 |
| 14 | bigGame | CONSIGUE {n} PUNTOS EN UN PARTIDO | general | best points | partidas | 600 | 900 |
| 15 | play | JUEGA {n} PARTIDOS | general | count | partidas | 3 | 15 |
| 16 | wins | GANA {n} PARTIDOS | victoria | count win | partidas | 2 | 10 |
| 17 | streak | GANA {n} PARTIDOS SEGUIDOS | victoria | best streak | partidas | 2 | 4 |
| 18 | wins2v2 | GANA {n} PARTIDOS 2V2 | victoria | count win∧2v2 | partidas | 1 | 5 |
| 19 | onlinePlay | JUEGA {n} PARTIDOS EN LÍNEA | en línea | count | en línea | 2 | 10 |
| 20 | onlineWins | GANA {n} PARTIDOS EN LÍNEA | en línea | count win | en línea | 1 | 5 |
| 21 | rankedPlay | JUEGA {n} PARTIDOS RANKED | en línea | count ranked | en línea | 1 | 5 |
| 22 | mgPlay | JUEGA {n} MINIJUEGOS | minijuegos | count | minijuegos | 3 | 15 |
| 23 | mgWins | GANA {n} MINIJUEGOS | minijuegos | count puesto=1 | minijuegos | 1 | 6 |
| 24 | mgPodium | QUEDA ENTRE LOS 2 PRIMEROS EN {n} MINIJUEGOS | minijuegos | count puesto≤2 | minijuegos | 2 | 10 |

"partidas" = `local`, `online_*` y `ranked` (nunca `training`). Cada tipo tiene una dificultad (1–3) que fija su
recompensa (60/80/100 los diarios, 300/400/500 los semanales).

---

## 4. Solo en el servidor

- El cliente **nunca** envía XP ni créditos. `SubmitMatch` sigue aceptando stats, que se recortan con `LIMITS`; la
  fuente, los multiplicadores, los topes y los desafíos los decide el servidor.
- `Progression.MatchXp` en el cliente pasa a ser solo una **estimación** para el texto inmediato. El número real llega
  por el nuevo `ProfileUpdate` y sustituye al estimado en la pantalla de resultado y en la tarjeta del menú.
- Remotes nuevos, creados por código por `ProfileService` en `ReplicatedStorage.Remotes` (igual que hoy):
  - `ProfileUpdate` (RemoteEvent, servidor → cliente): `{ profile = resumen, reward = desglose? }` tras cada
    recompensa. El desglose es `{ xp, credits, capped, levelsGained, challengesCompleted = {...}, source }`.
  - `GetProfile` (ya existe) devuelve además `credits`, `level`, `challenges` (con los textos resueltos),
    `dailyCap = { earned, max }`, `resetDaily` y `resetWeekly` (segundos que faltan) y `serverTime`.
  - Nada más: no hay remote para reclamar ni para gastar en esta fase.
- Minijuegos: `MinigameSession`, al entrar en `RESULTS` de una ronda de fiesta (`not def.NoPartyPoints`), llama a
  `service.submitMinigame(player, { kind = "minigame", minigameId, placement, humans, activeSeconds })` por cada humano
  que sigue en la sesión, y eso va al mismo `ServerSubmit`. Es la única línea nueva en la lógica de sesiones.

---

## 5. Perfil, guardado y migración

### 5.1 Esquema v2

```lua
{
  schema = 2,
  -- v1 (sin cambios): matches, wins, losses, draws, goals, assists, saves, epicSaves, shots, clears, demos,
  -- aerials, points, xp, bestKmh, streak, bestStreak, pinches, bestPinchKmh, settings
  credits = 0,                 -- saldo
  creditsEarned = 0,           -- total histórico (estadística)
  rewardedLevel = 1,           -- último nivel cuyas recompensas ya se dieron
  econ = { day = 0, earned = 0, localCredits = 0, localXp = 0, firstWinDay = 0 },   -- contadores del día UTC
  challenges = {
    daily  = { period = 0, list = { { id = "goals", progress = 0, done = false }, ... } },
    weekly = { period = 0, list = { ... } },
  },
  minigames = 0, minigameWins = 0,   -- estadísticas nuevas para el perfil
}
```

### 5.2 Reglas de migración (`Economy/ProfileSchema.lua`, puro y testeable)

1. **Se conservan todas las claves guardadas**, también las desconocidas (hoy se tiran). Así un servidor de esta
   versión nunca borra campos que añada una versión futura (inventario, cajas).
2. Sin `schema` → es v1. Pasos encadenados `migrations[1](data) → v2`, `[2] → v3`, … Cada paso solo **añade** campos
   con su valor por defecto; nunca borra ni reduce nada.
3. Después de migrar se rellenan los valores por defecto que falten y se sanea: los números no finitos o negativos
   vuelven a su valor por defecto y las tablas mal formadas se regeneran.
4. Si `schema` guardado > el que entiende el código (un servidor más nuevo lo escribió), el perfil se carga **en solo
   lectura**: se juega pero no se guarda, para no machacar datos nuevos.
5. v1 → v2: `credits = 0`, `rewardedLevel = nivel actual` (no se reparten de golpe los créditos de subida de nivel de
   los niveles ya alcanzados; ver la decisión A), desafíos vacíos, que se generan al cargar.

### 5.3 Guardado

- **DataStore nuevo `SupersonicProfile_v2`.** Al cargar: si no hay nada en v2, se lee `SupersonicProfile_v1`, se migra
  y se sigue en v2. **El v1 no se toca nunca** y queda como copia de seguridad. Un servidor con el código viejo que siga
  abierto tras publicar solo escribe en v1, así que no puede borrar créditos. (Lo que alguien juegue en un servidor
  viejo *después* de migrar no pasa a v2; por eso en la publicación hay que cerrar los servidores antiguos: ver
  «Probar en Studio».)
- `UpdateAsync` en vez de `SetAsync`, con **bloqueo de sesión**: `_lock = { job = game.JobId, t = os.time() }`.
  - Al cargar: si otro servidor tiene el bloqueo y es reciente (< 90 s), se reintenta cada 2 s durante 10 s (cubre el
    teleport: el servidor de origen guarda y suelta el bloqueo al salir el jugador). Pasado ese tiempo el bloqueo se
    considera caído y se toma.
  - Autoguardado cada 60 s si hay cambios (también refresca `_lock.t`), guardado inmediato tras cada recompensa (con
    6 s de margen entre guardados) y al salir, donde se suelta el bloqueo. `BindToClose` igual que hoy.
- Si la carga falla, el perfil sigue siendo **de sesión** (`persistent = false`, como hoy): no se guarda nunca, para no
  machacar el perfil bueno con uno vacío.

### 5.4 Módulos (nuevos y cambiados)

```
ReplicatedStorage/
  Game/Progression.lua              (cambia) curva en forma cerrada, MatchXp/MatchCredits(points, result, source),
                                             MinigameXp/MinigameCredits, LevelCredits
  Game/EconomyClient.lua            (nuevo)  caché del perfil en el cliente, escucha ProfileUpdate, Request()
  Game/ChallengesScreen.lua         (nuevo)  pantalla DESAFÍOS
  Game/MainMenu.lua                 (cambia) créditos en la tarjeta, palabra DESAFÍOS, ShowReward, MainMenu.UI
  Economy/EconomyConfig.lua         (nuevo)  todas las cifras: multiplicadores, topes, recompensas
  Economy/ChallengeCatalog.lua      (nuevo)  los 24 tipos + Rotation(periodIndex, kind) determinista
  Economy/DateUtil.lua              (nuevo)  DayIndex, WeekIndex, SecondsToNextDay/Week, hash + splitmix32
ServerScriptService/
  ProfileService.server.lua         (cambia) script fino: jugadores + remotes -> ProfileStore / Rewards
  Economy/ProfileStore.lua          (nuevo)  DataStore v2 (+ lectura de v1), bloqueo de sesión, guardados, Summary, Push
  Economy/ProfileSchema.lua         (nuevo)  valores por defecto + migraciones (puro)
  Economy/Rewards.lua               (nuevo)  ApplyMatch/ApplyMinigame(profile, raw, ..., now) -> desglose (puro);
                                             ganchos LevelHooks / ChallengeHooks / ResultHooks para las fases 2 y 3
  Economy/Challenges.lua            (nuevo)  Ensure / Apply / View (puro)
  Economy/EconomyTests.lua          (nuevo)  RunAll()
  PartyMinigameService/MinigameSession.lua    (SubmitRound al llegar a RESULTS en rondas de fiesta)
  PartyMinigameService/Minigames/Soccar.lua   (añade humanOpponents / activeSeconds / scoreFor / scoreAgainst)
StarterPlayerScripts/GameClient.client.lua     (envía scoreFor/scoreAgainst; reenvía ProfileUpdate al menú)
```

Los módulos puros reciben `now` como parámetro, así que los tests prueban el cambio de día y de semana sin esperar.

---

## 6. Interfaz

- **Tarjeta del menú:** bajo «NIVEL N» y la barra de XP, un contador de créditos con un rombo dorado hecho con `frame`
  rotado 45°, seguido de «1.250». Cuando llega `ProfileUpdate` sube con `countUp` y muestra «+35» con un fundido.
- **Nueva palabra «DESAFÍOS»** en el menú principal, entre GARAJE y ENTRENAMIENTO. Abre un modal como el de PERFIL
  (panel crema con `brackets`, Oswald y la misma paleta):
  - dos columnas, **DIARIOS** y **SEMANALES**, con «SE RENUEVAN EN 5 H 12 MIN» debajo de cada título;
  - 3 tarjetas por columna: texto del desafío, barra de progreso (`3 / 5`), recompensa («+80 CRÉDITOS · +150 XP») y un
    sello «COMPLETADO» en dorado;
  - pie: «CRÉDITOS DE PARTIDAS HOY: 180 / 400».
  - Mando: `InputGlyphs.PushPanel(g, primeraTarjeta, cerrar)`. Las tarjetas son `TextButton` seleccionables (la
    navegación del motor mueve el marco dorado) y B / Esc cierra. `HintBar` con «VOLVER».
- **Pantalla de resultado** (local y en línea): «+X XP» con el estimado y, al llegar `ProfileUpdate`, se sustituye
  por el real y aparece una franja bajo el panel con «+Y CRÉDITOS», «PRIMERA VICTORIA DEL DÍA», «¡NIVEL N!», «TOPE
  DIARIO…» y «DESAFÍO COMPLETADO: …» según corresponda. Las rondas de minijuegos usan su propia pantalla de resultados
  (PartyUI), así que ahí lo ganado se ve en la tarjeta del menú y en DESAFÍOS.
- **Bono de bienvenida:** la primera vez que un perfil antiguo se migra, la tarjeta muestra «BONO DE BIENVENIDA +N
  CRÉDITOS» durante unos segundos.

---

## 7. Tests (`ServerScriptService/Economy/EconomyTests.lua`, `RunAll()` → nº de tests pasados)

- **Curva:** la forma cerrada = el bucle original para todo xp hasta el nivel 300; los valores de la tabla 1.1;
  `FromXp(0) = 1`; xp negativa o NaN → nivel 1.
- **Recompensas:** victoria/empate/derrota por cada fuente; tope de puntos 1 500; training → 0; la subida de nivel da
  sus créditos una sola vez aunque se ganen varios niveles de golpe.
- **Anti-farmeo:** el tope de 400 se corta exacto (la partida que lo cruza da solo lo que falta); subtope `local`
  90/3 000; ventana de 240 s; el tope se reinicia al cambiar el día UTC; primera victoria del día solo una vez y nunca
  en `local`; `minigame_bots` al 0,4; ronda < 15 s → 0.
- **Rotación:** mismo día → misma lista (100 días seguidos, dos llamadas); 3 ids distintos; ≤ 1 minijuego; ≤ 1 solo-en-
  línea; categorías distintas; cambia entre días consecutivos casi siempre; la semana empieza el lunes 00:00 UTC.
- **Progreso:** sum/count/best; completar da la recompensa una vez; al cambiar de periodo se regenera y el progreso
  anterior no se arrastra.
- **Migración:** un perfil v1 real (con `settings`) → v2 sin perder ningún número ni `settings`; nivel idéntico antes y
  después; claves desconocidas se conservan; valores corruptos (NaN, strings, negativos) → valores por defecto;
  `schema` futuro → solo lectura; migrar dos veces = migrar una.

---

## 8. Decisiones (confirmadas)

- **A. Bono de bienvenida único** al migrar: `min(3 000, 100·(nivel−1))` créditos; los créditos por nivel cuentan a
  partir del nivel actual (`rewardedLevel`). *(No se respondió explícitamente: se aplicó la propuesta; se cambia en
  `EconomyConfig.WELCOME_BONUS`.)*
- **B. Partidas sin conexión:** XP ×0,7 y créditos ×0,3 con subtope diario de 90 créditos / 3 000 XP. *(Igual: propuesta
  aplicada; para dejarlo en 0 créditos basta `SOURCES["local"].credits = 0`.)*
- **C. DataStore nuevo `SupersonicProfile_v2`** con lectura inicial de `_v1`. **Aprobado.**

---

## Probar en Studio

Antes de empezar: sincroniza con Rojo y, para probar el guardado, activa *Game Settings › Security › Enable Studio
Access to API Services*. Sin eso todo funciona igual pero el perfil es de sesión (`persistent = false`) y la ventana
de PERFIL lo dice.

1. **Tests.** En la barra de comandos (vale en modo edición):
   `print(require(game.ServerScriptService.Economy.EconomyTests).RunAll(true))` → debe terminar en **36 / 36 tests
   passed**. Los tests de física siguen igual (`require(game.ReplicatedStorage.Physics.PhysicsTests).RunAll(true)`).
2. **Migración de un perfil existente** (con API Services activado y una cuenta que ya tenga partidas en el juego):
   - Play. La tarjeta del menú muestra el **mismo nivel que antes**, un contador de créditos (`N ◆`) y durante unos
     segundos «BONO DE BIENVENIDA +N CRÉDITOS» (100 por nivel por encima del 1, máximo 3 000).
   - PERFIL (P / Y): todas las estadísticas de carrera son las de antes y hay una línea «N CRÉDITOS» bajo la XP.
   - Barra de comandos del servidor: `print(game:GetService("DataStoreService"):GetDataStore("SupersonicProfile_v1"):GetAsync("u_TU_USERID"))`
     sigue devolviendo el perfil viejo **sin cambios** (sin `credits`, sin `schema`), y
     `...GetDataStore("SupersonicProfile_v2"):GetAsync("u_TU_USERID")` devuelve el nuevo con `schema = 2` y `_lock`.
   - Stop y Play otra vez: el bono **no** se repite y los créditos se conservan.
3. **DESAFÍOS:** la nueva palabra del menú (entre GARAJE y ENTRENAMIENTO) abre el panel con 3 DIARIOS y 3 SEMANALES,
   la cuenta atrás «SE RENUEVAN EN …» baja cada minuto y abajo pone «CRÉDITOS DE PARTIDAS HOY: X / 400».
   - Con mando: las tarjetas se seleccionan con la cruceta (marco dorado), B cierra. Con teclado: ESC cierra. Al
     cerrar, la pulsación no se cuela al menú de palabras.
   - Como mucho 1 de las 3 tarjetas de cada columna lleva «· EN LÍNEA» o «· FIESTA».
4. **Partida sin conexión** (JUGAR › CONTRA BOTS · SIN CONEXIÓN) hasta el final:
   - La pantalla de resultado muestra «+X XP»; un instante después X cambia al valor real (×0,7) y aparece la franja
     con «+Y CRÉDITOS» (pocos: ×0,3) y, si toca, «DESAFÍO COMPLETADO: …».
   - Al volver al menú, la barra de XP y los créditos de la tarjeta suben animados y DESAFÍOS refleja el progreso
     (goles, atajadas…).
   - ENTRENAMIENTO no da nada (no se envía resultado).
5. **Partida en línea** (*Test › Clients and Servers*, 2 jugadores, servidor local):
   - Los dos en la cola 1V1 EN LÍNEA → al terminar, franja con créditos de la fuente «online_pvp» (la victoria da
     ~35–40 + 50 de primera victoria del día).
   - Un solo jugador en la cola (entra con bot a los 8 s) → recompensa reducida (online_bots, créditos ×0,5, sin
     «PRIMERA VICTORIA DEL DÍA»).
   - Salir a mitad de partida (el bot ocupa el coche) → quien sale no recibe nada; el que sigue sí.
6. **Minijuego de fiesta** (2 jugadores en la misma fiesta, una ronda completa): al volver al menú, la tarjeta ha sumado
   XP y créditos, y un desafío de FIESTA en pantalla (si hay uno hoy) avanza. Una ronda con el anfitrión solo y bots da
   menos (×0,4 créditos).
7. **Tope diario:** en la barra de comandos del servidor puedes forzarlo para verlo sin jugar 20 partidas:
   `require(game.ServerScriptService.Economy.ProfileStore).Get(game.Players.TU_NOMBRE).econ.earned = 400`
   → la siguiente partida muestra «TOPE DIARIO DE CRÉDITOS ALCANZADO», da XP pero no créditos de partida.
8. **Salida sin errores:** en Output no debe haber `[ProfileStore] save failed` ni `hook failed`. Con API Services
   desactivado solo debe aparecer una vez `DataStore unavailable, session-only profile`.
9. **Al publicar:** después de *Publish*, usa **Shut Down All Servers** (o *Migrate to Latest Update*) para que no
   quede ningún servidor con el código viejo: esos solo escriben en `_v1`, así que no pueden borrar créditos, pero lo
   que alguien jugara allí tras migrar no pasaría a `_v2`.
