from types import SimpleNamespace
from pathlib import Path
import plistlib

import ifaddr
import zeroconf

from discovery import ServerAdvertisement, advertised_addresses, SERVICE_TYPE


def interfaces(monkeypatch):
    monkeypatch.setattr(ifaddr, "get_adapters", lambda: [SimpleNamespace(ips=[
        SimpleNamespace(ip="127.0.0.1"), SimpleNamespace(ip="10.42.0.1"),
        SimpleNamespace(ip="10.0.0.81"), SimpleNamespace(ip=("::1", 0, 0)),
    ])])


def test_addresses_follow_binding_and_include_hotspot_and_lan(monkeypatch):
    interfaces(monkeypatch)
    assert advertised_addresses("0.0.0.0") == ["10.0.0.81", "10.42.0.1"]
    assert advertised_addresses("10.42.0.1") == ["10.42.0.1"]
    assert advertised_addresses("127.0.0.1") == []
    assert advertised_addresses("10.0.0.99") == []


def test_registration_uses_actual_port_and_withdraws_once(monkeypatch):
    interfaces(monkeypatch)
    events = []

    class FakeZeroconf:
        def __init__(self, **kwargs):
            assert kwargs["interfaces"] == ["10.0.0.81", "10.42.0.1"]

        def register_service(self, info, **kwargs):
            assert info.port == 9123
            assert info.type == SERVICE_TYPE
            assert info.server.endswith(".local.")
            assert info.parsed_addresses() == ["10.0.0.81", "10.42.0.1"]
            assert kwargs["allow_name_change"] is True
            events.append("register")

        def unregister_service(self, info):
            events.append("unregister")

        def close(self):
            events.append("close")

    monkeypatch.setattr(zeroconf, "Zeroconf", FakeZeroconf)
    advertisement = ServerAdvertisement()
    advertisement.start("0.0.0.0", 9123)
    advertisement.close()
    advertisement.close()
    assert events == ["register", "unregister", "close"]


def test_registration_failure_does_not_prevent_server_start(monkeypatch, caplog):
    interfaces(monkeypatch)
    closed = []

    class BrokenZeroconf:
        def __init__(self, **kwargs):
            pass

        def register_service(self, *args, **kwargs):
            raise OSError("multicast unavailable")

        def unregister_service(self, *args):
            raise OSError("socket unavailable")

        def close(self):
            closed.append(True)

    monkeypatch.setattr(zeroconf, "Zeroconf", BrokenZeroconf)
    advertisement = ServerAdvertisement()
    advertisement.start("0.0.0.0", 8000)
    advertisement.close()
    assert closed == [True]
    assert "manual server addresses still work" in caplog.text


def test_ipad_declares_the_advertised_service_type():
    root = Path(__file__).resolve().parents[2]
    with (root / "ipad/Info.plist").open("rb") as file:
        plist = plistlib.load(file)
    assert SERVICE_TYPE.removesuffix(".local.") in plist["NSBonjourServices"]


def test_application_lifecycle_starts_and_closes_advertisement(monkeypatch):
    from fastapi.testclient import TestClient
    import server

    events = []

    class Advertisement:
        def start(self, host, port):
            events.append((host, port))

        def close(self):
            events.append("close")

    monkeypatch.setattr(server, "ServerAdvertisement", Advertisement)
    monkeypatch.setenv("INFINITE_NOTES_DISCOVERY_HOST", "10.0.0.81")
    monkeypatch.setenv("INFINITE_NOTES_DISCOVERY_PORT", "9123")
    with TestClient(server.app) as client:
        assert client.get("/").status_code == 200
        assert events == [("10.0.0.81", 9123)]
    assert events == [("10.0.0.81", 9123), "close"]
