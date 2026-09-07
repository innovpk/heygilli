"""Google sign-in for the parent and the YouTube read-only link.

PROTOCOL.md "Google sign-in and subscription import", SPEC §6.1 / §9.4 / §12.

The Android client shows the consent dialog and hands the gateway a **server
auth code**, never an access token. This module exchanges that code for a
refresh token using the *web* OAuth client credentials, caches the short-lived
access token beside it, and refreshes when it expires. The refresh token never
leaves the server and never goes back to the device.

One consent covers identity and nothing else: no sensitive scope, so no Google
verification review to keep alive. Only the parent's Google account is
involved: a child never
signs in to anything, and the parent's email is the single personal field
stored (SPEC §12).

Nothing in here logs a token, a refresh token, an auth code, or the payload
they travel in.

Environment (both required, both from the **web** OAuth client, not the
Android one):

    GOOGLE_CLIENT_ID
    GOOGLE_CLIENT_SECRET
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
import logging
import os
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import httpx

from .schemas import GoogleLink, now_iso
from .store import Store

log = logging.getLogger(__name__)

TOKEN_URL = "https://oauth2.googleapis.com/token"
USERINFO_URL = "https://www.googleapis.com/oauth2/v3/userinfo"
HTTP_TIMEOUT_S = 20.0

NOT_CONFIGURED = (
    "Google sign-in is not configured on this server. Set GOOGLE_CLIENT_ID and "
    "GOOGLE_CLIENT_SECRET (the *web* OAuth client of the same Google Cloud project as the "
    "Android client) and restart the gateway. POST /auth/dev still works meanwhile."
)


class GoogleAuthError(Exception):
    """Something about the Google link is wrong, and the message says what."""


class GoogleNotConfigured(GoogleAuthError):
    """GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET are missing on the server."""


class GoogleNotLinked(GoogleAuthError):
    """This household has never signed in with Google (a normal state)."""


class GoogleNeedsRelink(GoogleAuthError):
    """The grant was revoked or expired: the parent has to sign in again."""


def credentials() -> tuple[str, str]:
    """The web OAuth client id and secret, read at call time so tests and
    `.env` reloads both work."""
    client_id = os.getenv("GOOGLE_CLIENT_ID", "").strip()
    client_secret = os.getenv("GOOGLE_CLIENT_SECRET", "").strip()
    if not client_id or not client_secret:
        raise GoogleNotConfigured(NOT_CONFIGURED)
    return client_id, client_secret


def configured() -> bool:
    return bool(os.getenv("GOOGLE_CLIENT_ID", "").strip() and os.getenv("GOOGLE_CLIENT_SECRET", "").strip())


@dataclass(frozen=True)
class GoogleTokens:
    """What the token endpoint returned. `refresh_token` is None on every
    exchange after the first one for the same account."""

    access_token: str = ""
    expires_in: int = 3600
    refresh_token: str | None = None
    id_token: str | None = None
    scope: str = ""


def expires_at(expires_in: int) -> str:
    return (datetime.now(UTC) + timedelta(seconds=max(0, int(expires_in)))).isoformat(timespec="seconds")


def _body(r: httpx.Response) -> dict:
    try:
        parsed = r.json()
    except ValueError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _token_request(payload: dict[str, str], what: str) -> GoogleTokens:
    """One POST to Google's token endpoint.

    `payload` carries the auth code or the refresh token plus the client secret,
    so it is never logged, not even on failure.
    """
    try:
        with httpx.Client(timeout=HTTP_TIMEOUT_S) as client:
            r = client.post(TOKEN_URL, data=payload)
    except httpx.HTTPError as e:
        raise GoogleAuthError(f"could not reach Google to {what}: {type(e).__name__}") from e

    body = _body(r)
    if r.status_code >= 400:
        error = str(body.get("error") or f"http_{r.status_code}")
        detail = str(body.get("error_description") or "")
        log.warning("google token endpoint refused to %s: %s", what, error)
        if error == "invalid_grant":
            raise GoogleNeedsRelink(
                f"Google rejected the grant ({error}): it was revoked, already used or expired. "
                "The parent needs to sign in with Google again."
            )
        raise GoogleAuthError(f"Google could not {what}: {error} {detail}".strip())

    return GoogleTokens(
        access_token=str(body.get("access_token") or ""),
        expires_in=int(body.get("expires_in") or 3600),
        refresh_token=body.get("refresh_token") or None,
        id_token=body.get("id_token") or None,
        scope=str(body.get("scope") or ""),
    )


#: The only redirect a client may name. Google requires the token exchange to
#: match what the code was minted against, and there are exactly two cases:
#: a native consent has no redirect at all, and a browser popup uses Google's
#: own reserved word. Anything else is refused rather than forwarded, so this
#: endpoint cannot be talked into exchanging a code against a redirect of an
#: attacker's choosing.
POPUP_REDIRECT = "postmessage"
ALLOWED_REDIRECTS = frozenset({"", POPUP_REDIRECT})


def exchange_code(server_auth_code: str, redirect_uri: str = "") -> GoogleTokens:
    """Server auth code -> tokens. The credentials are always the **web** OAuth
    client's, whichever platform the code came from.

    `redirect_uri` is empty for a code minted by the Android or iOS client,
    which has no redirect and is refused if sent one. A browser's popup code
    must be exchanged against `postmessage`, or Google answers
    `invalid_request Missing parameter: redirect_uri` (PROTOCOL "Google sign-in
    and subscription import").
    """
    if redirect_uri not in ALLOWED_REDIRECTS:
        raise GoogleAuthError(
            f"Unsupported redirect_uri. Send {POPUP_REDIRECT!r} for a browser "
            "sign-in, or nothing at all for a phone."
        )
    client_id, client_secret = credentials()
    payload = {
        "grant_type": "authorization_code",
        "code": server_auth_code,
        "client_id": client_id,
        "client_secret": client_secret,
    }
    if redirect_uri:
        payload["redirect_uri"] = redirect_uri
    return _token_request(payload, "exchange the sign-in code")


def refresh_access_token(refresh_token: str) -> GoogleTokens:
    client_id, client_secret = credentials()
    return _token_request(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": client_id,
            "client_secret": client_secret,
        },
        "refresh the access token",
    )


def _id_token_claims(id_token: str) -> dict:
    """Read the claims out of Google's id_token without verifying the signature.

    That is safe here and only here: the token arrived over TLS as the direct
    response to our own token request, which is the one case OpenID Connect
    allows skipping verification.
    """
    try:
        payload = id_token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError, binascii.Error, UnicodeDecodeError):
        return {}
    return claims if isinstance(claims, dict) else {}


def _userinfo(access_token: str) -> dict:
    try:
        with httpx.Client(timeout=HTTP_TIMEOUT_S) as client:
            r = client.get(USERINFO_URL, headers={"Authorization": f"Bearer {access_token}"})
        return _body(r) if r.status_code == 200 else {}
    except httpx.HTTPError as e:
        log.warning("google userinfo failed: %s", type(e).__name__)
        return {}


def account_identity(tokens: GoogleTokens) -> tuple[str, str]:
    """`(google_sub, email)`. The id_token carries both when the client asked
    for the profile scopes; otherwise ask userinfo. Neither is fatal — the link
    works without an email to show."""
    claims = _id_token_claims(tokens.id_token) if tokens.id_token else {}
    sub, email = str(claims.get("sub") or ""), str(claims.get("email") or "")
    if not sub and tokens.access_token:
        info = _userinfo(tokens.access_token)
        sub, email = str(info.get("sub") or ""), str(info.get("email") or email)
    return sub, email


def household_id_for(sub: str, email: str) -> str:
    """Same Google account -> same household, every time. Matches the `hh_`
    shape `/auth/dev` produces."""
    seed = sub or email.strip().lower()
    if not seed:  # no identity claims at all: a fresh household is the honest answer
        return "hh_" + uuid.uuid4().hex[:10]
    return "hh_" + hashlib.sha1(f"google:{seed}".encode()).hexdigest()[:10]


def link_household(
    server_auth_code: str,
    store: Store,
    household_id: str | None = None,
    redirect_uri: str = "",
) -> tuple[str, GoogleLink]:
    """Exchange the code and persist the link. Returns `(household_id, link)`.

    Pass `household_id` to attach Google to a household the parent is already
    using (they started on `/auth/dev`); otherwise it is derived from the Google
    account so signing in twice lands in the same household.

    Google returns a refresh token only on the *first* consent for an account.
    A later exchange comes back without one, and the stored token is kept rather
    than overwritten with nothing.
    """
    tokens = exchange_code(server_auth_code, redirect_uri)
    sub, email = account_identity(tokens)
    hid = household_id or household_id_for(sub, email)
    stored = store.get_google_link(hid)

    refresh_token = tokens.refresh_token or (stored.refresh_token if stored else "")
    if not refresh_token:
        raise GoogleNeedsRelink(
            "Google returned no refresh token and none is stored for this household. "
            "The client must request offline access again (access_type=offline, prompt=consent)."
        )

    link = GoogleLink(
        email=email or (stored.email if stored else ""),
        google_sub=sub or (stored.google_sub if stored else ""),
        refresh_token=refresh_token,
        access_token=tokens.access_token,
        access_expires_at=expires_at(tokens.expires_in),
        linked_at=now_iso(),
    )
    store.put_google_link(hid, link)
    log.info("google link stored for household %s", hid)  # never the tokens themselves
    return hid, link


def google_access_token(household_id: str, store: Store) -> str:
    """A live access token for this household's YouTube link.

    Returns the cached one while it is still good, otherwise refreshes exactly
    once and caches the new one. A revoked or expired grant clears the link and
    raises `GoogleNeedsRelink` so the caller can say "sign in again" instead of
    turning it into a 500.
    """
    link = store.get_google_link(household_id)
    if link is None or not link.refresh_token:
        raise GoogleNotLinked("this household has not linked a Google account")
    if link.is_fresh():
        return link.access_token

    try:
        tokens = refresh_access_token(link.refresh_token)
    except GoogleNeedsRelink:
        store.clear_google_link(household_id)
        log.info("google grant rejected for household %s; link cleared", household_id)
        raise

    link.access_token = tokens.access_token
    link.access_expires_at = expires_at(tokens.expires_in)
    if tokens.refresh_token:  # Google does not rotate today, but honour it if it ever does
        link.refresh_token = tokens.refresh_token
    store.put_google_link(household_id, link)
    return link.access_token


def unlink(household_id: str, store: Store) -> None:
    """Forget the Google link (parent signs out, or data deletion, SPEC §12)."""
    store.clear_google_link(household_id)
