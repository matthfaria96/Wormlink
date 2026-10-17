#!/bin/sh
# ProFTPD com mod_tls para testar FTPS com reaproveitamento obrigatório da sessão TLS nas conexões de dados
# (o padrão do ProFTPD, do vsftpd e do FileZilla Server). Compila uma vez a partir do código-fonte oficial,
# sem instalar nada no sistema, e sobe na porta 2124 (usuário wl / senha senha).
# Uso: scripts/test-servers/proftpd.sh <pasta> [TLSv1.2|"TLSv1.2 TLSv1.3"]
#   WORMLINK_SERVERS=<pasta dos outros servidores> WORMLINK_PROFTPD=2124 swift test --filter protocolRoundTrip
# Requer o OpenSSL do Homebrew (/opt/homebrew/opt/openssl@3).
set -eu
W="${1:?pasta de trabalho}"
PROTOCOLS="${2:-TLSv1.2 TLSv1.3}"
VERSION=1.3.9d
SSL=/opt/homebrew/opt/openssl@3
mkdir -p "$W/proftpd/root"
cd "$W/proftpd"
if [ ! -x "proftpd-$VERSION/proftpd" ]; then
  curl -fsSL -o proftpd.tar.gz "https://github.com/proftpd/proftpd/archive/refs/tags/v$VERSION.tar.gz"
  tar xzf proftpd.tar.gz
  (cd "proftpd-$VERSION" && ./configure --with-modules=mod_tls --disable-pam --disable-ident --disable-cap \
     CPPFLAGS="-I$SSL/include" LDFLAGS="-L$SSL/lib" >/dev/null && make -j8 >/dev/null)
fi
[ -f "$W/tls.crt" ] || openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/tls.key" -out "$W/tls.crt" -days 30 -subj "/CN=localhost" 2>/dev/null
chmod 600 "$W/tls.key"
# Usuário virtual com o uid do usuário atual (o servidor roda sem root, então sem chroot).
HASH=$(python3 -c "import crypt; print(crypt.crypt('senha', 'wl'))")
echo "wl:$HASH:$(id -u):$(id -g)::$W/proftpd/root:/bin/sh" > passwd
chmod 600 passwd
cat > proftpd.conf <<CFG
ServerName "Wormlink teste"
ServerType standalone
DefaultServer on
Port 2124
DefaultAddress 127.0.0.1
User $(id -un)
Group $(id -gn)
UseIPv6 off
PidFile $W/proftpd/proftpd.pid
ScoreboardFile $W/proftpd/scoreboard
DelayTable none
WtmpLog off
TransferLog none
AuthOrder mod_auth_file.c
AuthUserFile $W/proftpd/passwd
RequireValidShell off
PassivePorts 50100 50150
UseReverseDNS off
<IfModule mod_tls.c>
  TLSEngine on
  TLSLog $W/proftpd/tls.log
  TLSProtocol $PROTOCOLS
  TLSRequired on
  TLSRSACertificateFile $W/tls.crt
  TLSRSACertificateKeyFile $W/tls.key
  TLSVerifyClient off
</IfModule>
<Directory />
  AllowOverwrite on
  AllowStoreRestart on
  AllowRetrieveRestart on
</Directory>
CFG
echo "ProFTPD na porta 2124 (TLS: $PROTOCOLS). Ctrl-C para parar."
exec "./proftpd-$VERSION/proftpd" -n -c "$W/proftpd/proftpd.conf"
