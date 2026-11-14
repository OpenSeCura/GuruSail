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

/* Default method calls of a GuruSail emulator, as the sim_io class of the simulation Verilog:
 * a receive returns zero and a send is dropped. A harness provides its own guru_send and
 * guru_recv in place of this file (make IO=<file>).
 *
 * Environment variable:
 *   GURU_TRACE_IO=1  print every send and receive to stderr
 */

#include "GuruRuntime.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int env_flag(const char *name) {
  const char *s = getenv(name);
  return s && *s && strcmp(s, "0") != 0;
}

static void trace_io(const char *dir, const char *name, const mpz_t val, mp_bitcnt_t len) {
  if (!env_flag("GURU_TRACE_IO")) return;
  fflush(stdout);
  gmp_fprintf(stderr, "%s %s %lu'h%Zx\n", dir, name, (unsigned long)len, val);
}

unit guru_send(const_sail_string name, const lbits v) {
  trace_io("send", name, *v.bits, v.len);
  return UNIT;
}

void guru_recv(lbits *out, const_sail_string name, const sail_int width) {
  out->len = mpz_get_ui(width);
  mpz_set_ui(*out->bits, 0);
  trace_io("recv", name, *out->bits, out->len);
}
