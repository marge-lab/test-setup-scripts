#!/usr/bin/env bash
# Seadistab VMware Shared Folderi Ubuntu VM-i poolel:
#   - paigaldab open-vm-tools + open-vm-tools-desktop kui pole
#   - puhastab eelmised kuhjunud /mnt/hgfs monteerimised
#   - lisab /etc/fstab rea püsivaks monteerimiseks
#   - monteerib jagamise
#   - loob sümbollingi ~/<nimi> -> /mnt/hgfs/<nimi>
#
# Eeldus: Windowsi hostis on VMware Settings -> Options -> Shared Folders
# seadistatud "Always enabled" ja jagatav kaust lisatud (Add... wizard).
#
# Kasutus:
#   ./setup-vmware-shared-folder.sh                 # tuvastab nime automaatselt
#   ./setup-vmware-shared-folder.sh SharedVM        # määra nimi käsitsi

set -uo pipefail

SHARE_NAME="${1:-}"
MOUNT_POINT="/mnt/hgfs"
FSTAB_LINE=".host:/ ${MOUNT_POINT} fuse.vmhgfs-fuse allow_other,defaults 0 0"

if ! command -v apt-get >/dev/null 2>&1; then
    echo "VIGA: see skript on mõeldud Ubuntu/Debian-põhiste süsteemide jaoks." >&2
    exit 1
fi

echo "==> 1/6  open-vm-tools paigaldus..."
need_install=0
for pkg in open-vm-tools open-vm-tools-desktop; do
    dpkg -s "$pkg" >/dev/null 2>&1 || need_install=1
done
if [ "$need_install" -eq 1 ]; then
    echo "    Paigaldan open-vm-tools + open-vm-tools-desktop..."
    sudo apt-get update
    sudo apt-get install -y open-vm-tools open-vm-tools-desktop
else
    echo "    Olemas."
fi

echo "==> 2/6  Mount point /mnt/hgfs..."
sudo mkdir -p "${MOUNT_POINT}"

echo "==> 3/6  Puhastan eelmised kuhjunud monteerimised..."
unmount_count=0
while mount | grep -qE "on ${MOUNT_POINT} type fuse\.vmhgfs-fuse"; do
    if sudo umount "${MOUNT_POINT}" 2>/dev/null; then
        unmount_count=$((unmount_count + 1))
    elif sudo umount -l "${MOUNT_POINT}" 2>/dev/null; then
        unmount_count=$((unmount_count + 1))
    else
        break
    fi
done
echo "    Eemaldatud ${unmount_count} kihti."

echo "==> 4/6  /etc/fstab rida..."
if grep -qE '^\s*\.host:/\s' /etc/fstab; then
    echo "    Juba olemas."
else
    echo "${FSTAB_LINE}" | sudo tee -a /etc/fstab >/dev/null
    echo "    Lisatud."
fi

echo "==> 5/6  Monteerin..."
sudo systemctl daemon-reload
if ! sudo mount -a; then
    echo "    mount -a viskas vea, proovin käsitsi..."
    sudo vmhgfs-fuse .host:/ "${MOUNT_POINT}" \
        -o allow_other -o "uid=$(id -u)" -o "gid=$(id -g)" || true
fi

echo
echo "    /mnt/hgfs sisu:"
ls -la "${MOUNT_POINT}" 2>/dev/null || true

echo "==> 6/6  Sümbollink..."
mapfile -t available_shares < <(find "${MOUNT_POINT}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)

if [ -z "${SHARE_NAME}" ]; then
    case "${#available_shares[@]}" in
        0)
            echo "    HOIATUS: /mnt/hgfs on tühi — host ei paku ühtegi jagamist."
            echo "    Kontrolli VMware Settings -> Shared Folders."
            exit 1
            ;;
        1)
            SHARE_NAME="${available_shares[0]}"
            echo "    Tuvastasin automaatselt: '${SHARE_NAME}'"
            ;;
        *)
            echo "    Mitu jagamist saadaval:"
            for s in "${available_shares[@]}"; do echo "      - ${s}"; done
            echo "    Käivita uuesti, valides ühe: $0 <nimi>"
            exit 1
            ;;
    esac
elif [ ! -d "${MOUNT_POINT}/${SHARE_NAME}" ]; then
    echo "    HOIATUS: ${MOUNT_POINT}/${SHARE_NAME} ei eksisteeri."
    if [ "${#available_shares[@]}" -gt 0 ]; then
        echo "    Olemasolevad jagamised:"
        for s in "${available_shares[@]}"; do echo "      - ${s}"; done
        echo "    Käivita: $0 ${available_shares[0]}"
    else
        echo "    /mnt/hgfs on tühi — kontrolli VMware Settings -> Shared Folders."
    fi
    exit 1
fi

SYMLINK_TARGET="${HOME}/${SHARE_NAME}"

# Eemalda vana ~/Shared link, kui see jäi eelmisest käivitusest järele
LEGACY_LINK="${HOME}/Shared"
if [ -L "${LEGACY_LINK}" ] && [ "${LEGACY_LINK}" != "${SYMLINK_TARGET}" ]; then
    legacy_target="$(readlink "${LEGACY_LINK}")"
    case "${legacy_target}" in
        "${MOUNT_POINT}"/*)
            echo "    Eemaldan vana ~/Shared lingi (-> ${legacy_target})"
            rm "${LEGACY_LINK}"
            ;;
    esac
fi

if [ -L "${SYMLINK_TARGET}" ]; then
    current_target="$(readlink "${SYMLINK_TARGET}")"
    if [ "${current_target}" = "${MOUNT_POINT}/${SHARE_NAME}" ]; then
        echo "    Olemas: ${SYMLINK_TARGET} -> ${current_target}"
    else
        echo "    Värskendan vale lingi (oli -> ${current_target})..."
        rm "${SYMLINK_TARGET}"
        ln -s "${MOUNT_POINT}/${SHARE_NAME}" "${SYMLINK_TARGET}"
    fi
elif [ -e "${SYMLINK_TARGET}" ]; then
    echo "    HOIATUS: ${SYMLINK_TARGET} on olemas, aga pole sümbollink — ei puutu."
else
    ln -s "${MOUNT_POINT}/${SHARE_NAME}" "${SYMLINK_TARGET}"
    echo "    Loodud: ${SYMLINK_TARGET} -> ${MOUNT_POINT}/${SHARE_NAME}"
fi

echo
echo "==> Kontroll: mount | grep hgfs"
mount | grep hgfs || true
echo
echo "Valmis. Faile saad jagada nii Windowsi kausta kui ka ~/${SHARE_NAME} kaudu."
