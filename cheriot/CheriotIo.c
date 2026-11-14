/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/* Test harness of the CHERIoT specifications (cheriot/Spec.v, SpecCheriot/Spec.v,
 * SpecCheriot/NondetSpec.v) for GuruSail emulators: external RAM, revocation table, UART and
 * the tohost check. It is a port of cheriot/TbCommon.sv, and replaces GuruIo.c
 * (make IO=cheriot/CheriotIo.c).
 *
 * Environment variables:
 *   CHERIOT_BIN=<file>    RAM image: one little-endian 64-bit word in hex per line, as the
 *                         +bin plusarg of the Verilog testbench
 *   CHERIOT_TOHOST=<hex>  address of tohost, as +tohost
 */

#include "GuruRuntime.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Cycle counter of the generated model (register guru_cycle) */
extern sail_int zguru_cycle;

#define RAM_SIZE_BYTES (256 * 1024)
#define REV_TABLE_SIZE_BYTES (4 * 1024)
/* Must match LgLineBytes in SpecDefines.v */
#define LG_LINE_BYTES 3
#define LINE_BYTES (1 << LG_LINE_BYTES)
#define NUM_LINES (RAM_SIZE_BYTES / LINE_BYTES)
#define REV_TABLE_NUM_LINES (REV_TABLE_SIZE_BYTES / LINE_BYTES)

#define UART_BASE 0x10000000u
#define UART_THR_OFFSET 0x0
#define UART_IER_OFFSET 0x4
#define UART_LCR_OFFSET 0xc
#define UART_LSR_OFFSET 0x14

static uint32_t uart_line(int off) { return UART_BASE + (uint32_t)(off & ~(LINE_BYTES - 1)); }
static int uart_byte(int off) { return off & (LINE_BYTES - 1); }

static uint64_t ram_data[NUM_LINES];
static uint8_t ram_tag[NUM_LINES];
static uint64_t rev_table_data[REV_TABLE_NUM_LINES];

static uint32_t ram_fetch_read_addr, ram_data_read_addr;
static int ram_fetch_read_rp_valid, ram_data_read_rp_valid;
static uint32_t rev_table_fetch_read_addr, rev_table_data_read_addr;
static int rev_table_fetch_read_rp_valid, rev_table_data_read_rp_valid;
static uint32_t uart_fetch_read_addr, uart_read_addr;
static int uart_fetch_read_rp_valid, uart_read_rp_valid;
static int dlab, rx_buf_valid;
static uint8_t ie, rx_buf;
static uint32_t tohost_addr;

static void tb_init(void) {
  static int inited = 0;
  if (inited) return;
  inited = 1;
  const char *bin = getenv("CHERIOT_BIN");
  if (bin && *bin) {
    FILE *f = fopen(bin, "r");
    if (!f) {
      fprintf(stderr, "cannot open %s\n", bin);
      exit(2);
    }
    unsigned long long word;
    for (size_t i = 0; i < NUM_LINES && fscanf(f, "%llx", &word) == 1; i++) ram_data[i] = word;
    fclose(f);
  }
  const char *tohost = getenv("CHERIOT_TOHOST");
  tohost_addr = (tohost && *tohost) ? (uint32_t)strtoul(tohost, NULL, 16) : 0;
}

static int has_substr(const char *s, const char *sub) { return strstr(s, sub) != NULL; }

static int has_suffix(const char *s, const char *suf) {
  size_t sl = strlen(s), bl = strlen(suf);
  return sl >= bl && strcmp(s + sl - bl, suf) == 0;
}

/* A line write request, {addr, data, dataMask, tag, tagMask} with addr most significant */
typedef struct {
  uint32_t addr;
  uint64_t data;
  uint8_t data_mask;
  int tag;
  int tag_mask;
} line_write_rq;

