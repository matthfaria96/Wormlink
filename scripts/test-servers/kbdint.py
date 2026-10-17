# Servidor SFTP (asyncssh) que só aceita keyboard-interactive em duas etapas, como PAM + 2FA:
# primeiro "Password:" (oculta), depois "Verification code:" (visível). Usuário wl, senha "senha", código 123456.
import asyncio, sys
import asyncssh

ROOT = sys.argv[1]

class Server(asyncssh.SSHServer):
    def begin_auth(self, username): return True
    def password_auth_supported(self): return False
    def public_key_auth_supported(self): return False
    def kbdint_auth_supported(self): return True
    def get_kbdint_challenge(self, username, lang, submethods):
        self._step = 0
        return "", "", "", [("Password: ", False)]
    def validate_kbdint_response(self, username, responses):
        if self._step == 0:
            if username != "wl" or responses != ["senha"]: return False
            self._step = 1
            return "Dois fatores", "Digite o código do app autenticador.", "", [("Verification code: ", True)]
        return responses == ["123456"]

async def main():
    await asyncssh.create_server(Server, "127.0.0.1", 2223, server_host_keys=[asyncssh.generate_private_key("ssh-ed25519")],
                                 sftp_factory=lambda chan: asyncssh.SFTPServer(chan, chroot=ROOT))
    print("kbdint ready", flush=True)
    await asyncio.Future()

asyncio.run(main())
