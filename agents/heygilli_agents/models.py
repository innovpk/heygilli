"""Provider-flexible model selection.

Every agent reads its provider from an env var so the same agent code runs on
Bedrock, Anthropic direct, or another Strands provider without edits.

    HEYGILLI_MODEL_PLANNER=bedrock:<model-id>
    HEYGILLI_MODEL_BUDDY=anthropic:claude-opus-5
    HEYGILLI_MODEL_DEFAULT=bedrock:us.amazon.nova-pro-v1:0   # fallback for any unset role

Format: "<provider>:<model id>". Providers: bedrock | anthropic | openai | ollama | fake.
Unknown provider -> ValueError so a typo fails fast instead of silently falling back.
"""
from __future__ import annotations

import os

ROLES = ("curator", "planner", "buddy", "digest", "reviewer")
# Verified in us-east-1 via `aws bedrock list-inference-profiles`; needs the account's
# Anthropic use-case form approved. Nova Pro is the key-free fallback that works today.
DEFAULT = "bedrock:us.anthropic.claude-sonnet-4-6"
BEDROCK_REGION = "us-east-1"  # cross-region inference profiles live here, not ap-southeast-1


def spec_for(role: str) -> str:
    if role not in ROLES:
        raise ValueError(f"unknown role {role!r}; expected one of {ROLES}")
    return os.getenv(f"HEYGILLI_MODEL_{role.upper()}") or os.getenv("HEYGILLI_MODEL_DEFAULT") or DEFAULT


def model_for(role: str):
    spec = spec_for(role)
    provider, _, model_id = spec.partition(":")
    provider = provider.strip().lower()

    if provider == "fake":
        from .fake_model import FakeModel

        return FakeModel()

    if provider == "bedrock":
        from strands.models import BedrockModel

        kwargs = {"model_id": model_id} if model_id else {}
        kwargs["region_name"] = os.getenv("HEYGILLI_BEDROCK_REGION", BEDROCK_REGION)
        return BedrockModel(**kwargs)

    if provider == "anthropic":
        from strands.models.anthropic import AnthropicModel

        return AnthropicModel(
            client_args={"api_key": os.environ["ANTHROPIC_API_KEY"]},
            model_id=model_id or "claude-opus-5",
            max_tokens=4096,
        )

    if provider == "openai":
        from strands.models.openai import OpenAIModel

        return OpenAIModel(
            client_args={"api_key": os.environ["OPENAI_API_KEY"]},
            model_id=model_id,
        )

    if provider == "ollama":
        from strands.models.ollama import OllamaModel

        return OllamaModel(
            host=os.getenv("OLLAMA_HOST", "http://localhost:11434"),
            model_id=model_id or "llama3.2",
        )

    raise ValueError(f"unknown provider {provider!r} in {spec!r}")
