const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {test} = require('node:test');
const layer = path.resolve(__dirname, '../../..');
const board = JSON.parse(fs.readFileSync(path.join(layer,
    'recipes-phosphor/configuration/entity-manager/Sophgo_board.json')));
const exposures = board.flatMap(b => b.Exposes || []);
const fans = JSON.parse(fs.readFileSync(path.join(layer,
    'recipes-sophgo/sophgo-fan-control/project/config/fan-config.json')));
const dts = fs.readFileSync(path.join(layer,
    'recipes-kernel/linux/linux-aspeed/srm3-c0/aspeed-ast2600-sophgo.dts'), 'utf8');

test('eight DT clients map to eight dual-channel Entity Manager configurations', () => {
    const sensors = exposures.filter(e => e.Type === 'YU08');
    assert.equal(sensors.length, 8);
    for (let i = 0; i < 8; ++i) {
        const sensor = sensors.find(s => Number(s.Address) === 0x60 + i);
        assert.ok(sensor);
        assert.equal(sensor.Bus, 80 + i);
        assert.equal(sensor.Name, `YU08_Chip${i}_Temp`);
        assert.equal(sensor.Name1, `YU08_Board${i}_Temp`);
        assert.equal(sensor.PowerState, 'On');
        assert.match(dts, new RegExp(`i2c${80+i}\\s*=\\s*&yu08_bus${i};`));
        assert.match(dts, new RegExp(`yu08_bus${i}: i2c@${i%4}\\s*\\{[^}]*yu08@${(0x60+i).toString(16)}`));
    }
    assert.equal(exposures.filter(e => e.Name?.startsWith('YU08') &&
        e.Type === 'ExternalSensor').length, 0);
});

test('all sixteen temperatures remain required fan inputs', () => {
    const names = new Set();
    for (let i = 0; i < 8; ++i) {
        names.add(`YU08_Chip${i}_Temp`);
        names.add(`YU08_Board${i}_Temp`);
    }
    const inputs = fans.temps.filter(t => t.name.startsWith('YU08'));
    assert.equal(inputs.length, 16);
    for (const input of inputs) {
        assert.ok(names.delete(input.name));
        assert.equal(input.isInherent, true);
        assert.equal(input.dbusName, 'xyz.openbmc_project.HwmonTempSensor');
        assert.equal(input.readPath, `/xyz/openbmc_project/sensors/temperature/${input.name}`);
    }
    assert.equal(names.size, 0);
    assert.equal(fans.fans.length, 4);
    assert.equal(fans.controlParams.FanDefSpeed, 100);
});
