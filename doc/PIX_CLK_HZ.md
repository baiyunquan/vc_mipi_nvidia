# Pixel clock adjustments

The `pix_clk_hz` value defines the pixel clock frequency of the image sensor in the NVIDIA Jetson device tree. It specifies how many pixels per second are transmitted over the MIPI CSI-2 interface.<br>
For most cases the default pixel clocks are suffient. E.g.: 1 lane 150 MHz, 2 lanes 300 MHz oder 4 lanes 600 MHz.
When streaming via the ISP path, the pixel clock may need to match the actual sensor data rate more precisely.

## Calculation — From the MIPI Data Rate

`pix_clk_hz` is derived directly from the physical lane rate:

```
pix_clk_hz = (num_lanes × lane_rate_bit_s) / bits_per_pixel
```

### Example: IMX568, 4 Lanes @ 1188 Mbit/s

The lane rate remains constant across all modes — only the bit depth changes:

```
Constant:  4 × 1,188,000,000 bit/s  =  4,752,000,000 bit/s

 8-bit:  4,752,000,000 /  8  =  594,000,000 Hz
10-bit:  4,752,000,000 / 10  =  475,200,000 Hz
12-bit:  4,752,000,000 / 12  =  396,000,000 Hz
```

The calculated value can be replaced in the device-tree.
The following example configures the 12-bit mode for a sensor with 1188 MBit/s at 4 lanes:
```
csi_pixel_bit_depth      = "12";

...

//pix_clk_hz               = PIX_CLK_HZ;
pix_clk_hz               = "396000000";
```
