"""Compatibility import for the provider runtime extracted into BIM Bridge."""

from aec_runtime.providers import (  # noqa: F401
    BLOCKED_TOOLS,
    MANAGER,
    READ_PREFIXES,
    READ_TOOL_NAMES,
    ChildMcpProcess,
    ProviderError,
    ProviderManager,
    classify_access,
    provider_config_path,
)

__all__ = [
    "BLOCKED_TOOLS",
    "MANAGER",
    "READ_PREFIXES",
    "READ_TOOL_NAMES",
    "ChildMcpProcess",
    "ProviderError",
    "ProviderManager",
    "classify_access",
    "provider_config_path",
]
