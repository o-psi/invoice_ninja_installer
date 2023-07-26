#!/bin/bash

# Configuration file path
config_file="config.txt"

# Check if this is a rerun and the configuration file exists
if [ -f "$config_file" ]; then
    echo "Configuration file found. Reusing saved configuration."
    source $config_file
else
    # Install MySQL client if not already installed
    if ! command -v mysql &> /dev/null
    then
        sudo apt update
        sudo apt install mysql-client -y
    fi

    # Install MySQL client if not already installed
    if ! command -v nginx &> /dev/null
    then
        sudo apt update
        sudo apt install nginx -y
    fi

    # Install unzip if not already installed
    if ! command -v unzip &> /dev/null
    then
        sudo apt update
        sudo apt install unzip -y
    fi

    # Install dialog if not already installed
    if ! command -v dialog &> /dev/null
    then
        sudo apt install dialog -y
    fi

    # Ask for necessary user inputs
    db_location=$(dialog --ascii-lines  --stdout --inputbox "Is the database server local or on a network? (local/network): " 0 0)
    domain=$(dialog --ascii-lines --stdout --inputbox "Please enter your domain (e.g., invoice.yourdomain.com): " 0 0)
    email=$(dialog --ascii-lines --stdout --inputbox "Please enter your email (for Let's Encrypt certificate): " 0 0)
    mysql_username=$(dialog --ascii-lines --stdout --inputbox "Please enter your desired MySQL username: " 0 0)
    mysql_password=$(dialog --ascii-lines --stdout --passwordbox "Please enter your desired MySQL password: " 0 0)

    # If the database server is on a network, ask for the network address and port
    if [ "$db_location" = "network" ]; then
        db_network_address=$(dialog --ascii-lines --stdout --inputbox "Please enter the network address of the database server: " 0 0)
        db_port=$(dialog --ascii-lines --stdout --inputbox "Please enter the port number of the database server: " 0 0)
    else
        db_network_address="localhost"
        db_port="3306"
    fi

    # Save the configuration to a file
    echo "db_location=$db_location" > $config_file
    echo "domain=$domain" >> $config_file
    echo "email=$email" >> $config_file
    echo "mysql_username=$mysql_username" >> $config_file
    echo "mysql_password=$mysql_password" >> $config_file
    echo "db_network_address=$db_network_address" >> $config_file
    echo "db_port=$db_port" >> $config_file
fi


# Step 1: Download InvoiceNinja Install Zip File on Ubuntu 22.04 Server
if [ "$rerun" != "y" ]; then
    wget https://github.com/invoiceninja/invoiceninja/releases/download/v5.4.9/invoiceninja.zip

    # Check if wget was successful
    if [ $? -ne 0 ]; then
        echo "Failed to download InvoiceNinja. Please check your internet connection and try again."
        exit 1
    fi

    # Extract the archive to the /var/www/ directory
    sudo mkdir -p /var/www/invoiceninja/
    sudo unzip invoiceninja.zip -d /var/www/invoiceninja/

    # Change the owner of this directory to www-data
    sudo chown www-data:www-data /var/www/invoiceninja/ -R

    # Change the permission of the storage directory
    sudo chmod 755 /var/www/invoiceninja/storage/ -R
fi

# Step 2: Create a Database and User in MariaDB
if [ "$db_location" = "local" ]; then
    sudo mysql -e "CREATE DATABASE invoiceninja; CREATE USER '$mysql_username'@'localhost' IDENTIFIED BY '$mysql_password'; GRANT ALL PRIVILEGES ON invoiceninja.* TO '$mysql_username'@'localhost'; FLUSH PRIVILEGES;"
elif [ "$db_location" = "network" ]; then
    sudo mysql -h $db_network_address -u $mysql_username -p$mysql_password -P $db_port -e "CREATE DATABASE invoiceninja; GRANT ALL PRIVILEGES ON invoiceninja.* TO '$mysql_username'@'$db_network_address'; FLUSH PRIVILEGES;"
fi


# Check if MySQL commands were successful
if [ $? -ne 0 ]; then
    echo "Failed to create database or user in MySQL. Please check your MySQL server and try again."
    echo 'sudo mysql -h $db_network_address -u $mysql_username -P $db_port -e "CREATE DATABASE invoiceninja; CREATE USER '$mysql_username'@'$db_network_address' IDENTIFIED BY '$mysql_password'; GRANT ALL PRIVILEGES ON invoiceninja.* TO '$mysql_username'@'$db_network_address'; FLUSH PRIVILEGES;"'
    exit 1
