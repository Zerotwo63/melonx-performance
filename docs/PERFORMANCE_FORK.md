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
  - `src/MeloNX/MeloNX/App/Core/JIT/JITCoordinator.swift` (nuevo) — loop de
    sondeo único y cancelable para el estado de JIT. Ahora conectado a
    `JITPopover` y `ContentView.checkJITAndRunGame()` (ver `#jit` abajo).
    Añadido soporte para llamadas concurrentes (`pendingCompletions`): si
    alguien llama `waitForJIT` mientras otro loop ya está en curso, se
    encola en vez de perder su `completion`; `cancel()` no tumba el timer
    si hay completions encoladas de otro llamador, para no dejarlas
    colgadas para siempre.
  - `src/MeloNX/MeloNX/App/UI/Main/Home/JITPopover/JITPopover.swift` — su
    `Timer` manual (nunca invalidado salvo en éxito) se reemplaza por
    `JITCoordinator.shared.waitForJIT(...)`, con `.onDisappear { cancel() }`
    corrigiendo la fuga documentada arriba.
  - `src/MeloNX/MeloNX/App/UI/Main/Home/ContentView.swift` —
    `checkJITAndRunGame()` pierde su parámetro `attempt`/recursión manual;
    usa `JITCoordinator.shared.waitForJIT(maxAttempts: 6, interval: 0.5)`
    con el mismo tope de 6 intentos que tenía antes.
  - `src/MeloNX/MeloNX/App/Core/JIT/BuiltInStikJITAvailability.swift` —
    preflight de disponibilidad para Built-in StikJIT (ver
    `#builtin-stikjit` abajo); ahora incluye `.helperMissing` y
    `helperIdentifier` (bundle ID real del `.appex`, leído, no asumido).
  - `src/MeloNX/MeloNXJITHelper/` (target `MeloNXJITHelper`, producto
    `.appex`) — la extensión helper real que enlaza
    `StikJIT.xcframework` (ver `#builtin-stikjit`). Embebida en el host
    vía la fase "Embed Foundation Extensions" (ya existía vacía en el
    proyecto).
  - `src/MeloNX/MeloNX/App/Core/JIT/BuiltInStikJIT/` —
    `MeloNXBuiltInJIT.swift` (el lanzador del lado host, API privada
    `NSExtension`), `MeloNXJITHelperRequest.swift` (copia del lado host
    del modelo `Codable`), `PairingFileImporter.swift` +
    `PairingFileImportRow.swift` (import real del pairing file, ver
    `#builtin-stikjit`). Sin call sites desde
    `LaunchGameHandler`/`ContentView` todavía.
  - `src/MeloNX/MeloNX/Dependencies/XCFrameworks/StikJIT.xcframework/`
    (vendoreado, `StikDebug/StikJIT` v1.9.0, MPL-2.0) — mismo patrón que
    los demás XCFrameworks ya vendoreados ahí (SDL2, FFmpeg, etc.).
  - `.github/workflows/ios-unsigned-ipa.yml` — el paso de empaquetado
    ahora también copia `StikJIT.framework` a
    `MeloNX.app/Frameworks/` (igual que ya hace con
    `Ryujinx.Headless.SDL2.dylib`) y verifica que el `.appex` quedó
    embebido en `PlugIns/`.

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
2b. **Fuga confirmada en `JITPopover`**: su `Timer` solo se invalida dentro
   de la rama de éxito (`isJIT == true`); no hay `onDisappear` ni una
   referencia guardada que lo cancele. Si el popover desaparece por
   cualquier otro motivo (p. ej. `currentGame` vuelve a `nil`), el `Timer`
   sigue vivo y sigue llamando `isJITEnabled()` cada 0.5s — y, a través de
   ella, `RyujinxBridge.initialize_dualmapped()` — indefinidamente durante
   el resto del proceso.
3. **`JitStreamerEB/EnableJIT.swift` existe en el árbol pero no está
   conectado**: no hay ningún toggle en `nativeSettings` ni ninguna
   llamada desde `LaunchGameHandler.enableJIT()` que lo invoque. Es código
   inactivo en este build — se corrige aquí el conteo anterior de "cuatro
   mecanismos de JIT" (TrollStore/StikDebug/breakpoints nativos/dual-mapped
   allocator): JitStreamerEB no es un quinto mecanismo activo, es código
   muerto.

El `JITCoordinator` (`App/Core/JIT/JITCoordinator.swift`) centraliza los
puntos 2 y 2b (una sola implementación de espera, cancelable, con tope
opcional) y deja documentado el punto 1 para medición posterior, sin
tocar `isJITEnabled()` (usado también desde `SettingsView` y `ContentView`
fuera de este flujo — cambiar su firma ahí sería un cambio no relacionado,
fuera de alcance de este commit). Es un archivo nuevo, aditivo: ningún
call site existente lo usa todavía — `JITPopover` y
`checkJITAndRunGame()` siguen con su lógica actual hasta el commit que
los migre, que se hace por separado para no mezclar "agregar la pieza" con
"cambiar el comportamiento en vivo del flujo de lanzamiento".

<a id="builtin-stikjit"></a>
## Built-in StikJIT (sección 9 del pedido original): arquitectura real, verificada

Verificado contra el repo real `StikDebug/StikJIT` (licencia **MPL-2.0**,
no GPLv3 — compatible como dependencia de un proyecto GPLv3 como MeloNX
sin obligar a relicenciar nada propio) y su `INTEGRATION.md` actual, no
inventado.

### Qué es StikJIT.xcframework

