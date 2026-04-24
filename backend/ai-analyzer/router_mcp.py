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
    MCP_PROMPTS = {
        "social_block": (
            "Evalúa dominios de redes sociales detectados y decide si aplicar bloqueo por IP destino. "
            "Responde JSON con action=block|none y reason breve."
        ),
        "porn_enforcement": (
            "Evalúa señales de sitios pornográficos y decide enforcement inmediato. "
            "Responde JSON con action=block_and_kick|none y reason breve."
        ),
        "social_unblock": (
            "Evalúa si terminó la ventana de restricción o bajó el consumo; decide retiro de bloqueo social. "
            "Responde JSON con action=unblock|none y reason breve."
        ),
    }

    def __init__(
        self,
        router_ip: str,
        router_user: str,
        ssh_key: str,
        portal_ip: str = "192.168.1.167",
        bypass_ips: Iterable[str] | None = None,
        timeout_s: int = 12,
        logger: logging.Logger | None = None,
    ):
        self.router_ip = router_ip
        self.router_user = router_user
        self.ssh_key = ssh_key
        self.portal_ip = portal_ip
        self.bypass_ips = self._normalize_ips(
            list(bypass_ips) if bypass_ips is not None else
            ["192.168.1.113", "192.168.1.167", "192.168.1.181", "192.168.1.182", "192.168.1.183"]
        )
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

    def _obfuscated_login(self) -> str:
        ip_parts = (self.router_ip or "").split(".")
        if len(ip_parts) == 4:
            ip_masked = f"{ip_parts[0]}.{ip_parts[1]}.{ip_parts[2]}.xxx"
        else:
            ip_masked = "x.x.x.x"
        return f"{self.router_user}@{ip_masked} (ssh key redacted)"

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
        bypass_expr = ""
        if self.bypass_ips:
            bypass_expr = " ip saddr != { " + ", ".join(self.bypass_ips) + " }"
        script = f"""
set -eu
nft list table {self.NFT_TABLE} >/dev/null 2>&1

nft list set {self.NFT_TABLE} {self.NFT_SOCIAL_SET} >/dev/null 2>&1 || \
  nft add set {self.NFT_TABLE} {self.NFT_SOCIAL_SET} {{ type ipv4_addr; }}

nft list set {self.NFT_TABLE} {self.NFT_PORN_SET} >/dev/null 2>&1 || \
  nft add set {self.NFT_TABLE} {self.NFT_PORN_SET} {{ type ipv4_addr; }}

nft list set {self.NFT_TABLE} {self.NFT_WARN_SET} >/dev/null 2>&1 || \
  nft add set {self.NFT_TABLE} {self.NFT_WARN_SET} {{ type ipv4_addr; flags dynamic,timeout; timeout 20m; }}

nft list chain {self.NFT_TABLE} forward_captive | grep -q 'ip saddr {self.LAN_SUBNET}{bypass_expr} ip daddr @{self.NFT_SOCIAL_SET} drop' || \
  nft insert rule {self.NFT_TABLE} forward_captive ip saddr {self.LAN_SUBNET}{bypass_expr} ip daddr @{self.NFT_SOCIAL_SET} drop

nft list chain {self.NFT_TABLE} forward_captive | grep -q 'ip saddr {self.LAN_SUBNET}{bypass_expr} ip daddr @{self.NFT_PORN_SET} drop' || \
  nft insert rule {self.NFT_TABLE} forward_captive ip saddr {self.LAN_SUBNET}{bypass_expr} ip daddr @{self.NFT_PORN_SET} drop

nft list chain {self.NFT_TABLE} prerouting | grep -q 'ip saddr {self.LAN_SUBNET}{bypass_expr} ip daddr @{self.NFT_SOCIAL_SET} add @warned_clients' || \
  nft insert rule {self.NFT_TABLE} prerouting ip saddr {self.LAN_SUBNET}{bypass_expr} ip daddr @{self.NFT_SOCIAL_SET} add @{self.NFT_WARN_SET} {{ ip saddr timeout 15m }} tcp dport 80 dnat to {self.portal_ip}:80

nft list chain {self.NFT_TABLE} prerouting | grep -q 'ip saddr {self.LAN_SUBNET}{bypass_expr} ip daddr @{self.NFT_PORN_SET} add @warned_clients' || \
  nft insert rule {self.NFT_TABLE} prerouting ip saddr {self.LAN_SUBNET}{bypass_expr} ip daddr @{self.NFT_PORN_SET} add @{self.NFT_WARN_SET} {{ ip saddr timeout 30m }} tcp dport 80 dnat to {self.portal_ip}:80

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

    def mcp_capabilities(self) -> dict:
        return {
            "name": "openwrt-router-mcp",
            "version": "1.0",
            "tool": {
                "name": "apply_router_policy",
                "description": (
                    "Abstrae operaciones de bloqueo/desbloqueo en OpenWrt usando nftables, "
                    "sin exponer credenciales SSH en el frontend."
                ),
                "operations": [
                    "ensure_policy_objects",
                    "apply_social_block",
                    "remove_social_block",
                    "block_porn_ips",
                    "kick_client_from_allowed",
                    "mark_client_warning",
                    "clear_client_warning",
                    "resolve_domains_to_ips",
                ],
                "ssh_target_obfuscated": self._obfuscated_login(),
            },
            "prompts": self.MCP_PROMPTS,
            "resources": [
                "markdown/policy-output-example",
                "json/action-schema-example",
            ],
        }

    def mcp_resources(self) -> dict:
        md = (
            "# Ejemplo esperado (Markdown)\n\n"
            "- policy: `social_block`\n"
            "- trigger: tráfico detectado dentro de la ventana 09:00-17:00\n"
            "- decision: bloquear IPs destino de dominios sociales\n"
            "- output: JSON estricto\n"
        )
        json_example = {
            "action": "block",
            "reason": "Consumo de red social en horario restringido",
            "category": "social",
            "domains": ["facebook.com", "instagram.com"],
            "ips": ["157.240.0.0", "31.13.64.0"],
        }
        md_json = (
            "```json\n"
            "{\n"
            '  "action": "block",\n'
            '  "reason": "Consumo de red social en horario restringido",\n'
            '  "category": "social",\n'
            '  "domains": ["facebook.com", "instagram.com"],\n'
            '  "ips": ["157.240.0.0", "31.13.64.0"]\n'
            "}\n"
            "```"
        )
        return {
            "markdown_policy_output_example": md,
            "json_action_schema_example": json_example,
            "markdown_json_highlight_example": md_json,
        }
