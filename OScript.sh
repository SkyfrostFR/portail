#!/bin/bash

# --- Configuration initiale du script d'installation ---
set -e          # Quitte le script si une commande échoue [11]
set -o pipefail # Quitte si une commande dans un pipeline échoue [12]

# Variables pour l'utilisateur de streaming
STREAM_USER="streamuser"
CONFIG_DIR="/etc/moonlight-os"
CONFIG_FILE="$CONFIG_DIR/config.conf"
FIRST_RUN_FLAG="/home/$STREAM_USER/.moonlight_first_run_complete"
MOONLIGHT_BOOT_SCRIPT="/usr/local/bin/moonlight-boot-script.sh"
WOL_SCRIPT_SOURCE="fbx_wol.sh"
WOL_SCRIPT_TARGET="/usr/local/bin/fbx_wol.sh"
MOONLIGHT_SERVICE="moonlight-boot.service"
XORG_SERVICE="xorg.service"
MOONLIGHT_XINITRC="/home/$STREAM_USER/.xinitrc"
STREAM_USER_PROFILE="/home/$STREAM_USER/.bash_profile" # Utiliser.bash_profile pour les shells de connexion [13]
PING_COUNT=2                            # Nombre de ping à envoyer


# Définition des codes de couleur ANSI
RED="\033[1;31m"
YELLOW="\033[1;33m"
GREEN="\033[1;32m"
RESET="\033[0m"

# Fonctions de log
log_info() {
    echo -e "${GREEN}$1${RESET}"
}

log_warn() {
    echo -e "${YELLOW}$1${RESET}" >&2
}

log_error() {
    echo -e "${RED}$1${RESET}" >&2
    exit 1
}

# Fonction pour exécuter une commande et vérifier son succès
run_command() {
    local cmd="$@"
    log_info "Exécution : $cmd"
    eval "$cmd"
    local exit_status=$?
    if [ $exit_status -ne 0 ]; then
        log_error "La commande '$cmd' a échoué avec le code de sortie : $exit_status."
    fi
}

# Fonction pour afficher une boîte de dialogue d'information
dialog_info() {
    dialog --title "Information" --msgbox "\$1" 8 60 2>/dev/tty
    if [ $? -ne 0 ]; then
        log_error "Boîte de dialogue annulée. Sortie du script."
    fi
}

# Fonction pour afficher une boîte de dialogue oui/non
dialog_yesno() {
    dialog --title "\$1" --yesno "\$2" 10 60 2>/dev/tty
    return $?
}

# --- Vérifications préliminaires ---

# Vérifier si le script est exécuté en tant que root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Ce script doit être exécuté en tant que root. Utilisez : sudo bash $(basename "\$0")"
fi


sudo cp $WOL_SCRIPT_SOURCE $WOL_SCRIPT_TARGET
sudo chmod +x $WOL_SCRIPT_TARGET

# Détection de l'OS (doit être Arch Linux)
if ! test -f "/etc/arch-release"; then
    if [ -f "/etc/os-release" ]; then
        . /etc/os-release
        if [ "$ID" != "arch" ]; then
            log_error "Ce script est conçu uniquement pour Arch Linux. Votre système n'est pas Arch Linux (ID='$ID')."
        fi
    else
        log_error "Impossible de détecter la distribution Linux. Le fichier /etc/arch-release ou /etc/os-release est manquant."
    fi
fi

# Définir le chemin du fichier de configuration
OS_CONFIG_FILE="$(dirname "$(readlink -f "\$0")")/os.config"

# Vérifier et charger le fichier de configuration
if ! test -f "$OS_CONFIG_FILE"; then
    log_error "Fichier de configuration '$OS_CONFIG_FILE' introuvable. Veuillez le créer."
fi

log_info "Chargement de la configuration depuis '$OS_CONFIG_FILE'."
source "$OS_CONFIG_FILE"

run_command "mkdir -p $CONFIG_DIR"
run_command "cp \"$OS_CONFIG_FILE\" \"$CONFIG_FILE\""
run_command "chmod 644 \"$CONFIG_FILE\""

