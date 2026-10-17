import sys
from cheroot import wsgi
from wsgidav.wsgidav_app import WsgiDAVApp
app = WsgiDAVApp({"provider_mapping": {"/": sys.argv[1]}, "verbose": 1, "logging": {"enable": False},
    "http_authenticator": {"domain_controller": None, "accept_basic": True, "accept_digest": True, "default_to_digest": False},
    "simple_dc": {"user_mapping": {"*": {"wl": {"password": "senha"}}}}})
server = wsgi.Server(("127.0.0.1", 8080), app)
print("dav ready", flush=True); server.start()
