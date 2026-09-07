"""The liveness probe must not drown the access log, and must not take real traffic with it."""
import logging

from heygilli_agents.gateway import _DropHealthChecks

ACCESS_FMT = '%s - "%s %s HTTP/%s" %d'


def _access_record(path: str, status: int = 200) -> logging.LogRecord:
    """A record shaped the way uvicorn.access emits one: message built from args."""
    return logging.LogRecord(
        name="uvicorn.access",
        level=logging.INFO,
        pathname=__file__,
        lineno=1,
        msg=ACCESS_FMT,
        args=("10.219.25.208:57260", "GET", path, "1.1", status),
        exc_info=None,
    )


def test_the_platform_probe_is_dropped():
    assert _DropHealthChecks().filter(_access_record("/healthz")) is False


def test_real_traffic_still_shows():
    # The whole point of filtering here rather than raising the log level.
    f = _DropHealthChecks()
    assert f.filter(_access_record("/kids")) is True
    assert f.filter(_access_record("/auth/google", status=503)) is True
    assert f.filter(_access_record("/sessions", status=500)) is True


def test_a_route_merely_containing_health_is_kept():
    # /healthz is one exact probe; a future /health-report is real traffic.
    assert _DropHealthChecks().filter(_access_record("/health-report")) is True
