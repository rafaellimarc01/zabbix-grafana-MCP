"""MCP único do modelo zabbix-grafana: um só endereço e um só token para a IA.

Junta as ferramentas dos MCPs oficiais do Zabbix e do Grafana, que ficam só na
rede interna, e as entrega com os prefixos "zabbix_" e "grafana_". Fala o
transporte HTTP "streamable" do MCP no modo sem sessão: cada POST em /mcp
recebe uma resposta JSON.

Só usa a biblioteca padrão do Python, para a imagem ficar pequena e fácil de
auditar. Configuração por variáveis de ambiente (veja o README):

  MCP_TOKEN              token que a IA manda (Authorization: Bearer ...)
  MCP_LISTEN             endereço:porta onde escuta (padrão 0.0.0.0:8765)
  MCP_ALLOWED_HOSTS      nomes aceitos no cabeçalho Host/Origin, separados por
                         vírgula (padrão localhost,127.0.0.1,::1)
  ZABBIX_MCP_URL         MCP oficial do Zabbix (vazio = desligado)
  ZABBIX_MCP_TOKEN       token de API do Zabbix do usuário "mcp"
  GRAFANA_MCP_URL        MCP oficial do Grafana (vazio = desligado)
  GRAFANA_MCP_TOKEN      token que o MCP do Grafana exige
"""

from __future__ import annotations

import hmac
import json
import logging
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

VERSION = "0.1.0"
SERVER_NAME = "zabbix-grafana-mcp"
# Versões do protocolo MCP que este servidor entende (a primeira é a preferida).
PROTOCOL_VERSIONS = ("2025-06-18", "2025-11-25", "2025-03-26")
MAX_REQUEST = 1 * 1024 * 1024
MAX_UPSTREAM_RESPONSE = 8 * 1024 * 1024
UPSTREAM_TIMEOUT = 60
TOOLS_CACHE_SECONDS = 60

INSTRUCTIONS = (
    "Monitoramento somente leitura. Ferramentas zabbix_* consultam o Zabbix "
    "(hosts, problemas, triggers, eventos); grafana_* consultam o Grafana "
    "(dashboards, datasources, alertas e consulta de painéis, inclusive os "
    "dados do Zabbix pelo plugin). Nenhuma ferramenta altera configuração."
)

log = logging.getLogger("mcp-gateway")


class UpstreamError(Exception):
    """Falha ao falar com um MCP interno."""


class RpcError(Exception):
    """Erro JSON-RPC devolvido por um MCP interno, repassado como veio."""

    def __init__(self, error: dict):
        super().__init__(error.get("message", "erro"))
        self.error = error


def parse_response(body: bytes, content_type: str, request_id: object) -> dict | None:
    """Acha a resposta JSON-RPC com o id pedido, em JSON puro ou em SSE."""
    text = body.decode("utf-8", "replace")
    if "text/event-stream" in content_type:
        messages, data = [], []
        for line in text.splitlines() + [""]:
            if line.startswith("data:"):
                data.append(line[5:].lstrip())
            elif line == "" and data:
                messages.append("\n".join(data))
                data = []
    else:
        messages = [text] if text.strip() else []
    for raw in messages:
        try:
            msg = json.loads(raw)
        except ValueError:
            continue
        if isinstance(msg, dict) and msg.get("id") == request_id and ("result" in msg or "error" in msg):
            return msg
    return None