Un XCFramework precompilado que habilita JIT para otro proceso sobre el
túnel RSD del dispositivo (el mismo mecanismo de depuración inalámbrica
moderno de Apple). Bundlea su propio FFI de
[`idevice`](https://github.com/jkcoxson/idevice) y los scripts
`universal.js`/`legacy.js` — no hay que reimplementar el protocolo RSD ni
el cliente idevice, se integra el framework ya compilado tal cual (esto
es exactamente lo que la sección 19 del pedido pide: preferir integrar
StikJIT directamente en vez de copiar de Madeira o reimplementar).

### Por qué esto NO es "agregar un archivo Swift más"

A diferencia de `JITCoordinator`, Built-in StikJIT **requiere un segundo
proceso** — un proceso no puede adjuntarse un depurador a sí mismo:

```text
App anfitriona (MeloNX): PID objetivo, datos del pairing file, chequeo
de get-task-allow
    ↕ XPC u otro mecanismo de IPC
Extensión helper (app extension): enlaza StikJIT.xcframework, cache de
DDI, trabajo bloqueante
```

Esto significa crear un **nuevo target de Xcode** (una app extension)
que enlace el `.xcframework` — MeloNX no debe enlazarlo fuerte en el
target principal (para no romper el soporte de versiones de iOS más
viejas que el mínimo del helper). Esta pieza **no se crea en este
commit**: este repositorio no usa XcodeGen (a diferencia del propio
StikJIT, que sí) — `project.pbxproj` está escrito a mano, y fabricar a
mano un `PBXNativeTarget` nuevo completo (product type de app extension,
build phases, embed-extension phase, Info.plist propio, entitlements
propios) sin Xcode real para validarlo — solo con el build de CI como
único feedback, a ~7 minutos por intento — es exactamente el tipo de
cambio de alto riesgo y alto radio de impacto (podría dejar de compilar
el proyecto *entero*, no solo la función nueva) que corresponde señalar
explícitamente antes de intentarlo, en vez de hacerlo a ciegas.

### Lo que sí se hizo en este commit (bajo riesgo, aditivo, verificado)

`App/Core/JIT/BuiltInStikJITAvailability.swift` (nuevo) — el preflight
del lado anfitrión que `INTEGRATION.md` exige ("Gate every entry point"),
reutilizando utilidades que MeloNX ya tiene en vez de inventarlas:
- `get-task-allow` → `checkAppEntitlement("get-task-allow")` (ya existe
  en `EntitlementChecker.swift`, ya usado en `SettingsView.swift` para
  mostrar estado — aquí se usa como gate real, no solo display).
- Detección de LiveContainer → `isInLiveContainer.0` (ya existe en
  `FilePickerfix.swift`, más completa que el `getenv("LC_HOME_PATH")`
  genérico del ejemplo de `INTEGRATION.md`). Built-in StikJIT está
  explícitamente excluido ahí porque LiveContainer no puede crear la
  extensión helper requerida.
- Existencia del pairing file en `Documents/StikJIT/pairingFile.plist`
  (la ruta recomendada por `INTEGRATION.md`) — solo el *check de
  existencia*; importar uno (picker, copia atómica, `UIFileSharingEnabled`)
  es "pairing-file management", la sección 10 del pedido original, por
  separado.
- El gate de iOS 17.4+ que pide `INTEGRATION.md` se omite a propósito:
  el deployment target de MeloNX ya es 18.1, así que esa comprobación
  sería código muerto siempre-verdadero.

### Actualización: el target de extensión sí se creó (commit siguiente)

Lo anterior describía el estado "solo preflight, sin extensión". Se
decidió proceder con la extensión real — el usuario autorizó
explícitamente intentar la cirugía de `project.pbxproj` a mano, con
verificación dura vía CI. Antes de escribir una sola línea se buscó
evidencia real de cómo otros integradores resuelven exactamente este
problema (en vez de inventar), encontrando:

- **`willfaust/Madeira`** (GPL-3.0-or-later, mismo árbol de licencia que
  MeloNX/Ryujinx — su "Converter Exception" es sobre enlazar el Metal
  Shader Converter de Apple, no relacionado, no restringe nada aquí): su
  target `MadeiraJITHelper` es la referencia real de cómo construir este
  tipo de extensión en iOS. No se copió su texto — se escribió código
  propio — pero su arquitectura es la base verificada de lo que sigue.
- El mecanismo real (confirmado en `project.pbxproj`/`Info.plist` de
  Madeira) **no** es Network Extension ni ningún punto de extensión
  documentado públicamente para esto: es un "classic app extension"
  (`productType = com.apple.product-type.app-extension`) registrado bajo
  `NSExtensionPointIdentifier = com.apple.ar.viewer` (un punto de
  extensión AR Quick Look reutilizado, con
  `NSExtensionActivationRule = FALSEPREDICATE` para que el sistema nunca
  lo active por su vía normal) más un diccionario `XPCService`
  (`CFBundlePackageType = XPC!`). Se arranca desde el host vía la API
  privada `NSExtension`/`ExtensionFoundation`
  (`extensionWithIdentifier:`/`beginExtensionRequestWithInputItems:...`)
  — la misma que usa LiveContainer para su "LiveProcess". Es una API
  privada, no seguro para App Store — consistente con el resto de este
  proyecto (sideload-only, igual que `SecTaskCopyValueForEntitlement` en
  `EntitlementChecker.swift`).
- `StikJIT.xcframework` publica un release precompilado real
  (`StikDebug/StikJIT` v1.9.0, `StikJIT.xcframework.zip`, solo
  `ios-arm64`, sin slice de simulador). Se vendoreó directamente en
  `src/MeloNX/MeloNX/Dependencies/XCFrameworks/StikJIT.xcframework/`,
  siguiendo la convención que MeloNX ya usa para SDL2/FFmpeg/etc. (no
  Git LFS — esos tampoco lo usan, y el zip son solo 1.7MB) en vez del
  patrón de Madeira de descargarlo en CI.
- El `.swiftinterface` real del framework (compilador real, no
  `INTEGRATION.md`) confirma `-target arm64-apple-ios17.4` — por eso el
  target del helper usa `IPHONEOS_DEPLOYMENT_TARGET = 17.4`, no el 18.1
  del host ni el 26.0 que eligió Madeira (una decisión propia de ellos,
  sin relación con el mínimo real de StikJIT). También confirma el
  overload de `enableJIT` recomendado (con `ddiPaths:`, no el deprecado
  sin él) y que el framework no trae `Info.plist` propio (confirmado por
  archivo, no por el comentario de Madeira) — se sintetizó uno estático
  una sola vez en vez de regenerarlo en cada build como hace su shell
  script.

**Qué se construyó** (`src/MeloNX/MeloNXJITHelper/`, nuevo target
`MeloNXJITHelper`, producto `MeloNXJITHelper.appex`):
- `Info.plist` — el mismo mecanismo `com.apple.ar.viewer`/`XPCService`
  verificado arriba.
- `MeloNXJITHelperRequest.swift` — el modelo `Codable` del
  request/response JSON que viaja en `NSExtensionItem.userInfo`.
  Duplicado (no compartido vía membership cruzado de grupo sincronizado)
  a propósito: compartirlo requeriría tocar las excepciones del grupo
  sincronizado del HOST (`MeloNX`), que ya funciona — no vale el riesgo
  por un struct de 20 líneas.
- `MeloNXBreakpointScript.swift` — el mismo script base64 que
  `StikEnableJIT.swift` le manda a la app externa StikDebug (verificado
  byte a byte idéntico), para que ambos caminos de JIT ejecuten el mismo
  protocolo. Duplicado por la misma razón que el modelo de arriba.
- `MeloNXJITHelperHandler.swift` — `NSExtensionRequestHandling` real,
  llamando `StikJIT.prepareDevice`/`enableJIT`/`resetCachedDDI` de
  verdad, con `script: .customBase64(meloNXBreakpointScript)` (no
  `.universal`: MeloNX tiene su propio archivo de protocolo, no el
  `universal.js` empaquetado por StikJIT, aunque implemente el mismo
  protocolo) y `forceScript: false` (el default documentado — StikJIT
  decide internamente si hace falta el script según TXM, igual que ya
  hace `enableJITStik()` del lado StikDebug).

### Lanzador del lado host (commit siguiente)

Se agregó el equivalente al `JITBuiltInHost.swift` de Madeira:
`App/Core/JIT/BuiltInStikJIT/MeloNXBuiltInJIT.swift` — código propio,
mismo mecanismo verificado (la API privada
`NSExtension`/`ExtensionFoundation`, la misma que usa LiveContainer para
su "LiveProcess"), más `MeloNXJITHelperRequest.swift` (copia del lado
host del modelo `Codable`, por la misma razón de no tocar las
excepciones del grupo sincronizado del host explicada arriba — ambas
copias se verificaron idénticas byte a byte en su estructura).

`BuiltInStikJITAvailability` se extendió con un caso nuevo,
`.helperMissing`, y `helperIdentifier` (lee el bundle ID real de
`MeloNXJITHelper.appex` desde `Bundle.main.builtInPlugInsURL`, en vez de
asumirlo — un sideloader puede renombrarlo o, según la herramienta,
eliminar las app extensions directamente). `MeloNXBuiltInJIT.send(...)`
reutiliza este preflight completo antes de intentar nada.

**Qué NO se conectó todavía**: `LaunchGameHandler`/`ContentView` no
llaman a `MeloNXBuiltInJIT.send(...)` — eso sería agregar "Built-in
StikJIT" como una tercera opción mutuamente excluyente en el selector de
método de JIT (junto a Wait for Debugger/StikDebug), un cambio de
comportamiento en vivo que además no puede probarse end-to-end sin el
flujo de importar un pairing file real (sección 10, aparte) y un
dispositivo físico. Lo que CI puede verificar aquí es que el lanzador
compila y que su forma coincide con la API privada real (por tipo —
Swift no puede verificar en tiempo de compilación que los selectores
`@objc` existan de verdad en el runtime, eso solo se confirma en un
dispositivo); no puede verificar que la extensión se lance o que el
protocolo de JIT funcione. Eso se dice explícitamente, no se da por
hecho.

### Pairing-file management (sección 10, commit siguiente)

Implementado según `INTEGRATION.md` ("Built-in StikJIT: Store and import
the pairing file"), verificado contra el texto real, no inventado:

- `PairingFileImporter.swift` (nuevo) — copia el archivo elegido a
  `BuiltInStikJITAvailability.pairingFileURL`
  (`Documents/StikJIT/pairingFile.plist`, la ruta que recomienda el
  propio `INTEGRATION.md`), con acceso security-scoped durante la copia
  (`startAccessingSecurityScopedResource`) y reemplazo atómico
  (`Data.write(options: .atomic)`). No registra el contenido del archivo
  en ningún log, como pide la guía.
- `PairingFileImportRow.swift` (nuevo) — la fila de UI real ("Import
  Pairing File" + estado "Imported"/"None"), usando `.fileImporter` de
  SwiftUI (no un `UIDocumentPickerViewController` envuelto a mano — ya es
  lo idiomático en una app 100% SwiftUI como esta). Insertada con un
  único cambio de una línea en `SettingsView.swift`
  (`jitAndMiscCard`, justo debajo de `jitToggleView`) — no se tocó nada
  más de ese archivo de ~3000 líneas.
- `Info.plist`: se agregó `LSSupportsOpeningDocumentsInPlace` (acceso en
  el lugar desde la app Archivos, la otra mitad opcional de la
  recomendación). `UIFileSharingEnabled` ya estaba presente desde antes
  de este fork — no fue necesario agregarlo.
- `import UniformTypeIdentifiers` (para `UTType` en `.fileImporter`) es,
  hasta donde se pudo confirmar grepeando el proyecto, el primer uso real
  de ese framework en todo el código — estaba listado en el grupo
  "Frameworks" del navegador pero sin ningún `PBXBuildFile` que lo
  enlazara y sin ningún `import` previo. No se asumió que esto compilaría
  limpio solo porque el framework "está en el proyecto" — se dejó que el
  build de CI lo confirmara (frameworks de solo-tipos como este
  normalmente auto-enlazan, pero "normalmente" no es lo mismo que
  verificado).

### Conectado al selector de método de JIT (commit siguiente)

El selector real de MeloNX no es un enum de tres opciones mutuamente
excluyentes como sugiere `INTEGRATION.md` — es una cadena
`if/else if` sobre dos `Bool` independientes
(`nativeSettings.useTrollStore`, `nativeSettings.stikJIT`) en
`LaunchGameHandler.enableJIT()`, cada uno respaldado por
`NativeSettingsManager`'s `@dynamicMemberLookup` (`Setting<T>`
respaldado en `UserDefaults`, sin clase nueva que escribir — el mismo
mecanismo que ya usan `stikJIT`/`useTrollStore`/`checkForUpdate`/etc.).
Se respetó esa arquitectura real en vez de reemplazarla por un enum
"ideal": se agregó una tercera rama, `nativeSettings.builtInStikJIT`,
al final de la cadena existente:

```swift
} else if nativeSettings.builtInStikJIT.value {
    gametorunDate = "\(Date().timeIntervalSince1970)"
    gametorun = currentGame?.titleId ?? ""
    MeloNXBuiltInJIT.enableCurrentProcess()
}
```

`MeloNXBuiltInJIT.enableCurrentProcess()` (nuevo) lee el pairing file
importado, arma el `MeloNXJITHelperRequest(operation: .enable, ...)` y
llama `send(...)` — dispara la solicitud y retorna, igual que
`askForJIT()`/`enableJITStik()`. No hace falta tocar `JITCoordinator`:
un `StikJIT.enableJIT()` exitoso deja `CS_DEBUGGED` activo en este
proceso, que es exactamente lo que `isJITEnabled()` ya comprueba — el
mismo poll de `JITPopover`/`checkJITAndRunGame` que ya funciona para
los otros dos métodos observa el resultado sin cambios.

En `SettingsView.swift` (`jitToggleView`) se agregó el tercer
`SettingsToggle`, deshabilitado vía `.disabled(!BuiltInStikJITAvailability.isAvailable)`
con un mensaje que explica el motivo exacto (reutilizando
`unavailableReason()` — el mismo preflight que ya usa
`MeloNXBuiltInJIT.send`, una sola fuente de verdad).

**Qué sigue sin poder verificarse aquí**: CI confirma que esto compila
y que la cadena de prioridad/el toggle encajan con el resto del
código real del proyecto (no uno inventado) — no puede confirmar que
el helper realmente se lance, que el protocolo de JIT complete, ni que
`isJITEnabled()` efectivamente pase a `true` en un dispositivo real.
Eso requiere un pairing file real y hardware físico, ninguno de los
cuales existe en este entorno de CI.

## JitStreamerEB como mecanismo interno (StikDebug ya no es requisito)

**Causa real, verificada por lectura del repositorio (no asumida):**
el pedido original decía que `JITCoordinator` "todavía no está
conectado", pero una lectura fresca de `JITPopover.swift` y
`ContentView.checkJITAndRunGame()` mostró que ambos YA llamaban a
`JITCoordinator.shared.waitForJIT(...)` desde el commit
`656e29273` (ver fila del changelog). Lo que sí estaba desconectado
—con cero llamadores en todo el repo— era
`JitStreamerEB/EnableJIT.swift`: un cliente HTTP completo para
`jkcoxson/JitStreamer-EB` que nunca se invocaba desde
`LaunchGameHandler.enableJIT()`. Esa es la razón real por la que JIT
requería StikDebug: no porque faltara el mecanismo interno, sino
porque el mecanismo interno existía en el código y no se usaba.

**Qué es `JitStreamerEB` en realidad** (confirmado contra el README
real del proyecto vía `gh api repos/jkcoxson/JitStreamer-EB`, no
inventado): un servidor Rust + VPN WireGuard que, tras recibir un
pairing file, entrega al dispositivo una config que enruta
`fd00::/64` hacia `fd00::9172`, donde expone `/attach/<pid>` (adjunta
un debugger al proceso indicado, otorgando JIT) y `/hello` (liveness).
"LocalDevVPN" —que el usuario ya tiene configurado como parte de su
flujo— es el cliente VPN externo que provee ese túnel; MeloNX nunca
necesitó construir la VPN, solo ser un cliente HTTP correcto una vez
que el túnel está arriba. Los valores `9172`/`fd00::` que ya estaban
hardcodeados en el archivo muerto coinciden exactamente con los
default reales del proyecto — no eran arbitrarios, solo nunca se
habían conectado a nada.

**Qué se cambió:**

- `JitStreamerEB/EnableJIT.swift`: reescrito de llamadas basadas en
  completion-handlers/`DispatchSource` a `async`/`await`
  (`try await URLSession.shared.data(for:)`,
  `try? await Task.sleep(nanoseconds:)`). Expone
  `JITStreamerEB.attach() async -> Bool` — antes la función disparaba
  la petición y solo informaba el resultado vía alerta, sin que ningún
  llamador pudiera decidir nada en base al resultado real. Se eliminó
  código sin llamadores externos (`enableJITEB`, `enableJITEBRequest`,
  `LaunchApp`, `showLaunchAppAlert`); `presentAlert(...)` se preservó
  intacto porque `Ryujinx.swift` sí lo usa.
- `LaunchGameHandler.enableJIT()`: ahora intenta `JITStreamerEB.attach()`
  primero y de forma incondicional, dentro de
  `Task { @MainActor in ... }`. Solo si falla (`!acquired`) cae a la
  cadena existente TrollStore → StikDebug → Built-in StikJIT, cada
  una todavía gateada por su propio toggle en `nativeSettings` — esos
  tres métodos no cambiaron de comportamiento, solo pasaron a ser
  fallback explícito en vez de ser el único camino.
- `JITCoordinator.swift`: sin cambios de lógica (el dedup vía
  `pendingCompletions` y el no-op de `cancel()` cuando hay otros
  llamadores en espera ya eran correctos desde `656e29273`); solo se
  agregaron los `print("[JIT] ...")` pedidos en los puntos de
  transición de estado reales (`waiting` al iniciar el primer poll,
  `acquired`/`timed out` en ambas rutas de resolución).

Flujo resultante al tocar Play: `enableJIT()` dispara
`JITStreamerEB.attach()` → si el túnel LocalDevVPN está arriba y
`/attach/<pid>` responde con éxito, `Ryujinx.checkForJIT()` se
re-evalúa y el poll existente de `JITPopover`/`checkJITAndRunGame` vía
`JITCoordinator` observa `isJITEnabled() == true` sin cambios — nunca
hizo falta tocar esa ruta de espera, porque ya era correcta. Si el
intento interno falla, recién ahí entra la cadena de fallback, y solo
si el usuario activó alguno de esos toggles.

**Qué sigue sin poder verificarse aquí**: igual que con Built-in
StikJIT, CI solo puede confirmar que esto compila y que la cadena de
prioridad es real (no inventada). No puede confirmar que
`fd00::9172` responda, que LocalDevVPN entregue el túnel, ni que
`/attach/<pid>` devuelva `success: true` — eso requiere el túnel
LocalDevVPN real y hardware físico.

## Bug 1 — onboarding no avanzaba con keys/firmware en verde

**Causa raíz, verificada por lectura de `SetupView.swift` y `MeloNXApp.swift`
(no asumida):** `isInSetup`/`inSetup` (`@AppStorage("hasbeenfinished")`) solo se
pone en `false` en dos sitios: el botón "Finish Setup" (que se *habilita*
cuando `firmImported && keysImported`, pero nadie lo pulsa automáticamente)
y el gesto oculto de doble-tap en "Welcome to MeloNX" que abre el diálogo de
Skip. `keysImported`/`firmImported` sí se actualizaban correctamente al
importar cada archivo — el checkmark verde es real — pero **ningún
`.onChange` ni comprobación re-evaluaba esa condición para avanzar la
pantalla por sí sola**. El usuario no estaba viendo un bug de `@State` que no
notifica (SwiftUI sí propagaba los cambios correctamente); estaba viendo que
la única acción que consulta `keysImported && firmImported` es un botón que
requiere un tap manual, y que la UI nunca lo comunicaba como "pendiente de tu
confirmación" — de ahí que recurriera al atajo de Skip vía "Welcome".

**Archivo y función responsables:** `SetupView.swift` — faltaba cualquier
observador sobre `keysImported`/`firmImported` que reevaluara el avance;
`MeloNXApp.swift` no tiene este problema, solo lee `inSetup` para decidir
qué vista mostrar.

**Corrección:** nueva `OnboardingGate` (`App/UI/Setup/OnboardingGate.swift`),
un `struct` puro con `requirementsSatisfied`/`currentStep`/`blockedReason` —
testeable sin SwiftUI. `SetupView` ahora llama `reevaluateOnboardingState()`
desde `.onChange(of: keysImported)`, `.onChange(of: firmImported)`, y al
final de `.onAppear` (cubre reabrir la pantalla/la app con ambos ya
instalados, donde no hay ningún cambio que dispare un `onChange`). Cuando
`OnboardingGate.requirementsSatisfied == true`, pone `isInSetup = false`
directamente — sin esperar un tap. El botón "Finish Setup" se deja como
alternativa manual, ya redundante en el camino feliz.

**Logs reales añadidos** (`[SETUP] keys import started/completed`, `keys
valid`, `firmware import started/completed`, `firmware valid`,
`reevaluating onboarding state`, `current onboarding step`, `requirements
satisfied`, `advancing to JIT`, `advance blocked reason`) — exactamente los
pedidos.

**Qué sigue sin poder verificarse aquí**: que el `.onChange`/`.onAppear` de
SwiftUI realmente disparen en producción solo se prueba por inspección de
código y porque CI confirma que compila — una vista SwiftUI en ejecución
real (reabrir pantalla, reabrir app) requiere un dispositivo o UI tests
(`MeloNXUITests`, fuera de alcance aquí). Lo que SÍ es 100% verificable sin
dispositivo es que `OnboardingGate` decide correctamente para cualquier
combinación de `keysValid`/`firmwareValid` — eso es lo que cubren los tests.

## Bug 2 — `Waiting for JIT` nunca resuelve con Built-in StikJIT

**Causa raíz #1 (estructural, confirmada por lectura de código):**
`MeloNXBuiltInJIT.enableCurrentProcess()` llamaba `.enable` directamente y
retornaba sin esperar nada — `Void`, no `async`. El resultado real de la
extensión (`MeloNXJITHelper.appex`) nunca llegaba a ningún sitio salvo un
`print` de depuración. `LaunchGameHandler.enableJIT()` no tenía forma de
saber si el intento interno había funcionado.

**Causa raíz #2 (más grave, también confirmada por lectura de código):**
`enableCurrentProcess()` **nunca llamaba a `.prepare`** — la operación que
obtiene/cachea el Developer Disk Image que `StikJIT.enableJIT()` necesita
para adjuntar un debugger. StikDebug (la app externa) hace ese "prepare" en
su propio onboarding, por eso funciona para quien la tiene instalada; el
camino Built-in, en esta instalación limpia sin StikDebug nunca instalado,
iba directo a `.enable` sin DDI cacheado — casi garantizado a fallar
silenciosamente dentro de la extensión.

**Causa raíz #3 (por qué "se queda indefinidamente", no solo "falla"):**
`JITPopover.onAppear` llamaba `JITCoordinator.shared.waitForJIT(...)` **sin
`maxAttempts`** → usa el default `0` = sondeo sin límite. `JITCoordinator`
nunca podía alcanzar `.timedOut` por diseño, y aunque lo alcanzara, el
`completion` de `JITPopover` solo reaccionaba a `success == true` — el caso
de fallo no tenía ninguna UI. Resultado: aunque todo lo demás fallara
rápido, la pantalla se quedaría exactamente como la describió el usuario,
indefinidamente, sin ningún mensaje.

**Archivos y funciones responsables:** `MeloNXBuiltInJIT.enableCurrentProcess()`
(causas #1 y #2), `JITPopover.swift` `.onAppear` (causa #3).

**Qué hace realmente `enableCurrentProcess()` (antes de este fix):**
únicamente: (a) lee el pairing file importado, (b) arma una request JSON,
(c) inicia una `NSExtension` request hacia `MeloNXJITHelper.appex` vía una
API privada, y (d) retorna inmediatamente. No esperaba respuesta, no
verificaba nada, no podía saber si JIT realmente se concedió.

**Corrección aplicada:**
- `enableCurrentProcess()` ahora es `async -> Bool`: llama `.prepare`
  primero y solo continúa a `.enable` si `.prepare` reporta éxito real;
  devuelve el resultado real de `.enable`, con un `[JIT] failed reason =
  ...` específico en cada punto de fallo posible.
- `LaunchGameHandler.enableJIT()` ahora `await`s ese resultado y hace una
  verificación inmediata adicional con `isJITEnabled()` (`[JIT] verification
  started/result`) — información honesta, sin tocar `.acquired` (que sigue
  siendo exclusivo de `JITCoordinator`, basado en su propio sondeo real).
- `JITPopover` ahora limita el sondeo a 60 intentos × 0.5s (30s) y muestra
  una alerta real con Retry/Cancel cuando `success == false` — ya no hay
  ningún camino que termine en spinner infinito sin información.

**¿El JIT integrado realmente funciona sin StikDebug instalado?** Con lo
verificable desde código: **ahora puede intentarlo de forma honesta
(prepare → enable → verificación real), pero no puedo confirmar que tenga
éxito en el hardware real del usuario**, porque dependen de dos cosas que
solo se pueden comprobar en un dispositivo:
1. Que la API privada de `NSExtension` (el mismo truco de LiveContainer
   para iniciar una extensión registrada con `NSExtensionActivationRule =
   FALSEPREDICATE`) realmente arranque `MeloNXJITHelper.appex` en la
   versión de iOS/firma de este dispositivo.
2. Que `StikJIT.prepareDevice`/`enableJIT` (framework externo precompilado,
   `StikJIT.xcframework`) puedan obtener un Developer Disk Image — lo que
   probablemente requiere acceso a internet a los servicios de Apple la
   primera vez, algo completamente ajeno al túnel LocalDevVPN usado por
   `JITStreamerEB`.

Si cualquiera de los dos falla, el usuario ahora verá `[JIT] failed reason
= ...` específico y una alerta real en vez de un spinner infinito — pero
**no se simula éxito en ningún punto**: `.acquired` sigue dependiendo
exclusivamente de que `isJITEnabled()` sea `true` de verdad.

## Corrección: `180a6a684` NO resolvió Bug 1 en dispositivo real

Prueba real en iPhone tras instalar el IPA de `180a6a684`: importar keys y
firmware **no** avanzó la pantalla automáticamente — se quedó en
Welcome/Setup, y solo avanzó después de que el usuario tocara "Welcome"
(doble-tap) y usara Skip manualmente. Es decir, **el fix no funcionó en la
práctica**, a pesar de que `OnboardingGate` pasaba todos sus tests
unitarios. Esto es exactamente la discrepancia que el pedido original
señaló: tests verdes sobre un tipo puro no prueban que la lógica de
`SetupView` real se ejecute de la forma esperada en un dispositivo.

En vez de adivinar una tercera vez, se agrega instrumentación visible EN
la propia pantalla de Setup — sin necesitar Xcode/Mac — para que la
siguiente prueba real determine cuál de estas hipótesis es la correcta:

- A) la importación realmente no termina
- B) el validador (`checkIfKeysImported()`/`fetchFirmwareVersion()`) devuelve `false`
- C) Setup observa otra instancia
- D) el estado se actualiza pero SwiftUI no refresca
- E) la transición sí ocurre pero otra vista la revierte
- F) la validación se ejecuta demasiado pronto
- G) firmware/keys quedan en una ruta distinta de la que revisa Setup

