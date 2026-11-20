#!/usr/bin/env python3
"""Generate the Tier 4 (A-1) patches from the pristine snapshot.

Reads the originals from ~/workspace/inha-world-static-test/src (never
modified), applies the Tier 4 string replacements, and writes unified diffs
into this folder:
  main.js.patch            — Tier 4 alone, against pristine src/main.js
  main.js.combined.patch   — fishing + reporter + Tier 3 + Tier 4, against
                             pristine src/main.js (built by applying Tier 3's
                             combined patch first, then the Tier 4 replacements
                             except the import, which is already there)
  world-online.js.patch    — staff-badges wiring (world-online.js only)
  smartphone.js.patch      — student-id wiring + NO_PROFILE line (smartphone.js)

Usage: python3 make-patches.py
Verifies every replacement applied exactly once, then verifies each patch
with `patch --dry-run` on a fresh pristine copy in /tmp.
"""
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
SNAP = HOME / "workspace" / "inha-world-static-test" / "src"
HERE = Path(__file__).resolve().parent
VERIFY = Path("/tmp/tier04-verify")
TIER03_COMBINED = HOME / "workspace" / "inha-world-tier03-client-auth" / "main.js.combined.patch"

AUTH_BLOCK = """// AUTH (migrated 2026-11-13, Tier 4 guest-open): the A-1 read clients below authenticate with
// the v0.1 guest session id (X-Session-Id). The id is read lazily from localStorage
// (fishing-reporter-wiring.js readGuestSessionId(): 'inha-v01:sync-session', fallback
// 'inha-v01:server-session'; null when absent — never fabricated). No legacy token header is
// sent anywhere on these paths. setAccount binds the session id; a null id leaves the client
// SIGNED_OUT. Loadout reads and shop reads are migrated; equip/unequip and purchase stay on
// the legacy path until A-2 (they report SIGNED_OUT with no legacy client supplied).
"""

# (old, new) replacements for src/main.js. The import insertion is first and
# is skipped when building the combined patch (Tier 3 already inserted it).
MAIN_REPLACEMENTS = [
    (
        'import { FISHING_CLIENT_STATE, createFishingClient } from "./activity/fishing-client.js";\n',
        'import { FISHING_CLIENT_STATE, createFishingClient } from "./activity/fishing-client.js";\n'
        'import { readGuestSessionId } from "./activity/fishing-reporter-wiring.js";\n',
    ),
    (
        "// P0-F3a: read-only server progression on the signed-in member client (never a new client).\n"
        "const progression = createProgressionClient({ getClient: () => online?.supabase ?? null });",
        AUTH_BLOCK +
        "// P0-F3a: read-only server progression on the guest session (X-Session-Id; Tier 4, never a new client).\n"
        "const progression = createProgressionClient({ getSessionId: () => readGuestSessionId() });",
    ),
    (
        "// Read-only server wallet balance on the same member client (never a new client, never computed).\n"
        "const wallet = createWalletClient({ getClient: () => online?.supabase ?? null });",
        "// Read-only server wallet balance on the same guest session (never a new client, never computed).\n"
        "const wallet = createWalletClient({ getSessionId: () => readGuestSessionId() });",
    ),
    (
        "// Inventory P0: read-only owned items on the same member client (never a new client, never inferred).\n"
        "const inventory = createInventoryClient({ getClient: () => online?.supabase ?? null });",
        "// Inventory P0: read-only owned items on the same guest session (never a new client, never inferred).\n"
        "const inventory = createInventoryClient({ getSessionId: () => readGuestSessionId() });",
    ),
    (
        "// Wardrobe P0: the server appearance loadout on the same member client (never a new client, never inferred).\n"
        "const loadout = createLoadoutClient({ getClient: () => online?.supabase ?? null });",
        "// Wardrobe P0: the server appearance loadout on the same guest session (never a new client, never inferred).\n"
        "// Reads only — equip/unequip stay on the legacy path until A-2.\n"
        "const loadout = createLoadoutClient({ getSessionId: () => readGuestSessionId() });",
    ),
    (
        "// P0-F3b: Student Center shop on the signed-in member client (never a new client). The server decides\n"
        "// price, Level lock and purchasability; the panel only shows them and forwards purchases.\n"
        "const shop = createShopRouter({\n"
        "  getClient: () => online?.supabase ?? null,\n"
        "  shopIds: SHOP_ROUTE_IDS\n"
        "});",
        "// P0-F3b: Student Center shop on the guest session (never a new client). The server decides\n"
        "// price, Level lock and purchasability; the panel only shows them and forwards purchases.\n"
        "const shop = createShopRouter({\n"
        "  getSessionId: () => readGuestSessionId(),\n"
        "  shopIds: SHOP_ROUTE_IDS\n"
        "});",
    ),
    (
        "const inventoryAcquisition = createInventoryAcquisitionClient({ getClient: () => online?.supabase ?? null });",
        "const inventoryAcquisition = createInventoryAcquisitionClient({ getSessionId: () => readGuestSessionId() });",
    ),
    (
        "    void syncBiryongAccount(identity);\n"
        "    void progression.setAccount(identity ? online?.userId ?? null : null);",
        "    void syncBiryongAccount(identity);\n"
        "    // A-1 reads (Tier 4 guest-open) no longer follow the host login identity: they bind the\n"
        "    // v0.1 guest session id (X-Session-Id). The other setAccount calls here are unchanged.\n"
        "    void progression.setAccount(readGuestSessionId());",
    ),
    (
        "    shop.setAccount(identity ? online?.userId ?? null : null);",
        "    shop.setAccount(readGuestSessionId());",
    ),
    (
        "    void wallet.setAccount(identity ? online?.userId ?? null : null);",
        "    void wallet.setAccount(readGuestSessionId());",
    ),
    (
        "    void inventory.setAccount(identity ? online?.userId ?? null : null);",
        "    void inventory.setAccount(readGuestSessionId());",
    ),
    (
        "    void loadout.setAccount(identity ? online?.userId ?? null : null);",
        "    void loadout.setAccount(readGuestSessionId());",
    ),
]