static line_write_rq get_write_rq(const lbits v) {
  uint64_t w[2] = {0, 0};
  mpz_export(w, NULL, -1, sizeof(uint64_t), 0, 0, *v.bits);
  line_write_rq wr;
  wr.tag_mask = (int)(w[0] & 1);
  wr.tag = (int)((w[0] >> 1) & 1);
  wr.data_mask = (uint8_t)(w[0] >> 2);
  wr.data = (w[0] >> 10) | (w[1] << 54);
  wr.addr = (uint32_t)(w[1] >> 10);
  return wr;
}

static uint64_t masked_write(uint64_t old, uint64_t data, uint8_t mask) {
  for (int b = 0; b < LINE_BYTES; b++) {
    if ((mask >> b) & 1) {
      uint64_t m = UINT64_C(0xff) << (8 * b);
      old = (old & ~m) | (data & m);
    }
  }
  return old;
}

unit guru_send(const_sail_string name, const lbits v) {
  tb_init();
  uint32_t addr = (uint32_t)mpz_get_ui(*v.bits);
  if (has_suffix(name, "_lineReadRq")) {
    int fetch = has_substr(name, "_fetch_");
    if (has_substr(name, "_ram_")) {
      if (fetch) { ram_fetch_read_addr = addr; ram_fetch_read_rp_valid = 1; }
      else { ram_data_read_addr = addr; ram_data_read_rp_valid = 1; }
    } else if (has_substr(name, "_revTable_")) {
      if (fetch) { rev_table_fetch_read_addr = addr; rev_table_fetch_read_rp_valid = 1; }
      else { rev_table_data_read_addr = addr; rev_table_data_read_rp_valid = 1; }
    } else if (has_substr(name, "_uart_")) {
      if (fetch) { uart_fetch_read_addr = addr; uart_fetch_read_rp_valid = 1; }
      else { uart_read_addr = addr; uart_read_rp_valid = 1; }
    }
  } else if (has_suffix(name, "_lineWriteRq")) {
    line_write_rq wr = get_write_rq(v);
    if (has_substr(name, "_ram_")) {
      uint32_t idx = (wr.addr >> LG_LINE_BYTES) % NUM_LINES;
      ram_data[idx] = masked_write(ram_data[idx], wr.data, wr.data_mask);
      if (wr.tag_mask) ram_tag[idx] = (uint8_t)wr.tag;

      uint32_t tohost_line_addr = tohost_addr & ~(uint32_t)(LINE_BYTES - 1);
      uint32_t tohost_byte_off = tohost_addr & (LINE_BYTES - 1);
      if (tohost_addr != 0 && wr.addr == tohost_line_addr && ((wr.data_mask >> tohost_byte_off) & 1)) {
        uint32_t tohost_val = (uint32_t)(ram_data[idx] >> (8 * tohost_byte_off));
        if (tohost_val != 0) {
          gmp_printf("[Cycle %Zd] Final cycle count\n", zguru_cycle);
          if (tohost_val == 1) {
            printf("TEST PASSED!\n");
            fflush(stdout);
            exit(0);
          } else {
            printf("TEST FAILED at test case: %u\n", tohost_val);
            fflush(stdout);
            exit(1);
          }
        }
      }
    } else if (has_substr(name, "_revTable_")) {
      uint32_t idx = (wr.addr >> LG_LINE_BYTES) % REV_TABLE_NUM_LINES;
      rev_table_data[idx] = masked_write(rev_table_data[idx], wr.data, wr.data_mask);
    } else if (has_substr(name, "_uart_")) {
      /* THR and IER see DLAB before this write's LCR update */
      if (wr.addr == uart_line(UART_THR_OFFSET) && ((wr.data_mask >> uart_byte(UART_THR_OFFSET)) & 1) && !dlab) {
        fputc((int)((wr.data >> (8 * uart_byte(UART_THR_OFFSET))) & 0xff), stdout);
        fflush(stdout);
      }
      if (wr.addr == uart_line(UART_IER_OFFSET) && ((wr.data_mask >> uart_byte(UART_IER_OFFSET)) & 1) && !dlab) {
        ie = (uint8_t)(wr.data >> (8 * uart_byte(UART_IER_OFFSET)));
      }
      if (wr.addr == uart_line(UART_LCR_OFFSET) && ((wr.data_mask >> uart_byte(UART_LCR_OFFSET)) & 1)) {
        dlab = (int)((wr.data >> (8 * uart_byte(UART_LCR_OFFSET) + 7)) & 1);
      }
    }
  } else if (has_suffix(name, "_lineReadRpReady")) {
    int fetch = has_substr(name, "_fetch_");
    if (has_substr(name, "_ram_")) {
      if (fetch) ram_fetch_read_rp_valid = 0; else ram_data_read_rp_valid = 0;
    } else if (has_substr(name, "_revTable_")) {
      if (fetch) rev_table_fetch_read_rp_valid = 0; else rev_table_data_read_rp_valid = 0;
    } else if (has_substr(name, "_uart_")) {
      if (fetch) uart_fetch_read_rp_valid = 0; else uart_read_rp_valid = 0;
    }
  }
  return UNIT;
}

