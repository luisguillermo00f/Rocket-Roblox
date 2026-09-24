# Rocket Roblox

Rocket League en Roblox: física 1:1 portada de RocketSim, partidas online, modo fiesta con minijuegos en mapas propios.

## Trabajar con Rojo

1. Instala Rojo: `rokit add rojo-rbx/rojo` y el plugin "Rojo" en Studio.
2. En esta carpeta: `rojo serve`
3. En Studio (place "Cohete Roblox"): plugin Rojo → Connect.

Rojo solo sincroniza los scripts de `src/`. Todo lo demás del place (el estadio `workspace.Arena`, Lighting,
modelos, RemoteEvents creados en Studio) vive en el place: guarda y publica desde Studio como siempre.

## Estructura

- `src/ReplicatedStorage/Physics` — simulación (RocketSim portado): World, CarPhysics, BallPhysics, CustomArena…
- `src/ReplicatedStorage/Game` — cliente: cámara, HUD, visuales, sonidos, menús.
- `src/ReplicatedStorage/Party` — modo fiesta: MapKit, predicción, vistas y reglas compartidas de minijuegos.
- `src/ServerScriptService` — servidor: sesiones de minijuegos, matchmaking, perfiles.
- `src/StarterPlayerScripts` — GameClient.
