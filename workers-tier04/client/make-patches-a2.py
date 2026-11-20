#!/usr/bin/env python3
"""Generate the Tier 4 (A-2) patches from the pristine snapshot.

Reads the originals from ~/workspace/inha-world-static-test/src (never
modified), applies the Tier 4 A-2 string replacements on top of the A-1
combined state, and writes unified diffs into this folder:
  main.js.a2.patch         — A-2 alone, against the A-1 combined state
                             (apply after client/main.js.combined-a1.patch)
  main.js.combined.patch   — A-1 + A-2 combined, against pristine src/main.js

The A-1 combined patch is kept as main.js.combined-a1.patch so this generator
stays re-runnable (the combined output must not be used as its own input).

Usage: python3 make-patches-a2.py
Verifies every replacement applied exactly once, then verifies each patch
with `patch --dry-run` on fresh copies in /tmp.
"""
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
SNAP = HOME / "workspace" / "inha-world-static-test" / "src"
HERE = Path(__file__).resolve().parent
VERIFY = Path("/tmp/tier04-writes-verify")
A1_COMBINED = HERE / "main.js.combined-a1.patch"

AUTH_BLOCK = """// AUTH (A-2 writes, Tier 4 guest-open): the write clients below authenticate with the v0.1
// guest session id (X-Session-Id). The id is read lazily from localStorage
// (fishing-reporter-wiring.js readGuestSessionId(): 'inha-v01:sync-session', fallback
// 'inha-v01:server-session'; null when absent — never fabricated). No legacy token header is
// sent anywhere on these paths. setAccount binds the session id; a null id leaves the client
// SIGNED_OUT. Equip/unequip, shop purchase, attendance claim, guestbook, jeongseok pass,
// cooking, furniture save, personal room and room knock all use this transport now.
"""

# (old, new) replacements for src/main.js, applied to the A-1 combined state.
# The readGuestSessionId import is already present (Tier 3 / A-1).
MAIN_A2_REPLACEMENTS = [
    (
        "const roomKnockClient = new RoomKnockClient({\n"
        "  getClient: () => online?.supabase ?? null,\n"
        "  getSelfUserId: () => online?.userId ?? null\n"
        "});",
        AUTH_BLOCK +
        "const roomKnockClient = new RoomKnockClient({\n"
        "  getSessionId: () => readGuestSessionId(),\n"
        "  getSelfUserId: () => readGuestSessionId()\n"
        "});",
    ),
    (
        "const attendance = createAttendanceClient({\n"
        "  getClient: () => online?.supabase ?? null,",
        "const attendance = createAttendanceClient({\n"
        "  getSessionId: () => readGuestSessionId(),",
    ),
    (
        "loadout.onChange((change) => {\n"
        "  if (change.accountId && change.accountId === online?.userId) roomSession?.setEquipment(publicEquipmentFor(change, change.accountId));\n"
        "});",
        "loadout.onChange((change) => {\n"
        "  // A-2 (A-1 follow-up, room side): the loadout account is now the v0.1 guest session id,\n"
        "  // not the host login id, so the room equipment is set when the change belongs to the\n"
        "  // current session. Campus Presence publication is NOT fixed here: world-online.js\n"
        "  // applyEquipment compares the stored account id against session.userId (the login id)\n"
        "  // and guests never publish by design, so it needs the C-group session→user mapping.\n"
        "  // See client/README.md.\n"
        "  if (change.accountId && change.accountId === readGuestSessionId()) roomSession?.setEquipment(publicEquipmentFor(change, change.accountId));\n"
        "});",
    ),
    (
        "const guestbook = new GuestbookClient({\n"
        "  getClient: () => online?.supabase ?? null,\n"
        "  getSelfUserId: () => online?.userId ?? null\n"
        "});\n"
        "const personalRoom = new PersonalRoomClient({\n"
        "  getClient: () => online?.supabase ?? null,\n"
        "  getSelfUserId: () => online?.userId ?? null\n"
        "});",
        "const guestbook = new GuestbookClient({\n"
        "  getSessionId: () => readGuestSessionId(),\n"
        "  getSelfUserId: () => readGuestSessionId()\n"
        "});\n"
        "const personalRoom = new PersonalRoomClient({\n"
        "  getSessionId: () => readGuestSessionId(),\n"
        "  getSelfUserId: () => readGuestSessionId()\n"
        "});",
    ),
    (
        "  getEquipment: () => publicEquipmentFor(loadout, online?.userId ?? null),",
        "  // A-2 (A-1 follow-up, room side): the loadout account is the v0.1 guest session id.\n"
        "  getEquipment: () => publicEquipmentFor(loadout, readGuestSessionId()),",
    ),
    (
        "roomFurniture = createFurnitureClient({\n"
        "  getClient: () => online?.supabase ?? null,\n"
        "  getUserId: () => online?.userId ?? null,",
        "roomFurniture = createFurnitureClient({\n"
        "  getSessionId: () => readGuestSessionId(),\n"
        "  getUserId: () => readGuestSessionId(),",
    ),
    (
        "cookingFeature = createCookingFeature({\n"
        "  getClient: () => online?.supabase ?? null,\n"
        "  getUserId: () => roomFunctionAccountId,",
        "cookingFeature = createCookingFeature({\n"
        "  getSessionId: () => readGuestSessionId(),\n"
        "  getUserId: () => roomFunctionAccountId,",
    ),
    (
        "const jeongseok = createJeongseokFeature({\n"
        "  getClient: () => online?.supabase ?? null, isEnabled: () => jeongseokEntryMode !== JEONGSEOK_ENTRY_MODE.CLOSED, audio: worldAudio,",
        "const jeongseok = createJeongseokFeature({\n"
        "  getSessionId: () => readGuestSessionId(), isEnabled: () => jeongseokEntryMode !== JEONGSEOK_ENTRY_MODE.CLOSED, audio: worldAudio,",
    ),
    (
        "    void jeongseok.setAccount(identity ? online?.userId ?? null : null);",
        "    // A-2 writes (Tier 4 guest-open) bind the v0.1 guest session id, like the A-1 reads.\n"
        "    void jeongseok.setAccount(readGuestSessionId());",
    ),
    (
        "    void attendance.setAccount(identity ? online?.userId ?? null : null);",
        "    void attendance.setAccount(readGuestSessionId());\n"
        "    void guestbook.setAccount(readGuestSessionId());",
    ),
]


