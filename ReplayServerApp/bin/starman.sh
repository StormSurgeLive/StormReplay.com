#!/usr/bin/bash

sudo starman --children 2 --pid ./starman.pid                                                \
  --signal-on-hup=QUIT ./bin/app.psgi                                                        \
  --listen :443:ssl --enable-ssl --ssl-key /etc/letsencrypt/live/stormreplay.com/privkey.pem \
  --ssl-cert /etc/letsencrypt/live/stormreplay.com/fullchain.pem                             \
  --user user --group user
