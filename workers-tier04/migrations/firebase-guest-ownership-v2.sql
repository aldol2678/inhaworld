-- INHA WORLD / P0 guest profile linkage ownership check (DRAFT)
-- Apply on an isolated non-production Neon branch first. Do NOT deploy to production here.
-- New v2 RPC can coexist with v1 so schema can be installed ahead of Worker release.
-- Once all Workers use v2 and are verified, separately review revocation of v1 EXECUTE.
-- The Worker must verify the Firebase ID token and provide a server-issued
-- X-Session-Id as p_proof_session_id before calling this function.
CREATE OR REPLACE FUNCTION public.link_firebase_identity_v2(
    p_firebase_uid text,
    p_provider text,
    p_email text,
    p_email_verified boolean,
    p_guest_user_id uuid,
    p_proof_session_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
    v_owns_guest boolean;
BEGIN
    IF p_guest_user_id IS NOT NULL THEN
        IF p_proof_session_id IS NULL THEN
            RAISE EXCEPTION 'GUEST_SESSION_PROOF_INVALID' USING ERRCODE = '42501';
        END IF;

        -- The session id is a bearer credential. The actor is the linked
        -- profile ID, or the guest session itself when not yet linked.
        -- Require a CURRENT epoch, and lock the proof session row while
        -- performing the identity link in this same SQL transaction.
        SELECT TRUE INTO v_owns_guest
        FROM public.sessions AS s
        CROSS JOIN private.world_auth_epoch AS e
        WHERE e.id = 1
          AND s.id = p_proof_session_id::text
          AND s.created_epoch >= e.epoch
          AND COALESCE(s.actor_user_id::text, s.id) = p_guest_user_id::text
        FOR SHARE OF s, e;

        IF COALESCE(v_owns_guest, FALSE) IS NOT TRUE THEN
            RAISE EXCEPTION 'GUEST_SESSION_PROOF_INVALID' USING ERRCODE = '42501';
        END IF;
    END IF;

    -- v1 performs identity upsert, conflict checks and profile link.
    -- With no guest target, ordinary Firebase login remains supported.
    RETURN public.link_firebase_identity_v1(
        p_firebase_uid, p_provider, p_email, p_email_verified, p_guest_user_id
    );
END;
$fn$;

REVOKE ALL ON FUNCTION public.link_firebase_identity_v2(text,text,text,boolean,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.link_firebase_identity_v2(text,text,text,boolean,uuid,uuid)
    TO inha_world_tier4_writes_app;
