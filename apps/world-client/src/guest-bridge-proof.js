// Select a session credential for the requested guest profile without
// treating a profile UUID itself as proof of ownership.
export function guestBridgeProof(storage, targetProfileId) {
  if (typeof targetProfileId !== 'string' || !targetProfileId) return null;
  const guest = storage.getItem('inhaworld-guest-session-v1');
  const account = storage.getItem('inhaworld-firebase-session-v1');
  // The browser never grants ownership. The server and the database verify
  // the candidate bearer; this only avoids sending an unproven id.
  return guest || account || null;
}