# Valider les variables critiques
if [ -z "$HOST_IP" ] || [ -z "$WG_PRIVATE_KEY" ] || \
   [ -z "$WG_PUBLIC_KEY_SERVER" ] || [ -z "$WG_ENDPOINT" ] || \
   [ -z "$WG_CLIENT_IP" ] || [ -z "$HOST_MAC" ] || [ -z "$OS_USER_PASSWORD" ] || [ -z "$HOST_MAC" ] || [ -z "$FREEBOX_IP" ]; then
    log_error "Certaines informations critiques sont manquantes dans le fichier de configuration. Assurez-vous que toutes les variables WG_ sont définies."
fi

log_info "Début de l'installation de l'OS de streaming Moonlight sur Arch Linux."

# --- 1. Création de l'utilisateur dédié au streaming ---
log_info "1. Création de l'utilisateur '$STREAM_USER'."
if id "$STREAM_USER" &>/dev/null; then
    log_warn "L'utilisateur '$STREAM_USER' existe déjà. Ignoré."
else
    USER_PASS="$OS_USER_PASSWORD"
    run_command "useradd -m -G wheel -s /bin/bash \"$STREAM_USER\""
    echo "$STREAM_USER:$USER_PASS" | run_command "chpasswd"
    run_command "echo \"$STREAM_USER ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/99_moonlight_user"
    run_command "chmod 0440 /etc/sudoers.d/99_moonlight_user"
fi

# --- 2. Installation des paquets nécessaires ---
log_info "2. Installation des paquets système et de streaming."
PACKAGES_TO_INSTALL="linux linux-headers openresolv xorg-server xorg-xinit moonlight-qt curl jq openssl wireguard-tools wol dialog networkmanager openbox ethtool iputils fontconfig ttf-liberation noto-fonts network-manager-applet"

dialog_yesno "Installation VirtualBox Guest Additions" "Êtes-vous en train d'installer cet OS dans VirtualBox?" && PACKAGES_TO_INSTALL+=" virtualbox-guest-utils"

run_command "pacman -Syu --noconfirm $PACKAGES_TO_INSTALL"
run_command "systemctl enable NetworkManager.service"
run_command "systemctl enable NetworkManager-wait-online.service"

# --- 3. Configuration du VPN WireGuard ---
log_info "3. Configuration du VPN WireGuard."

# Créer le répertoire WireGuard si absent
run_command "mkdir -p /etc/wireguard"

# Créer le fichier de configuration wg0.conf
cat <<EOF_WG > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $WG_PRIVATE_KEY
Address = $WG_CLIENT_IP # Assumer un masque de sous-réseau /24 pour l'adresse IP du client. Ajustez si nécessaire.
DNS = 212.27.38.253 # Exemple de serveur DNS public. Remplacez si votre fournisseur VPN en spécifie un autre.
MTU = 1360

[Peer]
PublicKey = $WG_PUBLIC_KEY_SERVER
Endpoint = $WG_ENDPOINT
AllowedIPs = 0.0.0.0/0, 192.168.27.64/27, 192.168.1.0/24
EOF_WG

# Définir les permissions pour le fichier wg0.conf (seulement root peut lire/écrire)
run_command "chmod 644 /etc/wireguard/wg0.conf"

# Note: Le service wg-quick@wg0.service sera activé et démarré par le MOONLIGHT_BOOT_SCRIPT.

# --- 4. Configuration de l'autologin et du démarrage Xorg/Moonlight ---
log_info "4. Configuration de l'autologin et du démarrage Xorg/Moonlight."

run_command "mkdir -p /etc/systemd/system/getty@tty1.service.d/"

cat <<EOF > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $STREAM_USER --noclear %I 38400 linux
EOF

run_command "loginctl enable-linger \"$STREAM_USER\""

MOON_CONFIG_FILE="/home/streamuser/.config/Moonlight Game Streaming Project/Moonlight.conf"
cat <<EOF > "$MOONLIGHT_XINITRC"
#!/bin/sh
HOST_UP=false
ping -c 1 -W 1 google.com && HOST_UP=true

