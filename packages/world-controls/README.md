# ALDOL World Controls · P0 (candidate)

Engine-independent 3D navigation mathematics derived from the INHA WORLD input conventions.

**Status:** Shared control contract and unit tests only. **Not wired into INHA WORLD runtime**: this repository currently holds Cloudflare Workers and Neon migration components, while the playable world controllers are not present under the same paths. No production deployment.

## Coordinates

- Gameplay right = +X; up = +Y; forward = +Z.
- Camera yaw is in radians. At yaw 0, W moves toward gameplay +Z; D toward +X.
- The camera-relative direction formula is `x=right*cos(yaw)-forward*sin(yaw)`, `z=right*sin(yaw)+forward*cos(yaw)`.
- Browser touch Y increases downward; joystick forward equals `-touchY`.
- Horizontal drag right decreases camera yaw; vertical invert Y is explicit.
- INHA WORLD's previous PlayCanvas rendering used `renderZ = -gameplayZ`. Reflect only at the renderer boundary, not again in movement calculations. A Three.js / PlayCanvas integration must explicitly verify conventions instead of guessing.
- Input ownership, collision, camera obstacle avoidance, engine updates, and mounts are **outside this pure-math package**.

## Files

- `control-math.mjs`: pure functions with no engine dependency.
- `test/control-math.test.mjs`: cardinal angles, joystick/keyboard parity, pitch limits.
- `package.json`: private package, no external packages or hosted infrastructure.

## Verify

Run `node --test packages/world-controls/test/control-math.test.mjs` at repository root.

Before considering this a stable shared standard, locate the actual deployed/gameplay source of INHA WORLD, port a dedicated adapter, run its full existing regression suite and mobile/desktop browser input QA, and smoke-test a second open-world game. Do not merge or deploy as a tested runtime migration until those checks exist.

Source basis: previous INHA WORLD `aldol2678/inhagame` code (PlayerController, OrbitCameraController and POND_VISIBILITY_QA), used only as historical implementation evidence, not a current canonical repository.
