#!/bin/bash

set -e

. /etc/lsb-release

MYUSER=cif
MYGROUP=cif
VER=$DISTRIB_RELEASE

if [ `whoami` != 'root' ]; then
    echo 'this script must be run as root'
    exit 0
fi

apt-get update
apt-get install -qq python-software-properties
echo "yes" | sudo add-apt-repository "ppa:chris-lea/zeromq"
wget -O - http://packages.elasticsearch.org/GPG-KEY-elasticsearch | apt-key add -

if [ -f /etc/apt/sources.list.d/elasticsearch.list ]; then
    echo "sources.list.d/elasticsearch.list already exists, skipping..."
else
    echo "deb http://packages.elasticsearch.org/elasticsearch/1.0/debian stable main" >> /etc/apt/sources.list.d/elasticsearch.list
fi

apt-get update
apt-get install -y curl cpanminus build-essential libmodule-build-perl libssl-dev elasticsearch apache2 libapache2-mod-perl2 curl mailutils build-essential git-core automake rng-tools openjdk-7-jre-headless libtool pkg-config vim htop bind9 libzmq3-dev libffi6 libmoose-perl libmouse-perl libanyevent-perl liblwp-protocol-https-perl libxml2-dev libexpat1-dev libgeoip-dev geoip-bin

if [ $VER == "12.04" ]; then ## 14.04 has it built in and supports cpanfile
	cpanm --self-upgrade --mirror http://cpan.metacpan.org
fi

# cpan.org has been less than reliable lately
cpanm --mirror http://cpan.metacpan.org Regexp::Common \
http://cpan.metacpan.org/authors/id/S/SH/SHERZODR/Config-Simple-4.59.tar.gz \
Mouse

echo 'HRNGDEVICE=/dev/urandom' >> /etc/default/rng-tools
service rng-tools restart

echo 'setting up bind...'

if [ -z `grep -l '8.8.8.8' /etc/bind/named.conf.options` ]; then
	echo 'overwriting bind config'
	cp /etc/bind/named.conf.options /etc/bind/named.conf.options.orig
	cp named.conf.options /etc/bind/named.conf.options
fi

if [ -z `grep -l 'spamhaus.org' /etc/bind/named.conf.local` ]; then
    cat ./named.conf.local >> /etc/bind/named.conf.local
fi

service bind9 restart

if [ -z `grep -l '127.0.0.1' /etc/resolvconf/resolv.conf.d/base` ]; then
    echo 'adding 127.0.0.1 as nameserver'
    echo "nameserver 127.0.0.1" >> /etc/resolvconf/resolv.conf.d/base
    echo "restarting network..."
    ifdown eth0 && sudo ifup eth0
fi

echo 'setting up apache'
cp cif.conf /etc/apache2/

if [ $VER == "12.04" ]; then
	cp /etc/apache2/sites-available/default-ssl /etc/apache2/sites-available/default-ssl.orig
	cp default-ssl /etc/apache2/sites-available
	a2dissite default
	a2ensite default-ssl
elif [ $VER == "14.04" ]; then
	cp /etc/apache2/sites-available/default-ssl.conf /etc/apache2/sites-available/default-ssl.conf.orig
	cp default-ssl /etc/apache2/sites-available/default-ssl.conf
	a2dissite 000-default.conf
	a2ensite default-ssl.conf
fi

a2enmod ssl

service apache2 restart

if [ -z `getent passwd $MYUSER` ]; then
	echo "adding user: $MYUSER"
	useradd $MYUSER -m -s /bin/bash
	adduser www-data $MYUSER
fi

echo 'starting elastic search'
update-rc.d elasticsearch defaults 95 10
service elasticsearch start

cd ../../../

./configure --enable-geoip --sysconfdir=/etc/cif --localstatedir=/var --prefix=/opt/cif
make && make deps NOTESTS=-n
make test
make install
make fixperms
make elasticsearch

echo 'copying init.d scripts...'
cp ./hacking/packaging/ubuntu/init.d/cif-smrt /etc/init.d/
cp ./hacking/packaging/ubuntu/init.d/cif-router /etc/init.d/

if [ ! -f /etc/default/cif ]; then
    echo 'setting /etc/default/cif'
    cp ./hacking/packaging/ubuntu/default/cif /etc/default/cif
fi

if [ ! -f /home/cif/.profile ]; then
	touch /home/cif/.profile
	chown $MYUSER:$MYGROUP /home/cif/.profile
fi

mkdir -p /var/smrt/cache
chown -R $MYUSER:$MYGROUP /var/smrt

if [ -z `grep -l '/opt/cif/bin' /home/cif/.profile` ]; then
    MYPROFILE=/home/$MYUSER/.profile
    echo "" >> $MYPROFILE
    echo "# automatically generated by CIF installation" >> $MYPROFILE
    echo 'PATH=/opt/cif/bin:$PATH' >> $MYPROFILE
fi

update-rc.d cif-router defaults 95 10
update-rc.d cif-smrt defaults 95 10

service cif-router start
