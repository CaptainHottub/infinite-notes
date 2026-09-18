"""Best-effort Bonjour advertisement; never changes interface configuration."""

import ipaddress
import logging
import socket
import uuid

logger = logging.getLogger(__name__)
SERVICE_TYPE = "_infinite-notes._tcp.local."


def advertised_addresses(host):
    import ifaddr

    available = {
        ip.ip for adapter in ifaddr.get_adapters() for ip in adapter.ips
        if isinstance(ip.ip, str)
        and not ipaddress.ip_address(ip.ip).is_loopback
        and not ipaddress.ip_address(ip.ip).is_unspecified
    }
    if host != "0.0.0.0":
        bound = {result[4][0] for result in socket.getaddrinfo(
            host, None, socket.AF_INET, socket.SOCK_STREAM
        )}
        available &= bound
    return sorted(available)


class ServerAdvertisement:
    def __init__(self):
        self.zeroconf = None
        self.info = None

    def start(self, host, port):
        try:
            from zeroconf import IPVersion, ServiceInfo, Zeroconf

            addresses = advertised_addresses(host)
            if not addresses:
                logger.info("Bonjour disabled: no reachable IPv4 interface for %s", host)
                return
            # A service-owned hostname avoids depending on a system Avahi daemon.
            identity = f"infinite-notes-{uuid.getnode():012x}"
            label = ("Infinite Notes — " + socket.gethostname()).encode("utf-8")[:63].decode(
                "utf-8", errors="ignore"
            )
            self.info = ServiceInfo(
                SERVICE_TYPE, f"{label}.{SERVICE_TYPE}",
                parsed_addresses=addresses, port=port,
                properties={"version": "1"}, server=f"{identity}.local.",
            )
            self.zeroconf = Zeroconf(interfaces=addresses, ip_version=IPVersion.V4Only)
            self.zeroconf.register_service(self.info, allow_name_change=True)
            logger.info("Bonjour: %s on port %s", self.info.name, port)
        except Exception:
            logger.warning("Bonjour unavailable; manual server addresses still work", exc_info=True)
            self.close()

    def close(self):
        zeroconf, self.zeroconf = self.zeroconf, None
        if zeroconf is None:
            return
        try:
            if self.info is not None:
                zeroconf.unregister_service(self.info)
        except Exception:
            logger.warning("Could not withdraw Bonjour advertisement", exc_info=True)
        finally:
            try:
                zeroconf.close()
            except Exception:
                logger.warning("Could not close Bonjour sockets", exc_info=True)
