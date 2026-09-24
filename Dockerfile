FROM python:3.12-alpine

RUN apk add --no-cache openssh-server \
 && adduser -D tlx \
 && echo 'tlx:*' | chpasswd -e

COPY relay.py /relay.py

VOLUME /etc/ssh /home/tlx

EXPOSE 22

CMD printf '%s\n' $TLX_MEMBERS > /members \
 && ssh-keygen -A \
 && chown tlx /home/tlx \
 && exec /usr/sbin/sshd -D -e \
    -o AllowUsers=tlx \
    -o PasswordAuthentication=no \
    -o DisableForwarding=yes \
    -o PermitTTY=no \
    -o AuthorizedKeysFile=none \
    -o "AuthorizedKeysCommand=/relay.py authorized-keys" \
    -o AuthorizedKeysCommandUser=tlx
