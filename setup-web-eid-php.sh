#!/bin/bash
set -e

HOME_DIR="$HOME"
REPO_DIR="$HOME_DIR/web-eid-authtoken-validation-php"
APACHE_CONF="/etc/apache2/sites-available/web-eid-php.conf"

echo "=== Web eID PHP näiterakenduse paigaldus ==="
echo "Kodukataloog: $HOME_DIR"
echo ""

# --- KÕIK SUDO KÄSUD KORRAGA ---

# 1. Paketid
echo "--- [1/6] Paketid ---"
sudo apt update -q
sudo apt install -y apache2 libapache2-mod-php php-curl phpunit php-xml composer

# 2. Apache seadistamine
echo ""
echo "--- [2/6] Apache seadistamine ---"

if ! grep -q "web-eid-authtoken-validation-php" /etc/apache2/apache2.conf; then
  echo "
<Directory $REPO_DIR>
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>" | sudo tee -a /etc/apache2/apache2.conf > /dev/null
  echo "Directory blokk lisatud apache2.conf-i"
else
  echo "Directory blokk juba olemas"
fi

sudo cp /etc/apache2/sites-available/default-ssl.conf "$APACHE_CONF"
sudo sed -i "s|DocumentRoot /var/www/html|DocumentRoot $REPO_DIR/example/public|" "$APACHE_CONF"
echo "DocumentRoot seadistatud: $REPO_DIR/example/public"

sudo a2enmod ssl rewrite
sudo a2ensite web-eid-php.conf
chmod 755 "$HOME_DIR"

sudo -v  # uuenda sudo sessioon enne restarti
sudo service apache2 restart
echo "Apache taaskäivitatud"

# --- SUDO EI OLE ENAM VAJALIK ---

# 3. Repo kloonimine
echo ""
echo "--- [3/6] Repo kloonimine ---"
if [ -d "$REPO_DIR" ]; then
  echo "Repo juba olemas, uuendan..."
  git -C "$REPO_DIR" pull
else
  git clone https://github.com/web-eid/web-eid-authtoken-validation-php.git "$REPO_DIR"
fi

# 4. Composer
echo ""
echo "--- [4/6] Composer sõltuvused ---"
cd "$REPO_DIR/example"
composer update

# 5. Sertifikaadid
echo ""
echo "--- [5/6] Sertifikaadid ---"
mkdir -p "$REPO_DIR/example/certificates"
cd "$REPO_DIR/example/certificates"

wget -q -N https://c.sk.ee/esteid2018.der.crt
wget -q -N https://sk.ee/upload/files/TEST_of_ESTEID2018.der.crt
wget -q -N https://crt.eidpki.ee/ESTEID2025.crt -O ESTEID2025.der.crt
wget -q -N https://installer.id.ee/media/id2025/TestChain/TestESTEID2025.crt -O TestESTEID2025.der.crt
wget -q -N https://www.sk.ee/upload/files/TEST_of_KLASS3-SK_2016.der.crt
wget -q -N https://c.sk.ee/TEST_ORG_2021E.der.crt
wget -q -N https://c.sk.ee/TEST_ORG_2021R.der.crt
echo "Sertifikaadid allalaaditud: $(ls | wc -l) faili"

echo ""
echo "=== Paigaldus valmis ==="
echo "Ava brauseris: https://localhost"
echo "NB! Brauseris tuleb sertifikaadi hoiatus — see on ootuspärane, kinnita erand."
