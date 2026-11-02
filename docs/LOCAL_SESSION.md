# Локальная сессия Claude Code + Studio MCP

Подготовка Studio MCP — как в `roblox/docs/LOCAL_SESSION.md` (Assistant → Manage MCP Servers → Enable Studio as MCP server, Quick connect → Claude Code). Сначала пройди [`PLAYTEST.md`](PLAYTEST.md) руками — это не тратит лимиты. Найденное (текст из Output, описание) дешевле присылать в облачную сессию.

## Промпт для старта (скопируй целиком)

```
Проект — Roblox-игра «Петля», Rojo-проект в этом репозитории.
Studio открыта и синхронизирована через `rojo serve`, Studio MCP подключён.

Правила экономии:
- Не читай весь репозиторий: структура — в README.md, механики — в docs/DESIGN.md.
- Правь ТОЛЬКО src/**, Rojo синхронизирует сам. Не правь скрипты в Studio напрямую.
- screen_capture — только если я прошу или баг без картинки не понять.
- После каждой правки логики: `lune run tests/run.luau`.
- Если правишь Level/Loop/Planner — перезапусти `lune run scripts/gen_campaign.luau`.

Задача:
1. start_stop_play (Play), подожди ~8 с, get_console_output.
2. Найди строки [SELFTEST] и красные ошибки, пришли короткую сводку.
3. Исправляй ошибки по одной: правка → стоп/Play → Output.
4. Когда Output чистый, проверь петлю через execute_luau (datamodel Server; require из
   Command Bar даёт отдельную копию модулей, поэтому — командой-атрибутом):
     workspace:SetAttribute("DebugCommand", "state")
   В Output: `[Debug] level 1 k=2 phase=play step=… loop=1/2 ghosts=0 …`; повтори через
   секунду — step вырос примерно на 10.
5. Прогони уровни командами (datamodel Server), по одной, после каждой — get_console_output:
     workspace:SetAttribute("DebugCommand", "autoplay")   -- сервер сам проходит уровень по решению
     workspace:SetAttribute("DebugCommand", "level 22")   -- уровень 22 (autoplay продолжает)
     workspace:SetAttribute("DebugCommand", "autoplay")   -- выключить
     workspace:SetAttribute("DebugCommand", "out")        -- «петли кончились»
     workspace:SetAttribute("DebugCommand", "undo")
   Во время autoplay сделай screen_capture один раз: видны призраки с номерами, тени и пунктир,
   надписи «через N» на дверях, шкала петли сверху?
   Остальные команды: win | next | prev | restart | unlockall | coins | reset | selftest.
6. Коммить исправления с понятными сообщениями.
```

## Типичные проблемы, видимые только в движке

| Симптом | Где править |
|---|---|
| Персонаж не появляется / появляется не на старте | `LoopService.onCharacter` и `placeAt` (позиция = клетка старта + 3 studs вверх); вызывается из `setupCharacter` в `init.server` |
| Персонаж проходит сквозь закрытую дверь | Дверь — `LevelBuilder.setDoor` (`CanCollide`); сервер возвращает игрока событием `blocked` (`LoopService.handleEvents`). Если дверь у клиента открывается с задержкой — это репликация свойства, не модель |
| Призрак «плывёт» или отстаёт от записи | Клиент берёт время от `Workspace:GetServerTimeNow()` и `start` петли: `Ghosts.update`. Проверь, что `start` в событии `loop` = `run.loopStart` |
| Сервер не записывает движение (призрак стоит на старте) | `LoopService.sampleInputs`: позиция корня → клетки; слишком большой рывок за шаг откатывается (`SpeedSlack`) |
| Двери/плиты не совпадают у двоих игроков | Двери и плиты меняет только сервер по событиям модели (`handleEvents`); у клиента — только надписи «через N» (предсказание) |
| Камера слишком близко / не видно уровень | `Controls.overview` (смещение 44 вверх, 30 назад, временный `CameraMinZoomDistance = 52`) и `StarterPlayer.CameraMaxZoomDistance` в `default.project.json` |
| Кнопка ⟲ мелкая на телефоне | `Hud.buildActions` (размер 220×96 до масштаба), минимальный масштаб HUD — 0.75 (`Ui.scaled(..., 0.75)`) |
| Наложение HUD на узком экране | `Hud.layout` (режим `narrow`); тест раскладки — конец `tests/engine/client_sim.luau` |
| Лагает с 6+ призраками | число точек пунктира (`nDots` в `Ghosts.startLoop`), след призрака (`trailOn`) |

## Звуки
`Config.Sounds` — встроенные `rbxasset://` звуки (заглушки). Найди через `search_asset` бесплатные (автор Roblox или public): «перемотка» (обратный свист, ~1 с), тик часов (последние 3 секунды петли), щелчок плиты, гул двери, звон ключа, стеклянный звон для парадокса, фанфары победы — и впиши `rbxassetid://<id>` в `Config.Sounds`.
