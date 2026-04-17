"""Webserver service integration tests.

Requires webserver_env fixture (defined in conftest.py), which applies
services/webserver/ on top of a running vault + vault-config deployment.
"""
import ssl
import socket
import urllib.request

from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.x509.oid import NameOID, ExtensionOID


def _get_server_cert(host, port, cacert):
    ctx = ssl.create_default_context(cafile=cacert)
    with socket.create_connection((host, port), timeout=10) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as ssock:
            der = ssock.getpeercert(binary_form=True)
    return x509.load_der_x509_certificate(der, default_backend())


# ---------------------------------------------------------------------------
# Connectivity
# ---------------------------------------------------------------------------

def test_nginx_reachable_on_8443(webserver_env):
    ctx = ssl.create_default_context(cafile=webserver_env["cacert"])
    with socket.create_connection(("127.0.0.1", 8443), timeout=10) as sock:
        with ctx.wrap_socket(sock, server_hostname="127.0.0.1") as ssock:
            assert ssock.version() in ("TLSv1.2", "TLSv1.3")


def test_nginx_returns_200(webserver_env):
    ctx = ssl.create_default_context(cafile=webserver_env["cacert"])
    req = urllib.request.urlopen(
        "https://127.0.0.1:8443/",
        context=ctx,
        timeout=10,
    )
    assert req.status == 200


# ---------------------------------------------------------------------------
# Certificate properties
# ---------------------------------------------------------------------------

def test_nginx_cert_issued_by_external_intermediate(webserver_env):
    cert = _get_server_cert("127.0.0.1", 8443, webserver_env["cacert"])
    issuer_cn = cert.issuer.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
    assert issuer_cn == "Armory External Intermediate CA"


def test_nginx_cert_common_name(webserver_env):
    cert = _get_server_cert("127.0.0.1", 8443, webserver_env["cacert"])
    cn = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
    assert cn == "armory-webserver"


def test_nginx_cert_has_aia(webserver_env):
    cert = _get_server_cert("127.0.0.1", 8443, webserver_env["cacert"])
    aia = cert.extensions.get_extension_for_oid(ExtensionOID.AUTHORITY_INFORMATION_ACCESS)
    assert aia is not None


def test_nginx_cert_validates_against_ca_bundle(webserver_env):
    """Full chain validation using the CA bundle from vault-config/."""
    ctx = ssl.create_default_context(cafile=webserver_env["cacert"])
    ctx.verify_mode = ssl.CERT_REQUIRED
    with socket.create_connection(("127.0.0.1", 8443), timeout=10) as sock:
        with ctx.wrap_socket(sock, server_hostname="127.0.0.1") as ssock:
            # If we get here without an exception, chain validation passed
            assert ssock.getpeercert() is not None


# ---------------------------------------------------------------------------
# SANs
# ---------------------------------------------------------------------------

def test_nginx_cert_has_localhost_ip_san(webserver_env):
    """127.0.0.1 must always be present as an IP SAN (hardcoded default)."""
    import ipaddress
    cert = _get_server_cert("127.0.0.1", 8443, webserver_env["cacert"])
    san_ext = cert.extensions.get_extension_for_oid(ExtensionOID.SUBJECT_ALTERNATIVE_NAME)
    ip_sans = san_ext.value.get_values_for_type(x509.IPAddress)
    assert ipaddress.IPv4Address("127.0.0.1") in ip_sans
