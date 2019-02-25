#
# Dockerfile to build a MISP (https://github.com/MISP/MISP) container
#
# Original docker file by eg5846 (https://github.com/eg5846)
#
# 2016/03/03 - First release
# 2017/06/02 - Updated
# 2018/04/04 - Added objects templates
# 2019/02/25 - Updated to ubuntu bionic, removed external dependencies, moved redis to external container, minimized dependencies

# We are based on Ubuntu:latest
FROM ubuntu:bionic
MAINTAINER Xavier Mertens <xavier@rootshell.be>

# Install core components
ENV DEBIAN_FRONTEND noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y  apache2 apache2-doc apache2-utils  \
                        software-properties-common postfix mysql-client curl gcc git gnupg-agent \
                        make openssl sudo vim zip locales \
                        apache2 apache2-doc apache2-utils  \
                        libapache2-mod-php php7.2 php7.2-cli  php7.2-dev php7.2-json \
                        php7.2-mysql php7.2-opcache php7.2-readline php7.2-redis php7.2-xml php7.2-mbstring \
                        php-pear pkg-config libbson-1.0 libmongoc-1.0-0 php-xml php-dev \
                        python3 python3-pip libjpeg-dev libxml2-dev libxslt1-dev zlib1g-dev  \
                        libfuzzy-dev cron logrotate supervisor syslog-ng-core && apt-get clean

RUN locale-gen en_US.UTF-8
ENV LANG en_US.UTF-8

# Fix php.ini with recommended settings
RUN sed -i "s/max_execution_time = 30/max_execution_time = 300/" /etc/php/7.2/apache2/php.ini && \
    sed -i "s/memory_limit = 128M/memory_limit = 512M/" /etc/php/7.2/apache2/php.ini &&  \
    sed -i "s/upload_max_filesize = 2M/upload_max_filesize = 50M/" /etc/php/7.2/apache2/php.ini && \
    sed -i "s/post_max_size = 8M/post_max_size = 50M/" /etc/php/7.2/apache2/php.ini

RUN pip3 install --upgrade setuptools pip

WORKDIR /var/www
RUN chown www-data:www-data /var/www
USER www-data
RUN git clone https://github.com/MISP/MISP.git
WORKDIR /var/www/MISP
RUN git config core.filemode false
RUN git submodule update --init --recursive && git submodule foreach --recursive git config core.filemode false
#RUN git checkout tags/$(git describe --tags `git rev-list --tags --max-count=1`)

WORKDIR /var/www/MISP/app/files/scripts
RUN git clone https://github.com/CybOXProject/python-cybox.git &&  git clone https://github.com/STIXProject/python-stix.git && git clone https://github.com/MAECProject/python-maec.git && git clone https://github.com/CybOXProject/mixbox.git

USER root

WORKDIR /var/www/MISP/app/files/scripts/mixbox
RUN python3 setup.py install

WORKDIR /var/www/MISP/app/files/scripts/python-maec
RUN python3 setup.py install

WORKDIR /var/www/MISP/app/files/scripts/python-cybox
#RUN git checkout v2.1.0.12
RUN python3 setup.py install

WORKDIR /var/www/MISP/app/files/scripts/python-stix
RUN python3 setup.py install

WORKDIR /var/www/MISP/cti-python-stix2
RUN python3 setup.py install

USER www-data
WORKDIR /var/www/MISP/app
RUN php composer.phar config vendor-dir Vendor && \
    php composer.phar install --ignore-platform-reqs && \
    cp -fa /var/www/MISP/INSTALL/setup/config.php /var/www/MISP/app/Plugin/CakeResque/Config/config.php

# Fix permissions
USER root
RUN chown -R www-data:www-data /var/www/MISP && \
    chmod -R 750 /var/www/MISP && \
    chmod -R g+ws /var/www/MISP/app/tmp && \
    chmod -R g+ws /var/www/MISP/app/files && \
    chmod -R g+ws /var/www/MISP/app/files/scripts/tmp

RUN cp /var/www/MISP/INSTALL/misp.logrotate /etc/logrotate.d/misp

# Preconfigure setting for packages
RUN echo "postfix postfix/main_mailer_type string Local only" | debconf-set-selections && \
    echo "postfix postfix/mailname string localhost.localdomain" | debconf-set-selections


# Install PEAR packages
#RUN pear install Crypt_GPG >>/tmp/install.log &&  pear install Net_GeoIP >>/tmp/install.log

# Apache Setup
RUN cp /var/www/MISP/INSTALL/apache.misp.ubuntu /etc/apache2/sites-available/misp.conf && \
        a2dissite 000-default && \
        a2ensite misp && a2enmod rewrite && \
        a2enmod headers && a2dismod status && a2dissite 000-default

# MISP base configuration

USER www-data
RUN cp -a /var/www/MISP/app/Config/bootstrap.default.php /var/www/MISP/app/Config/bootstrap.php && \
    cp -a /var/www/MISP/app/Config/database.default.php /var/www/MISP/app/Config/database.php && \
    cp -a /var/www/MISP/app/Config/core.default.php /var/www/MISP/app/Config/core.php && \
    cp -a /var/www/MISP/app/Config/config.default.php /var/www/MISP/app/Config/config.php && \
    chown -R www-data:www-data /var/www/MISP/app/Config && \
    chmod -R 750 /var/www/MISP/app/Config

USER root

# Replace the default salt
RUN sed -i -E "s/'salt'\s=>\s'(\S+)'/'salt' => '`openssl rand -base64 32|tr "/" "-"`'/" /var/www/MISP/app/Config/config.php

# Enable workers at boot time
RUN chmod a+x /var/www/MISP/app/Console/worker/start.sh && echo "sudo -u www-data bash /var/www/MISP/app/Console/worker/start.sh" >>/etc/rc.local

# Install MISP Modules
WORKDIR /opt
RUN git clone https://github.com/MISP/misp-modules.git
WORKDIR /opt/misp-modules
RUN pip3 install --upgrade --ignore-installed urllib3 requests setuptools && \
        pip3 install -I -r REQUIREMENTS && \
        pip3 install -I . && \
        pip3 install git+https://github.com/kbandla/pydeep.git \
                     https://github.com/lief-project/packages/raw/lief-master-latest/pylief-0.9.0.dev.zip \
                     python-magic
RUN echo "sudo -u www-data misp-modules -s -l 127.0.0.1 &" >>/etc/rc.local

# Enable php-redis and Install Crypt_GPG and Console_CommandLine
RUN phpenmod redis && \
    pear install /var/www/MISP/INSTALL/dependencies/Console_CommandLine/package.xml && \
    pear install /var/www/MISP/INSTALL/dependencies/Crypt_GPG/package.xml

# Supervisord Setup
COPY --chown=root:root supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Modify syslog configuration
RUN sed -i -E 's/^(\s*)system\(\);/\1unix-stream("\/dev\/log");/' /etc/syslog-ng/syslog-ng.conf

# Add run script
COPY --chown=root:root run.sh /run.sh
RUN chmod 0755 /run.sh

# Trigger to perform first boot operations
RUN touch /.firstboot.tmp

# Make a backup of /var/www/MISP to restore it to the local moint point at first boot
WORKDIR /var/www/MISP
RUN tar czpf /root/MISP.tgz .

VOLUME /var/www/MISP
EXPOSE 80
ENTRYPOINT ["/run.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
