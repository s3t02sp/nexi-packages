#!/usr/bin/env bash
# Собирает пакеты и публикует pacman-репозиторий [nexi] в GitHub Release.
#
# Запускается в контейнере archlinux:latest от root (см. .github/workflows).
# Окружение:
#   GH_TOKEN, GITHUB_REPOSITORY  — для gh release
#   NEXI_GPG_PRIVATE_KEY         — приватный ключ подписи (armored)
#   FORCE=1                      — пересобрать всё, даже без новых версий
set -euo pipefail

REPO=nexi
TAG=x86_64
ROOT_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
WORK="$ROOT_DIR/work"
OUT="$WORK/repo"
SRC="$WORK/src"
BUILD_USER=builder
FORCE="${FORCE:-0}"

msg()  { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m==> WARN:\e[0m %s\n' "$*" >&2; }
gh_r() { gh -R "$GITHUB_REPOSITORY" "$@"; }

[[ -n "${NEXI_GPG_PRIVATE_KEY:-}" ]] || { echo "NEXI_GPG_PRIVATE_KEY не задан" >&2; exit 1; }

# ── Окружение сборки ──
msg "Зависимости"
pacman -Syu --noconfirm --needed base-devel git github-cli

id "$BUILD_USER" &>/dev/null || useradd -m -s /bin/bash "$BUILD_USER"
echo "$BUILD_USER ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/90-builder
chmod 440 /etc/sudoers.d/90-builder
sed -i 's/^#\?MAKEFLAGS=.*/MAKEFLAGS="-j'"$(nproc)"'"/' /etc/makepkg.conf

# Ключ подписи репозитория (только у root, сборщик его не видит)
export GNUPGHOME="$WORK/gnupg"
rm -rf "$WORK"; mkdir -p "$GNUPGHOME" "$OUT" "$SRC"; chmod 700 "$GNUPGHOME"
printf '%s\n' "$NEXI_GPG_PRIVATE_KEY" | gpg --batch --quiet --import
FPR="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')"
[[ -n "$FPR" ]] || { echo "не удалось импортировать ключ" >&2; exit 1; }
msg "Ключ подписи: $FPR"

# ── Текущее состояние репозитория ──
if ! gh_r release view "$TAG" >/dev/null 2>&1; then
  msg "Создаю релиз $TAG"
  gh_r release create "$TAG" --title "Nexi Linux repository (x86_64)" --latest=false \
    --notes 'pacman-репозиторий. Не удаляйте этот релиз: его файлы — это и есть репозиторий [nexi].'
fi
( cd "$OUT" && gh_r release download "$TAG" -p "$REPO.db.tar.gz" -p "$REPO.files.tar.gz" 2>/dev/null ) \
  || msg "Репозиторий пуст — первая сборка"
(( FORCE )) && rm -f "$OUT/$REPO".{db,files}.tar.gz

# pkgname-ver, уже лежащие в репозитории
have_ver() {
  [[ -f "$OUT/$REPO.db.tar.gz" ]] && tar -tzf "$OUT/$REPO.db.tar.gz" | grep -qx "$1/"
}

# ── Исходники: локальные PKGBUILD + AUR ──
for d in "$ROOT_DIR"/pkgbuilds/*/; do cp -a "$d" "$SRC/"; done
while read -r p; do
  [[ -n "$p" ]] || continue
  git clone -q --depth 1 "https://aur.archlinux.org/$p.git" "$SRC/$p"
  [[ -f "$SRC/$p/PKGBUILD" ]] || { echo "AUR-пакет '$p' не найден" >&2; exit 1; }
done < <(grep -vE '^\s*(#|$)' "$ROOT_DIR/aur-packages.txt")

# Публичный ключ — в пакет nexi-keyring
gpg --export "$FPR" > "$SRC/nexi-keyring/nexi.gpg"
echo "$FPR:4:" > "$SRC/nexi-keyring/nexi-trusted"
chown -R "$BUILD_USER:" "$SRC"

as_builder() { sudo -u "$BUILD_USER" env HOME="/home/$BUILD_USER" "$@"; }

BUILT=()
for dir in "$SRC"/*/; do
  name="$(basename "$dir")"
  cd "$dir"
  info="$(as_builder makepkg --printsrcinfo)"
  ver="$(awk -F' = ' '$1~/^\tpkgver$/{v=$2} $1~/^\tpkgrel$/{r=$2} $1~/^\tepoch$/{e=$2":"} END{print e v "-" r}' <<<"$info")"
  mapfile -t names < <(awk -F' = ' '$1=="pkgname"{print $2}' <<<"$info")

  up_to_date=1
  for n in "${names[@]}"; do have_ver "$n-$ver" || up_to_date=0; done
  if (( up_to_date )); then
    msg "$name $ver — без изменений"
    continue
  fi

  msg "Сборка $name $ver"
  # PGP-ключи апстрима (validpgpkeys) для проверки исходников
  for k in $(awk -F' = ' '$1~/^\tvalidpgpkeys$/{print $2}' <<<"$info"); do
    as_builder gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$k" ||
    as_builder gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$k" ||
      warn "не удалось получить ключ $k"
  done
  as_builder env PKGDEST="$dir/out" makepkg --syncdeps --noconfirm --needed --clean --cleanbuild --force

  for f in "$dir"/out/*.pkg.tar.zst; do
    [[ "$f" == *-debug-* ]] && continue
    cp -f "$f" "$OUT/"
    gpg --batch --yes --detach-sign --no-armor -u "$FPR" "$OUT/$(basename "$f")"
    BUILT+=("$(basename "$f")")
  done
done
cd "$OUT"

if (( ${#BUILT[@]} == 0 )); then
  msg "Новых версий нет — репозиторий не меняется"
  exit 0
fi

msg "Обновление базы: ${BUILT[*]}"
repo-add -q -s -k "$FPR" "$REPO.db.tar.gz" "${BUILT[@]}"

# Ссылки nexi.db → nexi.db.tar.gz превращаем в обычные файлы для GitHub
for f in "$REPO.db" "$REPO.files" "$REPO.db.sig" "$REPO.files.sig"; do
  [[ -L "$f" ]] && cp --remove-destination "$(readlink -f "$f")" "$f"
done

UPLOAD=()
for f in "${BUILT[@]}"; do UPLOAD+=("$f" "$f.sig"); done
UPLOAD+=("$REPO".db{,.sig} "$REPO".db.tar.gz{,.sig} "$REPO".files{,.sig} "$REPO".files.tar.gz{,.sig})
msg "Загрузка в релиз $TAG"
gh_r release upload "$TAG" --clobber "${UPLOAD[@]}"

# Удаляем из релиза пакеты, которых больше нет в базе (старые версии)
mapfile -t KEEP < <(
  tar -xzOf "$REPO.db.tar.gz" --wildcards '*/desc' | awk '/^%FILENAME%$/{getline; print; print $0".sig"}'
  printf '%s\n' "$REPO".db{,.sig} "$REPO".db.tar.gz{,.sig} "$REPO".files{,.sig} "$REPO".files.tar.gz{,.sig}
)
gh_r release view "$TAG" --json assets -q '.assets[].name' | while read -r a; do
  printf '%s\n' "${KEEP[@]}" | grep -qxF "$a" || { msg "удаляю старый $a"; gh_r release delete-asset "$TAG" "$a" -y; }
done

msg "Готово. Репозиторий:"
tar -tzf "$REPO.db.tar.gz" | grep '/$' | sed 's|/$||;s|^|  |'
