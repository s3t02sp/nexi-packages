#!/usr/bin/env bash
# Собирает пакеты и публикует pacman-репозиторий [nexi] в GitHub Release.
#
# Запускается в контейнере archlinux:latest от root (см. .github/workflows).
# Окружение:
#   GH_TOKEN, GITHUB_REPOSITORY  — для gh release
#   NEXI_GPG_PRIVATE_KEY         — приватный ключ подписи (armored)
#   FORCE=1                      — пересобрать всё, даже без новых версий
#   DRY_RUN=1                    — только собрать (проверка в pull request):
#                                  без публикации, ключ подписи временный
set -euo pipefail

REPO=nexi
TAG=x86_64
ROOT_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
WORK="$ROOT_DIR/work"
OUT="$WORK/repo"
SRC="$WORK/src"
BUILD_USER=builder
FORCE="${FORCE:-0}"
DRY_RUN="${DRY_RUN:-0}"

msg()  { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m==> WARN:\e[0m %s\n' "$*" >&2; }
gh_r() { gh -R "$GITHUB_REPOSITORY" "$@"; }

if [[ -z "${NEXI_GPG_PRIVATE_KEY:-}" ]]; then
  (( DRY_RUN )) || { echo "NEXI_GPG_PRIVATE_KEY не задан" >&2; exit 1; }
fi

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
if [[ -n "${NEXI_GPG_PRIVATE_KEY:-}" ]]; then
  printf '%s\n' "$NEXI_GPG_PRIVATE_KEY" | gpg --batch --quiet --import
else
  msg "DRY_RUN: временный ключ подписи"
  gpg --batch --quiet --passphrase '' --quick-gen-key "nexi dry-run <dry-run@invalid>" ed25519 sign never
fi
FPR="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')"
[[ -n "$FPR" ]] || { echo "не удалось импортировать ключ" >&2; exit 1; }
msg "Ключ подписи: $FPR"

# ── Текущее состояние репозитория ──
if (( ! DRY_RUN )) && ! gh_r release view "$TAG" >/dev/null 2>&1; then
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

# ── Исходники: локальные PKGBUILD + AUR (с зависимостями из AUR) ──
for d in "$ROOT_DIR"/pkgbuilds/*/; do cp -a "$d" "$SRC/"; done
chown -R "$BUILD_USER:" "$SRC"
as_builder() { sudo -u "$BUILD_USER" env HOME="/home/$BUILD_USER" "$@"; }

# pacman сборочного контейнера видит уже опубликованный [nexi] и пакеты,
# собранные в этом запуске ([nexi-build]): пакеты могут зависеть друг от
# друга и от пакетов из AUR
LOCAL="$WORK/localrepo"; mkdir -p "$LOCAL"
repo-add -q "$LOCAL/nexi-build.db.tar.gz"
pacman-key --init >/dev/null 2>&1 || true
gpg --export "$FPR" | pacman-key --add - >/dev/null
pacman-key --lsign-key "$FPR" >/dev/null
if [[ -n "${GITHUB_REPOSITORY:-}" ]] && ! grep -q '^\[nexi\]' /etc/pacman.conf; then
  printf '\n[nexi]\nServer = https://github.com/%s/releases/download/%s\n' "$GITHUB_REPOSITORY" "$TAG" >> /etc/pacman.conf
fi
printf '\n[nexi-build]\nSigLevel = Optional TrustAll\nServer = file://%s\n' "$LOCAL" >> /etc/pacman.conf
if ! pacman -Sy; then
  warn "[nexi] недоступен — сборка без него"
  sed -i '/^\[nexi\]$/,+1d' /etc/pacman.conf
  pacman -Sy
fi

# Имена пакетов и provides всех исходников в $SRC
declare -A PROVIDED_BY=()
index_src() {
  local dir="$1" info n
  info="$(cd "$dir" && as_builder makepkg --printsrcinfo)"
  printf '%s\n' "$info" > "$dir/.SRCINFO.nexi"
  while read -r n; do
    [[ -n "$n" ]] && PROVIDED_BY["${n%%[<>=]*}"]="$(basename "$dir")"
  done < <(awk -F' = ' '$1=="pkgname"{print $2} $1~/^\tprovides$/{print $2}' <<<"$info")
}
deps_of() {  # depends + makedepends + checkdepends, без версий
  awk -F' = ' '$1~/^\t(depends|makedepends|checkdepends)$/{print $2}' "$1/.SRCINFO.nexi" \
    | sed 's/[<>=].*//' | sort -u
}
in_repos() { pacman -Sp --print-format '%n' "$1" >/dev/null 2>&1; }

add_aur() {
  local p="$1"
  [[ -d "$SRC/$p" ]] && return 0
  msg "AUR: $p"
  git clone -q --depth 1 "https://aur.archlinux.org/$p.git" "$SRC/$p" 2>/dev/null || true
  if [[ ! -f "$SRC/$p/PKGBUILD" ]]; then rm -rf "${SRC:?}/$p"; return 1; fi
  chown -R "$BUILD_USER:" "$SRC/$p"
  index_src "$SRC/$p"
}

# Публичный ключ — в пакет nexi-keyring
gpg --export "$FPR" > "$SRC/nexi-keyring/nexi.gpg"
echo "$FPR:4:" > "$SRC/nexi-keyring/nexi-trusted"
chown -R "$BUILD_USER:" "$SRC"
for d in "$SRC"/*/; do index_src "${d%/}"; done

while read -r p; do
  [[ -n "$p" ]] || continue
  add_aur "$p" || { echo "AUR-пакет '$p' не найден" >&2; exit 1; }
done < <(grep -vE '^\s*(#|$)' "$ROOT_DIR/aur-packages.txt")

# Зависимости, которых нет ни в официальных репозиториях, ни в $SRC, — из AUR
# (транзитивно)
changed=1
while (( changed )); do
  changed=0
  for d in "$SRC"/*/; do
    while read -r dep; do
      [[ -n "$dep" && -z "${PROVIDED_BY[$dep]:-}" ]] || continue
      in_repos "$dep" && continue
      if add_aur "$dep"; then changed=1
      else warn "зависимость '$dep' ($(basename "$d")) не найдена ни в репозиториях, ни в AUR"
      fi
    done < <(deps_of "${d%/}")
  done
done

BUILT=()
declare -A DONE=()
# Готов к сборке, если все его зависимости из $SRC уже обработаны
# (или уже есть в [nexi] / [nexi-build])
ready() {
  local dir="$1" dep owner
  while read -r dep; do
    [[ -n "$dep" ]] || continue
    owner="${PROVIDED_BY[$dep]:-}"
    [[ -z "$owner" || "$owner" == "$(basename "$dir")" || -n "${DONE[$owner]:-}" ]] && continue
    in_repos "$dep" && continue
    return 1
  done < <(deps_of "$dir")
}

build_one() {
  local dir="$1" name info ver n up_to_date=1 f k
  name="$(basename "$dir")"
  info="$(cat "$dir/.SRCINFO.nexi")"
  ver="$(awk -F' = ' '$1~/^\tpkgver$/{v=$2} $1~/^\tpkgrel$/{r=$2} $1~/^\tepoch$/{e=$2":"} END{print e v "-" r}' <<<"$info")"
  mapfile -t names < <(awk -F' = ' '$1=="pkgname"{print $2}' <<<"$info")
  for n in "${names[@]}"; do have_ver "$n-$ver" || up_to_date=0; done
  if (( up_to_date )); then
    msg "$name $ver — без изменений"
    return 0
  fi
  msg "Сборка $name $ver"
  cd "$dir"
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
    cp -f "$f" "$LOCAL/"
    gpg --batch --yes --detach-sign --no-armor -u "$FPR" "$OUT/$(basename "$f")"
    BUILT+=("$(basename "$f")")
    repo-add -q "$LOCAL/nexi-build.db.tar.gz" "$LOCAL/$(basename "$f")"
  done
  pacman -Sy >/dev/null
}

mapfile -t TODO < <(for d in "$SRC"/*/; do basename "$d"; done)
while (( ${#TODO[@]} )); do
  progress=0; rest=()
  for name in "${TODO[@]}"; do
    if ready "$SRC/$name"; then
      build_one "$SRC/$name"; DONE[$name]=1; progress=1
    else
      rest+=("$name")
    fi
  done
  TODO=("${rest[@]}")
  if (( ! progress )); then
    warn "не удалось упорядочить сборку (цикл или ненайденные зависимости): ${TODO[*]}"
    for name in "${TODO[@]}"; do build_one "$SRC/$name"; DONE[$name]=1; done
    TODO=()
  fi
done

cd "$OUT"

if (( ${#BUILT[@]} == 0 )); then
  msg "Новых версий нет — репозиторий не меняется"
  exit 0
fi

if (( DRY_RUN )); then
  msg "DRY_RUN: собрано ${#BUILT[@]} пакетов, публикация пропущена:"
  printf '  %s\n' "${BUILT[@]}"
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
