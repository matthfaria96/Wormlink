# Servidor OpenStack Swift simulado (só para testes), segundo a documentação oficial da API:
# Keystone v3 (POST /v3/auth/tokens) e TempAuth (GET /auth/v1.0); contêineres e objetos em memória.
# Usuário "projeto:wl", senha "senha". Porta 8090.
import datetime, hashlib, json, sys, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8090
TOKEN = "tok-123"
STORAGE = "/v1/AUTH_test"
containers = {}          # nome -> {objeto: (dados, content_type, modificado)}
lock = threading.Lock()

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def reply(self, code, body=b"", headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def route(self):
        u = urllib.parse.urlsplit(self.path)
        q = dict(urllib.parse.parse_qsl(u.query, keep_blank_values=True))
        path = urllib.parse.unquote(u.path)
        if path == "/v3/auth/tokens" and self.command == "POST":
            auth = json.loads(self.body())["auth"]
            user = auth["identity"]["password"]["user"]
            if user["name"] != "wl" or user["password"] != "senha": return self.reply(401)
            catalog = [{"type": "object-store", "endpoints": [
                {"interface": "public", "region": "RegionOne", "url": f"http://127.0.0.1:{PORT}{STORAGE}"},
                {"interface": "internal", "region": "RegionOne", "url": "http://10.0.0.1/naoUsar"}]}]
            return self.reply(201, json.dumps({"token": {"catalog": catalog}}).encode(), {"X-Subject-Token": TOKEN, "Content-Type": "application/json"})
        if path == "/auth/v1.0":
            if self.headers.get("X-Auth-User") != "projeto:wl" or self.headers.get("X-Auth-Key") != "senha": return self.reply(401)
            return self.reply(204, headers={"X-Storage-Url": f"http://127.0.0.1:{PORT}{STORAGE}", "X-Auth-Token": TOKEN})
        if not path.startswith(STORAGE): return self.reply(404)
        if self.headers.get("X-Auth-Token") != TOKEN: return self.reply(401)
        rest = path[len(STORAGE):].lstrip("/")
        container, _, obj = rest.partition("/")
        with lock:
            if not container:
                return self.reply(200, json.dumps([{"name": c} for c in sorted(containers)]).encode(), {"Content-Type": "application/json"})
            if not obj:
                if self.command == "PUT": containers.setdefault(container, {}); return self.reply(201)
                if self.command == "DELETE": containers.pop(container, None); return self.reply(204)
                if container not in containers: return self.reply(404)
                prefix, delim = q.get("prefix", ""), q.get("delimiter")
                out, seen = [], set()
                for name in sorted(containers[container]):
                    if not name.startswith(prefix): continue
                    if q.get("marker") and name <= q["marker"]: continue
                    rest_name = name[len(prefix):]
                    if delim and delim in rest_name:
                        sub = prefix + rest_name.split(delim)[0] + delim
                        if sub not in seen: seen.add(sub); out.append({"subdir": sub})
                        continue
                    data, ctype, mtime = containers[container][name]
                    out.append({"name": name, "bytes": len(data), "content_type": ctype, "hash": hashlib.md5(data).hexdigest(),
                                "last_modified": mtime})
                return self.reply(200, json.dumps(out).encode(), {"Content-Type": "application/json"})
            store = containers.get(container)
            if store is None: return self.reply(404)
            if self.command == "PUT":
                src = self.headers.get("X-Copy-From")
                data = self.body()
                if src:
                    sc, _, so = urllib.parse.unquote(src).lstrip("/").partition("/")
                    if so not in containers.get(sc, {}): return self.reply(404)
                    data, ctype, _ = containers[sc][so]
                else:
                    ctype = self.headers.get("Content-Type", "application/octet-stream")
                now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")
                store[obj] = (data, ctype, now)
                return self.reply(201, headers={"Etag": hashlib.md5(data).hexdigest()})
            if obj not in store: return self.reply(404)
            data, ctype, _ = store[obj]
            if self.command == "DELETE": del store[obj]; return self.reply(204)
            headers = {"Etag": hashlib.md5(data).hexdigest(), "Content-Type": ctype}
            rng = self.headers.get("Range")
            if rng and rng.startswith("bytes="):
                start = int(rng[6:].split("-")[0])
                headers["Content-Range"] = f"bytes {start}-{len(data)-1}/{len(data)}"
                return self.reply(206, data[start:], headers)
            return self.reply(200, data, headers)

    do_GET = do_PUT = do_POST = do_DELETE = do_HEAD = route

print("swift ready", flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
