# Pax CorpInc3D

3D-здания для модов Pax CorpInc. Модели — models/*.glb, их размеры и какая модель на какую площадку — config/models.json.

## Земля HD

src/earth/earth.gd и shaders/earth*.gdshader: Земля с настоящими картами поверх игрового шейдера планеты — рельеф, ночные огни, облака, резкая маска моря, атмосфера. Карты — textures/earth/ (список в config/earth.json), готовятся скриптом pax_corporations_dev/earth_maps.py. Консоль: earth on|off.

Рельеф: NASA Earth Observatory / GEBCO, Blue Marble Next Generation (общественное достояние).
Цвет Земли: NASA Blue Marble Next Generation, июнь 2004 (world.200406); ночные огни: NASA Black Marble 2016 — общественное достояние.
Модели солдата, бронемашины, контейнеровоза и спутника: созданы автором в Meshy AI.
Города мира: GeoNames (geonames.org), CC BY 4.0 — через пакет geonamescache (MIT).
Застройка крупных городов: Overture Maps Foundation (overturemaps.org), ODbL 1.0 — © участники OpenStreetMap, Microsoft, Google.


Достопримечательности (models/landmarks/): построены в Blender скриптом pax_corporations_dev/landmarks_blender.py из примитивов — без чужих моделей и текстур.
