#!/bin/sh

# NOTE: this is used during the building of the Docker container

# Run vsftpd:
&>/dev/null /usr/sbin/vsftpd /etc/vsftpd/vsftpd.conf &

#cd /opt/httpd
#plackup ./bin/app.psgi

tail -f /dev/null
