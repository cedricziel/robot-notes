"""Parity check: ``robot_notes._memory_provider_base._LocalMemoryProvider`` (the local
stub used when hermes-agent is not on the path) vs. the real
``agent.memory_provider.MemoryProvider`` ABC from an actual hermes-agent checkout.

Skipped unless ``agent.memory_provider`` is importable. To run it:

    git clone --depth 1 https://github.com/NousResearch/hermes-agent /tmp/hermes-agent
    cd hermes-plugin
    PYTHONPATH=/tmp/hermes-agent .venv/bin/python -m pytest tests/test_stub_parity.py -v

Import cost, checked against a real clone: ``agent.memory_provider`` on its own pulls in
nothing beyond the standard library (``contextvars``, ``logging``, ``re``, ``threading``,
``abc``, ``dataclasses``, ``typing``) -- it has no import-time dependency on the rest of
hermes-agent's package graph, so a bare ``PYTHONPATH`` pointing at the checkout root is
enough; no ``pip install`` of hermes-agent's own dependencies is required to run *this*
test. This does NOT extend to the other two upstream modules ``_hermes_compat``
optionally borrows from: ``tools.registry`` imports ``hermes_constants`` (another
stdlib-only top-level module from the same checkout, so it imports fine bare), but
``agent.secret_scope`` imports ``utils``, which imports the third-party ``pyyaml`` --
so getting the real (non-fallback) ``get_secret`` requires that dependency installed
too, not just the checkout on ``PYTHONPATH``. ``_hermes_compat`` handles this by trying
each of its three upstream imports independently, so a bare-PYTHONPATH checkout (no
extra pip installs) still gets the real ``MemoryProvider``/``RecallStatus``/etc. and
real ``tool_error``, with a working fallback for only ``get_secret``, rather than one
missing dependency taking the whole module down.

We deliberately import ``_LocalMemoryProvider`` (always defined, regardless of whether
upstream is importable) rather than the module's public ``MemoryProvider`` name -- the
latter picks upstream first, so with ``agent.memory_provider`` on the path (our skip
condition) it just *is* the upstream class and comparing it to itself would prove nothing.
"""

from __future__ import annotations

import inspect
from typing import Any, Dict

import pytest

pytest.importorskip("agent.memory_provider")

from agent.memory_provider import MemoryProvider as UpstreamMemoryProvider  # noqa: E402

from robot_notes._memory_provider_base import _LocalMemoryProvider as StubMemoryProvider  # noqa: E402

_MISSING = object()


def _public_callables(cls: type) -> Dict[str, Any]:
    """Public (non-underscore) methods/properties on *cls*, properties unwrapped to
    their getter function so ``inspect.signature`` sees a plain function either way."""
    members: Dict[str, Any] = {}
    for name in dir(cls):
        if name.startswith("_"):
            continue
        raw = inspect.getattr_static(cls, name)
        if isinstance(raw, property):
            members[name] = raw.fget
        elif inspect.isfunction(raw):
            members[name] = raw
    return members


def _signature_shape(fn: Any) -> list:
    """A signature's (name, kind, has_default, default) per parameter, plus its return
    annotation with whitespace normalized. Skips comparing raw annotation text for
    non-return parameters: with ``from __future__ import annotations`` active in both
    modules, annotations are unevaluated strings, and this cares about the real
    contract -- names, order, kinds, defaults -- rather than incidental formatting."""
    sig = inspect.signature(fn)
    shape = [
        (
            name,
            str(param.kind),
            param.default is not inspect.Parameter.empty,
            param.default if param.default is not inspect.Parameter.empty else _MISSING,
        )
        for name, param in sig.parameters.items()
    ]
    return_annotation = sig.return_annotation
    if isinstance(return_annotation, str):
        return_annotation = "".join(return_annotation.split())
    shape.append(("return", return_annotation))
    return shape


def test_public_method_names_match_upstream():
    upstream_names = set(_public_callables(UpstreamMemoryProvider))
    stub_names = set(_public_callables(StubMemoryProvider))
    assert stub_names == upstream_names


def test_signatures_match_upstream():
    upstream = _public_callables(UpstreamMemoryProvider)
    stub = _public_callables(StubMemoryProvider)
    common = set(upstream) & set(stub)
    mismatches = {
        name: {"upstream": _signature_shape(upstream[name]), "stub": _signature_shape(stub[name])}
        for name in sorted(common)
        if _signature_shape(upstream[name]) != _signature_shape(stub[name])
    }
    assert not mismatches, mismatches


def test_pre_compress_checkpoint_api_version_default_matches_upstream():
    assert (
        StubMemoryProvider.pre_compress_checkpoint_api_version
        == UpstreamMemoryProvider.pre_compress_checkpoint_api_version
    )
