#!/bin/bash
#
# Snipe-IT Installation Script for WSL/Ubuntu
# Based on official Snipe-IT installer
# Modified to use forked repository
#

# ensure running as root
if [ "$(id -u)" != "0" ]; then
    if ! hash sudo 2>/dev/null; then
        exec su -c "$0" "$@"
    else
        exec sudo "$0" "$@"
    fi
fi

# Configuration
readonly APP_USER="snipeitapp"
readonly APP_NAME="snipeit"
readonly APP_PATH="/var/www/html/$APP_NAME"
readonly APP_LOG="/var/log/snipeit-install.log"
readonly COMPOSER_PATH="/home/$APP_USER"
readonly GIT_REPO="https://github.com/Blessed-Shammah/asset-management-system.git"

# Detect OS
if [[ -f /etc/lsb-release ]]; then
    distro="$(lsb_release -is)"
    version="$(lsb_release -rs)"
    codename="$(lsb_release -cs)"
else
    echo "Unsupported OS. This script requires Ubuntu/Debian."
    exit 1
fi

echo '
          ___    __  ___    ____   ___    _   __ ____  
         /   |  /  |/  /   / __ ) /   |  / | / // __ \ 
        / /| | / /|_/ /   / __  |/ /| | /  |/ // / / / 
       / ___ |/ /  / /   / /_/ // ___ |/ /|  // /_/ /  
      /_/  |_/_/  /_/   /_____//_/  |_/_/ |_//_____/   
                                                       
'

echo ""
echo "  Snipe-IT Installer for WSL/Ubuntu"
echo "  Installation log: $APP_LOG"
echo ""
echo "  Detected: $distro $version ($codename)"
echo ""

# Set variables
apache_group=www-data
apachefile=/etc/apache2/sites-available/$APP_NAME.conf

# Logging function
log () {
    eval "$@" |& tee -a "$APP_LOG" >/dev/null 2>&1
}

# Package installation function
install_packages () {
    for p in $PACKAGES; do
        if dpkg -s "$p" >/dev/null 2>&1; then
            echo "  * $p already installed"
        else
            echo "  * Installing $p"
            log "DEBIAN_FRONTEND=noninteractive apt-get install -y $p"
        fi
    done
}

# Virtual host creation
create_virtualhost () {
    {
        echo "<VirtualHost *:80>"
        echo "  <Directory $APP_PATH/public>"
        echo "      Allow From All"
        echo "      AllowOverride All"
        echo "      Options -Indexes"
        echo "  </Directory>"
        echo ""
        echo "  DocumentRoot $APP_PATH/public"
        echo "  ServerName $fqdn"
        echo "</VirtualHost>"
    } > "$apachefile"
}

# User creation
create_user () {
    echo "* Creating Snipe-IT user."
    /usr/sbin/adduser --quiet --disabled-password --gecos 'Snipe-IT User' "$APP_USER"
    usermod -a -G "$apache_group" "$APP_USER"
    usermod -a -G "$APP_USER" "$apache_group"
}

# Run command as app user
run_as_app_user () {
    if ! hash sudo 2>/dev/null; then
        su - "$APP_USER" -c "$@"
    else
        sudo -i -u "$APP_USER" "$@"
    fi
}

# Composer installation
install_composer () {
    echo "* Installing composer."
    EXPECTED_SIGNATURE="$(wget -q -O - https://composer.github.io/installer.sig)"
    run_as_app_user php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_SIGNATURE="$(run_as_app_user php -r "echo hash_file('SHA384', 'composer-setup.php');")"

    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
        >&2 echo 'ERROR: Invalid composer installer signature'
        exit 1
    fi

    run_as_app_user php composer-setup.php
    run_as_app_user rm composer-setup.php
    mv "$(eval echo ~$APP_USER)"/composer.phar /usr/local/bin/composer
}

