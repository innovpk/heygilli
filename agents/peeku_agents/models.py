"""Provider-flexible model selection.

Every agent reads its provider from an env var so the same agent code runs on
Bedrock, Anthropic direct, or another Strands provider without edits.

    PEEKU_MODEL_PLANNER=bedrock:<model-id>
    PEEKU_MODEL_BUDDY=anthropic:claude-opus-5

Format: "<provider>:<model id>". Unknown provider -> ValueError so a typo fails
fast instead of silently falling back.
"""
from __future__ import annotations

import os

ROLES = ("curator", "planner", "buddy", "digest")
DEFAULT = "bedrock:"  # empty id -> Strands' Bedrock default model for the region


def model_for(role: str):
    if role not in ROLES:
        raise ValueError(f"unknown role {role!r}; expected one of {ROLES}")
    spec = os.getenv(f"PEEKU_MODEL_{role.upper()}", DEFAULT)
    provider, _, model_id = spec.partition(":")
    provider = provider.strip().lower()

    if provider == "bedrock":
        from strands.models import BedrockModel

        kwargs = {"model_id": model_id} if model_id else {}
        region = os.getenv("AWS_REGION")
        if region:
            kwargs["region_name"] = region
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
