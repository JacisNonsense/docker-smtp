#!/bin/bash
set -e

postconf -e myhostname=$DOMAIN
postconf -e mynetworks=127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16

# OpenDKIM
postconf -e milter_protocol=2
postconf -e milter_default_action=accept
postconf -e smtpd_milters=inet:localhost:12301
postconf -e non_smtpd_milters=inet:localhost:12301

export SOCKET="inet:12301@localhost"

cat > /etc/opendkim/opendkim.conf <<EOF
AutoRestart             Yes
AutoRestartRate         10/1h
UMask                   002
Syslog                  yes
SyslogSuccess           Yes
LogWhy                  Yes

Canonicalization        relaxed/simple

ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable

Mode                    sv
PidFile                 /var/run/opendkim/opendkim.pid
SignatureAlgorithm      rsa-sha256

UserID                  opendkim:opendkim

Socket                  inet:12301@localhost
EOF

cat > /etc/opendkim/TrustedHosts <<EOF
localhost
127.0.0.0/8
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16

*.$DOMAIN
EOF

if [ -f /run/secrets/opendkim_private ]; then
cp /run/secrets/opendkim_private /opendkim.private
else
cp /dkim/mail.private /opendkim.private
fi

cat > /etc/opendkim/KeyTable <<EOF
mail._domainkey.$DOMAIN $DOMAIN:mail:/opendkim.private
EOF

cat > /etc/opendkim/SigningTable <<EOF
*@$DOMAIN mail._domainkey.$DOMAIN
EOF

chown opendkim:opendkim /opendkim.private
chmod 440 /opendkim.private

mkdir -p /var/run/opendkim
opendkim

# Cyrus-SASL
postconf -e smtpd_sasl_auth_enable=yes
postconf -e broken_sasl_auth_client=yes
postconf -e smtpd_recipient_restrictions=permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination
postconf -e smtp_tls_security_level=may

mkdir -p /etc/postfix/sasl
cat >> /etc/postfix/sasl/smtpd.conf <<EOF
pwcheck_method: auxprop
auxprop_plugin: sasldb
mech_list: PLAIN LOGIN CRAM-MD5 DIGEST-MD5 NTLM
EOF

while IFS=':' read -r _user _pwd; do
  echo $_pwd | saslpasswd2 -p -c -u $maildomain $_user
done < /run/secrets/smtp_passwd

# Services
syslogd
postfix start

exec "$@"