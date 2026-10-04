# MeloNX Performance — fork baseline

## Upstream

- Upstream repository: https://github.com/AzureDominus/melonx
- Base branch (verified, not assumed — `gh repo view` reported this as
  `defaultBranchRef`): `XC-ios-ht`
- Base commit SHA: `55f84af15144e40d7fbe8984747855534d2a8ec1`
  ("Make LAN remote controller manual-first", 2026-06-02 17:33:47 +0000)
- Date this baseline was captured: 2026-10-04
- Fork: https://github.com/Zerotwo63/melonx-performance

## Filosofía del fork

Mantenernos lo más cerca posible de upstream. Nunca reescribir módulos
existentes que ya funcionan. Cada mejora de rendimiento/JIT vive en su
propio commit pequeño y, cuando el tamaño lo justifique, en su propia rama
`perf/*`, para que `git fetch upstream && git merge upstream/XC-ios-ht`
produzca el mínimo de conflictos posible.

No se modifica, ni se le escribe, ni se abre PR contra
`AzureDominus/melonx`. Todo el trabajo vive únicamente en este fork.

## Cómo actualizar desde upstream

```bash
git fetch upstream
git checkout XC-ios-ht
git merge upstream/XC-ios-ht     # o rebase, según convenga por rama
git push origin XC-ios-ht

# luego, para traer la base nueva a una rama de trabajo:
git checkout perf/jit-integration
git merge XC-ios-ht              # nunca --force, nunca rebase de upstream sobre commits ya pusheados sin avisar
```

No hay auto-merge de upstream configurado (ningún workflow lo hace
automáticamente) — se decide manualmente cada vez, revisando el diff real.

## Estrategia de ramas

```
upstream/XC-ios-ht
        ↓
   XC-ios-ht (este fork, espejo de upstream)
        ↓
   perf/jit-integration   ← rama de trabajo actual
        ↓
   (futuras: perf/benchmark-manager, perf/memory-guard, perf/metalfx, ...)
```

No se crean todas las ramas `perf/*` de antemano — solo cuando un tema
(JIT, memoria, térmico, etc.) esté listo para empezar, para no complicar
Git innecesariamente.

## Qué es nuestro vs. qué es upstream

- Todo archivo no listado aquí es upstream sin modificar.
- Cambios propios hasta ahora (ver también el CHANGELOG al final de este
  documento, que se va actualizando commit por commit):
  - `src/MeloNX/MeloNX/App/Core/JIT/StikJIT/StikEnableJIT.swift` — condición
    TXM invertida corregida, construcción de URL vía `URLComponents`,
    `stikdebug://` primario con `stikjit://` como fallback, detección por
    `canOpenURL` en vez de SpringBoardServices privado (ver
    `docs/PERFORMANCE_FORK.md#jit` abajo y el commit
    `fix(jit): modernize external StikDebug activation`).
  - `src/MeloNX/MeloNX/App/UI/Main/Home/SettingsView/SettingsView.swift` —
    la etiqueta "StikDebug"/"StikJIT" ahora se decide con
    `detectStikTool()` en vez de la API privada (mismo commit).
  - `src/MeloNX/MeloNX/Info.plist` — esquemas `stikdebug`/`stikjit` añadidos
    a `LSApplicationQueriesSchemes` (sin eliminar `melonx`, mismo commit).

## Snapshot técnico en el SHA base

- **Versión declarada de MeloNX**: `2.3` (`VERSION` en
  `src/MeloNX/MeloNX.xcconfig`), `CURRENT_PROJECT_VERSION = 1`.
- **Xcode project**: `src/MeloNX/MeloNX.xcodeproj`, scheme `MeloNX`.
- **Deployment target**: iOS 18.1 (target principal y UI tests);
  iOS 15.0 aparece en un target secundario (confirmado en
  `project.pbxproj`, no asumido).
- **Bundle identifier**: `com.stossy11.personal.PLS-DONT-TAKE.MeloNX` en el
  proyecto fuente; `com.stossy11.MeloNX` es el identifier de distribución
  real (`source.json`).
- **Workflow de compilación iOS**: `.github/workflows/ios-unsigned-ipa.yml`
  — runner `macos-latest`, dispara en push a `XC-ios-ht`/`main`/`master` o
  manualmente vía `workflow_dispatch`. Compila `Release` sin firma
  (`CODE_SIGNING_ALLOWED=NO`), empaqueta `MeloNX-unsigned.ipa` +
  `MeloNX-signing-entitlements.plist`. **No** se dispara automáticamente en
  ramas `perf/*` — hay que lanzarlo manualmente con `workflow_dispatch`
  apuntando a la rama.
