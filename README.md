# nexi-packages

Pacman-репозиторий **[nexi]** для Nexi Linux. Пакеты собираются в GitHub Actions,
подписываются ключом репозитория и публикуются в релизе
[`x86_64`](../../releases/tag/x86_64).

| Пакет | Откуда |
|---|---|
| `calamares` | `pkgbuilds/calamares` (Python-модули и packagechooser включены) |
| `nexi-keyring` | `pkgbuilds/nexi-keyring` — ключ подписи репозитория |
| `nexi-branding` | `pkgbuilds/nexi-branding` — логотипы и оформление |
| `helium-browser-bin` | AUR |
| `ckbcomp` | AUR |
| `yay-bin`, `paru-bin` | AUR |
| `nexi-hyprland-dots` | `pkgbuilds/nexi-hyprland-dots` — оформление Hyprland по умолчанию: dotfiles end-4 (illogical-impulse) из форка [s3t02sp/dots-hyprland](https://github.com/s3t02sp/dots-hyprland) на закреплённом коммите |
| `illogical-impulse-*` | `pkgbuilds/illogical-impulse-*` — зависимости end-4 (из `sdata/dist-arch` форка); Quickshell и MicroTeX на закреплённых коммитах |
| зависимости из AUR | находятся и собираются автоматически |

### Оформление Hyprland (end-4)

Обновления автора end-4 сами **не приходят**: пакет собирается из форка на
коммите `_commit` в `pkgbuilds/nexi-hyprland-dots/PKGBUILD`. Чтобы обновиться:
синхронизировать форк (*Sync fork* на GitHub), проверить, поменять `_commit`
и `pkgver`, при необходимости обновить `pkgbuilds/illogical-impulse-*` из
`sdata/dist-arch` форка.

Quickshell использует закрытый API Qt, поэтому версия Qt входит в его
`pkgver`: после обновления `qt6-base` в Arch ежедневная сборка пересобирает его.

Зависимости из AUR не нужно перечислять в `aur-packages.txt`: сборщик сам
находит зависимости, которых нет в официальных репозиториях, клонирует их из
AUR (транзитивно) и собирает в нужном порядке.

Pull request собирается без публикации (`DRY_RUN=1`) — проверка, что пакеты
собираются.

Сборка запускается при пуше в `main`, вручную (*Run workflow*, можно с
«Пересобрать все пакеты») и каждый день. Пакет пересобирается только когда
меняется его версия, поэтому новые версии из AUR (например, Helium)
появляются в репозитории в течение суток.

## Подключение

```ini
[nexi]
Server = https://github.com/s3t02sp/nexi-packages/releases/download/x86_64
```

Ключ: поставьте `nexi-keyring` (в Nexi Linux он стоит по умолчанию) или вручную:

```bash
curl -sL https://raw.githubusercontent.com/s3t02sp/nexi-packages/main/keys/nexi.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key 4CCC3150E2C6B3ACA46B1462CB2BAF3EDD4B05F9
```

## Добавить пакет

* из AUR — строка в `aur-packages.txt`;
* свой — каталог `pkgbuilds/<имя>/` с `PKGBUILD`.

Секрет `NEXI_GPG_PRIVATE_KEY` (Settings → Secrets → Actions) — приватный ключ
подписи. Публичная часть лежит в `keys/`.