class Upstream:
    """Cliente mínimo de um MCP HTTP streamable (sessão, SSE, reconexão)."""

    def __init__(self, name: str, url: str, token: str):
        self.name = name
        self.prefix = name + "_"
        self.url = url
        self.token = token
        self.session_id: str | None = None
        self.protocol_version = PROTOCOL_VERSIONS[0]
        self._lock = threading.Lock()
        self._next_id = 0

    def _post(self, payload: dict) -> tuple[int, dict, bytes]:
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Authorization": "Bearer " + self.token,
            "MCP-Protocol-Version": self.protocol_version,
        }
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        req = urllib.request.Request(self.url, data=json.dumps(payload).encode(), headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT) as resp:  # noqa: S310 (URL da configuração)
                body = resp.read(MAX_UPSTREAM_RESPONSE + 1)
                status, resp_headers = resp.status, dict(resp.headers)
        except urllib.error.HTTPError as err:
            return err.code, dict(err.headers or {}), err.read(4096)
        except (urllib.error.URLError, OSError) as err:
            raise UpstreamError(f"{self.name}: sem conexão ({err})") from None
        if len(body) > MAX_UPSTREAM_RESPONSE:
            raise UpstreamError(f"{self.name}: resposta maior que {MAX_UPSTREAM_RESPONSE // 1024 // 1024} MB")
        return status, resp_headers, body

    def _request(self, method: str, params: dict | None) -> dict:
        with self._lock:
            self._next_id += 1
            request_id = self._next_id
        payload = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            payload["params"] = params
        status, headers, body = self._post(payload)
        if status in (401, 403):
            raise UpstreamError(f"{self.name}: token recusado (HTTP {status})")
        if status == 404 and self.session_id:
            raise _SessionExpired()
        if status != 200:
            raise UpstreamError(f"{self.name}: HTTP {status}")
        ctype = {k.lower(): v for k, v in headers.items()}.get("content-type", "")
        msg = parse_response(body, ctype, request_id)
        if msg is None:
            raise UpstreamError(f"{self.name}: resposta sem o id {request_id}")
        if "error" in msg:
            raise RpcError(msg["error"])
        return msg["result"]

    def _initialize(self) -> None:
        self.session_id = None
        payload = {
            "jsonrpc": "2.0",
            "id": 0,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSIONS[0],
                "capabilities": {},
                "clientInfo": {"name": SERVER_NAME, "version": VERSION},
            },
        }
        status, headers, body = self._post(payload)
        if status in (401, 403):
            raise UpstreamError(f"{self.name}: token recusado (HTTP {status})")
        if status != 200:
            raise UpstreamError(f"{self.name}: initialize devolveu HTTP {status}")
        lower = {k.lower(): v for k, v in headers.items()}
        msg = parse_response(body, lower.get("content-type", ""), 0)
        if msg is None or "result" not in msg:
            raise UpstreamError(f"{self.name}: initialize sem resposta válida")
        self.session_id = lower.get("mcp-session-id")
        self.protocol_version = msg["result"].get("protocolVersion", PROTOCOL_VERSIONS[0])
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def call(self, method: str, params: dict | None = None) -> dict:
        for attempt in (1, 2):
            if self.session_id is None or attempt == 2:
                self._initialize()
            try:
                return self._request(method, params)
            except _SessionExpired:
                continue
        raise UpstreamError(f"{self.name}: a sessão expirou de novo")

    def list_tools(self) -> list[dict]:
        tools, cursor = [], None
        for _ in range(20):
            result = self.call("tools/list", {"cursor": cursor} if cursor else None)
            tools.extend(result.get("tools", []))
            cursor = result.get("nextCursor")
            if not cursor:
                break
        return tools


class _SessionExpired(Exception):
    pass


class Gateway:
    """Une as ferramentas dos MCPs internos com prefixo por origem."""

    def __init__(self, upstreams: list[Upstream]):
        self.upstreams = upstreams
        self._tools: list[dict] = []
        self._routes: dict[str, tuple[Upstream, str]] = {}
        self._loaded_at = 0.0
        self._lock = threading.Lock()

    def tools(self, refresh: bool = False) -> list[dict]:
        with self._lock:
            if refresh or time.monotonic() - self._loaded_at > TOOLS_CACHE_SECONDS:
                tools, routes = [], {}
                for up in self.upstreams:
                    try:
                        listed = up.list_tools()
                    except (UpstreamError, RpcError) as err:
                        log.warning("ferramentas de %s indisponíveis: %s", up.name, err)
                        continue
                    for tool in listed:
                        name = up.prefix + tool["name"]
                        exposed = dict(tool, name=name)
                        annotations = dict(tool.get("annotations") or {})
                        annotations.setdefault("readOnlyHint", True)
                        exposed["annotations"] = annotations
                        tools.append(exposed)
                        routes[name] = (up, tool["name"])
                self._tools, self._routes = tools, routes
                self._loaded_at = time.monotonic()
            return list(self._tools)

    def call_tool(self, name: str, arguments: dict) -> dict:
        route = self._routes.get(name)
        if route is None:
            self.tools(refresh=True)
            route = self._routes.get(name)
        if route is None:
            return tool_error(f"ferramenta desconhecida: {name}")
        up, original = route
        try:
            return up.call("tools/call", {"name": original, "arguments": arguments})
        except UpstreamError as err:
            log.warning("falha em %s: %s", name, err)
            return tool_error(f"o MCP do {up.name} não respondeu; tente de novo em instantes")


def tool_error(text: str) -> dict:
    return {"content": [{"type": "text", "text": text}], "isError": True}


def rpc_error(request_id: object, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def handle_rpc(gateway: Gateway, msg: object) -> dict | None:
    """Trata uma mensagem JSON-RPC; devolve None para notificações."""
    if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0" or not isinstance(msg.get("method"), str):
        return rpc_error(None, -32600, "pedido JSON-RPC inválido")
    method, request_id = msg["method"], msg.get("id")
    if "id" not in msg:
        return None  # notificação (notifications/initialized, cancelled...)
    params = msg.get("params") or {}
    if not isinstance(params, dict):
        return rpc_error(request_id, -32602, "params inválido")
    try:
        if method == "initialize":
            asked = params.get("protocolVersion")
            version = asked if asked in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0]
            result = {
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": SERVER_NAME, "version": VERSION},
                "instructions": INSTRUCTIONS,
            }
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": gateway.tools()}
        elif method == "tools/call":
            name, arguments = params.get("name"), params.get("arguments") or {}
            if not isinstance(name, str) or not isinstance(arguments, dict):
                return rpc_error(request_id, -32602, "tools/call precisa de name e arguments")
            log.info("tools/call %s", name)
            result = gateway.call_tool(name, arguments)
        else:
            return rpc_error(request_id, -32601, f"método não suportado: {method}")
    except RpcError as err:
        return {"jsonrpc": "2.0", "id": request_id, "error": err.error}
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def host_name(value: str) -> str:
    """Nome do host sem porta, de um cabeçalho Host ou de uma URL de Origin."""
    if "://" in value:
        return (urlsplit(value).hostname or "").lower()
    value = value.strip().lower()
    if value.startswith("["):
        return value[1 : value.find("]")] if "]" in value else value
    return value.rsplit(":", 1)[0] if value.count(":") == 1 else value


