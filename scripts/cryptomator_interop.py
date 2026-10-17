"""Cofres do Cryptomator feitos e lidos pelo pycryptomator, para conferir a compatibilidade do Wormlink.

    make <pasta> <senha>   cria um cofre com alguns arquivos e imprime o conteúdo esperado (JSON)
    dump <pasta> <senha>   imprime o conteúdo decifrado de um cofre (JSON: caminho -> sha256 ou "dir")
"""
import hashlib, io, json, os, sys, tempfile, unicodedata

if not hasattr(hashlib, "scrypt"):   # Python do macOS (LibreSSL) não tem; usa o do pycryptodome
    from Crypto.Protocol.KDF import scrypt as _scrypt
    hashlib.scrypt = lambda password, salt, n, r, p, maxmem=0, dklen=64: _scrypt(password, salt, dklen, n, r, p)

from pycryptomator.cryptomator import Vault, init_vault

LONG = "nome comprido " * 12 + ".txt"   # passa do limite de 220 caracteres cifrados (vira .c9s)


def dump(vault):
    result = {}
    for root, dirs, files in vault.walk("/"):
        for d in dirs:
            result[os.path.join(root, d)] = "dir"
        for f in files:
            with tempfile.TemporaryDirectory() as temp:
                target = os.path.join(temp, "arquivo")
                vault.decryptFile(os.path.join(root, f), target)
                result[os.path.join(root, f)] = hashlib.sha256(open(target, "rb").read()).hexdigest()
    return result


command, folder, password = sys.argv[1:4]
password = unicodedata.normalize("NFC", password)   # como o Cryptomator (e o Process do macOS manda NFD)
if command == "make":
    os.makedirs(folder, exist_ok=True)
    init_vault(folder, password)
    vault = Vault(folder, password)
    vault.mkdir("/Pasta/Sub")
    vault.mkdir("/" + LONG.replace(".txt", " pasta"))
    files = {
        "/leia-me.txt": "Olá, cofre!".encode(),
        "/vazio": b"",
        "/Pasta/blocos.bin": bytes(range(256)) * 300,      # mais de um bloco de 32 KiB
        "/Pasta/Sub/" + LONG: b"nome longo",
    }
    for path, data in files.items():
        vault.encryptFile(io.BytesIO(data), path)
    print(json.dumps(dump(vault), sort_keys=True))
else:
    print(json.dumps(dump(Vault(folder, password)), sort_keys=True))
