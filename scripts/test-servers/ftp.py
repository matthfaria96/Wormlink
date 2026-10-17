import sys
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
from pyftpdlib.servers import FTPServer
root, pem, mode = sys.argv[1], sys.argv[2], sys.argv[3]
auth = DummyAuthorizer(); auth.add_user("wl", "senha", root, perm="elradfmwMT")
if mode == "tls":
    class H(TLS_FTPHandler): pass
    H.certfile = pem; H.tls_control_required = True; H.tls_data_required = True; port = 2122; H.passive_ports = range(30100, 30200)
else:
    class H(FTPHandler): pass
    port = 2121; H.passive_ports = range(30000, 30100)
H.authorizer = auth
print("ftp ready", mode, flush=True); FTPServer(("127.0.0.1", port), H).serve_forever()
