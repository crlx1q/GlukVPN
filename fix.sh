#!/bin/bash
sudo -u glukvpn -H bash -c 'cd /opt/glukvpn/control-server && sed -i "s/const parsed = CreateUserBody.safeParse(request.body)/console.log(\"ROUTE_HANDLER_RUNNING\"); const parsed = CreateUserBody.safeParse(request.body)/" src/routes/admin.ts'
sudo -u glukvpn -H bash -c 'cd /opt/glukvpn/control-server && npm run build'
sudo systemctl restart glukvpn-control