/* A line read response, {data, tag} with data most significant */
static void set_read_rp(mpz_t out, uint64_t data, int tag) {
  mpz_import(out, 1, -1, sizeof(uint64_t), 0, 0, &data);
  mpz_mul_2exp(out, out, 1);
  if (tag) mpz_setbit(out, 0);
}

void guru_recv(lbits *out, const_sail_string name, const sail_int width) {
  tb_init();
  int fetch = has_substr(name, "_fetch_");
  out->len = mpz_get_ui(width);
  mpz_set_ui(*out->bits, 0);
  if (has_suffix(name, "_lineReadRqReady") || has_suffix(name, "_lineWriteRqReady") ||
      has_suffix(name, "_lineReadRpReady") || has_suffix(name, "_fenceIAck")) {
    mpz_set_ui(*out->bits, 1);
  } else if (has_suffix(name, "_lineReadRpValid")) {
    int valid;
    if (has_substr(name, "_ram_")) valid = fetch ? ram_fetch_read_rp_valid : ram_data_read_rp_valid;
    else if (has_substr(name, "_revTable_")) valid = fetch ? rev_table_fetch_read_rp_valid : rev_table_data_read_rp_valid;
    else valid = fetch ? uart_fetch_read_rp_valid : uart_read_rp_valid;
    mpz_set_ui(*out->bits, (unsigned long)valid);
  } else if (has_suffix(name, "_lineReadRp")) {
    if (has_substr(name, "_ram_")) {
      uint32_t addr = fetch ? ram_fetch_read_addr : ram_data_read_addr;
      uint32_t idx = (addr >> LG_LINE_BYTES) % NUM_LINES;
      set_read_rp(*out->bits, ram_data[idx], ram_tag[idx]);
    } else if (has_substr(name, "_revTable_")) {
      uint32_t addr = fetch ? rev_table_fetch_read_addr : rev_table_data_read_addr;
      uint32_t idx = (addr >> LG_LINE_BYTES) % REV_TABLE_NUM_LINES;
      set_read_rp(*out->bits, rev_table_data[idx], 0);
    } else {
      /* A line read has no byte mask: reading RBR's line pops the RX buffer, after LSR (which
       * may share the line) has sampled it */
      uint64_t data = 0;
      if (!fetch) {
        if (uart_read_addr == uart_line(UART_LSR_OFFSET)) {
          data |= (uint64_t)(rx_buf_valid ? 0x21 : 0x20) << (8 * uart_byte(UART_LSR_OFFSET));
        }
        if (uart_read_addr == uart_line(UART_THR_OFFSET)) {
          data |= (uint64_t)(rx_buf_valid ? rx_buf : 0) << (8 * uart_byte(UART_THR_OFFSET));
          rx_buf_valid = 0;
        }
      }
      set_read_rp(*out->bits, data, 0);
    }
  } else if (has_suffix(name, "_UartIrq")) {
    int ie0 = ie & 1, ie1 = (ie >> 1) & 1;
    mpz_set_ui(*out->bits, (unsigned long)(ie0 ? (rx_buf_valid | ie1) : ie1));
  }
  mpz_fdiv_r_2exp(*out->bits, *out->bits, out->len);
}
