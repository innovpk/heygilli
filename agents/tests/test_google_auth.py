"""Google sign-in and channel import — all offline.

Every Google call is mocked: the token endpoint through a fake `httpx.Client`,
so the posted form is asserted rather than just the call count.
`tests/conftest.py` makes any real socket fail.

Sign-in is identity only. HeyGilli asked for `youtube.readonly` until the
subscriptions import was removed; a sensitive scope nobody needs is a consent
screen that frightens a parent for nothing, and a Google verification review
to keep it alive.
"""
from __future__ import annotations

import base64
import json

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import gateway, google_auth
from heygilli_agents.schemas import GoogleLink
from heygilli_agents.store import LocalStore

CODE = "4/server-auth-code"
SUB = "115551234567890"
EMAIL = "parent@example.com"


def id_token(sub: str = SUB, email: str = EMAIL) -> str:
    """A Google id_token is a JWT; only the middle segment is read, and only
    because it came straight back from the token endpoint over TLS."""
    claims = base64.urlsafe_b64encode(json.dumps({"sub": sub, "email": email}).encode()).decode().rstrip("=")
    return f"header.{claims}.signature"


class _Resp:
    def __init__(self, status_code: int = 200, body: dict | None = None) -> None:
        self.status_code = status_code
        self._body = body or {}

    def json(self) -> dict:
        return self._body


@pytest.fixture
def google_http(monkeypatch: pytest.MonkeyPatch) -> dict:
    """Fake `httpx.Client` for google_auth: records posts, replays queued responses."""
    state: dict = {"posts": [], "gets": [], "responses": [], "userinfo": _Resp(404, {})}

    class _Client:
        def __init__(self, *a, **k) -> None: ...
        def __enter__(self): return self
        def __exit__(self, *a): return False

        def post(self, url: str, data: dict | None = None) -> _Resp:
            state["posts"].append({"url": url, "data": dict(data or {})})
            return state["responses"].pop(0) if state["responses"] else _Resp(200, {})

        def get(self, url: str, headers: dict | None = None, params: dict | None = None) -> _Resp:
            state["gets"].append(url)
            return state["userinfo"]

    monkeypatch.setenv("GOOGLE_CLIENT_ID", "web-client-id.apps.googleusercontent.com")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "web-client-secret")
    monkeypatch.setattr(google_auth.httpx, "Client", _Client)
    return state


def queue(state: dict, *responses: _Resp) -> None:
    state["responses"].extend(responses)


def tokens_response(**over) -> _Resp:
    body = {
        "access_token": "ya29.first",
        "expires_in": 3599,
        "refresh_token": "1//refresh-one",
        "id_token": id_token(),
        # What Google returns for an identity-only consent. HeyGilli no longer
        # asks for a YouTube scope, so a token that carried one would be a
        # fixture describing a grant the app never requests.
        "scope": "openid email profile",
    }
    body.update(over)
    return _Resp(200, body)


# --- code exchange ---------------------------------------------------------------------------


def test_exchange_stores_the_refresh_token_and_derives_a_stable_household(
    google_http: dict, store: LocalStore
) -> None:
    queue(google_http, tokens_response())
    hid, link = google_auth.link_household(CODE, store)

    posted = google_http["posts"][0]
    assert posted["url"] == google_auth.TOKEN_URL
    assert posted["data"] == {
        "grant_type": "authorization_code",
        "code": CODE,
        "client_id": "web-client-id.apps.googleusercontent.com",
        "client_secret": "web-client-secret",
    }
    assert "redirect_uri" not in posted["data"]  # a server auth code has no redirect

    saved = store.get_google_link(hid)
    assert saved is not None
    assert saved.refresh_token == "1//refresh-one" and saved.email == EMAIL and saved.google_sub == SUB
    assert saved.access_token == "ya29.first" and saved.is_fresh()
    assert link.email == EMAIL
    assert hid.startswith("hh_") and hid == google_auth.household_id_for(SUB, EMAIL)