- **Entitlements actuales** (`MeloNX.entitlements`, fuente real — nunca
  confundir con `source.json`, que describe el IPA ya firmado por
  AltStore/terceros):
  - `com.apple.developer.wifi-aware`: `Publish`, `Subscribe`
  - `com.apple.developer.kernel.increased-memory-limit`: `true`
  - (`MeloNX-extended.entitlements` añade además
    `com.apple.developer.kernel.extended-virtual-addressing` y
    `application-identifier`)
  - `get-task-allow` **no** está en el `.entitlements` fuente — lo inyecta
    la herramienta de firmado (AltStore/SideStore/etc.) al sideload, no el
    repositorio.

<a id="jit"></a>
## JIT actual (análisis completo, antes de tocar nada)

MeloNX ya implementa **cuatro** mecanismos de adquisición/verificación de
JIT, coexistiendo:

1. **TrollStore** — `AskForJIT.swift` → `apple-magnifier://enable-jit`,
   detectado correctamente con `UIApplication.shared.canOpenURL(...)`
   (éste es el único de los tres esquemas externos que YA sigue el patrón
   correcto — referencia de cómo deben quedar los otros).
2. **StikDebug/StikJIT externo** — `StikJIT/StikEnableJIT.swift`:
   `enableJITStik()` construye la URL `stikjit://enable-jit` y decide si
   adjuntar el script (protocolo de breakpoints iOS 26/TXM) según
   `ProcessInfo.processInfo.hasTXM`. La detección de si StikDebug/StikJIT
   está instalado usa `dlopen` + `SBSLaunchApplicationWithIdentifier` de
   `SpringBoardServices.framework` (API privada).
3. **Protocolo nativo de breakpoints (iOS 26/TXM)** —
   `Dependencies/Dynamic Libraries/BreakpointJIT.framework`
   (`BreakGetJITMapping`, `BreakMarkJITMapping`, `BreakJITDetach`, vía
   `brk #0xf00d` con el comando en `x16`) + `BreakpointHandler.swift`
   (instala un manejador de `SIGTRAP` que avanza el `pc` para que la app no
   crashee si un `brk` ocurre sin que el depurador esté realmente
   adjuntado). Esto YA implementa el lado "cliente" del protocolo universal
   que documenta StikJIT — **no se reimplementa**.
4. **Dual-mapped allocator (.NET)** —
   `src/Ryujinx.Memory/DualMappedJitAllocator.cs`, invocado desde Swift vía
   `RyujinxBridge.initialize_dualmapped()` (`IsJITEnabled.swift`,
   `LaunchGameHandler.configureEnvironmentVariables()`). Mantiene W^X real
   con dos mappings (uno RW, uno RX) del mismo backing — tampoco se toca.

(Existe además `App/Core/JIT/JitStreamerEB/EnableJIT.swift`, un quinto
mecanismo vía HTTP a `http://[fd00::]:9172/attach/<pid>` —
pero no está conectado a ningún toggle ni llamado desde
`LaunchGameHandler.enableJIT()`. Es código inactivo en este build, no un
mecanismo real en uso; se menciona solo para que quede registrado.)

Verificación de JIT listo: `isJITEnabled()` en `IsJITEnabled.swift`:
- Si la app tiene el entitlement `dynamic-codesigning` (jailbreak/TrollStore
  con firma especial) → solo `allocateTest()` (mmap+mprotect real).
- Si no, y es iOS 19+: `checkDebugged()` (bit `CS_DEBUGGED` vía `csops`) **Y**
  `LaunchGameHandler.succeededJIT` (resultado de
  `RyujinxBridge.initialize_dualmapped()`).
- Si no, pre-iOS 19: `checkDebugged()` **Y** `allocateTest()`.

### Hallazgo verificado: condición TXM invertida

`StikEnableJIT.swift`, función `enableJITStik()`:

```swift
if #available(iOS 19.0, *), !ProcessInfo.processInfo.hasTXM {
    // construye la URL CON el script de breakpoints adjunto
} else {
    // construye la URL SIN script
}
```

