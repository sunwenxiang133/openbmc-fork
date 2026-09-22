#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>

typedef uint32_t u32;
enum hwmon_sensor_types { hwmon_temp, hwmon_voltage };
enum { hwmon_temp_input, hwmon_temp_max };
enum { YU08_REG_CHIP_TEMP = 0, YU08_REG_BOARD_TEMP = 1 };
struct device { void *data; };
struct i2c_client { struct device dev; };
static struct i2c_client chip;
static int response, last_reg, calls;
static void *dev_get_drvdata(struct device *dev) { return dev->data; }
static struct i2c_client *to_i2c_client(struct device *dev)
{
    return (struct i2c_client *)dev;
}
static int i2c_smbus_read_byte_data(struct i2c_client *client, int reg)
{
    assert(client == &chip);
    last_reg = reg;
    ++calls;
    return response;
}

/* Built from the production callback, with only the hardware API stubbed. */
#include "yu08-read.inc"

int main(void)
{
    struct device hwmon = {.data = &chip};
    const int values[] = {0, 60, 127, 128, 246, 255};
    long value;
    for (int channel = 0; channel < 2; ++channel) {
        for (unsigned i = 0; i < sizeof(values) / sizeof(values[0]); ++i) {
            response = values[i];
            assert(yu08_read(&hwmon, hwmon_temp, hwmon_temp_input,
                             channel, &value) == 0);
            assert(last_reg == channel);
            assert(value == values[i] * 1000L);
        }
    }
    response = -EIO;
    value = 123;
    assert(yu08_read(&hwmon, hwmon_temp, hwmon_temp_input, 0, &value) == -EIO);
    assert(value == 123);
    int previous = calls;
    assert(yu08_read(&hwmon, hwmon_temp, hwmon_temp_input, 2, &value) == -EOPNOTSUPP);
    assert(yu08_read(&hwmon, hwmon_temp, hwmon_temp_max, 0, &value) == -EOPNOTSUPP);
    assert(yu08_read(&hwmon, hwmon_voltage, hwmon_temp_input, 0, &value) == -EOPNOTSUPP);
    assert(calls == previous);
    puts("PASS: hwmon drvdata, both channels, unsigned boundaries and I/O errors");
}
