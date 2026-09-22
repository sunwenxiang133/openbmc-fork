# YU08 temperature integration

## Data path

The board device tree creates eight I2C clients. The out-of-tree `yu08.ko`
module registers two read-only hwmon inputs per client. Entity Manager provides
Bus/Address/Name/Name1 configuration, and the existing dbus-sensors
HwmonTempSensor publishes the sixteen temperatures on D-Bus for consumers such
as bmcweb and fan control.

Both temperature registers are unsigned byte Celsius according to the YU08
protocol: command 0x00 is chip temperature and 0x01 is board temperature.
The driver propagates negative SMBus errors before multiplying successful
values by 1000 for the hwmon millidegree ABI. Command 0x02 must return board
type 0xb6. No signed conversion is applied. D-Bus values use degrees Celsius
with a representable range of 0 to 255; this is not a safe operating range.

## Source locations

Paths below are relative to `meta-SRM3-C0/`:

| Component | Location |
| --- | --- |
| Driver, module autoload and binding service | `recipes-kernel/yu08-driver/` |
| Device tree and bus aliases | `recipes-kernel/linux/linux-aspeed/srm3-c0/aspeed-ast2600-sophgo.dts` |
| YU08 type and D-Bus range support | `recipes-phosphor/sensors/dbus-sensors/0002-add-yu08-hwmon-type.patch` |
| Eight dual-channel configurations | `recipes-phosphor/configuration/entity-manager/Sophgo_board.json` |
| Sixteen required thermal inputs | `recipes-sophgo/sophgo-fan-control/project/config/fan-config.json` |
| Fan protection | `recipes-sophgo/sophgo-fan-control/project/src/fan_control.cpp` |
| Image package inclusion | `meta-ast2600-sdk/conf/machine/srm3-c0.conf` |

## Configured topology

| Parent mux | Channels | Child bus aliases | YU08 addresses |
| --- | --- | --- | --- |
| `5-0070`, PCA9546 | 0, 1, 2, 3 | 80, 81, 82, 83 | 0x60, 0x61, 0x62, 0x63 |
| `7-0073`, PCA9545 | 0, 1, 2, 3 | 84, 85, 86, 87 | 0x64, 0x65, 0x66, 0x67 |

These aliases keep Entity Manager and recovery independent of dynamic adapter
number assignment. Verify this inherited mux/channel mapping against the board.
Do not assume that `hwmonX` indices are stable.

## Host power and thermal protection

`yu08-hwmon-reconcile.service` retries binding existing, unbound DT clients
while HostState is Running. It handles the case where a mux or YU08 probe ran
before the Host-powered hardware was available. Successful bindings and entry
into Running request a HwmonTempSensor service restart so newly created hwmon
paths are discovered. Failed restarts are retried. Already bound devices are
left attached. The coordinator does not read temperatures or create clients
with `new_device`.

All sixteen YU08 readings are required fan-control inputs. Missing/nonfinite
required temperatures, detected fan faults and shutdown thresholds request
full PWM immediately, including in manual mode. Normal auto operation uses
the highest requested output across configured inputs. The former Shell
temperature collector and ExternalSensor publishing are superseded.

## Local verification

Run from the OpenBMC repository root; Node.js, Bash, GCC and G++ are required:

```sh
node --test meta-SRM3-C0/recipes-kernel/yu08-driver/tests/config.test.js
bash meta-SRM3-C0/recipes-kernel/yu08-driver/tests/read.test.sh
bash meta-SRM3-C0/recipes-kernel/yu08-driver/tests/reconcile.test.sh
bash meta-SRM3-C0/recipes-kernel/yu08-driver/tests/fan.test.sh
source oe-init-build-env build/srm3-c0
bitbake obmc-phosphor-image
```

The C/C++ tests extract the production callbacks and stub hardware/D-Bus
dependencies. They exercise conversion, error propagation and fan-monitor
decisions; they do not simulate kernel probing or asynchronous D-Bus timing.
Configuration tests check DT/Entity Manager/fan mapping consistency.

The YU08-only Entity Manager configuration passes the upstream schema validator.
The complete board configuration has pre-existing fan/voltage schema failures;
these are outside this migration. This version of Entity Manager does not
enforce that validation when loading configurations at runtime.

## Board acceptance

1. Boot with Host off, then power it on. Check the coordinator journal and
   confirm both muxes bind, buses 80-87 exist and all eight YU08 clients bind.
2. Inspect each client's `hwmon/hwmon*/name`, `temp1_input` and `temp2_input`.
   Confirm the expected chip/board mapping and millidegree values.
3. Inspect `xyz.openbmc_project.HwmonTempSensor` with `busctl tree` and verify
   all `YU08_Chip0_Temp` through `YU08_Chip7_Temp` and corresponding board
   objects. Compare their Value properties with hwmon divided by 1000.
4. Verify the same sixteen readings through Redfish/WebUI, including Host
   power cycling and recovery after a delayed device becomes available.
5. With controlled fault injection, verify missing required readings cause
   full PWM in both auto and manual modes. Restore readings and verify recovery.
   Test overtemperature shutdown only in a controlled hardware test setup.

Host tests and image builds cannot establish physical mux routing, real bus
timing, PWM effectiveness or end-to-end WebUI behavior. Those require this
board acceptance run. No speculative reset-GPIO delay change is included.
