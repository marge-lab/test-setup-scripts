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


# ── Live-logi monitooring eraldi terminaliaknas ────────────
# PHP-rakendus jookseb Apache all, seega tail-ime Apache access + error logi.
# Vajab sudo-d (Apache logid on root-omanduses) — kasutaja sisestab parooli
# uues aknas.
LOG_TAIL_HELPER="$HOME/.web-eid-php-log-tail.sh"
cat > "$LOG_TAIL_HELPER" <<'HELPER_EOF'
#!/bin/bash
G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'; N='\033[0m'
clear
echo -e "${G}================================================================${N}"
echo -e "${G}  WebEid PHP — LIVE LOGI (Apache)${N}"
echo -e "${G}================================================================${N}"
echo ""
echo -e "${Y}  Ava brauseris:${N}  https://localhost"
echo -e "${Y}  Logid:${N}          /var/log/apache2/access.log + error.log"
echo ""
echo -e "${B}  Iga päring (auth/sign/cert) ilmub allpool reaalajas.${N}"
echo -e "${B}  Ctrl+C või sulge aken kui lõpetad.${N}"
echo -e "${B}  NB: kui küsib sudo parooli, sisesta — Apache logid on root-omanduses.${N}"
echo ""
echo "----------------------------------------------------------------"
sudo tail -n 0 -f /var/log/apache2/access.log /var/log/apache2/error.log
HELPER_EOF
chmod +x "$LOG_TAIL_HELPER"

# Terminal-detektsioon
resolve_term_name() {
  local cmd path
  cmd=$(command -v "$1" 2>/dev/null) || return 1
  path=$(readlink -f "$cmd" 2>/dev/null || echo "$cmd")
  basename "$path"
}

opened_log=0
for term in x-terminal-emulator gnome-terminal ptyxis konsole xfce4-terminal alacritty kitty xterm kgx; do
  if command -v "$term" >/dev/null 2>&1; then
    real_term=$(resolve_term_name "$term" || echo "$term")
    case "$real_term" in
      gnome-terminal*|ptyxis*)
        "$term" -- "$LOG_TAIL_HELPER" >/dev/null 2>&1 &
        ;;
      kitty*)
        "$term" "$LOG_TAIL_HELPER" >/dev/null 2>&1 &
        ;;
      *)
        "$term" -e "$LOG_TAIL_HELPER" >/dev/null 2>&1 &
        ;;
    esac
    opened_log=1
    break
  fi
done

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                  PAIGALDUS VALMIS                              ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║                                                                ║"
echo "║  Ava brauseris:    https://localhost                           ║"
echo "║                                                                ║"
echo "║  NB! Brauseris tuleb sertifikaadi hoiatus — see on ootuspärane,║"
echo "║      kinnita erand ja jätka.                                   ║"
echo "║                                                                ║"
if [ "$opened_log" -eq 1 ]; then
  echo "║  Live logi:        AVATUD ERALDI TERMINALIAKNAS (Apache)       ║"
  echo "║                    NB! Aknas küsib sudo parooli                ║"
else
  echo "║  Live logi:        ei suutnud terminali avada                  ║"
  echo "║  Käivita käsitsi:  sudo tail -f /var/log/apache2/access.log    ║"
fi
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