WORLD_ONLINE_REPLACEMENTS = [
    (
        'import { setStaffBadgeClient } from "../staff-badges.js";\n',
        'import { setStaffBadgeClient } from "../staff-badges.js";\n'
        'import { readGuestSessionId } from "../activity/fishing-reporter-wiring.js";\n',
    ),
    (
        "    setStaffBadgeClient(transportClient);",
        "    // Staff badges (Tier 4 guest-open): the badge lookup authenticates with the v0.1 guest\n"
        "    // session id (X-Session-Id), not the realtime transport client. The realtime transport\n"
        "    // itself is unchanged (C-group scope).\n"
        "    setStaffBadgeClient({ getSessionId: () => readGuestSessionId() });",
    ),
]

SMARTPHONE_REPLACEMENTS = [
    (
        "  const student=createStudentId({getClient,getIdentity,getProgression,",
        "  // Student ID (Tier 4 guest-open): the profile read uses the v0.1 guest session id\n"
        "  // (X-Session-Id) via createStudentId's default supplier. The phone's getClient stays\n"
        "  // for the other phone modules (messages, notifications, album).\n"
        "  const student=createStudentId({getIdentity,getProgression,",
    ),
    (
        "    if(p.state==='LOADING')content.append(el('p','','프로필을 불러오는 중…'));",
        "    if(p.state==='LOADING')content.append(el('p','','프로필을 불러오는 중…'));\n"
        "    if(p.state==='NO_PROFILE')content.append(el('p','','프로필이 아직 없어요.'));",
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


def patch_dry_run(patch: Path, target_dir: Path):
    result = subprocess.run(
        ["patch", "-p1", "--dry-run", "-d", str(target_dir), "-i", str(patch)],
        capture_output=True, text=True)
    print(f"dry-run {patch.name}: rc={result.returncode}")
    if result.returncode != 0:
        print(result.stdout, result.stderr)
        sys.exit(1)


def main():
    VERIFY.mkdir(exist_ok=True)
    pristine_main = (SNAP / "main.js").read_text()

    # --- main.js.patch: Tier 4 alone against pristine main.js ---
    patched_main = apply_replacements(pristine_main, MAIN_REPLACEMENTS, "main.js")
    write_patch(SNAP / "main.js", patched_main, HERE / "main.js.patch",
                "a/src/main.js", "b/src/main.js")

    # --- main.js.combined.patch: Tier 3 combined + Tier 4, against pristine ---
    combined_dir = VERIFY / "combined-base"
    combined_dir.mkdir(exist_ok=True)
    (combined_dir / "src").mkdir(exist_ok=True)
    (combined_dir / "src" / "main.js").write_text(pristine_main)
    result = subprocess.run(
        ["patch", "-p1", "-d", str(combined_dir), "-i", str(TIER03_COMBINED)],
        capture_output=True, text=True)
    if result.returncode != 0:
        print("FAIL: Tier 3 combined patch did not apply to pristine main.js")
        print(result.stdout, result.stderr)
        sys.exit(1)
    print("tier03 combined patch applied cleanly to pristine main.js")
    combined_text = (combined_dir / "src" / "main.js").read_text()
    # Tier 4 replacements except the import insertion (already present).
    combined_patched = apply_replacements(
        combined_text, MAIN_REPLACEMENTS[1:], "main.js (combined)")
    write_patch(SNAP / "main.js", combined_patched, HERE / "main.js.combined.patch",
                "a/src/main.js", "b/src/main.js")

    # --- world-online.js.patch ---
    pristine_online = (SNAP / "online" / "world-online.js").read_text()
    patched_online = apply_replacements(pristine_online, WORLD_ONLINE_REPLACEMENTS, "world-online.js")
    write_patch(SNAP / "online" / "world-online.js", patched_online,
                HERE / "world-online.js.patch",
                "a/src/online/world-online.js", "b/src/online/world-online.js")

    # --- smartphone.js.patch ---
    pristine_phone = (SNAP / "phone" / "smartphone.js").read_text()
    patched_phone = apply_replacements(pristine_phone, SMARTPHONE_REPLACEMENTS, "smartphone.js")
    write_patch(SNAP / "phone" / "smartphone.js", patched_phone,
                HERE / "smartphone.js.patch",
                "a/src/phone/smartphone.js", "b/src/phone/smartphone.js")

    # --- verify: dry-run every patch on fresh pristine copies ---
    for patch, sub in [("main.js.patch", "main.js"),
                       ("main.js.combined.patch", "main.js"),
                       ("world-online.js.patch", "online/world-online.js"),
                       ("smartphone.js.patch", "phone/smartphone.js")]:
        fresh = VERIFY / f"dryrun-{patch}"
        fresh.mkdir(exist_ok=True)
        (fresh / "src").mkdir(exist_ok=True)
        if "/" in sub:
            (fresh / "src" / sub.split("/")[0]).mkdir(exist_ok=True)
        (fresh / "src" / sub).write_text((SNAP / sub).read_text())
        patch_dry_run(HERE / patch, fresh)

    print("all patches generated and dry-run verified")


if __name__ == "__main__":
    main()
