#!/bin/bash
# generate a test CA to put in the browser and server certificates signed by it.

usage() { echo "USAGE: mgit cert $1"; exit; }

do_ca() {
	openssl genrsa -out test-ca.key 2048
	openssl req -x509 -new -nodes -key test-ca.key -sha256 -days 9999 -out test-ca.pem
}

do_server() {
	local NAME="$1"; [ "$NAME" ] || usage "server <hostname>"
	openssl genrsa -out $NAME.key 2048
	openssl req -new -key $NAME.key -out $NAME.csr
	>$NAME.ext cat <<-EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = $NAME
EOF
	openssl x509 -req -in $NAME.csr -CA test-ca.pem -CAkey test-ca.key -CAcreateserial \
		-out $NAME.crt -days 9999 -sha256 -extfile $NAME.ext
	rm $NAME.ext
}

cmd="$1"; shift
[ "$cmd" ] || usage "ca | server <hostname>"
"do_$cmd" "$@"

