#!/bin/bash
# Cadre icin sabit bir yerel imza kimligi kurar.
# Ad-hoc imza her derlemede degisir, macOS de ekran kaydi iznini her seferinde unutur.
# Bu kimlik sabittir, izin bir kez verilir.
set -euo pipefail

NAME="Cadre Yerel Imza"
DIR="$HOME/.cadre-signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Kimlik zaten var: $NAME"
  exit 0
fi

mkdir -p "$DIR"
cd "$DIR"

cat > openssl.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Cadre Yerel Imza
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
  -days 3650 -nodes -config openssl.cnf >/dev/null 2>&1
openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem \
  -passout pass: -name "$NAME" >/dev/null 2>&1

echo "Sertifika anahtarliga aliniyor. Parola sorulabilir."
security import cert.p12 -k "$KEYCHAIN" -P "" -T /usr/bin/codesign

echo "Sertifikaya guven veriliyor. Yonetici parolasi sorulacak."
security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain cert.pem

echo
echo "Bitti. Simdi sunlari calistir:"
echo "  tccutil reset ScreenCapture com.huseyinsenkaya.cadre"
echo "  ~/Developer/cadre/Scripts/run.sh release"
