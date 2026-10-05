# pax-corpinc3d
Pax Universe · Pax CorpInc3D — 3D Модели на карте Pax Universe

| Папка | Что это |
|---|---|
| `pax_corpinc3d/` | сам мод (кладётся в `mods/` игры): 3D-здания компаний Pax Corporations и леса на 3D-Земле |
| `tools/gen_forest.py` | делает карту лесов `pax_corpinc3d/config/forest.png` из снимков NASA (Blue Marble 2004 и Black Marble 2016 из репозитория Pax-CorpInc) |

Карта лесов заново: `pip install pillow numpy`, затем
`python tools/gen_forest.py world.200406.3x21600x10800.jpg BlackMarble_2016_3km.jpg pax_corpinc3d/config/forest.png`.

Проверка мода из папки игры: `PaxUniverse.exe --headless -- --check-mods pax_corpinc3d`.