fi

# Step 3: Install PHP Modules
if [ "$rerun" != "y" ]; then
    sudo apt install software-properties-common -y
    sudo add-apt-repository ppa:ondrej/php -y
    sudo apt install php-imagick php8.0 php8.0-mysql php8.0-fpm php8.0-common php8.0-bcmath php8.0-gd php8.0-curl php8.0-zip php8.0-xml php8.0-mbstring php8.0-bz2 php8.0-intl php8.0-gmp -y

    # Check if PHP modules were installed successfully
    if [ $? -ne 0 ]; then
        echo "Failed to install PHP modules. Please check your apt sources and try again."
        exit 1
    fi
fi

# Step 4: Configure InvoiceNinja
cd /var/www/invoiceninja/
ls -l   # List files to check if .env.example exists
if [ "$rerun" != "y" ]; then
    echo "Copying .env.example to .env"
    sudo cp .env.example .env
    echo "Copy operation completed with exit code $?"
    ls -l .env  # Check if .env now exists
fi
# Edit the .env file as per your configuration
sudo sed -i "s/DB_HOST=.*/DB_HOST=$db_network_address/" .env
sudo sed -i "s/DB_PORT=.*/DB_PORT=$db_port/" .env
sudo sed -i "s/DB_DATABASE=.*/DB_DATABASE=invoiceninja/" .env
sudo sed -i "s/DB_USERNAME=.*/DB_USERNAME=$mysql_username/" .env
sudo sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$mysql_password/" .env
sudo sed -i "s/APP_URL=.*/APP_URL=http:\/\/$domain/" .env

# Generate a unique app key for your InvoiceNinja installation
sudo php8.0 /var/www/invoiceninja/artisan key:generate

# Migrate the database
sudo php8.0 /var/www/invoiceninja/artisan migrate:fresh --seed

# Step 5: Setting Up Nginx Web Server
# Create a invoiceninja.conf file in /etc/nginx/conf.d/ directory
if [ "$rerun" != "y" ]; then
    # Install composer and npm dependencies
    sudo composer install --no-dev -o
    sudo npm install    
    sudo npm run production
    sudo bash -c 'cat > /etc/nginx/conf.d/invoiceninja.conf << EOF
server {
    listen   80;
    listen   [::]:80;
    server_name '$domain';

    root /var/www/invoiceninja/public/;
    index index.php index.html index.htm;
    charset utf-8;
    client_max_body_size 20M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    if (!-e \$request_filename) {
       rewrite ^(.+)$ /index.php?q= last;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log  /var/log/nginx/invoiceninja.access.log;
    error_log   /var/log/nginx/invoiceninja.error.log;

    location ~ \\.php$ {
        fastcgi_split_path_info ^(.+\\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.0-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
    }

    location ~ /\\.ht {
        deny all;
    }

    sendfile off;
}
EOF'
fi

# Test Nginx configuration
sudo nginx -t

# Check if Nginx configuration test was successful
if [ $? -ne 0 ]; then
    echo "Nginx configuration test failed. Please check your Nginx configuration and try again."
    exit 1
fi

# Reload Nginx for the changes to take effect
sudo systemctl reload nginx

# Step 6: Enabling HTTPS
# Install the Certbot Nginx plugin
if [ "$rerun" != "y" ]; then
    sudo apt install python3-certbot-nginx -y
fi

# Obtain and install TLS certificate
sudo certbot --nginx --agree-tos --redirect --hsts --staple-ocsp --email $email -d $domain

# Check if Certbot was successful
if [ $? -ne 0 ]; then
    echo "Certbot failed to obtain and install a TLS certificate. Please check your domain and try again."
    exit 1
fi

# Configure the cron job
sudo crontab -l > mycron
echo "* * * * * cd /var/www/invoiceninja && php artisan schedule:run >> /dev/null 2>&1" >> mycron
sudo crontab mycron
rm mycron


# Generate a key for the application
sudo php artisan key:generate

# Run the database migrations
sudo php artisan migrate

# Restart the Nginx and PHP services
sudo systemctl restart nginx
sudo systemctl restart php8.1-fpm

sudo chown -R www-data:www-data /var/www/invoiceninja
sudo chmod -R 775 /var/www/invoiceninja
