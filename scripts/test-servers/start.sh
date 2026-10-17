#!/bin/sh
# Sobe servidores locais para o teste de integração (127.0.0.1), numa pasta de trabalho descartável:
#   SFTP 2222 (sshd do macOS em modo usuário, chaves ed25519 e RSA), FTP 2121, FTPS explícito 2122,
#   WebDAV 8080 (wl/senha), S3 9000 (versitygw ou rclone, WLACCESS/WLSECRET1234) e SFTP com
#   keyboard-interactive 2223 (wl / senha / código 123456).
# Para o teste do agente SSH: ssh-agent -a /tmp/x/s; ssh-add <pasta>/ssh/client_ed25519; WORMLINK_AGENT=/tmp/x/s
# Uso: scripts/test-servers/start.sh <pasta>   e depois:
#   WORMLINK_SERVERS=<pasta> DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter protocolRoundTrip
# Requer python3 (pyftpdlib, pyopenssl, wsgidav, cheroot, asyncssh num venv) e versitygw ou rclone no PATH.
# Variáveis dos testes: WORMLINK_SERVERS=<pasta> [WORMLINK_KBDINT=1] [WORMLINK_AGENT=<socket>]
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
W="${1:?pasta de trabalho}"
mkdir -p "$W/ssh" "$W/root" "$W/ftproot" "$W/davroot" "$W/s3root/bucket-um"
cd "$W"
[ -f ssh/host_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -f ssh/host_ed25519
[ -f ssh/client_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -f ssh/client_ed25519
[ -f ssh/client_rsa ] || ssh-keygen -q -t rsa -b 3072 -N "" -f ssh/client_rsa
[ -f ssh/client_enc ] || ssh-keygen -q -t ed25519 -N segredo -f ssh/client_enc   # chave com frase secreta
[ -f ssh/client_ecdsa ] || ssh-keygen -q -t ecdsa -b 256 -N "" -f ssh/client_ecdsa
cat ssh/client_ed25519.pub ssh/client_rsa.pub ssh/client_enc.pub ssh/client_ecdsa.pub > ssh/authorized_keys
cat > ssh/sshd_config <<CFG
Port 2222
ListenAddress 127.0.0.1
HostKey $W/ssh/host_ed25519
PidFile $W/ssh/sshd.pid
AuthorizedKeysFile $W/ssh/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
Subsystem sftp /usr/libexec/sftp-server
CFG
[ -f tls.pem ] || { openssl req -x509 -newkey rsa:2048 -nodes -keyout tls.key -out tls.crt -days 30 -subj "/CN=localhost" 2>/dev/null; cat tls.key tls.crt > tls.pem; }
[ -d venv ] || { python3 -m venv venv && ./venv/bin/pip install -q pyftpdlib pyopenssl wsgidav cheroot; }
/usr/sbin/sshd -D -e -f ssh/sshd_config > ssh/log.txt 2>&1 &
./venv/bin/python -I "$HERE/ftp.py" "$W/ftproot" "$W/tls.pem" plain > ftp-plain.log 2>&1 &
./venv/bin/python -I "$HERE/ftp.py" "$W/ftproot" "$W/tls.pem" tls > ftp-tls.log 2>&1 &
./venv/bin/python -I "$HERE/dav.py" "$W/davroot" > dav.log 2>&1 &
# S3: versitygw (gateway fiel, grava direto no disco); rclone serve s3 como alternativa (tem cache de VFS).
if command -v versitygw >/dev/null; then
  mkdir -p "$W/vgw/bucket-um"
  versitygw --port 127.0.0.1:9000 --access WLACCESS --secret WLSECRET1234 posix "$W/vgw" > s3.log 2>&1 &
else
  rclone serve s3 --dir-cache-time 0s --addr 127.0.0.1:9000 --auth-key WLACCESS,WLSECRET1234 --force-path-style "$W/s3root" > s3.log 2>&1 &
fi
# Keyboard-interactive (senha + código 2FA) na porta 2223; precisa do asyncssh no venv.
./venv/bin/pip install -q asyncssh >/dev/null 2>&1 || true
./venv/bin/python -I "$HERE/kbdint.py" "$W/root" > kbdint.log 2>&1 &
echo "Servidores no ar. Para parar: kill $(jobs -p | tr '\n' ' ')"
wait
