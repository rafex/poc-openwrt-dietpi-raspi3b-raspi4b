import logging
import re
import subprocess
from typing import Iterable


class RouterMCP:
    """Abstracción mínima tipo MCP para gestionar políticas en OpenWrt vía SSH."""

    NFT_TABLE = "ip captive"
    NFT_ALLOWED_SET = "allowed_clients"
    NFT_SOCIAL_SET = "blocked_social_ips"
    NFT_PORN_SET = "blocked_porn_ips"
    NFT_WARN_SET = "warned_clients"
    LAN_SUBNET = "192.168.1.0/24"

    def __init__(
        self,
        router_ip: str,
        router_user: str,
        ssh_key: str,
        portal_ip: str = "192.168.1.167",
        timeout_s: int = 12,
        logger: logging.Logger | None = None,
    ):
        self.router_ip = router_ip
        self.router_user = router_user
        self.ssh_key = ssh_key
        self.portal_ip = portal_ip
        self.timeout_s = timeout_s
        self.log = logger or logging.getLogger("router-mcp")

    def _run_ssh(self, remote_cmd: str, stdin_data: str | None = None, timeout_s: int | None = None):
        cmd = [
            "ssh",
            "-i", self.ssh_key,
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "LogLevel=ERROR",
            f"{self.router_user}@{self.router_ip}",
            remote_cmd,
        ]
        res = subprocess.run(
            cmd,
            input=stdin_data,
            text=True,
            capture_output=True,
            timeout=timeout_s or self.timeout_s,
        )
        return res.returncode, res.stdout.strip(), res.stderr.strip()

    @staticmethod
    def _normalize_ips(ips: Iterable[str]) -> list[str]:
        out = []
        seen = set()
        for ip in ips:
            ip = str(ip or "").strip()
            if not re.match(r"^\d{1,3}(?:\.\d{1,3}){3}$", ip):
                continue
            parts = [int(p) for p in ip.split(".")]
            if any(p > 255 for p in parts):
                continue
            if ip not in seen:
                seen.add(ip)
                out.append(ip)
        return sorted(out)

    def ensure_policy_objects(self) -> tuple[bool, str]:
        """Crea sets/reglas de política si no existen."""
        script = f"""
set -eu
nft list table {self.NFT_TABLE} >/dev/null 2>&1

nft list set {self.NFT_TABLE} {self.NFT_SOCIAL_SET} >/dev/null 2>&1 || \
  nft add set {self.NFT_TABLE} {self.NFT_SOCIAL_SET} {{ type ipv4_addr; }}

nft list set {self.NFT_TABLE} {self.NFT_PORN_SET} >/dev/null 2>&1 || \
  nft add set {self.NFT_TABLE} {self.NFT_PORN_SET} {{ type ipv4_addr; }}

nft list set {self.NFT_TABLE} {self.NFT_WARN_SET} >/dev/null 2>&1 || \
  nft add set {self.NFT_TABLE} {self.NFT_WARN_SET} {{ type ipv4_addr; flags dynamic,timeout; timeout 20m; }}

nft list chain {self.NFT_TABLE} forward_captive | grep -q 'ip saddr {self.LAN_SUBNET} ip daddr @{self.NFT_SOCIAL_SET} drop' || \
  nft insert rule {self.NFT_TABLE} forward_captive ip saddr {self.LAN_SUBNET} ip daddr @{self.NFT_SOCIAL_SET} drop

nft list chain {self.NFT_TABLE} forward_captive | grep -q 'ip saddr {self.LAN_SUBNET} ip daddr @{self.NFT_PORN_SET} drop' || \
  nft insert rule {self.NFT_TABLE} forward_captive ip saddr {self.LAN_SUBNET} ip daddr @{self.NFT_PORN_SET} drop

nft list chain {self.NFT_TABLE} prerouting | grep -q 'ip saddr {self.LAN_SUBNET} ip daddr @{self.NFT_SOCIAL_SET} add @warned_clients' || \
  nft insert rule {self.NFT_TABLE} prerouting ip saddr {self.LAN_SUBNET} ip daddr @{self.NFT_SOCIAL_SET} add @{self.NFT_WARN_SET} {{ ip saddr timeout 15m }} tcp dport 80 dnat to {self.portal_ip}:80

nft list chain {self.NFT_TABLE} prerouting | grep -q 'ip saddr {self.LAN_SUBNET} ip daddr @{self.NFT_PORN_SET} add @warned_clients' || \
  nft insert rule {self.NFT_TABLE} prerouting ip saddr {self.LAN_SUBNET} ip daddr @{self.NFT_PORN_SET} add @{self.NFT_WARN_SET} {{ ip saddr timeout 30m }} tcp dport 80 dnat to {self.portal_ip}:80

printf 'OK\\n'
"""
        rc, out, err = self._run_ssh("sh -s", stdin_data=script, timeout_s=25)
        if rc == 0:
            return True, out or "OK"
        return False, err or out or "ssh error"

    def _replace_set_ips(self, set_name: str, ips: Iterable[str]) -> tuple[bool, str]:
        ok, msg = self.ensure_policy_objects()
        if not ok:
            return False, msg
        ips_norm = self._normalize_ips(ips)
        script = [
            "set -eu",
            f"nft flush set {self.NFT_TABLE} {set_name}",
        ]
        if ips_norm:
            elements = ", ".join(ips_norm)
            script.append(f"nft add element {self.NFT_TABLE} {set_name} {{ {elements} }}")
        script.append("printf 'OK\\n'")
        rc, out, err = self._run_ssh("sh -s", stdin_data="\n".join(script) + "\n", timeout_s=20)
        if rc == 0:
            return True, f"OK ({len(ips_norm)} ips)"
        return False, err or out or "ssh error"

    def _add_set_ips(self, set_name: str, ips: Iterable[str]) -> tuple[bool, str]:
        ok, msg = self.ensure_policy_objects()
        if not ok:
            return False, msg
        ips_norm = self._normalize_ips(ips)
        if not ips_norm:
            return False, "no ips"
        elements = ", ".join(ips_norm)
        rc, out, err = self._run_ssh(
            f"nft add element {self.NFT_TABLE} {set_name} {{ {elements} }}",
            timeout_s=20,
        )
        if rc == 0:
            return True, f"OK ({len(ips_norm)} ips)"
        return False, err or out or "ssh error"

    def _set_count(self, set_name: str) -> int:
        rc, out, _ = self._run_ssh(
            f"nft list set {self.NFT_TABLE} {set_name} 2>/dev/null | grep -oE '([0-9]{{1,3}}\\.){{3}}[0-9]{{1,3}}' | wc -l"
        )
        if rc != 0:
            return 0
        try:
            return int(out.strip() or "0")
        except Exception:
            return 0

    def resolve_domains_to_ips(self, domains: Iterable[str]) -> list[str]:
        """Resuelve dominios en el router (best-effort) y devuelve IPv4 únicas."""
        doms = sorted({str(d or "").strip().lower() for d in domains if str(d or "").strip()})
        if not doms:
            return []
        script = ["set -eu"]
        for d in doms:
            script.append(
                f"nslookup '{d}' 127.0.0.1 2>/dev/null | "
                "awk '/^Address [0-9]+: /{print $3} /^Address: /{print $2}' || true"
            )
        rc, out, _ = self._run_ssh("sh -s", stdin_data="\n".join(script) + "\n", timeout_s=25)
        if rc != 0:
            return []
        ips = self._normalize_ips(out.splitlines())
        return [ip for ip in ips if ip != "0.0.0.0"]

    def is_social_block_active(self) -> bool:
        return self._set_count(self.NFT_SOCIAL_SET) > 0

    def apply_social_block(self, domains: Iterable[str]) -> tuple[bool, str]:
        """Bloquea redes sociales por IP destino (no por usuario)."""
        ips = self.resolve_domains_to_ips(domains)
        if not ips:
            return False, "no_resolved_ips"
        return self._replace_set_ips(self.NFT_SOCIAL_SET, ips)

    def remove_social_block(self) -> tuple[bool, str]:
        return self._replace_set_ips(self.NFT_SOCIAL_SET, [])

    def block_porn_ips(self, ips: Iterable[str]) -> tuple[bool, str]:
        return self._add_set_ips(self.NFT_PORN_SET, ips)

    def kick_client_from_allowed(self, client_ip: str) -> tuple[bool, str]:
        client_ip = str(client_ip or "").strip()
        if not client_ip:
            return False, "missing client_ip"
        ok, msg = self.ensure_policy_objects()
        if not ok:
            return False, msg
        script = f"""
set -eu
nft delete element {self.NFT_TABLE} {self.NFT_ALLOWED_SET} {{ {client_ip} }} >/dev/null 2>&1 || true
conntrack -D -s {client_ip} >/dev/null 2>&1 || true
printf 'OK\\n'
"""
        rc, out, err = self._run_ssh("sh -s", stdin_data=script, timeout_s=15)
        if rc == 0:
            return True, out or "OK"
        return False, err or out or "ssh error"

    def mark_client_warning(self, client_ip: str) -> tuple[bool, str]:
        client_ip = str(client_ip or "").strip()
        if not client_ip:
            return False, "missing client_ip"
        ok, msg = self.ensure_policy_objects()
        if not ok:
            return False, msg
        rc, out, err = self._run_ssh(
            f"nft add element {self.NFT_TABLE} {self.NFT_WARN_SET} {{ {client_ip} }}",
            timeout_s=12,
        )
        if rc == 0:
            return True, out or "OK"
        return False, err or out or "ssh error"

    def clear_client_warning(self, client_ip: str) -> tuple[bool, str]:
        client_ip = str(client_ip or "").strip()
        if not client_ip:
            return False, "missing client_ip"
        rc, out, err = self._run_ssh(
            f"nft delete element {self.NFT_TABLE} {self.NFT_WARN_SET} {{ {client_ip} }} >/dev/null 2>&1 || true; echo OK",
            timeout_s=12,
        )
        if rc == 0:
            return True, out or "OK"
        return False, err or out or "ssh error"

    def is_client_warned(self, client_ip: str) -> bool:
        client_ip = str(client_ip or "").strip()
        if not client_ip:
            return False
        rc, _, _ = self._run_ssh(
            f"nft get element {self.NFT_TABLE} {self.NFT_WARN_SET} {{ {client_ip} }} >/dev/null 2>&1"
        )
        return rc == 0
