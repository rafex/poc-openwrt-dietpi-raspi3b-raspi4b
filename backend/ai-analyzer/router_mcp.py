import logging
import subprocess
from typing import Iterable


class RouterMCP:
    """Abstracción mínima tipo MCP para gestionar políticas en OpenWrt vía SSH."""

    BEGIN_MARK = "# --- social-policy begin ---"
    END_MARK = "# --- social-policy end ---"

    def __init__(
        self,
        router_ip: str,
        router_user: str,
        ssh_key: str,
        timeout_s: int = 12,
        logger: logging.Logger | None = None,
    ):
        self.router_ip = router_ip
        self.router_user = router_user
        self.ssh_key = ssh_key
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

    def is_social_block_active(self) -> bool:
        rc, _, _ = self._run_ssh(
            "grep -q '^# --- social-policy begin ---$' /etc/dnsmasq.conf 2>/dev/null"
        )
        return rc == 0

    def apply_social_block(self, domains: Iterable[str]) -> tuple[bool, str]:
        domains = sorted({d.strip().lower() for d in domains if d and d.strip()})
        if not domains:
            return False, "no domains"

        block_lines = "\n".join(f"address=/{d}/0.0.0.0" for d in domains)
        script = f"""
set -eu
if grep -q '^{self.BEGIN_MARK}$' /etc/dnsmasq.conf 2>/dev/null; then
  sed -i '/^{self.BEGIN_MARK}$/,/^{self.END_MARK}$/d' /etc/dnsmasq.conf
fi
cat >> /etc/dnsmasq.conf <<'EOF'
{self.BEGIN_MARK}
# bloque automático de redes sociales (AI policy)
{block_lines}
{self.END_MARK}
EOF
/etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1
printf 'OK\n'
"""
        rc, out, err = self._run_ssh("sh -s", stdin_data=script, timeout_s=20)
        if rc == 0:
            return True, out or "OK"
        return False, err or out or "ssh error"

    def remove_social_block(self) -> tuple[bool, str]:
        script = f"""
set -eu
if grep -q '^{self.BEGIN_MARK}$' /etc/dnsmasq.conf 2>/dev/null; then
  sed -i '/^{self.BEGIN_MARK}$/,/^{self.END_MARK}$/d' /etc/dnsmasq.conf
  /etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1
fi
printf 'OK\n'
"""
        rc, out, err = self._run_ssh("sh -s", stdin_data=script, timeout_s=20)
        if rc == 0:
            return True, out or "OK"
        return False, err or out or "ssh error"
