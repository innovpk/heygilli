"""Text-to-speech: Amazon Polly for English, cached as mp3 under .data/tts/.

Polly has no Urdu voice, so "ur" returns an empty url and the client falls back
to on-device TTS (PROTOCOL.md "TTS"). Set HEYGILLI_TTS=off to skip Polly
entirely (tests, offline dev); every url is then "" and the client speaks.
"""
from __future__ import annotations

import hashlib
import logging
import os
import re
from pathlib import Path
from xml.sax.saxutils import escape

from strands import tool

from ..store import DATA_DIR

log = logging.getLogger(__name__)

TTS_DIR = DATA_DIR / "tts"
VOICE_EN = os.getenv("HEYGILLI_POLLY_VOICE", "Ivy")  # child-friendly neural voice in us-east-1
REGION = os.getenv("HEYGILLI_POLLY_REGION", "us-east-1")

_polly = None


def _client():
    global _polly
    if _polly is None:
        import boto3

        _polly = boto3.client("polly", region_name=REGION)
    return _polly


def _ssml(text: str, slow: bool) -> str:
    # Stretched words like "looong" are already in the text; slow the whole line for 4_6.
    body = escape(text)
    body = re.sub(r"\b(\w)-(\w+)\b", r'<break time="150ms"/>\1-\2', body)  # "Gi-raffe" pause
    rate = ' rate="85%"' if slow else ""
    return f"<speak><prosody{rate}>{body}</prosody></speak>"


def synthesize(text: str, language: str = "en", slow: bool = False) -> str:
    """Return a relative url `/tts/<sha1>.mp3`, or "" when the client should speak itself."""
    text = text.strip()
    if not text or language != "en" or os.getenv("HEYGILLI_TTS", "polly").lower() == "off":
        return ""
    key = hashlib.sha1(f"{VOICE_EN}|{slow}|{text}".encode()).hexdigest()
    path = TTS_DIR / f"{key}.mp3"
    if path.exists():
        return f"/tts/{key}.mp3"
    from botocore.exceptions import BotoCoreError, ClientError

    try:
        out = _client().synthesize_speech(
            Text=_ssml(text, slow),
            TextType="ssml",
            VoiceId=VOICE_EN,
            Engine="neural",
            OutputFormat="mp3",
        )
        TTS_DIR.mkdir(parents=True, exist_ok=True)
        Path(path).write_bytes(out["AudioStream"].read())
        return f"/tts/{key}.mp3"
    except (BotoCoreError, ClientError, OSError) as e:  # creds, throttling, disk: never block
        log.warning("polly failed, client falls back to on-device TTS: %s", e)
        return ""


@tool
def tts(text: str, language: str = "en", slow: bool = False) -> dict:
    """Turn a buddy line into speech and return the url the client should play.

    Args:
        text: what the buddy says (one or two short sentences)
        language: "en" or "ur" (Urdu returns an empty url; the client speaks on device)
        slow: True for the 4 to 6 band

    Returns:
        {"tts_url": str}
    """
    return {"tts_url": synthesize(text, language, slow)}