class Handler(BaseHTTPRequestHandler):
    server_version = SERVER_NAME
    sys_version = ""
    protocol_version = "HTTP/1.1"
    gateway: Gateway
    token: str
    allowed_hosts: frozenset[str]

    def log_message(self, fmt: str, *args: object) -> None:  # sem tokens nos logs
        log.debug("%s %s", self.address_string(), fmt % args)

    def _send(self, status: int, body: dict | None = None, headers: dict | None = None) -> None:
        data = json.dumps(body, ensure_ascii=False).encode() if body is not None else b""
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        if body is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _checks(self) -> bool:
        """Host/Origin (contra DNS rebinding) e token. Responde e devolve False se falhar."""
        host = host_name(self.headers.get("Host", ""))
        origin = self.headers.get("Origin")
        if host not in self.allowed_hosts or (origin and host_name(origin) not in self.allowed_hosts):
            self._send(403, rpc_error(None, -32000, "Host ou Origin não permitido"))
            return False
        auth = self.headers.get("Authorization", "")
        given = auth[7:].strip() if auth[:7].lower() == "bearer " else ""
        if not given or not hmac.compare_digest(given.encode(), self.token.encode()):
            self._send(
                401,
                rpc_error(None, -32001, "token ausente ou inválido"),
                {"WWW-Authenticate": 'Bearer realm="zabbix-grafana-mcp"'},
            )
            return False
        return True

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/healthz":
            self._send(200, {"status": "ok"})
        elif self.path.split("?")[0] == "/mcp":
            if self._checks():
                # Sem stream de eventos do servidor (modo sem sessão).
                self._send(405, None, {"Allow": "POST"})
        else:
            self._send(404, rpc_error(None, -32000, "não encontrado"))

    def do_DELETE(self) -> None:  # noqa: N802
        if self.path.split("?")[0] == "/mcp" and self._checks():
            self._send(405, None, {"Allow": "POST"})
        elif self.path.split("?")[0] != "/mcp":
            self._send(404, rpc_error(None, -32000, "não encontrado"))

    def do_POST(self) -> None:  # noqa: N802
        if self.path.split("?")[0] != "/mcp":
            self._send(404, rpc_error(None, -32000, "não encontrado"))
            return
        if not self._checks():
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length < 0 or length > MAX_REQUEST:
            self._send(413, rpc_error(None, -32600, "pedido grande demais"))
            return
        try:
            msg = json.loads(self.rfile.read(length) or b"null")
        except ValueError:
            self._send(400, rpc_error(None, -32700, "JSON inválido"))
            return
        if isinstance(msg, list):
            self._send(400, rpc_error(None, -32600, "lotes JSON-RPC não são suportados"))
            return
        response = handle_rpc(self.gateway, msg)
        if response is None:
            self._send(202)
        else:
            self._send(200, response)


def build_upstreams(env: dict) -> list[Upstream]:
    upstreams = []
    for name in ("zabbix", "grafana"):
        url = env.get(f"{name.upper()}_MCP_URL", "").strip()
        token = env.get(f"{name.upper()}_MCP_TOKEN", "").strip()
        if url and token:
            upstreams.append(Upstream(name, url, token))
        elif url:
            log.warning("%s desligado: %s_MCP_TOKEN vazio", name, name.upper())
    return upstreams


def main() -> int:
    logging.basicConfig(level=os.environ.get("MCP_LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    token = os.environ.get("MCP_TOKEN", "")
    if len(token) < 32:
        log.error("MCP_TOKEN precisa ter pelo menos 32 caracteres; rode make mcp")
        return 1
    upstreams = build_upstreams(dict(os.environ))
    if not upstreams:
        log.error("nenhum MCP interno configurado (ZABBIX_MCP_URL/GRAFANA_MCP_URL com token)")
        return 1
    listen = os.environ.get("MCP_LISTEN", "0.0.0.0:8765")
    addr, _, port = listen.rpartition(":")
    hosts = os.environ.get("MCP_ALLOWED_HOSTS", "localhost,127.0.0.1,::1")
    Handler.gateway = Gateway(upstreams)
    Handler.token = token
    Handler.allowed_hosts = frozenset(h.strip().lower().strip("[]") for h in hosts.split(",") if h.strip())
    server = ThreadingHTTPServer((addr.strip("[]") or "0.0.0.0", int(port)), Handler)
    server.daemon_threads = True
    log.info(
        "%s %s em %s; MCPs internos: %s", SERVER_NAME, VERSION, listen, ", ".join(u.name for u in upstreams)
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