# Main Snipe-IT installation
install_snipeit () {
    create_user
    
    echo "* Creating MariaDB Database/User."
    mysql -u root --execute="CREATE DATABASE IF NOT EXISTS snipeit;"
    mysql -u root --execute="CREATE USER IF NOT EXISTS snipeit_dbuser@localhost IDENTIFIED BY '$mysqluserpw';"
    mysql -u root --execute="GRANT ALL PRIVILEGES ON snipeit.* TO snipeit_dbuser@localhost;"
    mysql -u root --execute="FLUSH PRIVILEGES;"

    echo "* Cloning Snipe-IT from your forked repository."
    log "git clone $GIT_REPO $APP_PATH"
    pushd "$APP_PATH" >/dev/null
    git checkout master
    popd >/dev/null

    echo "* Configuring .env file."
    cp "$APP_PATH/.env.example" "$APP_PATH/.env"

    sed -i '1 i\#Created By Snipe-it Installer' "$APP_PATH/.env"
    sed -i "s|^\\(APP_TIMEZONE=\\).*|\\1$tzone|" "$APP_PATH/.env"
    sed -i "s|^\\(DB_HOST=\\).*|\\1localhost|" "$APP_PATH/.env"
    sed -i "s|^\\(DB_DATABASE=\\).*|\\1snipeit|" "$APP_PATH/.env"
    sed -i "s|^\\(DB_USERNAME=\\).*|\\1snipeit_dbuser|" "$APP_PATH/.env"
    sed -i "s|^\\(DB_PASSWORD=\\).*|\\1'$mysqluserpw'|" "$APP_PATH/.env"
    sed -i "s|^\\(APP_URL=\\).*|\\1http://$fqdn|" "$APP_PATH/.env"

    install_composer

    echo "* Setting permissions."
    for chmod_dir in "$APP_PATH/storage" "$APP_PATH/public/uploads" "$APP_PATH/bootstrap/cache"; do
        chmod -R 775 "$chmod_dir"
    done

    chown -R "$APP_USER":"$apache_group" "$APP_PATH"

    echo "* Running composer install."
    run_as_app_user /usr/local/bin/composer install --no-dev --prefer-source --working-dir "$APP_PATH"

    chgrp -R "$apache_group" "$APP_PATH/vendor"

    echo "* Generating the application key."
    log "php $APP_PATH/artisan key:generate --force"

    echo "* Running database migrations."
    log "php $APP_PATH/artisan migrate --force"

    echo "* Creating scheduler cron."
    (echo "* * * * * /usr/bin/php $APP_PATH/artisan schedule:run >> /dev/null 2>&1") | run_as_app_user crontab -
}

# Get user input
set_fqdn () {
    echo -n "  Q. What is the FQDN of your server? (localhost): "
    read -r fqdn
    if [ -z "$fqdn" ]; then
        readonly fqdn="localhost"
    fi
    echo "     Setting to $fqdn"
    echo ""
}

set_dbpass () {
    ans=default
    until [[ $ans == "yes" ]] || [[ $ans == "no" ]]; do
        echo -n "  Q. Do you want to automatically create the database user password? (y/n) "
        read -r setpw

        case $setpw in
            [yY] | [yY][Ee][Ss] )
                mysqluserpw="$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c16; echo)"
                echo ""
                ans="yes"
                ;;
            [nN] | [n|N][O|o] )
                echo -n "  Q. What do you want your snipeit user password to be? "
                read -rs mysqluserpw
                echo ""
                ans="no"
                ;;
            *)  echo "  Invalid answer. Please type y or n"
                ;;
        esac
    done
}

# Main installation logic for Ubuntu
case $distro in
    Ubuntu)
        if [ "${version//./}" -ge "2004" ]; then
            set_fqdn
            set_dbpass
            tzone=$(cat /etc/timezone)

            echo "* Updating packages."
            log "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade"

            echo "* Installing required packages."
            if [ "${version//./}" -ge "2304" ]; then
                # Ubuntu 23.04+ uses default PHP version
                PACKAGES="cron mariadb-server mariadb-client apache2 libapache2-mod-php php php-curl php-mysql php-gd php-ldap php-zip php-mbstring php-xml php-bcmath curl git unzip wget"
            else
                # Ubuntu 20.04-22.04 needs specific PHP version
                echo "* Adding Ondrej PHP repository."
                echo "deb http://ppa.launchpad.net/ondrej/php/ubuntu $codename main" >> /etc/apt/sources.list.d/ppa_ondrej_php_$codename.list
                apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 4F4EA0AAE5267A6C
                log "apt-get update"
                
                PACKAGES="cron mariadb-server mariadb-client apache2 libapache2-mod-php8.2 php8.2 php8.2-curl php8.2-mysql php8.2-gd php8.2-ldap php8.2-zip php8.2-mbstring php8.2-xml php8.2-bcmath curl git unzip"
            fi
            
            install_packages

            echo "* Configuring Apache."
            create_virtualhost
            log "a2enmod rewrite"
            log "a2ensite $APP_NAME.conf"
            log "a2dissite 000-default"

            echo "* Starting MariaDB."
            log "systemctl start mariadb.service"
            log "systemctl enable mariadb.service"

            install_snipeit

            echo "* Restarting Apache."
            log "systemctl restart apache2"

            echo "* Setting final permissions."
            chmod 777 -R "$APP_PATH/storage/framework/cache/"
            log "run_as_app_user php $APP_PATH/artisan cache:clear"
            chmod 775 -R "$APP_PATH/storage/"

        else
            echo "Unsupported Ubuntu version. Minimum required: 20.04"
            exit 1
        fi
        ;;
    *)
        echo "This script only supports Ubuntu. Detected: $distro"
        exit 1
        ;;
esac

echo ""
echo "✅ INSTALLATION COMPLETE!"
echo ""
echo "🌐 Open http://$fqdn to access Snipe-IT"
echo ""
echo "📋 Default login credentials:"
echo "   Username: admin"
echo "   Password: password"
echo ""
echo "⚠️  IMPORTANT: Change the default password immediately!"
echo "📁 App location: $APP_PATH"
echo "📋 Database password: $mysqluserpw"
echo "📄 Installation log: $APP_LOG"
echo ""