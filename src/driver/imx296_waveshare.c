// SPDX-License-Identifier: GPL-2.0
/*
 * NVIDIA tegracam driver for the Sony IMX296LQR-C used by the
 * Waveshare IMX296 Global Camera (A).
 *
 * The sensor register programming is derived from the Raspberry Pi IMX296
 * driver (Copyright 2019 Laurent Pinchart).  The tegracam integration follows
 * the NVIDIA L4T R32 camera sensor interface.
 */

#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/gpio.h>
#include <linux/i2c.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/of_gpio.h>
#include <linux/regmap.h>
#include <linux/regulator/consumer.h>

#include <media/camera_common.h>
#include <media/tegracam_core.h>

#define IMX296_NAME                    "imx296_waveshare"
#define IMX296_WIDTH                   1456
#define IMX296_HEIGHT                  1088
#define IMX296_DEFAULT_VMAX            1118
#define IMX296_HMAX                    1100
#define IMX296_OP_CLOCK                74250000ULL

#define IMX296_CTRL00                  0x3000
#define IMX296_CTRL08                  0x3008
#define IMX296_CTRL0A                  0x300a
#define IMX296_CTRL0D                  0x300d
#define IMX296_VMAX                    0x3010
#define IMX296_HMAX_REG                0x3014
#define IMX296_INCKSEL0                0x3089
#define IMX296_SHS1                    0x308d
#define IMX296_GAINDLY                 0x3212
#define IMX296_GAIN                    0x3204
#define IMX296_BLKLEVEL                0x3254
#define IMX296_SENSOR_INFO             0x3148
#define IMX296_MIPIC_AREA3W            0x4182
#define IMX296_GTTABLENUM              0x4114
#define IMX296_CTRL418C                0x418c

#define IMX296_STANDBY                 0x01
#define IMX296_XMSTA                   0x01
#define IMX296_SENSOR_INFO_COLOR       0x4a00

struct imx296_reg {
	u16 addr;
	u8 val;
};

struct imx296 {
	struct i2c_client *client;
	struct tegracam_device *tc_dev;
	struct camera_common_data *s_data;
	u32 frame_length;
};

static const struct imx296_reg imx296_init_table[] = {
	{ 0x3005, 0xf0 }, { 0x309e, 0x04 }, { 0x30a0, 0x04 },
	{ 0x30a1, 0x3c }, { 0x30a4, 0x5f }, { 0x30a8, 0x91 },
	{ 0x30ac, 0x28 }, { 0x30af, 0x0b }, { 0x30df, 0x00 },
	{ 0x3165, 0x00 }, { 0x3169, 0x10 }, { 0x316a, 0x02 },
	{ 0x31c8, 0xf3 }, { 0x31d0, 0xf4 }, { 0x321a, 0x00 },
	{ 0x3226, 0x02 }, { 0x3256, 0x01 }, { 0x3541, 0x72 },
	{ 0x3516, 0x77 }, { 0x350b, 0x7f }, { 0x3758, 0xa3 },
	{ 0x3759, 0x00 }, { 0x375a, 0x85 }, { 0x375b, 0x00 },
	{ 0x3832, 0xf5 }, { 0x3833, 0x00 }, { 0x38a2, 0xf6 },
	{ 0x38a3, 0x00 }, { 0x3a00, 0x80 }, { 0x3d48, 0xa3 },
	{ 0x3d49, 0x00 }, { 0x3d4a, 0x85 }, { 0x3d4b, 0x00 },
	{ 0x400e, 0x58 }, { 0x4014, 0x1c }, { 0x4041, 0x2a },
	{ 0x40a2, 0x06 }, { 0x40c1, 0xf6 }, { 0x40c7, 0x0f },
	{ 0x40c8, 0x00 }, { 0x4174, 0x00 },
};

static const struct regmap_config imx296_regmap_config = {
	.reg_bits = 16,
	.val_bits = 8,
	.cache_type = REGCACHE_RBTREE,
	.use_single_rw = true,
};

static int imx296_read_reg(struct camera_common_data *s_data, u16 addr,
			   u8 *val)
{
	u32 value;
	int ret = regmap_read(s_data->regmap, addr, &value);

	*val = value & 0xff;
	return ret;
}

static int imx296_write_reg(struct camera_common_data *s_data, u16 addr,
			    u8 val)
{
	return regmap_write(s_data->regmap, addr, val);
}

/* IMX296 multi-byte registers are little-endian on the wire. */
static int imx296_write_le(struct imx296 *priv, u16 addr, u32 value,
			   unsigned int bytes)
{
	unsigned int i;
	int ret;

	for (i = 0; i < bytes; ++i) {
		ret = imx296_write_reg(priv->s_data, addr + i,
					(value >> (8 * i)) & 0xff);
		if (ret)
			return ret;
	}
	return 0;
}