**Lo que se agregó** (`SetupView.swift`, estrictamente temporal/diagnóstico):

- Un panel visible en la propia pantalla de Setup (iPhone e iPad) con:
  KEYS (archivo encontrado + ruta exacta `Documents/system/prod.keys` +
  validación real vía `Ryujinx.shared.checkIfKeysImported()`), FIRMWARE
  (contenido encontrado en `Documents/bis/system/Contents/registered` +
  versión detectada + validación real vía
  `Ryujinx.shared.fetchFirmwareVersion()`), y SETUP (`hasKeys`/`hasFirmware`
  cacheados, `requirementsSatisfied`, step actual, razón de bloqueo).
  Deliberadamente consulta el filesystem/core real en cada render, no solo
  el `@State` cacheado — si alguna vez difieren, eso aísla D/G directamente.
- Log visible en pantalla (no solo `print()`, inútil sin Mac) con las
  cadenas exactas pedidas: `[KEYS] importer completion`,
  `[KEYS] real validation = ...`, `[FIRMWARE] importer completion`,
  `[FIRMWARE] real validation = ...`, `[SETUP] reevaluate called`,
  `[SETUP] keys = ...`, `[SETUP] firmware = ...`,
  `[SETUP] requirementsSatisfied = ...`, `[SETUP] transition oldState -> newState`.
