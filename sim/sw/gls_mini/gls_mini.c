// Minimal bring-up test that fits the 2 KB SRAM: print a short line over the UART and return.
#include "uart.h"

int main() {
    uart_init();
    const char msg[] = "GLS OK\n";
    for (int i = 0; msg[i]; i++) uart_write(msg[i]);
    uart_write_flush();
    return 0;
}