static int imx296_write_table(struct imx296 *priv)
{
	unsigned int i;
	int ret;

	for (i = 0; i < ARRAY_SIZE(imx296_init_table); ++i) {
		ret = imx296_write_reg(priv->s_data, imx296_init_table[i].addr,
					imx296_init_table[i].val);
		if (ret)
			return ret;
	}
	return 0;
}

static int imx296_set_group_hold(struct tegracam_device *tc_dev, bool val)
{
	struct imx296 *priv = tegracam_get_privdata(tc_dev);

	return imx296_write_reg(priv->s_data, IMX296_CTRL08, val ? 1 : 0);
}

static int imx296_set_gain(struct tegracam_device *tc_dev, s64 val)
{
	struct imx296 *priv = tegracam_get_privdata(tc_dev);
	const struct sensor_mode_properties *mode =
		&priv->s_data->sensor_props.sensor_modes[priv->s_data->mode_prop_idx];
	u32 gain;

	val = clamp_t(s64, val, mode->control_properties.min_gain_val,
			mode->control_properties.max_gain_val);
	gain = val * 10 / mode->control_properties.gain_factor;
	return imx296_write_le(priv, IMX296_GAIN, min_t(u32, gain, 480), 2);
}

static int imx296_set_exposure(struct tegracam_device *tc_dev, s64 val)
{
	struct imx296 *priv = tegracam_get_privdata(tc_dev);
	u64 lines;
	u32 shs;

	/* One line is HMAX / 74.25MHz seconds. val is in microseconds. */
	lines = val * IMX296_OP_CLOCK;
	do_div(lines, IMX296_HMAX * 1000000ULL);
	lines = clamp_t(u64, lines, 1, priv->frame_length - 1);
	shs = priv->frame_length - (u32)lines;
	return imx296_write_le(priv, IMX296_SHS1, shs, 3);
}

static int imx296_set_frame_rate(struct tegracam_device *tc_dev, s64 val)
{
	struct imx296 *priv = tegracam_get_privdata(tc_dev);
	const struct sensor_mode_properties *mode =
		&priv->s_data->sensor_props.sensor_modes[priv->s_data->mode_prop_idx];
	u64 frame_length;

	if (val <= 0)
		return -EINVAL;
	frame_length = IMX296_OP_CLOCK * mode->control_properties.framerate_factor;
	do_div(frame_length, IMX296_HMAX * val);
	priv->frame_length = clamp_t(u64, frame_length,
				      IMX296_DEFAULT_VMAX, 0xfffff);
	return imx296_write_le(priv, IMX296_VMAX, priv->frame_length, 3);
}

static const u32 imx296_ctrl_cids[] = {
	TEGRA_CAMERA_CID_GAIN,
	TEGRA_CAMERA_CID_EXPOSURE,
	TEGRA_CAMERA_CID_FRAME_RATE,
	TEGRA_CAMERA_CID_SENSOR_MODE_ID,
};

static struct tegracam_ctrl_ops imx296_ctrl_ops = {
	.numctrls = ARRAY_SIZE(imx296_ctrl_cids),
	.ctrl_cid_list = imx296_ctrl_cids,
	.set_gain = imx296_set_gain,
	.set_exposure = imx296_set_exposure,
	.set_frame_rate = imx296_set_frame_rate,
	.set_group_hold = imx296_set_group_hold,
};

static int imx296_power_on(struct camera_common_data *s_data)
{
	struct camera_common_power_rail *pw = s_data->power;
	int ret;

	if (pw->avdd && (ret = regulator_enable(pw->avdd)))
		return ret;
	if (pw->iovdd && (ret = regulator_enable(pw->iovdd)))
		goto disable_avdd;
	if (pw->dvdd && (ret = regulator_enable(pw->dvdd)))
		goto disable_iovdd;
	if (pw->reset_gpio)
		gpio_set_value_cansleep(pw->reset_gpio, 1);
	usleep_range(1000, 2000);
	pw->state = SWITCH_ON;
	return 0;

disable_iovdd:
	if (pw->iovdd)
		regulator_disable(pw->iovdd);
disable_avdd:
	if (pw->avdd)
		regulator_disable(pw->avdd);
	return ret;
}

static int imx296_power_off(struct camera_common_data *s_data)
{
	struct camera_common_power_rail *pw = s_data->power;

	if (pw->reset_gpio)
		gpio_set_value_cansleep(pw->reset_gpio, 0);
	if (pw->dvdd)
		regulator_disable(pw->dvdd);
	if (pw->iovdd)
		regulator_disable(pw->iovdd);
	if (pw->avdd)
		regulator_disable(pw->avdd);
	pw->state = SWITCH_OFF;
	return 0;
}