def test_second_exchange_without_a_refresh_token_keeps_the_stored_one(
    google_http: dict, store: LocalStore
) -> None:
    """Google returns a refresh token only on the first consent."""
    queue(google_http, tokens_response(), tokens_response(access_token="ya29.second", refresh_token=None))
    hid, _ = google_auth.link_household(CODE, store)
    hid_again, link = google_auth.link_household("4/another-code", store)

    assert hid_again == hid
    saved = store.get_google_link(hid)
    assert saved.refresh_token == "1//refresh-one"  # not wiped
    assert saved.access_token == "ya29.second" and link.email == EMAIL


def test_exchange_falls_back_to_userinfo_when_there_is_no_id_token(
    google_http: dict, store: LocalStore
) -> None:
    google_http["userinfo"] = _Resp(200, {"sub": SUB, "email": EMAIL})
    queue(google_http, tokens_response(id_token=None))
    hid, link = google_auth.link_household(CODE, store)
    assert google_http["gets"] == [google_auth.USERINFO_URL]
    assert link.email == EMAIL and hid == google_auth.household_id_for(SUB, EMAIL)


# --- access token lifecycle -------------------------------------------------------------------


def linked(store: LocalStore, hid: str = "hh_test", **over) -> str:
    link = GoogleLink(email=EMAIL, google_sub=SUB, refresh_token="1//refresh-one", **over)
    store.put_google_link(hid, link)
    return hid


def test_a_fresh_cached_access_token_is_reused_without_any_call(
    google_http: dict, store: LocalStore
) -> None:
    hid = linked(store, access_token="ya29.cached", access_expires_at=google_auth.expires_at(3600))
    assert google_auth.google_access_token(hid, store) == "ya29.cached"
    assert google_http["posts"] == []


def test_an_expired_access_token_triggers_exactly_one_refresh(
    google_http: dict, store: LocalStore
) -> None:
    hid = linked(store, access_token="ya29.stale", access_expires_at=google_auth.expires_at(-10))
    queue(google_http, tokens_response(access_token="ya29.refreshed", refresh_token=None))

    assert google_auth.google_access_token(hid, store) == "ya29.refreshed"
    assert google_auth.google_access_token(hid, store) == "ya29.refreshed"  # now cached
    assert len(google_http["posts"]) == 1
    assert google_http["posts"][0]["data"] == {
        "grant_type": "refresh_token",
        "refresh_token": "1//refresh-one",
        "client_id": "web-client-id.apps.googleusercontent.com",
        "client_secret": "web-client-secret",
    }
    assert store.get_google_link(hid).refresh_token == "1//refresh-one"


def test_invalid_grant_clears_the_link_and_asks_for_a_relink(
    google_http: dict, store: LocalStore
) -> None:
    hid = linked(store, access_token="ya29.stale", access_expires_at=google_auth.expires_at(-10))
    queue(google_http, _Resp(400, {"error": "invalid_grant", "error_description": "Token has been expired or revoked."}))

    with pytest.raises(google_auth.GoogleNeedsRelink) as excinfo:
        google_auth.google_access_token(hid, store)
    assert "sign in with Google again" in str(excinfo.value)
    assert store.get_google_link(hid) is None  # cleared, so /me/youtube reports linked: false


def test_an_unlinked_household_is_not_an_error_class_of_its_own(store: LocalStore) -> None:
    with pytest.raises(google_auth.GoogleNotLinked):
        google_auth.google_access_token("hh_nobody", store)


