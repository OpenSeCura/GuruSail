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

/* CallGallina for GuruSail emulators: forwards guru_gallina_call to the extracted Gallina
 * functions through Guru's PrettyPrinter/GallinaRuntime.hs, as Guru's Verilog/GallinaShim.cpp
 * does for Verilator. The Gallina registers live in the Haskell runtime.
 *
 * Environment variables, read once at the first call:
 *   GURU_GALLINA_SEED=N         seed of the CallGallina oracles (default 0)
 *   GURU_GALLINA_ORACLE_ZERO=1  every oracle is fun _ => 0
 */

#include "GuruRuntime.h"
#include "HsFFI.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

void hs_guru_gallina_call(int site, int leaf, long long cycle, const uint32_t *in, uint32_t *out);
void hs_guru_gallina_config(unsigned long long seed, int zero);

static void guru_gallina_ensure_init(void) {
  static int inited = 0;
  if (inited) return;
  inited = 1;
  hs_init(NULL, NULL);
  const char *s = getenv("GURU_GALLINA_SEED");
  const char *z = getenv("GURU_GALLINA_ORACLE_ZERO");
  unsigned long long seed = (s && *s) ? strtoull(s, NULL, 0) : 0;
  int zero = (z && *z && strcmp(z, "0") != 0) ? 1 : 0;
  hs_guru_gallina_config(seed, zero);
}

/* width is the width of the bit vectors of the Haskell runtime (gallinaWidth): it reads and
 * writes that many bits as 32-bit words, least significant first. */
void guru_gallina_call(lbits *out, const sail_int site, const sail_int leaf, const sail_int cycle,
                       const sail_int width, const lbits in, const sail_int out_width) {
  guru_gallina_ensure_init();
  size_t words = (mpz_get_ui(width) + 31) / 32;
  uint32_t *in_buf = calloc(words, sizeof(uint32_t));
  uint32_t *out_buf = calloc(words, sizeof(uint32_t));
  mpz_export(in_buf, NULL, -1, sizeof(uint32_t), 0, 0, *in.bits);
  hs_guru_gallina_call((int)mpz_get_si(site), (int)mpz_get_si(leaf), (long long)mpz_get_si(cycle), in_buf, out_buf);
  mpz_import(*out->bits, words, -1, sizeof(uint32_t), 0, 0, out_buf);
  out->len = mpz_get_ui(out_width);
  mpz_fdiv_r_2exp(*out->bits, *out->bits, out->len);
  free(in_buf);
  free(out_buf);
}