static int imx296_power_get(struct tegracam_device *tc_dev)
{
	struct camera_common_data *s_data = tc_dev->s_data;
	struct camera_common_power_rail *pw = s_data->power;
	struct camera_common_pdata *pdata = s_data->pdata;
	struct device *dev = tc_dev->dev;
	int ret = 0;

	if (!pdata)
		return -EFAULT;
	if (pdata->mclk_name) {
		pw->mclk = devm_clk_get(dev, pdata->mclk_name);
		if (IS_ERR(pw->mclk))
			return PTR_ERR(pw->mclk);
	}
	if (pdata->regulators.avdd)
		ret |= camera_common_regulator_get(dev, &pw->avdd,
						   pdata->regulators.avdd);
	if (pdata->regulators.iovdd)
		ret |= camera_common_regulator_get(dev, &pw->iovdd,
						   pdata->regulators.iovdd);
	if (pdata->regulators.dvdd)
		ret |= camera_common_regulator_get(dev, &pw->dvdd,
						   pdata->regulators.dvdd);
	if (ret)
		return ret;
	pw->reset_gpio = pdata->reset_gpio;
	if (gpio_is_valid(pw->reset_gpio))
		ret = gpio_request(pw->reset_gpio, "imx296_reset");
	pw->state = SWITCH_OFF;
	return ret;
}

static int imx296_power_put(struct tegracam_device *tc_dev)
{
	struct camera_common_power_rail *pw = tc_dev->s_data->power;

	if (gpio_is_valid(pw->reset_gpio))
		gpio_free(pw->reset_gpio);
	return 0;
}

static struct camera_common_pdata *imx296_parse_dt(struct tegracam_device *tc_dev)
{
	struct device *dev = tc_dev->dev;
	struct device_node *np = dev->of_node;
	struct camera_common_pdata *pdata;
	int gpio;

	pdata = devm_kzalloc(dev, sizeof(*pdata), GFP_KERNEL);
	if (!pdata)
		return NULL;
	gpio = of_get_named_gpio(np, "reset-gpios", 0);
	if (gpio == -EPROBE_DEFER)
		return ERR_PTR(gpio);
	if (gpio_is_valid(gpio))
		pdata->reset_gpio = gpio;
	of_property_read_string(np, "mclk", &pdata->mclk_name);
	of_property_read_string(np, "avdd-reg", &pdata->regulators.avdd);
	of_property_read_string(np, "iovdd-reg", &pdata->regulators.iovdd);
	of_property_read_string(np, "dvdd-reg", &pdata->regulators.dvdd);
	return pdata;
}

static int imx296_set_mode(struct tegracam_device *tc_dev)
{
	struct imx296 *priv = tegracam_get_privdata(tc_dev);
	int ret;

	ret = imx296_write_table(priv);
	if (ret)
		return ret;
	ret = imx296_write_le(priv, IMX296_HMAX_REG, IMX296_HMAX, 2);
	if (ret)
		return ret;
	priv->frame_length = IMX296_DEFAULT_VMAX;
	ret = imx296_write_le(priv, IMX296_VMAX, priv->frame_length, 3);
	if (ret)
		return ret;
	/* Waveshare board uses the Raspberry Pi module's 54MHz input clock. */
	imx296_write_reg(priv->s_data, IMX296_INCKSEL0 + 0, 0xb0);
	imx296_write_reg(priv->s_data, IMX296_INCKSEL0 + 1, 0x0f);
	imx296_write_reg(priv->s_data, IMX296_INCKSEL0 + 2, 0xb0);
	imx296_write_reg(priv->s_data, IMX296_INCKSEL0 + 3, 0x0c);
	imx296_write_reg(priv->s_data, IMX296_GTTABLENUM, 0xc5);
	imx296_write_reg(priv->s_data, IMX296_CTRL418C, 168);
	imx296_write_reg(priv->s_data, IMX296_GAINDLY, 0x09);
	imx296_write_le(priv, IMX296_BLKLEVEL, 0x3c, 2);
	imx296_write_le(priv, IMX296_MIPIC_AREA3W, IMX296_HEIGHT, 2);
	return 0;
}

static int imx296_start_streaming(struct tegracam_device *tc_dev)
{
	struct imx296 *priv = tegracam_get_privdata(tc_dev);
	int ret;

	ret = imx296_write_reg(priv->s_data, IMX296_CTRL00, 0);
	if (ret)
		return ret;
	usleep_range(2000, 5000);
	return imx296_write_reg(priv->s_data, IMX296_CTRL0A, 0);
}

static int imx296_stop_streaming(struct tegracam_device *tc_dev)
{
	struct imx296 *priv = tegracam_get_privdata(tc_dev);
	int ret;

	ret = imx296_write_reg(priv->s_data, IMX296_CTRL0A, IMX296_XMSTA);
	if (ret)
		return ret;
	return imx296_write_reg(priv->s_data, IMX296_CTRL00, IMX296_STANDBY);
}

