"""Small async-test runner for the computer test suite.

The project has one lightweight ``@pytest.mark.asyncio`` test, but installing a
third-party async plugin should not be required just to run the server tests.
If pytest-asyncio is installed, it remains authoritative and this hook does
nothing.
"""

from __future__ import annotations

import asyncio
import inspect


def pytest_configure(config) -> None:
    config.addinivalue_line(
        "markers",
        "asyncio: run this coroutine test with the standard-library event loop",
    )


def pytest_pyfunc_call(pyfuncitem):
    plugin_manager = pyfuncitem.config.pluginmanager
    if plugin_manager.hasplugin("asyncio") or plugin_manager.hasplugin("pytest_asyncio"):
        return None

    test_function = pyfuncitem.obj
    if not inspect.iscoroutinefunction(test_function):
        return None

    fixture_names = pyfuncitem._fixtureinfo.argnames
    kwargs = {name: pyfuncitem.funcargs[name] for name in fixture_names}
    asyncio.run(test_function(**kwargs))
    return True
