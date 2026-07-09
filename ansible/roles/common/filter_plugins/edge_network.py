"""Custom filters for edge network selection logic."""

from __future__ import annotations

import ipaddress


def armory_ip_in_any_cidr(ip_value, cidrs):
    """Return True when ip_value belongs to any CIDR in cidrs."""
    if not ip_value:
        return False

    try:
        ip_obj = ipaddress.ip_address(str(ip_value))
    except ValueError:
        return False

    for cidr in cidrs or []:
        try:
            if ip_obj in ipaddress.ip_network(str(cidr), strict=False):
                return True
        except ValueError:
            # Ignore malformed CIDRs so resolution can continue safely.
            continue
    return False


class FilterModule(object):
    """Expose custom Jinja2 filters to Ansible."""

    def filters(self):
        return {
            "armory_ip_in_any_cidr": armory_ip_in_any_cidr,
        }
