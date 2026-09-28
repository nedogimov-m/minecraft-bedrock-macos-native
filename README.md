# Minecraft Bedrock: нативная клавиатура и мышь на macOS

Исходники исправлений для Minecraft Bedrock на Mac с Apple Silicon. Проверено на Minecraft 1.26.51 и Xcode 27. PlayCover нужен для получения собственной установленной копии игры и её настроек; после сборки запускается отдельная `Minecraft Direct.app`, без запущенного PlayCover. Внутри копии остаётся модифицированный PlayTools.

Что входит:

- `NativeInput/MinecraftNativeInput.m` передаёт игре события `GCKeyboard` и `GCMouse` как подключённые устройства. Ввод действует при фокусе игрового окна и курсоре внутри него; при выходе курсора на игровом экране вызывается пауза. Также код восстанавливает захват указателя после закрытия меню, оставляет ввод текста в чате, подавляет системный писк от повторных клавиш и останавливает рекурсивный `SIGABRT` при закрытии.
- `patches/playtools-minecraft.patch` даёт игре нативный pointer lock, когда раскладка PlayTools выключена, и исправляет сохранение persistent references в PlayChain, нужное для Keychain Minecraft.
- `scripts/build.sh` собирает PlayTools и плагин. `scripts/install-copy.sh` устанавливает их только в новую копию игры, включает полноэкранное окно и Retina и сохраняет резервную копию настроек.

В репозитории нет Minecraft, IPA, ресурсов, миров, ключей, учётных данных или готовых бинарников. Нужна собственная установленная копия игры с подключённым PlayTools. Этот проект не предоставляет лицензию на Minecraft.

## Сборка

Требуются macOS на Apple Silicon, Xcode с iOS SDK, инструменты командной строки Xcode, Git и доступ к GitHub для зависимостей Xcode. Скрипт берёт [PlayCover/PlayTools](https://github.com/PlayCover/PlayTools) на коммите `f2bfbd76ff55f4737c959fa2eac07f9ada2e6d7e`, применяет патч и создаёт результаты в игнорируемом каталоге `build/`:

```bash
./scripts/build.sh
```

Если PlayTools уже клонирован локально, путь можно передать первым аргументом. Скрипт всё равно создаёт чистый checkout на указанном коммите и не меняет ваш рабочий каталог:

```bash
./scripts/build.sh /path/to/PlayTools
```

## Установка в отдельную копию

Сначала закройте Minecraft. Передайте путь к установленной через PlayCover копии **своей** игры и путь к новой копии. Второй аргумент необязателен; по умолчанию это `~/Applications/Minecraft Direct.app`. Скрипт откажется перезаписывать существующее приложение.

```bash
./scripts/install-copy.sh \
  "$HOME/Library/Containers/io.playcover.PlayCover/Applications/com.mojang.minecraftpe.app" \
  "$HOME/Applications/Minecraft Direct.app"
```

Скрипт копирует приложение, переносит PlayTools и плагин внутрь него, исправляет путь загрузки PlayTools в `minecraftpe`, устанавливает `MacOSX` в `Info.plist` и подписывает копию ad hoc с исходными entitlements. Исходное приложение PlayCover не меняется. Путь к файлу настроек берётся из `~/Library/Containers/io.playcover.PlayCover/App Settings/`; перед изменением создаётся резервная копия. Устанавливаются `keymapping=false`, `noKMOnInput=false`, `playChain=true`, `disableBuiltinMouse=false`, `resolution=6`, `notch=false`, `customScaler=2`.

Запускайте новую копию напрямую:

```bash
"$HOME/Applications/Minecraft Direct.app/minecraftpe"
```

При замене версии Minecraft пересоберите новую копию из своей обновлённой установки. Для повторной сборки удалите или переименуйте `build/PlayTools`, затем запустите `build.sh`; для повторной установки укажите новый путь вывода или сначала переименуйте старую копию приложения. Новые версии игры и PlayTools могут требовать обновления патча.

## Лицензия

Исходный PlayTools распространяется по [AGPL-3.0](LICENSE). Этот патч и код плагина распространяются по той же лицензии. Исходники Minecraft и другие сторонние компоненты сюда не входят.
