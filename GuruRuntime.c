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

/* Runtime of a GuruSail emulator: display, NonDet values and the cycle limit. The method
 * calls guru_send and guru_recv are in a separate file, GuruIo.c by default.
 *
 * Environment variables:
 *   GURU_CYCLES=N    cycles to run unless the design finishes earlier (default 100, as the
 *                    Verilog testbench)
 *   GURU_SEED=N      seed of NonDet values (default 0)
 */

#include "GuruRuntime.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned long long env_ull(const char *name, unsigned long long def) {
  const char *s = getenv(name);
  return (s && *s) ? strtoull(s, NULL, 0) : def;
}

unit guru_write_str(const_sail_string s) {
  fputs(s, stdout);
  return UNIT;
}

/* Verilog $write of one value under %<0?><width><b|d|x>, as Verilator prints it: the value
 * without leading zeros, padded on the left to the width. Binary and hex pad with zeros;
 * decimal pads with spaces, or with zeros when the format has the 0 flag. */
unit guru_write_bits(const_sail_string fmt, const lbits v) {
  const char *p = fmt + 1;
  int zero_flag = 0;
  if (*p == '0') {
    zero_flag = 1;
    p++;
  }
  size_t width = (size_t)strtoul(p, (char **)&p, 10);
  int base = (*p == 'b') ? 2 : (*p == 'x') ? 16 : 10;
  char pad = (base != 10 || zero_flag) ? '0' : ' ';
  char *digits = mpz_get_str(NULL, base, *v.bits);
  for (size_t n = strlen(digits); n < width; n++) fputc(pad, stdout);
  fputs(digits, stdout);
  free(digits);
  return UNIT;
}

/* splitmix64 */
static uint64_t nondet_next(void) {
  static int seeded = 0;
  static uint64_t state;
  if (!seeded) {
    seeded = 1;
    state = env_ull("GURU_SEED", 0);
  }
  uint64_t z = (state += UINT64_C(0x9e3779b97f4a7c15));
  z = (z ^ (z >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
  z = (z ^ (z >> 27)) * UINT64_C(0x94d049bb133111eb);
  return z ^ (z >> 31);
}

void guru_nondet(lbits *out, const sail_int width) {
  mp_bitcnt_t len = mpz_get_ui(width);
  size_t words = (len + 63) / 64;
  uint64_t *buf = calloc(words ? words : 1, sizeof(uint64_t));
  for (size_t i = 0; i < words; i++) buf[i] = nondet_next();
  mpz_import(*out->bits, words, -1, sizeof(uint64_t), 0, 0, buf);
  mpz_fdiv_r_2exp(*out->bits, *out->bits, len);
  out->len = len;
  free(buf);
}

void guru_max_cycles(sail_int *out, const unit u) {
  (void)u;
  mpz_set_ui(*out, env_ull("GURU_CYCLES", 100));
}
