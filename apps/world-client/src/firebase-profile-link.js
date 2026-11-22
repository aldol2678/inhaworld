// Complete the Firebase <-> game profile bridge after the user has created
// a profile on a Firebase device session. Profile creation by itself does
// not attach its actor to the Firebase UID. Never report success before
// reading back the linked identity.
export class FirebaseProfileLinkError extends Error {
  constructor(code) {
    super(code);
    this.name = 'FirebaseProfileLinkError';
    this.code = code;
  }
}

export async function linkNewFirebaseProfile({ profile, firebaseUser, authClient }) {
  if (typeof profile?.userId !== 'string' || !profile.userId) {
    throw new FirebaseProfileLinkError('PROFILE_ID_MISSING');
  }
  if (typeof firebaseUser?.uid !== 'string' ||
      typeof firebaseUser?.getIdToken !== 'function') {
    throw new FirebaseProfileLinkError('FIREBASE_SIGNIN_REQUIRED');
  }
  if (!authClient || typeof authClient.me !== 'function' ||
      typeof authClient.link !== 'function') {
    throw new FirebaseProfileLinkError('FIREBASE_LINK_CLIENT_REQUIRED');
  }
  // Guard against an account switch where localStorage still has another
  // user's device session. Do not attach that user's profile to this UID.
  const before = await authClient.me();
  if (before?.firebaseUid && before.firebaseUid !== firebaseUser.uid) {
    throw new FirebaseProfileLinkError('FIREBASE_ACCOUNT_MISMATCH');
  }
  const result = await authClient.link(await firebaseUser.getIdToken());
  if (result?.userId !== profile.userId) {
    throw new FirebaseProfileLinkError('PROFILE_LINK_MISMATCH');
  }
  const verified = await authClient.me();
  if (verified?.guest !== false ||
      verified.profileUserId !== profile.userId ||
      verified.firebaseUid !== firebaseUser.uid) {
    throw new FirebaseProfileLinkError('PROFILE_LINK_READBACK_FAILED');
  }
  return verified;
}
