#!/bin/bash
RESP=$(curl -s -X POST http://127.0.0.1:8081/api/auth/login -H "Content-Type: application/json" -d '{"username": "alisher@gluk.tech", "password": "65195678"}')
TOKEN=$(echo $RESP | jq -r .accessToken)
curl -s -X POST http://127.0.0.1:8081/api/admin/users -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d '{"username": "test4@example.com", "password": "short"}'