def test_missing_credentials_give_an_actionable_error(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GOOGLE_CLIENT_ID", raising=False)
    monkeypatch.delenv("GOOGLE_CLIENT_SECRET", raising=False)
    assert google_auth.configured() is False
    with pytest.raises(google_auth.GoogleNotConfigured) as excinfo:
        google_auth.exchange_code(CODE)
    message = str(excinfo.value)
    assert "GOOGLE_CLIENT_ID" in message and "GOOGLE_CLIENT_SECRET" in message and "web" in message


# --- subscriptions.list -----------------------------------------------------------------------


def sub_item(channel_id: str, title: str, thumb: str = "http://img/m.jpg") -> dict:
    """One `subscriptions.list` row, shaped like the real API.

    `snippet.channelId` is the *subscriber's* channel and is identical on every
    row; the channel that was subscribed to is `snippet.resourceId.channelId`.
    """
    return {
        "snippet": {
            "title": title,
            "channelId": "UCsubscriberOwnChannel00000",
            "resourceId": {"kind": "youtube#channel", "channelId": channel_id},
            "thumbnails": {"default": {"url": "http://img/d.jpg"}, "medium": {"url": thumb}},
        }
    }


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Import Parent"}).json()
    return {"Authorization": f"Bearer {body['token']}", "_hid": body["household_id"]}


def hdr(auth: dict) -> dict:
    return {"Authorization": auth["Authorization"]}


def test_auth_google_links_the_household_the_parent_is_already_in(
    client: TestClient, auth: dict, google_http: dict, store: LocalStore
) -> None:
    queue(google_http, tokens_response())
    r = client.post("/auth/google", json={"server_auth_code": CODE}, headers=hdr(auth))
    assert r.status_code == 200
    assert r.json() == {
        "token": auth["Authorization"].split()[1],
        "household_id": auth["_hid"],
        "email": EMAIL,
        "youtube_linked": True,
    }
    assert store.get_google_link(auth["_hid"]).refresh_token == "1//refresh-one"
    assert client.get("/me/youtube", headers=hdr(auth)).json() == {"linked": True, "email": EMAIL}


def test_auth_google_without_credentials_is_a_503_not_a_crash(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv("GOOGLE_CLIENT_ID", raising=False)
    monkeypatch.delenv("GOOGLE_CLIENT_SECRET", raising=False)
    r = client.post("/auth/google", json={"server_auth_code": CODE})
    assert r.status_code == 503
    assert "GOOGLE_CLIENT_ID" in r.json()["detail"]


def test_unlinked_household_reports_linked_false_and_an_empty_list(
    client: TestClient, auth: dict
) -> None:
    assert client.get("/me/youtube", headers=hdr(auth)).json() == {"linked": False, "email": None}
    # There is no subscriptions endpoint any more: HeyGilli does not ask for
    # access to a parent's YouTube account, so there is nothing to report.
    assert client.get("/me/youtube/subscriptions", headers=hdr(auth)).status_code == 404


def test_import_adds_only_new_channels_and_screens_them_in_the_background(
    client: TestClient, auth: dict, store: LocalStore, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The bulk import a Takeout export goes through. It used to prefer titles
    from a cached copy of the parent's subscriptions; that list is no longer
    read, so every channel is resolved the same way whichever door it came in
    through."""
    kid = client.post("/kids", json={"nickname": "Ayaan", "age": 5}, headers=hdr(auth)).json()
    titles = {"UC_sci": "SciShow Kids", "UC_zoo": "Zoo Time"}
    monkeypatch.setattr(
        gateway, "resolve_channel_url",
        lambda cid: {"channel_id": cid, "title": titles[cid], "thumb_url": "http://img/m.jpg"},
    )

    curated: list[str] = []
    monkeypatch.setattr(gateway, "run_curator", lambda kid, store: curated.append(kid.id))

    first = client.post(
        f"/kids/{kid['id']}/channels/import",
        json={"channel_ids": ["UC_sci", "UC_zoo", "UC_sci", " "]},
        headers=hdr(auth),
    ).json()
    assert [c["id"] for c in first["added"]] == ["UC_sci", "UC_zoo"]  # deduped within the batch
    assert first["added"][0] == {"id": "UC_sci", "title": "SciShow Kids", "thumb_url": "http://img/m.jpg",
                                 "approved": True, "last_checked": None}
    assert first["already"] == []
    assert curated == [kid["id"]]  # TestClient runs background tasks inline

    second = client.post(
        f"/kids/{kid['id']}/channels/import",
        json={"channel_ids": ["UC_sci", "UC_zoo"]},
        headers=hdr(auth),
    ).json()
    assert second == {"added": [], "already": ["UC_sci", "UC_zoo"]}
    assert curated == [kid["id"]]  # nothing new: no second Curator run

    # An imported channel is indistinguishable from a pasted one.
    listed = client.get(f"/kids/{kid['id']}/channels", headers=hdr(auth)).json()
    assert sorted(c["id"] for c in listed) == ["UC_sci", "UC_zoo"]
    assert all(c["approved"] for c in listed)
    # Importing a channel approves no video: the home row stays empty until the Curator says so.
    assert client.get(f"/kids/{kid['id']}/home", headers=hdr(auth)).json()["rows"] == []


def test_import_of_an_unknown_channel_still_succeeds(
    client: TestClient, auth: dict, monkeypatch: pytest.MonkeyPatch
) -> None:
    kid = client.post("/kids", json={"nickname": "Zara", "age": 8}, headers=hdr(auth)).json()
    monkeypatch.setattr(gateway, "run_curator", lambda kid, store: None)
    monkeypatch.setattr(
        gateway, "resolve_channel_url",
        lambda url: {"channel_id": "UC_new", "title": "Resolved Later", "thumb_url": "th"},
    )
    body = client.post(
        f"/kids/{kid['id']}/channels/import", json={"channel_ids": ["UC_new"]}, headers=hdr(auth)
    ).json()
    assert body["added"] == [{"id": "UC_new", "title": "Resolved Later", "thumb_url": "th",
                              "approved": True, "last_checked": None}]

    monkeypatch.setattr(gateway, "resolve_channel_url", lambda url: (_ for _ in ()).throw(ValueError("no")))
    body = client.post(
        f"/kids/{kid['id']}/channels/import", json={"channel_ids": ["UC_broken"]}, headers=hdr(auth)
    ).json()
    assert body["added"][0]["title"] == "UC_broken"  # named after itself rather than failing the batch


def test_import_requires_a_real_kid(client: TestClient, auth: dict) -> None:
    r = client.post("/kids/nope/channels/import", json={"channel_ids": ["UC_x"]}, headers=hdr(auth))
    assert r.status_code == 404
    assert client.post("/kids/nope/channels/import", json={"channel_ids": []}).status_code == 401


# --- what the code was minted against ----------------------------------------------------------
#
# PROTOCOL "Google sign-in and subscription import". Google's token endpoint
# requires redirect_uri to match how the code was created, and the two client
# platforms differ. Getting this wrong is not a soft failure: the whole sign-in
# ends at "Google could not exchange the sign-in code".


def test_a_phone_code_is_exchanged_with_no_redirect_at_all(
    google_http: dict, store: LocalStore
) -> None:
    queue(google_http, tokens_response())
    google_auth.link_household(CODE, store)

    # Not "empty string": absent. Google refuses an empty redirect_uri on a
    # native code, so sending the key at all would break every phone sign-in.
    assert "redirect_uri" not in google_http["posts"][0]["data"]


def test_a_browser_code_is_exchanged_against_postmessage(
    google_http: dict, store: LocalStore
) -> None:
    queue(google_http, tokens_response())
    google_auth.link_household(CODE, store, None, google_auth.POPUP_REDIRECT)

    posted = google_http["posts"][0]["data"]
    assert posted["redirect_uri"] == "postmessage"
    assert posted["code"] == CODE
    assert posted["grant_type"] == "authorization_code"


def test_any_other_redirect_is_refused_before_google_is_called(
    google_http: dict, store: LocalStore
) -> None:
    # The client names the redirect, so this endpoint must not be a passthrough
    # that would exchange a code against somewhere an attacker chose.
    with pytest.raises(google_auth.GoogleAuthError, match="Unsupported redirect_uri"):
        google_auth.link_household(CODE, store, None, "https://evil.example/steal")

    assert google_http["posts"] == [], "a refused redirect must not reach Google"


def test_the_endpoint_passes_the_redirect_it_was_given(
    google_http: dict, store: LocalStore, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The seam: a browser's POST body has to arrive at the exchange intact.

    Asserted through the real HTTP endpoint rather than the function, because
    both halves have been green before while the field never crossed between
    them.
    """
    monkeypatch.setattr(gateway, "get_store", lambda: store)
    queue(google_http, tokens_response())

    r = TestClient(gateway.app).post(
        "/auth/google",
        json={"server_auth_code": CODE, "redirect_uri": "postmessage"},
    )

    assert r.status_code == 200, r.text
    assert google_http["posts"][0]["data"]["redirect_uri"] == "postmessage"