static const int imx296_fps[] = { 60 };
static const struct camera_common_frmfmt imx296_frmfmt[] = {
	{{ IMX296_WIDTH, IMX296_HEIGHT }, imx296_fps, 1, 0, 0},
};

static struct camera_common_sensor_ops imx296_sensor_ops = {
	.numfrmfmts = ARRAY_SIZE(imx296_frmfmt),
	.frmfmt_table = imx296_frmfmt,
	.power_on = imx296_power_on,
	.power_off = imx296_power_off,
	.power_get = imx296_power_get,
	.power_put = imx296_power_put,
	.parse_dt = imx296_parse_dt,
	.read_reg = imx296_read_reg,
	.write_reg = imx296_write_reg,
	.set_mode = imx296_set_mode,
	.start_streaming = imx296_start_streaming,
	.stop_streaming = imx296_stop_streaming,
};

static const struct of_device_id imx296_of_match[] = {
	{ .compatible = "waveshare,imx296" },
	{ }
};
MODULE_DEVICE_TABLE(of, imx296_of_match);

static int imx296_board_setup(struct imx296 *priv)
{
	u8 lo, hi;
	int ret;

	if (priv->s_data->pdata->mclk_name) {
		ret = camera_common_mclk_enable(priv->s_data);
		if (ret)
			return ret;
	}
	ret = imx296_power_on(priv->s_data);
	if (ret)
		goto disable_mclk;
	ret = imx296_read_reg(priv->s_data, IMX296_SENSOR_INFO, &lo);
	ret |= imx296_read_reg(priv->s_data, IMX296_SENSOR_INFO + 1, &hi);
	if (!ret && (((hi << 8) | lo) & 0xff00) != IMX296_SENSOR_INFO_COLOR) {
		dev_err(priv->s_data->dev, "unexpected sensor id 0x%02x%02x\n", hi, lo);
		ret = -ENODEV;
	}
	imx296_power_off(priv->s_data);
disable_mclk:
	if (priv->s_data->pdata->mclk_name)
		camera_common_mclk_disable(priv->s_data);
	return ret;
}

static int imx296_probe(struct i2c_client *client,
			const struct i2c_device_id *id)
{
	struct device *dev = &client->dev;
	struct tegracam_device *tc_dev;
	struct imx296 *priv;
	int ret;

	if (!IS_ENABLED(CONFIG_OF) || !dev->of_node)
		return -EINVAL;
	priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
	tc_dev = devm_kzalloc(dev, sizeof(*tc_dev), GFP_KERNEL);
	if (!priv || !tc_dev)
		return -ENOMEM;
	priv->client = tc_dev->client = client;
	priv->tc_dev = tc_dev;
	tc_dev->dev = dev;
	strncpy(tc_dev->name, IMX296_NAME, sizeof(tc_dev->name));
	tc_dev->dev_regmap_config = &imx296_regmap_config;
	tc_dev->sensor_ops = &imx296_sensor_ops;
	tc_dev->tcctrl_ops = &imx296_ctrl_ops;
	ret = tegracam_device_register(tc_dev);
	if (ret)
		return ret;
	priv->s_data = tc_dev->s_data;
	tegracam_set_privdata(tc_dev, priv);
	ret = imx296_board_setup(priv);
	if (ret)
		goto unregister_device;
	ret = tegracam_v4l2subdev_register(tc_dev, true);
	if (ret)
		goto unregister_device;
	dev_info(dev, "Waveshare IMX296LQR-C detected\n");
	return 0;

unregister_device:
	tegracam_device_unregister(tc_dev);
	return ret;
}

static int imx296_remove(struct i2c_client *client)
{
	struct camera_common_data *s_data = to_camera_common_data(&client->dev);
	struct imx296 *priv = s_data->priv;

	tegracam_v4l2subdev_unregister(priv->tc_dev);
	tegracam_device_unregister(priv->tc_dev);
	return 0;
}

static const struct i2c_device_id imx296_id[] = {
	{ IMX296_NAME, 0 }, { }
};
MODULE_DEVICE_TABLE(i2c, imx296_id);

static struct i2c_driver imx296_i2c_driver = {
	.driver = {
		.name = IMX296_NAME,
		.owner = THIS_MODULE,
		.of_match_table = of_match_ptr(imx296_of_match),
	},
	.probe = imx296_probe,
	.remove = imx296_remove,
	.id_table = imx296_id,
};
module_i2c_driver(imx296_i2c_driver);

MODULE_DESCRIPTION("Waveshare IMX296 tegracam driver for Jetson Nano");
MODULE_AUTHOR("OpenAI; register programming based on Raspberry Pi IMX296 driver");
MODULE_LICENSE("GPL v2");
