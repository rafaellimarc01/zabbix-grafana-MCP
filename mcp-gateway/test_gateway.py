"""Testes do gateway com MCPs internos falsos. Rode: python -m unittest -v"""

import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import os
import tempfile

import gateway

TOKEN = "t" * 40


def fake_upstream(tools, token, sse=False):
    """Sobe um MCP falso que exige sessão e responde em JSON ou SSE."""
    state = {"sessions": set(), "calls": []}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            msg = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            expected = None if token is None else "Bearer " + token
            if self.headers.get("Authorization") != expected:
                self.send_response(401)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            headers = {}
            if msg["method"] == "initialize":
                sid = "s%d" % (len(state["sessions"]) + 1)
                state["sessions"].add(sid)
                headers["Mcp-Session-Id"] = sid
                result = {"protocolVersion": msg["params"]["protocolVersion"], "capabilities": {}, "serverInfo": {"name": "f", "version": "1"}}
            elif self.headers.get("Mcp-Session-Id") not in state["sessions"]:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            elif "id" not in msg:
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            elif msg["method"] == "tools/list":
                result = {"tools": tools}
            elif msg["method"] == "tools/call":
                state["calls"].append(msg["params"])
                if msg["params"]["name"] == "boom":
                    body = {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32602, "message": "bad"}}
                    self._reply(body, headers)
                    return
                result = {"content": [{"type": "text", "text": "ok " + msg["params"]["name"]}]}
            body = {"jsonrpc": "2.0", "id": msg["id"], "result": result}
            self._reply(body, headers)

        def _reply(self, body, headers):
            if sse:
                data = ("event: message\ndata: " + json.dumps(body) + "\n\n").encode()
                ctype = "text/event-stream"
            else:
                data, ctype = json.dumps(body).encode(), "application/json"
            self.send_response(200)
            for k, v in headers.items():
                self.send_header(k, v)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, "http://127.0.0.1:%d/mcp" % srv.server_address[1], state


class GatewayTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.z, zurl, cls.zstate = fake_upstream([{"name": "host_get", "inputSchema": {"type": "object"}}], "ztok", sse=True)
        cls.g, gurl, cls.gstate = fake_upstream(
            [{"name": "search_dashboards", "inputSchema": {"type": "object"}, "annotations": {"title": "x"}}, {"name": "boom", "inputSchema": {"type": "object"}}],
            "gtok",
        )
        cls.k, kurl, cls.kstate = fake_upstream([{"name": "pods_list", "inputSchema": {"type": "object"}}], None)
        cls.tmp = tempfile.TemporaryDirectory()
        cls.gfile = os.path.join(cls.tmp.name, "grafana-token")
        with open(cls.gfile, "w") as f:
            f.write("gtok\n")
        ups = gateway.build_upstreams({
            "ZABBIX_MCP_URL": zurl, "ZABBIX_MCP_TOKEN": "ztok",
            "GRAFANA_MCP_URL": gurl, "GRAFANA_MCP_TOKEN_FILE": cls.gfile,
            "KUBERNETES_MCP_URL": kurl,
        })
        gateway.Handler.gateway = gateway.Gateway(ups)
        gateway.Handler.token = TOKEN
        gateway.Handler.allowed_hosts = frozenset({"localhost", "127.0.0.1", "::1"})
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), gateway.Handler)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.url = "http://127.0.0.1:%d/mcp" % cls.srv.server_address[1]

    @classmethod
    def tearDownClass(cls):
        for s in (cls.srv, cls.z, cls.g, cls.k):
            s.shutdown()
        cls.tmp.cleanup()

    def post(self, body, token=TOKEN, headers=None):
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if token:
            h["Authorization"] = "Bearer " + token
        h.update(headers or {})
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), headers=h, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                raw = r.read()
                return r.status, json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            return e.code, None

    def test_sem_token_401(self):
        self.assertEqual(self.post({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, token=None)[0], 401)

    def test_token_errado_401(self):
        self.assertEqual(self.post({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, token="x" * 40)[0], 401)

    def test_origin_estranho_403(self):
        st, _ = self.post({"jsonrpc": "2.0", "id": 1, "method": "ping"}, headers={"Origin": "https://evil.example"})
        self.assertEqual(st, 403)

    def test_host_estranho_403(self):
        st, _ = self.post({"jsonrpc": "2.0", "id": 1, "method": "ping"}, headers={"Host": "evil.example:8765"})
        self.assertEqual(st, 403)

    def test_initialize(self):
        st, r = self.post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}})
        self.assertEqual(st, 200)
        self.assertEqual(r["result"]["protocolVersion"], "2025-03-26")
        self.assertIn("tools", r["result"]["capabilities"])

    def test_notificacao_202(self):
        self.assertEqual(self.post({"jsonrpc": "2.0", "method": "notifications/initialized"})[0], 202)

    def test_lista_com_prefixos(self):
        _, r = self.post({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        names = sorted(t["name"] for t in r["result"]["tools"])
        self.assertEqual(names, ["grafana_boom", "grafana_search_dashboards", "k8s_pods_list", "zabbix_host_get"])
        for t in r["result"]["tools"]:
            self.assertTrue(t["annotations"]["readOnlyHint"])

    def test_chamada_roteada(self):
        _, r = self.post({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "zabbix_host_get", "arguments": {"a": 1}}})
        self.assertEqual(r["result"]["content"][0]["text"], "ok host_get")
        self.assertIn({"name": "host_get", "arguments": {"a": 1}}, self.zstate["calls"])
        _, r = self.post({"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "grafana_search_dashboards", "arguments": {}}})
        self.assertEqual(r["result"]["content"][0]["text"], "ok search_dashboards")

    def test_erro_do_upstream_repassado(self):
        _, r = self.post({"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "grafana_boom", "arguments": {}}})
        self.assertEqual(r["error"]["code"], -32602)

    def test_ferramenta_desconhecida(self):
        _, r = self.post({"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "zabbix_item_get", "arguments": {}}})
        self.assertTrue(r["result"]["isError"])

    def test_sessao_expirada_reconecta(self):
        self.post({"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "zabbix_host_get", "arguments": {}}})
        self.zstate["sessions"].clear()
        _, r = self.post({"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "zabbix_host_get", "arguments": {}}})
        self.assertEqual(r["result"]["content"][0]["text"], "ok host_get")

    def test_metodo_desconhecido_e_lote(self):
        _, r = self.post({"jsonrpc": "2.0", "id": 9, "method": "resources/list"})
        self.assertEqual(r["error"]["code"], -32601)
        self.assertEqual(self.post([{"jsonrpc": "2.0", "id": 1, "method": "ping"}])[0], 400)

    def test_kubernetes_sem_token(self):
        _, r = self.post({"jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": {"name": "k8s_pods_list", "arguments": {}}})
        self.assertEqual(r["result"]["content"][0]["text"], "ok pods_list")

    def test_token_em_arquivo_vazio_desliga(self):
        up = gateway.Upstream("grafana", "http://127.0.0.1:1/mcp", token_file=self.gfile)
        self.assertTrue(up.enabled())
        empty = os.path.join(self.tmp.name, "vazio")
        open(empty, "w").close()
        up = gateway.Upstream("zabbix", "http://127.0.0.1:1/mcp", token_file=empty)
        self.assertFalse(up.enabled())
        self.assertEqual(gateway.build_upstreams({"ZABBIX_MCP_URL": "http://x/mcp"}), [])

    def test_host_name(self):
        self.assertEqual(gateway.host_name("localhost:8765"), "localhost")
        self.assertEqual(gateway.host_name("[::1]:8765"), "::1")
        self.assertEqual(gateway.host_name("http://127.0.0.1:8765"), "127.0.0.1")


if __name__ == "__main__":
    unittest.main()