if [ \$HOST_UP = false ]; then
     echo "Aucune connexion détectée. Lancement de l'interface graphique de configuration réseau..."
     
     export DISPLAY=:0
     export XAUTHORITY=/home/$STREAM_USER/.Xauthority

    nm-connection-editor

    # Attendre que l’utilisateur configure le réseau
    echo "En attente de connexion réseau. Fermez la fenêtre après connexion..."
     while ! ping -c 1 -W 1 9.9.9.9 >/dev/null 2>&1; do
        sleep 2
    done

    echo "Connexion réseau détectée. Poursuite du démarrage..."
fi

$MOONLIGHT_BOOT_SCRIPT

if !(grep -q "BEGIN CERTIFICATE" "$MOON_CONFIG_FILE" && grep -q "BEGIN PRIVATE KEY" "$MOON_CONFIG_FILE"); then
/usr/bin/moonlight pair $HOST_IP
fi

/usr/bin/moonlight stream $HOST_IP "desktop" --display-mode fullscreen

EOF

run_command "chown \"$STREAM_USER\":\"$STREAM_USER\" \"$MOONLIGHT_XINITRC\""
run_command "chmod +x \"$MOONLIGHT_XINITRC\""

run_command "chown \"$STREAM_USER\":\"$STREAM_USER\" \"$STREAM_USER_PROFILE\""

# --- 5. Création du script de démarrage principal ---
log_info "5. Création du script de démarrage principal."

cat <<EOF > "$MOONLIGHT_BOOT_SCRIPT"
#!/bin/bash

set -e
set -o pipefail

FIRST_RUN_FLAG="$FIRST_RUN_FLAG"
HOST_UP=false
echo "start"
sudo resolvconf -u
source "$CONFIG_FILE"
echo "loaded"


WG_INTERFACE="wg0"
sudo resolvconf -u
sudo systemctl start wg-quick@wg0.service


if
   ip addr show "\$WG_INTERFACE" | grep -q "inet " && \
   ping -c 1 google.com >/dev/null 2>&1; then

    echo "✅ WireGuard (\$WG_INTERFACE) est actif"
    echo "ping -c 1 -W 1 $HOST_IP"

else
    echo "❌ WireGuard (\$WG_INTERFACE) est inactif"
fi

if ping -c $PING_COUNT $HOST_IP > /dev/null 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') : $HOST_IP est joignable. Lancement du stream"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') : $HOST_IP est ingoignalbe . Lancement du WAKE UP ON LAN"
    $WOL_SCRIPT_TARGET "$FREEBOX_IP" "$HOST_MAC"
fi

EOF

run_command "chown \"$STREAM_USER\":\"$STREAM_USER\" \"$MOONLIGHT_BOOT_SCRIPT\""
run_command "chmod +x \"$MOONLIGHT_BOOT_SCRIPT\""

# --- 6. Création du service Systemd ---
log_info "6. Création du service Systemd."

cat <<EOF > /etc/systemd/system/"$MOONLIGHT_SERVICE"
[Unit]
Description=Moonlight Streaming OS Boot Script
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$MOONLIGHT_BOOT_SCRIPT
User=$STREAM_USER
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF


cat <<EOF > /etc/systemd/system/"$XORG_SERVICE"
# /etc/systemd/system/xorg.service
[Unit]
Description=Start Xorg
After=systemd-user-sessions.service
Conflicts=getty@tty1.service

[Service]
User=streamuser
PAMName=login
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty
StandardOutput=tty
StandardError=tty
ExecStart=/usr/bin/startx


[Install]
WantedBy=multi-user.target
EOF



run_command "systemctl daemon-reload"
run_command "systemctl enable \"$XORG_SERVICE\""


run_command "systemctl enable NetworkManager.service"
run_command "systemctl daemon-reload"


# --- 7. Finalisation ---
log_info "7. Finalisation de l'installation."
log_info "Installation complète. Vous pouvez redémarrer la machine."
log_info "Utilisez 'sudo reboot' pour redémarrer maintenant."
log_info "Consultez les journaux avec : journalctl -u $MOONLIGHT_SERVICE"
