#!/bin/bash

MYSQL_ROOT_PASSWORD=sandwiches

USER=$1
PASSWORD=$3
DOMAIN=$3

if [ $# -ne 3 ]; then
    echo -e "Usage: $0 <username> <password> <domain>"
    exit 1
fi

mysql -u root -p$MYSQL_ROOT_PASSWORD <<EOF 
USE mail;
INSERT INTO domains (domain) VALUES ("${DOMAIN}");
INSERT INTO users (email, password) VALUES ("${USER}@${DOMAIN}", ENCRYPT("${PASSWORD}"));
quit
EOF