Se verificó contra la documentación oficial actual de StikJIT
(`StikDebug/StikJIT`, `INTEGRATION.md`, sección "Part 1: Add iOS 26 JIT
support"), cita textual:

> "On a device where TXM/SPTM is **not present**, attaching and detaching
> the debugger is enough to enable JIT. **Where TXM/SPTM is present**, the
> debugger flag alone is not enough: each executable memory region must be
> prepared through the debug connection before the app executes code from
> it."

Es decir: el script (protocolo de breakpoints) se necesita **cuando SÍ hay
TXM/SPTM**, no cuando no lo hay. La condición actual de MeloNX está
invertida — hace exactamente lo contrario de lo documentado. Esto se
corrige en el primer commit de esta rama (ver el mensaje de ese commit
para el detalle exacto del cambio).

### Corrección: el hallazgo anterior sobre "JIT sin esperar" era incorrecto

Una versión anterior de este documento afirmaba que `startGame()` no
esperaba a que el JIT estuviera listo. Se verificó contra el flujo real de
UI (`ContentView.swift`, `JITPopover.swift`, `LoadingOverlayView.swift`) y
es **falso** — se corrige aquí según la regla de este fork de nunca dejar
una hipótesis técnica errónea sin corregir.

El flujo real sí bloquea el arranque del juego hasta que el JIT está
confirmado:

1. `LaunchGameHandler.shouldCheckJIT` es `true` cuando hay un juego
   seleccionado y `ryujinx.jitenabled` todavía es `false`.
2. Mientras sea `true`, `ContentView` presenta `JITPopover` como
   `fullScreenCover` — **no** el flujo de emulación.
3. `JITPopover.onAppear` llama a `gameHandler.enableJIT()` (dispara
   TrollStore o StikDebug/StikJIT según el toggle activo) y arranca un
   `Timer` que sondea `isJITEnabled()` cada 0.5s.
4. Solo cuando ese sondeo devuelve `true` se cierra el popover, se llama
   `Ryujinx.shared.checkForJIT()` (refresca `jitenabled`) y recién entonces
   `shouldLaunchGame` pasa a `true`, mostrando `EmulationContainerView` →
   `LoadingOverlayView`, cuyo `startEmulationCallback` es lo único que
   invoca `gameHandler.startGame()`.

El juego físicamente no puede arrancar antes de que `isJITEnabled()` haya
devuelto `true` al menos una vez.

### Problemas reales verificados (éstos sí son el objetivo del `JITCoordinator`)

1. **`isJITEnabled()` tiene un efecto secundario no memoizado**: llama
   incondicionalmente a `RyujinxBridge.initialize_dualmapped()` en cada
   invocación (`IsJITEnabled.swift`). El `Timer` de `JITPopover` lo invoca
   cada 0.5s mientras espera, así que esa rutina nativa de inicialización
   del allocator dual-mapped puede ejecutarse decenas de veces durante una
   sola espera de JIT. No se puede verificar desde Swift si llamadas
   repetidas son seguras (la implementación está en el puente .NET) — se
   deja documentado como riesgo medible, no como bug confirmado.
2. **Dos implementaciones de "esperar al JIT" duplicadas e inconsistentes**:
   - `JITPopover`: `Timer` sin límite de intentos ni timeout — si la
     herramienta externa nunca responde (usuario cancela, app no
     instalada, red/VPN caída), sondea cada 0.5s para siempre sin mostrar
     error.
   - `ContentView.checkJITAndRunGame()`: recursión con tope de 6 intentos
     × 0.5s (3s) — pero es un camino distinto (resumir un juego tras
     relanzar la app desde la herramienta externa vía `gametorun`
     `AppStorage`), no la misma función.
3. **`JitStreamerEB/EnableJIT.swift` existe en el árbol pero no está
   conectado**: no hay ningún toggle en `nativeSettings` ni ninguna
   llamada desde `LaunchGameHandler.enableJIT()` que lo invoque. Es código
   inactivo en este build — se corrige aquí el conteo anterior de "cuatro
   mecanismos de JIT" (TrollStore/StikDebug/breakpoints nativos/dual-mapped
   allocator): JitStreamerEB no es un quinto mecanismo activo, es código
   muerto.

El `JITCoordinator` centraliza el punto 2 (una sola implementación de
espera, con tope y manejo de fallo) y deja documentado el punto 1 para
medición posterior, sin tocar `isJITEnabled()` (usado también desde
`SettingsView` y `ContentView` fuera de este flujo — cambiar su firma ahí
sería un cambio no relacionado, fuera de alcance de este commit).

## CHANGELOG de este fork (se actualiza por commit)

| Commit | SHA | Qué cambia | Por qué |
|---|---|---|---|
| `chore: establish performance fork baseline` | `b4f2c9b30` | Este documento | Registrar la base exacta antes de tocar nada |
| `fix(jit): modernize external StikDebug activation` | `f873baf4b` | `StikEnableJIT.swift`, `SettingsView.swift`, `Info.plist` | Condición TXM invertida (ver sección JIT arriba) + URL vía `URLComponents` + detección por `canOpenURL` en vez de SpringBoardServices privado |