- Botón **Reevaluate Now**, que llama exactamente `refreshAndEvaluate(...)`
  — la misma función que `onAppear` y ambos importadores ya llaman — para
  distinguir un problema de disparo/reactividad (si al presionarlo avanza)
  de un problema de fuente de verdad (si sigue en `false`).
- Botón **Copy Diagnostics**, que copia todo lo anterior (snapshot +
  log completo) al clipboard vía `UIPasteboard`, para reportarlo sin Mac.

**Importante:** esto es deliberadamente temporal — vive en el código hasta
que la próxima prueba real en dispositivo identifique cuál de A–G es la
causa; no se afirma que Bug 1 esté resuelto. Bug 2 (JIT) no se toca en
este commit salvo preservar los logs `[JIT] ...` ya existentes.

## CHANGELOG de este fork (se actualiza por commit)

| Commit | SHA | Qué cambia | Por qué |
|---|---|---|---|
| `chore: establish performance fork baseline` | `b4f2c9b30` | Este documento | Registrar la base exacta antes de tocar nada |
| `fix(jit): modernize external StikDebug activation` | `f873baf4b` | `StikEnableJIT.swift`, `SettingsView.swift`, `Info.plist` | Condición TXM invertida (ver sección JIT arriba) + URL vía `URLComponents` + detección por `canOpenURL` en vez de SpringBoardServices privado |
| `docs: correct the JIT-wait architectural claim...` | `f3f47d767` | `docs/PERFORMANCE_FORK.md` | Corrige el hallazgo erróneo de "JIT sin esperar"; documenta los problemas reales (polling duplicado, fuga de Timer en `JITPopover`, `JitStreamerEB` inactivo) |
| `refactor(jit): add JIT coordinator foundation` | `159ae9bb2` | `JITCoordinator.swift` (nuevo) | Pieza aditiva, sin call sites todavía: un solo loop de sondeo cancelable con tope opcional |
| `refactor(jit): migrate JITPopover and checkJITAndRunGame onto JITCoordinator` | `656e29273` | `JITCoordinator.swift`, `JITPopover.swift`, `ContentView.swift` | Conecta los dos call sites; corrige la fuga de `Timer` de `JITPopover`; añade manejo de llamadores concurrentes (`pendingCompletions`) para no perder ni pisar completions entre los dos flujos |
| `feat(jit): add Built-in StikJIT host-side availability preflight` | `503c26705` | `BuiltInStikJITAvailability.swift` (nuevo) | Checks de disponibilidad verificados contra `INTEGRATION.md` real de StikJIT (ver `#builtin-stikjit`); el target de extensión que haría falta para enlazar `StikJIT.xcframework` queda fuera de este commit, señalado como el siguiente paso de mayor riesgo |
| `feat(jit): add the Built-in StikJIT helper extension target` | `38c730419` | `project.pbxproj`, `MeloNXJITHelper/` (nuevo target+carpeta), `Dependencies/XCFrameworks/StikJIT.xcframework` (vendoreado), `ios-unsigned-ipa.yml` | El target real, verificado contra la arquitectura de Madeira (ver `#builtin-stikjit`); compila, enlaza StikJIT de verdad, se empaqueta en el IPA. No conectado a ningún call site del host todavía. **Primer intento de CI falló** — ver fila siguiente |
| `fix(jit): give MeloNXJITHelper a build dependency on RyujinxAg` | `041f56011` | `project.pbxproj` | Causa real del fallo de CI (log real, no especulado): `OTHER_LDFLAGS`/`LIBRARY_SEARCH_PATHS` para `Ryujinx.Headless.SDL2.dylib` se pasan como override global de `xcodebuild` en `ios-unsigned-ipa.yml`, y ese override alcanza a TODOS los targets del build, no solo a `MeloNX`. `MeloNXJITHelper` no tenía dependencias declaradas, así que Xcode lo agendó antes de que el target `Ryujinx`/`RyujinxAg` (que produce ese .dylib vía su shell script) terminara — `clang: error: no such file or directory`. El propio target `MeloNX` no sufre esto porque ya depende de `RyujinxAg`. Se agrega la misma dependencia a `MeloNXJITHelper` para forzar el orden correcto — `MeloNXJITHelper` no necesita Ryujinx, es puramente para resolver la carrera; queda documentado como una verruga conocida (el .appex terminará enlazando innecesariamente ese dylib) |
| `feat(jit): add the host-side Built-in StikJIT launcher` | `21ebfbb78` | `BuiltInStikJIT/MeloNXBuiltInJIT.swift`, `BuiltInStikJIT/MeloNXJITHelperRequest.swift` (nuevos), `BuiltInStikJITAvailability.swift` | El lanzador real (API privada `NSExtension`, ver `#builtin-stikjit`). Puramente aditivo en la carpeta sincronizada existente del host — sin cambios a `project.pbxproj`. Sin call sites desde `LaunchGameHandler`/`ContentView` |
| `feat(jit): add the pairing-file import flow` | `f40cc3a9c` | `BuiltInStikJIT/PairingFileImporter.swift`, `BuiltInStikJIT/PairingFileImportRow.swift` (nuevos), `SettingsView.swift` (+1 línea), `Info.plist` (+`LSSupportsOpeningDocumentsInPlace`) | Import real vía `.fileImporter`, copia atómica + security-scoped, per `INTEGRATION.md`. Primer uso real de `UniformTypeIdentifiers` en el proyecto (estaba en el navegador pero sin enlazar) |
| `feat(jit): wire Built-in StikJIT into the JIT method picker` | `f721bba88` | `LaunchGameHandler.swift`, `SettingsView.swift`, `BuiltInStikJIT/MeloNXBuiltInJIT.swift` (+`enableCurrentProcess()`) | Tercera rama en la cadena `if/else if` real de `enableJIT()` (no un enum nuevo); tercer `SettingsToggle`, deshabilitado con motivo real vía `BuiltInStikJITAvailability.unavailableReason()`. **Primer intento de CI falló** — ver fila siguiente |
| `fix(jit): fix LocalizedStringKey conversion and MainActor isolation error` | `98c95e203` | `SettingsView.swift`, `LaunchGameHandler.swift` | Dos errores reales de compilación (log real, no especulado): (1) `infoMessage:` de `SettingsToggle` espera `LocalizedStringKey`, no `String` — los demás call sites pasan literales (que convierten implícitamente), pero `builtInStikJITInfoMessage` es una `String` calculada en tiempo de ejecución, así que necesita `LocalizedStringKey(...)` explícito. (2) Llamar a `MeloNXBuiltInJIT.enableCurrentProcess()` (`@MainActor`) desde `enableJIT()` (no aislado) en un contexto síncrono — se resuelve envolviendo la llamada en `Task { @MainActor in ... }`, el mismo patrón que ya usa el resto del código (`Ryujinx.swift`) |
| `feat(jit): activate JitStreamerEB as the internal JIT path, StikDebug as fallback-only` | `89f6c1a3a` | `JitStreamerEB/EnableJIT.swift`, `LaunchGameHandler.swift`, `JITCoordinator.swift` (logs), `MeloNXTests/JITFlowTests.swift` (nuevo) | Causa real (ver sección arriba): el archivo cliente de `jkcoxson/JitStreamer-EB` existía con cero llamadores; StikDebug no era "requisito" por falta de mecanismo interno, sino porque el mecanismo interno nunca se conectó. `JITStreamerEB.attach()` migrado a `async`/`await` y conectado como primer intento, incondicional, en `enableJIT()`; TrollStore/StikDebug/Built-in StikJIT quedan como fallback explícito solo si `attach()` falla. `JITCoordinator` no necesitó cambios de lógica, solo los `print("[JIT] ...")` pedidos. **CI (run 37378791033) compiló en verde** y produjo `MeloNX-unsigned.ipa` (91.1 MB); bundle ID verificado sin cambios (`com.stossy11.personal.PLS-DONT-TAKE.MeloNX`). De los 6 logs pedidos, 3 (`activation requested`/`internal method selected`/`fallback selected`, todos >15 bytes) se confirmaron presentes en el binario por búsqueda directa de bytes; los otros 3 (`waiting`/`acquired`/`timed out`, los tres ≤15 bytes) no aparecieron así — consistente con la small-string optimization de Swift (strings ≤15 UTF-8 bytes se guardan inline, no como constante de texto clásica), no con que el código se haya eliminado: están en el `HEAD` compilado real, verificados por lectura de fuente, pero esa presencia específica solo se confirma en línea viendo el log de consola en un dispositivo real |
| `fix(onboarding+jit): auto-advance setup and make Built-in StikJIT actually verifiable` | `180a6a684` | `OnboardingGate.swift` (nuevo), `SetupView.swift`, `MeloNXBuiltInJIT.swift`, `LaunchGameHandler.swift`, `JITCoordinator.swift`, `JITPopover.swift`, `MeloNXTests/OnboardingGateTests.swift` (nuevo), `MeloNXTests/JITFlowTests.swift` | Bug 1 y Bug 2 reportados tras prueba real en dispositivo (ver secciones arriba). Bug 1: nada reevaluaba `keysImported && firmImported` para avanzar — solo un botón manual o el atajo de Skip; se agrega `OnboardingGate` + `finishSetupIfReady()` que avanza sola tras cada import y en `onAppear`. Bug 2: `enableCurrentProcess()` no esperaba ningún resultado y nunca llamaba `.prepare` (sin DDI cacheado, `.enable` no tiene nada con qué trabajar); además `JITPopover` sondeaba sin límite y sin reacción al fallo, por lo que "stuck forever" estaba garantizado por diseño incluso si todo lo demás fallara rápido. Se corrigen los tres puntos; no se simula `.acquired` en ningún punto. **Reconciliado por rebase** con 5 commits paralelos ya presentes en el remoto (`a48ad6dc5`..`52dcc9b4c`, mismo autor) que atacaban los mismos bugs desde otro ángulo — incluyendo un hallazgo real que esta sesión no había visto: `shouldLaunchGame`/`shouldShowPopover`/`shouldCheckJIT` estaban también condicionados a `hasJITEntitlement`, que un build firmado por AltStore gratis no tiene, lo que podía impedir que `JITPopover` se mostrara. La rama final conserva ambos aportes: su manejo robusto de `startAccessingSecurityScopedResource()`, su auto-activación del toggle `builtInStikJIT` y su alerta con motivo real, más el `async`/`.prepare`-primero de esta sesión y los logs `[SETUP]`/`[JIT]` pedidos. **CI (run 37409105830) compiló en verde** y produjo `MeloNX-unsigned.ipa` (91.2 MB); bundle ID sin cambios (`com.stossy11.personal.PLS-DONT-TAKE.MeloNX`); todas las cadenas `[SETUP] ...`/`[JIT] ...` de más de 15 bytes verificadas presentes en el binario por búsqueda directa |
| `fix(setup): add on-device diagnostics panel, Bug 1 still not fixed` | `f850cddcf` | `SetupView.swift` | **`180a6a684` no resolvió Bug 1 en el iPhone real** del usuario (ver sección arriba) — se queda en Welcome/Setup tras importar keys+firmware, solo avanza con Welcome→Skip manual. En vez de adivinar de nuevo, se agrega un panel de diagnóstico visible en la propia pantalla de Setup (sin Xcode/Mac): snapshot real de filesystem/core para keys y firmware (independiente del `@State` cacheado), estado de `OnboardingGate`, log visible con las cadenas `[KEYS]`/`[FIRMWARE]`/`[SETUP]` pedidas, botón "Reevaluate Now" (llama la misma función que debería dispararse solo) y "Copy Diagnostics" (copia todo al clipboard). No se afirma que Bug 1 esté resuelto; esto existe para que la siguiente prueba real aísle la causa entre: import que no termina, validador que devuelve false, instancia equivocada, SwiftUI que no refresca, otra vista revirtiendo la transición, validación prematura, o ruta equivocada. JIT (Bug 2) no se toca salvo preservar sus logs existentes |
