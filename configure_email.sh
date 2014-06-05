#!/bin/bash
#
# email_config.sh
#
# This script installs and configures the following items:
#
# Mysql
# Postfix
# Dovecot
#
# Postfix is configured to query mysql for virtual domains and users and
# functions otherwise as a mail transfer agent. Dovecot is used to provide IMAP

if [ -f globals ]; then
	. globals
fi


# Install packages
function install_packages() {
    local package
    for package in ${PACKAGES[@]}; do
    	rpm -q $package > /dev/null && echo -e "${package} already installed"
        if [ $? -ne 0 ]; then
        	yum install "${package}" -y
        fi
    done
}

# Enable mysqld on boot an start service
function enable_mysql() {
    chkconfig --list mysqld | grep on > /dev/null
    if [ $? -ne 0 ]; then
    	echo -e "Enabling mysqld"
    	chkconfig mysqld on > /dev/null
    else
    	echo -e "Mysqld enabled"
    fi

    service mysqld status > /dev/null
    if [ $? -ne 0 ]; then
    	echo -e "Starting mysqld"
    	service mysqld start > /dev/null
    else
    	echo -e "Mysql started"
    fi
}

# Execute mysql_secure_install, if the test database doesn't exist
# then it's most likely been executed. An 'answer' file is piped into
# stdin.
function mysql_secure_install() {
    if [ -d '/var/lib/mysql/test' ]; then
        cat $MYSQL_ANSWER_FILE | mysql_secure_installation
    fi
}

# Set up the mail databases
function setup_databases() {
    if [ ! -d '/var/lib/mysql/mail' ]; then
    	mysql -u root -p$MYSQL_ROOT_PASSWORD < $CREATE_DATABASES_SQL
    fi
}

# Copy a my.cnf template that contains the required 'bind-address'
# directive to /etc/my.cnf
function my_cnf() {
    grep '127.0.0.1' /etc/my.cnf
    if [ $? -ne 0 ]; then
    	cp $MY_CNF /etc/my.cnf
    	service mysqld restart
    fi
}

# Copy the postfix configuration files to the postfix conf dir.
# These files configure postfix to query mysql for user information.
function postfix_configure() {
    local file
    for file in ${POSTFIX_CF[@]}; do
        if [ ! -f "/etc/postfix/${file}" ]; then
            cp $file /etc/postfix/
            chmod 640 /etc/postfix/$file
            chgrp postfix /etc/postfix/$file
        fi
    done

    id $VMAIL_USER
    if [ $? -ne 0 ]; then
    	groupadd -g 5000 $VMAIL_GROUP
    	useradd -g $VMAIL_USER -u 5000 $VMAIL_USER -d /home/$VMAIL_USER -m
    fi
}

# Postfix configuration directives
function postfix_do_postconf() {
    postconf -e "myhostname = $HOSTNAME"
    postconf -e 'mydestination = $myhostname, localhost, localhost.localdomain'
    postconf -e 'mynetworks = 127.0.0.0/8'
    postconf -e 'inet_interfaces = all'
    postconf -e 'message_size_limit = 30720000'
    postconf -e 'virtual_alias_domains ='
    postconf -e 'virtual_alias_maps = proxy:mysql:/etc/postfix/mysql-virtual_forwardings.cf, mysql:/etc/postfix/mysql-virtual_email2email.cf'
    postconf -e 'virtual_mailbox_domains = proxy:mysql:/etc/postfix/mysql-virtual_domains.cf'
    postconf -e 'virtual_mailbox_maps = proxy:mysql:/etc/postfix/mysql-virtual_mailboxes.cf'
    postconf -e 'virtual_mailbox_base = /home/vmail'
    postconf -e 'virtual_uid_maps = static:5000'
    postconf -e 'virtual_gid_maps = static:5000'
    postconf -e 'smtpd_sasl_type = dovecot'
    postconf -e 'smtpd_sasl_path = private/auth'
    postconf -e 'smtpd_sasl_auth_enable = yes'
    postconf -e 'broken_sasl_auth_clients = yes'
    postconf -e 'smtpd_sasl_authenticated_header = yes'
    postconf -e 'smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination'
    postconf -e 'smtpd_use_tls = yes'
    postconf -e 'smtpd_tls_cert_file = /etc/pki/dovecot/certs/dovecot.pem'
    postconf -e 'smtpd_tls_key_file = /etc/pki/dovecot/private/dovecot.pem'
    postconf -e 'virtual_create_maildirsize = yes'
    postconf -e 'virtual_maildir_extended = yes'
    postconf -e 'proxy_read_maps = $local_recipient_maps $mydestination $virtual_alias_maps $virtual_alias_domains $virtual_mailbox_maps $virtual_mailbox_domains $relay_recipient_maps $relay_domains $canonical_maps $sender_canonical_maps $recipient_canonical_maps $relocated_maps $transport_maps $mynetworks $virtual_mailbox_limit_maps'
    postconf -e 'virtual_transport = dovecot'
    postconf -e 'dovecot_destination_recipient_limit = 1'
}

# Use dovecot for delivery
function postfix_master_conf() {
    grep 'dovecot' /etc/postfix/master.cf > /dev/null
    if [ $? -ne 0 ]; then
cat <<EOF >> /etc/postfix/master.cf
dovecot   unix  -       n       n       -       -       pipe
  flags=DRhu user=vmail:vmail argv=/usr/libexec/dovecot/deliver -f \${sender} -d \${recipient}
EOF
    fi
}

# Ensure postfix on boot and enable services
function postfix_enable_services() {
    rpm -q sendmail > /dev/null
    if [ $? -eq 0 ]; then
        service sendmail stop
        chkconfig sendmail off
    fi
    chkconfig postfix on
    service postfix start
}

# Copy the provided dovecot configuration files to the dovcot conf directory
function dovecot_conf() {
    cp /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.bak
    cp dovecot.conf /etc/dovecot/dovecot.conf
    cp dovecot-sql.conf /etc/dovecot/dovecot-sql.conf
    chgrp dovecot /etc/dovecot/dovecot-sql.conf
    chmod 640 /etc/dovecot/dovecot-sql.conf
}

# Ensure dovecot on boot and enable the service
function dovecot_enable_services() {
    chkconfig dovecot on
    service dovecot start
}

# Execute sql to create a test user and domain
function setup_test_user() {
    mysql -u root -p$MYSQL_ROOT_PASSWORD < test_user.sql
}

# Ensure iptables allows postfix and dovecot
# 25  -> postfix
# 993 -> imaps
# 143 -> imap
# 995 -> pop3s
# 110 -> pop3
function iptables_configure() {
    grep '25,993,995,110,143' /etc/sysconfig/iptables > /dev/null
    if [ $? -ne 0 ]; then
        iptables -I INPUT -m multiport -p tcp --dports 25,993,995,110,143 -j ACCEPT
        iptables-save > /etc/sysconfig/iptables
        service iptables restart
    fi
}

function main() {
    install_packages
    enable_mysql
    mysql_secure_install
    setup_databases
    my_cnf
    postfix_configure
    postfix_do_postconf
    postfix_master_conf
    postfix_enable_services
    dovecot_conf
    dovecot_enable_services
    setup_test_user
    iptables_configure
}
main
