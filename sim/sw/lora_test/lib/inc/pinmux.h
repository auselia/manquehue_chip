// Copyright and related rights waived via CC0.
//
// Driver for the pad-sharing pinmux register (rtl/user_domain.sv,
// UserPinmux in rtl/user_pkg.sv). Selects, per shared pad, whether it's
// driven by its stock Croc peripheral or by obi_spi_host -- see the mux in
// rtl/croc_soc.sv.
//
// IMPORTANT: setting any bit here steals that pad from its stock peripheral
// immediately. In particular PINMUX_UART_SEL steals uart_rx_i/uart_tx_o --
// the console goes silent the instant that bit is set, and comes back the
// instant it's cleared. There is no partial state: a real SPI transfer
// needs SCK+MISO (UART_SEL) at minimum, so you can't keep the console alive
// during a transfer, only before and after one.
#pragma once

#include <stdint.h>
#include "config.h"

#define PINMUX_UART_SEL   (1u << 0)  // uart_rx_i/uart_tx_o    -> spi MISO(sd[1]) / SCK
#define PINMUX_GPIO01_SEL (1u << 1)  // gpio0_io/gpio1_io      -> spi CS1(csb[1]) / MOSI(sd[0])
#define PINMUX_STATUS_SEL (1u << 2)  // status_o (core_busy_o) -> spi CS0(csb[0])
#define PINMUX_ALL        (PINMUX_UART_SEL | PINMUX_GPIO01_SEL | PINMUX_STATUS_SEL)

/// Set the pinmux select register. Pass 0 to return every shared pad to its
/// stock peripheral (UART console, GPIO, core-busy status); pass
/// PINMUX_ALL before any obi_spi_host transfer -- a real transfer needs all
/// three bits set, there's no way to do one with only some of them.
void pinmux_set(uint32_t sel);

/// Read back the current pinmux select register.
uint32_t pinmux_get(void);
