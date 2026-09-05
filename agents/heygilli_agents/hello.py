"""Day-1 smoke test: one Strands agent, one tool, provider chosen by env var.

    uv run python -m heygilli_agents.hello                       # Bedrock default
    HEYGILLI_MODEL_PLANNER=anthropic:claude-opus-5 uv run python -m heygilli_agents.hello
"""
from __future__ import annotations

from strands import Agent, tool

from .models import model_for


@tool
def icon_lookup(concept: str) -> dict:
    """Look up a kid-safe icon id for a concept (animal, colour, object).

    Args:
        concept: a single English word such as "giraffe" or "red".
    """
    library = {"giraffe": "icon_giraffe", "red": "icon_red_ball", "fish": "icon_fish", "leaf": "icon_leaf"}
    return {"concept": concept, "icon_id": library.get(concept.lower(), "icon_missing")}


def main() -> None:
    agent = Agent(
        model=model_for("planner"),
        system_prompt=(
            "You plan one 'pick it' question for a 4-year-old from a video transcript. "
            "Use icon_lookup for each of the three options. Reply in one short line."
        ),
        tools=[icon_lookup],
    )
    result = agent(
        "Transcript: 'Look at the giraffe eating leaves by the river, and a red ball rolls past.' "
        "Make a pick-it question with three options, one correct."
    )
    print(result)


if __name__ == "__main__":
    main()
