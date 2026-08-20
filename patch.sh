#!/bin/bash
sudo -u glukvpn -H bash -c 'cd /opt/glukvpn/control-server && sed -i "s/if (error instanceof HttpError)/console.log(\"caught!\", error.name, error instanceof HttpError); if (error instanceof HttpError)/" src/app.ts'
sudo -u glukvpn -H bash -c 'cd /opt/glukvpn/control-server && npm run build'
sudo systemctl restart glukvpn-control
