Terminado. Informe completo (leído .swift/.md/.json/.yml completos vía `gh api`, nada clonado de forma persistente, todo en /tmp/gh-explore descartable):

## Resumen del §5 del HANDOFF (para contexto del desempate)

Opción A: `wraith-app` implementa NDJSON-sobre-unix-socket en Swift puro (Foundation `Network`), sin Zig. Opción B: `zkit/ipc` lo implementa una vez en Zig sobre C-ABI, consumido por Swift Y por un "consumer Linux" (Tauri o similar, ADR-0040 T8 — "no headless, Linux primero"). El propio doc fija el desempate: si el consumer Linux llega en semanas, gana B; si en meses, A es lo pragmático.

## 1. wraith-app

- **Qué es**: host nativo macOS del wraith — Swift+AppKit puro, `LSUIElement` (sin UI), solo sostiene identidad TCC firmada + registra 2 LaunchAgents vía `SMAppService`. Privado, creado 21-ago, **3 commits todos el mismo día**, **parado desde entonces** (7 días).
- **Tamaño real**: 5 ficheros Swift, 3905 bytes — leí los 4 con código completo (`AppDelegate`, `TCCProbe`, `WraithApp`, `WraithLog`). Confirma la cifra del doc.
- **Zig/zkit**: cero. Ni una referencia.
- **IPC/NDJSON/unix socket — el dato que decide A vs B**: **no existe nada, está 100% por escribir**. Ningún socket, ningún parser de frames, ninguna referencia a consumer-bus. El propio commit dice explícito que ni el lado JS (gateway-broker.js/gateway-runner.js) está bundled aún. Es pizarra en blanco — coste de retrabajo si se elige B es cero.

## 2. cloudreve-mirror

- **Qué es**: NO es un mirror de upstream de Cloudreve (`isFork:false`, `parent:null`, cero código de Cloudreve vendorizado). "Mirror" = puente bidireccional Cloudreve↔Jellyfin (polling 120s porque el FUSE mount de rclone no propaga inotify): JF→CR importa nuevas pelis/series vía API, CR→JF mueve ficheros de una carpeta inbox a la librería de Jellyfin y notifica refresh.
- **Rol operativo en Helsinki (verificado en `.coolify.json`+`docker-compose.yml`)**: Coolify, server `lab1`, proyecto "Medicina Moderna", UUID `loy3fi5999xomdjtvqkj3xno`, auto-deploy en push a master. 2 contenedores: API+worker de cola (Elysia+Postgres) y `videopt-worker` (sidecar de compresión de vídeo).
- **Actividad**: creado ayer 27-ago 22:04, última actividad HOY 03:49 — 5.5h de desarrollo intensivo, repo muy vivo (no parado).
- **Zig/zkit — hallazgo relevante**: cero Zig trackeado en git, PERO su `CLAUDE.md` (leído completo) declara explícito: `zkit/` como clone local gitignored de referencia ("not consumed yet"), y lista `MKS2508/zkit` como sibling repo con la nota **"`zkit/ipc/` does NOT exist yet (planned port of consumer-bus wire protocol to Zig)"**.
- **Verifiqué que zkit YA EXISTE de verdad** (no es especulación del CLAUDE.md): repo público, creado 27-ago 16:49, Zig, push hoy 03:41. Su árbol real ya tiene `handle.zig`, `subscriber_queue.zig`, `reorder_buffer.zig`, `tracking_allocator.zig`, `watchdog.zig`, `errors.zig` — exactamente lo que el HANDOFF §7.2 pedía rescatar de styx. **No hay `ipc/`** — confirmado. También existen ya `MKS2508/spire` y `MKS2508/conduit` (creados hoy, push 03:49) y `MKS2508/consumer-bus` (privado, creado hoy). El lock #2 del HANDOFF ("repo nuevo dedicado") ya se ejecutó, un día antes de lo que el doc preveía.
- **¿Es el "consumer Linux" que desempata el §5? NO, dicho sin adornos.** cloudreve-mirror sí consume `@mks2508/consumer-bus` (vía `@spire/bus` re-export) y sí corre en Linux en prod — pero en **TypeScript puro, sin FFI, sin C-ABI**. No es el consumer Linux tipo Tauri/desktop de ADR-0040 T8 (esa es la familia wraith-product/menubar/desktop, dominio totalmente distinto al bridge Cloudreve/Jellyfin). Es irrelevante para el desempate A/B de wraith-app, aparte de confirmar que zkit y consumer-bus ya tienen entidad real.

## Conclusión para el desempate

No hay ningún repo/commit visible del consumer Linux nativo de ADR-0040 T8 — sigue sin arrancar. Dato nuevo: la infra de soporte (zkit/spire/conduit/consumer-bus) se materializó en <24h desde que el HANDOFF la proponía como "próxima sesión", lo que abarata el coste de ir a B — pero no hay evidencia de que el consumer Linux esté a "semanas". El desempate del doc sigue abierto; wraith-app no ha avanzado nada que cambie el cálculo.

Repos: `MKS2508/wraith-app` (privado, 3 commits), `MKS2508/cloudreve-mirror` (privado, ~40 commits en 5.5h). Nada tocado fuera de `/tmp/gh-explore`.