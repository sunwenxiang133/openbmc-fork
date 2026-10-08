// SPDX-License-Identifier: GPL-2.0-only
/*
 * YU08 Temperature Sensor Driver
 *
 * hwmon driver for Sophgo YU08 temperature sensor chips
 */

#include <linux/module.h>
#include <linux/i2c.h>
#include <linux/hwmon.h>
#include <linux/hwmon-sysfs.h>
#include <linux/err.h>

#define YU08_REG_CHIP_TEMP	0x00
#define YU08_REG_BOARD_TEMP	0x01
#define YU08_REG_BOARD_TYPE	0x02
#define YU08_BOARD_TYPE_ID	0xb6

static int yu08_read(struct device *dev, enum hwmon_sensor_types type,
		     u32 attr, int channel, long *val)
{
	struct i2c_client *client = dev_get_drvdata(dev);
	int reg, ret;

	if (type != hwmon_temp)
		return -EOPNOTSUPP;

	if (attr != hwmon_temp_input)
		return -EOPNOTSUPP;

	switch (channel) {
	case 0:
		reg = YU08_REG_CHIP_TEMP;
		break;
	case 1:
		reg = YU08_REG_BOARD_TEMP;
		break;
	default:
		return -EOPNOTSUPP;
	}

	ret = i2c_smbus_read_byte_data(client, reg);
	if (ret < 0)
		return ret;

	/* unsigned char, unit: degree Celsius, convert to millidegree */
	*val = (long)ret * 1000;

	return 0;
}

static umode_t yu08_is_visible(const void *data, enum hwmon_sensor_types type,
			       u32 attr, int channel)
{
	if (type != hwmon_temp)
		return 0;

	if (attr == hwmon_temp_input)
		return 0444;

	return 0;
}

static const struct hwmon_ops yu08_hwmon_ops = {
	.is_visible = yu08_is_visible,
	.read = yu08_read,
};

static const struct hwmon_channel_info * const yu08_info[] = {
	HWMON_CHANNEL_INFO(temp,
			   HWMON_T_INPUT,	/* temp1: chip temperature */
			   HWMON_T_INPUT),	/* temp2: board temperature */
	NULL
};

static const struct hwmon_chip_info yu08_chip_info = {
	.ops = &yu08_hwmon_ops,
	.info = (const struct hwmon_channel_info * const *)yu08_info,
};

static int yu08_probe(struct i2c_client *client,
		      const struct i2c_device_id *id)
{
	struct device *dev = &client->dev;
	struct device *hwmon_dev;
	int board_type;

	if (!i2c_check_functionality(client->adapter, I2C_FUNC_SMBUS_BYTE_DATA))
		return -EOPNOTSUPP;

	/* Verify board type */
	board_type = i2c_smbus_read_byte_data(client, YU08_REG_BOARD_TYPE);
	if (board_type < 0) {
		dev_err(dev, "Failed to read board type: %d\n", board_type);
		return board_type;
	}

	if (board_type != YU08_BOARD_TYPE_ID) {
		dev_err(dev, "Invalid board type: 0x%02x (expected 0x%02x)\n",
			board_type, YU08_BOARD_TYPE_ID);
		return -ENODEV;
	}

	hwmon_dev = devm_hwmon_device_register_with_info(dev,
							 client->name,
							 client,
							 &yu08_chip_info,
							 NULL);
	if (IS_ERR(hwmon_dev)) {
		dev_err(dev, "Failed to register hwmon device\n");
		return PTR_ERR(hwmon_dev);
	}

	dev_info(dev, "YU08 temperature sensor registered\n");

	return 0;
}

static const struct of_device_id yu08_of_match[] = {
	{ .compatible = "sophgo,yu08" },
	{ }
};
MODULE_DEVICE_TABLE(of, yu08_of_match);

static const struct i2c_device_id yu08_id[] = {
	{ "yu08", 0 },
	{ }
};
MODULE_DEVICE_TABLE(i2c, yu08_id);

static struct i2c_driver yu08_driver = {
	.driver = {
		.name = "yu08",
		.of_match_table = yu08_of_match,
	},
	.probe = yu08_probe,
	.id_table = yu08_id,
};

module_i2c_driver(yu08_driver);

MODULE_AUTHOR("Sophgo");
MODULE_DESCRIPTION("YU08 temperature sensor driver");
MODULE_LICENSE("GPL");