def apply_replacements(text, replacements, label):
    for old, new in replacements:
        count = text.count(old)
        if count != 1:
            print(f"FAIL {label}: expected 1 occurrence, found {count}: {old[:80]!r}")
            sys.exit(1)
        text = text.replace(old, new)
    return text


def diff_file(original: Path, patched: Path, label_a: str, label_b: str) -> str:
    result = subprocess.run(
        ["diff", "-u", "--label", label_a, "--label", label_b, str(original), str(patched)],
        capture_output=True, text=True)
    if result.returncode not in (0, 1):
        print(result.stdout, result.stderr)
        sys.exit(1)
    return result.stdout


def write_patch(original: Path, patched_text: str, out: Path, label_a: str, label_b: str):
    patched = VERIFY / f"patched-{out.stem}.tmp"
    patched.write_text(patched_text)
    out.write_text(diff_file(original, patched, label_a, label_b))
    print(f"wrote {out} ({out.stat().st_size} bytes)")


def patch_dry_run(patch: Path, target_dir: Path, strip: str = "-p1"):
    result = subprocess.run(
        ["patch", strip, "--dry-run", "-d", str(target_dir), "-i", str(patch)],
        capture_output=True, text=True)
    print(f"dry-run {patch.name}: rc={result.returncode}")
    if result.returncode != 0:
        print(result.stdout, result.stderr)
        sys.exit(1)


def main():
    VERIFY.mkdir(exist_ok=True)
    pristine_main = (SNAP / "main.js").read_text()

    # --- A-1 combined state: pristine + A-1 combined patch ---
    a1_dir = VERIFY / "a1-base"
    a1_dir.mkdir(exist_ok=True)
    (a1_dir / "src").mkdir(exist_ok=True)
    (a1_dir / "src" / "main.js").write_text(pristine_main)
    result = subprocess.run(
        ["patch", "-p1", "-d", str(a1_dir), "-i", str(A1_COMBINED)],
        capture_output=True, text=True)
    if result.returncode != 0:
        print("FAIL: A-1 combined patch did not apply to pristine main.js")
        print(result.stdout, result.stderr)
        sys.exit(1)
    print("A-1 combined patch applied cleanly to pristine main.js")
    a1_text = (a1_dir / "src" / "main.js").read_text()
    a1_file = a1_dir / "src" / "main.js"

    # --- main.js.a2.patch: A-2 alone, against the A-1 combined state ---
    a2_text = apply_replacements(a1_text, MAIN_A2_REPLACEMENTS, "main.js (A-2)")
    write_patch(a1_file, a2_text, HERE / "main.js.a2.patch",
                "a/src/main.js", "b/src/main.js")

    # --- main.js.combined.patch: A-1 + A-2 combined, against pristine ---
    write_patch(SNAP / "main.js", a2_text, HERE / "main.js.combined.patch",
                "a/src/main.js", "b/src/main.js")

    # --- verify: dry-run the A-2 patch on the A-1 state, the combined on pristine ---
    fresh_a2 = VERIFY / "dryrun-a2"
    fresh_a2.mkdir(exist_ok=True)
    (fresh_a2 / "src").mkdir(exist_ok=True)
    (fresh_a2 / "src" / "main.js").write_text(a1_text)
    patch_dry_run(HERE / "main.js.a2.patch", fresh_a2)

    fresh_combined = VERIFY / "dryrun-combined"
    fresh_combined.mkdir(exist_ok=True)
    (fresh_combined / "src").mkdir(exist_ok=True)
    (fresh_combined / "src" / "main.js").write_text(pristine_main)
    patch_dry_run(HERE / "main.js.combined.patch", fresh_combined)

    print("all A-2 patches generated and dry-run verified")


if __name__ == "__main__":
    main()
