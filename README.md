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
