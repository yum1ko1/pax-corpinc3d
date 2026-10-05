# pax-corpinc3d
Pax Universe · Pax CorpInc3D — 3D Модели на карте Pax Universe

| Папка | Что это |
|---|---|
| `pax_corpinc3d/` | сам мод (кладётся в `mods/` игры): 3D-Земля Pax Universe — здания компаний Pax Corporations и кварталы городов, аэропорты, леса, дороги, ж/д и ЛЭП, армии, корабли и самолёты в 3D, слои глобуса |
| `tools/gen_airports.py` | делает `pax_corpinc3d/config/airports.json` из данных OurAirports (`airports.csv`, `runways.csv` с ourairports.com/data, общественное достояние) |
| `tools/gen_forest.py` | делает карту лесов `pax_corpinc3d/config/forest.png` из снимков NASA (Blue Marble 2004 и Black Marble 2016 из репозитория Pax-CorpInc) |

Карта лесов заново: `pip install pillow numpy`, затем
`python tools/gen_forest.py world.200406.3x21600x10800.jpg BlackMarble_2016_3km.jpg pax_corpinc3d/config/forest.png`.

Проверка мода из папки игры: `PaxUniverse.exe --headless -- --check-mods pax_corpinc3d`.
