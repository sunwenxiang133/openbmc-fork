#!/usr/bin/python3
"""Run under dbus-run-session; uses QEMU and a private fake Entity Manager."""
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

root = Path(__file__).resolve().parents[4]
work = root / 'build/SRM31/tmp/work/armv7ahf-vfpv4d16-openbmc-linux-gnueabi/yu08-temp-sensor/0.1-r0'
qemu = Path(os.environ.get('YU08_QEMU', str(root / 'build/SRM31/tmp/sysroots-components/x86_64/qemu-native/usr/bin/qemu-arm')))
service = 'xyz.openbmc_project.YU08TempSensor'
manager = '/xyz/openbmc_project/inventory'
parent = manager + '/system/board/ConfiguredBoard'
iface = 'xyz.openbmc_project.Configuration.YU08'
dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
dbus.mainloop.glib.threads_init()
bus = dbus.SessionBus()

class EntityManager(dbus.service.Object):
    def __init__(self):
        self.owner = dbus.service.BusName('xyz.openbmc_project.EntityManager', bus)
        super().__init__(bus, manager)
        self.snapshot = {}
        self.calls = 0

    @dbus.service.method('org.freedesktop.DBus.ObjectManager', out_signature='a{oa{sa{sv}}}')
    def GetManagedObjects(self):
        self.calls += 1
        return self.snapshot

em = EntityManager()
loop = GLib.MainLoop()
thread = threading.Thread(target=loop.run, daemon=True)
thread.start()
env = os.environ.copy()
env['DBUS_SYSTEM_BUS_ADDRESS'] = env['DBUS_SESSION_BUS_ADDRESS']
log = root / 'build/SRM31/validation/yu08-userspace/dbus-integration.log'
log.parent.mkdir(parents=True, exist_ok=True)

def wait_for(predicate, description, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        assert process.poll() is None, log.read_text()
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError('Timed out: ' + description + '\n' + log.read_text())

def objects():
    proxy = bus.get_object(service, '/xyz/openbmc_project/sensors', introspect=False)
    return dbus.Interface(proxy, 'org.freedesktop.DBus.ObjectManager').GetManagedObjects()

command = [str(qemu), '-L', str(work/'recipe-sysroot')]
if os.environ.get('YU08_QEMU_PEERGROUPS_WORKAROUND') == '1':
    shim = log.parent / 'qemu-peergroups.so'
    compiler = work / 'recipe-sysroot-native/usr/bin/arm-openbmc-linux-gnueabi/arm-openbmc-linux-gnueabi-gcc'
    subprocess.run([str(compiler), '-march=armv7-a', '-mfpu=vfpv4-d16',
                    '-mfloat-abi=hard', '--sysroot='+str(work/'recipe-sysroot'),
                    '-shared', '-fPIC', str(Path(__file__).with_name('qemu-peergroups.c')),
                    '-ldl', '-o', str(shim)], check=True)
    command += ['-E', 'LD_PRELOAD='+str(shim)]
command += [str(work/'build/yu08-temp-sensor')]
with log.open('w') as output:
    process = subprocess.Popen(command,
                               env=env, stdout=output, stderr=output)
    try:
        wait_for(lambda: bus.name_has_owner(service) and em.calls >= 1, 'empty configuration retry')
        assert len(objects()) == 0
        # Include a malformed configuration first: no partial sensors may appear.
        em.snapshot = {parent: {'xyz.openbmc_project.Inventory.Item.Board': {}},
                       parent+'/Bad': {iface: {'Bus': dbus.Double(1.5)}}}
        wait_for(lambda: 'configuration unavailable or invalid' in log.read_text(), 'invalid configuration rejection')
        assert len(objects()) == 0
        configs = json.loads((root/'meta-SRM31/recipes-phosphor/configuration/entity-manager/Sophgo_board.json').read_text())
        exposes = next(x for x in configs if x['Name'] == 'SRM31')['Exposes']
        entries = [x for x in exposes if x.get('Type') == 'YU08']
        assert len(entries) == 8
        snapshot = {parent: {'xyz.openbmc_project.Inventory.Item.Board': {},
                            'xyz.openbmc_project.Association.Definitions': {
                                'Associations': dbus.Array([], signature='(sss)')}}}
        for i, entry in enumerate(entries):
            # Non-default buses prove the service uses configuration, not 16+i.
            props = {'Bus': dbus.Double(941+i), 'Address': dbus.UInt64(entry['Address']),
                     'Name': entry['Name'], 'Name1': entry['Name1'], 'Type': 'YU08'}
            snapshot[parent+'/'+entry['Name']] = {iface: props}
        em.snapshot = snapshot
        wait_for(lambda: len(objects()) == 16, 'all 16 configured sensors')
        wait_for(lambda: 'bus=941' in log.read_text(), 'configured bus used')
        sensors = objects()
        for entry in entries:
            for name in [entry['Name'], entry['Name1']]:
                obj = sensors['/xyz/openbmc_project/sensors/temperature/'+name]
                value = obj['xyz.openbmc_project.Sensor.Value']
                assert math.isnan(value['Value'])
                assert value['Unit'].endswith('.DegreesC')
                assert not obj['xyz.openbmc_project.State.Decorator.Availability']['Available']
                assoc = obj['xyz.openbmc_project.Association.Definitions']['Associations']
                assert tuple(assoc[0]) == ('chassis', 'all_sensors', parent)
        em.snapshot = {}
        time.sleep(3.5)
        assert len(objects()) == 16, 'startup-only configuration must persist until restart'
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=10) == 0
        print('PASS: delayed/invalid config retry, 8 devices/16 sensors, configured buses and board association, unavailable readings, startup-only config, graceful shutdown')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        loop.quit()
